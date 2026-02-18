# Setup Instructions

## Building the App

1. **Open in Xcode:**
   ```bash
   cd ~/git/stts
   open stts.xcodeproj
   ```

2. **Build and Run:**
   - Press `Cmd+R` or click the Run button
   - Xcode will compile the Swift files and launch the app

3. **Grant Permissions:**
   - **Microphone:** Required for speech-to-text recording
   - **Accessibility:** Required for:
     - Global keyboard shortcuts
     - Detecting selected text
     - Pasting transcribed text

## Backend Setup (Required for Speech-to-Text)

The app connects to the a2gent backend for Whisper transcription.

1. **Start the backend:**
   ```bash
   cd ~/git/a2gent/aagent
   make run
   ```

2. **Verify the endpoint:**
   ```bash
   curl http://localhost:3000/health
   ```

3. **Configure endpoint** (if different):
   Edit `stts/Services/WhisperService.swift` and change:
   ```swift
   private let apiEndpoint = "http://localhost:3000/speech/transcribe"
   ```

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│           macOS Menu Bar App                │
│                                             │
│  ┌─────────────┐      ┌──────────────────┐ │
│  │ AppDelegate │──────│ Global Shortcut  │ │
│  │             │      │ Monitor (F12)    │ │
│  └─────────────┘      └──────────────────┘ │
│         │                                   │
│         ├────► AudioService                 │
│         │      (AVFoundation)               │
│         │                                   │
│         ├────► AccessibilityService         │
│         │      (AX API)                     │
│         │                                   │
│         ├────► RecordingWindow              │
│         │      (Waveform Viz)               │
│         │                                   │
│         └────► WhisperService               │
│                (HTTP → a2gent)              │
└─────────────────────────────────────────────┘
                   │
                   ▼
         ┌─────────────────┐
         │  a2gent backend │
         │  (whisper.cpp)  │
         └─────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `AppDelegate.swift` | Main app logic, menu bar setup |
| `main.swift` | Entry point |
| `Services/GlobalShortcutMonitor.swift` | F12 keyboard shortcut via Carbon |
| `Services/AccessibilityService.swift` | Text selection & paste via AX API |
| `Services/AudioService.swift` | Recording & TTS via AVFoundation |
| `Services/WhisperService.swift` | HTTP client for transcription |
| `Views/RecordingWindow.swift` | Floating window with waveform |

## Usage Flow

### Text-to-Speech (TTS)
1. Select text in any app
2. Press F12
3. App reads selection via Accessibility API
4. AVSpeechSynthesizer plays audio

### Speech-to-Text (STT)
1. Press F12 (no text selected)
2. Recording window appears with waveform
3. Speak into microphone
4. Press F12 again to stop
5. Audio sent to a2gent backend
6. Whisper transcribes audio
7. Text pasted at cursor via Accessibility API

## Troubleshooting

### "Microphone permission denied"
- Go to System Settings → Privacy & Security → Microphone
- Enable for "stts"

### "Accessibility permission denied"
- Go to System Settings → Privacy & Security → Accessibility
- Enable for "stts"

### "Failed to transcribe"
- Ensure a2gent backend is running on `localhost:3000`
- Check backend logs for errors
- Verify audio file was created in `/tmp/`

### Global shortcut not working
- Check Accessibility permission is granted
- Try different key (edit `GlobalShortcutMonitor.swift`)
- Current keyCode `111` = F12

## Customization

### Change Keyboard Shortcut
Edit `stts/Services/GlobalShortcutMonitor.swift`:
```swift
// F12 = 111, F11 = 103, F10 = 109
registerHotKey(keyCode: 111, modifiers: 0)
```

### Change API Endpoint
Edit `stts/Services/WhisperService.swift`:
```swift
private let apiEndpoint = "http://your-server:3000/speech/transcribe"
```

### Customize Waveform
Edit `stts/Views/RecordingWindow.swift`:
- Colors: HSL gradient in `draw(_:)`
- Bar count: `barCount` property
- Window size: `windowWidth` and `windowHeight`
