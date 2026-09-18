# Escalation: The technical view's labels are 11px, under CEO section 15's 14px floor, and no check has ever counted them

- id: `esc-20260918T211347Z-d7e05a01`
- raised: 2026-09-18T21:13:47Z
- from: echo-opus-cand10rows1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-cand10rows1` (branch `cc/echo-opus-cand10rows1`)
- head: `59c7e74f2c12342eacda6d6515e7b82d630e441e`
- state: **work-complete**
- for: ceo

## The question

Section 15 says nothing readable sits below 14px, and 14px is the floor for text that is SKIPPABLE. The technical view's command labels are 11px (0.6875rem). Raising the ink fixed their contrast and does not make the size compliant. Does the CEO want them at 14px - which reflows the technical view and makes it noticeably bulkier - or does he rule that these labels are exempt as a technical readout he opted into?

## What was already tried

Measured on the acme fixture under WebKit: .tl-tech-title is 0.6875rem = 11px, and the same token measures 4.99:1 at 14px upright and 4.36:1 at 11px italic because antialiasing over thin slanted small strokes never reaches the declared color. That is what made Ray's row 4 numbers real. I raised the ink to --ink-tech 0.75 so the rendered glyph now measures 6.28:1 light and 7.49:1 dark, and added contrast.js check 17 which holds both the declared and the rendered column. The SIZE is untouched. It is also invisible to every existing guard: appearance.js check 12 enumerates only the PIXEL font-size declarations and reports smallest 14px, so a rem value under the floor has never been counted at all - that gap is worth closing whichever way the size question is answered.

## Proceeding meanwhile

Row 4 is committed and green. Nothing else in my five rows depends on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T211347Z-d7e05a01`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T211347Z-d7e05a01 --disposition "<what you decided or did>"
