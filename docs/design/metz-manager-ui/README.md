# METZ Manager UI Skill v2.0

This is a reusable Codex/agent design-system skill for the METZ Manager macOS application.

## Installation (project-local)
Copy the whole `metz-manager-ui` directory to your project's `.agents/skills/metz-manager-ui/`, keeping all `references/` and `assets/` files. Invoke it in Codex with: `Используй skill metz-manager-ui и обнови дизайн страницы «Экран», сохранив текущие функции.`

If you also use an `AGENTS.md` at the repository root, add a small project-specific reminder: `For METZ Manager UI modifications, load .agents/skills/metz-manager-ui/SKILL.md and follow the references.` Do not paste the entire guideline into every prompt.

## Contents
- `SKILL.md` — triggers, overall rules, workflow.
- `references/01-design-tokens.md` — design colors, type scale, spacing, geometry and responsive layout.
- `references/02-components.md` — buttons, remote, forms, dropdowns, menus, tables, app list and feedback.
- `references/03-pages.md` — actual page structure and supported workflow principles.
- `references/04-copy-diagnostics.md` — wording changes, statuses, truthful audio/video/system diagnostic semantics.
- `references/05-implementation-qa.md` — migration checklist, keyboard support, responsive quality gates.
- `assets/metz-tokens.css` — a starter CSS variable file. Adapt to your actual app stack.

**Note:** This package defines UI rules; it does not automatically modify or install anything in your local repository.
