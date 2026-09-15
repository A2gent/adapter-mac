import Carbon
import XCTest

@testable import adapter_mac

final class SettingsDraftTests: XCTestCase {
    private func draft() -> SettingsDraft {
        SettingsDraft(
            inputDeviceID: nil,
            adapterShortcut: ShortcutOption(keyCode: UInt32(kVK_F12), modifiers: 0),
            bruteShortcut: ShortcutOption(keyCode: UInt32(kVK_F11), modifiers: 0),
            holdToRecord: false,
            provider: .bruteHTTP,
            endpoint: "http://localhost:5445/speech/transcribe",
            ttsEngine: .automatic
        )
    }

    func testValidSettingsCanBeSaved() {
        XCTAssertNil(draft().validationMessage)
    }

    func testConflictingShortcutsAreRejectedBeforeSaving() {
        var value = draft()
        value.bruteShortcut = value.adapterShortcut
        XCTAssertNotNil(value.validationMessage)
    }

    func testHTTPProviderRequiresAnHTTPOrHTTPSEndpoint() {
        for endpoint in ["", "localhost:5445", "file:///tmp/audio", "https://"] {
            var value = draft()
            value.endpoint = endpoint
            XCTAssertNotNil(value.validationMessage, endpoint)
        }
        var value = draft()
        value.endpoint = "  https://example.com/speech/transcribe  "
        XCTAssertNil(value.validationMessage)
    }

    func testLocalProviderDoesNotRequireBackendURL() {
        var value = draft()
        value.provider = .localWhisperCPP
        value.endpoint = ""
        XCTAssertNil(value.validationMessage)
    }
}
