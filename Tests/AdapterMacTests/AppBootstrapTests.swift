import XCTest
@testable import adapter_mac

final class AppBootstrapTests: XCTestCase {
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
