# Testing Guide

## Запуск приложения

1. **Открыть в Xcode:**
   ```bash
   cd ~/git/stts
   open stts.xcodeproj
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

### Тест 4: Recording (базовый)
- ❌ Нажать F12 → должно появиться окно записи
- ❌ Окно должно быть сверху экрана
- ❌ Окно должно показывать "● Recording"
- ❌ Нажать F12 снова → окно должно исчезнуть
- ❌ Проверить что файл создался в /tmp/recording_*.wav

### Тест 5: Waveform
- ❌ Нажать F12 → начать запись
- ❌ Говорить в микрофон
- ❌ Проверить что waveform анимируется (полоски двигаются)
- ❌ Остановить F12

### Тест 6: Text-to-Speech
- ❌ Выделить любой текст в браузере
- ❌ Нажать F12
- ❌ Должен воспроизвестись звук

### Тест 7: Speech-to-Text (нужен backend)
- ❌ Запустить a2gent backend: `cd ~/git/a2gent/aagent && make run`
- ❌ Нажать F12 (без выделения текста)
- ❌ Говорить "Hello world"
- ❌ Нажать F12
- ❌ Текст должен вставиться

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
