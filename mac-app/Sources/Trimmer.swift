import AVFoundation
import Foundation

// MARK: - 数据模型

/// 单个截取片段：开始/结束时间，以「分 + 秒」输入，内部换算为总秒数。
struct TrimSegment: Identifiable, Equatable {
    let id = UUID()
    var startHours: Int = 0
    var startMinutes: Int = 0
    var startSeconds: Int = 0
    var endHours: Int = 0
    var endMinutes: Int = 0
    var endSeconds: Int = 0

    var startTotalSeconds: Double {
        Double(max(0, startHours) * 3600 + max(0, startMinutes) * 60 + max(0, startSeconds))
    }

    var endTotalSeconds: Double {
        Double(max(0, endHours) * 3600 + max(0, endMinutes) * 60 + max(0, endSeconds))
    }

    var durationSeconds: Double {
        endTotalSeconds - startTotalSeconds
    }

    /// 校验片段是否合法（结束晚于开始、秒数在 0–59）
    func validate(against videoDuration: Double?) -> String? {
        if startMinutes < 0 || startMinutes > 59 || endMinutes < 0 || endMinutes > 59 {
            return "分钟需在 0–59 之间"
        }
        if startSeconds < 0 || startSeconds > 59 || endSeconds < 0 || endSeconds > 59 {
            return "秒数需在 0–59 之间"
        }
        if durationSeconds <= 0 {
            return "结束时间必须晚于开始时间"
        }
        if let dur = videoDuration, startTotalSeconds >= dur {
            return "开始时间超过视频总时长"
        }
        if let dur = videoDuration, endTotalSeconds > dur + 0.5 {
            return "结束时间超过视频总时长"
        }
        return nil
    }
}

/// 单次截取任务的结果
struct TrimResult: Identifiable {
    let id = UUID()
    let segmentIndex: Int
    let outputURL: URL
    let success: Bool
    let message: String
}

/// 一次运行的整体结果：各分片 + 可选的合并结果
struct TrimRunResult {
    let segmentResults: [TrimResult]
    let merged: TrimResult?
}

// MARK: - 时长与命名工具

enum TimeFormat {
    /// 把秒格式化为 mm:ss 或 hh:mm:ss 供界面展示
    static func display(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 文件名安全的时间标签，如 1m05s、1h01m30s
    static func fileLabel(_ seconds: Double) -> String {
        let total = max(0.0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = total.truncatingRemainder(dividingBy: 60)
        let sRounded = (s * 10).rounded() / 10
        let sStr = abs(sRounded - sRounded.rounded()) < 0.01
            ? String(format: "%d", Int(sRounded))
            : String(format: "%.1f", sRounded)

        if h > 0 {
            return String(format: "%dh%02dm%@s", h, m, sStr.count <= 2 ? String(format: "%02d", Int(sRounded)) : sStr)
        }
        if m > 0 {
            return String(format: "%dm%@s", m, sStr.count <= 2 ? String(format: "%02d", Int(sRounded)) : sStr)
        }
        return "\(sStr)s"
    }
}

// MARK: - 视频信息与 ffmpeg 裁剪

enum TrimmerError: LocalizedError {
    case ffmpegNotFound
    case invalidInput
    case ffmpegFailed(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "未找到内置 ffmpeg，请重新构建应用"
        case .invalidInput:
            return "输入文件无效"
        case .ffmpegFailed(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "ffmpeg 失败 (code \(code))\n\(tail)"
        }
    }
}

/// 线程安全地收集 ffmpeg stderr 尾部文本（readabilityHandler 与 terminationHandler 可能在不同线程访问）
private final class StderrCollector {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + s).suffix(4000))
    }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

final class Trimmer {
    /// 内置静态 ffmpeg 路径（打包在 .app/Contents/Resources/ffmpeg）
    static var bundledFFmpegPath: URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let url = resource.appendingPathComponent("ffmpeg")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// 用 AVFoundation 读取视频时长（秒）
    static func probeDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    /// 生成输出文件路径：与源文件同目录，命名 源名_片段N_开始-结束.ext
    static func outputURL(for input: URL, segmentIndex: Int, segment: TrimSegment, directory: URL? = nil) -> URL {
        let dir = directory ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "mp4" : input.pathExtension
        let startLabel = TimeFormat.fileLabel(segment.startTotalSeconds)
        let endLabel = TimeFormat.fileLabel(segment.endTotalSeconds)
        let name = "\(stem)_片段\(segmentIndex + 1)_\(startLabel)-\(endLabel).\(ext)"
        return dir.appendingPathComponent(name)
    }

    /// 对单个片段执行流复制裁剪（最快，不重编码）
    static func trimSegment(
        input: URL,
        segment: TrimSegment,
        segmentIndex: Int,
        overwrite: Bool = true
    ) async throws -> URL {
        guard let ffmpeg = bundledFFmpegPath else { throw TrimmerError.ffmpegNotFound }
        guard FileManager.default.fileExists(atPath: input.path) else { throw TrimmerError.invalidInput }

        let output = outputURL(for: input, segmentIndex: segmentIndex, segment: segment)
        let start = segment.startTotalSeconds
        let duration = segment.durationSeconds

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner",
            overwrite ? "-y" : "-n",
            "-ss", formatFFmpegTime(start),
            "-i", input.path,
            "-t", String(format: "%.3f", duration),
            "-map", "0",
            "-c", "copy",
            "-movflags", "+faststart",
            output.path,
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw TrimmerError.ffmpegFailed(code: process.terminationStatus, stderr: stderr)
        }

        return output
    }

    /// ffmpeg 时间参数：HH:MM:SS.mmm
    private static func formatFFmpegTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = total.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }

    /// 校验片段整体是否按时间顺序且不重叠（用户约定的前提；满足时才能一次顺序读完最优）
    static func validateOrdering(_ segments: [TrimSegment]) -> String? {
        let ordered = segments.sorted { $0.startTotalSeconds < $1.startTotalSeconds }
        var lastEnd = -1.0
        for seg in ordered {
            if seg.startTotalSeconds < lastEnd - 0.001 {
                return "存在时间重叠的片段（建议各片段不重叠）"
            }
            lastEnd = seg.endTotalSeconds
        }
        return nil
    }

    /// 从 ffmpeg stderr 输出片段中解析最后一个 time=HH:MM:SS.xx，用于估算整体进度
    private static func parseProgressTime(_ chunk: String) -> Double? {
        var result: Double?
        var range = chunk.startIndex..<chunk.endIndex
        while let r = chunk.range(of: "time=", range: range) {
            let after = chunk[r.upperBound...].prefix(11)
            let parts = after.split(separator: ":")
            if parts.count == 3 {
                let h = Double(parts[0]) ?? 0
                let m = Double(parts[1]) ?? 0
                let sStr = String(parts[2].prefix(while: { $0.isNumber || $0 == "." }))
                let s = Double(sStr) ?? 0
                let t = h * 3600 + m * 60 + s
                if t >= 0 { result = t }
            }
            range = r.upperBound..<chunk.endIndex
        }
        return result
    }

    /// 一次顺序读取整段输入、同时输出所有片段（机械硬盘优化）。
    ///
    /// 关键点：用单个 ffmpeg 进程 + 多个 output，每个 output 用 output-side 的 `-ss/-t` 取自己的片段。
    /// 输入只被顺序 demux 一遍（读到最后一个片段的结束位置即可停），把原来「N 段 = N 次随机 seek /
    /// 对无索引文件 N 次从头扫描」变成「1 次顺序读」——这正是机械硬盘最快的访问模式。
    /// 前提：片段按时间顺序、不重叠（即便偶有重叠也能正确输出，只是会多读一些）。
    static func trimAll(
        input: URL,
        segments: [TrimSegment],
        outputDirectory: URL? = nil,
        onProgress: @escaping (Double, String) -> Void
    ) async -> [TrimResult] {
        let outputs = segments.enumerated().map {
            outputURL(for: input, segmentIndex: $0.offset, segment: $0.element, directory: outputDirectory)
        }

        func failAll(_ msg: String) -> [TrimResult] {
            segments.enumerated().map { i, _ in
                TrimResult(segmentIndex: i, outputURL: outputs[i], success: false, message: msg)
            }
        }

        guard let ffmpeg = bundledFFmpegPath else { return failAll("未找到内置 ffmpeg，请重新构建应用") }
        guard FileManager.default.fileExists(atPath: input.path) else { return failAll("输入文件无效") }

        var args: [String] = ["-hide_banner", "-y", "-i", input.path]
        for (i, seg) in segments.enumerated() {
            args += [
                "-map", "0", "-c", "copy",
                "-ss", formatFFmpegTime(seg.startTotalSeconds),
                "-t", String(format: "%.3f", seg.durationSeconds),
                "-movflags", "+faststart",
                outputs[i].path,
            ]
        }
        let maxEnd = segments.map(\.endTotalSeconds).max() ?? 0

        return await withCheckedContinuation { (continuation: CheckedContinuation<[TrimResult], Never>) in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = args
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice

            let handle = errPipe.fileHandleForReading
            let collector = StderrCollector()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                collector.append(s)
                if maxEnd > 0, let t = parseProgressTime(s) {
                    onProgress(min(1.0, t / maxEnd),
                               "顺序读取中 \(TimeFormat.display(t)) / \(TimeFormat.display(maxEnd))")
                }
            }
            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                if let s = String(data: rest, encoding: .utf8) {
                    collector.append(s)
                }

                let ok = proc.terminationStatus == 0
                var results: [TrimResult] = []
                for (i, _) in segments.enumerated() {
                    let out = outputs[i]
                    let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if ok && size > 0 {
                        let sizeMB = Double(size) / 1024 / 1024
                        results.append(TrimResult(
                            segmentIndex: i, outputURL: out, success: true,
                            message: "完成 → \(out.lastPathComponent) (\(String(format: "%.1f", sizeMB)) MB)"))
                    } else {
                        let tail = collector.snapshot().split(separator: "\n").suffix(2).joined(separator: " ")
                        results.append(TrimResult(
                            segmentIndex: i, outputURL: out, success: false,
                            message: ok ? "未生成输出文件" : "ffmpeg 失败(code \(proc.terminationStatus)) \(tail)"))
                    }
                }
                continuation.resume(returning: results)
            }

            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                continuation.resume(returning: failAll("无法启动 ffmpeg: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - 合并（流复制 concat）

    /// 若文件已存在则在文件名后追加序号，避免覆盖
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    /// 合并输出文件名：源名_合并_N段.ext（与源同目录，自动避让重名）
    static func mergedOutputURL(for input: URL, count: Int) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "mp4" : input.pathExtension
        return uniqueURL(dir.appendingPathComponent("\(stem)_合并_\(count)段.\(ext)"))
    }

    /// 用 concat demuxer 流复制把多个片段拼接为一个文件（不重编码）
    static func concatCopy(
        parts: [URL],
        output: URL,
        totalDuration: Double,
        onProgress: @escaping (Double, String) -> Void
    ) async -> TrimResult {
        guard let ffmpeg = bundledFFmpegPath else {
            return TrimResult(segmentIndex: -1, outputURL: output, success: false, message: "未找到内置 ffmpeg")
        }
        // concat 列表写到临时目录（路径对单引号转义）
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt_concat_\(UUID().uuidString).txt")
        let listContent = parts.map {
            let escaped = $0.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }.joined(separator: "\n")
        do {
            try listContent.write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            return TrimResult(segmentIndex: -1, outputURL: output, success: false, message: "无法写入合并列表")
        }

        let args = [
            "-hide_banner", "-y",
            "-f", "concat", "-safe", "0",
            "-i", listURL.path,
            "-c", "copy",
            "-movflags", "+faststart",
            output.path,
        ]

        return await withCheckedContinuation { (continuation: CheckedContinuation<TrimResult, Never>) in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = args
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice

            let handle = errPipe.fileHandleForReading
            let collector = StderrCollector()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                collector.append(s)
                if totalDuration > 0, let t = parseProgressTime(s) {
                    onProgress(min(1.0, t / totalDuration),
                               "合并中 \(TimeFormat.display(t)) / \(TimeFormat.display(totalDuration))")
                }
            }
            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                if let s = String(data: rest, encoding: .utf8) { collector.append(s) }
                try? FileManager.default.removeItem(at: listURL)

                let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if proc.terminationStatus == 0 && size > 0 {
                    let sizeMB = Double(size) / 1024 / 1024
                    continuation.resume(returning: TrimResult(
                        segmentIndex: -1, outputURL: output, success: true,
                        message: "合并完成 → \(output.lastPathComponent) (\(String(format: "%.1f", sizeMB)) MB)"))
                } else {
                    let tail = collector.snapshot().split(separator: "\n").suffix(2).joined(separator: " ")
                    continuation.resume(returning: TrimResult(
                        segmentIndex: -1, outputURL: output, success: false,
                        message: "合并失败(code \(proc.terminationStatus)) \(tail)"))
                }
            }
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                try? FileManager.default.removeItem(at: listURL)
                continuation.resume(returning: TrimResult(
                    segmentIndex: -1, outputURL: output, success: false,
                    message: "无法启动 ffmpeg: \(error.localizedDescription)"))
            }
        }
    }

    /// 统一入口：根据 merge 决定是否在切片后流复制合并为一个文件。
    /// 进度：切片占前 85%，合并占后 15%。
    static func run(
        input: URL,
        segments: [TrimSegment],
        merge: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async -> TrimRunResult {
        if !merge {
            let results = await trimAll(input: input, segments: segments, onProgress: onProgress)
            return TrimRunResult(segmentResults: results, merged: nil)
        }

        // 合并模式：分片切到临时目录，再 concat 复制到源目录，最后清理临时分片
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("videotrim_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let cutResults = await trimAll(input: input, segments: segments, outputDirectory: tmpDir) { p, msg in
            onProgress(p * 0.85, msg)
        }
        guard cutResults.allSatisfy(\.success) else {
            return TrimRunResult(segmentResults: cutResults, merged: nil)
        }

        let parts = cutResults.map(\.outputURL)
        let totalDur = segments.reduce(0.0) { $0 + $1.durationSeconds }
        let mergedURL = mergedOutputURL(for: input, count: segments.count)
        let mergeResult = await concatCopy(parts: parts, output: mergedURL, totalDuration: totalDur) { p, msg in
            onProgress(0.85 + p * 0.15, msg)
        }
        return TrimRunResult(segmentResults: cutResults, merged: mergeResult)
    }
}
