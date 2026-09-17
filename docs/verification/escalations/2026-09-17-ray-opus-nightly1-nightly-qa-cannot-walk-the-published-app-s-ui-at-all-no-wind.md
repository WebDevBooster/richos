# Escalation: Nightly QA cannot walk the published app's UI at all — no window, and the only in-repo driver builds an instrumented copy

- id: `esc-20260917T035456Z-caf1fbb7`
- raised: 2026-09-17T03:54:56Z
- from: ray-opus-nightly1
- worktree: `/Users/alex/ab/richos-wt/ray-opus-nightly1` (branch `cc/ray-opus-nightly1`)
- head: `8fb8a9d0952253a88f33832110fabeda135e432e`
- state: **work-complete**
- for: lead

## The question

Which of these should exist before the next nightly: an RICHOS_ACTIVATION=offscreen value (accessory policy, window visible to the window server so screencapture works), a RICHOS_DEVTOOLS=1 CDP opt-in, or a second Mac/VM for nightly QA?

## What was already tried

Booted the published v1.2.0-nightly.20260917.1 bundle twice under a scratch HOME. Activation is accessory by construction because a harness must hold the process (getppid != 1), and main.rs:1205 then builds the window .visible(false). An invisible window has no window-server surface, so screencapture and the accessibility API both have nothing to address. README's only stated outs are window.show() (not callable externally) and RICHOS_ACTIVATION=regular (forbidden by brief; takes the CEO's screen). The repo's only real-IPC harness, scripts/native-responsiveness.test.py, rewrites main.rs and builds an instrumented binary - forbidden here and not the published bundle.

## Proceeding meanwhile

Audit committed covering everything reachable from outside: SHA256 verified, Developer ID + stapled notarization + spctl accepted, first-boot log on empty HOME, crash-restart detection, hot-mic invariant held with positive control, model pin re-verified against the live HuggingFace remote (size and sha256 both agree), updater endpoint and live manifest both 1.2.0-nightly.20260917.1 so it will not offer itself. Two low defects recorded. No blocking product defect found - but items 1-5's UI halves were NOT walked and the audit says so rather than inferring them.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T035456Z-caf1fbb7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T035456Z-caf1fbb7 --disposition "<what you decided or did>"
