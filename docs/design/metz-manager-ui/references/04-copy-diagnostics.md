# 04 — UI copywriting, naming, state language and truthful diagnostics

## Editorial principles
- Russian localization throughout, without random English terms in the primary UI. Product names, API terms and file formats may retain proper names (`Mac`, `Android TV`, `ADB`, `METZ Display`). Don't translate actual internal identifiers into visible status.
- A destination is a short noun: `Пульт`, `Приложения`, `Экран`, `Диагностика`, `Файлы`, `Настройки`.
- A button starts with a verb: `Подключить`, `Проверить`, `Начать трансляцию`, `Остановить`, `Открыть на ТВ`, `Скопировать`.
- A state is not a button: `Подключено`, `Не подключено`, `Трансляция идёт`, `Нет данных`, `Не проверено`.
- Titles use sentence case, not uppercase everywhere. No three-line captions on buttons; no repeated `Управляйте телевизором с Mac` on every view if context is self-evident.
- Where a failure occurs, explain **what happened → what can be done** in one or two short sentences. Keep exact logs in disclosure.
- Use exact terms: `Кадры/с` for stream fps, `Разрешение` for resolution, `Громкость` for volume, `Без звука` for mute, `Снимок экрана` for captured still, `Трансляция` for live stream. `Перезапустить ТВ` is different from `Переподключить`.

## Rewrite of currently visible legacy texts
Only perform changes where their **underlying meaning is confirmed** in code; choose the right target state. Never edit connection semantics just to match suggested copy.

| Old/technical label | Better user-facing label | Conditions |
|---|---|---|
| `Второй экран Mac` | `Экран` (page) / `Второй экран` (mode) | Only extended display is supported |
| `Экран - 1280x720 / 30` | `Разрешение: 1280 × 720` and `Частота: 30 кадр/с` | Actual configured values |
| `Создать METZ Display` | `Создать виртуальный экран` | If action really creates display; otherwise keep correct specific term |
| `Подготовить подключение на ТВ` | `Подготовить ТВ` | Begins receiver/pairing preparation |
| `Ключ ТВ готов` | `Ключ создан` or `Сопряжение подтверждено` | Different states; never conflate |
| `Приёмник ТВ готов` | `ТВ готов к приёму` | Only on current readiness confirmation |
| `Доступ к записи экрана` | `Разрешить запись экрана` | Button opening macOS permission flow |
| `Принято декодером кадров: 2132 · пропущено до передачи: 31` | `Принято: 2 132 кадров · Пропущено: 31` | Under `Технические данные`, if telemetry is real |
| `История показаний и доставки команд · последние 30` | `История проверок` or `История команд` | Separate those two concepts if both exist |
| `Нет замера` | `Нет данных` | No measurement, not zero or failure |
| `Обновить показания` | `Проверить` or `Обновить данные` | First run vs refresh distinction |
| `Снять диагностику` | `Проверить сейчас` | An actual supported diagnostic run |
| `Выберите устройство в состоянии device` | `Выберите подключённый телевизор` | ADB state is advanced detail |
| `Снимок` | `Снимок экрана` | Identifies the artifact |
| `Открыть` | `Открыть снимок` / `Открыть на ТВ` | Clear object and destination |
| `Обновить устройства` | `Найти телевизоры` | Device discovery action |
| `Проверить соединение` | `Проверить подключение` | Consistent user terminology |
| `Включить ввод с Mac` | `Ввод с Mac` (toggle/mode) | Show current on/off state |
| `Быстрый / Резервный ADB` | `Быстрый ввод / ADB (резерв)` | Advanced method setting; explain when needed |
| `720p / 30` in global header | Hide, or compact `720p · 30 кадр/с` in Screen | Don't show ambiguous global debug info |

## Status vocabulary (shared state machine UI)

| State | UI text | Color | Interpretation |
|---|---|---|---|
| Offline | `Не подключено` | muted | No current confirmed connection |
| Discovering | `Поиск телевизора…` | neutral | Actively looking |
| Connecting | `Подключение…` | neutral progress | Ongoing handshake |
| Awaiting TV approval | `Подтвердите подключение на ТВ` | warning/info | Explicit user step |
| Connected | `Подключено` | success | Confirmed device connection NOW |
| Ready to stream | `Готово к трансляции` | success/neutral | Receiver/capture prerequisites satisfied NOW |
| Streaming | `Трансляция идёт` | success | Active verified session |
| Stopped | `Трансляция остановлена` | neutral | Not active |
| Partly functional | `Доступ ограничен` | warning | Specific feature unavailable |
| Failure | `Не удалось подключиться` | danger | Action failed; provide recovery |
| Never measured | `Не проверено` | muted | Test not run |
| Measurement unavailable | `Нет данных` | muted | No valid reading |
| Unsupported | `Не поддерживается` | muted | Explicitly unimplemented or not supported by TV |
| Stale | `Данные устарели` | warning/neutral | Older reading, not live |

**State composition:** icon/dot + short text; add an honest timestamp (`Обновлено в 12:46`) if cached, and actionable detail when not connected. Avoid “Норма” until rule and measured evidence exist. Don't show `Подключено` and `Нет соединения` concurrently due to uncoordinated polling; separate ADB connection state vs stream session if both exist.

## Diagnostic confidence levels: what may legitimately be said
Every diagnostic field should have: `name`, `status`, `source`, `observed_at`, `value` (possibly null), `unit`, `explanation`, `action`, and optionally `raw_evidence`. Use the same domain model for list, detail and export so no contradictory text. Do not fabricate data.

**No measurement**: value null, status `Нет данных`, no color implying success, optionally `Обновить`. **Action sent, no confirmation**: label `Команда отправлена` with a timestamp; not `Функция работает`. **ADB command acknowledged**: `Команда выполнена` when response indicates it, but not `звук воспроизводится`. **End-user manually confirms audible playback**: `Звук подтверждён пользователем` and identify time/method; never attribute this to automated instrumentation. **Timeout**: `ТВ не ответил` and recovery. **Unsupported**: disable unavailable detail/report at source, do not invent placeholder `0`.

### Detailed audio diagnostics blueprint
Group `Звук` with at most four focused rows:
- `Громкость` → reported `45 %` only if Android TV actually returns an audio stream volume; otherwise `Нет данных`; avoid percentage if only integer steps without known max.
- `Без звука` → `Включён`/`Выключен` only when queried; if we only sent a mute toggle, display `Команда отправлена` until refreshed/confirmed.
- `Аудиовыход` → `Динамики ТВ` / `HDMI` etc *only if output route is actually queryable*; else omit row or mark unavailable in details.
- `Проверка воспроизведения` → optional `Воспроизвести тестовый звук` **only** when implemented with real sound; guide user to confirm hearing it; never automatically mark successful sound from key events.

Example compact result for actual command-only check:
`Звук · Управление громкостью — Команда отправлена. Подтверждение воспроизведения недоступно.` No misleading green `Звук в норме`.

### Detailed connection diagnostics blueprint
Inspect separately if supported: ADB socket reachability; authorization (`unauthorized` state), command responses, connectivity delay only via timed operation, stream receiver handshake (different from ADB). Present `Нет ответа`, `Нужно разрешение на ТВ`, `Соединение установлено`, `Данные устарели`. If unreachable: give one concrete next step `Проверьте питание и Wi‑Fi ТВ` plus `Повторить`.

### Detailed picture diagnostics blueprint
Only report actual stream pipeline events: selected resolution/target FPS ≠ real received FPS. Distinguish `Задано`, `Отправлено`, `Принято декодером`, `Отображено` (last one requires proof/telemetry). Dropped-before-send and decoder drop are different counters. On idle stream use `Нет активной трансляции`, not empty successful graph. Don't label screenshot as live video.

### Detailed system diagnostics blueprint
Report CPU/RAM/storage only when collected and with provenance, unit, timestamp. E.g. `Память: 620 МБ из 1 024 МБ` if measured, else `Нет данных`. OS/version/model not a sensor reading. Avoid fabricated `Температура`, `Здоровье: 97 %`, trend graphs when no time series exists. Separate manager diagnostics from TV diagnostics clearly, e.g. `Mac: …` vs `Телевизор: …` if both.

## Writing short errors and recoveries
- `Не удалось подключиться` → `Убедитесь, что ТВ и Mac в одной сети.` `[Повторить]`.
- `Ожидаем разрешение` → `Подтвердите запрос на экране телевизора.`
- `Нет доступа к экрану Mac` → `Разрешите запись экрана в настройках macOS.` `[Открыть настройки]`.
- `Проверка прервана` → `Часть данных не получена.` `[Повторить]`.
- `Приложения недоступны` → `Подключите телевизор, чтобы открыть список.` `[Подключить]`.
- `История пуста` → `Проверок пока не было.` `[Проверить сейчас]`.

A successful low-level operation must not conceal an unresolved higher-level problem. More verbose instructions are allowed in **Help, recovery sheet, or advanced details** — not permanently on the main canvas.
