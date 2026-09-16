import AppKit
import Carbon
import WebKit
import XCTest

@testable import adapter_mac

@MainActor
final class SettingsWindowTests: XCTestCase {
    private func makeModel() -> SettingsModel {
        SettingsModel(
            draft: SettingsDraft(
                inputDeviceID: nil,
                adapterShortcut: ShortcutOption(keyCode: UInt32(kVK_F12), modifiers: 0),
                bruteShortcut: ShortcutOption(keyCode: UInt32(kVK_F11), modifiers: 0),
                holdToRecord: false, provider: .bruteHTTP,
                endpoint: "http://localhost:5445/speech/transcribe", ttsEngine: .automatic),
            devices: [], defaultDeviceName: "Built-in microphone", ttsAvailability: "System Voice available")
    }

    func testInvalidSaveDoesNotApplyAnySettings() {
        let model = makeModel()
        var saves = 0
        model.onSave = { _ in saves += 1 }
        model.draft.bruteShortcut = model.draft.adapterShortcut
        model.save()
        XCTAssertEqual(saves, 0)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.saved)
    }

    func testSaveAndEditFeedback() {
        let model = makeModel()
        var saved: SettingsDraft?
        model.onSave = { saved = $0 }
        model.save()
        XCTAssertEqual(saved, model.draft)
        XCTAssertTrue(model.saved)
        model.draft.holdToRecord.toggle()
        XCTAssertFalse(model.saved)
        XCTAssertNil(model.message)
    }

    func testWindowIsReusableAndNonModal() {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let controller = SettingsWindowController(model: makeModel(), voiceModel: VoiceOverlayModel())
        let window = controller.window
        controller.present()
        controller.present()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window?.isVisible == true)
        XCTAssertTrue(window?.styleMask.contains(.resizable) == true)
        XCTAssertFalse(window?.isModalPanel == true)
        XCTAssertNil(NSApp.modalWindow)
        controller.close()
        XCTAssertFalse(window?.isVisible == true)
    }

    func testMenuBarOpensAndReusesSettingsWithDraftIntact() {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        delegate.audioService = AudioService()
        delegate.shortcutMonitor = GlobalShortcutMonitor()
        delegate.voiceController = VoiceConversationController()
        delegate.openConversation()
        let controller = delegate.settingsController
        let window = controller?.window
        controller?.model.draft.endpoint = "https://unsaved.example/transcribe"
        delegate.openConversation()
        XCTAssertTrue(delegate.settingsController === controller)
        XCTAssertEqual(delegate.settingsController?.model.draft.endpoint, "https://unsaved.example/transcribe")
        controller?.close()
        delegate.openConversation()
        XCTAssertTrue(delegate.settingsController === controller)
        XCTAssertTrue(delegate.settingsController?.window === window)
        XCTAssertFalse(delegate.settingsController?.isShowingSettings == true)
        XCTAssertNotEqual(delegate.settingsController?.model.draft.endpoint, "https://unsaved.example/transcribe")
        delegate.settingsController?.close()
    }

    func testStatusItemHasDirectSettingsActionInsteadOfDropdown() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.setupMenuBar()
        defer {
            if let item = delegate.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        XCTAssertNil(delegate.statusItem?.menu)
        XCTAssertTrue(delegate.statusItem?.button?.target === delegate)
        XCTAssertEqual(delegate.statusItem?.button?.action, #selector(AppDelegate.openConversation))
        XCTAssertNotNil(delegate.statusItem?.button?.image)
    }

    func testBrandAndSphereResourcesShipWithSwiftPackage() throws {
        XCTAssertNotNil(BrandResources.logo)
        XCTAssertTrue(BrandResources.statusImage(active: false)?.isTemplate == true)
        XCTAssertTrue(BrandResources.statusImage(active: true)?.isTemplate == true)
        let html = try XCTUnwrap(BrandResources.url("caesar-sphere", extension: "html"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: html.deletingLastPathComponent().appendingPathComponent("caesar-sphere.js").path))
    }

    func testDefaultAgentNameIsBrute() {
        let model = makeModel()
        XCTAssertEqual(model.draft.voice.agentName, "Brute")
    }

    func testVoiceModelStateDefaultsAndCallbacks() {
        let model = makeModel()
        XCTAssertEqual(model.voiceModelState, .idle)
        var cancelled = false
        var retried = false
        model.onCancelVoiceLoading = { cancelled = true }
        model.onRetryVoiceLoading = { retried = true }
        model.onCancelVoiceLoading?()
        model.onRetryVoiceLoading?()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(retried)
    }

    func testVoiceFieldsStayEditableWhileModelLoads() {
        let model = makeModel()
        model.voiceModelState = .loading("Downloading models…", 0.25)
        model.draft.voice.agentName = "Custom Agent"
        model.draft.voice.newSessionPhrases = "new session, restart"
        model.draft.voice.endPhrases = "done, stop"
        XCTAssertEqual(model.draft.voice.agentName, "Custom Agent")
        XCTAssertEqual(model.draft.voice.newSessionPhrases, "new session, restart")
        XCTAssertEqual(model.draft.voice.endPhrases, "done, stop")
    }

    func testBundledSphereLoadsInWebKit() async throws {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let controller = SettingsWindowController(model: makeModel(), voiceModel: VoiceOverlayModel())
        let sphere = CaesarSphereView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        controller.window?.contentView = sphere
        controller.present()
        defer { controller.close() }
        let webView = try XCTUnwrap(sphere.subviews.first as? WKWebView)
        var loaded = false
        for _ in 0..<100 {
            if let result = try? await webView.evaluateJavaScript(
                "typeof window.setSphereState === 'function' && document.querySelector('canvas') !== null"),
                result as? Bool == true
            {
                loaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(loaded, "Bundled shaders and Three.js must load without network access")
        sphere.setActivity("listening", level: 0.7)
        let canvasWidth = try await webView.evaluateJavaScript("document.querySelector('canvas').width")
        XCTAssertGreaterThan((canvasWidth as? Int) ?? 0, 0)
    }
}
