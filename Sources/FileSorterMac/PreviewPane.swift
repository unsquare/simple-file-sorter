import AVKit
import SwiftUI

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

struct PreviewPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackCoordinator
    let fileURL: URL?

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var preparedPath: String = ""
    @State private var periodicObserver: Any?
    @State private var playbackEndObserver: Any?
    @State private var isHoveringOpenPrompt = false

    private let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic"]
    private let videoExt: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv"]
    private let audioExt: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"]

    var body: some View {
        ZStack {
            if let fileURL {
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
        }
        .onAppear { prepareMedia() }
        .onChange(of: fileURL?.path ?? "") { _, _ in
            prepareMedia()
        }
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

    @ViewBuilder
    private func content(for fileURL: URL) -> some View {
        let ext = fileURL.pathExtension.lowercased()

        if imageExt.contains(ext), let image {
            if ext == "gif" {
                AnimatedImageContainerView(image: image)
                    .padding(8)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
        } else if videoExt.contains(ext) || audioExt.contains(ext) {
            if let player {
                AVPlayerContainerView(player: player)
                    .onAppear { player.play() }
                    .padding(8)
            } else {
                Text("Loading media preview…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Preview not available for .\(ext.isEmpty ? "file" : ext)")
                .foregroundStyle(.secondary)
        }
    }

    private func prepareMedia() {
        persistCurrentPlaybackPosition()
        removePeriodicObserver()
        removePlaybackEndObserver()

        guard let fileURL else {
            preparedPath = ""
            image = nil
            player = nil
            playback.attach(nil)
            return
        }

        guard fileURL.path != preparedPath else { return }
        preparedPath = fileURL.path

        image = nil
        player = nil
        playback.attach(nil)

        let ext = fileURL.pathExtension.lowercased()
        if imageExt.contains(ext) {
            image = NSImage(contentsOf: fileURL)
            return
        }

        if videoExt.contains(ext) || audioExt.contains(ext) {
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
