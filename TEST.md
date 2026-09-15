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
- [ ] Clicking the icon opens a nonmodal Settings window directly, without a dropdown.
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
