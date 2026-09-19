# Escalation: The on-screen criterion 'one Escape at the home screen must leave the sheet on screen' contradicts the CEO's own Escape rule, and the state it names does not exist at entry

- id: `esc-20260919T180855Z-42fb07c3`
- raised: 2026-09-19T18:08:55Z
- from: echo-opus-offer2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-offer2` (branch `cc/echo-opus-offer2`)
- head: `d27c67e14da1a979a979d37d47b6811bde3aca8a`
- state: **proceeding**
- for: lead

## The question

Should Escape at the entry offer press 'Not now' (the CEO's 2026-09-17 rule, escape.js B1, setup.js case 14, and the original brief's own second clause), or do nothing (the added on-screen criterion)? I have built the first and cannot satisfy both.

## What was already tried

Measured on 4f2d57c9 and on cc/echo-opus-offer2 under WebKit, and about to re-measure on the real binary on screen: home.js's give-way hides the home screen the moment the offer opens (isOpen() false at +0 ms, fade done by +550 ms), and show() gives way again in the SAME task when the logo is pressed with the offer up. Every dialog in the window is an .overlay, so the give-way covers all of them. So 'the home screen with the sheet behind it' is not a state a person can reach at entry: the sheet holds the keyboard and #setup-sheet declares data-dismiss='control:#setup-later,#setup-close', which makes Escape press 'Not now'. Ray's Escape at candidate .16 spent the offer because focus had been dragged onto the composer by main.js:7721 — fixed in 327cbc7a — so his Escape reached a question his hand was not pointed at. With focus on 'Set it up' the same key is the named way out, under his eyes. I have ALSO built the floor the criterion is reaching for (d42a1ba4, escape.js B7): while the home screen holds the keyboard, Escape cannot answer a surface painted behind it.

## Proceeding meanwhile

Reporting the on-screen Escape result exactly as measured rather than forcing the criterion's shape, and finishing everything else: focus at entry, the harness regression tests, and the instance quit and scratch HOME deleted. A build where Escape at the offer does nothing would fail escape.js B1, which asserts every declared surface answers Escape.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T180855Z-42fb07c3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T180855Z-42fb07c3 --disposition "<what you decided or did>"
