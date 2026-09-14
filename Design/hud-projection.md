# Anima — HUD (Meta Ray-Ban Display · DAT SDK 0.9)

Source of truth: `uploads/06-hud-design-guide.md`. Everything below uses only that vocabulary. Visual mockups in `Anima.dc.html` §07 are illustrations of these trees, never the other way round.

## Model
- App runs on the iPhone; the glasses render a component tree. Every update is a full view swap. No animation, no streaming, no partial updates.
- Text: `heading | body | meta` × `primary | secondary`. Backgrounds: `.none | .card`. Buttons: `primary | secondary | outline`. Icons: catalog only.
- The system moves focus and paints it. System back gesture ends the session, so every non-root view has an app-rendered `Button("Back", outline, arrowLeft)`.
- Budget per view: heading ≤ 40 chars, body ≤ 200, ≤ 3 buttons, ≤ 4 interactive elements. Anything longer hands off to the phone.
- Display sleeps; the app re-sends the current view from state. No view may depend on an in-between moment.

## Icon mapping (catalog names)
proposal `bell` · confirm `checkmarkCircle` / `checkmark` · dismiss/cancel `x` · attention `exclamationTriangle` · calendar/goal `calendar` · answer `speechBubble` · declined `speechBubbleOff` · thinking `circle8RaysLarge` · back `arrowLeft` · glasses/mind `smartGlasses` · remembered `eye` · handoff `phone` · person `person`.

## Conversation (voice in, voice out)
Audio never touches the SDK. The phone records the glasses' mic (Bluetooth HFP), runs turn detection (pause ≈ 1.2 s ends the turn) and plays Anima's reply through the glasses' speakers. The HUD shows each stage as a full view:

```
Home ──Talk──▶ Listening ──(turn ends)──▶ Heard ──Send──▶ Thinking ──▶ Reply (speaking) ──Reply──▶ Listening
                  └─Cancel─▶ Home           └─Again─▶ Listening         └─Proposal─▶ Proposal · └─On phone─▶ Home
"remember that…" ──▶ Heard · note ──Keep──▶ Kept for tonight ──Done/Forget──▶ Home
Conversation · today (list of last turns, tap → Reply) · third card = handoff
```

Rules: the transcript is always shown before it is sent; the spoken reply is complete, the card is its gist (heading ≤40, body ≤200); what enters memory is shown before Keep; Declined and Offline are Reply-shaped cards with their own glyph; more than 3 turns ⇒ handoff. Icons: listening/speak `speechBubble` (there is no mic glyph) · speaking `speakerWithTwoArcs` · note/thread `threeDotSpeechBubble` · kept `eye`.

The mark on glass: Listening, Thinking and Reply carry one `Image(uri, 56×56)` at the top of the card — a static monochrome PNG of the Breath mark per state (listening mid-amplitude, thinking near-flat, speaking full). Three files total, cached after first send; no animation, no per-plasticity variants (the regime word in Home carries that).

```
Listening:  Back → Home · card(speechBubble · "Listening · pause to send" meta · body secondary hint) · "Cancel" outline x · ("Heard it" secondary — illustrative only; the phone advances this view)
Heard:      Back → Home · card(speechBubble · "Heard · 0:04" meta · Text("“…”", body)) · "Again" outline speechBubble → Listening · "Send" primary checkmarkCircle → Thinking
Reply:      Back → Home · card(speakerWithTwoArcs · "Speaking · 0:06" meta · heading · body) · "Reply" primary speechBubble → Listening · "Proposal" outline bell · "On phone" secondary phone
Note heard: Back → Home · card(threeDotSpeechBubble · "Heard · 0:09 · note" · Text("“…”", body)) · "Again" outline · "Keep" primary checkmarkCircle → Kept
Note kept:  Back → Home · card(eye · "Kept for tonight" · heading ≤40 · body consequence) · "Forget" outline x · "Done" secondary checkmark
Thread:     Back → Home · FlexBox(column) .none · row(threeDotSpeechBubble, "Today · 3 turns" meta) · 2 turn cards .onTap → Reply · handoff card → Handoff
```

## State machine
```
Home (root)
 ├─ Proposal ──confirm──▶ Confirmed ──done──▶ Home
 │      └──not now──▶ Home (stays in phone Inbox)
 ├─ Inbox ──▶ Proposal | Inferred goal | Handoff (identity → phone)
 ├─ [voice question, phone mic] ──▶ Thinking ──▶ Answer | Declined | Offline ──▶ Home
 └─ [camera capture] ──▶ Remembered ──keep/forget──▶ Home
```

## Views (trees)

```
Home:
FlexBox(column, spacing: 12, padding: all 16)
└─ FlexBox(column, spacing: 10, padding: all 12) .background(.card)
   ├─ FlexBox(row, spacing: 8, crossAlignment: center)
   │  ├─ Icon(smartGlasses, outline)
   │  └─ Text("Anima · adolescence", style: meta, color: secondary)
   ├─ Text("1 proposal waiting", style: heading)
   ├─ Text("Free 3:00–4:30 today. Two reminders overdue.", style: body)
   └─ ButtonGroup(alignment: start)
      ├─ Button("Proposal", style: primary, icon: bell) → Proposal
      └─ Button("Inbox", style: outline, icon: calendar) → Inbox

Proposal:
FlexBox(column, spacing: 12, padding: all 16)
├─ Button("Back", style: outline, icon: arrowLeft) → Home
└─ FlexBox(column, spacing: 10, padding: all 12) .background(.card)
   ├─ FlexBox(row, spacing: 8) ├─ Icon(bell, outline) └─ Text("Proposal · expires in 6 days", meta, secondary)
   ├─ Text("Schedule bank call + prescription at 3 pm?", heading)
   ├─ Text("Two 15-minute events. Nothing is booked until you confirm.", body)
   └─ ButtonGroup(alignment: end)
      ├─ Button("Not now", outline, icon: x) → Home
      └─ Button("Confirm", primary, icon: checkmarkCircle) → Confirmed

Confirmed:
FlexBox(column) ├─ Back → Home
└─ card ├─ row(Icon checkmarkCircle, Text "Booked" meta secondary)
        ├─ Text("3:00 Call the bank · 3:15 Renew prescription", heading)
        ├─ Text("Added to your calendar…", body)
        └─ ButtonGroup(end) └─ Button("Done", secondary, checkmark) → Home

Inbox:
FlexBox(column) ├─ Back → Home
└─ FlexBox(column, spacing: 8) .background(.none)
   ├─ row(Icon bell, Text "Inbox · 3 to decide" meta secondary)
   ├─ FlexBox(row) .background(.card) .onTap → Proposal   [Icon bell · Text body · Text meta]
   ├─ FlexBox(row) .background(.card) .onTap → Handoff    [Icon person · "Anima wants to change how it speaks to you" · "Identity change · on phone"]
   └─ FlexBox(row) .background(.card) .onTap → Inferred goal [Icon calendar · "Train three times a week?" · "Inferred goal · confirm"]
   (interactive: 4 = ceiling; more items ⇒ handoff)

Inferred goal: Back → Inbox · card(calendar · heading question · body consequence) · ButtonGroup(end): "Not quite" outline x → Inbox · "Confirm" primary checkmarkCircle → Inbox
Handoff:       Back → Inbox · card(phone · "This one needs the phone." · why) · ButtonGroup(end): "Back" outline arrowLeft
Thinking:      Back → Home · card(circle8RaysLarge · Text("thinking…", meta, secondary) · Text(heard question, body, secondary)) · "Cancel" outline x. Replaced by Answer/Declined/Offline as a full view.
Answer:        Back → Home · card(speechBubble · "Answer" meta · heading ≤40 · body ≤200) · "Back" outline · "On phone" secondary phone
Remembered:    Back → Home · card(eye · "Remembered · for tonight" · heading merchant · body detail) · "Forget" outline x · "Keep" primary checkmark
Declined:      Back → Home · card(speechBubbleOff · "Declined" · one-sentence refusal · the alternative) · "Back" outline
Offline:       Back → Home · card(exclamationTriangle · "Attention" · "Phone unreachable." · "Your message is kept…") · "Back" outline
Inbox empty:   Back → Home · card(checkmarkCircle · "Inbox" · "Nothing to decide." · one sentence) · "Back" outline
```

## Never on glass
Identity diffs (handoff), memory browsing, plasticity numbers beyond the regime word, API/budget details, anything over two body lines, any input other than a button.

## Checklist (from the guide) — all views above
root FlexBox ✓ · 7 components only ✓ · no invented colors/fonts/animation ✓ · catalog icons verified ✓ · Back on every non-root ✓ · ≤4 interactive, ≤3 buttons ✓ · no swipe/long-press/text input ✓ · reconstructible from app state ✓ · long content hands off ✓ · delivered as trees ✓
