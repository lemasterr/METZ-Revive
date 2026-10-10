# 05 — Migration plan, interaction completeness and quality gates

## Implement in phases (minimize regression risk)
### Phase A: audit
- Map existing view hierarchy, route labels, device selection and state, backend commands, stream lifecycle, diagnostics scripts, ADB method toggles, permissions, keyboard input, histories and settings.
- Record screenshots and UI behavior in each meaningful state: disconnected/connected, remote, cast ready/streaming/failure, diagnostics missing/collected, dropdowns open. Inventory every visible action before redesigning.
- Separate supported, partially supported, currently unavailable capability. In the new interface label accordingly; do not silently drop or fake.

### Phase B: shared foundations
- Centralize semantic color/spacing/type/radius tokens and status vocabulary. Make `AppShell`, `DeviceSelector`, `ConnectionStatus`, `Sidebar`, `Button`, `Input`, `Select`, `Menu`, `Disclosure`, `StatusRow`, `DataTable`, `InlineFeedback`, `EmptyState`, `LoadingState`, `RemoteControl` reusable components using the project's existing stack and naming conventions.
- Ensure window titlebar, safe area and content scroll semantics remain native-correct.
- Maintain one app navigation system; ensure focus & selection are distinct.

### Phase C: page refactors
1. **Пульт**: one integrated D-pad, meaningful toolbar, volume cluster, secondary function strip. Preserve every existing remote key action and input method.
2. **Экран**: collapse keys and debug counters; show primary capture/receiver readiness and one CTA with honest state. Integrate macOS permissions and active stream status.
3. **Диагностика**: tested categories and measurement status, concise result rows, diagnostic detail, reliable history table. Keep raw log behind disclosure.
4. **Приложения / Файлы / Настройки**: follow form/list patterns, do not invent data or supported capabilities.

### Phase D: verify and polish
- Verify full navigation, device selection, keyboard-driven remote, button loading/feedback, select overlay with long list, start/stop casting, request permissions, error recovery, diagnostics/no-data state, logs/details, all history actions.
- Type-check/lint/build/tests. Check application is performant with idle and frequent status refresh, and resource-constrained TV remains unaffected by manager UI decisions.
- Test both Russian long strings and English localization if present; do not break i18n keys or fallbacks.

## Component acceptance checks
**Buttons**: only one primary at a time per workflow; every button has action and hover/focus/pressed/disabled/loading; text is clear; destructive confirms appropriately.

**Dropdowns**: popup is not cut by scroll/overflow; selected checkmark; outside click and Escape close; arrows/Enter work; selected human label only; popover responds to right/bottom viewport edge; long lists scroll; device sublabels displayed separately.

**Inputs**: labels are visible, errors specific, long keys masked/copied safely, focus outlines not hidden, values not reset on unrelated renders.

**Tables**: column meaning obvious; status text not just dots; empty/loading/error; right-aligned numbers; no vertical grid; no horizontal clipping without available scroll or condensed columns. When clicking row, detail opens and keyboard focus returns on close.

**Remote**: no overlapping click targets; direction keys distinguish active press/focus, arrow keys operate only when appropriate; `Назад` not confused with media `Предыдущий`; no repeated command on rerender; device disconnection not silently ignored; controls sized for real window.

**Screen**: streaming button never suggests live if not; states reflect capture permission and receiver readiness separately; no unmasked pairing key; known quality values reported correctly; stop action clears active status and residual metrics are labeled historical; no fake real-time preview.

**Diagnostics**: every green/OK maps to actual evidence and a validity interval; sound not marked played on command ACK alone; `Нет данных` not shown as 0; missed/failed tests have action; metrics show time, units and source under details; connection/ADB/receiver states distinguished; history and raw log accessible without dominating main layout.

## Responsive test matrix
| Window (content concept) | Navigation | Main content | Supporting area |
|---|---|---|---|
| 1600×900 | 216px full nav | normal spacing; remote large | Optional ~320px rail |
| 1280×800 | full/nav as fits | fluid, same components | Collapsible if cramped |
| 960×720 | 64px rail or slim nav | primary action visible, content scroll | hidden behind disclosure |
| smallest supported | accessible | wrapping and scroll | no clipped actions |

Do not change the minimum macOS window size merely to avoid implementing adaptive UI. At 960×720 the remote center, sound and most-needed navigation must remain usable. QA must be on an actual running build whenever possible.

## Required output when implementation is requested
Provide: changed files; before/after summary; preserved behavior list; new controls and state flows; test commands and results; screenshots at reference+compact widths; known limits; no claims of tests not run. If a design-only task, clearly say no app code or live functionality was changed.

## Design review rubric (pass/fail)
- [ ] Global navigation not duplicated.
- [ ] Page establishes purpose within 2 seconds.
- [ ] Primary action visually obvious without 5 competing blue boxes.
- [ ] No more than one visually raised major region per ordinary page (exception real remote assembly/true preview).
- [ ] All page sections use shared spacing, tokens, typography, button and menu primitives.
- [ ] At 960px width there are no overlaps, cut-off controls, giant empty gaps or forced 16:9 cropping.
- [ ] All captions are consistent Russian with short, plain-language actions.
- [ ] Menus align to trigger, are scrollable, support keyboard and never clip.
- [ ] Every status is traceable to a measurement or connection confirmation.
- [ ] Diagnostics distinguish sent command vs actual observed outcome.
- [ ] TV preview explicitly indicates live vs cached; no fake live.
- [ ] Existing commands, pairing, permissions, stream and diagnostics continue working.
- [ ] Keyboard focus, disabled explanations, loading and errors all exist.
- [ ] Reduced motion, readable contrast and semantic accessibility are checked.

## Copy-paste agent request template
Use this skill for every future METZ Manager UI task. Inspect the current implementation and preserve functionality. Start by defining the content hierarchy, then implement shared tokens/components, refactor the requested view, and test at 1600×900 and 960×720. Use real connection and diagnostics data only, avoid card-island design and fake previews, provide clear Russian labels and show what tests were actually run. Read all five reference files before editing UI.
