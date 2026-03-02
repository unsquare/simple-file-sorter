import AVFoundation
import Foundation

enum PlaybackToggleResult {
    case unavailable
    case playing
    case paused
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var overlayMessage: String = ""
    private var statusObservation: NSKeyValueObservation?
    private var overlayTask: Task<Void, Never>?

    func attach(_ player: AVPlayer?) {
        statusObservation?.invalidate()
        self.player = player
        isPlaying = player?.timeControlStatus == .playing

        guard let player else { return }

        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = observed.timeControlStatus == .playing
            }
        }
    }

    func seek(by deltaSeconds: Double) {
        guard let player else { return }

        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        if !currentSeconds.isFinite { return }

        let durationSeconds = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
        var target = max(0, currentSeconds + deltaSeconds)
        if durationSeconds.isFinite && durationSeconds > 0 {
            target = min(target, max(0, durationSeconds - 0.2))
        }

        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func togglePlayPause() -> PlaybackToggleResult {
        guard let player else { return .unavailable }

        switch player.timeControlStatus {
        case .paused:
            player.play()
            showOverlay("Playing")
            return .playing
        case .playing, .waitingToPlayAtSpecifiedRate:
            player.pause()
            showOverlay("Paused")
            return .paused
        @unknown default:
            player.play()
            showOverlay("Playing")
            return .playing
        }
    }

    private func showOverlay(_ message: String) {
        overlayTask?.cancel()
        overlayMessage = message
        overlayTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self.overlayMessage = ""
        }
    }
}
