import XCTest

@testable import adapter_mac

final class VoiceCommandTests: XCTestCase {
    func testDefaultsAndValidation() {
        let settings = VoiceSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.speakReplies)
        XCTAssertEqual(settings.agentName, "Цезарь")
        var invalid = settings
        invalid.agentName = " , "
        XCTAssertNotNil(invalid.validationMessage)
    }

    func testWakeWordBoundaryAndSameUtteranceCommand() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        XCTAssertEqual(machine.receive("цезарями", now: 0), [])
        XCTAssertEqual(machine.receive("Цезарь, проверь тесты", now: 1), [.activated])
        XCTAssertEqual(machine.text, "проверь тесты")
        XCTAssertEqual(
            machine.receive("Цезарь, проверь тесты, приём", now: 2), [.submit("проверь тесты", newSession: false)])
        XCTAssertEqual(machine.receive("исправь ошибки приём", now: 3), [])
    }

    func testSilenceAndEmptyWake() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        _ = machine.receive("Цезарь", now: 0)
        XCTAssertEqual(machine.tick(now: 10), [.cancelled])
        _ = machine.receive("Цезарь проверь тесты", now: 20)
        XCTAssertEqual(machine.tick(now: 29), [])
        XCTAssertEqual(machine.tick(now: 30), [.submit("проверь тесты", newSession: false)])
    }

    func testPartialRevisionsAndRecognitionRollover() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        _ = machine.receive("Цезарь проверь текст", now: 0)
        _ = machine.receive("Цезарь проверь тесты", now: 1)
        machine.finishSegment()
        _ = machine.receive("и исправь ошибки", now: 2)
        XCTAssertEqual(
            machine.receive("и исправь ошибки конец команды", now: 3),
            [.submit("проверь тесты и исправь ошибки", newSession: false)])
    }

    func testControlPhrasesAndSuffixOnly() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        XCTAssertEqual(
            machine.receive("Цезарь новая сессия проверь память приём", now: 0),
            [.activated, .submit("проверь память", newSession: true)])
        XCTAssertEqual(machine.receive("Цезарь новая сессия приём", now: 1), [.activated, .newSession])
        XCTAssertEqual(machine.receive("Цезарь отмена", now: 2), [.activated, .cancelled])
        _ = machine.receive("Цезарь объясни слово приём на примере", now: 3)
        XCTAssertTrue(machine.listening)
    }

    func testLongCommandsAreNotSilentlySentAndTextIsBounded() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        _ = machine.receive("Цезарь начало", now: 0)
        _ = machine.receive("Цезарь продолжение", now: 119)
        XCTAssertEqual(machine.tick(now: 120), [.limitReached])
        XCTAssertFalse(machine.listening)
        XCTAssertEqual(machine.text, "продолжение")
    }

    func testVADSpeechPostponesSilenceWithoutNewWords() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        _ = machine.receive("Цезарь подумай", now: 0)
        machine.speechDetected(now: 9)
        XCTAssertEqual(machine.tick(now: 10), [])
        XCTAssertEqual(machine.tick(now: 19), [.submit("подумай", newSession: false)])
    }

    func testBoundedAudioBufferReportsOverflowAndDrains() {
        var buffer = VoiceSampleBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        XCTAssertEqual(buffer.samples, [3, 4, 5, 6])
        let result = buffer.drain()
        XCTAssertTrue(result.overflowed)
        XCTAssertEqual(result.samples.count, 4)
        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertFalse(buffer.overflowed)
    }

    func testCustomWakePhraseAndPunctuationArePreserved() {
        var settings = VoiceSettings()
        settings.agentName = "Эй Алиса"
        var machine = VoiceCommandState(settings: settings)
        XCTAssertEqual(
            machine.receive("Эй, Алиса, проверь Foo.swift, приём", now: 0),
            [.activated, .submit("проверь Foo.swift", newSession: false)])
    }

    func testSettingsPersistence() {
        let name = "voice-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = VoiceSettings()
        settings.agentName = "Алиса"
        settings.speakReplies = false
        settings.save(to: defaults)
        XCTAssertEqual(VoiceSettings.load(from: defaults), settings)
    }
}
