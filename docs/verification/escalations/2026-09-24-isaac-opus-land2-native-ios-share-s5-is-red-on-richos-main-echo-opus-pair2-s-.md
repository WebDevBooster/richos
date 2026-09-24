# Escalation: native-ios-share S5 is red on richos main: echo-opus-pair2's PWA v2 (c5250dc9) changed the tree §76 preserves

- id: `esc-20260924T024907Z-d94e133c`
- raised: 2026-09-24T02:49:07Z
- from: isaac-opus-land2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-land2` (branch `cc/isaac-opus-land2`)
- head: `ef243e80abf9870255e76bd712682f5a8f30821f`
- state: **work-complete**
- for: lead

## The question

Was changing richos/web/web-app (app.js, index.html, lib/api.js, lib/fingerprint.js) in c5250dc9 authorized under §76's 'preserved as is for now'? If yes, S5's baseline tag preserved/mobile-ios-and-pwa-2026-09-22 needs a reviewed move; if no, the PWA change needs reverting. Either way native-ios-share cannot pass on main until one happens.

## What was already tried

Ran native-ios-share on cc/isaac-opus-land2: S1-S4 and S6 pass; S5 fails naming those four files; git log preserved-tag..HEAD on that tree shows only c5250dc9; git diff main HEAD on richos/web, richos/mobile/ios and richos/mobile/ui is empty, so this branch adds nothing to it.

## Proceeding meanwhile

Left S5 untouched; it is not an iPhone-branch change.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T024907Z-d94e133c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T024907Z-d94e133c --disposition "<what you decided or did>"
