# Escalation: The same unrun-reports-ok defect has two more instances in richos-core, and one fires on every ubuntu spine-CI run

- id: `esc-20260905T152456Z-1a219757`
- raised: 2026-09-05T15:24:56Z
- from: echo-opus-gs1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-gs1` (branch `echo-opus-gs1`)
- head: `f8c12b06477a62f45d2e097e1c399251677bef93`
- state: **work-complete**
- for: lead

## The question

Should richos-core's two conditional skips in tests/setup.rs get the same treatment in a follow-up, or is a known-and-recorded gap acceptable there?

## What was already tried

Surveyed both crates for conditional-skip shapes rather than grepping the one variable. richos-voice had FIVE, not four: the four RICHOS_VOICE_LIVE_AUDIO sites plus tts.rs:294, gated on /usr/bin/say existing. All five fixed and committed. richos-core has two more of the identical class in crates/richos-core/tests/setup.rs: the_real_claude_binary_on_this_machine_satisfies_the_requirement (lines 691-700) and the_digest_agrees_with_shasum (line 794). Both eprintln a SKIPPED line and return; cargo captures stderr for a PASSING test and discards it, so the log shows only 'ok'. The first is not cfg-gated to macOS and app-spine-ci.yml runs cargo test -p richos-core on ubuntu-latest, where ~/.local/bin/claude does not exist. Its own doc comment reads 'a negative-only signature test is one that passes because everything fails' - which is what it has been on every CI run since that job landed. It is the POSITIVE half of the Anthropic code-signature check that guards claude installs.

## Proceeding meanwhile

richos-voice is done and proven both ways: 966/0/6 unset, 970/0/2 with RICHOS_VOICE_LIVE_AUDIO=1 (identical to the 970/0/2 baseline). Not touching richos-core, per the brief's fix-only-this-crate scope.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T152456Z-1a219757`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T152456Z-1a219757 --disposition "<what you decided or did>"
