import AppKit
import SwiftUI

@MainActor
final class VoiceOverlayModel: ObservableObject {
    @Published var status = "Listening"
    @Published var text = ""
    @Published var session = "New voice session · Knowledge Base"
    @Published var activity = "listening"
    @Published var canSend = false
    @Published var canReset = true
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onOpenSession: (() -> Void)?
}

@MainActor
final class VoiceOverlayWindow: NSPanel {
    let model = VoiceOverlayModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Voice conversation"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: VoiceOverlayView(model: model))
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.minY + 30))
        }
    }
}

private struct VoiceOverlayView: View {
    @ObservedObject var model: VoiceOverlayModel
    var body: some View {
        VStack(spacing: 10) {
            VoiceSphere(activity: model.activity).frame(height: 140).accessibilityHidden(true)
            Text(model.status).font(.headline)
            Button(model.session) { model.onOpenSession?() }.buttonStyle(.plain).font(.caption)
            ScrollView { Text(model.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
            HStack {
                Button("Send") { model.onSend?() }.disabled(!model.canSend)
                Button("Cancel / Hide") { model.onCancel?() }
                Button("New session") { model.onNewSession?() }.disabled(!model.canReset)
            }.font(.caption)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
    }
}

private struct VoiceSphere: NSViewRepresentable {
    let activity: String
    func makeNSView(context: Context) -> CaesarSphereView { CaesarSphereView(frame: .zero) }
    func updateNSView(_ view: CaesarSphereView, context: Context) {
        view.setActivity(activity, level: activity == "listening" ? 0.3 : 0)
    }
}
