import AppKit
import Carbon
import XCTest

@testable import adapter_mac

@MainActor
final class UnifiedSettingsWindowTests: XCTestCase {
    private func makeSettingsModel() -> SettingsModel {
        SettingsModel(
            draft: SettingsDraft(
                inputDeviceID: nil,
                adapterShortcut: ShortcutOption(keyCode: UInt32(kVK_F12), modifiers: 0),
                bruteShortcut: ShortcutOption(keyCode: UInt32(kVK_F11), modifiers: 0),
                holdToRecord: false, provider: .bruteHTTP,
                endpoint: "http://localhost:5445/speech/transcribe", ttsEngine: .automatic),
            devices: [], defaultDeviceName: "Built-in microphone", ttsAvailability: "System Voice available")
    }

    private func makeController() -> SettingsWindowController {
        SettingsWindowController(model: makeSettingsModel(), voiceModel: VoiceOverlayModel())
    }

    func testConversationAndSettingsShareSingleWindow() {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let controller = makeController()
        let window = controller.window
        controller.presentConversation()
        XCTAssertTrue(controller.window === window)
        controller.presentSettings()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.isShowingSettings)
        controller.collapseToConversation()
        XCTAssertFalse(controller.isShowingSettings)
        controller.close()
    }

    func testExpandCollapsePreservesDraft() {
        let controller = makeController()
        controller.presentConversation()
        controller.model.draft.endpoint = "https://draft.example/transcribe"
        controller.presentSettings()
        XCTAssertEqual(controller.model.draft.endpoint, "https://draft.example/transcribe")
        controller.collapseToConversation()
        XCTAssertEqual(controller.model.draft.endpoint, "https://draft.example/transcribe")
        controller.close()
    }

    func testPresentConversationDoesNotCollapseVisibleSettings() {
        let controller = makeController()
        controller.presentSettings()
        XCTAssertTrue(controller.isShowingSettings)
        controller.presentConversation()
        XCTAssertTrue(controller.isShowingSettings)
        controller.close()
    }

    func testPresentSettingsOpensExpandedVoiceSection() {
        let controller = makeController()
        controller.presentSettings(section: .voice)
        XCTAssertTrue(controller.isShowingSettings)
        XCTAssertEqual(controller.selectedSettingsSection, .voice)
        controller.close()
    }

    func testHideConversationOnlyWhenCompact() {
        let controller = makeController()
        controller.presentConversation()
        controller.hideConversationIfVisible()
        XCTAssertFalse(controller.window?.isVisible == true)
        controller.presentSettings()
        controller.hideConversationIfVisible()
        XCTAssertTrue(controller.window?.isVisible == true)
        controller.close()
    }

    func testPassivePresentDoesNotExpandSettingsOrChangeSection() {
        let controller = makeController()
        controller.presentSettings(section: .audio)
        controller.presentConversation(passive: true)
        XCTAssertTrue(controller.isShowingSettings)
        XCTAssertEqual(controller.selectedSettingsSection, .audio)
        controller.close()
    }

    func testCloseReusesWindowAndReloadsDraft() {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let controller = makeController()
        let window = controller.window
        let savedEndpoint = controller.model.draft.endpoint
        controller.onPrepareForPresentation = { controller.model.draft.endpoint = savedEndpoint }
        controller.presentConversation()
        controller.model.draft.endpoint = "https://draft.example/transcribe"
        controller.close()
        XCTAssertTrue(controller.wasClosed)
        controller.presentConversation()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.model.draft.endpoint, savedEndpoint)
        XCTAssertFalse(controller.isShowingSettings)
    }

    func testHideKeepsDraft() {
        let controller = makeController()
        controller.presentConversation()
        controller.model.draft.endpoint = "https://draft.example/transcribe"
        controller.hideConversationIfVisible()
        XCTAssertFalse(controller.window?.isVisible == true)
        controller.presentConversation()
        XCTAssertEqual(controller.model.draft.endpoint, "https://draft.example/transcribe")
        controller.close()
    }

    func testVoiceOverlayModelExposesAudioLevel() {
        let model = VoiceOverlayModel()
        XCTAssertEqual(model.audioLevel, 0)
        model.audioLevel = 0.42
        XCTAssertEqual(model.audioLevel, 0.42)
    }

    func testTrayOpensConversationAndSettingsShortcutExpands() {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        delegate.audioService = AudioService()
        delegate.shortcutMonitor = GlobalShortcutMonitor()
        delegate.voiceController = VoiceConversationController()
        delegate.openConversation()
        XCTAssertFalse(delegate.settingsController?.isShowingSettings == true)
        delegate.openSettingsExpanded()
        XCTAssertTrue(delegate.settingsController?.isShowingSettings == true)
        delegate.settingsController?.close()
    }
    func testCloseExpandedWindowReopensCompact() {
        let controller = makeController()
        controller.presentSettings(section: .voice)
        let window = controller.window
        controller.close()
        controller.presentConversation()
        XCTAssertTrue(controller.window === window)
        XCTAssertFalse(controller.isShowingSettings)
        controller.close()
    }

    func testControllerAndWindowShareLiveVoiceModel() {
        let voice = VoiceConversationController()
        let controller = SettingsWindowController(model: makeSettingsModel(), voiceModel: voice.model)
        XCTAssertTrue(controller.voiceModel === voice.model)
        voice.model.text = "Live transcript"
        voice.model.audioLevel = 0.7
        controller.presentSettings()
        controller.collapseToConversation()
        XCTAssertEqual(controller.voiceModel.text, "Live transcript")
        XCTAssertEqual(controller.voiceModel.audioLevel, 0.7)
        var hides = 0
        voice.onHide = { hides += 1 }
        voice.model.onCancel?()
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(voice.model.text, "")
        XCTAssertFalse(voice.model.canSend)
        controller.close()
    }

}
