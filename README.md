# Parselton - Speech To Text & Text To Speech

<p align="center">
  <img src="./logo-settings.png" alt="Parselton logo" width="180" />
</p>

Native macOS application for system-wide speech-to-text and text-to-speech conversion.

Speech-to-text depends on the [A2gent brute backend](https://github.com/A2gent/brute) being installed and running locally.

## Features

- **System-wide keyboard shortcut** (default: F12)
- **Menu bar presence** with configuration window
- **Smart context detection:**
  - Text selected → Text-to-Speech (plays audio)
  - No selection → Speech-to-Text (records audio, transcribes, pastes result)
- **Floating recording window** with live waveform visualization
- **Floating playback window** for text-to-speech with stop, pause, and seek controls
- **Higher quality TTS path** via optional `edge-tts`, with automatic fallback to native macOS speech
- **Native macOS integration** using Swift and AppKit

## Requirements

- macOS 13.0+
- Xcode 14.0+
- Microphone permissions
- Accessibility permissions (for global shortcuts and text insertion)
- Optional: `edge-tts` in `PATH` or a common local install location for better text-to-speech quality

## Quick Start

1. **Start the backend** (required for speech-to-text):
   ```bash
   ./scripts/start-backend.sh
   ```

2. **Open in Xcode**:
   ```bash
   open parselton.xcodeproj
   ```

3. **Build and Run** (`Cmd+R` in Xcode)

4. **Grant permissions** when prompted:
   - Microphone access
   - Accessibility access

5. **Open Settings** and confirm the backend URL if needed.

6. **Test it**:
   - Select any text → Press F12 → Listen to speech
   - No selection → Press F12 → Speak → Press F12 again → Text pasted

## Setup

### Backend Setup

Parselton depends on the [A2gent brute backend](https://github.com/A2gent/brute) for Whisper transcription. Speech-to-text will not work unless that service is running.

```bash
cd ~/git/a2gent/brute
make run
```

Or use the helper script:
```bash
./scripts/start-backend.sh
```

Default transcription endpoint:
```text
http://localhost:5445/speech/transcribe
```

Test the endpoint:
```bash
./scripts/test-whisper.sh
```

### Text-to-Speech Privacy

Parselton supports two text-to-speech paths:

- `edge-tts` for higher-quality voices
- native macOS speech synthesis as a local fallback

When `edge-tts` is available, the selected text is sent to Microsoft's online text-to-speech service to generate audio. If you prefer to keep text-to-speech local-only for privacy reasons, do not install `edge-tts` or remove it from `PATH`, and Parselton will fall back to macOS speech synthesis instead.

## Architecture

- **Swift + AppKit** for native macOS experience
- **AVFoundation** for audio recording and playback
- **Carbon** for global keyboard shortcuts
- **Accessibility API** for text selection detection and insertion
- **brute** backend integration for speech-to-text

## Usage

1. Click menu bar icon to configure settings
2. Press configured shortcut (default: F12):
   - **With text selected:** Converts text to speech and plays audio
   - **Without selection:** Opens recording window
3. While recording, press shortcut again to stop and transcribe
4. Transcribed text is automatically pasted at cursor position

## License

Private project
