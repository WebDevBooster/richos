# Escalation: Round 16 panel needs one behavior change the brief said not to make: the pause switch now also governs Switch at 93%

- id: `esc-20261004T210324Z-825bc017`
- raised: 2026-10-04T21:03:24Z
- from: echo-opus-panel16
- worktree: `/Users/alex/ab/richos-wt/echo-opus-panel16` (branch `cc/echo-opus-panel16`)
- head: `34c54f9f4e33f8fca1a0c1828cb9d16c854a7fac`
- state: **proceeding**
- for: lead

## The question

Keep commit 1 of echo-opus-panel16 (the automatic switch governs the five-hour Switch, as round 16 draws it), or drop it and accept a panel that says 'Off - nothing happens at 93%' while the app still switches at 93%?

## What was already tried

Read round-16 NOTES.md: one sentence, the switch is its subject, Pause or Switch is the verb; off = 'nothing happens at 93%; the line is only drawn'; only the weekly 99% switch still happens. The app (claude_accounts.rs gone()) switched at the five-hour line whenever the setting was Switch, regardless of policy.enabled (the 2026-10-04 VM walk switched with pause off). The brief says change nothing else in the behavior. The two cannot both hold without the panel saying something false.

## Proceeding meanwhile

Built to the design: gone() needs Switch AND the automatic switch on for the five-hour line; weekly 99% and the limit backstop unchanged. It is its own commit, first on cc/echo-opus-panel16, so it can be dropped alone. Proceeding with the panel and the conversation lines.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261004T210324Z-825bc017`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261004T210324Z-825bc017 --disposition "<what you decided or did>"
