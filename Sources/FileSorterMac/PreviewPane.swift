import AppKit
import AVKit
import PDFKit
import SwiftUI

private func fourCCString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
}

private func mediaDiagnosticsString(for url: URL, knownDurationSeconds: Double? = nil) async -> String {
    let ext = url.pathExtension.lowercased()
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    let fileSize = Int64(values?.fileSize ?? 0)
    let sizeLine = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    let typeLine = values?.contentType?.identifier ?? "unknown"

    let asset = AVURLAsset(url: url)
    let isPlayable = (try? await asset.load(.isPlayable))
    let hasProtectedContent = (try? await asset.load(.hasProtectedContent))
    let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
    let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

    func trackCodecList(_ tracks: [AVAssetTrack]) async -> [String] {
        var codecs = Set<String>()
        for track in tracks {
            if let descriptions = try? await track.load(.formatDescriptions) {
                for description in descriptions {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(description)
                    codecs.insert(fourCCString(mediaSubType))
                }
            }
        }
        return Array(codecs).sorted()
    }

    let videoCodecs = await trackCodecList(videoTracks)
    let audioCodecs = await trackCodecList(audioTracks)

    let durationSeconds: Double?
    if let duration, duration.isFinite, duration > 0 {
        durationSeconds = duration
    } else {
        durationSeconds = knownDurationSeconds
    }

    var lines: [String] = []
    lines.append("Path: \(url.path)")
    lines.append("Extension: \(ext.isEmpty ? "<none>" : ext)")
    lines.append("Type: \(typeLine)")
    lines.append("Size: \(sizeLine) (\(fileSize) bytes)")
    lines.append("Playable: \(isPlayable.map(String.init(describing:)) ?? "unknown")")
    lines.append("Protected: \(hasProtectedContent.map(String.init(describing:)) ?? "unknown")")
    lines.append("Video tracks: \(videoTracks.count)")
    lines.append("Audio tracks: \(audioTracks.count)")
    lines.append("Video codecs: \(videoCodecs.isEmpty ? "none" : videoCodecs.joined(separator: ", "))")
    lines.append("Audio codecs: \(audioCodecs.isEmpty ? "none" : audioCodecs.joined(separator: ", "))")
    if let durationSeconds {
        lines.append(String(format: "Duration: %.2fs", durationSeconds))
    }

    return lines.joined(separator: "\n")
}

private func generateVideoThumbnail(for url: URL) async -> NSImage? {
    let asset = AVURLAsset(url: url)
    let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
    let captureSecond: Double = {
        guard let duration, duration.isFinite, duration > 1.0 else { return 0.0 }
        return previewSeekSecond(forDuration: duration)
    }()
    let captureTime = CMTime(seconds: captureSecond, preferredTimescale: 600)

    return await Task.detached(priority: .utility) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        guard let cgImage = try? generator.copyCGImage(at: captureTime, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }.value
}

private func previewSeekSecond(forDuration durationSeconds: Double) -> Double {
    guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
    if durationSeconds >= 90 {
        return min(25.0, max(0, durationSeconds - 5.0))
    }
    if durationSeconds >= 45 {
        return min(12.0, max(0, durationSeconds * 0.2))
    }
    return min(4.0, max(0, durationSeconds * 0.15))
}

private func generatePDFPreviewImage(for url: URL) -> NSImage? {
    guard let document = PDFDocument(url: url),
          let page = document.page(at: 0)
    else {
        return nil
    }

    let preview = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
    guard preview.size.width > 0, preview.size.height > 0 else {
        return nil
    }
    return preview
}

private func generateTextPreview(for url: URL, maxBytes: Int = 64_000, maxLines: Int = 260, maxCharacters: Int = 14_000) -> String? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          !data.isEmpty
    else {
        return nil
    }

    let sample = data.prefix(maxBytes)
    if sample.contains(0) {
        return nil
    }

    var text = String(decoding: sample, as: UTF8.self)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let clippedByLines = lines.prefix(maxLines).joined(separator: "\n")
    text = String(clippedByLines)

    var clipped = false
    if lines.count > maxLines {
        clipped = true
    }
    if text.count > maxCharacters {
        text = String(text.prefix(maxCharacters))
        clipped = true
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if clipped {
        return text + "\n\n…"
    }
    return text
}

private func isPreviewTranscodeInProgress(message: String?) -> Bool {
    guard let message else { return false }
    let lower = message.lowercased()
    let workingKeywords = ["queued", "waiting", "trying", "transcoding", "running", "preparing preview clip"]
    let finishedKeywords = ["failed", "timed out", "unavailable", "ready"]
    let hasWorking = workingKeywords.contains { lower.contains($0) }
    let hasFinished = finishedKeywords.contains { lower.contains($0) }
    return hasWorking && !hasFinished
}

private func exportSessionCompleted(
    _ session: AVAssetExportSession,
    timeoutSeconds: Double = 20,
    statusUpdate: (@Sendable (String) -> Void)? = nil
) async -> Bool {
    session.exportAsynchronously {}

    let startedAt = Date()
    var elapsedSecondsReported = -1
    while true {
        let status = session.status
        if status == .completed {
            return true
        }
        if status == .failed || status == .cancelled {
            return false
        }

        let elapsedInterval = Date().timeIntervalSince(startedAt)
        if elapsedInterval >= timeoutSeconds {
            session.cancelExport()
            statusUpdate?("Native transcode timed out.")
            return false
        }

        let elapsed = Int(elapsedInterval.rounded(.down))
        if elapsed != elapsedSecondsReported {
            elapsedSecondsReported = elapsed
            statusUpdate?("Transcoding preview clip… \(elapsed)s")
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}

private func ffmpegExecutableURL() -> URL? {
    var candidates: [String] = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    if let path = ProcessInfo.processInfo.environment["PATH"] {
        let pathEntries = path.split(separator: ":").map(String.init)
        candidates.append(contentsOf: pathEntries.map { "\($0)/ffmpeg" })
    }

    var seen = Set<String>()
    for candidate in candidates {
        guard seen.insert(candidate).inserted else { continue }
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
    }
    return nil
}

private func runFFmpegTranscode(
    sourceURL: URL,
    outputURL: URL,
    start: Double,
    duration: Double,
    statusUpdate: (@Sendable (String) -> Void)? = nil
) async -> Bool {
    guard let executableURL = ffmpegExecutableURL() else { return false }

    func run(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(25)
            var elapsedSecondsReported = -1
            while process.isRunning, Date() < deadline {
                let elapsed = Int(25 - max(0, deadline.timeIntervalSinceNow).rounded(.down))
                if elapsed != elapsedSecondsReported {
                    elapsedSecondsReported = elapsed
                    statusUpdate?("Running ffmpeg fallback… \(elapsed)s")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                process.terminate()
                statusUpdate?("ffmpeg fallback timed out.")
                return false
            }

            if process.terminationStatus != 0 {
                statusUpdate?("ffmpeg fallback failed.")
            }
            return process.terminationStatus == 0
        } catch {
            statusUpdate?("ffmpeg fallback failed.")
            return false
        }
    }

    let startArg = String(format: "%.2f", start)
    let durationArg = String(format: "%.2f", duration)
    let baseArgs: [String] = [
        "-hide_banner",
        "-nostdin",
        "-loglevel", "error",
        "-ss", startArg,
        "-t", durationArg,
        "-i", sourceURL.path,
        "-map", "0:v:0",
        "-map", "0:a:0?",
        "-movflags", "+faststart",
        "-y", outputURL.path
    ]

    statusUpdate?("Trying ffmpeg hardware encode (h264_videotoolbox)…")
    let videotoolboxArgs = baseArgs + ["-c:v", "h264_videotoolbox", "-b:v", "2.5M", "-c:a", "aac"]
    if run(arguments: videotoolboxArgs) {
        return true
    }

    try? FileManager.default.removeItem(at: outputURL)
    statusUpdate?("Trying ffmpeg software encode (libx264 ultrafast)…")
    let x264Args = baseArgs + [
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-tune", "zerolatency",
        "-pix_fmt", "yuv420p",
        "-crf", "28",
        "-c:a", "aac"
    ]
    return run(arguments: x264Args)
}

private func generateFFmpegVideoThumbnail(
    sourceURL: URL,
    startSecond: Double,
    statusUpdate: (@Sendable (String) -> Void)? = nil
) async -> NSImage? {
    guard let executableURL = ffmpegExecutableURL() else {
        statusUpdate?("ffmpeg frame extraction unavailable (ffmpeg not found).")
        return nil
    }

    statusUpdate?("Trying ffmpeg frame extraction…")

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileSorterMac-PreviewClips", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")

    defer {
        try? FileManager.default.removeItem(at: outputURL)
    }

    let args: [String] = [
        "-hide_banner",
        "-nostdin",
        "-loglevel", "error",
        "-ss", String(format: "%.2f", startSecond),
        "-i", sourceURL.path,
        "-an",
        "-frames:v", "1",
        "-f", "image2",
        "-update", "1",
        "-vf", "scale='min(960,iw)':-2",
        "-q:v", "4",
        "-y", outputURL.path
    ]

    return await Task.detached(priority: .utility) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            var elapsedSecondsReported = -1
            while process.isRunning, Date() < deadline {
                let elapsed = Int(20 - max(0, deadline.timeIntervalSinceNow).rounded(.down))
                if elapsed != elapsedSecondsReported {
                    elapsedSecondsReported = elapsed
                    statusUpdate?("Extracting preview frame via ffmpeg… \(elapsed)s")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if process.isRunning {
                process.terminate()
                statusUpdate?("ffmpeg frame extraction timed out.")
                return nil
            }

            guard process.terminationStatus == 0 else {
                statusUpdate?("ffmpeg frame extraction failed.")
                return nil
            }

            let image = NSImage(contentsOf: outputURL)
            if image != nil {
                statusUpdate?("Preview frame ready.")
            } else {
                statusUpdate?("ffmpeg frame extraction produced no image.")
            }
            return image
        } catch {
            statusUpdate?("ffmpeg frame extraction failed.")
            return nil
        }
    }.value
}

private func transcodePreviewClipToURL(
    sourceURL: URL,
    outputURL: URL,
    statusUpdate: (@Sendable (String) -> Void)? = nil
) async -> URL? {
    let asset = AVURLAsset(url: sourceURL)
    let duration = (try? await asset.load(.duration)) ?? .zero
    let durationSeconds = CMTimeGetSeconds(duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

    let maxClipDuration = min(8.0, durationSeconds)
    let start = previewSeekSecond(forDuration: durationSeconds)
    let availableDuration = max(0.2, durationSeconds - start)
    let clipDuration = min(maxClipDuration, availableDuration)
    let ffmpegClipDuration = min(3.0, clipDuration)

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
        return nil
    }

    try? FileManager.default.removeItem(at: outputURL)
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true
    session.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
    )

    statusUpdate?("Trying native transcode at \(Int(start.rounded()))s…")
    let success = await exportSessionCompleted(session, statusUpdate: statusUpdate)
    if success {
        statusUpdate?("Preview clip ready.")
        return outputURL
    }

    try? FileManager.default.removeItem(at: outputURL)
    statusUpdate?("Trying ffmpeg fallback at \(Int(start.rounded()))s…")
    let ffmpegSucceeded = await Task.detached(priority: .utility) {
        await runFFmpegTranscode(
            sourceURL: sourceURL,
            outputURL: outputURL,
            start: start,
            duration: ffmpegClipDuration,
            statusUpdate: statusUpdate
        )
    }.value
    if ffmpegSucceeded {
        statusUpdate?("Preview clip ready.")
    } else {
        statusUpdate?("Preview clip failed.")
    }
    return ffmpegSucceeded ? outputURL : nil
}

private actor TranscodedPreviewClipStore {
    static let shared = TranscodedPreviewClipStore()

    private var clipURLBySourcePath: [String: URL] = [:]
    private var taskBySourcePath: [String: Task<URL?, Never>] = [:]
    private var transcodeLogBySourcePath: [String: [String]] = [:]

    private func appendLog(_ message: String, for key: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines = transcodeLogBySourcePath[key] ?? []
        lines.append("[\(timestamp)] \(message)")
        if lines.count > 80 {
            lines = Array(lines.suffix(80))
        }
        transcodeLogBySourcePath[key] = lines
    }

    private func emitStatus(_ message: String, for key: String, statusUpdate: (@Sendable (String) -> Void)?) {
        appendLog(message, for: key)
        statusUpdate?(message)
    }

    func clipURL(for sourceURL: URL, statusUpdate: (@Sendable (String) -> Void)? = nil) async -> URL? {
        let key = sourceURL.path
        if let cached = clipURLBySourcePath[key], FileManager.default.fileExists(atPath: cached.path) {
            emitStatus("Using cached preview clip.", for: key, statusUpdate: statusUpdate)
            return cached
        }

        if let existingTask = taskBySourcePath[key] {
            emitStatus("Waiting on existing preview transcode…", for: key, statusUpdate: statusUpdate)
            return await existingTask.value
        }

        emitStatus("Queued preview transcode…", for: key, statusUpdate: statusUpdate)

        let task = Task<URL?, Never> {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileSorterMac-PreviewClips", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")
            let forwardingStatus: @Sendable (String) -> Void = { [weak self] message in
                Task {
                    await self?.emitStatus(message, for: key, statusUpdate: statusUpdate)
                }
            }
            return await transcodePreviewClipToURL(sourceURL: sourceURL, outputURL: outputURL, statusUpdate: forwardingStatus)
        }

        taskBySourcePath[key] = task
        let result = await task.value
        taskBySourcePath.removeValue(forKey: key)

        if let result {
            clipURLBySourcePath[key] = result
        }

        return result
    }

    func transcodeLog(for sourceURL: URL) -> String {
        let key = sourceURL.path
        var lines: [String] = []
        lines.append("Path: \(key)")
        let cachedStatus = clipURLBySourcePath[key] != nil ? "yes" : "no"
        lines.append("Clip cached: \(cachedStatus)")
        if let ffmpeg = ffmpegExecutableURL()?.path {
            lines.append("ffmpeg: \(ffmpeg)")
        } else {
            lines.append("ffmpeg: not found")
        }

        let logLines = transcodeLogBySourcePath[key] ?? []
        if logLines.isEmpty {
            lines.append("Transcode log: <none>")
        } else {
            lines.append("Transcode log:")
            lines.append(contentsOf: logLines)
        }

        return lines.joined(separator: "\n")
    }

    func recordStatus(for sourceURL: URL, message: String) {
        appendLog(message, for: sourceURL.path)
    }

    func clearAll() {
        for task in taskBySourcePath.values {
            task.cancel()
        }
        taskBySourcePath = [:]

        for url in clipURLBySourcePath.values {
            try? FileManager.default.removeItem(at: url)
        }
        clipURLBySourcePath = [:]
        transcodeLogBySourcePath = [:]

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSorterMac-PreviewClips", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
    }
}

private struct AnimatedImageContainerView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.image = image
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = true
        if nsView.image !== image {
            nsView.image = image
        }
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private struct PassiveAVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = videoGravity
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.controlsStyle = .none
        nsView.showsFullScreenToggleButton = false
        nsView.videoGravity = videoGravity
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private struct DuplicateCandidateCard: View {
    let file: AppModel.DuplicateCandidateFile
    let detectedPeopleCount: Int
    let isKeeper: Bool
    let isResolved: Bool
    let actionTitle: String?
    let autoplayEnabled: Bool
    let canInlineTag: Bool
    let currentTags: [String]
    let trackedPeople: [String]
    let showQuickReviewActions: Bool
    let isRejectedMatch: Bool
    let onSelectKeeper: () -> Void
    let onSubmitTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    let onConfirmMatch: () -> Void
    let onRejectMatch: () -> Void

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var textPreview: String?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var mediaAspectRatio: CGFloat = 16.0 / 9.0
    @State private var mediaPreviewIssue: String?
    @State private var isTagging: Bool = false
    @State private var tagInput: String = ""

    private let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic"]
    private let pdfExt: Set<String> = ["pdf"]
    private let textExt: Set<String> = ["txt", "md", "markdown", "json", "yaml", "yml", "csv", "tsv", "log", "xml", "html", "htm", "js", "ts", "swift", "py", "rb", "java", "c", "cpp", "h", "hpp", "ini", "toml", "conf", "cfg"]
    private let videoExt: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv"]
    private let audioExt: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"]

    var body: some View {
        let isTagged = !currentTags.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .aspectRatio(mediaAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 140, maxHeight: 420)
                } else if let player {
                    PassiveAVPlayerContainerView(player: player, videoGravity: .resizeAspect)
                        .aspectRatio(mediaAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 140, maxHeight: 420)
                        .allowsHitTesting(false)
                        .onAppear {
                            if autoplayEnabled {
                                player.play()
                            } else {
                                player.pause()
                            }
                        }
                        .onDisappear {
                            player.pause()
                        }
                } else if !canInlineTag, let textPreview {
                    ScrollView {
                        Text(textPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 140, maxHeight: 420)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
                    )
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                        .aspectRatio(mediaAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 140, maxHeight: 420)
                        .overlay(
                            Group {
                                if let mediaPreviewIssue,
                                   !mediaPreviewIssue.isEmpty {
                                    VStack(spacing: 6) {
                                        if isPreviewTranscodeInProgress(message: mediaPreviewIssue) {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "exclamationmark.triangle")
                                        }
                                        Text(mediaPreviewIssue)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(4)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                                } else {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(file.name)
                .font(.callout)
                .lineLimit(2)

            if !currentTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(currentTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Label(tag, systemImage: "tag.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if canInlineTag && !isResolved {
                                    Button {
                                        onRemoveTag(tag)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            )
                        }
                    }
                }
            } else if canInlineTag {
                Text("Click card to add tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isRejectedMatch {
                Label("Marked No", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            Text(fileMetadataLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if canInlineTag && detectedPeopleCount == 0 {
                Text("No face detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let actionTitle {
                Button(actionTitle) {
                    onSelectKeeper()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(isKeeper ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor).opacity(0.8))
                )
                .disabled(isResolved)
            }

            if showQuickReviewActions && !isResolved {
                HStack(spacing: 8) {
                    Button {
                        onConfirmMatch()
                    } label: {
                        Label("Yes", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onRejectMatch()
                    } label: {
                        Label("No", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if canInlineTag && !isResolved && isTagging {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Tag person", text: $tagInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submitInlineTag()
                        }

                    Menu("Choose Person") {
                        if trackedPeople.isEmpty {
                            Text("No tracked people yet")
                        } else {
                            ForEach(filteredSuggestions, id: \.self) { person in
                                Button(person) {
                                    tagInput = person
                                    submitInlineTag()
                                }
                            }
                        }
                    }

                    if !filteredSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(filteredSuggestions, id: \.self) { person in
                                    Button(person) {
                                        tagInput = person
                                        submitInlineTag()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty,
                       !trackedPeople.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        Button("Create \"\(trimmed)\"") {
                            submitInlineTag()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Button("Save") {
                            submitInlineTag()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            isTagging = false
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isKeeper
                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
                    : (isTagged ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .opacity(isRejectedMatch ? 0.48 : 1.0)
        .onAppear {
            loadPreviewIfNeeded()
        }
        .onTapGesture {
            guard canInlineTag, !isResolved else { return }
            tagInput = ""
            isTagging = true
        }
        .onChange(of: autoplayEnabled) { _, enabled in
            guard let player else { return }
            if enabled {
                player.play()
            } else {
                player.pause()
            }
        }
        .onDisappear {
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
                self.playbackEndObserver = nil
            }
            player?.pause()
            player = nil
            textPreview = nil
            image = nil
            mediaPreviewIssue = nil
            mediaAspectRatio = 16.0 / 9.0
        }
        .contextMenu {
            Button("Copy Filename") {
                copyToPasteboard(file.name)
            }
            Button("Copy File Path") {
                copyToPasteboard(file.path)
            }
            Button("Copy File Info") {
                copyToPasteboard("\(file.name) • \(fileMetadataLine)\n\(file.path)")
            }
            Button("Copy Media Diagnostics") {
                let url = URL(fileURLWithPath: file.path)
                Task {
                    let diagnostics = await mediaDiagnosticsString(for: url, knownDurationSeconds: file.durationSeconds)
                    await MainActor.run {
                        copyToPasteboard(diagnostics)
                    }
                }
            }
            Button("Copy Preview Transcode Log") {
                let url = URL(fileURLWithPath: file.path)
                Task {
                    let transcodeLog = await TranscodedPreviewClipStore.shared.transcodeLog(for: url)
                    await MainActor.run {
                        copyToPasteboard(transcodeLog)
                    }
                }
            }
        }
    }

    private var fileMetadataLine: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let peoplePart: String = {
            guard detectedPeopleCount > 0 else { return "" }
            return detectedPeopleCount == 1 ? " • 1 person" : " • \(detectedPeopleCount) people"
        }()
        if let durationSeconds = file.durationSeconds,
           durationSeconds > 0 {
            return "\(size) • \(formatDuration(durationSeconds))\(peoplePart)"
        }
        return "\(size)\(peoplePart)"
    }

    private func loadPreviewIfNeeded() {
        guard image == nil, player == nil, textPreview == nil else { return }
        let url = URL(fileURLWithPath: file.path)
        let ext = url.pathExtension.lowercased()
        mediaPreviewIssue = nil

        if imageExt.contains(ext) {
            image = NSImage(contentsOf: url)
            if image == nil {
                mediaPreviewIssue = "Unable to decode image preview"
            }
            if let image {
                updateAspectRatio(fromImage: image)
            }
            return
        }

        if pdfExt.contains(ext) {
            image = generatePDFPreviewImage(for: url)
            if image == nil {
                mediaPreviewIssue = "Unable to decode PDF preview"
            }
            if let image {
                updateAspectRatio(fromImage: image)
            }
            return
        }

        if !canInlineTag, textExt.contains(ext) {
            textPreview = generateTextPreview(for: url)
            if textPreview == nil {
                mediaPreviewIssue = "Unable to decode text preview"
            }
            return
        }

        if videoExt.contains(ext) || audioExt.contains(ext) {
            let isVideo = videoExt.contains(ext)
            if videoExt.contains(ext) {
                updateAspectRatio(fromVideoAt: url)
            }

            Task {
                let asset = AVURLAsset(url: url)
                let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                if !isPlayable, isVideo {
                    await MainActor.run {
                        guard player == nil, image == nil else { return }
                        mediaPreviewIssue = "Preparing short preview clip…"
                    }
                }
                let fallbackClipURL = (!isPlayable && isVideo)
                    ? await TranscodedPreviewClipStore.shared.clipURL(for: url) { status in
                        Task { @MainActor in
                            guard player == nil, image == nil else { return }
                            mediaPreviewIssue = status
                        }
                    }
                    : nil
                let fallbackThumbnail: NSImage?
                if !isPlayable, isVideo, fallbackClipURL == nil {
                    let previewStart = file.durationSeconds.map(previewSeekSecond(forDuration:)) ?? 0
                    let ffmpegThumbnail = await generateFFmpegVideoThumbnail(sourceURL: url, startSecond: previewStart) { status in
                        Task {
                            await TranscodedPreviewClipStore.shared.recordStatus(for: url, message: status)
                        }
                        Task { @MainActor in
                            guard player == nil, image == nil else { return }
                            mediaPreviewIssue = status
                        }
                    }
                    if let ffmpegThumbnail {
                        fallbackThumbnail = ffmpegThumbnail
                    } else {
                        fallbackThumbnail = await generateVideoThumbnail(for: url)
                    }
                } else {
                    fallbackThumbnail = nil
                }

                await MainActor.run {
                    guard player == nil, image == nil else { return }

                    if !isPlayable {
                        if let fallbackClipURL {
                            let avPlayer = AVPlayer(url: fallbackClipURL)
                            avPlayer.isMuted = true
                            avPlayer.actionAtItemEnd = .none
                            if let item = avPlayer.currentItem {
                                playbackEndObserver = NotificationCenter.default.addObserver(
                                    forName: .AVPlayerItemDidPlayToEndTime,
                                    object: item,
                                    queue: .main
                                ) { _ in
                                    avPlayer.seek(to: .zero)
                                    if autoplayEnabled {
                                        avPlayer.play()
                                    }
                                }
                            }
                            if autoplayEnabled {
                                avPlayer.play()
                            } else {
                                avPlayer.pause()
                            }
                            player = avPlayer
                            mediaPreviewIssue = nil
                        } else if let fallbackThumbnail {
                            image = fallbackThumbnail
                            updateAspectRatio(fromImage: fallbackThumbnail)
                            mediaPreviewIssue = nil
                        } else {
                            mediaPreviewIssue = "Preview unavailable for this media/codec (AV1 may require ffmpeg)"
                        }
                        return
                    }

                    let avPlayer = AVPlayer(url: url)
                    avPlayer.isMuted = true

                    if isVideo {
                        avPlayer.actionAtItemEnd = .none
                        if let item = avPlayer.currentItem {
                            playbackEndObserver = NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: item,
                                queue: .main
                            ) { _ in
                                avPlayer.seek(to: .zero)
                                if autoplayEnabled {
                                    avPlayer.play()
                                }
                            }
                        }
                    }

                    if autoplayEnabled {
                        avPlayer.play()
                    } else {
                        avPlayer.pause()
                    }
                    player = avPlayer
                }
            }
        }
    }

    private func updateAspectRatio(fromImage image: NSImage) {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return }
        mediaAspectRatio = max(0.35, min(2.8, width / height))
    }

    private func updateAspectRatio(fromVideoAt url: URL) {
        Task {
            let asset = AVURLAsset(url: url)

            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }

                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let natural = naturalSize.applying(transform)
                let width = abs(natural.width)
                let height = abs(natural.height)
                guard width > 0, height > 0 else { return }

                await MainActor.run {
                    mediaAspectRatio = max(0.35, min(2.8, width / height))
                }
            } catch {
                return
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var filteredSuggestions: [String] {
        let query = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return trackedPeople.filter { !currentTags.contains($0) }
        }

        return trackedPeople.filter { person in
            person.localizedCaseInsensitiveContains(query)
            && !currentTags.contains(person)
        }
    }

    private func submitInlineTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitTag(trimmed)
        isTagging = false
    }
}

struct PreviewPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackCoordinator
    let fileURL: URL?

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var textPreview: String?
    @State private var preparedPath: String = ""
    @State private var periodicObserver: Any?
    @State private var playbackEndObserver: Any?
    @State private var isHoveringOpenPrompt = false
    @State private var scanHeartbeatTick: Date = Date()
    @State private var pendingLargeBatchTag: PendingLargeBatchTag?
    @State private var mediaPreviewIssue: String?

    private let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic"]
    private let pdfExt: Set<String> = ["pdf"]
    private let textExt: Set<String> = ["txt", "md", "markdown", "json", "yaml", "yml", "csv", "tsv", "log", "xml", "html", "htm", "js", "ts", "swift", "py", "rb", "java", "c", "cpp", "h", "hpp", "ini", "toml", "conf", "cfg"]
    private let videoExt: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv"]
    private let audioExt: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"]
    private let scanHeartbeatTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private static let heartbeatFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private struct PendingLargeBatchTag: Identifiable {
        let id = UUID()
        let groupID: UUID
        let personName: String
        let paths: [String]
    }

    var body: some View {
        ZStack {
            if model.appMode == .duplicateFinder || model.appMode == .similarityFinder {
                duplicateFinderPane
            } else if let fileURL {
                content(for: fileURL)
            } else if model.isLoadingDirectory {
                loadingSessionView
            } else if model.hasClosedSessionSummary,
                      let summary = model.closedSessionSummary {
                sessionSummaryCard(
                    title: "Session Closed",
                    directoryPath: summary.directoryPath,
                    processed: summary.processed,
                    total: summary.total,
                    moved: summary.moved,
                    duplicates: summary.duplicates,
                    renamed: summary.renamed,
                    skipped: summary.skipped,
                    showStartOver: false,
                    showClearSelection: false,
                    showDismiss: true
                )
            } else if model.isSessionEmpty {
                emptySessionWarningView
            } else if model.isSessionComplete {
                completionSummaryView
            } else {
                VStack(spacing: 8) {
                    Text("Choose a folder to begin")
                        .font(.headline)
                    Text("Click to open a folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isHoveringOpenPrompt ? 0.95 : 0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(isHoveringOpenPrompt ? 0.28 : 0.12), lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.15), value: isHoveringOpenPrompt)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.chooseFolderInteractive()
                }
                .onHover { hovering in
                    if hovering, !isHoveringOpenPrompt {
                        NSCursor.pointingHand.push()
                        isHoveringOpenPrompt = true
                    } else if !hovering, isHoveringOpenPrompt {
                        NSCursor.pop()
                        isHoveringOpenPrompt = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .textSelection(.enabled)
        .overlay(alignment: .top) {
            previewToastStack
        }
        .animation(.easeOut(duration: 0.2), value: playback.overlayMessage)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.statusToastEntry?.id)
        .onDisappear {
            if isHoveringOpenPrompt {
                NSCursor.pop()
                isHoveringOpenPrompt = false
            }
            Task {
                await TranscodedPreviewClipStore.shared.clearAll()
            }
        }
        .onAppear { prepareMedia() }
        .onChange(of: fileURL?.path ?? "") { _, _ in
            prepareMedia()
        }
        .onChange(of: model.isAutoSorting) { _, _ in
            prepareMedia()
        }
        .onChange(of: model.appMode) { _, _ in
            prepareMedia()
        }
        .onChange(of: model.currentDirectory?.path ?? "") { _, _ in
            Task {
                await TranscodedPreviewClipStore.shared.clearAll()
            }
        }
        .onReceive(scanHeartbeatTimer) { timestamp in
            if model.isDuplicateScanning {
                scanHeartbeatTick = timestamp
            }
        }
        .alert(item: $pendingLargeBatchTag) { pending in
            Alert(
                title: Text("Tag \(pending.paths.count) files as \(pending.personName)?"),
                message: Text("This will apply a person tag to the entire batch."),
                primaryButton: .default(Text("Tag All")) {
                    model.tagSimilarityBatch(
                        groupID: pending.groupID,
                        rawPersonName: pending.personName,
                        paths: pending.paths
                    )
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var duplicateFinderPane: some View {
        Group {
            if model.isDuplicateScanning,
               let progress = model.duplicateScanProgress {
                duplicateScanProgressView(progress: progress)
            } else if let report = model.duplicateScanReport {
                let visibleGroups = visibleDuplicateGroups(in: report)
                let displayComplete: Bool = {
                    if model.appMode == .similarityFinder {
                        if model.showKnownPersonReviewBatches {
                            return report.resolvedGroupCount == report.groups.count
                        }
                        return visibleGroups.allSatisfy { $0.resolvedKeeperPaths != nil }
                    }
                    return report.resolvedGroupCount == report.groups.count
                }()

                if report.groups.isEmpty {
                    duplicateNoMatchesView(report: report)
                } else if displayComplete {
                    duplicateCompletionSummaryView(report: report, visibleGroups: visibleGroups)
                } else {
                    duplicateResultsView(report: report)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(model.appMode == .similarityFinder ? "People" : "Duplicate Finder")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(model.appMode == .similarityFinder ? "Start a People scan to review visual and face matches, tag files, and confirm person suggestions." : "Start a duplicate scan to review matching files side-by-side.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func duplicateNoMatchesView(report: AppModel.DuplicateScanReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.appMode == .similarityFinder ? "No People Matches Found" : "No Duplicate Matches Found")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let directoryPath = model.currentDirectory?.path {
                        Text(directoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                completionStatRow(title: "Scanned Files", value: report.scannedFileCount, icon: "doc.text.magnifyingglass")
                completionStatRow(title: "Exact Groups", value: report.exactGroupCount, icon: "checkmark.seal")
                completionStatRow(title: "Similar Groups", value: report.similarGroupCount, icon: "questionmark.circle")
            }

            HStack(spacing: 10) {
                Button("Run Scan Again") {
                    model.startDuplicateScan()
                }

                Button("Choose New Folder") {
                    model.chooseFolderInteractive()
                }

                Button("Clear Report") {
                    model.clearDuplicateScanReport()
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.12), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 28)
    }

    private func duplicateScanProgressView(progress: AppModel.DuplicateScanProgress) -> some View {
        let total = max(progress.total, 1)
        let percent = Int((progress.fractionComplete * 100).rounded())
        let etaLine = duplicateScanETALine(for: progress)
        let elapsedLine = duplicateScanElapsedLine(for: progress)
        let throughputLine = duplicateScanThroughputLine(for: progress)
        let pendingLine = duplicateScanPendingLine(for: progress)

        return VStack(spacing: 18) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text(model.appMode == .similarityFinder ? "Scanning for People" : "Scanning for Duplicates")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(progress.phase.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let current = progress.currentFileName,
                   !current.isEmpty {
                    Text(current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionComplete, total: 1)
                    .tint(.accentColor)

                HStack {
                    Text("\(progress.processed) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(percent)%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                if progress.phase == .personScoring {
                    HStack(spacing: 14) {
                        Label(
                            "People \(progress.personScoringPeopleProcessed) of \(max(progress.personScoringPeopleTotal, 1))",
                            systemImage: "person.2"
                        )
                        Label(
                            "Files \(progress.personScoringFilesProcessed) of \(max(progress.personScoringFilesTotal, 1))",
                            systemImage: "film"
                        )
                        Label("Candidates \(progress.personScoringMatchCount)", systemImage: "sparkles")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    if model.appMode == .similarityFinder {
                        Label("Faces Indexed \(progress.faceIndexedCount)", systemImage: "person.crop.circle.badge.checkmark")
                        Label("Face Pair Links \(progress.faceMatchCount)", systemImage: "person.2.fill")
                        Label("Visual Matches \(progress.visualMatchCount)", systemImage: "photo.on.rectangle.angled")
                    } else {
                        Label("Potential \(progress.potentialGroupCount)", systemImage: "sparkles")
                        Label("Exact \(progress.exactGroupCount)", systemImage: "checkmark.seal")
                        Label("Similar Files \(progress.similarGroupCount)", systemImage: "questionmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let etaLine {
                    Text(etaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label("Active heartbeat \(Self.heartbeatFormatter.string(from: scanHeartbeatTick))", systemImage: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let elapsedLine {
                    Text(elapsedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let throughputLine {
                    Text(throughputLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let pendingLine {
                    Label(pendingLine, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if progress.phase == .personScoring {
                    Text("Face pair links count pairwise face similarities, so it can be higher than indexed-face files.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor).opacity(0.95),
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.08), radius: 14, x: 0, y: 8)
    }

    private func duplicateScanETALine(for progress: AppModel.DuplicateScanProgress) -> String? {
        guard progress.processed > 0,
              progress.total > progress.processed
        else { return nil }

        let elapsed = Date().timeIntervalSince(progress.startedAt)
        guard elapsed.isFinite, elapsed > 0 else { return nil }

        let secondsPerUnit = elapsed / Double(progress.processed)
        let remainingUnits = progress.total - progress.processed
        let remainingSeconds = Int((secondsPerUnit * Double(remainingUnits)).rounded())
        guard remainingSeconds > 0 else { return nil }

        return "ETA \(formatDuration(seconds: remainingSeconds)) remaining"
    }

    private func duplicateScanElapsedLine(for progress: AppModel.DuplicateScanProgress) -> String? {
        let elapsed = Date().timeIntervalSince(progress.startedAt)
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return "Elapsed \(formatDuration(seconds: Int(elapsed.rounded())))"
    }

    private func duplicateScanThroughputLine(for progress: AppModel.DuplicateScanProgress) -> String? {
        guard progress.phase == .personScoring else { return nil }
        let elapsed = Date().timeIntervalSince(progress.startedAt)
        guard elapsed.isFinite, elapsed > 0 else { return nil }

        let filesPerSecond = Double(progress.personScoringFilesProcessed) / elapsed
        guard filesPerSecond.isFinite, filesPerSecond > 0 else { return nil }
        return String(format: "Person scoring throughput: %.1f files/sec", filesPerSecond)
    }

    private func duplicateScanPendingLine(for progress: AppModel.DuplicateScanProgress) -> String? {
        switch progress.phase {
        case .collecting:
            return "Collecting files from disk…"
        case .profiling:
            return "Profiling media metadata and signatures…"
        case .hashing:
            return "Checking exact content hashes…"
        case .comparing:
            return "Comparing similar media pairs (video-heavy folders can take longer)…"
        case .faceMatching:
            return "Running face-to-face match pass…"
        case .personScoring:
            if progress.personScoringFilesTotal > 0 {
                let filesRemaining = max(0, progress.personScoringFilesTotal - progress.personScoringFilesProcessed)
                return "Scoring likely matches per person… \(filesRemaining) file checks remaining"
            }
            return "Scoring likely matches per person…"
        case .finalizing:
            return "Finalizing groups and preparing review UI…"
        }
    }

    private func formatDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @ViewBuilder
    private func duplicateGroupCopyMenu(group: AppModel.DuplicateCandidateGroup) -> some View {
        Button("Copy Group Filenames") {
            copyToPasteboard(group.files.map(\ .name).joined(separator: "\n"))
        }

        Button("Copy Group File Paths") {
            copyToPasteboard(group.files.map(\ .path).joined(separator: "\n"))
        }

        Button("Copy Group Details") {
            let details = group.files
                .map { "\($0.name)\n\($0.path)" }
                .joined(separator: "\n\n")
            copyToPasteboard(details)
        }
    }

    private func duplicateResultsView(report: AppModel.DuplicateScanReport) -> some View {
        let visibleGroups = visibleDuplicateGroups(in: report)
        let selectedGroup = selectedDuplicateGroup(in: report, visibleGroups: visibleGroups)
        let isSimilarityMode = model.appMode == .similarityFinder
        let hiddenBatchCount = max(0, report.groups.count - visibleGroups.count)

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.appMode == .similarityFinder ? "People Batches" : "Duplicate Groups")
                    .font(.headline)

                Text(model.appMode == .similarityFinder ? "\(visibleGroups.count) visible of \(report.groups.count) batches • Visual/Face \(report.similarGroupCount) • Resolved \(report.resolvedGroupCount)" : "\(report.groups.count) groups • Exact \(report.exactGroupCount) • Similar \(report.similarGroupCount) • Resolved \(report.resolvedGroupCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isSimilarityMode {
                    Toggle("Show Known", isOn: Binding(
                        get: { model.showKnownPersonReviewBatches },
                        set: { model.setShowKnownPersonReviewBatches($0) }
                    ))
                        .toggleStyle(.switch)
                        .font(.callout)

                    if hiddenBatchCount > 0 && !model.showKnownPersonReviewBatches {
                        Text("Hiding \(hiddenBatchCount) known-only batches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleGroups) { group in
                            Button {
                                model.selectDuplicateGroup(group.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Image(systemName: model.appMode == .similarityFinder ? "person.2.circle.fill" : (group.kind == .exactHash ? "checkmark.seal.fill" : "questionmark.circle"))
                                            .foregroundStyle(model.appMode == .similarityFinder ? Color(nsColor: .systemBlue) : (group.kind == .exactHash ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)))
                                        Text(group.reason)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(group.files.count) files")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if group.resolvedKeeperPaths != nil {
                                            Text(model.appMode == .similarityFinder ? "Sorted" : "Resolved")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(group.files.map(\ .name).joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(model.selectedDuplicateGroupID == group.id ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                duplicateGroupCopyMenu(group: group)
                            }
                        }
                    }
                }
            }
            .frame(width: 320)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if visibleGroups.isEmpty, isSimilarityMode, !model.showKnownPersonReviewBatches {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All remaining batches are known matches")
                            .font(.headline)
                        Text("Turn on Show Known to review them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let selectedGroup {
                    duplicateGroupGridView(group: selectedGroup)
                } else {
                    Text("Select a duplicate group to review previews.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
    }

    private func visibleDuplicateGroups(in report: AppModel.DuplicateScanReport) -> [AppModel.DuplicateCandidateGroup] {
        guard model.appMode == .similarityFinder, !model.showKnownPersonReviewBatches else {
            return report.groups
        }

        return report.groups.filter { group in
            guard group.isPersonReview, group.personName != nil else {
                return true
            }

            let knownPaths = Set(group.knownMatchPaths ?? [])
            guard !group.files.isEmpty else { return false }
            let allKnown = group.files.allSatisfy { knownPaths.contains($0.path) }
            return !allKnown
        }
    }

    private func duplicateCompletionSummaryView(report: AppModel.DuplicateScanReport, visibleGroups: [AppModel.DuplicateCandidateGroup]) -> some View {
        let summaryGroups: [AppModel.DuplicateCandidateGroup]
        if model.appMode == .similarityFinder, !model.showKnownPersonReviewBatches {
            summaryGroups = visibleGroups
        } else {
            summaryGroups = report.groups
        }

        let removedCount = summaryGroups.reduce(into: 0) { total, group in
            let keptCount = group.resolvedKeeperPaths?.count ?? 0
            total += max(0, group.files.count - keptCount)
        }
        let keptCount = summaryGroups.reduce(into: 0) { total, group in
            total += group.resolvedKeeperPaths?.count ?? 0
        }
        let sortedFolderCount = Set(summaryGroups.compactMap(\ .resolvedDestinationFolder)).count
        let resolvedGroupCount = summaryGroups.filter { $0.resolvedKeeperPaths != nil }.count

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.appMode == .similarityFinder ? "People Review Complete" : "Duplicate Review Complete")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let directoryPath = model.currentDirectory?.path {
                        Text(directoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                completionStatRow(title: "Groups Resolved", value: resolvedGroupCount, icon: "checkmark.circle")
                completionStatRow(title: model.appMode == .similarityFinder ? "Files Sorted" : "Files Kept", value: keptCount, icon: model.appMode == .similarityFinder ? "folder.badge.person.crop" : "tray.full")
                completionStatRow(title: model.appMode == .similarityFinder ? "Person Folders" : "Files Trashed", value: model.appMode == .similarityFinder ? sortedFolderCount : removedCount, icon: model.appMode == .similarityFinder ? "person.3" : "trash")
                completionStatRow(title: "Scanned Files", value: report.scannedFileCount, icon: "doc.text.magnifyingglass")

                if model.appMode == .similarityFinder,
                   !model.showKnownPersonReviewBatches,
                   report.groups.count > summaryGroups.count {
                    Text("Known-only batches are hidden from this summary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Run Scan Again") {
                    model.startDuplicateScan()
                }

                Button("Choose New Folder") {
                    model.chooseFolderInteractive()
                }

                Button("Clear Report") {
                    model.clearDuplicateScanReport()
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.12), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 28)
    }

    private func selectedDuplicateGroup(in report: AppModel.DuplicateScanReport, visibleGroups: [AppModel.DuplicateCandidateGroup]) -> AppModel.DuplicateCandidateGroup? {
        if let selectedDuplicateGroupID = model.selectedDuplicateGroupID,
           let matched = visibleGroups.first(where: { $0.id == selectedDuplicateGroupID }) {
            return matched
        }

        return visibleGroups.first
    }

    private func duplicateGroupGridView(group: AppModel.DuplicateCandidateGroup) -> some View {
        let keeperPaths = selectedKeeperPaths(for: group)
        let selectedCount = model.selectedKeeperCount(for: group)
        let isSimilarityMode = model.appMode == .similarityFinder
        let similaritySelectedPaths = model.selectedSimilarityTrainingPaths(for: group)
        let similaritySelectedCount = model.selectedSimilarityTrainingCount(for: group)
        let selectedPersonName = model.selectedPersonName(for: group)
        let isPersonReviewBatch = isSimilarityMode && group.isPersonReview && group.personName != nil
        let knownMatchPaths = Set(group.knownMatchPaths ?? [])
        let visibleFiles = (isPersonReviewBatch && !model.showKnownPersonReviewBatches)
            ? group.files.filter { !knownMatchPaths.contains($0.path) }
            : group.files
        let hiddenKnownCount = max(0, group.files.count - visibleFiles.count)
        let visibleGroups = model.duplicateScanReport.map(visibleDuplicateGroups(in:)) ?? []
        let groupPosition = (visibleGroups.firstIndex(where: { $0.id == group.id }) ?? 0) + 1
        let groupTotal = max(visibleGroups.count, 1)
        let columns = Array(repeating: GridItem(.flexible(minimum: 180), spacing: 10), count: min(3, max(visibleFiles.count, 1)))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group \(groupPosition) of \(groupTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(group.reason)
                        .font(.headline)
                    if isPersonReviewBatch, let person = group.personName {
                        HStack(spacing: 6) {
                            Text("Reviewing possible matches for \(person)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let focusedPerson = model.focusedPersonSearchName,
                               focusedPerson.caseInsensitiveCompare(person) == .orderedSame {
                                Label("Auto-focused", systemImage: "scope")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                    )
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("Score \(Int((group.score * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Autoplay previews", isOn: Binding(
                get: { model.duplicatePreviewAutoplayEnabled },
                set: { model.setDuplicatePreviewAutoplayEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.callout)

            if isPersonReviewBatch {
                if hiddenKnownCount > 0 && !model.showKnownPersonReviewBatches {
                    Text("Hiding \(hiddenKnownCount) known matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isSimilarityMode, !isPersonReviewBatch, !model.trackedPeople.isEmpty {
                Picker("Tag As", selection: Binding(
                    get: { selectedPersonName ?? model.trackedPeople.first ?? "" },
                    set: { model.setSelectedPersonForGroup(groupID: group.id, rawName: $0) }
                )) {
                    ForEach(model.trackedPeople, id: \.self) { person in
                        Text(person).tag(person)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleFiles) { file in
                        let isSelected = isSimilarityMode ? similaritySelectedPaths.contains(file.path) : keeperPaths.contains(file.path)
                        let taggedPeople = model.taggedPeople(for: file.path)
                        let isRejectedMatch = isPersonReviewBatch ? model.isRejectedPersonMatch(groupID: group.id, path: file.path) : false
                        let similarityTitle: String? = {
                            guard group.resolvedKeeperPaths == nil else { return nil }
                            if isSimilarityMode && !isPersonReviewBatch {
                                return nil
                            }
                            if isPersonReviewBatch {
                                return isSelected ? "Selected" : "Select"
                            }
                            if let selectedPersonName {
                                return "Tag as \(selectedPersonName)"
                            }
                            return nil
                        }()

                        DuplicateCandidateCard(
                            file: file,
                            detectedPeopleCount: model.detectedPeopleCount(for: file.path),
                            isKeeper: isSelected,
                            isResolved: group.resolvedKeeperPaths != nil,
                            actionTitle: group.resolvedKeeperPaths == nil
                                ? (isSimilarityMode
                                    ? similarityTitle
                                    : (isSelected ? "Keeping" : "Keep This"))
                                : nil,
                            autoplayEnabled: model.duplicatePreviewAutoplayEnabled,
                            canInlineTag: isSimilarityMode,
                            currentTags: taggedPeople,
                            trackedPeople: model.trackedPeople,
                            showQuickReviewActions: isPersonReviewBatch,
                            isRejectedMatch: isRejectedMatch,
                            onSelectKeeper: {
                                if isSimilarityMode {
                                    if isPersonReviewBatch {
                                        model.toggleSimilarityTrainingSelection(groupID: group.id, path: file.path)
                                    } else if let selectedPersonName {
                                        model.tagSimilarityMatch(groupID: group.id, path: file.path, rawPersonName: selectedPersonName)
                                    }
                                } else {
                                    model.toggleDuplicateKeeper(groupID: group.id, keeperPath: file.path)
                                }
                            },
                            onSubmitTag: { typedName in
                                model.tagSimilarityMatch(groupID: group.id, path: file.path, rawPersonName: typedName)
                            },
                            onRemoveTag: { tag in
                                model.untagSimilarityMatch(path: file.path, personName: tag)
                            },
                            onConfirmMatch: {
                                model.confirmPersonMatch(groupID: group.id, path: file.path, isMatch: true)
                            },
                            onRejectMatch: {
                                model.confirmPersonMatch(groupID: group.id, path: file.path, isMatch: false)
                            }
                        )
                    }
                }
            }
            .id(group.id)

            HStack(spacing: 10) {
                if let resolved = group.resolvedKeeperPaths {
                    if isSimilarityMode {
                        let destination = group.resolvedDestinationFolder ?? "People Matches"
                        Text("Sorted • \(resolved.count) files → \(destination)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        let keptNames = group.files
                            .filter { resolved.contains($0.path) }
                            .map(\ .name)
                            .joined(separator: ", ")
                        Text("Resolved • kept \(resolved.count): \(keptNames)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if isSimilarityMode {
                        if !isPersonReviewBatch {
                            Button(selectedPersonName == nil ? "Tag Entire Batch" : "Tag Entire Batch as \(selectedPersonName!)") {
                                guard let selectedPersonName else { return }
                                let paths = visibleFiles.map(\ .path)
                                if paths.count >= model.largeBatchTagConfirmationThreshold {
                                    pendingLargeBatchTag = PendingLargeBatchTag(
                                        groupID: group.id,
                                        personName: selectedPersonName,
                                        paths: paths
                                    )
                                } else {
                                    model.tagSimilarityBatch(
                                        groupID: group.id,
                                        rawPersonName: selectedPersonName,
                                        paths: paths
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPersonName == nil || visibleFiles.isEmpty)

                            Button(similaritySelectedCount > 0 ? "Sort Selected (\(similaritySelectedCount)) to Person Folder" : "Sort Group into Person Folder") {
                                model.resolveSimilarityGroup(groupID: group.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if isPersonReviewBatch {
                            Button("Confirm Selected as Match") {
                                model.confirmSelectedPersonMatches(groupID: group.id, isMatch: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(similaritySelectedCount == 0)

                            Button("Mark Selected Not Person") {
                                model.confirmSelectedPersonMatches(groupID: group.id, isMatch: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(similaritySelectedCount == 0)
                        } else if let selectedPersonName {
                            Text("Tagging as: \(selectedPersonName)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Add/select a person in the sidebar to tag files.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Button("Select Matches") {
                            for file in group.files {
                                model.toggleSimilarityTrainingSelection(groupID: group.id, path: file.path)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(group.files.isEmpty)

                        Button("Clear Selection") {
                            for path in similaritySelectedPaths {
                                model.toggleSimilarityTrainingSelection(groupID: group.id, path: path)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(similaritySelectedCount == 0)

                    } else {
                        Button("Keep Selected (\(selectedCount)), Trash Others") {
                            model.resolveDuplicateGroup(groupID: group.id, keeperPaths: keeperPaths)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Spacer(minLength: 0)

                Button("Clear Report") {
                    model.clearDuplicateScanReport()
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                Label("←/→ Group", systemImage: "arrow.left.and.right")
                if group.resolvedKeeperPaths == nil {
                    if isSimilarityMode {
                        if isPersonReviewBatch {
                            Label("Select cards", systemImage: "cursorarrow.click")
                            Label("Confirm / Not Person", systemImage: "person.crop.circle.badge.questionmark")
                        } else {
                            Label("Click card = Tag", systemImage: "tag")
                        }
                    } else {
                        Label("1-9 Toggle", systemImage: "number")
                        Label("Return Apply", systemImage: "return")
                    }
                } else {
                    Label(isSimilarityMode ? "Sorted" : "Resolved", systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func selectedKeeperPaths(for group: AppModel.DuplicateCandidateGroup) -> Set<String> {
        model.selectedKeeperPaths(for: group)
    }

    private var loadingSessionView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading folder…")
                .font(.headline)
            if let currentDirectory = model.currentDirectory {
                Text(currentDirectory.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var emptySessionWarningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text("No Files Found")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Text("The selected folder has no sortable files.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Choose Another Folder") {
                    model.chooseFolderInteractive()
                }
                Button("Clear Selection") {
                    model.closeCurrentSession()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var completionSummaryView: some View {
        if let report = model.autoSortReport {
            return AnyView(autoSortCompletionSummaryView(report: report))
        }

        return AnyView(
        sessionSummaryCard(
            title: "Sorting Complete",
            directoryPath: model.currentDirectory?.path,
            processed: model.sessionProcessedCount,
            total: model.sessionTotalCount,
            moved: model.sessionMovedCount,
            duplicates: model.sessionDuplicateCount,
            renamed: model.sessionRenamedCount,
            skipped: model.sessionSkippedCount,
            showStartOver: true,
            showClearSelection: true,
            showDismiss: false
        )
        )
    }

    private func autoSortCompletionSummaryView(report: AppModel.AutoSortReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Sort Complete")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let directoryPath = model.currentDirectory?.path {
                        Text(directoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Processed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(report.processedCount) / \(max(model.sessionTotalCount, 1))")
                        .font(.callout)
                        .fontWeight(.semibold)
                }

                ProgressView(
                    value: Double(report.processedCount),
                    total: Double(max(model.sessionTotalCount, 1))
                )
                .tint(.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                completionStatRow(title: "Moved", value: report.movedCount, icon: "folder.badge.plus")
                completionStatRow(title: "Duplicates", value: report.duplicateCount, icon: "doc.on.doc")
                completionStatRow(title: "Renamed", value: report.renamedCount, icon: "pencil")
                completionStatRow(title: "Needs Review", value: report.reviewCount, icon: "exclamationmark.triangle")
                completionStatRow(title: "Failed", value: report.failedCount, icon: "xmark.octagon")
            }

            if !report.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions Taken")
                        .font(.headline)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.actionItems) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: autoSortOutcomeIcon(for: item.outcome))
                                        .foregroundStyle(autoSortOutcomeColor(for: item.outcome))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.fileName)
                                            .font(.callout)
                                            .lineLimit(1)

                                        Text(item.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 0)

                                    if item.undoActionID != nil && !item.isUndone {
                                        Button("Undo") {
                                            model.undoAutoSortItem(item.id)
                                        }
                                        .buttonStyle(.borderless)
                                    } else if item.isUndone {
                                        Text("Undone")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 90, maxHeight: 280)
                }
            }

            HStack(spacing: 10) {
                Button("Start Over") {
                    model.restartCurrentSession()
                }

                Button("Choose New Folder") {
                    model.chooseFolderInteractive()
                }

                Button("Clear Selection") {
                    model.closeCurrentSession()
                }

                Button("Clear Report") {
                    model.clearAutoSortReport()
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.12), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 28)
    }

    private func sessionSummaryCard(
        title: String,
        directoryPath: String?,
        processed: Int,
        total: Int,
        moved: Int,
        duplicates: Int,
        renamed: Int,
        skipped: Int,
        showStartOver: Bool,
        showClearSelection: Bool,
        showDismiss: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let directoryPath {
                        Text(directoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Processed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(processed) / \(total)")
                        .font(.callout)
                        .fontWeight(.semibold)
                }

                ProgressView(
                    value: Double(processed),
                    total: Double(max(total, 1))
                )
                .tint(.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                completionStatRow(title: "Moved", value: moved, icon: "folder.badge.plus")
                completionStatRow(title: "Duplicates", value: duplicates, icon: "doc.on.doc")
                completionStatRow(title: "Renamed", value: renamed, icon: "pencil")
                completionStatRow(title: "Skipped", value: skipped, icon: "arrow.uturn.right")
            }

            HStack(spacing: 10) {
                if showStartOver {
                    Button("Start Over") {
                        model.restartCurrentSession()
                    }
                }

                Button("Choose New Folder") {
                    model.chooseFolderInteractive()
                }

                if showClearSelection {
                    Button("Clear Selection") {
                        model.closeCurrentSession()
                    }
                }

                if showDismiss {
                    Button("Dismiss") {
                        model.dismissClosedSessionSummary()
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: 640, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.12), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 28)
    }

    private func completionStatRow(title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(value)")
                .font(.callout)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    @ViewBuilder
    private var previewToastStack: some View {
        VStack(spacing: 8) {
            if !playback.overlayMessage.isEmpty {
                Text(playback.overlayMessage)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                    .transition(.opacity)
            }

            if let entry = model.statusToastEntry {
                HStack(spacing: 8) {
                    Image(systemName: severityIcon(for: entry.severity))
                        .foregroundStyle(severityColor(for: entry.severity))
                    Text(entry.message)
                        .font(.callout)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(entry.id)
            }
        }
        .padding(.top, 20)
    }

    private func severityIcon(for severity: AppModel.ActivitySeverity) -> String {
        switch severity {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func severityColor(for severity: AppModel.ActivitySeverity) -> Color {
        switch severity {
        case .info:
            return .accentColor
        case .success:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemOrange)
        case .error:
            return Color(nsColor: .systemRed)
        }
    }

    private func autoSortOutcomeIcon(for outcome: AppModel.AutoSortItemOutcome) -> String {
        switch outcome {
        case .moved:
            return "folder.badge.plus"
        case .duplicate:
            return "doc.on.doc"
        case .renamed:
            return "pencil"
        case .needsReview:
            return "exclamationmark.triangle"
        case .failed:
            return "xmark.octagon"
        }
    }

    private func autoSortOutcomeColor(for outcome: AppModel.AutoSortItemOutcome) -> Color {
        switch outcome {
        case .moved, .duplicate, .renamed:
            return Color(nsColor: .systemGreen)
        case .needsReview:
            return Color(nsColor: .systemOrange)
        case .failed:
            return Color(nsColor: .systemRed)
        }
    }

    @ViewBuilder
    private func content(for fileURL: URL) -> some View {
        Group {
            if model.isAutoSorting {
                autoSortProcessingView
            } else {
                let ext = fileURL.pathExtension.lowercased()

                if (imageExt.contains(ext) || pdfExt.contains(ext)), let image {
                    if ext == "gif" {
                        AnimatedImageContainerView(image: image)
                            .padding(8)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                    }
                } else if textExt.contains(ext) {
                    if let textPreview {
                        ScrollView {
                            Text(textPreview)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(14)
                        }
                    } else {
                        Text("Loading text preview…")
                            .foregroundStyle(.secondary)
                    }
                } else if videoExt.contains(ext) || audioExt.contains(ext) {
                    if let player {
                        AVPlayerContainerView(player: player)
                            .onAppear { player.play() }
                            .padding(8)
                    } else if let mediaPreviewIssue,
                              !mediaPreviewIssue.isEmpty {
                        VStack(spacing: 8) {
                            if isPreviewTranscodeInProgress(message: mediaPreviewIssue) {
                                ProgressView()
                            }
                            Text(mediaPreviewIssue)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        Text("Loading media preview…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Preview not available for .\(ext.isEmpty ? "file" : ext)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button("Copy Media Diagnostics") {
                Task {
                    let diagnostics = await mediaDiagnosticsString(for: fileURL)
                    await MainActor.run {
                        copyToPasteboard(diagnostics)
                        model.statusMessage = "Copied media diagnostics."
                    }
                }
            }
            Button("Copy Preview Transcode Log") {
                Task {
                    let transcodeLog = await TranscodedPreviewClipStore.shared.transcodeLog(for: fileURL)
                    await MainActor.run {
                        copyToPasteboard(transcodeLog)
                        model.statusMessage = "Copied preview transcode log."
                    }
                }
            }
        }
    }

    private var autoSortProcessingView: some View {
        let processed = model.sessionProcessedCount
        let total = max(model.sessionTotalCount, 1)
        let progress = Double(processed) / Double(total)
        let percent = Int((progress * 100).rounded())

        return VStack(spacing: 18) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Auto-Sorting Files")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(model.currentDirectory?.path ?? "No source folder selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress, total: 1)
                    .tint(.accentColor)

                HStack {
                    Text("Processing \(processed) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(percent)%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor).opacity(0.95),
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.08), radius: 14, x: 0, y: 8)
    }

    private func prepareMedia() {
        persistCurrentPlaybackPosition()
        removePeriodicObserver()
        removePlaybackEndObserver()

        guard let fileURL else {
            preparedPath = ""
            image = nil
            player = nil
            textPreview = nil
            mediaPreviewIssue = nil
            playback.attach(nil)
            return
        }

        if model.isAutoSorting || model.appMode == .duplicateFinder || model.appMode == .similarityFinder {
            preparedPath = ""
            image = nil
            player = nil
            textPreview = nil
            mediaPreviewIssue = nil
            playback.attach(nil)
            return
        }

        guard fileURL.path != preparedPath || (image == nil && player == nil) else { return }
        preparedPath = fileURL.path

        image = nil
        player = nil
        textPreview = nil
        mediaPreviewIssue = nil
        playback.attach(nil)

        let ext = fileURL.pathExtension.lowercased()
        if imageExt.contains(ext) {
            image = NSImage(contentsOf: fileURL)
            if image == nil {
                mediaPreviewIssue = "Unable to decode image preview"
            }
            return
        }

        if pdfExt.contains(ext) {
            image = generatePDFPreviewImage(for: fileURL)
            if image == nil {
                mediaPreviewIssue = "Unable to decode PDF preview"
            }
            return
        }

        if textExt.contains(ext) {
            textPreview = generateTextPreview(for: fileURL)
            if textPreview == nil {
                mediaPreviewIssue = "Unable to decode text preview"
            }
            return
        }

        if videoExt.contains(ext) || audioExt.contains(ext) {
            let expectedPath = fileURL.path
            let isVideoFile = videoExt.contains(ext)
            Task {
                let asset = AVURLAsset(url: fileURL)
                let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                if !isPlayable, isVideoFile {
                    await MainActor.run {
                        guard preparedPath == expectedPath else { return }
                        mediaPreviewIssue = "Preparing short preview clip…"
                    }
                }
                let fallbackClipURL = (!isPlayable && isVideoFile)
                    ? await TranscodedPreviewClipStore.shared.clipURL(for: fileURL) { status in
                        Task { @MainActor in
                            guard preparedPath == expectedPath else { return }
                            mediaPreviewIssue = status
                        }
                    }
                    : nil
                let fallbackThumbnail: NSImage?
                if !isPlayable, isVideoFile, fallbackClipURL == nil {
                    let durationSeconds = (try? await AVURLAsset(url: fileURL).load(.duration)).map { CMTimeGetSeconds($0) }
                    let previewStart = durationSeconds.map(previewSeekSecond(forDuration:)) ?? 0
                    let ffmpegThumbnail = await generateFFmpegVideoThumbnail(sourceURL: fileURL, startSecond: previewStart) { status in
                        Task {
                            await TranscodedPreviewClipStore.shared.recordStatus(for: fileURL, message: status)
                        }
                        Task { @MainActor in
                            guard preparedPath == expectedPath else { return }
                            mediaPreviewIssue = status
                        }
                    }
                    if let ffmpegThumbnail {
                        fallbackThumbnail = ffmpegThumbnail
                    } else {
                        fallbackThumbnail = await generateVideoThumbnail(for: fileURL)
                    }
                } else {
                    fallbackThumbnail = nil
                }

                await MainActor.run {
                    guard preparedPath == expectedPath else { return }

                    if !isPlayable {
                        if let fallbackClipURL {
                            let avPlayer = AVPlayer(url: fallbackClipURL)
                            player = avPlayer
                            playback.attach(avPlayer)

                            avPlayer.actionAtItemEnd = .none
                            if let item = avPlayer.currentItem {
                                playbackEndObserver = NotificationCenter.default.addObserver(
                                    forName: .AVPlayerItemDidPlayToEndTime,
                                    object: item,
                                    queue: .main
                                ) { _ in
                                    avPlayer.seek(to: .zero)
                                    avPlayer.play()
                                }
                            }

                            avPlayer.play()
                            mediaPreviewIssue = nil
                        } else if let fallbackThumbnail {
                            image = fallbackThumbnail
                            mediaPreviewIssue = nil
                            playback.attach(nil)
                        } else {
                            mediaPreviewIssue = "Preview unavailable for this media/codec (AV1 may require ffmpeg)"
                            playback.attach(nil)
                        }
                        return
                    }

                    let avPlayer = AVPlayer(url: fileURL)
                    player = avPlayer
                    playback.attach(avPlayer)

                    if videoExt.contains(ext) {
                        avPlayer.actionAtItemEnd = .none
                        if let item = avPlayer.currentItem {
                            playbackEndObserver = NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: item,
                                queue: .main
                            ) { _ in
                                avPlayer.seek(to: .zero)
                                avPlayer.play()
                            }
                        }
                    }

                    let remembered = model.rememberedSeek(for: fileURL)
                    if remembered > 0 {
                        avPlayer.seek(to: CMTime(seconds: remembered, preferredTimescale: 600))
                    }

                    let token = avPlayer.addPeriodicTimeObserver(
                        forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                        queue: .main
                    ) { currentTime in
                        let seconds = CMTimeGetSeconds(currentTime)
                        if seconds.isFinite, seconds > 0 {
                            Task { @MainActor in
                                model.rememberSeek(seconds: seconds, for: fileURL)
                            }
                        }
                    }
                    periodicObserver = token
                    avPlayer.play()
                }
            }
        }
    }

    private func persistCurrentPlaybackPosition() {
        guard let fileURL,
              let player
        else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        if seconds.isFinite, seconds > 0 {
            model.rememberSeek(seconds: seconds, for: fileURL)
        }
    }

    private func removePeriodicObserver() {
        guard let player, let periodicObserver else { return }
        player.removeTimeObserver(periodicObserver)
        self.periodicObserver = nil
    }

    private func removePlaybackEndObserver() {
        guard let playbackEndObserver else { return }
        NotificationCenter.default.removeObserver(playbackEndObserver)
        self.playbackEndObserver = nil
    }
}
