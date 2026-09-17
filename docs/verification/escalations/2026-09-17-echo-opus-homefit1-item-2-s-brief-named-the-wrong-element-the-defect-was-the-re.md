# Escalation: Item 2's brief named the wrong element; the defect was the renderer's quiet pass, and a text shadow could not hold the floor

- id: `esc-20260917T081744Z-381c31d4`
- raised: 2026-09-17T08:17:45Z
- from: echo-opus-homefit1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-homefit1` (branch `cc/echo-opus-homefit1`)
- head: `30ffa8d1797b4b1d00ba8a04996e4542a3d19b79`
- state: **work-complete**
- for: lead

## The question

Do you accept the two departures from the brief's prescribed shape — the fix landing in field-engine.js's quiet pass plus a line-sized plate rather than a text-shadow on #home-note-line — and the blind-path fallback dropping from 1400x880 to the declared 1024x700?

## What was already tried

Reproduced before writing anything: home.js:348's #home-note-line is the FIRST-RUN BANNER (a standing sentence, CEO 2026-09-01), not a temporary line; the temporary lines are #home-ticker, written by field-engine.js's landSpark. The shadow was not CSS at all but the renderer's quiet pass, and it had two independent causes, neither of which the brief's hypotheses named. Measured on a 2px lattice over the right half at 1440x900, erased px before/up/after: 57,564 -> 110,928 -> 123,432. A text-shadow was tried first because it is his literal wording and measured 1.19:1 ink / 1.00:1 gold at the line box's corner over a bokeh lobe, twelve frames out of twelve. Also: his sentence in item 3 never contains the word 'opens' that the brief told me to read literally, and the quoted fallback line the brief attributed to docs/hardware-choices-2026-09-10.md is actually gui-boot.test.sh:436.

## Proceeding meanwhile

Both items are complete, tested and committed on cc/echo-opus-homefit1; every departure is recorded in the commit messages and in two docs/verification records.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T081744Z-381c31d4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T081744Z-381c31d4 --disposition "<what you decided or did>"
