import Cocoa

MainActor.assumeIsolated {
    // SwiftPM runs this AppKit executable without a .app bundle, so Bundle.main has
    // no identifier. Disabling automatic tabbing before NSApplication starts prevents
    // AppKit from trying to index tabs against a missing bundle id.
    if AppBootstrap.shouldDisableAutomaticWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
