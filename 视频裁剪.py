#!/usr/bin/env python3
"""
视频裁剪（按时间）小工具

基于系统已安装的 ffmpeg / ffprobe，从一段视频里截取 [起始, 结束] 时间区间。
不依赖任何第三方库，只调用 ffmpeg 命令行。

两种模式：
  - 精确模式（默认）：重新编码（libx264/aac），帧级精确，裁出时长与请求一致；
    速度取决于片段长度与机器性能。
  - 快速模式（--fast）：流复制 -c copy，秒级完成、零画质损失；
    但只能在关键帧处切，起点会对齐到最近关键帧、时长可能略有出入。

时间格式支持：秒（如 90 / 90.5）、mm:ss（如 1:30）、hh:mm:ss（如 01:02:03）。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional


# =============================================================================
# 环境与时间解析
# =============================================================================


def ensure_ffmpeg() -> None:
    """确认 ffmpeg / ffprobe 可用，否则给出安装提示并退出。"""
    missing = [exe for exe in ("ffmpeg", "ffprobe") if shutil.which(exe) is None]
    if missing:
        print(f"[错误] 未找到命令: {', '.join(missing)}")
        print("       请先安装 ffmpeg（macOS: brew install ffmpeg）")
        sys.exit(1)


def parse_time(value: str) -> float:
    """
    把时间字符串解析为秒（float）。

    支持三种写法：
      - 纯秒：'90'、'90.5'
      - 分:秒：'1:30'（= 90 秒）
      - 时:分:秒：'01:02:03'（= 3723 秒）
    """
    value = value.strip()
    if value == "":
        raise ValueError("时间不能为空")

    parts = value.split(":")
    try:
        nums = [float(p) for p in parts]
    except ValueError:
        raise ValueError(f"无法解析时间: {value!r}")

    if len(parts) == 1:
        seconds = nums[0]
    elif len(parts) == 2:
        seconds = nums[0] * 60 + nums[1]
    elif len(parts) == 3:
        seconds = nums[0] * 3600 + nums[1] * 60 + nums[2]
    else:
        raise ValueError(f"时间格式不支持: {value!r}")

    if seconds < 0:
        raise ValueError(f"时间不能为负: {value!r}")
    return seconds


def format_hms(seconds: float) -> str:
    """把秒格式化为 HH:MM:SS.mmm，用于传给 ffmpeg 和展示。"""
    if seconds < 0:
        seconds = 0
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def label_for_filename(seconds: float) -> str:
    """
    生成简洁、文件名安全的时间标签。

    例：1.0 -> '1s'，65 -> '1m05s'，3661.5 -> '1h01m01.5s'
    （整数秒不带小数，便于自动命名时拼成 '..._cut_1s-4s.mp4' 这种可读名字）
    """
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    s_str = f"{s:.0f}" if abs(s - round(s)) < 0.001 else f"{s:.1f}"
    parts = []
    if h:
        parts.append(f"{h}h")
        parts.append(f"{m:02d}m")
        parts.append(f"{float(s_str):04.1f}s" if "." in s_str else f"{int(s_str):02d}s")
    elif m:
        parts.append(f"{m}m")
        parts.append(f"{float(s_str):04.1f}s" if "." in s_str else f"{int(s_str):02d}s")
    else:
        parts.append(f"{s_str}s")
    return "".join(parts)


# =============================================================================
# ffprobe 探测
# =============================================================================


def probe_duration(path: Path) -> Optional[float]:
    """用 ffprobe 读取视频总时长（秒）。失败返回 None。"""
    try:
        out = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return float(out) if out else None
    except (subprocess.CalledProcessError, ValueError):
        return None


def print_info(path: Path) -> None:
    """打印输入视频的时长 / 分辨率 / 编码 / 体积，便于决定裁剪区间。"""
    duration = probe_duration(path)
    size_mb = path.stat().st_size / 1024 / 1024 if path.exists() else 0
    vinfo = ""
    try:
        vinfo = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height,codec_name,r_frame_rate",
                "-of", "default=noprint_wrappers=1",
                str(path),
            ],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        pass

    print(f"文件: {path}")
    print(f"体积: {size_mb:.1f} MB")
    if duration is not None:
        print(f"时长: {format_hms(duration)} ({duration:.3f} 秒)")
    if vinfo:
        print("视频流:")
        for line in vinfo.splitlines():
            print(f"  {line}")


# =============================================================================
# 输出命名与裁剪
# =============================================================================


def build_output_path(
    input_path: Path, start: float, end: float, explicit: Optional[str]
) -> Path:
    """确定输出路径：用户指定则用之，否则在输入同目录自动命名。"""
    if explicit:
        return Path(explicit).expanduser()
    stem = input_path.stem
    suffix = input_path.suffix or ".mp4"
    name = f"{stem}_cut_{label_for_filename(start)}-{label_for_filename(end)}{suffix}"
    return input_path.with_name(name)


def build_ffmpeg_cmd(
    input_path: Path,
    output_path: Path,
    start: float,
    duration: float,
    fast: bool,
    overwrite: bool,
) -> list[str]:
    """
    组装 ffmpeg 命令。

    -ss 放在 -i 之前做输入定位（快速 seek）。
    -t 用“持续时长”而非结束时间，避免 -ss 与 -to 的时间基歧义。

    精确模式（默认）：重新编码。ffmpeg 会解码并丢弃到精确 -ss 点，
      做到帧级精确，输出时长与请求一致。
    快速模式（fast=True）：-c copy 流复制，不重编码。只能在关键帧处切，
      起点会对齐到最近的关键帧，因此实际时长可能与请求略有出入——
      这是流复制的固有限制，需要精确请改用默认（重编码）模式。
    """
    cmd = ["ffmpeg", "-hide_banner", "-y" if overwrite else "-n"]
    cmd += ["-ss", format_hms(start), "-i", str(input_path), "-t", f"{duration:.3f}"]

    if fast:
        # 快速：流复制，不重编码（关键帧对齐，时长近似）
        cmd += ["-c", "copy"]
    else:
        # 精确：重新编码，帧级精确
        cmd += [
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
        ]

    cmd.append(str(output_path))
    return cmd


def trim(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser()
    if not input_path.is_file():
        print(f"[错误] 输入文件不存在: {input_path}")
        return 1

    # 仅查看信息
    if args.info:
        print_info(input_path)
        return 0

    total = probe_duration(input_path)

    # 解析起始 / 结束 / 时长
    start = parse_time(args.start) if args.start else 0.0

    if args.duration is not None and args.end is not None:
        print("[错误] --end 与 --duration 只能二选一")
        return 1

    if args.duration is not None:
        duration = parse_time(args.duration)
        end = start + duration
    elif args.end is not None:
        end = parse_time(args.end)
        duration = end - start
    else:
        # 未指定结束：裁到视频末尾
        if total is None:
            print("[错误] 未指定 --end/--duration，且无法探测视频总时长")
            return 1
        end = total
        duration = end - start

    # 合法性校验
    if duration <= 0:
        print(f"[错误] 结束时间需晚于起始时间（起始 {format_hms(start)} ≥ 结束 {format_hms(end)}）")
        return 1
    if total is not None and start >= total:
        print(f"[错误] 起始时间 {format_hms(start)} 超过视频总时长 {format_hms(total)}")
        return 1
    if total is not None and end > total + 0.5:
        print(f"[提示] 结束时间 {format_hms(end)} 超过总时长 {format_hms(total)}，将裁到末尾")
        duration = max(0.0, total - start)

    output_path = build_output_path(input_path, start, end, args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = build_ffmpeg_cmd(
        input_path, output_path, start, duration, args.fast, overwrite=args.yes
    )

    mode = "快速(流复制，按关键帧对齐)" if args.fast else "精确(重编码)"
    print(f"模式: {mode}")
    print(f"区间: {format_hms(start)} → {format_hms(end)}  (时长 {format_hms(duration)})")
    print(f"输出: {output_path}")
    print("执行: " + " ".join(cmd))
    print("-" * 50)

    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"\n[失败] ffmpeg 返回码 {result.returncode}")
        if not args.yes and output_path.exists():
            print("       （输出已存在？加 -y 可覆盖）")
        return result.returncode

    out_dur = probe_duration(output_path)
    size_mb = output_path.stat().st_size / 1024 / 1024 if output_path.exists() else 0
    print("-" * 50)
    print(f"[完成] {output_path}")
    print(f"       体积 {size_mb:.1f} MB" + (f"，实际时长 {format_hms(out_dur)}" if out_dur else ""))
    return 0


# =============================================================================
# 入口
# =============================================================================


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="按时间裁剪视频（基于 ffmpeg）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  python3 视频裁剪.py in.mp4 -ss 00:10 -to 00:30\n"
            "  python3 视频裁剪.py in.mp4 -ss 10 -t 20 -o out.mp4\n"
            "  python3 视频裁剪.py in.mp4 -ss 5 -to 15 --fast   # 快速但按关键帧对齐\n"
            "  python3 视频裁剪.py in.mp4 --info\n"
            "\n时间格式: 秒(90 / 90.5) | 分:秒(1:30) | 时:分:秒(01:02:03)"
        ),
    )
    parser.add_argument("input", help="输入视频路径")
    parser.add_argument("-ss", "--start", help="起始时间（默认 0）")
    parser.add_argument("-to", "--end", help="结束时间（与 -t 二选一）")
    parser.add_argument("-t", "--duration", help="持续时长（与 -to 二选一）")
    parser.add_argument("-o", "--output", help="输出路径（默认在输入同目录自动命名）")
    parser.add_argument(
        "--fast", action="store_true",
        help="快速流复制（-c copy，不重编码，按关键帧对齐、时长近似）；默认帧精确重编码",
    )
    parser.add_argument("--info", action="store_true", help="仅显示输入视频信息后退出")
    parser.add_argument("-y", "--yes", action="store_true", help="覆盖已存在的输出文件")
    return parser


def main() -> None:
    ensure_ffmpeg()
    args = build_parser().parse_args()
    try:
        sys.exit(trim(args))
    except ValueError as e:
        print(f"[错误] {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
