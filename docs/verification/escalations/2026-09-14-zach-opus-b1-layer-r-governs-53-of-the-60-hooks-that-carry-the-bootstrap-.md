# Escalation: Layer R governs 53 of the 60 hooks that carry the bootstrap; the other 7 can diverge unseen

- id: `esc-20260914T105902Z-e10ccf88`
- raised: 2026-09-14T10:59:02Z
- from: zach-opus-b1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-b1` (branch `cc/zach-opus-b1`)
- head: `be3ae72f3c062752f6f0f4a96c3982ad4e24ce98`
- state: **work-complete**
- for: lead

## The question

Should Layer R's typed list grow from 53 to 60? Two of the seven cannot simply be added: guard-ci-red-lands and guard-stop-live-work carry a SECOND bootstrap (git-jurisdiction) inside Layer R's extraction window, so naming them turns the layer red for a divergence that is an artifact of the sed range rather than a real one. Moving the window is a change to the layer itself, which my brief told me to argue for separately rather than make.

## What was already tried

Re-derived all three facts the brief flagged as unverified. Three of its numbers were wrong. (1) 60 files carry the bootstrap, not 53; 53 is the size of Layer R's TYPED list, and seven carriers sit outside it: contract-integrity-probe, guard-ceo-ruled-ask, guard-ci-red-lands, guard-owned-state, guard-stop-live-work, notice-ceo-ruled-prose, observe-created-refs. (2) The alarm was NOT silent in all of them: 35 of the 60 exit 2 in that branch, where the host renders stderr as the refusal reason, so they were already audible; 24 exit 0 and were silent, and those 24 are the notices and observers. (3) Layer R asserts identity MODULO NORMALIZATION, not byte-identity: it seds the hook name and the exit code out before comparing, which is precisely what made one uniform edit possible. The core premise held: stderr at exit 0 reaches nobody, measured on Claude Code 2.1.270 across SessionStart, UserPromptSubmit, PreToolUse, PostToolUse and Stop, and the only event-agnostic channel that reaches a person is {systemMessage} on stdout.

## Proceeding meanwhile

The job is done and committed at be3ae72f on cc/zach-opus-b1: 59 hooks, one uniform edit, banner now on stderr AND {systemMessage}. Layer R green across all 53; --only base 11/11 and --only manifest 10/10 at exit 3; stop-hook-visibility 42/42. Exit codes untouched, refusal parity measured. I did NOT touch Layer R. Separately worth knowing: Layer R's green tick says 'byte-identical' when what it asserts is identity modulo normalization, and the same claim is repeated in the header comment of all 59 hooks; correcting it would mean re-editing all 59, so I left it rather than churn the file set twice.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T105902Z-e10ccf88`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T105902Z-e10ccf88 --disposition "<what you decided or did>"
