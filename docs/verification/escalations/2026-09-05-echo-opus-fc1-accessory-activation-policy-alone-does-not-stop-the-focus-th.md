# Escalation: Accessory activation policy alone does NOT stop the focus theft — measured, and the brief's likely mechanism is refuted

- id: `esc-20260905T234335Z-60ffbe9c`
- raised: 2026-09-05T23:43:35Z
- from: echo-opus-fc1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-fc1` (branch `echo-opus-fc1`)
- head: `6789e6dd8c2ea7a96d9b99a9446e46236e9b045c`
- state: **work-complete**
- for: lead

## The question

Nothing needs deciding; this is a record of two premises in my brief that turned out false, so nobody rebuilds on them.

## What was already tried

Built and booted the binary both ways with lsappinfo front sampled every 250ms. (1) tauri::ActivationPolicy::Accessory plus a window built .focused(false) STILL took the keyboard: richos-tauri frontmost for 22 of 24 samples. tao sends makeKeyAndOrderFront: to every VISIBLE window at applicationDidFinishLaunching and calls activateIgnoringOtherApps(true) unconditionally, and neither consults the policy or the requested focus (tao-0.35.3 app_state.rs:284-299, 432-453; app_delegate.rs:107). What works is building the window INVISIBLE plus the policy, ablated apart: invisible without the policy keeps focus but restores the Dock icon. (2) The brief said the contractor harness cannot be made to set a variable; it already sets two, RICHOS_TEST_DATA_DIR and RICHOS_OWNED_SELFTEST, and its own main.rs reads them. That was moot after the reframe, since the shipped rule identifies the installed launch positively and uses no variable, but the stated fact was wrong.

## Proceeding meanwhile

Work is complete and committed on echo-opus-fc1. Evidence, both probes and the four deliberate probe failures are at docs/verification/activation-2026-09-06/.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T234335Z-60ffbe9c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T234335Z-60ffbe9c --disposition "<what you decided or did>"
