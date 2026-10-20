import Foundation
import XCTest

@testable import adapter_mac

final class VoiceReplySpeakerTests: XCTestCase {
    @MainActor
    func testStopDiscardsLateAudioAndDoesNotComplete() async throws {
        var continuation: CheckedContinuation<URL, Error>?
        let speaker = VoiceReplySpeaker(synthesize: { text, baseURL in
            XCTAssertEqual(text, "Reply")
            XCTAssertEqual(baseURL?.host, "brute.example")
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let task = speaker.speak(text: "Reply", baseURL: URL(string: "https://brute.example")) { _ in
            XCTFail("Cancelled reply must not finish or start playback")
        }
        while continuation == nil { await Task.yield() }
        speaker.stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("stale audio".utf8).write(to: url)
        continuation?.resume(returning: url)
        await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testNewReplyIgnoresPreviousSynthesisError() async {
        var first: CheckedContinuation<URL, Error>?
        let speaker = VoiceReplySpeaker(synthesize: { _, _ in
            try await withCheckedThrowingContinuation { first = $0 }
        })
        let oldTask = speaker.speak(text: "Old", baseURL: nil) { _ in
            XCTFail("Superseded reply must not complete")
        }
        while first == nil { await Task.yield() }
        let oldContinuation = first
        first = nil
        let newTask = speaker.speak(text: "New", baseURL: nil) { _ in
            XCTFail("Old failure must not finish the new reply")
        }
        while first == nil { await Task.yield() }
        oldContinuation?.resume(throwing: URLError(.cancelled))
        await oldTask.value
        speaker.stop()
        first?.resume(throwing: URLError(.cancelled))
        await newTask.value
    }

    @MainActor
    func testSynthesisFailureReachesConversation() async {
        let speaker = VoiceReplySpeaker(synthesize: { _, _ in throw URLError(.cannotConnectToHost) })
        var receivedError = false
        let task = speaker.speak(text: "Reply", baseURL: nil) { result in
            if case .failure(let error) = result {
                receivedError = (error as? URLError)?.code == .cannotConnectToHost
            }
        }
        await task.value
        XCTAssertTrue(receivedError)
    }
}
