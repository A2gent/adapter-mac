import AppKit
import Carbon
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var draft: SettingsDraft {
        didSet {
            saved = false
            message = nil
        }
    }
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var audioLevel: Float = 0
    @Published var message: String?
    @Published var saved = false
    @Published var voiceStatus = "Voice listening off"
    let devices: [AudioInputDevice]
    let defaultDeviceName: String
    let ttsAvailability: String
    var onSave: ((SettingsDraft) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onStopPlayback: (() -> Void)?
    var onCancel: (() -> Void)?
    var onNewSession: (() -> Void)?

    init(draft: SettingsDraft, devices: [AudioInputDevice], defaultDeviceName: String, ttsAvailability: String) {
        self.draft = draft
        self.devices = devices
        self.defaultDeviceName = defaultDeviceName
        self.ttsAvailability = ttsAvailability
    }

    func save() {
        message = draft.validationMessage
        guard message == nil else { return }
        onSave?(draft)
        saved = true
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "A²gent · Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 590)
        window.setFrameAutosaveName("A2gentSettings")
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "Overview"
    case audio = "Audio & speech"
    case shortcuts = "Shortcuts"
    case voice = "Voice conversation"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .shortcuts: return "keyboard"
        case .voice: return "ear.badge.waveform"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Your voice, connected to A²gent."
        case .audio: return "Choose how your Mac listens and speaks."
        case .shortcuts: return "Your next action is just a keystroke away."
        case .voice: return "Local listening, activated by your agent’s name."
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var section = SettingsSection.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.rawValue).font(.system(size: 27, weight: .bold))
                    Text(section.subtitle).foregroundStyle(.secondary)
                }.padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch section {
                        case .general: overview
                        case .audio: audio
                        case .shortcuts: shortcuts
                        case .voice: voice
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
                footer
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.blue)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                if let logo = BrandResources.logo {
                    Image(nsImage: logo).resizable().frame(width: 38, height: 38).clipShape(
                        RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("A²gent").font(.system(size: 19, weight: .bold))
                    Text("MAC ADAPTER").font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(
                        .secondary)
                }
            }.padding(.top, 16)
            VStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(
                                section == item ? Color.blue.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .foregroundStyle(section == item ? Color.blue : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label("Runs in your menu bar", systemImage: "menubar.rectangle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Quit A²gent") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut("q")
            }
        }.padding(18).frame(width: 188).frame(maxHeight: .infinity)
            .background(.regularMaterial)
    }

    private var overview: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                SphereRepresentable(
                    activity: model.isRecording ? "listening" : model.isPlaying ? "speaking" : "idle",
                    level: model.audioLevel
                )
                .frame(height: 190).accessibilityHidden(true)
                Label(
                    model.isRecording ? "Listening" : model.isPlaying ? "Speaking" : "Ready when you are",
                    systemImage: model.isRecording
                        ? "mic.fill" : model.isPlaying ? "speaker.wave.2.fill" : "checkmark.circle.fill"
                )
                .font(.system(size: 17, weight: .semibold))
                Text("Dictate anywhere. Listen to selected text. Start an agent session.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.bottom, 8)
            Button {
                model.onNewSession?()
            } label: {
                Label("New session with screen context", systemImage: "plus.bubble")
            }.buttonStyle(.borderedProminent)
            Text(
                "F11 sends to Knowledge Base with a screenshot. Background voice conversations never capture the screen."
            )
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                summary("Dictation & read aloud", value: model.draft.adapterShortcut.title, symbol: "mic")
                summary("New Brute session", value: model.draft.bruteShortcut.title, symbol: "sparkles")
            }
            HStack {
                if model.isPlaying {
                    Button("Stop playback") { model.onStopPlayback?() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.isRecording ? "Stop recording" : "Start recording") { model.onToggleRecording?() }
                        .buttonStyle(.borderedProminent)
                }
                Text("Esc to cancel").font(.caption).foregroundStyle(.secondary)
            }
            Text("For dictation into another app, place your cursor there and use your shortcut.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func summary(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var audio: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Microphone", symbol: "mic") {
                Picker("Input device", selection: $model.draft.inputDeviceID) {
                    Text("System default (\(model.defaultDeviceName))").tag(String?.none)
                    ForEach(model.devices, id: \.id) { device in Text(device.name).tag(Optional(device.id)) }
                    if let selected = model.draft.inputDeviceID, !model.devices.contains(where: { $0.id == selected }) {
                        Text("Unavailable device (\(selected))").tag(Optional(selected))
                    }
                }
                Text("System default follows the input selected in macOS Sound settings.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            card("Transcription", symbol: "text.bubble") {
                Picker("Provider", selection: $model.draft.provider) {
                    ForEach(TranscriptionProviderOption.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                if model.draft.provider == .bruteHTTP {
                    TextField(
                        "Backend URL", text: $model.draft.endpoint,
                        prompt: Text("http://localhost:5445/speech/transcribe")
                    )
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Backend URL")
                    Text("Audio is sent to your configured Brute backend for transcription.").font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "On-device transcription. Models download on first use; no Brute server is required for dictation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            card("Text to speech", symbol: "speaker.wave.2") {
                Picker("Voice engine", selection: $model.draft.ttsEngine) {
                    ForEach(TTSEngine.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                Text(model.ttsAvailability).font(.caption).foregroundStyle(.secondary)
                Text("edge-tts sends selected text to Microsoft. Choose System Voice for local-only speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Background listening", symbol: "ear") {
                Toggle("Listen while the app is running", isOn: $model.draft.voice.enabled)
                Text(model.voiceStatus).font(.caption).foregroundStyle(.secondary)
                TextField("Agent name / wake phrase", text: $model.draft.voice.agentName)
                    .textFieldStyle(.roundedBorder)
                Picker("Recognition language", selection: $model.draft.voice.localeIdentifier) {
                    Text("Русский").tag("ru-RU")
                    Text("English (US)").tag("en-US")
                }
                Text(
                    "Say the name before every command. Uses the selected microphone and local multilingual whisper.cpp and voice activity detection. No cloud fallback or audio files. First use downloads models (~500 MB) from Hugging Face."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            card("Command and reply", symbol: "bubble.left.and.bubble.right") {
                TextField("End phrases (comma-separated)", text: $model.draft.voice.endPhrases)
                    .textFieldStyle(.roundedBorder)
                Stepper(
                    "Send after \(Int(model.draft.voice.silenceSeconds)) seconds without speech",
                    value: $model.draft.voice.silenceSeconds, in: 3...30)
                Toggle("Speak agent replies (local system voice)", isOn: $model.draft.voice.speakReplies)
                Text(
                    "The microphone pauses during replies and F11/F12 recording or playback. Each command is limited to 2 minutes. Say ‘новая сессия’ to start another conversation or ‘отмена’ to discard a command."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            card("Dedicated voice session", symbol: "bubble.left") {
                TextField("Brute transcription / backend URL", text: $model.draft.endpoint)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Recognized commands go to a separate Knowledge Base session in Brute. No automatic screenshots. The session is kept for this app launch, independent of the open Caesar tab. Open Caesar for interactive agent questions."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Dictation & read aloud", symbol: "mic") {
                ShortcutEditor(shortcut: $model.draft.adapterShortcut)
                Text("With text selected, reads it aloud. Otherwise, records and pastes your speech.").font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Toggle("Hold to record", isOn: $model.draft.holdToRecord)
                Text(
                    "Hold the shortcut while speaking, then release to transcribe. When off, tap to start and tap again to stop."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            card("Brute session", symbol: "sparkles") {
                ShortcutEditor(shortcut: $model.draft.bruteShortcut)
                Text("Record a prompt and start a new agent session. Requires your Brute backend.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label("Press Escape to cancel recording or playback.", systemImage: "escape")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06)))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if model.saved {
                    Label("Settings saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Cancel") { model.onCancel?() }.keyboardShortcut(.cancelAction)
                Button("Save changes") { model.save() }.buttonStyle(.borderedProminent).keyboardShortcut("s")
            }.padding(18)
        }
    }
}

private struct ShortcutEditor: View {
    @Binding var shortcut: ShortcutOption
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "Key",
                selection: Binding(
                    get: { shortcut.keyCode },
                    set: { shortcut = ShortcutOption(keyCode: $0, modifiers: shortcut.modifiers) })
            ) {
                ForEach(GlobalShortcutMonitor.availableShortcutKeys(), id: \.keyCode) { Text($0.title).tag($0.keyCode) }
            }.frame(maxWidth: 230)
            HStack(spacing: 12) {
                modifier("⌘", name: "Command", flag: UInt32(cmdKey))
                modifier("⌥", name: "Option", flag: UInt32(optionKey))
                modifier("⌃", name: "Control", flag: UInt32(controlKey))
                modifier("⇧", name: "Shift", flag: UInt32(shiftKey))
            }
        }
    }
    private func modifier(_ title: String, name: String, flag: UInt32) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { shortcut.modifiers & flag != 0 },
                set: { enabled in
                    shortcut = ShortcutOption(
                        keyCode: shortcut.keyCode,
                        modifiers: enabled ? shortcut.modifiers | flag : shortcut.modifiers & ~flag)
                })
        ).accessibilityLabel(name).help(name)
    }
}

private struct SphereRepresentable: NSViewRepresentable {
    let activity: String
    let level: Float
    func makeNSView(context: Context) -> CaesarSphereView { CaesarSphereView(frame: .zero) }
    func updateNSView(_ view: CaesarSphereView, context: Context) { view.setActivity(activity, level: level) }
}
