import AppKit
import ScreenCaptureKit

@MainActor
struct DisplaySnapshot {
    let image: NSImage
    let displayID: CGDirectDisplayID
    let applicationName: String
}

@MainActor
struct DisplayCaptureService {
    static func currentDisplayID() -> CGDirectDisplayID {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    func capture(displayID: CGDirectDisplayID, applicationName: String) async throws -> DisplaySnapshot {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SessionServiceError.message(
                "Screen capture is not allowed. Enable A²gent in System Settings → Privacy & Security → Screen Recording, then retry. You can also send without a screenshot."
            )
        }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SessionServiceError.message("The selected display disconnected. Capture the screen again.")
        }
        // Exclude this process, not a window title: settings, recording HUD and composer
        // must never cover the game or app the user is describing.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, 2560.0 / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return DisplaySnapshot(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            displayID: displayID, applicationName: applicationName)
    }
}
