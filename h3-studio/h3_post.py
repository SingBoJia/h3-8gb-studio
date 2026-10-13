"""MiniMax-H3 成片后期：可选提亮 + 锐化 + 插帧 60fps。

用法：
  python h3_post.py 输入.mp4 --brighten 1.35 --sharpen 0.8 -o 输出.mp4
  python h3_post.py 输入.mp4 --fps60 -o 输出_60fps.mp4
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--brighten", type=float, default=1.0, help="gamma，越大越亮（1.0 = 不动）")
    ap.add_argument("--contrast", type=float, default=1.0)
    ap.add_argument("--saturation", type=float, default=1.0)
    ap.add_argument("--sharpen", type=float, default=0.0, help="锐化强度，常用 0.5-1.0")
    ap.add_argument("--fps60", action="store_true")
    ap.add_argument("--crf", type=int, default=17)
    args = ap.parse_args()

    filters = []
    if args.brighten != 1.0 or args.contrast != 1.0 or args.saturation != 1.0:
        filters.append(f"eq=gamma={args.brighten}:contrast={args.contrast}:saturation={args.saturation}")
    if args.sharpen > 0:
        filters.append(f"unsharp=5:5:{args.sharpen}:5:5:0.0")
    if args.fps60:
        filters.append("minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1")
    if not filters:
        print("没有指定任何处理，退出")
        return

    cmd = [find_ffmpeg(), "-y", "-v", "warning", "-i", args.input,
           "-vf", ",".join(filters), "-c:v", "libx264", "-preset", "medium",
           "-crf", str(args.crf), "-pix_fmt", "yuv420p", "-c:a", "copy", args.output]
    print(" ".join(cmd))
    subprocess.run(cmd, check=True)
    print("输出: " + args.output)


if __name__ == "__main__":
    main()
