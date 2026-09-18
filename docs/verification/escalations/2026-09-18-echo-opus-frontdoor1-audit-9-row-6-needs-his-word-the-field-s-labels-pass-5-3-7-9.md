# Escalation: Audit-9 row 6 needs his word: the field's labels pass 5.3-7.9:1 against the ground they sit on and fail against the nebula around them

- id: `esc-20260918T143512Z-f198ca29`
- raised: 2026-09-18T14:35:12Z
- from: echo-opus-frontdoor1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-frontdoor1` (branch `cc/echo-opus-frontdoor1`)
- head: `ff2c20512732ac32e6289fa562e71458a837e96d`
- state: **proceeding**
- for: ceo

## The question

For text drawn on the moving artwork, is the contrast floor measured against the halo the engine strokes under each glyph (5.27-7.85:1, passing) or against the nebula in the surrounding crop (2.99-4.46:1, failing)? Only the second reading calls for a change to round-11.1's composition.

## What was already tried

Computed both, on Ray's own frame 01-launch-window.png, with the WCAG formula and no eyeballing. Against the DARKEST GROUND WITHIN 4px of each glyph pixel — the halo main.js strokes at lineWidth 5 under every label — CUSTOMERS 5.27:1, REVENUE 7.02:1, CAPITAL 7.85:1, LEGAL & RISK 7.73:1, and the counts 1,318 5.80:1, 558 6.82:1, 362 7.20:1, 424 6.77:1. Against the crop's most-common value, which is what Ray measured, the same glyphs read 1.00-1.96:1. The algebra agrees: ink 223,228,238 at the resting alpha 0.86 over a halo 10,15,28 at 0.98*0.86 composited over PURE WHITE nebula is 7.60:1 for a name and 6.28:1 for a count, which is the worst ground on the screen.

## Proceeding meanwhile

Rows 1, 3, 4 and 5 are fixed and committed with checks; row 2 has its instrument and is blocked on an unlocked screen. I have changed nothing in the field's composition, because a scrim or plate behind every label is a visible change to a composition he ruled on, and 0.72 plate alpha is the minimum that would hold 4.5:1 over white.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T143512Z-f198ca29`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T143512Z-f198ca29 --disposition "<what you decided or did>"
