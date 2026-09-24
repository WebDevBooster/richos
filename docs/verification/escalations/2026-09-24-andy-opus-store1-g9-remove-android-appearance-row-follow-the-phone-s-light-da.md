# Escalation: G9 (remove Android Appearance row, follow the phone's light/dark) contradicts CEO ruling §15

- id: `esc-20260924T004217Z-fccdcaf8`
- raised: 2026-09-24T00:42:17Z
- from: andy-opus-store1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-store1` (branch `cc/andy-opus-store1`)
- head: `d17008c911125d553243f860e705f543244b5078`
- state: **proceeding**
- for: ceo

## The question

For RichConnect, which rule holds: (a) CEO §15 as the Android code cites it today: opens dark on every phone, and the person can switch to light in Settings (keep a switch, get it into a mockup); or (b) Urban's G9: no switch, the app follows the phone's own light/dark setting, so a phone set to light opens light (overrides §15 for the phone apps); or (c) always dark, no light at all?

## What was already tried

Read richos-hq wiki/ceo-decisions.md §15 ('Dark is the default. A newly installed app opens dark. The user may switch to light at any time.'), Urban's audit fffe1d1d G9, and round 12.1 (app.html/app.css/NOTES.md): the mockup draws both themes and is silent on how one is chosen; 'follows the phone's system appearance' is Urban's inference, not the mockup's. Android MainActivity.kt and Sheets.kt cite §15 for the current dark-default-plus-switch design. iOS (Isaac) has the same question with its 'Light appearance' toggle.

## Proceeding meanwhile

Not touching the Appearance row or the theme default until this is answered; doing E1/E4/E5/E7/E8/E9, G1 and G10 now.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T004217Z-fccdcaf8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T004217Z-fccdcaf8 --disposition "<what you decided or did>"

## Answered

The CEO, relayed by the lead on 2026-09-24: "Follow the phone". Option (b). Android implements it at
`e6a853de` on `cc/andy-opus-store1`: no Appearance row, and the app, the share sheet, the system bar
icons and the launch window follow the phone's light/dark setting.
