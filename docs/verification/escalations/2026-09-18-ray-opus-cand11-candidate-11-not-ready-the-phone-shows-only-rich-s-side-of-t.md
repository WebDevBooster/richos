# Escalation: Candidate .11 NOT READY: the phone shows only Rich's side of the conversation, and the paired card gives iOS certificate steps for an Android phone

- id: `esc-20260918T235629Z-429dfb0a`
- raised: 2026-09-18T23:56:29Z
- from: ray-opus-cand11
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand11` (branch `cc/ray-opus-cand11`)
- head: `68bdf282c5b53b21716fdbfdbd4decab0d847b2c`
- state: **work-complete**
- for: lead

## The question

Both are copy/render defects on the phone path — do they go back to the phone-page owner as one fix, or does the iOS-copy bleed (it also appears on the phone's six-words card) go to whoever owns the home-only vs Tailscale copy split?

## What was already tried

Full live walk of candidate 1.2.0-nightly.20260918.6 on the Mac window and the CEO's HONOR X6b over the cable through the tailnet. Q1 (background job lands end to end) PASSES and is verified at the artifact: fixture ref 932fc0f4 -> 3d6a560c, line in notes.txt, reflog 1 -> 2 lines. Blocking 1: neither a message typed on the phone nor one typed on the Mac ever renders in the phone's thread, only Rich's replies do; positive control is the Mac's copy of the same thread, which shows them. Blocking 2: reopening the paired card swaps 'There is nothing to remove from your phone' for iOS Settings > General > VPN and Device Management > Remove Profile, on a card whose own first line says 'Android phone is paired', on a path that told him no certificate is installed; reproduced twice. Also high: the pairing code expires in ~60s and the flow silently resets with no message; dark-mode unchecked checkboxes render as solid white squares and read as checked (1.85:1 in light, below the 3:1 floor); the thread empties to the first-run greeting for ~4.6s after send; 'On it!' takes ~18s because the engine refresh does not re-prime the desk for the message that follows it.

## Proceeding meanwhile

Audit and 28 OCR-screened frames are committed on cc/ray-opus-cand11 (12d95bad, 68bdf282). Phone unpaired, app quit, pid 62312 gone.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T235629Z-429dfb0a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T235629Z-429dfb0a --disposition "<what you decided or did>"
