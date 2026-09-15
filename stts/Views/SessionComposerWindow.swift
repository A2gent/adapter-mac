import AppKit
import SwiftUI

@MainActor
final class SessionComposerModel: ObservableObject {
    @Published var text = ""
    @Published var projects: [SessionProject] = []
    @Published var projectID = ""
    @Published var snapshot: DisplaySnapshot?
    @Published var marks: [ScreenMark] = []
    @Published var loadingProjects = false
    @Published var capturing = false
    @Published var submitting = false
    @Published var error: String?
    @Published var captureError: String?
    @Published var created: CreatedSession?
    private let service: BruteSessionService
    let baseURL: URL
    var onRecapture: (() -> Void)?
    var onDiscard: (() -> Void)?

    init(baseURL: URL, service: BruteSessionService = BruteSessionService()) {
        self.baseURL = baseURL
        self.service = service
    }

    var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && projects.contains { $0.id == projectID }
            && !submitting && !capturing && created == nil
    }

    func loadProjects(preferKnowledgeBase: Bool = false) async {
        loadingProjects = true
        defer { loadingProjects = false }
        do {
            projects = try await service.listProjects(baseURL: baseURL)
            if preferKnowledgeBase { projectID = SessionProject.knowledgeBase(in: projects)?.id ?? "" }
            if !projects.contains(where: { $0.id == projectID }) { projectID = "" }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func submit() async {
        guard canSubmit else { return }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            let images =
                try snapshot.map { [SessionImage(pngData: try ScreenshotRenderer.png(image: $0.image, marks: marks))] }
                ?? []
            let request = try SessionCreationRequest(task: text, projectID: projectID, images: images)
            created = try await service.create(baseURL: baseURL, request: request)
        } catch {
            // Retain text, project and screenshot. Never automatically retry a POST that
            // may already have succeeded on the server before the connection was lost.
            self.error =
                "\(error.localizedDescription) Your draft is retained. Check Caesar before retrying if the connection was interrupted."
        }
    }
}

@MainActor
final class SessionComposerWindow: NSWindowController {
    let model: SessionComposerModel

    init(model: SessionComposerModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "A²gent · New session"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 660, height: 570)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionComposerView(model: model))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SessionComposerView: View {
    @ObservedObject var model: SessionComposerModel
    @State private var confirmDiscard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let logo = BrandResources.logo {
                    Image(nsImage: logo).resizable().frame(width: 42, height: 42).clipShape(
                        RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.created == nil ? "New session" : "Session created").font(
                        .system(size: 25, weight: .bold))
                    Text("Bring context from any app, window or game.").foregroundStyle(.secondary)
                }
            }
            if let session = model.created {
                Label(
                    "Your message and context were sent to the selected project.", systemImage: "checkmark.circle.fill"
                ).foregroundStyle(.green)
                Button("Open in Caesar") {
                    if let url = BruteSessionService.caesarURL(sessionID: session.id) { NSWorkspace.shared.open(url) }
                }.buttonStyle(.borderedProminent)
                Text(session.id).font(.caption).textSelection(.enabled)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Picker("Project", selection: $model.projectID) {
                                Text("Choose a project…").tag("")
                                ForEach(model.projects) { Text($0.name).tag($0.id) }
                            }
                            Button {
                                Task { await model.loadProjects() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Reload projects").disabled(model.loadingProjects)
                            if model.loadingProjects { ProgressView().controlSize(.small) }
                        }
                        Text("What would you like the agent to do?").font(.headline)
                        TextEditor(text: $model.text).font(.body).frame(minHeight: 110)
                            .padding(6).background(
                                Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                            .accessibilityLabel("Session message")
                        HStack {
                            Label("Display context", systemImage: "display").font(.headline)
                            Spacer()
                            Button("Capture again") { model.onRecapture?() }.disabled(model.capturing)
                            if model.snapshot != nil {
                                Button("Remove") {
                                    model.snapshot = nil
                                    model.marks = []
                                }
                            }
                        }
                        if model.capturing { ProgressView("Capturing display…") }
                        if let error = model.captureError {
                            Text(error).foregroundStyle(.orange).font(.callout)
                            Button("Screen Recording settings") {
                                NSWorkspace.shared.open(
                                    URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                                    )!)
                            }
                        }
                        if let snapshot = model.snapshot {
                            Text("\(snapshot.applicationName) · Display \(snapshot.displayID)").font(.caption)
                                .foregroundStyle(.secondary)
                            ScreenshotAnnotationView(image: snapshot.image, marks: $model.marks)
                        } else if !model.capturing {
                            Text("No screenshot attached. You can send a text-only session.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.padding(2)
                }.disabled(model.submitting)
                if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                Divider()
                HStack {
                    Button("Discard") { confirmDiscard = true }.disabled(model.submitting)
                    Text("Only this message and the visible attachment will be sent.").font(.caption).foregroundStyle(
                        .secondary)
                    Spacer()
                    if model.submitting { ProgressView().controlSize(.small) }
                    Button("Create session") { Task { await model.submit() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canSubmit).keyboardShortcut(
                            .return, modifiers: .command)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("Discard this draft and its screenshot?", isPresented: $confirmDiscard) {
                Button("Discard draft", role: .destructive) { model.onDiscard?() }
            }
    }
}
