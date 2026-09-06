# Escalation: The inner doctrine has no dialect, and the model drifted to British spelling on the first product-shaped question

- id: `esc-20260906T124636Z-172912c2`
- raised: 2026-09-06T12:46:36Z
- from: echo-opus-dr1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-dr1` (branch `echo-opus-dr1`)
- head: `8b5a98fd46f38256063e419d200cff5987df81a2`
- state: **work-complete**
- for: ceo

## The question

Should the inner Rich's standing instruction pin a dialect, and if so should it be American English for v1 or a setting the CEO picks?

## What was already tried

Built and landed the doctrine per the design; drove five live cells against claude 2.1.263. Cell L5, the shipping doctrine, answered a CEO-shaped question with the word 'authorised'. The design's own boundary rule (4.1) says a clause must be true for every turn of every install, and 'always American English' is not true for an adopter in London, so a fixed dialect clause fails the same test that keeps the company name out. It belongs in the rendered identity beside the CEO's name, from a setting that does not exist in ConfigStore today. Evidence: docs/verification/inner-doctrine-live-2026-09-06/ 6, raw/cellL5-register-treatment.jsonl.

## Proceeding meanwhile

Everything else in the brief is built, tested and committed. DoctrineIdentity is a struct precisely so a second hashed input can be added; if the answer is yes, that is roughly an hour of work and one re-render.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T124636Z-172912c2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T124636Z-172912c2 --disposition "<what you decided or did>"
