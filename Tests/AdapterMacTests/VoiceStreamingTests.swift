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

    func testShortPausesDoNotExhaustQueueSlots() throws {
        var queue = VoiceDecodeQueue()
        let ids = (0..<12).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            try queue.enqueue(.init(id: id, samples: chunk, isFinal: true, speechTime: Double(index)))
        }
        XCTAssertEqual(queue.count, ids.count)
        for id in ids { XCTAssertEqual(queue.popFirst()?.id, id) }
        XCTAssertTrue(queue.isEmpty)
    }

    func testBusyDecoderSkipsPreviewsButRetainsEveryFinalSample() throws {
        var stream = VoiceUtteranceStream()
        let speech = [Float](repeating: 0.2, count: 4096)
        let silence = [Float](repeating: 0, count: 4096)
        for i in 0..<8 {
            XCTAssertNil(stream.append(speech, speech: true, speechTime: Double(i), allowPartial: false))
        }
        for i in 0..<2 {
            XCTAssertNil(stream.append(silence, speech: false, speechTime: Double(i + 8), allowPartial: false))
        }
        let final = try XCTUnwrap(stream.append(silence, speech: false, speechTime: 10, allowPartial: false))
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(
            final.samples,
            Array(repeating: speech, count: 8).flatMap { $0 } + Array(repeating: silence, count: 3).flatMap { $0 })
        XCTAssertFalse(stream.hasUtterance)
    }

    func testSlowDecoderAcrossSixPausedSegmentsRetainsOrderedFinals() throws {
        var stream = VoiceUtteranceStream()
        var queue = VoiceDecodeQueue()
        let silence = [Float](repeating: 0, count: 4096)
        var inFlight: VoiceDecodeRequest?
        var expectedFinals: [[Float]] = []
        for segment in 0..<6 {
            let speech = [Float](repeating: Float(segment + 1), count: 4096)
            for chunkIndex in 0..<6 {
                let isSpeech = chunkIndex < 3
                let chunk = isSpeech ? speech : silence
                if let request = stream.append(
                    chunk, speech: isSpeech, speechTime: Double(segment * 6 + chunkIndex) * 0.256,
                    allowPartial: inFlight == nil && queue.isEmpty)
                {
                    try queue.enqueue(request)
                    if inFlight == nil { inFlight = queue.popFirst() }
                }
            }
            expectedFinals.append(
                Array(repeating: speech, count: 3).flatMap { $0 } + Array(repeating: silence, count: 3).flatMap { $0 })
        }
        XCTAssertEqual(inFlight?.isFinal, false)
        XCTAssertEqual(queue.count, 6)
        XCTAssertFalse(stream.hasUtterance)
        var previousID: UUID?
        for expected in expectedFinals {
            let final = try XCTUnwrap(queue.popFirst())
            XCTAssertTrue(final.isFinal)
            XCTAssertEqual(final.samples, expected)
            XCTAssertNotEqual(final.id, previousID)
            previousID = final.id
        }
        XCTAssertEqual(queue.queuedSampleCount, 0)
    }

    func testPreviewsResumeImmediatelyAfterBackpressureClears() {
        var stream = VoiceUtteranceStream()
        for i in 0..<6 {
            XCTAssertNil(stream.append(chunk, speech: true, speechTime: Double(i), allowPartial: false))
        }
        let preview = stream.append(chunk, speech: true, speechTime: 6, allowPartial: true)
        XCTAssertEqual(preview?.samples.count, 7 * chunk.count)
        XCTAssertEqual(preview?.isFinal, false)
    }

    func testQueueBoundsAudioNotSegmentCountAndRecoversCapacityOnPop() throws {
        var queue = VoiceDecodeQueue(maxSamples: 10)
        let first = UUID()
        try queue.enqueue(.init(id: first, samples: [1, 2], isFinal: false, speechTime: 1))
        try queue.enqueue(.init(id: first, samples: [1, 2, 3, 4], isFinal: true, speechTime: 2))
        try queue.enqueue(.init(id: UUID(), samples: [5, 6, 7, 8, 9, 10], isFinal: true, speechTime: 3))
        XCTAssertEqual(queue.queuedSampleCount, 10)
        XCTAssertThrowsError(try queue.enqueue(.init(id: UUID(), samples: [11], isFinal: true, speechTime: 4)))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.popFirst()?.samples, [1, 2, 3, 4])
        XCTAssertEqual(queue.queuedSampleCount, 6)
        try queue.enqueue(.init(id: UUID(), samples: [11], isFinal: true, speechTime: 4))
    }

    func testOversizedReplacementLeavesEarlierAudioIntact() throws {
        var queue = VoiceDecodeQueue(maxSamples: 4)
        let id = UUID()
        try queue.enqueue(.init(id: id, samples: [1, 2], isFinal: false, speechTime: 0))
        XCTAssertThrowsError(try queue.enqueue(.init(id: id, samples: [1, 2, 3, 4, 5], isFinal: true, speechTime: 1)))
        XCTAssertEqual(queue.queuedSampleCount, 2)
        XCTAssertEqual(queue.popFirst()?.samples, [1, 2])
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
