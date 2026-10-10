# 01 — Design tokens, spacing, color, typography and layout

## Design intent
Graphite utility: a flat, contiguous dark canvas, compact left navigation, a slim shared device header, readable page title, controlled hierarchy. **Use spacing instead of card borders.** Only the physically grouped remote and actual preview may attract stronger focus. No blue swirl background, no glowing random ornaments, no saturated gradients behind content.

## Semantic colors (dark mode v2)

| Role / token | HEX or value | Usage |
|---|---|---|
| `--bg-app` | `#0C1118` | Primary continuous canvas |
| `--bg-sidebar` | `#101720` | Quiet navigation region |
| `--bg-elevated` | `#17212D` | Menus, controlled remote groups, popovers |
| `--bg-hover` | `#1F2B39` | Hover background |
| `--bg-pressed` | `#26364A` | Pressed controls |
| `--border-subtle` | `#26313E` | Important hairlines, never box everything |
| `--text-primary` | `#F4F7FA` | Page titles, values, essential actions |
| `--text-secondary` | `#B9C4D0` | Labels, supporting text |
| `--text-muted` | `#8D9BAA` | Timestamps, tech meta, hints |
| `--accent` | `#6EA8FF` | Selected state, primary action, key remote focus |
| `--accent-soft` | `rgba(110,168,255,.12)` | Selected sidebar/background tint |
| `--accent-pressed` | `#90BBFF` | Active interaction emphasis |
| `--focus-ring` | `#9AC4FF` | Keyboard focus |
| `--success` | `#4ED9A0` | Verified healthy / connected |
| `--warning` | `#F2C46A` | Degraded / caution |
| `--danger` | `#FF8088` | Error / destructive |
| `--info` | `#92B9ED` | Purely informative state |

**Semantics:** green only if verified, yellow for actionable warning, red for failure, neutral for unknown/unmeasured. Never indicate status solely by a color dot: pair with clear text and optional icon. Default body text contrast ≥4.5:1, important icons/borders ≥3:1. Test hovered/selected variants, not just static tokens. Avoid decorative color-filled success boxes.

## Spacing and sizing scale
An 8px grid with 4px half-steps:

| Token | px | Usage |
|---|---:|---|
| `space-1` | 4 | optical micro-gap |
| `space-2` | 8 | icon/text gap |
| `space-3` | 12 | compact input internal gap |
| `space-4` | 16 | normal element gap |
| `space-5` | 24 | inner section spacing |
| `space-6` | 32 | page padding and section separation |
| `space-7` | 40 | large gap only when needed |
| `space-8` | 48 | very rare major transition |

**Window baseline:** 1600×900 is for artwork/testing only, **not** forced macOS window ratio. Sidebar width 216px (acceptable 208–232), compact icon-only rail 64px; device app bar 60px height (account for native window drag/titlebar). Main padding 32px wide, 24px compact, 16px narrow. Typical section-to-section gap 32px; label-to-field 8px; form row gap 16px; table row 44px; sidebar row 48px. Keep forms to max ~840px width; don't stretch a short 2-column field pair across the window.

**Control size:** normal height 40px; compact 32px; large action 44px; click area for the important remote functions at least 40×40px. Chips/status tags around 24–28px in height only when not interactive. Don't make all buttons the same giant style.

**Radius:** input 8px; button 9px; popup 10px; grouped remote 14px; status chip 999px. Radius must not become a substitute for layout. 1px muted dividers only where they clarify grouping. No heavy drop shadow on regular items; only overlays use `0 12px 36px rgba(0,0,0,.32)`.

## Type scale
System macOS stack: `-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif`. Use existing SF system font rather than bundling licensed font files.

| Role | Font | Weight |
|---|---|---|
| App brand | 19px / 24px | 600 |
| Page title | 28px / 34px | 650 |
| Section title | 17px / 24px | 600 |
| Body / button label | 14px / 20px | 400–500 |
| Data/table | 13px / 19px | 400–500 |
| Secondary / help | 13px / 18px | 400 |
| Technical / timestamp | 12px / 16px | 400 |
| Large relevant metric | 24px / 30px | 600 |

Use `font-variant-numeric: tabular-nums` for metrics. Avoid paragraphs >2 lines outside help views. Do not truncate critical error messages without a way to expand. Russian localized strings have more width than English; test it.

## Icons, dividers, interactions
18–20px regular icons, 16px inline, stroke weight 1.75–2, consistent icon set. No emoji icons in interface; no ring around every installed application icon. Dividers should be ~1px muted and full-width only at true section changes. Motion: hover 120ms, menu/opening 170ms ease-out; respect Reduce Motion. No constantly moving glow, background animation or jitter when live numbers update.

## Responsive design
- **≥1400px:** 216px sidebar + main + optional contextual right area max 340px for Remote if useful. Right panel must show real data; no fake live feed.
- **1100–1399px:** sidebar ~208px, give main stage priority; optional rail collapses when needed.
- **900–1099px:** icon nav rail 64px when content needs space, contextual info collapses to accessible section; remote controller scales toward 220px.
- **<900px when window permits:** one content column and main-area scrolling; essential controls stay accessible. Show nav labels on tooltips and accessible name if rail compact.
- **Short window (≤720px):** allow content scrolling, avoid huge sticky areas or split controls over hidden fold.

## Global hierarchy
Global device bar (selector, honest connection status, contextual actions) → one page title → primary task → supporting data → advanced details. Do **not** repeat sidebar page links as tab buttons in the header.
