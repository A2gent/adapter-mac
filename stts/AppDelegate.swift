import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var shortcutMonitor: GlobalShortcutMonitor?
    var audioService: AudioService?
    var recordingWindow: RecordingWindow?
    var isRecording = false
    
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
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "STTS")
        }
        
        menu = NSMenu()
        menu?.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        
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
        // Request microphone permission
        AudioService.requestMicrophonePermission()
        
        // Request accessibility permission for text insertion
        AccessibilityService.requestAccessibilityPermission()
    }
    
    // MARK: - Actions
    
    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Configure keyboard shortcut and other preferences"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(self)
    }
    
    // MARK: - Shortcut Handler
    
    private func handleShortcutPressed() {
        if isRecording {
            stopRecording()
        } else {
            // Check if there's selected text
            if let selectedText = AccessibilityService.getSelectedText(), !selectedText.isEmpty {
                performTextToSpeech(text: selectedText)
            } else {
                startRecording()
            }
        }
    }
    
    private func startRecording() {
        isRecording = true
        
        // Show recording window
        recordingWindow = RecordingWindow()
        recordingWindow?.show()
        
        // Start audio recording
        audioService?.startRecording { [weak self] success in
            if !success {
                self?.isRecording = false
                self?.recordingWindow?.close()
                self?.showError("Failed to start recording")
            }
        }
    }
    
    private func stopRecording() {
        isRecording = false
        recordingWindow?.close()
        recordingWindow = nil
        
        audioService?.stopRecording { [weak self] audioFileURL in
            guard let url = audioFileURL else {
                self?.showError("Failed to save recording")
                return
            }
            
            self?.performSpeechToText(audioURL: url)
        }
    }
    
    private func performTextToSpeech(text: String) {
        audioService?.playTextToSpeech(text: text) { [weak self] success in
            if !success {
                self?.showError("Failed to play audio")
            }
        }
    }
    
    private func performSpeechToText(audioURL: URL) {
        // Show processing indicator
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Processing")
        
        WhisperService.shared.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                // Restore icon
                self?.statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "STTS")
                
                switch result {
                case .success(let text):
                    AccessibilityService.pasteText(text)
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
}

// MARK: - AudioServiceDelegate

extension AppDelegate: AudioServiceDelegate {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float]) {
        recordingWindow?.updateWaveform(data: data)
    }
}
