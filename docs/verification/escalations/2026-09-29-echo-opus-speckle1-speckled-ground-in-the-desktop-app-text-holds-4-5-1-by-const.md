# Escalation: Speckled ground in the desktop app: text holds 4.5:1 by construction, but two non-text indicators fall under 3:1 against the strongest single speckle pixel in light mode

- id: `esc-20260929T102757Z-353f9b9e`
- raised: 2026-09-29T10:27:57Z
- from: echo-opus-speckle1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-speckle1` (branch `cc/echo-opus-speckle1`)
- head: `6a29378d963652e099918a96bc617a4df20b4be1`
- state: **proceeding**
- for: lead

## The question

For NON-TEXT indicators on the speckled ground (control borders, the mark), which measure applies: the worst single device pixel (as the design system uses for text), which would need the light glitter cut by about a third (gold cap 0.3795 to 0.2596) to hold --line-control and by about three quarters to hold the mark's gold swoosh; or the average adjacent ground, under which both clear 3:1 unchanged? This is a design-system question (the engine only guarantees text pairs), not an app-integration one.

## What was already tried

Integrated the design system's desktop preset exactly (richos branch cc/echo-opus-speckle1). Text: every app text token that can sit on the ground is passed as extraTextPairs; light caps re-solve 10% lower because --attention #8c4a1b was 4.500 at the preset caps; the browser suite measures 106 rendered text nodes on the ground, worst 4.69:1 dark, 4.52:1 light. Non-text, engine arithmetic against a point at its cap: light --line-control #767c8d 3.35:1 plain, 2.93:1 on the strongest point; light mark swoosh #9c7c34 3.15 plain, 2.76 on the strongest point; dark --line-control 4.57 plain, 3.52 on the point (passes); dark --trim #4c6087 is already 2.94 plain (design-system GAP 1), 2.26 on the point.

## Proceeding meanwhile

Shipping the design system's chosen look unchanged (no cap cut for non-text), with the numbers above in the handoff, and proceeding to the real-app check in the test VM.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T102757Z-353f9b9e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T102757Z-353f9b9e --disposition "<what you decided or did>"
