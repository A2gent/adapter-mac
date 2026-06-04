import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private enum MenuBarVisualState {
        case idle
        case active
    }

    private enum RecordingMode {
        case pasteTranscription
        case bruteSession
    }

    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var shortcutMonitor: GlobalShortcutMonitor?
    var audioService: AudioService?
    var recordingWindow: RecordingWindow?
    var playbackWindow: PlaybackWindow?
    var isRecording = false
    var isPlayingTextToSpeech = false
    private var recordingMode: RecordingMode?
    private var hasShownAccessibilityClipboardNotice = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupServices()
        setupGlobalShortcut()
        requestPermissions()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        shortcutMonitor?.stop()
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - Setup
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.imageScaling = .scaleProportionallyDown
            button.image = menuBarImage(for: .idle)
        }
        
        menu = NSMenu()
        menu?.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(NSMenuItem(title: "Start Recording", action: #selector(startRecordingFromMenu), keyEquivalent: "r"))
        menu?.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingFromMenu), keyEquivalent: "s"))
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        menu?.autoenablesItems = false
        updateMenuState()
        
        statusItem?.menu = menu
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
    
    @objc private func openSettings() {
        guard let audioService, let shortcutMonitor else {
            showError("Settings are unavailable")
            return
        }

        let devices = audioService.availableInputDevices()
        let shortcutKeys = GlobalShortcutMonitor.availableShortcutKeys()
        let currentAdapterMacShortcut = shortcutMonitor.currentShortcut(for: .adapterMac)
        let currentBruteShortcut = shortcutMonitor.currentShortcut(for: .bruteSession)

        let whisperService = WhisperService.shared

        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Choose the microphone, shortcuts, speech backend, and text-to-speech engine adapter-mac should use."
        alert.alertStyle = .informational
        if let settingsLogo = imageResource(named: "logo-settings") {
            let alertIcon = settingsLogo.copy() as? NSImage ?? settingsLogo
            alertIcon.size = NSSize(width: 72, height: 72)
            alert.icon = alertIcon
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let microphoneLabel = NSTextField(labelWithString: "Microphone")
        microphoneLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(microphoneLabel)

        let microphonePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        microphonePopup.addItem(withTitle: "System Default (\(audioService.systemDefaultInputDeviceName()))")
        microphonePopup.lastItem?.representedObject = nil
        for device in devices {
            let title = device.isDefault ? "\(device.name) (Default)" : device.name
            microphonePopup.addItem(withTitle: title)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if let selectedID = audioService.selectedInputDeviceID(),
           let index = microphonePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedID }) {
            microphonePopup.selectItem(at: index)
        } else {
            microphonePopup.selectItem(at: 0)
        }
        contentStack.addArrangedSubview(microphonePopup)

        let adapterMacShortcutControls = makeShortcutEditor(
            label: "adapter-mac Shortcut",
            shortcut: currentAdapterMacShortcut,
            keyOptions: shortcutKeys
        )
        contentStack.addArrangedSubview(adapterMacShortcutControls.container)

        let bruteShortcutControls = makeShortcutEditor(
            label: "Brute Session Shortcut",
            shortcut: currentBruteShortcut,
            keyOptions: shortcutKeys
        )
        contentStack.addArrangedSubview(bruteShortcutControls.container)

        let endpointLabel = NSTextField(labelWithString: "Backend URL")
        endpointLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(endpointLabel)

        let endpointField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        endpointField.placeholderString = "http://localhost:5445/speech/transcribe"
        endpointField.stringValue = whisperService.apiEndpoint
        contentStack.addArrangedSubview(endpointField)

        let ttsLabel = NSTextField(labelWithString: "TTS Engine")
        ttsLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(ttsLabel)

        let ttsPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        for engine in TTSEngine.allCases {
            ttsPopup.addItem(withTitle: engine.title)
            ttsPopup.lastItem?.representedObject = engine.rawValue
        }

        if let currentIndex = ttsPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == audioService.selectedTTSEngine().rawValue
        }) {
            ttsPopup.selectItem(at: currentIndex)
        }
        contentStack.addArrangedSubview(ttsPopup)

        let ttsStatus = NSTextField(labelWithString: audioService.ttsEngineAvailabilitySummary())
        ttsStatus.textColor = .secondaryLabelColor
        ttsStatus.lineBreakMode = .byWordWrapping
        ttsStatus.maximumNumberOfLines = 0
        contentStack.addArrangedSubview(ttsStatus)

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 330))
        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor)
        ])

        alert.accessoryView = accessoryContainer

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let selectedID = microphonePopup.selectedItem?.representedObject as? String
            audioService.selectInputDevice(id: selectedID)

            let adapterMacShortcut = shortcutOption(
                keyPopup: adapterMacShortcutControls.keyPopup,
                commandCheckbox: adapterMacShortcutControls.commandCheckbox,
                optionCheckbox: adapterMacShortcutControls.optionCheckbox,
                controlCheckbox: adapterMacShortcutControls.controlCheckbox,
                shiftCheckbox: adapterMacShortcutControls.shiftCheckbox
            )
            let bruteShortcut = shortcutOption(
                keyPopup: bruteShortcutControls.keyPopup,
                commandCheckbox: bruteShortcutControls.commandCheckbox,
                optionCheckbox: bruteShortcutControls.optionCheckbox,
                controlCheckbox: bruteShortcutControls.controlCheckbox,
                shiftCheckbox: bruteShortcutControls.shiftCheckbox
            )

            if adapterMacShortcut == bruteShortcut {
                showError("adapter-mac and brute session shortcuts must be different.")
                return
            }

            shortcutMonitor.updateShortcut(for: .adapterMac, shortcut: adapterMacShortcut)
            shortcutMonitor.updateShortcut(for: .bruteSession, shortcut: bruteShortcut)

            whisperService.updateAPIEndpoint(endpointField.stringValue)

            if let rawValue = ttsPopup.selectedItem?.representedObject as? String,
               let engine = TTSEngine(rawValue: rawValue) {
                audioService.selectTTSEngine(engine)
            }
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Shortcut Handler
    
    private func handleAdapterMacShortcutPressed() {
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

    private func handleBruteSessionShortcutPressed() {
        if isRecording {
            stopRecording()
            return
        }
        if isPlayingTextToSpeech {
            stopPlayback()
        }
        startRecording(mode: .bruteSession)
    }

    private func handleCancelRequested() {
        guard isRecording else { return }
        cancelRecording()
    }
    
    private func startRecording(mode: RecordingMode) {
        guard !isRecording else { return }
        recordingMode = mode
        
        isRecording = true
        updateMenuState()
        
        // Create and show recording window
        let window = RecordingWindow(
            deviceName: audioService?.activeInputDeviceName() ?? "No microphone",
            titleText: mode == .bruteSession ? "BRUTE" : "REC",
            hintText: mode == .bruteSession ? "Esc cancel, shortcut send to brute" : "Esc cancel, shortcut paste text"
        )
        self.recordingWindow = window
        window.show()
        
        // Start audio recording
        audioService?.startRecording { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.isRecording = false
                self.recordingMode = nil
                self.recordingWindow?.close()
                self.recordingWindow = nil
                self.updateMenuState()
                self.showError("Failed to start recording")
            }
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        
        isRecording = false
        updateMenuState()
        let completedMode = recordingMode
        recordingMode = nil
        
        // Close recording window immediately
        recordingWindow?.close()
        recordingWindow = nil
        
        // Stop audio recording
        audioService?.stopRecording { [weak self] audioFileURL in
            guard let self = self else { return }
            
            guard let url = audioFileURL else {
                self.showError("Failed to save recording")
                return
            }
            
            switch completedMode {
            case .bruteSession:
                self.performSpeechToBruteSession(audioURL: url)
            case .pasteTranscription, .none:
                self.performSpeechToText(audioURL: url)
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }

        isRecording = false
        recordingMode = nil
        updateMenuState()
        recordingWindow?.close()
        recordingWindow = nil
        audioService?.cancelRecording()
    }

    @objc private func startRecordingFromMenu() {
        startRecording(mode: .pasteTranscription)
    }

    @objc private func stopRecordingFromMenu() {
        stopRecording()
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
    
    private func performSpeechToText(audioURL: URL) {
        statusItem?.button?.image = menuBarImage(for: .active)
        
        WhisperService.shared.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                self?.statusItem?.button?.image = self?.menuBarImage(for: .idle)
                
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
                            self?.showError("Transcription was copied to the clipboard because automatic paste is unavailable for this running build. You can still paste manually with Cmd+V.")
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

        WhisperService.shared.transcribe(audioURL: audioURL) { [weak self] result in
            switch result {
            case .success(let text):
                let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else {
                    DispatchQueue.main.async {
                        self?.statusItem?.button?.image = self?.menuBarImage(for: .idle)
                    }
                    return
                }

                BruteSessionService.shared.startSession(with: prompt) { launchResult in
                    DispatchQueue.main.async {
                        self?.statusItem?.button?.image = self?.menuBarImage(for: .idle)
                        if case .failure(let error) = launchResult {
                            self?.showError("Failed to start brute session: \(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.statusItem?.button?.image = self?.menuBarImage(for: .idle)
                    self?.showError("Transcription failed: \(error.localizedDescription)")
                }
            }
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

    private func updateMenuState() {
        guard let menu else { return }

        menu.item(withTitle: "Start Recording")?.isEnabled = !isRecording && !isPlayingTextToSpeech
        menu.item(withTitle: "Stop Recording")?.isEnabled = isRecording
        statusItem?.button?.image = menuBarImage(for: (isRecording || isPlayingTextToSpeech) ? .active : .idle)
    }

    private func menuBarImage(for state: MenuBarVisualState) -> NSImage? {
        let resourceName: String
        let description: String

        switch state {
        case .idle:
            resourceName = "logo-silent"
            description = "adapter-mac Idle"
        case .active:
            resourceName = "logo-speaking"
            description = "adapter-mac Active"
        }

        guard let image = imageResource(named: resourceName) else {
            return NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: description)
        }

        let menuImage = image.copy() as? NSImage ?? image
        menuImage.size = NSSize(width: 18, height: 18)
        menuImage.isTemplate = false
        return menuImage
    }

    private func imageResource(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private func makeShortcutEditor(
        label: String,
        shortcut: ShortcutOption,
        keyOptions: [ShortcutKeyOption]
    ) -> (
        container: NSStackView,
        keyPopup: NSPopUpButton,
        commandCheckbox: NSButton,
        optionCheckbox: NSButton,
        controlCheckbox: NSButton,
        shiftCheckbox: NSButton
    ) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let title = NSTextField(labelWithString: label)
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(title)

        let keyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        for option in keyOptions {
            keyPopup.addItem(withTitle: option.title)
            keyPopup.lastItem?.representedObject = NSNumber(value: option.keyCode)
        }
        if let index = keyPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? NSNumber)?.uint32Value == shortcut.keyCode
        }) {
            keyPopup.selectItem(at: index)
        }
        stack.addArrangedSubview(keyPopup)

        let modifiersRow = NSStackView()
        modifiersRow.orientation = .horizontal
        modifiersRow.alignment = .centerY
        modifiersRow.spacing = 10

        let commandCheckbox = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
        commandCheckbox.state = shortcut.modifiers & UInt32(cmdKey) != 0 ? .on : .off
        modifiersRow.addArrangedSubview(commandCheckbox)

        let optionCheckbox = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
        optionCheckbox.state = shortcut.modifiers & UInt32(optionKey) != 0 ? .on : .off
        modifiersRow.addArrangedSubview(optionCheckbox)

        let controlCheckbox = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
        controlCheckbox.state = shortcut.modifiers & UInt32(controlKey) != 0 ? .on : .off
        modifiersRow.addArrangedSubview(controlCheckbox)

        let shiftCheckbox = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
        shiftCheckbox.state = shortcut.modifiers & UInt32(shiftKey) != 0 ? .on : .off
        modifiersRow.addArrangedSubview(shiftCheckbox)

        stack.addArrangedSubview(modifiersRow)

        return (stack, keyPopup, commandCheckbox, optionCheckbox, controlCheckbox, shiftCheckbox)
    }

    private func shortcutOption(
        keyPopup: NSPopUpButton,
        commandCheckbox: NSButton,
        optionCheckbox: NSButton,
        controlCheckbox: NSButton,
        shiftCheckbox: NSButton
    ) -> ShortcutOption {
        let keyCode = (keyPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value ?? UInt32(kVK_F12)
        var modifiers: UInt32 = 0
        if commandCheckbox.state == .on {
            modifiers |= UInt32(cmdKey)
        }
        if optionCheckbox.state == .on {
            modifiers |= UInt32(optionKey)
        }
        if controlCheckbox.state == .on {
            modifiers |= UInt32(controlKey)
        }
        if shiftCheckbox.state == .on {
            modifiers |= UInt32(shiftKey)
        }
        return ShortcutOption(keyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - AudioServiceDelegate

extension AppDelegate: AudioServiceDelegate {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float]) {
        guard isRecording, let window = recordingWindow else { return }
        window.updateWaveform(data: data)
    }

    func audioServiceDidBeginPreparingPlayback(_ service: AudioService) {
        isPlayingTextToSpeech = true
        playbackWindow?.setPreparing()
        playbackWindow?.show()
        updateMenuState()
    }

    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval) {
        isPlayingTextToSpeech = true
        playbackWindow?.updatePlayback(currentTime: 0, duration: duration, isPlaying: true)
        playbackWindow?.show()
        updateMenuState()
    }

    func audioService(_ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        playbackWindow?.updatePlayback(currentTime: currentTime, duration: duration, isPlaying: isPlaying)
    }

    func audioServiceDidFinishPlayback(_ service: AudioService) {
        isPlayingTextToSpeech = false
        playbackWindow?.close()
        playbackWindow = nil
        updateMenuState()
    }
}
