import Foundation

enum AppBootstrap {
    static func shouldDisableAutomaticWindowTabbing(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier?.isEmpty != false
    }
}
