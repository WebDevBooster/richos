# Escalation: The main-only ruleset has no hole: nightly-channel was explicitly excluded from it by the owner account on 2026-09-16, and NIGHTLY.md documents that carve-out as required

- id: `esc-20260917T145741Z-843c8c21`
- raised: 2026-09-17T14:57:41Z
- from: zach-opus-channel1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-channel1` (branch `cc/zach-opus-channel1`)
- head: `345ea76df77f211a90470935f92586bc35363c3c`
- state: **proceeding**
- for: ceo

## The question

The branch was permitted on purpose, not leaked. Removing the carve-out is right and I am doing it — but do you want to know who asked for it? The API names the actor as the WebDevBooster account, which cannot distinguish you clicking it from an agent using a token authorized as you.

## What was already tried

gh api repos/WebDevBooster/richos/rulesets/23194738 shows conditions.ref_name.exclude = [refs/heads/main, refs/heads/nightly-channel]. The /history endpoint shows two versions: v49562454 (2026-09-13T18:42:15+01:00) excluded only refs/heads/main; v49950050 (2026-09-16T22:57:22+01:00) added refs/heads/nightly-channel. Both actor id 29904195 = WebDevBooster. A live probe push of refs/heads/zz-ruleset-probe-20260917a was REFUSED with GH013 'Cannot create ref due to creations being restricted', so the ruleset is active and enforced against this machine's own credentials. richos/app/NIGHTLY.md:175 states the exception is needed, and richos/app/scripts/nightly-local.py:234-236 REFUSES to run unless the carve-out is present.

## Proceeding meanwhile

Removing refs/heads/nightly-channel from the exclude list, moving the channel to a rolling 'nightly' prerelease asset, and inverting the runner preflight so a future re-opening of any branch carve-out refuses the nightly run.

## Answered, 2026-09-17, by the lead

**It was a Codex run, not the CEO in a browser.** Codex session
`~/.codex/sessions/2026/09/16/rollout-2026-09-16T08-36-58-01a0a925-c097-72d0-bafc-8495bf7ee38d.jsonl`,
tool call at 2026-09-16T21:57:21Z: a Python heredoc read ruleset 23194738 through `gh`
(the CEO's token, user id 29904195), wrote the backup
`~/.richos-nightly/main-only-before-nightly.json` and then PUT the exclusion list back
with `refs/heads/nightly-channel` added. The account id the API reports is the token's
owner, which is why the API alone could not answer this and why it was worth asking.

The lead added one requirement on the back of it, and it is implemented: before the
publisher publishes anything it reads the ruleset back and REFUSES unless `main` is the
only exempt branch (`nightly.py verify_repository_rules`, subcommand `check-rules`),
with a positive control that widens the exclusion list and goes red
(`nightly.test.py RepositoryRuleTests`).

**Disposition:** the rule was restored FROM that backup file rather than by hand
(`jq '{name,target,enforcement,bypass_actors,conditions,rules}'` piped to
`gh api --method PUT`), and the live ruleset now diffs identical to the backup.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T145741Z-843c8c21`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T145741Z-843c8c21 --disposition "<what you decided or did>"
