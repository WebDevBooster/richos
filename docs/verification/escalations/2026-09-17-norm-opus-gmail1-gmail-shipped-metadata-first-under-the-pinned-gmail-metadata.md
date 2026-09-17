# Escalation: Gmail shipped metadata-first under the pinned gmail.metadata scope, so cross-thread body synthesis is not reachable without re-consent

- id: `esc-20260917T003225Z-7d633958`
- raised: 2026-09-17T00:32:25Z
- from: norm-opus-gmail1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-gmail1` (branch `cc/norm-opus-gmail1`)
- head: `bf5bb380389500eca7386daa0895caec93b6111b`
- state: **work-complete**
- for: ceo

## The question

Should mail stay metadata-only under gmail.metadata, or does the CEO want to widen to gmail.readonly and re-consent so RichOS can read message bodies?

## What was already tried

Re-derived from the repo rather than from the brief: config.js pins GOOGLE_SCOPES.mail to gmail.metadata, already annotated 'P3, metadata-first (graduated privacy)'. Architecture 6.2 recommends exactly that as the first cut. Under that grant Gmail permits format=metadata/minimal and rejects full/raw, so a body cannot be read at all. I built metadata-only and made it an enforced, mutation-probed refusal rather than an assumption: toSourceItem refuses a payload carrying snippet, raw or part body data, and body mode is refused at construction without gmail.readonly. 157/157 tests pass. The consequence worth the CEO's attention is that the headline mail value the plan describes - 4.4's 'the same pricing objection in four threads this month' - operates on SUBJECTS and participants only under the current grant, not on message text. Metadata still buys real value (who the CEO corresponds with, how often, on what subjects, and the people feeding the entity flywheel), but cross-thread synthesis over body content is not reachable without a scope widening. On a Workspace/Internal app widening is a re-consent; on consumer Gmail 6.1 says gmail.readonly is a restricted scope that drags in CASA verification, which is why the plan flags it as 9-Q1/Q3.

## Proceeding meanwhile

P3 is complete and committed metadata-only. Nothing is blocked. Widening later is localized - replace the refusal in toSourceItem with a reviewed normalization path (the body-mode code and its tests already exist and are exercised) - but it changes the OAuth consent screen, so it is the CEO's call and not an adapter decision.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T003225Z-7d633958`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T003225Z-7d633958 --disposition "<what you decided or did>"
