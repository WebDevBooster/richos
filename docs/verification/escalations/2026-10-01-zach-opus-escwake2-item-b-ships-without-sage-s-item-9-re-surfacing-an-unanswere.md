# Escalation: Item B ships without Sage's item 9 (re-surfacing an unanswered question); it needs a new Stop hook

- id: `esc-20261001T142236Z-507d6532`
- raised: 2026-10-01T14:22:36Z
- from: zach-opus-escwake2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-escwake2` (branch `cc/zach-opus-escwake2`)
- head: `c77b6c1788237e686a4308413e722c7534799a9e`
- state: **proceeding**
- for: lead

## The question

Should Sage's review item 9 (a non-blocking Stop notice that repeats an unanswered `QUESTION FOR YOU:` final message in the Stop systemMessage under every later turn) be built in this branch, or dispatched as its own follow-up? It is a NEW Stop hook: a hooks/hooks.json registration, the contract-integrity probe's hook inventory, a dependency-pins node and its own suite, and like every hook it only takes effect from a session started after the land.

## What was already tried

Read notice-ceo-ruled-prose.sh as a host for it: it exits early whenever the repository declares no CEO record and its stop_notice ledger de-duplicates by key, so it cannot repeat a line at every turn end without bending its contract. No existing Stop notice re-emits per turn by design.

## Proceeding meanwhile

Building item B as Sage specified otherwise: refuse AskUserQuestion while a teammate of this session is live; allow it when this turn was already refused at Stop; allow it after a per-session declaration (blocking-ask-exempt.sh, the ceo-ruled-exempt.sh shape); fail open on unknown liveness. The refusal tells the lead to end the turn with the question under the fixed lead-in `QUESTION FOR YOU:`, so a re-surfacer can key on it mechanically whenever it is built.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T142236Z-507d6532`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T142236Z-507d6532 --disposition "<what you decided or did>"
