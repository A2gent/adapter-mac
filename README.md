# STTS - Speech To Text & Text To Speech

Native macOS application for system-wide speech-to-text and text-to-speech conversion.

## Features

- **System-wide keyboard shortcut** (default: F12)
- **Menu bar presence** with configuration window
- **Smart context detection:**
  - Text selected → Text-to-Speech (plays audio)
  - No selection → Speech-to-Text (records audio, transcribes, pastes result)
- **Floating recording window** with live waveform visualization
- **Native macOS integration** using Swift and AppKit

## Requirements

- macOS 13.0+
- Xcode 14.0+
- Microphone permissions
- Accessibility permissions (for global shortcuts and text insertion)

## Setup

1. Clone the repository
2. Open `stts.xcodeproj` in Xcode
3. Build and run
4. Grant required permissions when prompted

## Architecture

- **Swift + AppKit** for native macOS experience
- **AVFoundation** for audio recording and playback
- **Carbon** for global keyboard shortcuts
- **Accessibility API** for text selection detection and insertion
- **Whisper.cpp** backend integration for speech-to-text

## Usage

1. Click menu bar icon to configure settings
2. Press configured shortcut (default: F12):
   - **With text selected:** Converts text to speech and plays audio
   - **Without selection:** Opens recording window
3. While recording, press shortcut again to stop and transcribe
4. Transcribed text is automatically pasted at cursor position

## License

Private project
