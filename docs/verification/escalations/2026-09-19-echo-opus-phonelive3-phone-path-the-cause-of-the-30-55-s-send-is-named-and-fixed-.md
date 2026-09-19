# Escalation: Phone path: the cause of the 30-55 s send is named and fixed both sides, but the VM send-to-intake number is NOT measured

- id: `esc-20260919T232950Z-4dd1b8b8`
- raised: 2026-09-19T23:29:50Z
- from: echo-opus-phonelive3
- worktree: `/Users/alex/ab/richos-wt/echo-opus-phonelive3` (branch `cc/echo-opus-phonelive3`)
- head: `06af574bd73b36d893f1357d25aeea934669852e`
- state: **work-complete**
- for: lead

## The question

Does the VM number have to be measured before this lands, or does a Ray walk on the next nightly serve?

## What was already tried

Built an ad-hoc bundle at 86c19278 and booted it in test VM pl3 twice; the app renders and the tailnet certificate is in hand. Driving the Mac's OWN sheet to a pairing code failed: the webview's AXPress does not fire the settings row's handler (the walk finds '5|AXMenuItem|Use Rich from your phone' and pressing it reports clicked while the sheet never opens), so no code could be produced and nothing could pair. A Node client that loads lib/api.js and lib/queue.js verbatim and reproduces the sw.js shell burst is written and ready; it needs one pairing code and nothing else.

## Proceeding meanwhile

Every item is red/green in the harness: cargo test --bin richos-tauri 331 pass 0 fail; richos-core 58 suites 0 failures; richos/web/web-app 178 pass 0 fail; ui/tests phone.js, contrast.js, settings-fit.js and second-mouth.js all exit 0.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T232950Z-4dd1b8b8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T232950Z-4dd1b8b8 --disposition "<what you decided or did>"
