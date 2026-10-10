---
name: metz-manager-ui
description: Design, implement, refactor, or review the METZ Manager macOS interface and its TV companion screens. Apply consistent navigation, remote-control, casting, apps, diagnostics, settings, buttons, tables, dropdowns, microcopy, a11y and responsive styling without breaking existing capabilities.
---

# METZ Manager — Product UI Skill
**Version 2.0 · 10 October 2026 · UI language: Russian.**

## Goal
Build a coherent, functional, refined **macOS utility**, not a Dribbble dashboard. METZ Manager controls an Android TV (METZ Display) through the features that already work: remote control, installed apps, screen streaming / second-display modes when available, diagnostics and device configuration. The TV itself has limited hardware (~1 GB RAM), so avoid unnecessary effects in TV-facing components.

**Visual direction:** dark graphite / blue-black, excellent typography and spacing, restrained blue interactive accent. Make one continuous surface. The navigation control on the Remote page may be visually distinctive; everything else should remain calm. No big gradient arcs, fake glass, glowing tiles, ornamental metric dashboards, giant icons or dozens of floating cards.

## Reference files — read before editing
1. [Design tokens, layout and typography](references/01-design-tokens.md) — fixed decisions about colors, dimensions, spacing, states.
2. [Component specifications](references/02-components.md) — buttons, menus, dropdowns, controls, tables, lists, feedback.
3. [Page blueprints](references/03-pages.md) — Пульт, Приложения, Экран, Диагностика, Файлы, Настройки.
4. [Copy and diagnostic semantics](references/04-copy-diagnostics.md) — exact interface labels and what diagnostic status can truthfully mean.
5. [Migration workflow and QA](references/05-implementation-qa.md) — implementation steps, tests, adaptive behavior, acceptance checklist.
6. [CSS token starter](assets/metz-tokens.css) — semantic tokens if the codebase uses CSS; otherwise map into native theme.

## Rules that override styling convenience
- **Preserve all behavior.** Inventory current actions, ADB flow, pairing, permissions, capture, stream start/stop, existing diagnostic commands before moving UI. Never remove a real capability just to simplify composition.
- **One navigation model** at a given width: sidebar preferred for desktop, or top tabs if that fits existing architecture, **never duplicate both**. Global header is for selected device and connection state, not a second set of page tabs.
- **One page = one clear primary task.** One strong button in the primary workflow, auxiliary controls neutral/ghost.
- **Do not build card islands.** Use section spacing and hairlines on a shared canvas. Raised surfaces only for physically grouped controls, dropdowns/dialogs, genuinely isolated preview.
- **Progressive disclosure.** Raw IP/port, ADB serial, pairing token, device ID, codec stats, dropped frames, full logs, debug history go into `Подробности`/`Технические данные`. Keep them accessible, copyable and searchable where appropriate.
- **Truthful live states.** Never mark green for unavailable data, stale connection or unsupported test. A command sent successfully is not proof that speakers emit sound. A frame submitted is not proof it appeared on screen. Distinguish `Не проверено`, `Нет данных`, `Подключено`, `Проблема`, `Недоступно`.
- **Keep copy short.** Destinations are nouns; command buttons start with verbs; description only when it helps decide or recover. Prefer Russian user-facing labels; reserve code terms for advanced details.
- **No fake live TV preview** when real screenshot/video pipeline isn't present. Label cached screenshots with timestamp; otherwise do not show preview.
- **No dead-end controls.** Every visible button performs a supported action, opens a meaningful view, or is clearly disabled with a reason; never invent unsupported AirPlay or casting paths.
- **Desktop is not a fixed 16:9 viewport.** Concept art is 16:9; the real macOS window can resize to ~960px wide. Keep controls readable and scrollable at compact sizes.
- **Performance.** No permanent glow animations, expensive layered filters, repeated canvas rerenders, or frequent measurement polling driven by decorative widgets.

## Mandatory workflow for UI changes
1. Inspect implementation + current screenshots, app state and supported commands.
2. List every action in the changed area; flag backend functionality not currently supported.
3. Arrange **main action → supporting controls → state/results → advanced details**.
4. Apply shared tokens/components before custom page styles; do not scatter hex values.
5. Rewrite all touched visible copy with vocabulary from references, including error/empty/loading states.
6. Implement mouse+keyboard interactions, focus, screen-reader labels, menus that don't clip, and actionable recovery text.
7. Validate at 1600×900, 1280×800, **960×720** and smallest supported window; fix clipping, overlap, scroll.
8. Build/test; verify an actual end-to-end action (remote command, stream session, diagnostic run) rather than relying on screenshot appearance.
9. State what changed, what stayed functional and what is still unknown or unimplemented.

## Preferred navigation and page responsibility
`Пульт` · `Приложения` · `Экран` · `Диагностика`; optionally `Файлы` if genuinely supported and `Настройки` for preferences and advanced configurations. Rare maintenance tools belong to a meaningful overflow/menu, not an additional equal-weight dashboard island.

- **Пульт:** prioritize direction pad / OK, Home/Back/Menu, volume/mute, media controls, keyboard input, optional channels.
- **Приложения:** installed apps, search, launch and app management only where supported.
- **Экран:** casting/virtual display, device readiness, macOS Screen Recording permission, connection details as secondary.
- **Диагностика:** observed metrics and test outcomes by category; accurate evidence, timestamps and error recovery. No fake synthetic health grades.
- **Настройки:** pairing, preferred input methods, display preferences and expert ADB settings.
- **Файлы:** transfers and browsing only when working.

## Explicit anti-patterns
Do not duplicate header/sidebar nav; don't place a border around every text row; don't force 360px right sidebar at 960px width; don't show raw keys by default; don't turn forms into pill-shaped card walls; don't stack long help paragraphs; don't rely only on green/red dots; don't visually promise features without code support; don't render a preview that looks live when stale; don't confuse a second Mac display with simple screen mirroring.
