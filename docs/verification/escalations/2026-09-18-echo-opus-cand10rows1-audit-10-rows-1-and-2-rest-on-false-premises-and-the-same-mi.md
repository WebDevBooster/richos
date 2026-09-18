# Escalation: Audit-10 rows 1 and 2 rest on false premises, and the same misreading has now cost three audits

- id: `esc-20260918T211335Z-1af916b9`
- raised: 2026-09-18T21:13:35Z
- from: echo-opus-cand10rows1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-cand10rows1` (branch `cc/echo-opus-cand10rows1`)
- head: `59c7e74f2c12342eacda6d6515e7b82d630e441e`
- state: **work-complete**
- for: lead

## The question

Both rows are closed as named defects rather than as the defects they were briefed as. Rows 1 and 2 asked me to change the product; the measurements say the product was right and the AUDIT was reading the wrong surface and the wrong instrument. Does the lead want that fed back to Ray before the next walk, and does the CEO want to rule on the one product question underneath row 1 - whether the HOME screen should get an off switch of its own, which his 2026-09-01 ruling currently says no to?

## What was already tried

Row 1: re-derived in WebKit across five launch shapes. The Settings switch governs the 3-second CURTAIN (splash.js) and obeys it every time - durable OFF draws no curtain node at all. The screen in Ray's frame 52 is the HOME screen (home.js), which carries Talk to Rich, Enter, CUSTOMERS, CAPITAL - none of which exist on the curtain - and has never had a switch, by the CEO's ruling of 2026-09-01 that it must be shown after the splash screen. Ray's exact scratch-home shape reproduces the confusion: durable ON, shared WebKit mirror says false, so the curtain correctly draws and the Settings row paints OFF. Row 2: ran the native front-door harness against candidate .10's own bundle, same window, one line different. cliclick kp:return - door 174x52 before and after, FAIL, Ray's finding reproduced. System Events key code 36 - door 174x52 then gone, PASS. Return opens the door; the failure is the instrument, which Ray's own caveat predicted. The accessibility half of row 2 is the deliberate design landed in 7ed03c68 one day earlier in answer to Ray's audit-8 row 3, pinned by front-door.js A3 whose comment says in as many words that it exists so the next walk does not re-open it.

## Proceeding meanwhile

All five rows are committed on cc/echo-opus-cand10rows1. Rows 3, 4 and 5 were real and are fixed with red-first checks. Rows 1 and 2 are closed with the name fixed (Opening screen -> Splash screen, both doors) and with the first native measurement of Return on the shipped window, plus checks that refuse the literal fix each row asked for.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T211335Z-1af916b9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T211335Z-1af916b9 --disposition "<what you decided or did>"
