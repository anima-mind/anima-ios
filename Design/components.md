# Anima — components

Dark only. Tokens in `design-tokens.json`. Every component is outlined, never filled; the accent is a line or a glow. One accent, no semantic reds.

## Standard patterns (use these; don't invent variants)
- **Primary action**: full-width outlined button, accent border, accentText label 500, h48, radius 8, pinned to the bottom of the screen. One per screen.
- **Secondary action**: text button, textMuted 14pt, centered under the primary; or, in a two-button row, the left button with border color.
- **Button rows** (cards, sheets): secondary left, primary right, equal width, h44.
- **Inline card action** (Try again, Raise budget, Open permissions): accentText 14pt text button, right-aligned, h44.
- **Back**: chevron.left 44×44 at top-left, accentText. Onboarding progress: 2px segments, accent for done/current, border for pending.
- **Sheet**: bottom sheet, radius 16, grabber 36×4, scrim 45%, enter 250 ms.
- **List container**: bordered radius-8 group, rows h48, hairline separators; trailing value 13pt textMuted, chevron or switch.
- **Switch**: 40×24, accent fill when on (knob = bg), transparent + border when off (knob = textFaint).
- **Chip**: 13pt, radius 16 (suggestion) or 6 (filter), border; selected = accent border + accentText.
- **Composer**: [camera 44] [field h44] [mic/send 44]. Mic turns into arrow.up when a draft exists. Listening state replaces the field with the 5-bar wave + "Listening…" + Done.
- **Conversational field**: any place the app needs user input (onboarding seed, later: goals, corrections). Anima asks one question at a time as a streamed mind message; the user answers with a suggestion chip, typed text, or voice; the answer appears as a user bubble; a summary card lists key · value when done; "Skip the rest" is always available. Never a bare textarea. Exception: API key (paste) and typed "delete" confirmation, where friction is the point.
- **Streamed mind message**: no bubble; optional thought line (chevron + "Thinking…" pulse → "Thought · first sentence"), then text with caret.
- **Empty state**: 17pt title + one 14pt sentence, textMuted, left-aligned, optional 28pt outline glyph. No illustration.
- **Motion**: enter 300 ms ease-out (6px rise), sheet 250 ms, caret 1 s steps(1), plasticity changes 600 ms. Nothing spins or bounces except the loading ring (3 s linear).

## Header
Body line (6px dot + "glasses connected" / "phone only"), optional "consolidating memory" spinner on the right. Below: screen title 24/500 left, plasticity badge right (tapping opens Mind sheet). Fading rule underneath.
SwiftUI: `VStack` in safe area; badge is a `Button` with `.buttonStyle(.plain)`.

## Plasticity badge
44×2 bar filled to p + `p 0.42 · adolescence`, accentText, 11pt tabular. Animates 600ms when cycles change.

## Mind sheet
Bottom sheet, radius 16, scrim 45%. Breath mark 104pt (amplitude = p) with `p 0.42` under it; headline "26 nights of consolidation"; regime sentence; formula in textFaint; key/value rows (body, last consolidation, live memories); text action "Disconnect glasses".
SwiftUI: `.sheet` with `.presentationDetents([.medium])`, `.presentationBackground(bg)`.

## Chat
- **User bubble**: surface fill, border, radius 8, right-aligned ≤80%. Optional photo thumb (160×110) or "voice transcript" meta line above.
- **Mind message**: no bubble. Order: thought line → text → (error | refusal card).
- **Thought line**: chevron (rotates 90° open) + "Thinking…" pulsing while thinking, then "Thought · first sentence". Tap expands full reasoning in a 1px left-ruled block, textMuted 13pt.
- **Streaming caret**: 2×15 accent bar, blinks 1s steps(1), only while streaming.
- **Error card**: border, label "Couldn't reach the model", body, text action "Try again". Message is never lost.
- **Refusal card**: border, label "Declined", body 15pt in full text color. Refusals are said plainly, with an alternative.
- **Composer**: camera (40×40 outlined) · text field (surface, border, radius 8, h40) · mic/send (accent outline; icon swaps arrow.up when draft exists).
- **Listening bar**: accent border, 5 staggered wave bars, "Listening…", text action "Done".

## Inbox card
surface, border, radius 8, pad 14. Label row: kind (accentText, uppercase) + meta (textFaint). Title 16/500. Body 13 muted. Optional **diff block**: rows `field | before (strikethrough) / after`. Actions: primary outline accent + secondary outline border, equal width, h40. Kinds: Proposal, Identity change, Inferred goal. Decided items move to a "Decided" list below (never vanish).
Empty state: tray glyph, "Nothing to decide.", one sentence.

## Memory timeline
Filter chips (all / episodic / semantic / procedural / reflection). Row: importance dot (6 + 1.2·importance px, accent glow ∝ importance) on a hairline spine; meta `TYPE · 7/10` + relative time; text 15pt. Invalidated: 55% opacity, strikethrough, "invalidated · reason". Revisions show "revises an earlier memory ↑". Tap opens **Memory sheet** (type · importance · state, text 17, detail, "Revised from" block, Invalidate/Restore + Close).
Newborn empty state: "No memories yet. Memories form when the phone charges."

## Settings
Grouped lists in bordered radius-8 containers (row h48, hairline separators). Sections: Model (API key masked · Keychain, monthly budget + 3px progress), Cost by turn type (label · bar · $), Permissions (Allowed / Off), Mind (cycles · p, Simulate one night, Replay onboarding).

## Onboarding (7 steps, back chevron + progress segments)
1 Tutorial: three bordered rows (glyph, title, one sentence). 2 Account: one sentence (identity for what's next — backup, shared plans; the mind lives on the phone), native Sign in with Apple button (.black, h48, radius 8, hairline) with "Not now" text button under it, always available; signed in = bordered row with check + name, primary "Next"; a Firebase failure shows a soft meta line, never blocks. 3 Provider: radio list (Anthropic, OpenAI, Google, On-device). 4 API key: monospace field, Paste action, status line (checking → valid/rejected), budget chips $10/20/40/100; Next disabled until valid. 5 Permissions: list with why-lines, 22pt check circles, "n of 7 allowed". 6 Glasses: radar animation while pairing, "Pair glasses" / "Not now". 7 Birth: conversational field, three questions (name, tone, ask-first), summary card, "Begin". Finishing sets cycles 0 and empties memory/inbox.

## Intro
Radial ground, Breath mark 180pt breathing (4 s), wordmark ANIMA 30pt tracked .08em, one sentence, primary "Give life to a mind", secondary "Restore an exported mind".

## Conversation mode (voice)
Full-screen overlay over Chat, radial ground. Top: body line left, × (44) right. Center: Breath mark 220pt = Anima's face, then phase label (11pt uppercase accentText) and the live text 20pt centered (transcript while listening, caption while speaking, caret while streaming). Phases and mark motion: listening = wave breathes 1.1 s + glow; thinking = wave still, glow pulses 1.6 s, label pulses; speaking = wave 0.6 s with the voice; done = 4 s idle breath. Bottom controls: keyboard (48, back to text) · main (72, accent ring: wave bars while listening, stop square while busy, mic when done) · mute (48). Hint 12pt under the controls. Exit writes both turns to Chat tagged "voice" / "spoken". Entry: mic button with empty draft, or the "conversation mode" chip. When glasses are connected the same audio plays there and the HUD shows the matching view.

## Tab bar
4 items (bubble.left, tray, circle.circle, slider.vertical.3) 22pt outline + 10pt label; selected = accentText, else textFaint; accent dot on Inbox when undecided items exist. Gradient fade from bg behind it.

## HUD (glasses)
No ground. Ink #e8f3ff with halo; label row 10pt uppercase + catalog glyph; body 15pt max 2 lines; hint 11pt inkMuted. Cards: Proposal (nod / look away), Answer (streams, "Full answer on phone"), Remembered (fades 4s), Attention (offline, kept message).

## Icons
SF Symbols, Light weight, monochrome; hierarchical rendering only for the Breath mark. Selected state by color, never fill.
