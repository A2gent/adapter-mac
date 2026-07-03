import AVFoundation
import Foundation

final class AudioPlaybackController: NSObject, @unchecked Sendable {
    var onStartPlayback: ((TimeInterval) -> Void)?
    var onUpdatePlaybackPosition: ((TimeInterval, TimeInterval, Bool) -> Void)?
    var onFinishPlayback: (() -> Void)?

    private var audioPlayer: AVAudioPlayer?
    private var externalPlaybackURL: URL?
    private var playbackTimer: Timer?

    func playGeneratedAudio(url: URL) -> Bool {
        do {
            stop()
            cleanupExternalPlaybackFile()

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()

            guard player.play() else {
                return false
            }

            audioPlayer = player
            externalPlaybackURL = url
            startPlaybackTimer()
            onStartPlayback?(player.duration)
            emitPlaybackPosition(isPlaying: true)
            return true
        } catch {
            print("❌ Failed to play generated audio: \(error)")
            return false
        }
    }

    func stop() {
        let hadPlayback = audioPlayer != nil || playbackTimer != nil || externalPlaybackURL != nil
        audioPlayer?.stop()
        audioPlayer = nil
        stopPlaybackTimer()
        cleanupExternalPlaybackFile()
        if hadPlayback {
            onFinishPlayback?()
        }
    }

    func seekPlayback(by delta: TimeInterval) {
        guard let player = audioPlayer else { return }
        let duration = max(player.duration, 0)
        let nextTime = min(max(0, player.currentTime + delta), duration)
        player.currentTime = nextTime
        emitPlaybackPosition(isPlaying: player.isPlaying)
    }

    func seekPlayback(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        let duration = max(player.duration, 0)
        player.currentTime = min(max(0, time), duration)
        emitPlaybackPosition(isPlaying: player.isPlaying)
    }

    func togglePlaybackPaused() {
        guard let player = audioPlayer else { return }

        if player.isPlaying {
            player.pause()
            stopPlaybackTimer()
        } else {
            guard player.play() else { return }
            startPlaybackTimer()
        }

        emitPlaybackPosition(isPlaying: player.isPlaying)
    }

    private func cleanupExternalPlaybackFile() {
        if let url = externalPlaybackURL {
            try? FileManager.default.removeItem(at: url)
        }
        externalPlaybackURL = nil
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.emitCurrentPlaybackPosition()
        }
        if let playbackTimer {
            RunLoop.main.add(playbackTimer, forMode: .common)
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func emitCurrentPlaybackPosition() {
        guard let player = audioPlayer else { return }
        emitPlaybackPosition(isPlaying: player.isPlaying)
    }

    private func emitPlaybackPosition(isPlaying: Bool) {
        guard let player = audioPlayer else { return }
        onUpdatePlaybackPosition?(player.currentTime, player.duration, isPlaying)
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        stopPlaybackTimer()
        cleanupExternalPlaybackFile()
        onFinishPlayback?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error {
            print("❌ Audio decode error: \(error)")
        }
        audioPlayer = nil
        stopPlaybackTimer()
        cleanupExternalPlaybackFile()
        onFinishPlayback?()
    }
}
