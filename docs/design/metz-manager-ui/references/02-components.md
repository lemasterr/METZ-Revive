# 02 — Component library and behavior specification

These components must be reusable across the whole METZ Manager app. Avoid page-local imitations of the same button/select/row.

## Global shell and navigation
**Window:** native macOS traffic-light controls and titlebar remain functional. Respect draggable regions. Do not put buttons below native window controls. Use window background `--bg-app`; sidebar `--bg-sidebar`; no enormous decorative radial overlays.

**Header:** selected TV (human name `METZ_2K_TV`) + status (`Подключено`, `Подключение…`, `Не подключено`) on left; on right maximum 1–2 contextual actions and overflow `Ещё`. IP/ADB port appear in device info, not in selector label. When no device selected, selector reads `Выбрать телевизор` and body provides a recovery path. Header keeps its placement on every page.

**Navigation:** only one global navigation scheme. Preferred left sidebar: 216px width, row 48px, 18px icon + 14px label, 8px icon/label gap; selected subtle accent tint and narrow left indicator; no vivid filled blue rounded box per item. Keyboard focus separate from selected. Bottom area can contain a one-line current device status, but don't repeat connection state four times. Compact 64px rail preserves accessible labels and informative tooltip.

**Content:** one main scrollable region. Vertical section gap 32px. Section headers 17px semibold, optionally one short secondary sentence; simple 1px divider where a line actually helps.

## Buttons and actions
| Variant | Use | Appearance |
|---|---|---|
| `primary` | One main job (start stream, connect, test) | Accent fill or quietly accented contour; 40–44px high; never 5 at once |
| `secondary` | Reversible supported actions (refresh) | Neutral elevated/hover fill, 40px high |
| `quiet` / `ghost` | Toolbar, inline link-like secondary actions | Transparent at rest; hover subtle, minimum 32px visual, 40px hit area if important |
| `destructive` | Unpair/delete/reset | Danger label/icon; confirm where irreversible; don't use for ordinary power button by default |
| `icon` | Recognizable simple utility only | 32–40px hit target; accessible name + tooltip |

**Text:** direct imperative: `Начать трансляцию`, `Остановить`, `Подключить`, `Обновить`, `Открыть на ТВ`, `Скопировать`, `Проверить звук`. Avoid `Осуществить`, `Произвести`, `Снять диагностику`, `Выполнить подключение телевизионного приемника`.

**Feedback:** default, hover, pressed, focus-visible (2px outline), disabled, loading; if latency >250ms show spinner/progress/optimistic feedback as supported. Disabled explains why via adjacent hint or tooltip. If a command can fail silently, show a meaningful result/timeout. Do not treat dispatch success as confirmed outcome.

**Grouping:** rows of 2–3 equal actions max in normal settings, then `Ещё` when actions share context. Keep power/restart in device actions, not duplicated globally and inside three panels. Never make huge square island buttons for every action.

## Remote controls (the functional visual centerpiece)
Compose from **five semantically grouped control areas**, not 20 floating cards:
1. **Quick navigation** `Главная · Назад · Меню` and `Настройки` only if real TV action exists; quiet inline toolbar, no heavy individual tiles.
2. **D-pad**: one unified circular assembly ~220–260px wide when space permits, ~200–220px compact. Four arrows form clear hit regions around centered `OK` (60–76px). Outer ring quiet; only focused/pressed region has blue. Keyboard arrows + Enter/Space act consistently if focus in remote area; avoid intercepting arrow keys while a dropdown or text field is active.
3. **Volume**: a single slender grouped vertical + / − controller, mute as adjacent smaller control or integrated cluster, not a separately outlined square. Press and hold optional only where supported.
4. **Channels**: optional group only if channel command actually works; can fold under `Дополнительно`. Not required to take symmetrical space with volume if device does not support it.
5. **Playback**: neutral `Назад 10с / Пауза / Далее` or actual key events supported. Group in horizontal pill/toolbar. Do not use icon labels that falsely imply seeking if commands are only KEYCODE_MEDIA_PREVIOUS/NEXT. `Ввод с Mac`, `Приложения`, `Источник` under lower quiet action strip or remote overflow.

Use meaningful button labels or hover tooltips, accessible name for every icon. No complex shadowed inner ring or glossy control face. Distinguish `Назад` (Android navigation) from `Предыдущий` (media) unmistakably.

## Form controls
**Text input**: 40px high, 8px radius, dark fill on continuous background, one quiet border on input only, 14px text, visible external label. Placeholder gives example, never serves as only label. Validation message below in plain language. IP, pairing token and serial use fixed-width digits if needed, text field copy button outside. Password/secret type hides contents until explicitly revealed; avoid exposing pairing keys in screenshots.

**Switch**: on/off property that changes immediately and can be rolled back; e.g. `Управление стрелками клавиатуры`. Label left, switch right. Don't use a switch for navigation or starting a lengthy asynchronous stream.

**Radio / segmented**: 2–3 mutually exclusive modes with short names; e.g. `Управление: Пульт | Ввод с Mac` if both modes truly exist. Selected pane muted accent-soft, no heavily raised islands. Keep text legible with icons optionally.

**Dropdown/select:** use when 3+ alternatives or long lists. Height 40px; label above; only selected human-friendly value inside with down-chevron right; `Выбрать…` if none. For device selector show `METZ_2K_TV`, status/subtitle inside list item, IP as secondary detail — never concatenate device name + `device` + `192.168...:5555` in trigger. Popover: `--bg-elevated`, 10px radius, subtle border, soft shadow only on popup, max height ~320px with internal scrolling, width ≥ trigger / min 220px, show checkmark on selection. Space for labels; don't clip at window edge — portal/overlay with adaptive placement, flip to top if needed. Popover not clipped by ancestor overflow. Auto-focus sensible; arrows navigate, Enter selects, Escape closes, type-to-search on long options, Tab moves focus, opening/closing returns focus appropriately. Searchable device list if many devices. Avoid separate confirmation button for normal select unless selection causes risky change.

**Menu/context menu:** descriptive verbs, logical grouping separated by sparse dividers. Danger item at bottom. Disabled item is visible with reason if useful; never display unsupported items as if they work. `...` affordance gets tooltip `Дополнительные действия`.

**Popover/tooltips:** for rare explanation, not a home for core steps; 200–300px text max, short. Tooltip delay ~400ms, no tooltip as exclusive source of required instructions.

**Accordion/disclosure:** default collapsed for `Технические данные`, `История команд`, `Подробности подключения`, `Дополнительные настройки`. Compact chevron and section label. Persist open/closed while navigating where helpful. Contents keep consistent 16–24px padding only if needed.

**Modal/sheet:** only for pairing, destructive confirmation, request for permissions that requires context. Clear title, 1–2 short sentences, primary and Cancel. No generic confirmation dialog for harmless toggles. Modal must support Escape and focus return.

## Data components
**Status row**: title / value / (optional) action; 44px minimum, 16px horizontal gap, subtle row dividers; no card per metric. Use `Нет данных` for not measured, `Не поддерживается` for missing capability, `Последнее обновление: HH:MM` for cached values, `—` in purely empty optional table cell.

**Diagnostics summary**: `Подключение: OK`, `Звук: Не проверено`, etc. Represent label and evidence. Do not use progress rings as invented “health percent”. For measured numeric stats display unit, timestamp and origin; update without full layout shift. One prominent result summary line and diagnostic categories as rows or compact tabs.

**Table**: reserve for repeating comparable records: diagnostic runs/history, ADB delivery history, app package/version list, transfer queue. Row 44px, header 36–40px with `--text-muted`, numeric data right aligned and `tabular-nums`, labels left aligned, no vertical grids, row separators only. On hover subtle fill; selectable row has focused treatment. Tables should support sort if it helps, search/filter where data volume requires, pagination or virtualized list for >100 rows. Sticky header only within actual scroll container, not for 4 entries. Column truncation with accessible full detail; status text paired with color/icon. Empty = explanation + next action; loading = quiet skeleton/inline loading; error = inline message + retry. Export actions in toolbar only when implemented.

**Example diagnostic-history table (not synthetic data):**

| Время | Раздел | Проверка | Результат | Действие |
|---|---|---|---|---|
| 12:46 | Подключение | Ответ ТВ | Нет ответа | Подробнее |
| 12:44 | Звук | Команда громкости | Команда отправлена | Подробнее |

Never label sent audio command `Звук работает`: those observations differ.

**Installed apps grid/list:** icon should be the real app icon without ring, bevel or decorative outlined tile; aligned with app name and supported `Открыть на ТВ`. Use no enormous padding or 16:9 art by default in a narrow manager list. Grid may adapt to actual app icon format. Search and filter operate on existing app data, no hardcoded fake catalog.

**Preview:** show only genuine TV screenshot or real receiver preview. Timestamp or `Снимок экрана · 12:46` when cached. If unavailable: `Предпросмотр недоступен` + actual supported action `Сделать снимок` if implemented. Never use stock background, invented TV app tiles or claim `В реальном времени` without a realtime transport.

**Feedback:** fixed compact toast bottom-right or inline result near action, only when event truly succeeded/failed; 3–5 sec for noncritical, persistent for unresolved problems. Preserve rich error details behind `Подробности`. Don't flood with one toast per remote key press.

## Accessibility / interaction
- Every clickable icon has accessible label; key actions have keyboard equivalent and focus states.
- Expose selected/expanded/disabled semantics programmatically.
- Use labels for inputs and table headings; avoid text embedded solely in images.
- Respect Reduced Motion and text zoom/dynamic type where supported.
- Do not trap focus in dropdowns or lose it after closing; tab order matches spatial reading order.
- Prevent accidental destructive actions with confirmation when needed; keep recoverable operations immediate.
- Selection via mouse and keyboard must yield the same device actions, with loading/ack/timeout distinction.
