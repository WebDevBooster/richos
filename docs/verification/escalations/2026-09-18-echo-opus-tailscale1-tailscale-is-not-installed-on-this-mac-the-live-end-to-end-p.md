# Escalation: Tailscale is not installed on this Mac — the live end-to-end proof in the brief's step 5 cannot be run here

- id: `esc-20260918T204405Z-e25d25de`
- raised: 2026-09-18T20:44:05Z
- from: echo-opus-tailscale1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-tailscale1` (branch `cc/echo-opus-tailscale1`)
- head: `ff821816c647f4fdcdf1ca9e77f8b223a85e3e9a`
- state: **proceeding**
- for: ceo

## The question

Will the CEO install Tailscale (the app plus a free-tier sign-in) on this Mac, so the tailnet-origin pairing QR and a no -k curl to /api/ can actually be demonstrated? Until then the Tailscale path ships detection-and-fallback verified against recorded CLI output, with the live leg unproven.

## What was already tried

Checked /Applications/Tailscale.app (absent), which tailscale (not found), /usr/local/bin + /opt/homebrew/bin + the app bundle MacOS dir (all absent), ~/Library/Containers/io.tailscale* (absent), /var/run/tailscale* socket (absent), launchctl list | grep -i tailscale (nothing), brew list (not present), scutil --dns for a ts.net resolver (none). The four utun interfaces present are not Tailscale. The brief says explicitly: do not install software on his Mac yourself.

## Proceeding meanwhile

Building the whole path: tailnet detection behind a provider seam pinned to RECORDED tailscale status --json output, the absent / signed-out / signed-in state model Urban's how-to screens need, the tailnet origin in the pairing screen gated on signed-in detection, and the cert/serve decision argued from Sage 2.3 and the code rather than from a live run. Every claim that needs a live Tailscale will be labelled unproven in the handoff rather than asserted.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T204405Z-e25d25de`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T204405Z-e25d25de --disposition "<what you decided or did>"
