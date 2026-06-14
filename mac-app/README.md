# 视频裁剪（macOS）

原生 SwiftUI 应用，拖入视频、设置多个「开始时:分:秒 → 结束时:分:秒」片段，使用内置静态 ffmpeg **流复制**（`-c copy`）快速导出，不重编码、保持原画质。

**仅支持 Apple Silicon（arm64）Mac。**

## 功能

- 拖放视频文件，自动显示文件名与总时长（AVFoundation 读取）
- 多片段列表：每行输入开始/结束的「时 + 分 + 秒」（小时默认 0），可添加、删除
- 一键导出：每个片段各生成一个文件，保存在**源视频同目录**
- 自动命名：`源名_片段1_0m10s-0m30s.mp4`
- 流复制模式：最快、参数不变（切点对齐关键帧，起止可能差几帧，属正常现象）
- **机械硬盘优化**：多个片段在**一个 ffmpeg 进程内一次顺序读取**完成（前提：片段按时间顺序、不重叠），把「N 段 = N 次随机 seek」变成「1 次顺序读」。对无索引的直播录制文件尤其明显——实测 3 个片段比逐段裁剪快 2.6 倍以上
- **可选合并**：勾选「合并为一个视频」后，先切出各片段，再按顺序用 concat **流复制**拼接成一个文件（`源名_合并_N段.mp4`），同样不重编码
- **可视化进度条**：处理过程中显示实时进度条与百分比

## 构建

环境要求：

- macOS 12+
- Apple Silicon（arm64）
- Command Line Tools（`xcode-select --install`），无需完整 Xcode

```bash
cd mac-app
chmod +x build.sh
./build.sh
```

脚本会：

1. 下载静态 arm64 ffmpeg 到 `Resources/ffmpeg`（首次需联网）
2. 用 `swiftc` 编译 SwiftUI 源码
3. 组装 `视频裁剪.app` 并 ad-hoc 签名

产物：`mac-app/视频裁剪.app`（约 44 MB，自带 ffmpeg）

## 运行

```bash
open 视频裁剪.app
```

或双击 Finder 中的 `视频裁剪.app`。

## 分发到其他 Mac

1. 将 `视频裁剪.app` 压缩（zip）后发送
2. 对方解压后，**首次打开**需绕过 Gatekeeper（应用未做 Apple 公证）：
   - **推荐**：Finder 中 **右键 → 打开** → 确认打开
   - 或终端：`xattr -dr com.apple.quarantine 视频裁剪.app`
3. 无需安装 ffmpeg 或其他依赖，拷过去即可用

## 使用说明

1. 将视频拖入窗口
2. 在片段列表中填写开始/结束时间（时、分、秒；小时默认 0，分/秒 0–59）
3. 点击「+ 添加片段」可增加多段
4. （可选）勾选「合并为一个视频」：把所有片段按顺序拼接成一个文件输出
5. 点击「开始截取」
6. 状态区显示进度条与结果；输出文件在源视频所在文件夹

## ffmpeg 命令（内部）

多个片段在**一个进程内一次顺序读取、同时输出**（output-side seeking），等价于：

```bash
ffmpeg -hide_banner -y -i <输入> \
  -map 0 -c copy -ss <开始1> -t <时长1> -movflags +faststart <输出1> \
  -map 0 -c copy -ss <开始2> -t <时长2> -movflags +faststart <输出2> \
  ...
```

- 输入只被顺序 demux 一遍（读到最后一个片段的结束位置即可），避免对无索引文件反复从头扫描——这是机械硬盘的关键优化。
- `-movflags +faststart` 把索引（moov）放到文件头，便于秒开与网络边下边播。

## 项目结构

```
mac-app/
├── Sources/
│   ├── App.swift          # 应用入口
│   ├── ContentView.swift  # SwiftUI 界面
│   └── Trimmer.swift      # 时长读取、ffmpeg 调用、命名
├── Resources/
│   └── ffmpeg             # 构建时下载的静态 arm64 二进制
├── Info.plist
├── build.sh
└── README.md
```

## 注意事项

- **片段顺序、不重叠**：为发挥「一次顺序读」的性能，建议片段按时间先后排列且不重叠；若有重叠仍能正确输出，只是会多读一些数据
- **流复制限制**：只能在关键帧处精确切分，片段实际起止可能与输入差几帧；若要帧级精确需重编码（本应用为速度优先，不做重编码）
- **Intel Mac**：不支持（仅 arm64 构建）
- **重新构建**：若 `Resources/ffmpeg` 已存在，构建脚本会跳过下载

## 与 CLI 版本的关系

同目录上一级有 Python CLI 版 `视频裁剪.py`（支持 `--fast` 流复制与默认精确重编码）。本 macOS 应用为独立 GUI，始终使用流复制模式。
