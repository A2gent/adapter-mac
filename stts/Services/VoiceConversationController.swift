@preconcurrency import AVFoundation
import AppKit

@MainActor
final class VoiceConversationController: NSObject, AVSpeechSynthesizerDelegate {
    var onStatus: ((String, Bool) -> Void)?
    var onModelState: ((VoiceModelLoadState) -> Void)?
    private(set) var modelState: VoiceModelLoadState = .idle {
        didSet { onModelState?(modelState) }
    }
    private var configured = false
    private var deviceID: String?
    private var startupID = UUID()
    private let recognition = LocalVoiceRecognition()
    private let speaker = AVSpeechSynthesizer()
    private let service = BruteSessionService()
    let model = VoiceOverlayModel()
    var onPresent: (() -> Void)?
    var onHide: (() -> Void)?
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
    private var feedbackGeneration = UUID()

    override init() {
        super.init()
        speaker.delegate = self
        model.onSend = { [weak self] in
            guard let self, !self.recognition.decoding else { return }
            self.handle(self.machine.finish())
        }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onNewSession = { [weak self] in self?.resetSession() }
        model.onOpenSession = { [weak self] in
            if let id = self?.sessionID, let url = BruteSessionService.caesarURL(sessionID: id) {
                NSWorkspace.shared.open(url)
            }
        }
        recognition.onText = { [weak self] text, speechTime in
            guard let self else { return }
            self.handle(self.machine.receive(text, now: ProcessInfo.processInfo.systemUptime, speechTime: speechTime))
            if self.machine.listening { self.showListening() }
        }
        recognition.onAudioLevel = { [weak self] level in self?.model.audioLevel = level }
        recognition.onSpeech = { [weak self] time in
            self?.machine.speechDetected(now: time)
        }
        recognition.onSegmentEnd = { [weak self] in self?.machine.finishSegment() }
        recognition.onError = { [weak self] error in self?.fail(error) }
    }

    func configure(_ settings: VoiceSettings, deviceID: String? = nil) {
        // Saving unrelated settings must not interrupt a command or restart model preparation.
        guard !configured || self.settings != settings || self.deviceID != deviceID else { return }
        configured = true
        self.deviceID = deviceID
        self.settings = settings
        enabled = settings.enabled
        failed = false
        machine = VoiceCommandState(settings: settings)
        model.canSend = false
        stopStartup()
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
            modelState = .idle
            model.status = "Voice listening off"
            model.activity = "idle"
            onStatus?("Voice listening off", false)
            return
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if self.machine.listening {
                    self.model.canSend = !self.machine.text.isEmpty && !self.recognition.decoding
                }
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
            stopStartup()
            if modelState.isLoading { modelState = .idle }
            recognition.stop()
            machine.reset()
            speaker.stopSpeaking(at: .immediate)
            speaking = false
            currentUtterance = nil
            onHide?()
            if enabled { onStatus?("Voice paused for dictation/playback", false) }
        } else {
            if !deferredReplies.isEmpty { speakDeferredReply() }
            if !speaking { resumeListening() }
        }
    }

    func cancel() {
        feedbackGeneration = UUID()
        stopStartup()
        machine.reset()
        model.text = ""
        model.canSend = false
        model.status = enabled ? "Say \(settings.agentName) to start" : "Voice listening off"
        speaker.stopSpeaking(at: .immediate)
        speaking = false
        currentUtterance = nil
        deferredReplies.removeAll()
        pending.removeAll()
        failed = false
        onHide?()
        // A submitted backend task is not cancelled by hiding the microphone HUD.
        recognition.stop()
        resumeListening()
    }

    private func showListening() {
        model.status = "Listening · \(settings.silenceSeconds.formatted())s silence to send"
        model.text = machine.text
        model.activity = "listening"
        model.canSend = !machine.text.isEmpty && !recognition.decoding
        model.canReset = work == nil
        onPresent?()
    }

    private func stopStartup() {
        startupID = UUID()
        startup?.cancel()
        startup = nil
    }

    func cancelModelLoading() {
        guard modelState.isLoading else { return }
        stopStartup()
        recognition.stop()
        failed = true
        modelState = .cancelled
        model.status = "Voice setup cancelled"
        model.activity = "idle"
        onStatus?("Voice setup cancelled. Retry when ready.", false)
    }

    func retryModelLoading() {
        guard enabled, modelState.canRetry else { return }
        failed = false
        modelState = .idle
        resumeListening()
    }

    private func resumeListening() {
        guard enabled, !suspended, !speaking, !failed else { return }
        stopStartup()
        let id = startupID
        model.activity = "idle"
        if model.text.isEmpty { model.status = "Starting local voice listening…" }
        modelState = .loading("Checking microphone permission and cached voice models…", nil)
        onStatus?("Starting local voice listening…", false)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recognition.start(
                    settings: self.settings, deviceID: self.deviceID,
                    onProgress: { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.startupID == id, self.modelState.isLoading else { return }
                            self.modelState = state
                        }
                    })
                guard !Task.isCancelled, self.startupID == id, self.enabled, !self.suspended, !self.failed else {
                    return
                }
                self.startup = nil
                self.modelState = .ready
                if !self.machine.listening && self.work == nil && self.model.text.isEmpty {
                    self.model.status = "Say \(self.settings.agentName) to start"
                }
                self.model.activity = "listening"
                self.onStatus?("Listening locally for \(self.settings.agentName)", true)
            } catch {
                guard !Task.isCancelled, self.startupID == id else { return }
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
                onHide?()
                resumeListening()
                speakDeferredReply()
            case .newSession:
                resetSession()
            case .limitReached:
                model.text = machine.text
                fail(
                    "Command limit reached (2 minutes / 8,000 characters). Copy the draft below or press Send explicitly."
                )
                model.canSend = !machine.text.isEmpty
            case .submit(let text, let newSession):
                recognition.stop()
                guard pending.count + deferredReplies.count < 3 else {
                    machine.reset()
                    model.text = text
                    fail("Voice queue is full. This command was not sent; copy it below.")
                    return
                }
                failed = false
                pending.append((text, newSession))
                model.text = text
                model.canSend = false
                model.status = "Sent / queued · say \(settings.agentName) for another command"
                model.activity = "idle"
                processNext()
                resumeListening()
            }
        }
    }

    private func resetSession() {
        guard work == nil, pending.isEmpty else {
            model.status = "Wait for the current reply before resetting the session"
            return
        }
        recognition.stop()
        sessionID = nil
        sessionBaseURL = nil
        machine.reset()
        model.session = "New voice session · Knowledge Base"
        model.status = "Say \(settings.agentName) to start a new session"
        model.text = ""
        model.canSend = false
        resumeListening()
    }

    private func processNext() {
        guard work == nil, !pending.isEmpty, enabled, !failed else { return }
        let command = pending.removeFirst()
        if command.newSession {
            sessionID = nil
            sessionBaseURL = nil
        }
        let currentGeneration = generation
        let feedback = feedbackGeneration
        model.canReset = false
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
                    self.model.session = "Voice · \(created.id.prefix(8)) · Open in Caesar"
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
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    guard let result else {
                        throw SessionServiceError.message(
                            "Reply monitoring stopped after 10 minutes. The task may still be running; check Caesar.")
                    }
                    reply = result
                }
                guard currentGeneration == self.generation, !Task.isCancelled else { return }
                self.work = nil
                self.model.session = "Voice · \(self.sessionID?.prefix(8) ?? "") · Open in Caesar"
                self.model.canReset = self.pending.isEmpty
                if !self.machine.listening && feedback == self.feedbackGeneration {
                    self.model.status = "Agent replied · say \(self.settings.agentName) to continue"
                    self.model.text = reply
                    self.model.activity = "idle"
                }
                if self.settings.speakReplies && feedback == self.feedbackGeneration {
                    self.deferredReplies.append(String(reply.prefix(12_000)))
                }
                self.processNext()
                self.speakDeferredReply()
            } catch {
                guard currentGeneration == self.generation, !Task.isCancelled else { return }
                self.work = nil
                let unsent = self.pending.map(\.text) + (self.machine.text.isEmpty ? [] : [self.machine.text])
                self.pending.removeAll()
                self.model.text = ([command.text] + unsent).joined(separator: "\n\n")
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
        model.activity = "speaking"
        model.status = "Speaking · microphone paused"
        onPresent?()
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
            // Keep the reply visible in the conversation window.
            // Let the loudspeaker tail decay before rearming the microphone.
            try? await Task.sleep(for: .milliseconds(500))
            if !self.deferredReplies.isEmpty { self.speakDeferredReply() } else { self.resumeListening() }
        }
    }

    private func fail(_ message: String) {
        failed = true
        stopStartup()
        modelState = .failed(message)
        recognition.stop()
        if machine.listening { model.text = machine.text }
        machine.finishSegment()
        model.status = message
        model.activity = "idle"
        model.canReset = work == nil
        model.canSend = false
        if !suspended { onPresent?() }
        onStatus?("Voice paused: \(message)", false)
    }
}
