import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var viewModel = TrimViewModel()

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            videoInfoBar
            segmentList
            actionBar
            statusArea
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 拖放区

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    viewModel.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(viewModel.isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                if let url = viewModel.inputURL {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    Text("将视频文件拖放到此处")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("支持 mp4 / mov / mkv 等常见格式")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
        }
        .frame(height: 120)
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isTargeted) { providers in
            viewModel.handleDrop(providers: providers)
        }
    }

    // MARK: 视频信息

    @ViewBuilder
    private var videoInfoBar: some View {
        if viewModel.inputURL != nil {
            HStack {
                Label("总时长", systemImage: "clock")
                    .foregroundStyle(.secondary)
                Text(viewModel.durationText)
                    .fontWeight(.medium)
                Spacer()
                if viewModel.ffmpegAvailable {
                    Label("流复制模式", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("ffmpeg 未就绪", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: 片段列表

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("截取片段")
                    .font(.headline)
                Spacer()
                Button(action: viewModel.addSegment) {
                    Label("添加片段", systemImage: "plus")
                }
                .disabled(viewModel.inputURL == nil)
            }

            if viewModel.segments.isEmpty {
                Text("点击「添加片段」设置开始与结束时间")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, _ in
                            SegmentRow(
                                index: index,
                                segment: $viewModel.segments[index],
                                onDelete: { viewModel.removeSegment(at: index) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: 操作栏

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("清空片段") {
                viewModel.clearSegments()
            }
            .disabled(viewModel.segments.isEmpty || viewModel.isProcessing)

            Toggle("合并为一个视频", isOn: $viewModel.mergeOutput)
                .toggleStyle(.checkbox)
                .disabled(viewModel.isProcessing)
                .help("勾选后：切出各片段并按顺序流复制拼接成一个文件输出")

            Spacer()

            Button(action: { Task { await viewModel.startTrimming() } }) {
                if viewModel.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("截取中...")
                } else {
                    Text("开始截取")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canStart)
        }
    }

    // MARK: 状态区

    @ViewBuilder
    private var statusArea: some View {
        if !viewModel.statusLines.isEmpty || !viewModel.progressText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.isProcessing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: viewModel.progress)
                            .progressViewStyle(.linear)
                        if !viewModel.progressText.isEmpty {
                            Text(viewModel.progressText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.statusLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(statusColor(for: line))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private func statusColor(for line: String) -> Color {
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("✗") { return .red }
        if line.hasPrefix("⚠") { return .orange }
        return .primary
    }
}

// MARK: - 单个片段行

struct SegmentRow: View {
    let index: Int
    @Binding var segment: TrimSegment
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("片段 \(index + 1)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            HStack(spacing: 4) {
                Text("从")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimeField(hours: $segment.startHours, minutes: $segment.startMinutes, seconds: $segment.startSeconds, label: "开始")
            }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimeField(hours: $segment.endHours, minutes: $segment.endMinutes, seconds: $segment.endSeconds, label: "结束")
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("删除此片段")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// 时 + 分 + 秒 输入框组
struct TimeField: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            TextField("时", value: $hours, format: .number)
                .frame(width: 30)
                .multilineTextAlignment(.trailing)
            Text("时")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("分", value: $minutes, format: .number)
                .frame(width: 30)
                .multilineTextAlignment(.trailing)
            Text("分")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("秒", value: $seconds, format: .number)
                .frame(width: 30)
                .multilineTextAlignment(.trailing)
            Text("秒")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .help("\(label)时间")
    }
}

// MARK: - ViewModel

@MainActor
final class TrimViewModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var videoDuration: Double?
    @Published var segments: [TrimSegment] = [TrimSegment()]
    @Published var isTargeted = false
    @Published var isProcessing = false
    @Published var statusLines: [String] = []
    @Published var progressText: String = ""
    @Published var progress: Double = 0
    @Published var mergeOutput: Bool = false
    @Published var ffmpegAvailable = false

    var durationText: String {
        guard let d = videoDuration else { return "读取中..." }
        return TimeFormat.display(d)
    }

    var canStart: Bool {
        guard inputURL != nil, ffmpegAvailable, !isProcessing, !segments.isEmpty else { return false }
        return segments.allSatisfy { $0.validate(against: videoDuration) == nil }
    }

    init() {
        ffmpegAvailable = Trimmer.bundledFFmpegPath != nil
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                await self.loadVideo(url: url)
            }
        }
        return true
    }

    func loadVideo(url: URL) async {
        inputURL = url
        videoDuration = await Trimmer.probeDuration(url: url)
        statusLines = ["已加载: \(url.lastPathComponent)"]
        if let d = videoDuration {
            statusLines.append("总时长: \(TimeFormat.display(d))")
        } else {
            statusLines.append("⚠ 无法读取时长，请确认文件格式")
        }
    }

    func addSegment() {
        segments.append(TrimSegment())
    }

    func removeSegment(at index: Int) {
        guard segments.count > 1 else {
            segments = [TrimSegment()]
            return
        }
        segments.remove(at: index)
    }

    func clearSegments() {
        segments = [TrimSegment()]
        statusLines = []
    }

    func startTrimming() async {
        guard let input = inputURL else { return }

        for (i, seg) in segments.enumerated() {
            if let err = seg.validate(against: videoDuration) {
                statusLines.append("✗ 片段 \(i + 1): \(err)")
                return
            }
        }

        isProcessing = true
        progress = 0
        progressText = ""
        let modeDesc = mergeOutput ? "截取并合并" : "截取"
        statusLines = ["开始\(modeDesc) \(segments.count) 个片段（一次顺序读取 · 机械硬盘优化 · 流复制）..."]
        if let warn = Trimmer.validateOrdering(segments) {
            statusLines.append("⚠ \(warn)")
        }

        let outcome = await Trimmer.run(input: input, segments: segments, merge: mergeOutput) { p, msg in
            Task { @MainActor in
                self.progress = p
                self.progressText = "\(Int(p * 100))%  \(msg)"
            }
        }

        let total = outcome.segmentResults.count
        if mergeOutput {
            let okCut = outcome.segmentResults.filter(\.success).count
            if okCut < total {
                for r in outcome.segmentResults where !r.success {
                    statusLines.append("✗ 片段 \(r.segmentIndex + 1): \(r.message)")
                }
                statusLines.append("--- 切片失败（\(okCut)/\(total)），未合并 ---")
            } else if let merged = outcome.merged {
                statusLines.append("✓ 已切出 \(okCut) 段")
                statusLines.append(merged.success ? "✓ \(merged.message)" : "✗ \(merged.message)")
            }
        } else {
            for r in outcome.segmentResults {
                if r.success {
                    statusLines.append("✓ \(r.message)")
                } else {
                    statusLines.append("✗ 片段 \(r.segmentIndex + 1): \(r.message)")
                }
            }
            let ok = outcome.segmentResults.filter(\.success).count
            statusLines.append("--- 完成: \(ok)/\(total) 个片段 ---")
        }

        progressText = ""
        isProcessing = false
    }
}
