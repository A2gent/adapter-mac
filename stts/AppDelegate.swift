import Carbon
import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private enum MenuBarVisualState {
        case idle
        case active
    }

    private enum RecordingMode {
        case pasteTranscription
        case bruteSession
    }

    private let holdToRecordGesture = HoldToRecordGesture(threshold: 0.3)

    private var voiceController: VoiceConversationController?
    private var voiceStatus = "Voice listening off"

    var statusItem: NSStatusItem?
    var settingsController: SettingsWindowController?
    private var previousApplication: NSRunningApplication?
    private var sessionComposer: SessionComposerWindow?
    private var audioRecoveryComposer: SessionComposerWindow?
    private var audioSnapshotTask: Task<DisplaySnapshot, Error>?
    private var isSessionProcessing = false
    private let sessionService = BruteSessionService()
    var shortcutMonitor: GlobalShortcutMonitor?
    var audioService: AudioService?
    var recordingWindow: RecordingWindow?
    var playbackWindow: PlaybackWindow?
    var isRecording = false
    var isPlayingTextToSpeech = false
    private var recordingMode: RecordingMode?
    private var hasShownAccessibilityClipboardNotice = false
    private var adapterMacShortcutPressStartedAt: Date?
    private let transcriptionProviderFactory: TranscriptionProvidingFactory

    init(transcriptionProviderFactory: TranscriptionProvidingFactory = TranscriptionProviderFactory()) {
        self.transcriptionProviderFactory = transcriptionProviderFactory
        super.init()
    }

    private var transcriptionProvider: TranscriptionProvider {
        transcriptionProviderFactory.makeSelectedProvider()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupServices()
        setupGlobalShortcut()
        requestPermissions()
        setupVoiceConversation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceController?.shutdown()
        shortcutMonitor?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Setup

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.imageScaling = .scaleProportionallyDown
            button.image = menuBarImage(for: .idle)
        }

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(openSettings)
            button.toolTip = "A²gent · Open settings"
            button.setAccessibilityLabel("A²gent settings")
        }
        // Keep standard keyboard commands available without a status-item dropdown.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        for item in [
            NSMenuItem(title: "New session…", action: #selector(openSessionComposer), keyEquivalent: "n"),
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","),
            NSMenuItem(title: "Quit A²gent", action: #selector(quit), keyEquivalent: "q"),
        ] {
            item.target = self
            appMenu.addItem(item)
        }
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupServices() {
        audioService = AudioService()
        audioService?.delegate = self
    }

    private func setupGlobalShortcut() {
        shortcutMonitor = GlobalShortcutMonitor()
        shortcutMonitor?.onAdapterMacShortcutPressed = { [weak self] in
            self?.handleAdapterMacShortcutPressed()
        }
        shortcutMonitor?.onAdapterMacShortcutReleased = { [weak self] in
            self?.handleAdapterMacShortcutReleased()
        }
        shortcutMonitor?.onBruteSessionShortcutPressed = { [weak self] in
            self?.handleBruteSessionShortcutPressed()
        }
        shortcutMonitor?.onCancelRequested = { [weak self] in
            self?.handleCancelRequested()
        }
        shortcutMonitor?.start()
    }

    private func requestPermissions() {
        AudioService.requestMicrophonePermission { granted in
            if !granted {
                print("⚠️ Microphone permission not granted")
            }
        }

        AccessibilityService.requestAccessibilityPermission()
    }

    // MARK: - Actions

    @objc func openSettings() {
        guard let audioService, let shortcutMonitor else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousApplication = frontmost
        }
        // Reuse the live window, preserving unsaved edits on repeated menu-bar clicks.
        if let controller = settingsController,
            controller.window?.isVisible == true || controller.window?.isMiniaturized == true
        {
            controller.present()
            return
        }
        let draft = SettingsDraft(
            inputDeviceID: audioService.selectedInputDeviceID(),
            adapterShortcut: shortcutMonitor.currentShortcut(for: .adapterMac),
            bruteShortcut: shortcutMonitor.currentShortcut(for: .bruteSession),
            holdToRecord: RecordingShortcutSettings.holdToRecordEnabled,
            provider: TranscriptionSettings.selectedProvider,
            endpoint: WhisperService.shared.apiEndpoint,
            ttsEngine: audioService.selectedTTSEngine(),
            voice: VoiceSettings.load()
        )
        let model = SettingsModel(
            draft: draft, devices: audioService.availableInputDevices(),
            defaultDeviceName: audioService.systemDefaultInputDeviceName(),
            ttsAvailability: audioService.ttsEngineAvailabilitySummary())
        model.voiceStatus = voiceStatus
        model.onSave = { [weak self] draft in
            // Validate the complete draft before changing any persisted setting.
            guard draft.validationMessage == nil else { return }
            audioService.selectInputDevice(id: draft.inputDeviceID)
            shortcutMonitor.updateShortcut(for: .adapterMac, shortcut: draft.adapterShortcut)
            shortcutMonitor.updateShortcut(for: .bruteSession, shortcut: draft.bruteShortcut)
            RecordingShortcutSettings.holdToRecordEnabled = draft.holdToRecord
            TranscriptionSettings.selectedProvider = draft.provider
            WhisperService.shared.updateAPIEndpoint(draft.endpoint)
            audioService.selectTTSEngine(draft.ttsEngine)
            draft.voice.save()
            self?.voiceController?.configure(draft.voice)
        }
        model.onToggleRecording = { [weak self] in
            guard let self else { return }
            // Return focus to the destination app so dictation never pastes into Settings.
            self.settingsController?.window?.orderOut(nil)
            self.previousApplication?.activate()
            if self.isRecording { self.stopRecording() } else { self.startRecording(mode: .pasteTranscription) }
        }
        model.onStopPlayback = { [weak self] in self?.stopPlayback() }
        model.onNewSession = { [weak self] in self?.openSessionComposer() }
        model.onCancel = { [weak self] in self?.settingsController?.close() }
        model.isRecording = isRecording
        model.isPlaying = isPlayingTextToSpeech
        settingsController = SettingsWindowController(model: model)
        settingsController?.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func quit() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - Shortcut Handler

    private func handleAdapterMacShortcutPressed() {
        guard !isSessionProcessing else { return }
        adapterMacShortcutPressStartedAt = Date()

        if RecordingShortcutSettings.holdToRecordEnabled {
            if isRecording {
                return
            }
            if isPlayingTextToSpeech {
                stopPlayback()
                return
            }
            if let selectedText = AccessibilityService.getSelectedText(),
                !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                performTextToSpeech(text: selectedText)
            } else {
                startRecording(mode: .pasteTranscription)
            }
            return
        }

        if isRecording {
            stopRecording()
        } else if isPlayingTextToSpeech {
            stopPlayback()
        } else {
            AccessibilityService.getSelectedText { [weak self] selectedText in
                DispatchQueue.main.async {
                    guard let self else { return }

                    if let selectedText, !selectedText.isEmpty {
                        self.performTextToSpeech(text: selectedText)
                    } else {
                        self.startRecording(mode: .pasteTranscription)
                    }
                }
            }
        }
    }

    private func handleAdapterMacShortcutReleased() {
        guard RecordingShortcutSettings.holdToRecordEnabled,
            isRecording,
            recordingMode == .pasteTranscription,
            let pressStartedAt = adapterMacShortcutPressStartedAt
        else {
            return
        }

        let pressDuration = Date().timeIntervalSince(pressStartedAt)
        adapterMacShortcutPressStartedAt = nil

        guard holdToRecordGesture.shouldStopRecordingOnKeyUp(pressDuration: pressDuration) else {
            return
        }

        stopRecording()
    }

    private func handleBruteSessionShortcutPressed() {
        guard !isSessionProcessing else { return }
        if isRecording {
            stopRecording()
            return
        }
        if let recovery = audioRecoveryComposer, recovery.model.created == nil {
            recovery.present()
            return
        }
        if isPlayingTextToSpeech {
            stopPlayback()
        }
        startRecording(mode: .bruteSession)
    }

    private func handleCancelRequested() {
        adapterMacShortcutPressStartedAt = nil
        voiceController?.cancel()

        if isRecording {
            cancelRecording()
            return
        }

        if isPlayingTextToSpeech {
            stopPlayback()
        }
    }

    private func startRecording(mode: RecordingMode) {
        guard !isRecording, !isSessionProcessing else { return }
        recordingMode = mode
        if mode == .bruteSession {
            let displayID = DisplayCaptureService.currentDisplayID()
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Current display"
            audioSnapshotTask = Task {
                try await DisplayCaptureService().capture(displayID: displayID, applicationName: appName)
            }
        }

        isRecording = true
        updateMenuState()

        let window = RecordingWindow(
            deviceName: audioService?.activeInputDeviceName() ?? "No microphone",
            titleText: mode == .bruteSession ? "BRUTE" : "REC",
            hintText: mode == .bruteSession ? "Knowledge Base + screen · Esc cancel" : "Esc cancel, shortcut paste text"
        )
        self.recordingWindow = window
        window.show()

        audioService?.startRecording { [weak self] result in
            guard let self = self else { return }
            if case .failure(let issue) = result {
                self.isRecording = false
                self.recordingMode = nil
                self.audioSnapshotTask?.cancel()
                self.audioSnapshotTask = nil
                self.adapterMacShortcutPressStartedAt = nil
                self.closeRecordingWindow()
                self.updateMenuState()
                self.showError(issue.userMessage)
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        let completedMode = recordingMode
        if completedMode == .bruteSession { isSessionProcessing = true }
        updateMenuState()
        recordingMode = nil
        adapterMacShortcutPressStartedAt = nil

        // Keep the HUD visible after the user presses the shortcut again. Long
        // recordings can spend noticeable time finalizing and transcribing, so
        // closing the window here makes the operation look lost.
        recordingWindow?.updateRecordingState(.finishing)

        audioService?.stopRecording { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let outcome):
                switch completedMode {
                case .bruteSession:
                    self.recordingWindow?.updateRecordingState(.startingBruteSession)
                    self.performSpeechToBruteSession(audioURL: outcome.fileURL)
                case .pasteTranscription, .none:
                    self.recordingWindow?.updateRecordingState(.transcribing)
                    self.performSpeechToText(audioURL: outcome.fileURL)
                }
            case .failure(let issue):
                self.isSessionProcessing = false
                self.audioSnapshotTask?.cancel()
                self.audioSnapshotTask = nil
                self.updateMenuState()
                self.closeRecordingWindow()
                self.showError(issue.userMessage)
            }
        }
    }

    private func closeRecordingWindow() {
        recordingWindow?.close()
        recordingWindow = nil
    }

    private func cancelRecording() {
        guard isRecording else { return }

        isRecording = false
        audioSnapshotTask?.cancel()
        audioSnapshotTask = nil
        recordingMode = nil
        adapterMacShortcutPressStartedAt = nil
        updateMenuState()
        closeRecordingWindow()
        audioService?.cancelRecording()
    }

    private func stopPlayback() {
        audioService?.stopPlayback()
    }

    private func performTextToSpeech(text: String) {
        let window = PlaybackWindow()
        window.onStop = { [weak self] in self?.stopPlayback() }
        window.onTogglePause = { [weak self] in self?.audioService?.togglePlaybackPaused() }
        window.onSeekBackward = { [weak self] in self?.audioService?.seekPlayback(by: -15) }
        window.onSeekForward = { [weak self] in self?.audioService?.seekPlayback(by: 15) }
        window.onSeekToTime = { [weak self] time in self?.audioService?.seekPlayback(to: time) }
        window.setPreparing()
        window.show()
        playbackWindow?.close()
        playbackWindow = window
        isPlayingTextToSpeech = true
        updateMenuState()

        audioService?.playTextToSpeech(text: text) { [weak self] success in
            if !success {
                self?.isPlayingTextToSpeech = false
                self?.playbackWindow?.close()
                self?.playbackWindow = nil
                self?.updateMenuState()
                self?.showError("Failed to play audio")
            }
        }
    }

    func requestTranscription(for audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        transcriptionProvider.transcribe(audioURL: audioURL, completion: completion)
    }

    private func performSpeechToText(audioURL: URL) {
        statusItem?.button?.image = menuBarImage(for: .active)

        requestTranscription(for: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                self?.statusItem?.button?.image = self?.menuBarImage(for: .idle)
                self?.closeRecordingWindow()

                switch result {
                case .success(let text):
                    switch AccessibilityService.pasteText(text) {
                    case .pasted:
                        break
                    case .copiedToClipboard(let reason):
                        AccessibilityService.requestAccessibilityPermission()
                        print("⚠️ Transcription copied to clipboard instead of pasted: \(reason)")
                        if self?.hasShownAccessibilityClipboardNotice == false {
                            self?.hasShownAccessibilityClipboardNotice = true
                            self?.showError(
                                "Transcription was copied to the clipboard because automatic paste is unavailable for this running build. You can still paste manually with Cmd+V."
                            )
                        }
                    }
                case .failure(let error):
                    self?.showError("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func performSpeechToBruteSession(audioURL: URL) {
        statusItem?.button?.image = menuBarImage(for: .active)
        let capture = audioSnapshotTask
        audioSnapshotTask = nil
        requestTranscription(for: audioURL) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isSessionProcessing = false
                    self.closeRecordingWindow()
                    self.updateMenuState()
                }
                let prompt: String
                switch result {
                case .success(let text): prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let error):
                    capture?.cancel()
                    self.showError(
                        "Transcription failed: \(error.localizedDescription). Audio remains at \(audioURL.path).")
                    return
                }
                guard !prompt.isEmpty else {
                    capture?.cancel()
                    self.showError("No speech was transcribed. No session was created.")
                    return
                }
                var snapshot: DisplaySnapshot?
                var captureError: String?
                do { snapshot = try await capture?.value } catch { captureError = error.localizedDescription }
                guard let baseURL = WhisperService.shared.apiBaseURL() else {
                    self.showError("Invalid Brute URL. Transcript: \(prompt)")
                    return
                }
                do {
                    let project = try await self.sessionService.knowledgeBaseProject(baseURL: baseURL)
                    let images =
                        try snapshot.map {
                            [SessionImage(pngData: try ScreenshotRenderer.png(image: $0.image, marks: []))]
                        } ?? []
                    let request = try SessionCreationRequest(task: prompt, projectID: project.id, images: images)
                    let session = try await self.sessionService.create(baseURL: baseURL, request: request)
                    if let url = BruteSessionService.caesarURL(sessionID: session.id) { NSWorkspace.shared.open(url) }
                    if let captureError {
                        self.showError(
                            "Session created with your transcript, but without a screenshot. \(captureError)")
                    }
                } catch {
                    // Failed audio submissions become editable drafts instead of discarding speech.
                    let model = SessionComposerModel(baseURL: baseURL)
                    model.text = prompt
                    model.snapshot = snapshot
                    model.captureError = captureError
                    await model.loadProjects(preferKnowledgeBase: true)
                    model.error =
                        "\(error.localizedDescription) Transcript retained. Check Caesar before retrying after a connection failure."
                    self.showComposer(model, audioRecovery: true)
                }
            }
        }
    }

    @objc func openSessionComposer() {
        if let controller = sessionComposer, controller.model.created == nil {
            controller.present()
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousApplication = frontmost
        }
        guard let baseURL = WhisperService.shared.apiBaseURL() else {
            showError("Configure a valid Brute URL in Audio & speech settings.")
            return
        }
        let model = SessionComposerModel(baseURL: baseURL)
        showComposer(model, captureOnOpen: true)
        Task { await model.loadProjects() }
    }

    private func showComposer(_ model: SessionComposerModel, captureOnOpen: Bool = false, audioRecovery: Bool = false) {
        let controller = SessionComposerWindow(model: model)
        // A failed voice submission must not overwrite a separate manual draft.
        if audioRecovery { audioRecoveryComposer = controller } else { sessionComposer = controller }
        model.onDiscard = { [weak self, weak controller] in
            controller?.close()
            if audioRecovery { self?.audioRecoveryComposer = nil } else { self?.sessionComposer = nil }
        }
        model.onRecapture = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.captureForComposer(controller)
        }
        if captureOnOpen { captureForComposer(controller) } else { controller.present() }
    }

    private func captureForComposer(_ controller: SessionComposerWindow) {
        let model = controller.model
        guard !model.capturing else { return }
        let displayID = DisplayCaptureService.currentDisplayID()
        let appName =
            previousApplication?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "Current display"
        model.capturing = true
        model.captureError = nil
        // Hide adapter windows before capture, then restore the composer. ScreenCaptureKit
        // also excludes this process so HUDs never leak into the captured context.
        settingsController?.window?.orderOut(nil)
        controller.window?.orderOut(nil)
        previousApplication?.activate()
        Task {
            do {
                model.snapshot = try await DisplayCaptureService().capture(
                    displayID: displayID, applicationName: appName)
                model.marks = []
            } catch {
                model.snapshot = nil
                model.marks = []
                model.captureError = error.localizedDescription
            }
            model.capturing = false
            controller.present()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setupVoiceConversation() {
        let controller = VoiceConversationController()
        controller.onStatus = { [weak self] status, listening in
            guard let self else { return }
            self.voiceStatus = status
            self.settingsController?.model.voiceStatus = status
            self.statusItem?.button?.toolTip = "A²gent · \(status)"
            self.statusItem?.button?.title = listening ? " •" : ""
        }
        voiceController = controller
        controller.configure(VoiceSettings.load())
    }

    private func updateMenuState() {
        voiceController?.setSuspended(isRecording || isPlayingTextToSpeech || isSessionProcessing)
        if !isRecording { settingsController?.model.audioLevel = 0 }
        settingsController?.model.isRecording = isRecording
        settingsController?.model.isPlaying = isPlayingTextToSpeech
        statusItem?.button?.image = menuBarImage(
            for: (isRecording || isPlayingTextToSpeech || isSessionProcessing) ? .active : .idle)
    }

    private func menuBarImage(for state: MenuBarVisualState) -> NSImage? {
        BrandResources.statusImage(active: state == .active)
    }
}

extension AppDelegate: AudioServiceDelegate {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float]) {
        DispatchQueue.main.async { [weak self] in
            self?.recordingWindow?.updateWaveform(data: data)
            if self?.settingsController?.window?.isVisible == true {
                self?.settingsController?.model.audioLevel = data.max() ?? 0
            }
        }
    }

    func audioServiceDidBeginPreparingPlayback(_ service: AudioService) {
        DispatchQueue.main.async { [weak self] in
            self?.playbackWindow?.setPreparing()
        }
    }

    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            self?.playbackWindow?.updatePlayback(currentTime: 0, duration: duration, isPlaying: true)
        }
    }

    func audioService(
        _ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval,
        isPlaying: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.playbackWindow?.updatePlayback(currentTime: currentTime, duration: duration, isPlaying: isPlaying)
        }
    }

    func audioServiceDidFinishPlayback(_ service: AudioService) {
        DispatchQueue.main.async { [weak self] in
            self?.isPlayingTextToSpeech = false
            self?.playbackWindow?.close()
            self?.playbackWindow = nil
            self?.updateMenuState()
        }
    }
}
