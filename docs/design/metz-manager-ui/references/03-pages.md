# 03 — Page-specific information architecture and interaction behavior

## Global shell (all pages)
```
┌─ macOS title bar / native controls ──────────────────────────────────────┐
│ Nav rail │ METZ_2K_TV  ● Подключено       [context action] [•••]       │
│          ├─────────────────────────────────────────────────────────────┤
│ Пульт    │ PAGE TITLE                                                  │
│ Прилож. │ main task/controls, result, supporting options                 │
│ Экран    │ ─────────── a rule only when necessary ───────────────       │
│ Диагн.   │ expandable technical details                                 │
│ ...      │                                                             │
└──────────┴─────────────────────────────────────────────────────────────┘
```
Do not render this as an array of framed cards. Sidebar and header stay consistent; do not mirror sidebar links again in the app bar. Device selection is a single shared control, not reimplemented per page. In short-height windows the *page content* scrolls.

## 1 — Пульт (Remote)
**Job:** quick, pleasant, reliable TV commands. This is the most visual, tactile screen; avoid replacing command precision with ornamental symmetry.

**Primary hierarchy**
1. Compact header: `Пульт`, optional status near device selector (already in global bar, so don't duplicate).
2. Quiet top toolbar: `Главная`, `Назад`, `Меню`, optional `Настройки ТВ` when supported. All visually linked as a group, **not individual thick bordered boxes**.
3. Central D-pad (one integrated object, meaningful arrow target zones and blue-accented center `OK`). Up/down/left/right hit areas do not overlap center.
4. Volume control (+, −) as one vertical cluster; `Без звука` beside or within cluster; optional channel cluster appears only if supported.
5. Media control strip with `Предыдущий`, `Пауза/Воспроизвести`, `Следующий` only when command semantics support it.
6. Bottom quiet utility strip: `Ввод с Mac`, `Приложения`, `Источник`, `Режим экрана` only where live.
7. Optional contextual device info: one slim right rail for wide window or collapsible section for compact. Don't require preview to make remote page usable.

**Modes:** `Пульт` vs `Ввод с Mac` may be a two-way segmented switch *inside the remote page*, not a duplicate global page. Show `Клавиатура Mac` toggle with short help only on first use / failure. Respect native modifier/key capture and focus in form controls; never globally intercept keyboard keys while typing.

**Errors:** transient message `Телевизор не отвечает` + `[Повторить]` / `[Подключить]`. Hold/long-press visual state on remote commands only if implemented. Do not promise that every TV key has a measurable acknowledgement.

**Layout at ~960px width:** hide optional device info rail, drop unsupported channel cluster and put extra utilities in `Ещё`; retain D-pad, volume, Home/Back/Menu without tiny targets. Single main stage should fit with normal scrolling if window is short.

## 2 — Приложения (Apps)
**Job:** find and open installed TV apps, optionally manage where actual APIs permit.

**Top:** `Приложения` + search field `Найти приложение`; refresh as icon/button if useful. One primary content region — list or calm adaptive grid.

**Row/tile:** actual app icon (no separate ornamental ring), name, optional package/version in expandable detail, `Открыть на ТВ` or a context menu for secondary supported actions. Filter `Установленные`/`Системные` only if data exists. Preserve keyboard selection and Enter-to-open.

**Empty states:** `Приложения не найдены` + `Обновить список`; if TV disconnected: `Подключите телевизор, чтобы увидеть приложения` + `Подключить`.

**Never:** inject sample Netflix/YouTube data, suggest app installs that are not implemented, turn every application into a huge individual bordered island, use streaming service logos as a static fake “TV preview”.

## 3 — Экран (Screen / Mac-to-TV)
**Job:** start, understand and stop a session with predictable quality, proper macOS permissions, and explicit receiver readiness.

**Header:** `Экран`. A single short subtitle is allowed if it distinguishes streaming from the remote. Don't show 5 rows of network IDs by default.

**Primary form on common 960px window:**
```
Экран                                 [Снимок экрана] (if real action)

Передача изображения
Режим                [Повтор экрана ▾]  (only if supported; 2 real modes -> segmented)
Экран Mac            [Встроенный дисплей ▾]
Качество             [1280 × 720 ▾]    Частота [30 кадр/с ▾]

Состояние            ● Готов к трансляции
[Начать трансляцию]  (becomes [Остановить трансляцию] while live)

Доступ Mac           ✓ Запись экрана разрешена   [Настроить] (if needed)
Подключение ТВ       ✓ ТВ готов к приёму         [Проверить]

▸ Технические данные    ▸ История трансляции
```

**Important: supported modes are not interchangeable**:
- `Повтор экрана` = mirror Mac content to TV; show only if stream pipeline supports.
- `Второй экран` = genuinely extended virtual display; show only if implemented and properly configured. The existing `Создать METZ Display` can live under the mode's configuration as `Создать виртуальный экран` if that is what it actually does.
- If only second display works, mode switch should not pretend mirroring is available. Show `Второй экран` as page's truthful existing mode.

**Single linear readiness flow:**
1. Choose input/output and quality; show only actual supported options.
2. If Screen Recording permission absent, primary CTA should be `Разрешить запись экрана`; clicking opens the correct macOS settings or documented OS flow. Clearly communicate that Mac permission is required, not TV access.
3. If receiver not ready, show `Подготовить ТВ` and `Ожидаем подтверждения на телевизоре`; if pairing confirmed, show `ТВ готов к приёму` only when currently confirmed.
4. CTA `Начать трансляцию` activates only when prerequisites met (or starts a guided preparation flow if that is the actual implementation).
5. While starting: `Подключение…` with progress. While live: prominent `Трансляция идёт` + duration, supported quality and `Остановить трансляцию`. Failed: short error + `Повторить` + `Подробности`.
6. After stopping: `Трансляция остановлена`. Do not keep stale `live` stats in green; place prior session under history if available.

**Status vocabulary:** `Не готово` (prerequisites missing), `Ожидает подтверждения`, `Готово`, `Подключение…`, `Идёт трансляция`, `Остановлено`, `Ошибка`. Do not claim “receiver running” based on old status. Avoid exposing long pairing hex key in normal layout; `Технические данные` expands `IP-адрес`, `Порт`, `Код/ключ`, `Скопировать`, receiver/encoder counters. Sensitive pairing token hidden by default. ADB status and stream status are separate.

**Advanced diagnostics if live data available:** elapsed time, actual resolution/FPS, frames submitted/received/decoded where individually measured, dropped frames, latency *with a source*, timestamp. Do not infer measured network latency from guessed assumptions.

**Design when disconnected:** one sentence `Нет соединения с телевизором` and one `Подключить` action rather than a disabled control sheet with a paragraph for every option.

## 4 — Диагностика (Diagnostics)
**Job:** user understands *what was tested, outcome, why it matters, next supported step* — with optional full technical evidence.

**Main page:**
```
Диагностика                       [Проверить сейчас]
Последняя проверка: 12:46 · 4 раздела

Все   Подключение   Звук   Изображение   Система  (tabs only if useful)

Подключение    [Не отвечает]  Команды до ТВ не доходят      [Подробнее]
Звук           [Не проверено] Не выполнялась проверка       [Проверить]
Изображение    [Нет данных]   Трансляция не запущена         [Подробнее]
Система        [Нет данных]   Показатели не получены        [Повторить]

▸ История проверок   ▸ Технические данные / журнал
```

**Do not create 4 equally massive colored cards.** Four calm rows or grouped sections on a single plane, with one meaningful status, one short result and one action per row. Category filter can be tabs if category-specific data is rich; do not add a second toolbar just to fill space.

**Sections / expected data model**
- **Подключение:** ADB state (`device` / unauthorized / offline / unreachable), responding to command, actual RTT only if measured, command success/timeouts, stream receiver reachable if independently measured; Wi‑Fi transport info only if supplied. Stale result labeled timestamp.
- **Звук:** current volume and mute state only if the OS reports them; whether command was sent/accepted if verifiable; audio output route only if query supported. A user-assisted playback test `Проверить звук` can show `Слышите звук на телевизоре? [Да] [Нет]` *only if test sound functionality exists*, and must label this as manual confirmation. Never infer “audible output normal” merely from volume command.
- **Изображение:** stream receiver, actual reported resolution/FPS, encoder/decoder pipeline if instrumented, dropped frames and errors with explicit counters/time windows. `Нет активной трансляции` if idle, not `Ошибок нет`.
- **Система:** supported CPU/RAM/storage, OS version, TV model, uptime; don't claim temperatures/percentages when not exposed by TV or APIs. For “Нет замера” show `Нет данных` and action `Проверить`, not `0 %`.

**Diagnostic run UX:** select TV → `Проверить сейчас` (show only checks that exist) → running progress per check `Проверка…` → completed summary with timestamp and individual result. **No unconditional `Норма`**: if data cannot be collected show `Нет данных`, plus an explanation. Avoid infinite spinner when ADB times out; retries limited/visible. Canceled runs should not be marked OK. `Проверить` for category reruns only its checks if supported, not necessarily everything.

**Detail drawer for category:** diagnostic heading, last observation time, method/source, compact test results, actual values and units, cause/recovery suggestion, `Повторить проверку`, `Скопировать отчёт` where implemented, optional raw log disclosure. Keep main screen plain and concise. Avoid technical jargon unless a user chooses Advanced.

**History:** one table `Время | Раздел | Проверка | Результат | Подробнее`; filter for error and recent events, preserve useful last 30 or configurable limit. `История проверок` isn't the same as `История доставки команд`: if both exist, maintain separate tabs inside a history subview, not a wall of raw text.

**Error examples:** `Телевизор не отвечает` → `Проверьте, что ТВ включён и подключён к той же сети` + `[Повторить]`. `Нет доступа ADB` → `Разрешите отладку на ТВ` + `[Открыть инструкцию]` if a real instruction is available. `Звук не проверен` → do not call it error.

## 5 — Настройки
**Job:** configure app/device, not a dump of debug primitives. Use a **form list** with dividers rather than cards.

Suggested sections only where relevant: `Устройство` (name / reconnection), `Управление` (keyboard arrows, ADB fallback), `Экран` (default stream quality only if supported), `Подключение` (pairing and permissions), `Дополнительно` (ADB path/port, logs, developer actions). Danger zone `Сбросить сопряжение` isolated at bottom with confirmation; never accidentally next to routine button `Обновить`.

Real settings use a visible label, control aligned consistently to right or below on narrow windows, one short help line only if not self-explanatory. Avoid inline full IP IDs and long credentials unless explicitly expanded.

## 6 — Файлы (when supported)
File transfer area uses a familiar **table/list**, not a hero gallery: `Имя | Тип | Размер | Состояние | Действия`. `Передать файл` is primary, if implemented; progress stays adjacent to the row, with failure/retry. Current transfer state must not disappear when navigating. If functionality does not yet exist, don't add this page merely to fill navigation.

## 7 — Device info (shared contextual details)
Present only if useful: device name, connection state, IP as optional subtitle, Android TV version, last seen, model when known. Use inline definitions/rows with right-aligned values, not one card per property. Use a compact menu `Действия с телевизором` for power/reboot/screenshots if supported; destructive power/reboot confirmations as appropriate. Do not require that right rail to be always visible on compact windows.
