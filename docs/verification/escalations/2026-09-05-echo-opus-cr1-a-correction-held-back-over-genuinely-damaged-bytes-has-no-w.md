# Escalation: A correction held back over genuinely damaged bytes has no way back, and only he can say whether it should

- id: `esc-20260905T124300Z-3ce871e9`
- raised: 2026-09-05T12:43:00Z
- from: echo-opus-cr1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-cr1` (branch `echo-opus-cr1`)
- head: `4bea0915f853cf235ca67913185c8ab8a19cb69d`
- state: **work-complete**
- for: ceo

## The question

When a damaged record makes RichOS unable to tell whether he already answered a correction, should there be a way for him to say 'ask me anyway' — or is silence the right answer for a proposal it cannot vouch for?

## What was already tried

Built the hold exactly to the bar in my brief: a proposal whose answer might be among the unreadable records is Unresolved, out of pending_for, refused by confirm/decline, counted in desk_health and listed by unresolved(). For a record written by a NEWER build this resolves itself — updating reads the record and the proposal returns to its true state, pinned by a test. For genuinely DAMAGED bytes it never resolves: damaged bytes do not become readable, so that proposal is held forever. It is inspectable and it is named in the boot notice, so it is not silent, but there is no verb that releases it. I deliberately did not invent one: releasing it means offering him a correction he may already have confirmed, which is the exact repeat the whole change exists to prevent, and choosing to accept that risk is his call and not mine. Live exposure is nil today: no loro-corrections.jsonl exists in his app data dir, so this is prospective like steering.rs was.

## Proceeding meanwhile

All five commits are on echo-opus-cr1 and the work is complete; 956 Rust tests and 443 UI checks pass, none lost.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T124300Z-3ce871e9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T124300Z-3ce871e9 --disposition "<what you decided or did>"
