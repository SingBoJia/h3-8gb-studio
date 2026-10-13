"""MiniMax-H3 参考图模式出片（Ref2VA）

用「人物 / 道具 / 场景」参考图生成一段视频，可选自动插帧到 60fps。

用法示例：
  python h3_ref_run.py --seconds 12 --width 832 --height 480 --steps 20 --fps60
  python h3_ref_run.py --seconds 5 --width 480 --height 288 --steps 4          # 快速试跑
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SERVER = "http://127.0.0.1:8188"
HERE = os.path.dirname(os.path.abspath(__file__))
# h3_ref_run.py 就在 ComfyUI 便携版的 h3-studio 子目录里
COMFY = os.path.join(os.path.dirname(HERE), "ComfyUI")
if not os.path.isdir(COMFY):
    COMFY = r"C:\ComfyUI_windows_portable\ComfyUI"
OUTPUT_DIR = os.path.join(COMFY, "output")
SAVE_DIR = os.path.join(os.path.expanduser("~"), "Downloads")   # 成片统一保存到这里

DEFAULT_REFS = ["ref_face.png", "ref_body.png", "ref_sword.png", "ref_scene.png"]


def save_copy(src, name):
    """把成片复制到「下载」文件夹，返回目标路径。"""
    os.makedirs(SAVE_DIR, exist_ok=True)
    dst = os.path.join(SAVE_DIR, name)
    shutil.copy2(src, dst)
    print(f"已保存到: {dst}")
    return dst


def find_ffmpeg():
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    candidates = [
        os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe"),
        os.path.expandvars(r"%ProgramFiles%\ffmpeg\bin\ffmpeg.exe"),
    ]
    candidates += sorted(glob.glob(os.path.expandvars(r"%LOCALAPPDATA%\*\*\ffmpeg*\bin\ffmpeg.exe")), reverse=True)
    for p in candidates:
        if os.path.isfile(p):
            return p
    raise FileNotFoundError("找不到 ffmpeg.exe，请安装 ffmpeg 并加入 PATH 环境变量")


def align_frames(seconds):
    """H3 的帧数必须满足 17n+5（官方公式）。"""
    t = max(5, round(seconds * 24))
    return t + (5 - t % 17) % 17


def build_graph(args, prompt, frames):
    g = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": args.unet, "weight_dtype": "default"}},
        "3": {"class_type": "CLIPLoader", "inputs": {"clip_name": args.clip, "type": "minimax"}},
        "4": {"class_type": "VAELoader", "inputs": {"vae_name": args.video_vae}},
        "5": {"class_type": "VAELoader", "inputs": {"vae_name": args.audio_vae}},
        "6": {"class_type": "MiniMaxH3ReferenceToVideo", "inputs": {
            "clip": ["3", 0], "vae": ["4", 0], "audio_vae": ["5", 0],
            "prompt": prompt, "width": args.width, "height": args.height,
            "length": frames, "ref_image_size": args.ref_size}},
        "9": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "res_multistep"}},
        "11": {"class_type": "RandomNoise", "inputs": {"noise_seed": args.seed}},
        "12": {"class_type": "SamplerCustomAdvanced", "inputs": {
            "noise": ["11", 0], "guider": ["10", 0], "sampler": ["9", 0],
            "sigmas": ["8", 0], "latent_image": ["6", 1]}},
        "13": {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["4", 0]}},
        "14": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["12", 0], "vae": ["5", 0]}},
        "16": {"class_type": "CreateVideo", "inputs": {"images": ["13", 0], "fps": 24, "audio": ["14", 0]}},
        "17": {"class_type": "SaveVideo", "inputs": {"video": ["16", 0],
                                                     "filename_prefix": "h3_ref/" + args.out_prefix,
                                                     "format": "mp4"}},
    }
    model_ref = ["1", 0]
    if args.use_turbo:
        g["2"] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": ["1", 0], "lora_name": args.lora, "strength_model": 1.0}}
        model_ref = ["2", 0]
    g["8"] = {"class_type": "BasicScheduler", "inputs": {
        "model": model_ref, "scheduler": "simple", "steps": args.steps, "denoise": 1.0}}
    g["10"] = {"class_type": "BasicGuider", "inputs": {"model": model_ref, "conditioning": ["6", 0]}}
    for i, name in enumerate(args.refs):
        nid = 20 + i
        g[str(nid)] = {"class_type": "LoadImage", "inputs": {"image": name}}
        g["6"]["inputs"][f"ref_images.ref_image_{i}"] = [str(nid), 0]
    return g


def submit(graph):
    body = json.dumps({"prompt": graph, "client_id": "h3-ref-run"}).encode()
    req = urllib.request.Request(SERVER + "/prompt", data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=120))["prompt_id"]
    except urllib.error.HTTPError as e:
        print("提交被拒绝:\n" + e.read().decode("utf-8", "replace")[:2000], file=sys.stderr)
        raise


def wait_for(pid, timeout_min=180):
    started = time.time()
    while True:
        time.sleep(10)
        try:
            with urllib.request.urlopen(f"{SERVER}/history/{pid}", timeout=30) as r:
                hist = json.load(r)
        except Exception as e:
            print(f"  (查询失败 {type(e).__name__}，继续等待)")
            continue
        if pid in hist:
            return hist[pid], (time.time() - started) / 60
        mins = (time.time() - started) / 60
        if mins > timeout_min:
            raise TimeoutError("等待超时")
        print(f"  生成中... {mins:.1f} 分钟", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt-file", default=os.path.join(HERE, "prompt-aiden.txt"))
    ap.add_argument("--prompt", default=None, help="直接给提示词，覆盖 --prompt-file")
    ap.add_argument("--width", type=int, default=832)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--seconds", type=float, default=12.0)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--seed", type=int, default=777)
    ap.add_argument("--out-prefix", default="aiden")
    ap.add_argument("--refs", nargs="+", default=DEFAULT_REFS)
    ap.add_argument("--use-turbo", action="store_true", help="启用 4 步加速 LoRA")
    ap.add_argument("--fps60", action="store_true", help="生成后用 ffmpeg 插帧到 60fps")
    ap.add_argument("--unet", default="minimax_h3_fl2va_pruned_nvfp4.safetensors")
    ap.add_argument("--lora", default="minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors")
    ap.add_argument("--clip", default="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors")
    ap.add_argument("--video-vae", default="minimax_h3_video_vae_int8_convrot.safetensors")
    ap.add_argument("--audio-vae", default="minimax_h3_audio_vae_fp32.safetensors")
    ap.add_argument("--ref-size", default="match", choices=["match", "max"])
    args = ap.parse_args()

    if args.prompt is not None:
        prompt = args.prompt
    else:
        with open(args.prompt_file, encoding="utf-8") as f:
            prompt = f.read()

    frames = align_frames(args.seconds)
    print(f"帧数 {frames} = {frames / 24:.2f} 秒 | {args.width}x{args.height} | {args.steps} 步"
          f"{' + turbo LoRA' if args.use_turbo else ''} | 参考图 {len(args.refs)} 张")
    for i, r in enumerate(args.refs):
        exists = os.path.exists(os.path.join(COMFY, "input", r))
        print(f"  参考图 {i + 1}: {r} ({'OK' if exists else '缺失'})")
        if not exists:
            sys.exit(1)

    pid = submit(build_graph(args, prompt, frames))
    print(f"已提交: {pid}")
    entry, mins = wait_for(pid)
    if entry["status"]["status_str"] != "success":
        print("生成失败:")
        print(json.dumps(entry["status"]["messages"], ensure_ascii=False, indent=1)[:3000])
        sys.exit(1)

    video = None
    for out in entry["outputs"].values():
        for item in out.get("images", []):
            if item["filename"].endswith(".mp4"):
                video = os.path.join(OUTPUT_DIR, item.get("subfolder", ""), item["filename"])
    print(f"完成，用时 {mins:.2f} 分钟")
    print(f"输出: {video}")
    if video:
        save_copy(video, args.out_prefix + ".mp4")

    if args.fps60 and video:
        ff = find_ffmpeg()
        out60 = os.path.splitext(video)[0] + "_60fps.mp4"
        print("插帧到 60fps（运动补偿，需要几分钟）...")
        cmd = [ff, "-y", "-v", "warning", "-i", video,
               "-vf", "minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
               "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p",
               "-c:a", "copy", out60]
        subprocess.run(cmd, check=True)
        print(f"60fps 输出: {out60}")
        save_copy(out60, args.out_prefix + "_60帧.mp4")


if __name__ == "__main__":
    main()
