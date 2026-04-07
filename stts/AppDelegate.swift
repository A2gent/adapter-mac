import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private enum MenuBarVisualState {
        case idle
        case active
    }

    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var shortcutMonitor: GlobalShortcutMonitor?
    var audioService: AudioService?
    var recordingWindow: RecordingWindow?
    var isRecording = false
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
        shortcutMonitor?.onShortcutPressed = { [weak self] in
            self?.handleShortcutPressed()
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
        let shortcuts = shortcutMonitor.availableShortcuts()
        let currentShortcut = shortcutMonitor.currentShortcut()

        let whisperService = WhisperService.shared
        let accessibilityStatus = AccessibilityService.isAccessibilityEnabled() ? "Granted" : "Not Detected"

        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Choose the microphone, global shortcut, and transcription backend Parselton should use."
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

        let shortcutLabel = NSTextField(labelWithString: "Keyboard Shortcut")
        shortcutLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(shortcutLabel)

        let shortcutPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        for shortcut in shortcuts {
            shortcutPopup.addItem(withTitle: shortcut.title)
            shortcutPopup.lastItem?.representedObject = NSNumber(value: shortcut.keyCode)
        }
        if let shortcutIndex = shortcutPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? NSNumber)?.uint32Value == currentShortcut.keyCode
        }) {
            shortcutPopup.selectItem(at: shortcutIndex)
        }
        contentStack.addArrangedSubview(shortcutPopup)

        let endpointLabel = NSTextField(labelWithString: "Backend URL")
        endpointLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(endpointLabel)

        let endpointField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        endpointField.placeholderString = "http://localhost:5445/speech/transcribe"
        endpointField.stringValue = whisperService.apiEndpoint
        contentStack.addArrangedSubview(endpointField)

        let accessibilityLabel = NSTextField(labelWithString: "Accessibility")
        accessibilityLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentStack.addArrangedSubview(accessibilityLabel)

        let accessibilityValue = NSTextField(labelWithString: "\(accessibilityStatus) for \(Bundle.main.bundlePath)")
        accessibilityValue.textColor = .secondaryLabelColor
        accessibilityValue.lineBreakMode = .byTruncatingMiddle
        accessibilityValue.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        contentStack.addArrangedSubview(accessibilityValue)

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 230))
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

            if let selectedKeyCode = (shortcutPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value {
                shortcutMonitor.updateShortcut(keyCode: selectedKeyCode)
            }

            whisperService.updateAPIEndpoint(endpointField.stringValue)
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Shortcut Handler
    
    private func handleShortcutPressed() {
        if isRecording {
            stopRecording()
        } else {
            AccessibilityService.getSelectedText { [weak self] selectedText in
                DispatchQueue.main.async {
                    guard let self else { return }

                    if let selectedText, !selectedText.isEmpty {
                        self.performTextToSpeech(text: selectedText)
                    } else {
                        self.startRecording()
                    }
                }
            }
        }
    }
    
    private func startRecording() {
        guard !isRecording else { return }
        
        isRecording = true
        updateMenuState()
        
        // Create and show recording window
        let window = RecordingWindow(deviceName: audioService?.activeInputDeviceName() ?? "No microphone")
        self.recordingWindow = window
        window.show()
        
        // Start audio recording
        audioService?.startRecording { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.isRecording = false
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
            
            self.performSpeechToText(audioURL: url)
        }
    }

    @objc private func startRecordingFromMenu() {
        startRecording()
    }

    @objc private func stopRecordingFromMenu() {
        stopRecording()
    }
    
    private func performTextToSpeech(text: String) {
        audioService?.playTextToSpeech(text: text) { [weak self] success in
            if !success {
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
                            self?.showError("Transcription was copied to the clipboard because automatic paste is unavailable for this running build. You can still paste manually with Cmd+V. Settings shows the current Accessibility detection status.")
                        }
                    }
                case .failure(let error):
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

        menu.item(withTitle: "Start Recording")?.isEnabled = !isRecording
        menu.item(withTitle: "Stop Recording")?.isEnabled = isRecording
        statusItem?.button?.image = menuBarImage(for: isRecording ? .active : .idle)
    }

    private func menuBarImage(for state: MenuBarVisualState) -> NSImage? {
        let resourceName: String
        let description: String

        switch state {
        case .idle:
            resourceName = "logo-silent"
            description = "Parselton Idle"
        case .active:
            resourceName = "logo-speaking"
            description = "Parselton Active"
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
}

// MARK: - AudioServiceDelegate

extension AppDelegate: AudioServiceDelegate {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float]) {
        guard isRecording, let window = recordingWindow else { return }
        window.updateWaveform(data: data)
    }
}
