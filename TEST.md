# Testing Guide

## Запуск приложения

1. **Открыть в Xcode:**
   ```bash
   cd ~/git/a2gent/adapter-mac
   open adapter-mac.xcodeproj
   ```

2. **Build & Run** (`Cmd+R`)

3. **Проверить menu bar** - должна появиться монохромная иконка A²gent

## Пошаговое тестирование

### Тест 1: Menu Bar Icon
- ✅ Иконка появилась в menu bar
- [ ] Clicking the icon opens the compact conversation; the gear and Cmd+, expand the same nonmodal window into Settings.
- [ ] Repeated clicks focus the same window without losing unsaved edits.
- [ ] Overview shows the blue Caesar sphere, recording/playback controls, and Quit.
- [ ] Audio & speech and Shortcuts remain usable at minimum window size, in light and dark mode.
- [ ] Save applies all settings; Cancel/close discards drafts. Invalid URLs or duplicate shortcuts do not partially save.
- [ ] Cmd+C/V/A work in the backend field; Cmd+S saves, Cmd+W closes, Cmd+Q quits.
- [ ] The sphere stops animating when hidden/minimized; Reduce Motion disables animation.
- [ ] Dictation started from Settings returns focus to the previous app.

### Тест 2: Permissions
- ✅ При первом запуске запрашивает Microphone permission
- ✅ При первом F12 запрашивает Accessibility permission

### Тест 3: Global Shortcut (без записи)
- ❌ Нажать F12 БЕЗ записи - проверить что не крэшится
- ❌ Проверить консоль на ошибки

### Тест 4: Recording (basic reliability)
- ✅ Нажать F12 -> должно появиться окно записи
- ✅ Окно должно быть сверху экрана
- ✅ Окно должно сначала показать connecting state, затем Recording
- ✅ Нажать F12 снова -> окно должно закрыться после finalizing state
- ✅ Проверить что файл создаётся как /tmp/recording_*.m4a, если запись не была отклонена как пустая или слишком короткая

### Тест 5: Waveform and normal speech
- ✅ Нажать F12 -> начать запись
- ✅ Говорить в микрофон обычной громкостью
- ✅ Проверить что waveform анимируется
- ✅ Остановить F12
- ✅ Проверить, что запись ушла в transcription flow

### Тест 6: Short accidental recording
- ✅ Нажать и почти сразу отпустить shortcut
- ✅ Проверить, что transcription не запускается
- ✅ Проверить понятное сообщение про too short recording

### Тест 7: External or Bluetooth microphone
- ✅ Выбрать внешний, Bluetooth или iPhone microphone в Settings, если доступен
- ✅ Проверить, что Settings показывают понятный label для устройства
- ✅ Начать запись и убедиться, что окно показывает имя устройства и connection hint
- ✅ При успешной записи waveform должен обновляться

### Тест 8: Text-to-Speech
- ❌ Выделить любой текст в браузере
- ❌ Нажать F12
- ❌ Должен воспроизвестись звук

### Тест 9: Speech-to-Text (нужен backend)
- ❌ Запустить a2gent backend: `cd ~/git/a2gent/aagent && make run`
- ❌ Нажать F12 (без выделения текста)
- ❌ Говорить "Hello world"
- ❌ Нажать F12
- ❌ Текст должен вставиться

### Тест 10: Hold-to-record mode
- ❌ Открыть Settings и включить `Hold to record adapter-mac shortcut`
- ❌ Убедиться, что shortcut adapter-mac остался F12, а brute session остался F11
- ❌ Зажать F12 (без выделения текста) → запись должна стартовать на удержании
- ❌ Говорить, пока F12 удерживается
- ❌ Отпустить F12 после короткой паузы удержания → запись должна остановиться и отправиться на транскрибацию
- ❌ Коротко нажать F12 → запись не должна уйти в транскрибацию

### Тест 11: Escape cancel
- ❌ Начать запись через F12 и нажать Escape → запись должна закрыться без транскрибации
- ❌ Запустить TTS через F12 на выделенном тексте и нажать Escape → playback должен остановиться сразу
- ❌ Начать запись через F11 и нажать Escape → brute session не должен стартовать

## Известные проблемы

### Audio Engine Warning
```
AddInstanceForFactory: No factory registered for id <CFUUID> F8BB1C28-BAE8-11D6-9C31-00039315CD46
throwing -10877
```
**Статус:** Warning, можно игнорировать. Запись всё равно работает.

### EXC_BAD_ACCESS
**Возможные причины:**
1. Обращение к закрытому окну из audio callback
2. Race condition между main thread и audio thread
3. Deallocated buffer в installTap

**Исправления:**
- Добавлены weak references
- Добавлены guards для isRecording
- Добавлен isClosed флаг для окна
- Cleanup порядок улучшен

## Debugging

### Консольные логи
При работе приложения должны быть видны:
```
Microphone permission granted
📱 Input format: sampleRate=48000.0, channels=1
✅ Recording started
🛑 Recording stopped: /tmp/recording_XXX.wav
```

### Проверка аудио файла
```bash
ls -lh /tmp/recording_*.wav
afinfo /tmp/recording_*.wav
```

### Если крэш всё ещё происходит
1. Запустить через Xcode с debugger
2. Посмотреть stack trace в момент крэша
3. Проверить Thread Sanitizer: Product → Scheme → Edit Scheme → Diagnostics → Thread Sanitizer

## Automated verification

```sh
swift test
swift build
xcodebuild -project adapter-mac.xcodeproj -scheme adapter-mac -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcrun swift-format lint --strict stts/Views/{SettingsWindow,BrandResources,CaesarSphereView}.swift stts/Services/SettingsDraft.swift Tests/AdapterMacTests/Settings*Tests.swift
```

Settings tests cover draft validation, save/cancel semantics, window reuse and bundled WebKit sphere loading without network access.

## Session composer and voice regression checklist

Automated: `swift test` covers the API contract (`task`, `project_id`, `images`, serial queue), Knowledge Base lookup, missing projects, HTTP errors, incomplete responses, retained drafts, duplicate-submit prevention, annotation scaling/clamping and PNG export orientation.

Manual checks (require microphone/Screen Recording permissions and a running Brute):

- [ ] F11 from another app: speak, stop, and verify Caesar opens a session in Knowledge Base with the actual transcript and a screenshot captured at recording start.
- [ ] Empty/failed transcription creates no session. A failed session POST opens a draft containing the transcript and screenshot; an existing manual draft remains intact.
- [ ] No screen permission: transcript still sends, with a visible screenshot warning. F12 never captures a display.
- [ ] Settings → New session: select project, edit task, draw pen/arrow/rectangle, Undo/Clear, submit. Check the project's first user message contains the flattened image with correctly placed marks.
- [ ] Remove attachment and submit: the backend receives no images. Recapture failure clears the stale attachment.
- [ ] Multiple displays: capture uses the display under the pointer, not always the primary display. Verify with Retina scaling and a fullscreen game. Own settings/composer/HUD must be excluded.
- [ ] Permission-denied, disconnected display, offline backend and missing Knowledge Base show actionable errors without creating an unbound session or discarding drafts.
- [ ] Double-click Create does not duplicate requests. Close/reopen retains a draft; Discard clears it. A failed audio draft is offered again on F11 until submitted or discarded.
- [ ] Resize composer to minimum size, test light/dark appearance and keyboard project/message editing.

Lint the new session files:

```sh
xcrun swift-format lint --strict stts/Services/{BruteSessionService,DisplayCaptureService}.swift stts/Views/{SessionComposerWindow,ScreenshotAnnotationView,SettingsWindow}.swift Tests/AdapterMacTests/{SessionRequest,SessionComposer,BruteSessionService}Tests.swift
```

## Background voice verification

Automated unit tests cover configurable wake-name boundaries, same-utterance commands, partial STT revision, segment rollover, VAD-driven silence, cancellation, new session commands, text/audio bounds, settings persistence, continued-chat JSON, assistant-only replies, and HTTP errors.

An opt-in real-model smoke test uses synthetic Russian audio, not the microphone. It downloads models on first run. Use Release to measure realistic decoding latency:

```sh
mkdir -p build/voice-smoke
say -v Milena -o build/voice-smoke/russian.aiff 'Цезарь, проверь тесты. Конец команды.'
afconvert -f WAVE -d LEF32@16000 -c 1 build/voice-smoke/russian.aiff build/voice-smoke/russian.wav
VOICE_SMOKE_AUDIO="$PWD/build/voice-smoke/russian.wav" swift test -c release --filter VoiceDecoderSmokeTests
```

Manual acceptance (not replaced by fixture tests):

- [ ] Release app: enable background voice, allow microphone, wait for initial model download. Rename the agent, Save, relaunch and verify persistence.
- [ ] Say the name plus command without a pause. Sphere/cue appears and text after the name is retained. Normal room conversation without the name creates no backend requests.
- [ ] Test stop suffix and 1.5 seconds of VAD silence (or the saved custom delay) with fan/background noise; a word mentioned inside a sentence does not terminate it unless it is the trailing stop phrase.
- [ ] Say a second name-prefixed command while Brute works; verify it is serialized into the same session. Use new-session commands and check context separation.
- [ ] Toggle spoken replies; confirm local voice speaks once and does not activate itself. F12 playback and F11/F12 recording pause background capture. Escape cancels the active draft/speech.
- [ ] Verify no recording files are created by background voice; observe memory during 30 minutes of idle and conversation. Use Release for performance acceptance.
- [ ] Disable during model loading, capture, decoding, and a pending HTTP request. No stale callback may reactivate capture or speech.
- [ ] Disconnect microphone, deny permission, interrupt backend connectivity, overflow the queue, and exceed the command limit. Errors pause capture; drafts stay visible and uncertain requests are not retried.
- [ ] Verify the HUD in full-screen apps/multiple Spaces, keyboard focus preservation, screen lock/sleep/wake recovery, and local Russian voice availability.

Lint task files with `xcrun swift-format lint --strict` followed by their Swift paths. Full repository lint is `xcrun swift-format lint --strict --recursive stts Tests`; unrelated pre-existing formatting debt is tracked separately.

### Voice settings regression verification (2026-09-15)

- Local Debug app: keyboard edit of agent name persisted after closing/reopening Settings; restored to Brute.
- Command and Reply appear as separate cards. Decorative card borders do not intercept field clicks.
- Cancel during cached-model startup exposes Retry. Saving unchanged settings leaves setup cancelled; Retry reaches Listening locally for Brute.
- Five consecutive saves while listening preserve ready status without restarting model preparation.
- Background listening was disabled after the manual check.
- `VOICE_SMOKE_AUDIO="$PWD/build/voice-smoke/russian.wav" swift test`: 78 tests pass, including real Whisper/VAD decoding (no microphone fixture recording).
- Xcode Debug build and strict swift-format lint on changed Swift files pass. Repository-wide formatting debt remains tracked as A-39.
- Cold network download UI was not exercised manually because models were already cached. Preparation tests cover cancellation reaching the loader, immediate retry serialization, retry after failure, and reuse of successful preparation. Do not delete the user's cached models to test downloads.

## Unified window and voice latency verification (2026-09-15)

- `VOICE_SMOKE_AUDIO="$PWD/build/voice-smoke/russian.wav" swift test -c release`: 96 tests pass, including real Whisper/VAD. The 2.816-second Russian fixture decoded in approximately 0.94 seconds on this host (decoder only, not microphone-to-reply latency).
- `swift test` / `swift build` and Xcode Debug build pass. Changed Swift files pass strict swift-format. Repository-wide formatting findings remain tracked in A-39; unrelated files were not reformatted.
- Regression tests cover single window/model identity, draft preservation across expansion/hiding, saved settings on reopen, no microphone startup in UI tests, partial coalescing, final ordering, bounded backlog, sub-second partial cadence, silence migration, and speech-time-based deadlines.
- Review fixes include passive presentation without app activation, explicit Cancel/Hide behavior, Send waiting for pending decoding, fresh capture on session reset, and cancelled feedback suppression without cancelling an accepted backend task.

Manual acceptance still required with the actual microphone and a running Brute:

1. Use a Release app. Tray opens the sphere; gear expands navigation and Conversation returns. Edit a setting, expand/collapse, and confirm the draft survives. Close/reopen and verify only saved settings remain.
2. Speak Russian and English commands. Verify live sphere levels before wake detection, revised text during speech, and no duplicate words at segment boundaries.
3. Pause for the configured timeout, including while decoder load is high; the final recognized audio must be included before submission. Send is unavailable while decoding is pending.
4. Keep another app focused during wake activation, then edit Settings using real keys. Verify only one conversation/settings window exists, including across Spaces/fullscreen apps.
5. Cancel during a pending reply: the backend session still exists but must not speak on completion. Check noise, Bluetooth input, disconnects, and recovery.

No live-microphone, live-backend, or native screenshot acceptance is claimed by the fixture/unit tests. The already running Xcode app was not restarted automatically.

## Slow-decoder backpressure regression (2026-09-16)

- Reproduced performance mismatch on the same 2.816s Russian fixture: Debug decode 7.73s, Release decode 1.10s. The running user process was in Xcode's Debug products directory.
- New deterministic tests stall the decoder across six paused segments, preserve every final PCM sample and segment order, suppress previews while busy, resume previews when idle, accept more than four short finals, and check sample-budget exhaustion/replacement/pop accounting.
- The shared scheme's normal Run is Release; Debug remains available for diagnosis. `xcodebuild -project adapter-mac.xcodeproj -scheme adapter-mac -showBuildSettings` must report `CONFIGURATION = Release` without an override.
- Manual acceptance: stop the old Debug instance; run the shared Release scheme; Retry voice setup if needed. Speak several short clauses separated by pauses, then a longer command. Verify no four-fragment error, ordered text without duplicate words, and final audio included before send. Real microphone/backend acceptance is still required (A-40).
