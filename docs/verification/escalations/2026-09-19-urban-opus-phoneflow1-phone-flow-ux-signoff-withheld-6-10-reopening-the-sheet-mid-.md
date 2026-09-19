# Escalation: Phone flow: UX signoff WITHHELD (6/10). Reopening the sheet mid-pairing renders the HOME path's certificate screen over a live Tailscale code

- id: `esc-20260919T041857Z-640acd39`
- raised: 2026-09-19T04:18:57Z
- from: urban-opus-phoneflow1
- worktree: `/Users/alex/ab/richos-wt/urban-opus-phoneflow1` (branch `cc/urban-opus-phoneflow1`)
- head: `fae042a277458d6cc6c2a790af9a46c94db2dbc2`
- state: **work-complete**
- for: lead

## The question

Who takes the blocker - the pairing screen's path must come from the Mac's record for the open pairing window (a serving_via field on phone_status), never from the forgotten 'route' - and does the CEO walk wait for it, or does he see nothing of this flow until the re-walk?

## What was already tried

Full live walk on pid 9587, candidate .12, 1024x700, both themes, contrast computed from pixels. Reproduced the blocker twice and re-confirmed it after an interruption. Root-caused to phone.js:718 (onTailscale derives from route) and :741 (choosing requires !pairing), so a reopen with a live or expired code falls through to the home path's blocks. Signoff and 15 gated frames committed on cc/urban-opus-phoneflow1 at fae042a2.

## Proceeding meanwhile

Nothing of mine is outstanding. Two things the lead needs beyond the signoff: (1) another agent's RichOS instance (scratchpad/sixsec) launched at 05:06:26 and took the front during my audit - I drove it by mistake for ~90s before identifying it, no finding depends on it and all 15 committed frames predate it, but two visual audits must not be scheduled concurrently on this Mac; (2) the gear-vs-menu question is answered in the signoff - one Settings, the sliders panel, promoted from popover to sheet, rail gear retired - required before the next settings row lands in either panel, not this round.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T041857Z-640acd39`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T041857Z-640acd39 --disposition "<what you decided or did>"
