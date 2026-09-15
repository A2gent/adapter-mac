import AppKit
import WebKit

@MainActor
final class CaesarSphereView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var activity = "idle"
    private var level: Float = 0
    private var ready = false

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        webView.setAccessibilityHidden(true)
        addSubview(webView)
        if let url = BrandResources.url("caesar-sphere", extension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateVisibility),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(updateVisibility), name: name, object: window)
            }
        }
        syncState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // Decorative web content must not steal clicks or keyboard focus from native controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setActivity(_ activity: String, level: Float = 0) {
        self.activity = activity
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        syncState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        syncState()
    }

    @objc private func updateVisibility(_ notification: Notification) {
        syncState(closing: notification.name == NSWindow.willCloseNotification)
    }

    private func syncState(closing: Bool = false) {
        guard ready else { return }
        let mode = activity == "listening" ? 1 : activity == "speaking" ? 2 : 0
        let visible = !closing && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        webView.evaluateJavaScript(
            "window.setSphereState(\(mode), \(level), \(visible), \(reducedMotion))", completionHandler: nil)
    }
}
