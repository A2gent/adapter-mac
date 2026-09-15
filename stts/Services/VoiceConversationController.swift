@preconcurrency import AVFoundation
import AppKit

@MainActor
final class VoiceConversationController: NSObject, AVSpeechSynthesizerDelegate {
    var onStatus: ((String, Bool) -> Void)?
    private let recognition = LocalVoiceRecognition()
    private let speaker = AVSpeechSynthesizer()
    private let service = BruteSessionService()
    private var overlay: VoiceOverlayWindow?
    private var settings = VoiceSettings()
    private var machine = VoiceCommandState(settings: VoiceSettings())
    private var timer: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var enabled = false
    private var suspended = false
    private var speaking = false
    private var currentUtterance: AVSpeechUtterance?
    private var failed = false
    private var sessionID: String?
    private var sessionBaseURL: URL?
    private var pending: [(text: String, newSession: Bool)] = []
    private var deferredReplies: [String] = []
    private var generation = UUID()

    override init() {
        super.init()
        speaker.delegate = self
        recognition.onText = { [weak self] text in
            guard let self else { return }
            self.handle(self.machine.receive(text, now: ProcessInfo.processInfo.systemUptime))
            if self.machine.listening { self.showListening() }
        }
        recognition.onSpeech = { [weak self] in
            self?.machine.speechDetected(now: ProcessInfo.processInfo.systemUptime)
        }
        recognition.onSegmentEnd = { [weak self] in self?.machine.finishSegment() }
        recognition.onError = { [weak self] error in self?.fail(error) }
    }

    func configure(_ settings: VoiceSettings) {
        self.settings = settings
        enabled = settings.enabled
        failed = false
        machine = VoiceCommandState(settings: settings)
        startup?.cancel()
        recognition.stop()
        timer?.cancel()
        speaker.stopSpeaking(at: .immediate)
        speaking = false
        currentUtterance = nil
        deferredReplies.removeAll()
        if !enabled {
            generation = UUID()
            work?.cancel()
            work = nil
            pending.removeAll()
            overlay?.orderOut(nil)
            onStatus?("Voice listening off", false)
            return
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if !self.failed && !self.recognition.decoding {
                    self.handle(self.machine.tick(now: ProcessInfo.processInfo.systemUptime))
                }
            }
        }
        resumeListening()
    }

    func shutdown() {
        var off = settings
        off.enabled = false
        configure(off)
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value {
            startup?.cancel()
            recognition.stop()
            machine.reset()
            speaker.stopSpeaking(at: .immediate)
            speaking = false
            currentUtterance = nil
            overlay?.orderOut(nil)
            if enabled { onStatus?("Voice paused for dictation/playback", false) }
        } else {
            if !deferredReplies.isEmpty { speakDeferredReply() }
            if !speaking { resumeListening() }
        }
    }

    func cancel() {
        machine.reset()
        speaker.stopSpeaking(at: .immediate)
        speaking = false
        currentUtterance = nil
        deferredReplies.removeAll()
        pending.removeAll()
        failed = false
        overlay?.orderOut(nil)
        // A submitted backend task is not cancelled by hiding the microphone HUD.
        recognition.stop()
        resumeListening()
    }

    private func window() -> VoiceOverlayWindow {
        if let overlay { return overlay }
        let window = VoiceOverlayWindow()
        window.model.onSend = { [weak self] in
            guard let self else { return }
            self.handle(self.machine.finish())
        }
        window.model.onCancel = { [weak self] in self?.cancel() }
        window.model.onNewSession = { [weak self] in self?.resetSession() }
        window.model.onOpenSession = { [weak self] in
            if let id = self?.sessionID, let url = BruteSessionService.caesarURL(sessionID: id) {
                NSWorkspace.shared.open(url)
            }
        }
        overlay = window
        return window
    }

    private func showListening() {
        let window = window()
        window.model.status = "Listening · \(Int(settings.silenceSeconds))s silence to send"
        window.model.text = machine.text
        window.model.activity = "listening"
        window.model.canSend = !machine.text.isEmpty
        window.model.canReset = work == nil
        window.orderFrontRegardless()
    }

    private func resumeListening() {
        guard enabled, !suspended, !speaking, !failed else { return }
        startup?.cancel()
        onStatus?("Loading local voice models (first use downloads ~500 MB)…", false)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recognition.start(
                    settings: self.settings,
                    deviceID: AudioInputDeviceManager().selectedInputDeviceID())
                guard !Task.isCancelled, self.enabled, !self.suspended, !self.failed else { return }
                self.onStatus?("Listening locally for \(self.settings.agentName)", true)
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func handle(_ events: [VoiceCommandEvent]) {
        for event in events {
            switch event {
            case .activated:
                NSSound(named: "Tink")?.play()
                showListening()
            case .cancelled:
                recognition.stop()
                overlay?.orderOut(nil)
                resumeListening()
                speakDeferredReply()
            case .newSession:
                resetSession()
                recognition.stop()
                resumeListening()
            case .limitReached:
                window().model.text = machine.text
                fail(
                    "Command limit reached (2 minutes / 8,000 characters). Copy the draft below or press Send explicitly."
                )
                window().model.canSend = !machine.text.isEmpty
            case .submit(let text, let newSession):
                recognition.stop()
                guard pending.count + deferredReplies.count < 3 else {
                    machine.reset()
                    window().model.text = text
                    fail("Voice queue is full. This command was not sent; copy it below.")
                    return
                }
                failed = false
                pending.append((text, newSession))
                window().model.text = text
                window().model.canSend = false
                window().model.status = "Sent / queued · say \(settings.agentName) for another command"
                window().model.activity = "idle"
                processNext()
                resumeListening()
            }
        }
    }

    private func resetSession() {
        guard work == nil, pending.isEmpty else {
            window().model.status = "Wait for the current reply before resetting the session"
            return
        }
        sessionID = nil
        sessionBaseURL = nil
        machine.reset()
        window().model.session = "New voice session · Knowledge Base"
        window().model.status = "Say \(settings.agentName) to start a new session"
        window().model.text = ""
        window().model.canSend = false
    }

    private func processNext() {
        guard work == nil, !pending.isEmpty, enabled, !failed else { return }
        let command = pending.removeFirst()
        if command.newSession {
            sessionID = nil
            sessionBaseURL = nil
        }
        let currentGeneration = generation
        window().model.canReset = false
        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard let baseURL = self.sessionBaseURL ?? WhisperService.shared.apiBaseURL() else {
                    throw SessionServiceError.message("Configure a valid Brute backend URL.")
                }
                let reply: String
                if let id = self.sessionID {
                    let state = try await self.service.voiceSnapshot(baseURL: baseURL, sessionID: id)
                    guard state.finished, state.status != "input_required" else {
                        throw SessionServiceError.message(
                            "This session is busy or requires an interactive answer. Open it in Caesar before continuing."
                        )
                    }
                    try Task.checkCancellation()
                    guard currentGeneration == self.generation else { return }
                    let response = try await self.service.voiceChat(
                        baseURL: baseURL, sessionID: id, message: command.text)
                    guard response.status != "failed" else {
                        throw SessionServiceError.message("Agent execution failed. Open the voice session in Caesar.")
                    }
                    reply = response.content
                } else {
                    let project = try await self.service.knowledgeBaseProject(baseURL: baseURL)
                    try Task.checkCancellation()
                    guard currentGeneration == self.generation else { return }
                    let created = try await self.service.create(
                        baseURL: baseURL,
                        request: SessionCreationRequest(task: command.text, projectID: project.id, images: []))
                    // Keep the ID even if monitoring fails: never blindly recreate a possibly accepted task.
                    guard currentGeneration == self.generation, !Task.isCancelled else { return }
                    self.sessionID = created.id
                    self.sessionBaseURL = baseURL
                    self.window().model.session = "Voice · \(created.id.prefix(8)) · Open in Caesar"
                    let deadline = ProcessInfo.processInfo.systemUptime + 600
                    var result: String?
                    while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        let snapshot = try await self.service.voiceSnapshot(baseURL: baseURL, sessionID: created.id)
                        if snapshot.finished {
                            guard snapshot.status != "failed" else {
                                throw SessionServiceError.message(
                                    "Agent execution failed. Open the voice session in Caesar.")
                            }
                            result = snapshot.reply
                            break
                        }
                        try await Task.sleep(for: .seconds(2))
                    }
                    guard let result else {
                        throw SessionServiceError.message(
                            "Reply monitoring stopped after 10 minutes. The task may still be running; check Caesar.")
                    }
                    reply = result
                }
                guard currentGeneration == self.generation, !Task.isCancelled else { return }
                self.work = nil
                self.window().model.session = "Voice · \(self.sessionID?.prefix(8) ?? "") · Open in Caesar"
                self.window().model.canReset = self.pending.isEmpty
                if !self.machine.listening {
                    self.window().model.status = "Agent replied · say \(self.settings.agentName) to continue"
                    self.window().model.text = reply
                    self.window().model.activity = "idle"
                }
                if self.settings.speakReplies { self.deferredReplies.append(String(reply.prefix(12_000))) }
                self.processNext()
                self.speakDeferredReply()
            } catch {
                guard currentGeneration == self.generation, !Task.isCancelled else { return }
                self.work = nil
                let unsent = self.pending.map(\.text) + (self.machine.text.isEmpty ? [] : [self.machine.text])
                self.pending.removeAll()
                self.window().model.text = ([command.text] + unsent).joined(separator: "\n\n")
                self.machine.reset()
                self.fail(
                    "\(error.localizedDescription)\nNo automatic retry. The request may already be accepted; check Caesar before sending again. Drafts are shown below."
                )
            }
        }
    }

    private func speakDeferredReply() {
        guard settings.speakReplies, enabled, !suspended, !failed, !machine.listening,
            !speaking, work == nil, !deferredReplies.isEmpty
        else { return }
        let reply = deferredReplies.removeFirst()
        let text = AudioTextNormalizer.normalizedSpeechText(from: reply)
        guard !text.isEmpty else {
            speakDeferredReply()
            return
        }
        startup?.cancel()
        recognition.stop()
        speaking = true
        onStatus?("Speaking · microphone paused", false)
        window().model.activity = "speaking"
        window().model.status = "Speaking · microphone paused"
        window().orderFrontRegardless()
        let utterance = AVSpeechUtterance(string: String(text.prefix(12_000)))
        utterance.voice = AVSpeechSynthesisVoice(language: settings.localeIdentifier)
        currentUtterance = utterance
        speaker.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.speaking, self.currentUtterance === utterance else { return }
            self.speaking = false
            self.currentUtterance = nil
            self.overlay?.orderOut(nil)
            // Let the loudspeaker tail decay before rearming the microphone.
            try? await Task.sleep(for: .milliseconds(500))
            if !self.deferredReplies.isEmpty { self.speakDeferredReply() } else { self.resumeListening() }
        }
    }

    private func fail(_ message: String) {
        failed = true
        startup?.cancel()
        recognition.stop()
        let window = window()
        if machine.listening { window.model.text = machine.text }
        machine.finishSegment()
        window.model.status = message
        window.model.activity = "idle"
        window.model.canReset = work == nil
        window.model.canSend = false
        if !suspended { window.orderFrontRegardless() }
        onStatus?("Voice paused: \(message)", false)
    }
}
