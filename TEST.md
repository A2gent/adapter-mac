# Testing Guide

## Запуск приложения

1. **Открыть в Xcode:**
   ```bash
   cd ~/git/a2gent/adapter-mac
   open adapter-mac.xcodeproj
   ```

2. **Build & Run** (`Cmd+R`)

3. **Проверить menu bar** - должна появиться иконка waveform.circle

## Пошаговое тестирование

### Тест 1: Menu Bar Icon
- ✅ Иконка появилась в menu bar
- ✅ Клик по иконке → показывает меню
- ✅ Меню содержит: Settings, Quit

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
