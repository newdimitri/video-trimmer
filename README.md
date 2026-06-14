# 视频裁剪 · Video Trimmer

按时间从视频中**快速**截取片段的工具,核心是 ffmpeg **流复制**(`-c copy`)——不重编码、零画质损失、秒级完成。提供两种形态:

| 形态 | 路径 | 适合 |
|---|---|---|
| **命令行版** | [`视频裁剪.py`](视频裁剪.py) | 跨平台、脚本化;依赖系统 ffmpeg |
| **macOS App 版** | [`mac-app/`](mac-app/) | 图形界面、拖放操作;自带 ffmpeg,零依赖分发 |

---

## 功能总览

### 命令行版(`视频裁剪.py`)

- **两种模式**:默认**帧精确重编码**(裁出时长与请求完全一致);`--fast` **流复制**(秒级、零损失,按关键帧对齐)
- **灵活时间格式**:秒(`90` / `90.5`)、分:秒(`1:30`)、时:分:秒(`01:02:03`)
- **`--info`**:只查看视频信息(时长 / 分辨率 / 编码)
- 起止可用 `-ss/-to` 或 `-ss/-t`(时长);不指定结束则裁到末尾
- 自动命名输出(如 `输入_cut_5s-15s.mp4`),也可 `-o` 指定
- **纯 Python 标准库**,无第三方依赖

### macOS App 版(`mac-app/`)

- **拖放视频**,自动读取文件名与总时长(AVFoundation,无需 ffprobe)
- **多片段列表**:每段「时 : 分 : 秒 → 时 : 分 : 秒」(小时默认 0),可任意增删
- **机械硬盘性能优化**:多个片段在**一个 ffmpeg 进程内、输入只顺序读取一遍**同时切出,把「N 段 = N 次随机 seek」变成「1 次顺序读」。对无索引的直播录制大文件尤其明显——实测 3 个片段比逐段裁剪**快 2.6 倍以上**
- **可选合并**:勾选「合并为一个视频」后,把各片段按顺序用 concat **流复制**拼接成一个文件(`源名_合并_N段.mp4`),同样不重编码
- **faststart**:每个输出都把索引(`moov`)放到文件头 → **秒开**、支持网络**边下边播**
- **可视化进度条** + 实时百分比(切片 0→85%、合并 85→100%)
- **自带静态 arm64 ffmpeg**:拷到其他 Apple Silicon Mac 即可运行,无需安装任何东西
- 输出自动避让重名,失败不破坏已有文件

---

## 快速开始

### 命令行版

依赖系统的 `ffmpeg` 和 `ffprobe`:

```bash
brew install ffmpeg          # macOS
```

```bash
# 截取 00:10 到 00:30(默认帧精确)
python3 视频裁剪.py 输入.mp4 -ss 00:10 -to 00:30

# 从第 10 秒起截取 20 秒,指定输出
python3 视频裁剪.py 输入.mp4 -ss 10 -t 20 -o 输出.mp4

# 快速模式(流复制,秒级完成)
python3 视频裁剪.py 输入.mp4 -ss 5 -to 15 --fast

# 只看视频信息
python3 视频裁剪.py 输入.mp4 --info
```

#### 参数

| 参数 | 说明 |
|---|---|
| `input` | 输入视频路径(必填) |
| `-ss, --start` | 起始时间(默认 0) |
| `-to, --end` | 结束时间(与 `-t` 二选一) |
| `-t, --duration` | 持续时长(与 `-to` 二选一) |
| `-o, --output` | 输出路径(默认自动命名) |
| `--fast` | 快速流复制;默认是帧精确重编码 |
| `--info` | 只显示输入视频信息后退出 |
| `-y, --yes` | 覆盖已存在的输出文件 |

### macOS App 版

```bash
cd mac-app
chmod +x build.sh
./build.sh                   # 首次会联网下载静态 arm64 ffmpeg
open 视频裁剪.app
```

详细构建、分发、首次打开绕过 Gatekeeper 的说明见 [`mac-app/README.md`](mac-app/README.md)。

环境要求:macOS 12+、Apple Silicon(arm64)、Command Line Tools(无需完整 Xcode)。

---

## 截取模式:流复制 vs 重编码

| 模式 | 命令 | 特点 |
|---|---|---|
| **精确**(CLI 默认) | 重编码 libx264/aac | 帧级精确,裁出时长与请求**完全一致**;速度取决于片段长度 |
| **快速**(`--fast` / App 始终) | `-c copy` 流复制 | 秒级完成、零画质损失;但**只能在关键帧处切**,起止对齐最近关键帧,时长会有几帧出入 |

> 流复制只能在关键帧切,是 ffmpeg 的固有限制:要"所见即所得"的精确片段用精确模式;只想快速粗剪大文件、不在意起止差几帧就用流复制。macOS App 以"最快"为目标,始终使用流复制。

---

## 技术亮点

### 机械硬盘优化:一次顺序读取

机械硬盘**随机寻道慢、顺序读快**。传统"逐段各跑一次 ffmpeg"会反复 `-ss` 定位,对**无索引的直播录制文件**(fragmented MP4)每段都要从头扫描 fragment,截 N 段就扫描 N 次。

本工具(App 版)改为**单进程多输出**:输入只被顺序 demux 一遍,读到最后一个片段结束位置即可,同时切出所有片段。等价命令:

```bash
ffmpeg -hide_banner -y -i 输入.mp4 \
  -map 0 -c copy -ss 开始1 -t 时长1 -movflags +faststart 片段1.mp4 \
  -map 0 -c copy -ss 开始2 -t 时长2 -movflags +faststart 片段2.mp4 \
  ...
```

### faststart:秒开、可边下边播

加 `-movflags +faststart` 把索引 `moov` 移到文件头。直播录制文件常把索引拆散在整个文件里(读时长、seek 都要扫全文件,极慢);本工具裁剪/合并时**顺带重建了完整索引并前置**,产出的片段任意播放器秒开、秒拖,放到网上也能边下边播。

### 合并:流复制拼接

勾选合并后,先把各片段切到临时目录,再用 ffmpeg **concat demuxer** 流复制拼成一个文件——全程不重编码:

```bash
ffmpeg -f concat -safe 0 -i list.txt -c copy -movflags +faststart 合并.mp4
```

---

## 项目结构

```
视频裁剪/
├── 视频裁剪.py            # 命令行版(纯 Python 标准库)
├── README.md             # 本文件
└── mac-app/              # macOS App 版(SwiftUI)
    ├── Sources/
    │   ├── App.swift          # 应用入口
    │   ├── ContentView.swift  # 界面 + ViewModel
    │   └── Trimmer.swift      # 时长读取 / ffmpeg 调用 / 合并 / 命名
    ├── Info.plist
    ├── build.sh               # 一键构建:下载 ffmpeg → swiftc 编译 → 组装 .app → 签名
    └── README.md              # 构建 / 分发 / Gatekeeper 说明
```

> 构建产物(`mac-app/视频裁剪.app`)与下载的 `mac-app/Resources/ffmpeg` 不纳入版本库,`build.sh` 会自动获取与生成。

---

## 说明

- macOS App 仅支持 Apple Silicon(arm64),未做 Apple 公证;分发后对方首次打开需「右键 → 打开」。
- 命令行版跨平台,只要系统有 `ffmpeg`/`ffprobe`。
