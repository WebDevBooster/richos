# Escalation: The front-page README's voice sentence is now false, and only the CEO may change it

- id: `esc-20260917T013254Z-b70644da`
- raised: 2026-09-17T01:32:54Z
- from: echo-opus-voicemodel1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-voicemodel1` (branch `cc/echo-opus-voicemodel1`)
- head: `a58525ee2512cc85226cb5114fe8d27d495f6dc0`
- state: **work-complete**
- for: ceo

## The question

Do you want .github/README.md line 35 changed, and do you want to write it or take a draft? The line says 'Speech needs a model this build does not download for you' - it downloads it now, proven on the installed bundle.

## What was already tried

My brief instructed me to rewrite that line if the installed proof passed. The proof passed. I did not touch the file: the RichOS GitHub home page is the CEO's own writing by his ruling of 2026-09-04, given after an agent was dispatched to extend that same file ('no, that's not Will's job. That's my job.'). A brief from an orchestrator cannot authorize crossing a standing ruling of his, so I left it and raised it. Everything else in the task is complete and committed. A wording true of what was actually proven is written out verbatim in docs/verification/voice-model-provisioning-2026-09-17.md for him to take, edit or discard.

## Proceeding meanwhile

Nothing is blocked. The feature is built, tested and proven on the installed binary; only the public sentence describing it is stale. Note that only ONE of its two claims went false: the model now arrives by itself, and voice still does not work on a Mac with no whisper-cli, which RichOS cannot fetch because a Homebrew binary's sha256 cannot be pinned.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T013254Z-b70644da`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T013254Z-b70644da --disposition "<what you decided or did>"
