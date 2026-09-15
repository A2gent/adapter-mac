import AppKit
import SwiftUI

@MainActor
final class VoiceOverlayModel: ObservableObject {
    @Published var status = "Voice listening off"
    @Published var text = ""
    @Published var session = "New voice session · Knowledge Base"
    @Published var activity = "idle"
    @Published var audioLevel: Float = 0
    @Published var canSend = false
    @Published var canReset = true
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onOpenSession: (() -> Void)?
}

struct VoiceOverlayView: View {
    @ObservedObject var model: VoiceOverlayModel
    var body: some View {
        VStack(spacing: 10) {
            VoiceSphereRepresentable(activity: model.activity, level: model.audioLevel)
                .frame(height: 140).accessibilityHidden(true)
            Text(model.status).font(.headline)
            Button(model.session) { model.onOpenSession?() }.buttonStyle(.plain).font(.caption)
            ScrollView { Text(model.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
            HStack {
                Button("Send") { model.onSend?() }.disabled(!model.canSend)
                Button("Cancel / Hide") { model.onCancel?() }
                Button("New session") { model.onNewSession?() }.disabled(!model.canReset)
            }.font(.caption)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceSphereRepresentable: NSViewRepresentable {
    let activity: String
    let level: Float
    func makeNSView(context: Context) -> CaesarSphereView { CaesarSphereView(frame: .zero) }
    func updateNSView(_ view: CaesarSphereView, context: Context) { view.setActivity(activity, level: level) }
}
