import XCTest

@testable import adapter_mac

final class VoiceStreamingTests: XCTestCase {
    private let chunk = [Float](repeating: 0.1, count: 4096)

    func testPartialBeforeOneSecondAndFinalAfterPause() {
        var stream = VoiceUtteranceStream()
        XCTAssertNil(stream.append(chunk, speech: true, speechTime: 0.256))
        XCTAssertNil(stream.append(chunk, speech: true, speechTime: 0.512))
        let partial = stream.append(chunk, speech: true, speechTime: 0.768)
        XCTAssertNotNil(partial)
        XCTAssertFalse(partial!.isFinal)
        XCTAssertTrue(stream.hasUtterance)
        XCTAssertNil(stream.append(chunk, speech: false, speechTime: 1.024))
        _ = stream.append(chunk, speech: false, speechTime: 1.280)
        let final = stream.append(chunk, speech: false, speechTime: 1.536)
        XCTAssertTrue(final!.isFinal)
        XCTAssertEqual(final!.speechTime, 0.768)
        XCTAssertFalse(stream.hasUtterance)
    }

    func testSlowDecoderCoalescesPartialsButKeepsFinalsInOrder() throws {
        var queue = VoiceDecodeQueue()
        let first = UUID()
        let second = UUID()
        try queue.enqueue(.init(id: first, samples: [1], isFinal: false, speechTime: 1))
        try queue.enqueue(.init(id: first, samples: [1, 2], isFinal: false, speechTime: 2))
        XCTAssertEqual(queue.count, 1)
        try queue.enqueue(.init(id: first, samples: [1, 2, 3], isFinal: true, speechTime: 3))
        try queue.enqueue(.init(id: second, samples: [4], isFinal: false, speechTime: 4))
        XCTAssertEqual(queue.count, 2)
        let final = try XCTUnwrap(queue.popFirst())
        XCTAssertEqual(final.id, first)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.samples, [1, 2, 3])
        XCTAssertEqual(queue.popFirst()?.id, second)
        XCTAssertNil(queue.popFirst())
    }

    func testDecoderBacklogFailsExplicitlyInsteadOfDroppingCommands() throws {
        var queue = VoiceDecodeQueue()
        for _ in 0..<4 {
            try queue.enqueue(.init(id: UUID(), samples: [1], isFinal: true, speechTime: 0))
        }
        XCTAssertThrowsError(try queue.enqueue(.init(id: UUID(), samples: [2], isFinal: true, speechTime: 1)))
        XCTAssertEqual(queue.count, 4)
    }

    func testLongUtterancesAreBoundedAndSilenceDoesNotDecode() {
        var stream = VoiceUtteranceStream()
        for _ in 0..<100 { XCTAssertNil(stream.append(chunk, speech: false, speechTime: 0)) }
        var final: VoiceDecodeRequest?
        for i in 0..<60 {
            if let request = stream.append(chunk, speech: true, speechTime: Double(i)), request.isFinal {
                final = request
            }
        }
        XCTAssertNotNil(final)
        XCTAssertLessThanOrEqual(final!.samples.count, 16_000 * 15 + 4096)
    }

    func testLateTranscriptDoesNotRestartSilenceClock() {
        var settings = VoiceSettings()
        settings.agentName = "Brute"
        var state = VoiceCommandState(settings: settings)
        _ = state.receive("Brute hello", now: 4, speechTime: 1)
        XCTAssertEqual(state.tick(now: 4), [.submit("hello", newSession: false)])
    }

    func testFastDefaultAndLegacyDefaultMigrationPreserveCustomPauses() throws {
        XCTAssertEqual(VoiceSettings().silenceSeconds, 1.5)
        var settings = VoiceSettings()
        settings.silenceSeconds = 0.5
        XCTAssertNil(settings.validationMessage)
        settings.silenceSeconds = 0.49
        XCTAssertNotNil(settings.validationMessage)
        let name = "voice-streaming-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for (old, expected) in [(10.0, 1.5), (7.0, 7.0)] {
            settings.silenceSeconds = old
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            json.removeValue(forKey: "silenceTimingVersion")
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "voiceConversationSettings")
            XCTAssertEqual(VoiceSettings.load(from: defaults).silenceSeconds, expected)
        }
        settings.silenceSeconds = 10
        settings.save(to: defaults)
        XCTAssertEqual(VoiceSettings.load(from: defaults).silenceSeconds, 10)
    }
}
