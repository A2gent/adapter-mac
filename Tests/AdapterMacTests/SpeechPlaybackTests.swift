import Foundation
import XCTest

@testable import adapter_mac

private actor DelayedSpeechResponse {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var url: URL?
    var waiting: Bool { continuation != nil }

    func wait(for request: URLRequest) async -> (Data, HTTPURLResponse) {
        url = request.url
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(
            returning: (
                Data("late audio".utf8),
                HTTPURLResponse(
                    url: url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
            ))
        continuation = nil
    }
}

@MainActor
private final class PlaybackObserver: AudioServiceDelegate {
    var prepared = 0
    var finished = 0
    var started = 0
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float]) {}
    func audioServiceDidBeginPreparingPlayback(_ service: AudioService) { prepared += 1 }
    func audioServiceDidFinishPlayback(_ service: AudioService) { finished += 1 }
    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval) { started += 1 }
}

final class SpeechPlaybackTests: XCTestCase {
    @MainActor
    func testStoppingF12PreparationFinishesUIAndSuppressesLateResponse() async {
        let suite = "SpeechPlaybackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = DelayedSpeechResponse()
        let service = BruteSpeechService { request in await gate.wait(for: request) }
        let audio = AudioService(
            textToSpeechSynthesizer: AudioTextToSpeechSynthesizer(
                speechService: service, defaults: defaults))
        let observer = PlaybackObserver()
        audio.delegate = observer
        let completion = expectation(description: "Cancelled synthesis must not call playback completion")
        completion.isInverted = true
        audio.playTextToSpeech(text: "Selected text") { _ in completion.fulfill() }
        while !(await gate.waiting) { await Task.yield() }
        XCTAssertEqual(observer.prepared, 1)
        audio.stopPlayback()
        XCTAssertEqual(observer.finished, 1)
        await gate.finish()
        await fulfillment(of: [completion], timeout: 0.2)
        XCTAssertEqual(observer.started, 0)
        XCTAssertEqual(observer.finished, 1)
    }
}
