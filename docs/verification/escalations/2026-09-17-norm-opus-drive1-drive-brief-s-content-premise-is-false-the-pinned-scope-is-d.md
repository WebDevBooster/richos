# Escalation: Drive brief's content premise is false: the pinned scope is drive.metadata.readonly, so P2 shipped metadata-only

- id: `esc-20260917T001323Z-b6d2a11e`
- raised: 2026-09-17T00:13:23Z
- from: norm-opus-drive1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-drive1` (branch `cc/norm-opus-drive1`)
- head: `748593733e5b9fbc8d5fa7426b0bb09eb18d7096`
- state: **work-complete**
- for: ceo

## The question

Should Drive stay metadata-only under drive.metadata.readonly, or does the CEO want to widen to drive.readonly and re-consent so RichOS can read document text?

## What was already tried

Re-derived from the repo: config.js:648 already pins GOOGLE_SCOPES.drive to drive.metadata.readonly (the narrower of the two options architecture 6.2 lists). That scope cannot read a body - files.get?alt=media and files.export both need drive.readonly. The brief stated 'Drive is the first source that carries file CONTENT rather than metadata'; the committed scope says otherwise. Built metadata-only and made it an enforced, mutation-probed refusal rather than an assumption. 127/127 tests pass.

## Proceeding meanwhile

P2 is complete and committed metadata-only. Nothing is blocked. Widening later is a localized change (replace the refusal in toSourceItem with a reviewed text-export path) but it changes the OAuth consent screen, so it is the CEO's call and not an adapter decision.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T001323Z-b6d2a11e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T001323Z-b6d2a11e --disposition "<what you decided or did>"
