import XCTest

@testable import adapter_mac

final class VoiceCommandTests: XCTestCase {
    private func russianWakeSettings() -> VoiceSettings {
        var settings = VoiceSettings()
        settings.agentName = "Цезарь"
        settings.newSessionPhrases = "новая сессия, начни новую сессию"
        settings.endPhrases = "приём, конец команды"
        settings.silenceSeconds = 10
        return settings
    }

    func testDefaultsAndValidation() {
        let settings = VoiceSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.speakReplies)
        XCTAssertEqual(settings.agentName, "Brute")
        XCTAssertEqual(settings.localeIdentifier, "en-US")
        XCTAssertEqual(settings.newSessionPhrases, "new session, start new session")
        XCTAssertEqual(settings.endPhrases, "over, end command")
        XCTAssertEqual(settings.newSessionPhraseList, ["new session", "start new session"])
        XCTAssertEqual(settings.endPhraseList, ["over", "end command"])
        var invalid = settings
        invalid.agentName = " , "
        XCTAssertNotNil(invalid.validationMessage)
        invalid = settings
        invalid.newSessionPhrases = " , "
        XCTAssertNotNil(invalid.validationMessage)
    }

    func testEnglishDefaultsStartAndFinishCommands() {
        var machine = VoiceCommandState(settings: VoiceSettings())
        XCTAssertEqual(
            machine.receive("Brute start new session check the tests end command", now: 0),
            [.activated, .submit("check the tests", newSession: true)])
        XCTAssertEqual(machine.receive("Brute new session over", now: 1), [.activated, .newSession])
    }

    func testWakeWordBoundaryAndSameUtteranceCommand() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
        XCTAssertEqual(machine.receive("цезарями", now: 0), [])
        XCTAssertEqual(machine.receive("Цезарь, проверь тесты", now: 1), [.activated])
        XCTAssertEqual(machine.text, "проверь тесты")
        XCTAssertEqual(
            machine.receive("Цезарь, проверь тесты, приём", now: 2), [.submit("проверь тесты", newSession: false)])
        XCTAssertEqual(machine.receive("исправь ошибки приём", now: 3), [])
    }

    func testSilenceAndEmptyWake() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
        _ = machine.receive("Цезарь", now: 0)
        XCTAssertEqual(machine.tick(now: 10), [.cancelled])
        _ = machine.receive("Цезарь проверь тесты", now: 20)
        XCTAssertEqual(machine.tick(now: 29), [])
        XCTAssertEqual(machine.tick(now: 30), [.submit("проверь тесты", newSession: false)])
    }

    func testPartialRevisionsAndRecognitionRollover() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
        _ = machine.receive("Цезарь проверь текст", now: 0)
        _ = machine.receive("Цезарь проверь тесты", now: 1)
        machine.finishSegment()
        _ = machine.receive("и исправь ошибки", now: 2)
        XCTAssertEqual(
            machine.receive("и исправь ошибки конец команды", now: 3),
            [.submit("проверь тесты и исправь ошибки", newSession: false)])
    }

    func testControlPhrasesAreConfiguredSeparatelyAndMatchWholePhrases() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
        XCTAssertEqual(
            machine.receive("Цезарь начни новую сессию проверь память конец команды", now: 0),
            [.activated, .submit("проверь память", newSession: true)])
        XCTAssertEqual(machine.receive("Цезарь новая сессия приём", now: 1), [.activated, .newSession])
        XCTAssertEqual(machine.receive("Цезарь отмена", now: 2), [.activated, .cancelled])
        _ = machine.receive("Цезарь объясни слова новая сессия приём на примере", now: 3)
        XCTAssertTrue(machine.listening)
        XCTAssertEqual(
            machine.receive("Цезарь объясни слова новая сессия приём на примере конец команды", now: 4),
            [.submit("объясни слова новая сессия приём на примере", newSession: false)])
    }

    func testLongCommandsAreNotSilentlySentAndTextIsBounded() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
        _ = machine.receive("Цезарь начало", now: 0)
        _ = machine.receive("Цезарь продолжение", now: 119)
        XCTAssertEqual(machine.tick(now: 120), [.limitReached])
        XCTAssertFalse(machine.listening)
        XCTAssertEqual(machine.text, "продолжение")
    }

    func testVADSpeechPostponesSilenceWithoutNewWords() {
        var machine = VoiceCommandState(settings: russianWakeSettings())
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
        settings.endPhrases = "приём"
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

    func testPersistedCustomAgentNameIsPreservedAcrossDefaultChange() {
        let name = "voice-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = VoiceSettings()
        settings.agentName = "Цезарь"
        settings.save(to: defaults)
        XCTAssertEqual(VoiceSettings.load(from: defaults).agentName, "Цезарь")
    }

    func testLegacySettingsKeepExistingValuesAndPreviousNewSessionPhrase() throws {
        let name = "voice-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy: [String: Any] = [
            "enabled": true,
            "agentName": "Цезарь",
            "endPhrases": "приём, конец команды",
            "silenceSeconds": 3.0,
            "silenceTimingVersion": 1,
            "speakReplies": false,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "voiceConversationSettings")

        let loaded = VoiceSettings.load(from: defaults)
        XCTAssertEqual(loaded.agentName, "Цезарь")
        XCTAssertEqual(loaded.localeIdentifier, "ru-RU")
        XCTAssertEqual(loaded.endPhrases, "приём, конец команды")
        XCTAssertEqual(loaded.newSessionPhrases, "новая сессия")
    }

    func testVoiceModelLoadStateContract() {
        XCTAssertFalse(VoiceModelLoadState.idle.isLoading)
        XCTAssertFalse(VoiceModelLoadState.idle.canRetry)
        XCTAssertNil(VoiceModelLoadState.idle.progress)
        XCTAssertEqual(VoiceModelLoadState.idle.message, "")

        let loading = VoiceModelLoadState.loading("Downloading whisper model…", 0.42)
        XCTAssertTrue(loading.isLoading)
        XCTAssertFalse(loading.canRetry)
        XCTAssertEqual(loading.progress, 0.42)
        XCTAssertEqual(loading.message, "Downloading whisper model…")

        let indeterminate = VoiceModelLoadState.loading("Preparing…", nil)
        XCTAssertTrue(indeterminate.isLoading)
        XCTAssertNil(indeterminate.progress)

        XCTAssertFalse(VoiceModelLoadState.ready.isLoading)
        XCTAssertFalse(VoiceModelLoadState.ready.canRetry)

        XCTAssertFalse(VoiceModelLoadState.cancelled.isLoading)
        XCTAssertTrue(VoiceModelLoadState.cancelled.canRetry)

        let failed = VoiceModelLoadState.failed("Network error")
        XCTAssertFalse(failed.isLoading)
        XCTAssertTrue(failed.canRetry)
        XCTAssertEqual(failed.message, "Network error")
    }
}
