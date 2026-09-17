# Escalation: Rows 5 and 9 are built and tested; the two window-and-quit acceptance steps need a screen this Mac does not have free

- id: `esc-20260917T214008Z-28032960`
- raised: 2026-09-17T21:40:08Z
- from: echo-opus-resident1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-resident1` (branch `cc/echo-opus-resident1`)
- head: `64c3620360a0b49c2b4b270be6f1007318f5b0c6`
- state: **work-complete**
- for: lead

## The question

Who walks §7.4 and §7.4a on screen — a QA seat with accessibility permission and a free screen, or does the packaged nightly's own walk cover it?

## What was already tried

Checked before running anything and again at the end: pgrep shows 42051 ./RichOS.app/Contents/MacOS/richos-tauri, ppid 1, started 22:38:06, cwd .../scratchpad/richos-qa-cand6, and System Events reports it frontmost — the candidate-6 audit is live on screen. Walking 7.4 needs the opposite of an accessory boot (§2.4b: a double-clicked bundle or RICHOS_ACTIVATION=regular), and that branch takes the screen by construction. Independently, 7.4's Dock-icon click and 7.4a's Cmd-Q are clicks on macOS chrome, which need System Events with accessibility permission to post; this session can run osascript for a read and that is not the same permission. What I DID walk, on the real binary under a temp HOME with no screen touched: §7.7 end to end — a seeded running receipt plus an orphan grant, boot 1 reports '1 assignment(s) unknown until re-witnessed; 1 orphan grant(s) closed', the receipt reads unknown with the honest sentence, kill -9, boot 2 is classified crash-restart and reports 0 (nothing restarts, nothing is said twice), and a blocked receipt is left as recorded.

## Proceeding meanwhile

Everything else is done and committed: cargo test -p richos-core 661 green, cargo test --bin richos-tauri 118 green, cargo check clean, the quit-question suite 5/5 with contrast computed in both themes (worst 4.72:1), affordances/docs-claims/control-names/dialect/escape green. The record at docs/verification/two-riches-window-and-recovery-2026-09-17.md states exactly what is unobserved and does not claim the walk will pass.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T214008Z-28032960`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T214008Z-28032960 --disposition "<what you decided or did>"
