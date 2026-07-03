import XCTest
@testable import adapter_mac

final class AudioRecordingSupportTests: XCTestCase {
    func testShortRecordingValidationRejectsVeryShortDurationEvenWithAudioData() {
        let analysis = AudioRecordingAnalysis(
            duration: 0.18,
            fileSizeBytes: 24_000,
            averageLevel: 0.23,
            peakLevel: 0.47,
            hadAudioSamples: true,
            waveformSampleCount: 18
        )

        let result = AudioRecordingValidator.validate(analysis)

        XCTAssertEqual(result, .failure(.tooShort))
    }

    func testShortRecordingValidationRejectsSilentRecording() {
        let analysis = AudioRecordingAnalysis(
            duration: 1.4,
            fileSizeBytes: 42_000,
            averageLevel: 0.001,
            peakLevel: 0.004,
            hadAudioSamples: true,
            waveformSampleCount: 42
        )

        let result = AudioRecordingValidator.validate(analysis)

        XCTAssertEqual(result, .failure(.noSpeechDetected))
    }

    func testShortRecordingValidationAcceptsNormalSpeechRecording() {
        let analysis = AudioRecordingAnalysis(
            duration: 2.8,
            fileSizeBytes: 96_000,
            averageLevel: 0.09,
            peakLevel: 0.42,
            hadAudioSamples: true,
            waveformSampleCount: 75
        )

        let result = AudioRecordingValidator.validate(analysis)

        XCTAssertEqual(result, .success)
    }

    func testMicrophoneClassificationFlagsContinuityAndBluetoothDevices() {
        XCTAssertEqual(
            AudioInputDeviceDescriptor.classify(name: "John's iPhone Microphone"),
            .continuity
        )
        XCTAssertEqual(
            AudioInputDeviceDescriptor.classify(name: "AirPods Pro Microphone"),
            .bluetooth
        )
        XCTAssertEqual(
            AudioInputDeviceDescriptor.classify(name: "MacBook Pro Microphone"),
            .builtIn
        )
        XCTAssertEqual(
            AudioInputDeviceDescriptor.classify(name: "USB Audio Device"),
            .external
        )
    }

    func testConnectionHintExplainsFallbackForContinuityAndBluetooth() {
        XCTAssertEqual(
            AudioInputDeviceDescriptor.connectionHint(for: .continuity),
            "Continuity microphone detected. Keep the iPhone nearby, unlocked, and with Continuity Camera available."
        )
        XCTAssertEqual(
            AudioInputDeviceDescriptor.connectionHint(for: .bluetooth),
            "Bluetooth microphone detected. If audio drops out, reconnect it or switch to Built-in Microphone."
        )
    }

    func testRecordingIssueMessagesAreUserFriendly() {
        XCTAssertEqual(AudioRecordingIssue.tooShort.userMessage, "Recording was too short. Hold the shortcut a bit longer before releasing.")
        XCTAssertEqual(AudioRecordingIssue.noSpeechDetected.userMessage, "No speech was detected. Check the selected microphone connection and try again.")
        XCTAssertEqual(AudioRecordingIssue.unavailableInput.userMessage, "The selected microphone is unavailable. Reconnect it or switch to System Default.")
    }
}
