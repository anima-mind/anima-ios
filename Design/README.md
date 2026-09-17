# Anima iOS — design handoff

Open `Anima.dc.html` in a browser (needs the sibling files; keep the folder intact).

## Files
- `Anima.dc.html` — the design board: prototype, onboarding, conversation mode, core surfaces, edge cases, mark/icon, widgets, glasses views.
- `Anima Screen.dc.html` — the interactive app prototype (all screens, one component; `scenario` prop selects a start state).
- `Anima Glasses.dc.html` — HUD views for Meta Ray-Ban Display as DAT SDK 0.9 component trees (click to walk the state machine; tree shown beside each view).
- `design-tokens.json` — color, type, spacing, radius, motion, plasticity formula, the Breath mark geometry.
- `components.md` — every component and standard pattern with measurements and SwiftUI mapping. Build new screens only from these patterns.
- `hud-projection.md` — glasses: model, icon mapping, state machine, view trees, checklist.
- `06-hud-design-guide.md` — the SDK constraints the HUD design follows.
- `CLAUDE.md` — project rules for the coding session.

## Rules in one breath
Dark only. One accent (#94bce3) as line or glow, never fill. SF Pro 400/500. Outlined buttons, radius 8, hit targets ≥44. Primary CTA full-width at bottom; in rows secondary left / primary right. Every input is conversational (Anima asks; chip, text or voice). Plasticity p(n) = 0.05 + 0.95·e^(−n/30) drives the badge, the mind sheet and the mark's amplitude.
