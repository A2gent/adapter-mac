@preconcurrency import AVFoundation
import Foundation

/// Owns reply synthesis and playback so cancelling a delayed HTTP response cannot start stale speech.
@MainActor
final class VoiceReplySpeaker: NSObject, AVAudioPlayerDelegate {
    typealias Synthesis = @MainActor (String, URL?) async throws -> URL
    private let synthesize: Synthesis
    private let cancelSynthesis: () -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var audioURL: URL?
    private var completion: ((Result<Void, Error>) -> Void)?

    init(synthesize: Synthesis? = nil, cancelSynthesis: (() -> Void)? = nil) {
        let synthesizer = AudioTextToSpeechSynthesizer()
        self.synthesize =
            synthesize ?? { text, baseURL in
                try await synthesizer.synthesizeTextToAudio(text: text, baseURL: baseURL)
            }
        self.cancelSynthesis = cancelSynthesis ?? { _ = synthesizer.cancelFileSynthesis() }
        super.init()
    }

    @discardableResult
    func speak(text: String, baseURL: URL?, completion: @escaping (Result<Void, Error>) -> Void) -> Task<Void, Never> {
        stop()
        self.completion = completion
        let current = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.synthesize(text, baseURL)
                guard current == self.generation, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.audioURL = url
                let player = try AVAudioPlayer(contentsOf: url)
                self.player = player
                player.delegate = self
                guard player.prepareToPlay(), player.play() else {
                    throw SessionServiceError.message("Could not play the agent reply.")
                }
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.finish(.failure(error))
            }
        }
        self.task = task
        return task
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        cancelSynthesis()
        player?.stop()
        player = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        completion = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        let completion = completion
        stop()
        completion?(result)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(flag ? .success(()) : .failure(SessionServiceError.message("Agent reply playback failed.")))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(.failure(error ?? SessionServiceError.message("Agent reply audio could not be decoded.")))
        }
    }
}
