import AppKit

enum AppBootstrap {
    @MainActor
    static func configureActivation(_ application: NSApplication) {
        // Unbundled Xcode/SwiftPM launches default to prohibited, so visible text fields cannot receive keys.
        // Accessory keeps the app out of the Dock while allowing Settings to become active.
        application.setActivationPolicy(.accessory)
    }

    static func shouldDisableAutomaticWindowTabbing(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier?.isEmpty != false
    }
}
