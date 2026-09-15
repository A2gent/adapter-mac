import AVFoundation
import XCTest

@testable import adapter_mac

final class VoiceDecoderSmokeTests: XCTestCase {
    /// Opt-in: downloads local models, then decodes a synthetic fixture, never the microphone.
    func testRussianFixtureWithRealLocalModels() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOICE_SMOKE_AUDIO"] else {
            throw XCTSkip("Set VOICE_SMOKE_AUDIO to a 16 kHz mono speech fixture for real-model verification.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard samples.count >= 4096 else {
            XCTFail("Fixture must contain at least one VAD chunk")
            return
        }
        let decoder = VoiceWhisperDecoder()
        try await decoder.prepare()
        var speechDetected = false
        for offset in stride(from: 0, through: max(0, samples.count - 4096), by: 4096) {
            let probability = try await decoder.speechProbability(Array(samples[offset..<(offset + 4096)]))
            speechDetected = speechDetected || probability >= 0.6
        }
        XCTAssertTrue(speechDetected)
        let text = try await decoder.transcribe(samples, language: "ru", vocabulary: "Цезарь. приём, конец команды")
        var settings = VoiceSettings()
        settings.agentName = "Цезарь"
        var machine = VoiceCommandState(settings: settings)
        let events = machine.receive(text, now: 0)
        XCTAssertTrue(events.contains(.activated), "Wake word absent from fixture transcript: \(text)")
        XCTAssertTrue(
            events.contains {
                if case .submit = $0 { return true }
                return false
            }, "End phrase absent: \(text)")
    }
}
