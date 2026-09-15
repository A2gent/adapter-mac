import AppKit
import XCTest

@testable import adapter_mac

final class AppBootstrapTests: XCTestCase {
    @MainActor
    func testAccessoryActivationAllowsSettingsKeyboardFocus() {
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        defer { application.setActivationPolicy(originalPolicy) }
        application.setActivationPolicy(.prohibited)
        AppBootstrap.configureActivation(application)
        XCTAssertEqual(application.activationPolicy(), .accessory)
    }

    func testShouldDisableAutomaticWindowTabbingWhenBundleIdentifierIsMissing() {
        XCTAssertTrue(AppBootstrap.shouldDisableAutomaticWindowTabbing(bundleIdentifier: nil))
    }

    func testShouldDisableAutomaticWindowTabbingWhenBundleIdentifierIsEmpty() {
        XCTAssertTrue(AppBootstrap.shouldDisableAutomaticWindowTabbing(bundleIdentifier: ""))
    }

    func testShouldKeepAutomaticWindowTabbingWhenBundleIdentifierExists() {
        XCTAssertFalse(AppBootstrap.shouldDisableAutomaticWindowTabbing(bundleIdentifier: "com.a2gent.adapter-mac"))
    }
}
