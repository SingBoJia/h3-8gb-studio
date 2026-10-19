# -*- coding: utf-8 -*-
"""
MiniMax-H3 一键出片 —— 本地小服务
用一张中文表单替代 ComfyUI 的节点图：
    上传首帧图（可选） + 全局提示词 + 每段提示词 -> 自动分段生成、尾部衔接 -> 拼接成整片

启动：python server.py    然后浏览器打开 http://127.0.0.1:8799
"""
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
COMFY = "http://127.0.0.1:8188"
# server.py 就在 ComfyUI 便携版的 h3-studio 子目录里，往上一层就是根目录
COMFY_ROOT = os.path.dirname(ROOT)
if not os.path.isdir(os.path.join(COMFY_ROOT, "ComfyUI")):
    COMFY_ROOT = r"C:\ComfyUI_windows_portable"
COMFY_PY = os.path.join(COMFY_ROOT, "python_embeded", "python.exe")
COMFY_MAIN = os.path.join(COMFY_ROOT, "ComfyUI", "main.py")
COMFY_OUTPUT = os.path.join(COMFY_ROOT, "ComfyUI", "output")
STUDIO_DIR = os.path.join(COMFY_OUTPUT, "h3_studio")
SAVE_DIR = os.path.join(os.path.expanduser("~"), "Downloads")   # 成片统一保存到这里
PORT = 8799

MODELS = {
    "unet": "minimax_h3_fl2va_pruned_nvfp4.safetensors",
    "clip": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
    "vae_video": "minimax_h3_video_vae_int8_convrot.safetensors",
    "vae_audio": "minimax_h3_audio_vae_fp32.safetensors",
    "lora": "minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors",
}

JOBS = {}
JOBS_LOCK = threading.Lock()


# ---------------------------------------------------------------- ComfyUI 接口
def comfy_api(path, payload=None, timeout=30):
    url = COMFY + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def comfy_up(timeout=3):
    try:
        comfy_api("/system_stats", timeout=timeout)
        return True
    except Exception:
        return False


def ensure_comfy(log):
    if comfy_up():
        return True
    log("ComfyUI 没在运行，正在自动启动…")
    flags = 0x08000000 if os.name == "nt" else 0   # CREATE_NO_WINDOW
    # 本机实测：pinned memory 会把提交量顶到上限导致 aimdo 宿主缓冲读失败，
    # 关闭后提交量回落且出片正常。
    subprocess.Popen([COMFY_PY, "-s", COMFY_MAIN, "--port", "8188",
                      "--reserve-vram", "0.6", "--disable-auto-launch",
                      "--disable-pinned-memory"],
                     cwd=os.path.join(COMFY_ROOT, "ComfyUI"), creationflags=flags)
    deadline = time.time() + 300
    while time.time() < deadline:
        if comfy_up():
            log("ComfyUI 已就绪")
            return True
        time.sleep(2)
    raise RuntimeError("ComfyUI 启动超时，请手动双击桌面「MiniMax-H3 启动」看报错")


def upload_image(raw_bytes, filename):
    """把图片传进 ComfyUI 的 input 目录，返回它认识的文件名"""
    boundary = "----h3studio" + uuid.uuid4().hex
    body = b""
    body += ("--%s\r\n" % boundary).encode()
    body += ('Content-Disposition: form-data; name="image"; filename="%s"\r\n' % filename).encode("utf-8")
    body += b"Content-Type: application/octet-stream\r\n\r\n"
    body += raw_bytes
    body += b"\r\n"
    body += ("--%s--\r\n" % boundary).encode()
    req = urllib.request.Request(COMFY + "/upload/image", data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=120) as resp:
        info = json.loads(resp.read().decode("utf-8"))
    name = info.get("name", "uploaded.png")
    sub = info.get("subfolder")
    return (sub + "/" + name) if sub else name


# -------------------------------------------------------------------- ffmpeg
FFMPEG = None


def find_ffmpeg():
    for cand in ("ffmpeg", "ffmpeg.exe"):
        try:
            subprocess.run([cand, "-version"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
            return cand
        except Exception:
            pass
    patterns = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "hermes", "tools", "ffmpeg*", "bin", "ffmpeg.exe"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Links", "ffmpeg.exe"),
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
    ]
    found = []
    for pat in patterns:
        found += glob.glob(pat)
    for f in sorted(found, reverse=True):
        if os.path.isfile(f):
            return f
    raise RuntimeError("找不到 ffmpeg.exe，无法拼接视频")


def ffmpeg():
    global FFMPEG
    if FFMPEG is None:
        FFMPEG = find_ffmpeg()
    return FFMPEG


def media_duration(path):
    out = subprocess.run([ffmpeg(), "-hide_banner", "-i", path],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="ignore").stdout
    m = re.search(r"Duration: (\d+):(\d+):(\d+\.\d+)", out)
    if not m:
        raise RuntimeError("读不出视频时长: " + path)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


# --------------------------------------------------------------- 生成用的图
def build_graph(prompt, width, height, length, seed, seg_index,
                first_frame=None, last_frame=None, chain=True):
    g = {}
    g["1"] = {"class_type": "UNETLoader", "inputs": {"unet_name": MODELS["unet"], "weight_dtype": "default"}}
    g["2"] = {"class_type": "LoraLoaderModelOnly",
              "inputs": {"model": ["1", 0], "lora_name": MODELS["lora"], "strength_model": 1.0}}
    g["3"] = {"class_type": "CLIPLoader", "inputs": {"clip_name": MODELS["clip"], "type": "minimax"}}
    g["4"] = {"class_type": "VAELoader", "inputs": {"vae_name": MODELS["vae_video"]}}
    g["5"] = {"class_type": "VAELoader", "inputs": {"vae_name": MODELS["vae_audio"]}}

    i2v = {"clip": ["3", 0], "vae": ["4", 0], "prompt": prompt,
           "width": width, "height": height, "length": length}
    if first_frame:
        i2v["first_frame"] = ["20", 0]
        g["20"] = {"class_type": "LoadImage", "inputs": {"image": first_frame}}
    if last_frame:
        i2v["last_frame"] = ["22", 0]
        g["22"] = {"class_type": "LoadImage", "inputs": {"image": last_frame}}
    g["6"] = {"class_type": "MiniMaxH3ImageToVideo", "inputs": i2v}

    mc = {"conditioning": ["6", 0], "vae": ["4", 0], "latent": ["6", 1],
          "context_length": "56", "audio_context_length": 48}
    if seg_index > 1 and chain:
        mc["context_latent"] = ["21", 0]
        g["21"] = {"class_type": "MiniMaxH3MotionContextLoadLatent",
                   "inputs": {"latent_path": "h3_context", "clip_index": seg_index - 1}}
    g["7"] = {"class_type": "MiniMaxH3MotionContext", "inputs": mc}

    g["8"] = {"class_type": "BasicScheduler",
              "inputs": {"model": ["2", 0], "scheduler": "simple", "steps": 4, "denoise": 1.0}}
    g["9"] = {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "res_multistep"}}
    g["10"] = {"class_type": "BasicGuider", "inputs": {"model": ["2", 0], "conditioning": ["7", 0]}}
    g["11"] = {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}}
    g["12"] = {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["11", 0], "guider": ["10", 0], "sampler": ["9", 0],
                          "sigmas": ["8", 0], "latent_image": ["6", 1]}}
    g["13"] = {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["4", 0]}}
    g["14"] = {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["12", 0], "vae": ["5", 0]}}
    g["15"] = {"class_type": "MiniMaxH3MotionContextTrim",
               "inputs": {"images": ["13", 0], "trim_frames": ["7", 1], "audio": ["14", 0],
                          "fps": 24, "match_tail": True}}
    g["16"] = {"class_type": "CreateVideo", "inputs": {"images": ["15", 0], "fps": 24, "audio": ["15", 1]}}
    g["17"] = {"class_type": "SaveVideo",
               "inputs": {"video": ["16", 0], "filename_prefix": "h3_studio/seg%02d" % seg_index,
                          "format": "mp4"}}
    g["18"] = {"class_type": "MiniMaxH3MotionContextSaveLatent",
               "inputs": {"latent": ["12", 0], "filename_prefix": "h3_context/clip",
                          "clip_index": seg_index}}
    return g


def wait_prompt(prompt_id, on_tick, timeout=3600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(4)
        try:
            hist = comfy_api("/history/" + prompt_id, timeout=15)
        except Exception:
            continue
        if prompt_id in hist:
            entry = hist[prompt_id]
            if entry.get("status", {}).get("status_str") != "success":
                raise RuntimeError("生成失败：" + json.dumps(entry.get("status", {}), ensure_ascii=False)[:400])
            for out in entry.get("outputs", {}).values():
                for key in ("images", "videos", "gifs"):
                    for item in out.get(key, []) or []:
                        fn = item.get("filename")
                        if fn:
                            sub = item.get("subfolder") or ""
                            return os.path.join(COMFY_OUTPUT, sub, fn) if sub else os.path.join(COMFY_OUTPUT, fn)
            raise RuntimeError("任务完成了但没找到输出文件")
        on_tick(time.time() - t0)
    raise RuntimeError("等待超时")


def run_job(job_id, cfg):
    job = JOBS[job_id]

    def log(msg):
        job["detail"] = msg
        job["log"].append("%s  %s" % (time.strftime("%H:%M:%S"), msg))

    try:
        job["state"] = "running"
        ensure_comfy(log)

        segs = cfg["segments"]
        total = len(segs)
        seconds = float(cfg.get("seconds") or 5)
        frames = int(max(5, round(seconds * 24)))
        frames = int(frames + ((5 - (frames % 17)) % 17))     # H3 要求 17n+5
        width, height = int(cfg["width"]), int(cfg["height"])
        seed = int(cfg.get("seed") or 12345)

        global_prompt = (cfg.get("global_prompt") or "").strip()
        seg_files = []
        t_start = time.time()
        for i, seg in enumerate(segs, start=1):
            job["segment"] = i
            job["total"] = total
            seg_prompt = (seg.get("prompt") or "").strip()
            text = (global_prompt + "\n" + seg_prompt).strip() if global_prompt else seg_prompt
            # 第 1 段永远从头开始；之后每段可以选择"接上一段"或"用图片另起一段"
            chain = bool(seg.get("chain", True)) and i > 1
            first_name = last_name = None
            if seg.get("image"):
                log("正在上传第 %d 段的图片…" % i)
                name = upload_image(base64.b64decode(seg["image"].split(",", 1)[-1]),
                                    seg.get("image_name") or ("seg%02d.png" % i))
                if i == 1 or not chain:
                    first_name = name          # 用作这一段的开头画面
                else:
                    last_name = name           # 这一段演到这张图为止
            log("正在生成第 %d/%d 段…" % (i, total))
            graph = build_graph(text, width, height, frames, seed + i, i,
                                first_frame=first_name, last_frame=last_name, chain=chain)
            pid = comfy_api("/prompt", {"prompt": graph, "client_id": "h3-studio"})["prompt_id"]
            path = wait_prompt(pid, lambda el: job.__setitem__("elapsed_seg", round(el)))
            seg_files.append(path)
            done = time.time() - t_start
            job["elapsed"] = round(done)
            job["eta"] = round(done / i * (total - i)) if i < total else 0
            log("第 %d/%d 段完成" % (i, total))

        job["state"] = "assembling"
        log("正在拼接成整片…")
        os.makedirs(STUDIO_DIR, exist_ok=True)
        out = os.path.join(STUDIO_DIR, "成片_%s.mp4" % time.strftime("%Y%m%d_%H%M%S"))
        xfade = int(cfg.get("crossfade") or 0)
        if total > 1 and xfade > 0:
            d = xfade / 24.0
            fc, pv, pa, L = "", "[0:v]", "[0:a]", media_duration(seg_files[0])
            for i in range(1, total):
                fc += "%s[%d:v]xfade=transition=fade:duration=%.4f:offset=%.4f[v%d];" % (pv, i, d, L - d, i)
                fc += "%s[%d:a]acrossfade=d=%.4f:c1=tri:c2=tri[a%d];" % (pa, i, d, i)
                pv, pa = "[v%d]" % i, "[a%d]" % i
                L += media_duration(seg_files[i]) - d
            args = [ffmpeg(), "-y", "-hide_banner", "-loglevel", "error"]
            for f in seg_files:
                args += ["-i", f]
            args += ["-filter_complex", fc.rstrip(";"), "-map", pv, "-map", pa,
                     "-c:v", "libx264", "-crf", "18", "-preset", "veryfast",
                     "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", out]
            subprocess.run(args, check=True)
        else:
            listfile = os.path.join(STUDIO_DIR, "list.txt")
            with open(listfile, "w", encoding="utf-8") as fh:
                for f in seg_files:
                    fh.write("file '%s'\n" % f.replace("\\", "/"))
            subprocess.run([ffmpeg(), "-y", "-hide_banner", "-loglevel", "error",
                            "-f", "concat", "-safe", "0", "-i", listfile,
                            "-c", "copy", out], check=True)

        job["output"] = out
        try:
            os.makedirs(SAVE_DIR, exist_ok=True)
            saved = os.path.join(SAVE_DIR, os.path.basename(out))
            shutil.copy2(out, saved)
            job["saved_to"] = saved
            log("成片已保存到 %s" % saved)
        except Exception as exc:                              # noqa: BLE001
            log("保存到下载文件夹失败：%s" % exc)
        job["elapsed"] = round(time.time() - t_start)
        job["state"] = "done"
        log("全部完成！")
    except Exception as exc:                                  # noqa: BLE001
        job["state"] = "error"
        job["error"] = str(exc)
        job["log"].append("出错：" + str(exc))


# ------------------------------------------------------------------- HTTP 服务
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _job_id(self):
        return self.path.split("job=")[-1] if "job=" in self.path else ""

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            with open(os.path.join(ROOT, "index.html"), "rb") as fh:
                self._send(200, fh.read(), "text/html; charset=utf-8")
            return
        if path == "/api/status":
            job = JOBS.get(self._job_id())
            if not job:
                self._send(404, {"error": "no such job"})
                return
            payload = {k: v for k, v in job.items() if k != "log"}
            payload["log_tail"] = job["log"][-6:]
            self._send(200, payload)
            return
        if path == "/api/video":
            job = JOBS.get(self._job_id()) or {}
            out = job.get("output")
            if not out or not os.path.isfile(out):
                self._send(404, {"error": "not ready"})
                return
            size = os.path.getsize(out)
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", 'inline; filename="result.mp4"')
            self.end_headers()
            with open(out, "rb") as fh:
                while True:
                    chunk = fh.read(262144)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        path = self.path.split("?")[0]
        try:
            if path == "/api/start":
                cfg = json.loads(raw.decode("utf-8"))
                segs = [s for s in (cfg.get("segments") or []) if (s.get("prompt") or "").strip()]
                if not segs:
                    self._send(400, {"error": "至少要写一段提示词"})
                    return
                cfg["segments"] = segs
                jid = uuid.uuid4().hex[:12]
                with JOBS_LOCK:
                    JOBS[jid] = {"state": "starting", "segment": 0,
                                 "total": len(segs), "detail": "准备中",
                                 "elapsed": 0, "eta": 0, "elapsed_seg": 0,
                                 "log": [], "output": None, "error": None}
                threading.Thread(target=run_job, args=(jid, cfg), daemon=True).start()
                self._send(200, {"job": jid})
                return
            if path == "/api/open":
                info = json.loads(raw.decode("utf-8"))
                target = info.get("path") or STUDIO_DIR
                if os.path.isfile(target):
                    subprocess.Popen(["explorer", "/select,", os.path.normpath(target)])
                else:
                    subprocess.Popen(["explorer", os.path.normpath(target)])
                self._send(200, {"ok": True})
                return
        except Exception as exc:                              # noqa: BLE001
            self._send(500, {"error": str(exc)})
            return
        self._send(404, {"error": "not found"})


def main():
    os.makedirs(STUDIO_DIR, exist_ok=True)

    class QuietServer(ThreadingHTTPServer):
        """浏览器中断连接时不要打印一堆吓人的堆栈"""
        def handle_error(self, request, client_address):
            import sys as _sys
            if isinstance(_sys.exc_info()[1], ConnectionResetError):
                return
            super().handle_error(request, client_address)

    server = QuietServer(("127.0.0.1", PORT), Handler)
    print("MiniMax-H3 一键出片 已启动: http://127.0.0.1:%d" % PORT, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
