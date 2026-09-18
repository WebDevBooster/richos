# Escalation: §15 has two tiers and a section heading fits either — the desk's headings are at 14px, not 16px, and that is the CEO's call

- id: `esc-20260918T222146Z-0041574f`
- raised: 2026-09-18T22:21:46Z
- from: echo-opus-typefloor1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-typefloor1` (branch `cc/echo-opus-typefloor1`)
- head: `3f7be73034e1c9649a93a3e5bbc434e4bbfa9b11`
- state: **work-complete**
- for: ceo

## The question

Should the desk's section headings and the feedback panel's group legends sit at §15's 14px skippable floor (what I took) or at its 16px 'meant to be easily read' tier?

## What was already tried

The brief and escalation esc-20260918T211347Z-d7e05a01 ruled 14px minimum, so I applied 14px and said so in the CSS at each site. But the enumeration that found them turned up text the brief did not anticipate: .desk-section-title and .desk-sub-title are <h2>/<h3> reading 'What I believe', 'Words I may have got wrong', 'What's on this machine', 'Never ask again', and .feedback-group-legend is the accessible NAME of a radio group ('What kind of failure was it?'). Those are headings a person reads, not chrome, and §15's own words give readable text a 16px minimum and only the skippable a 14px one. 14px is the floor; it may not be the right tier.

## Proceeding meanwhile

Shipped at 14px in commit 49b5701e on branch cc/echo-opus-typefloor1 (the sha as rebased onto main 9f8a045c; it was 2b235b9d one rebase earlier, and this correction is here because the raise named them the wrong way round), which clears the floor either way, so nothing is blocked. Moving them to 16px later is a one-line change per rule plus four re-photographed shots. The two surfaces are the corrections desk and the feedback panel.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T222146Z-0041574f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T222146Z-0041574f --disposition "<what you decided or did>"
