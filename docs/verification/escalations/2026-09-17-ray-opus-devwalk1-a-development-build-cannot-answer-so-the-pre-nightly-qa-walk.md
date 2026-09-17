# Escalation: A development build cannot answer, so the pre-nightly QA walk cannot test whether Rich replies

- id: `esc-20260917T104211Z-381e0dba`
- raised: 2026-09-17T10:42:11Z
- from: ray-opus-devwalk1
- worktree: `/Users/alex/ab/richos-wt/ray-opus-devwalk1` (branch `cc/ray-opus-devwalk1`)
- head: `b510871cd8e0049ce860d6df7958639658472d41`
- state: **work-complete**
- for: lead

## The question

How should a pre-nightly development-build walk reach a working engine: a documented RICHOS_ENGINE_* development pin, a locally built runtime, or an explicit ruling that model turns are out of scope for a development-build walk?

## What was already tried

Built 1.2.0-dev.aa0165cc with package-app.sh per the brief and walked it on his screen. Both turns I sent, one typed and one spoken, were refused locally: conversation-ledger.jsonl records TurnInterrupted with reason 'cognition io: RichOS runtime setup is incomplete: the selected engine has no delivered runtimes'. The boot log says 'this build carries NO engine pin, so it cannot install one'. Neither richos/engine/runtime nor /Users/alex/.claude/richos-engine/runtime exists on this machine. runtime.rs:53 resolves <engine>/runtime with no override in the production path; make-engine-asset.sh says the runtime ships only via the release path. So a nightly would carry one and a plain development build never can.

## Proceeding meanwhile

Everything that does not depend on a turn was walked and is committed: docs/verification/2026-09-17-main-aa0165cc-dev-walk-audit.md on branch cc/ray-opus-devwalk1. Verdict NOT READY TO BUILD THE NIGHTLY, for this and because D1-D8 all still reproduce on main at aa0165cc. Seven new defects ranked with frames; contrast passes at 118 of 118 nodes in both themes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T104211Z-381e0dba`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T104211Z-381e0dba --disposition "<what you decided or did>"
