# Escalation: containers.test.sh leaks labelled containers on a failed run, and the residue makes every later local run of it red

- id: `esc-20260914T003636Z-ea530880`
- raised: 2026-09-14T00:36:36Z
- from: zach-opus-n2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-n2` (branch `cc/zach-opus-n2`)
- head: `6660c8b51c7d03bfc6c221c3b0d7801cdd3f577c`
- state: **work-complete**
- for: lead

## The question

Should the D cases get a run-scoped cleanup that survives an interrupted mutant, or is a documented 'docker rm -f by label before running this suite' enough?

## What was already tried

Both assigned shard failures are fixed and verified. While verifying, the suite went red 6 times in a row at mount-authorizes-delete-real with 'the red is unrelated', and I wrongly attributed it to my own C10 edit; a pin-only vs sandbox-only bisect appeared to confirm that, and a 500ms timing-only perturbation of pristine did not. The actual cause is residue: 8 containers labelled sh.richos.test-run were still Up after a failed run, because tearDown does not survive the pool interrupting a mutant. After 'docker ps -aq --filter label=sh.richos.test-run | xargs docker rm -f -v' the suite went 3/3 green on my tree. One run degraded so far that all 8 concurrent mutants reported red-but-unrelated. CI is NOT affected: the four D mutants skip on the runner because alpine:latest is not pre-pulled, confirmed in run 34787626046's own log.

## How far the evidence actually goes

Stated plainly because the first version of this record overstated it, and an
escalation that overstates its own confidence is the thing it is warning about.

WHAT IS MEASURED: leaked containers exist (8 still `Up` after a failed run, and
the suite's own header promises they are removed in tearDown); they are removed
by one command; and with a clean slate and cleaning between runs, my branch went
3/3 green where it had been going red.

WHAT IS NOT ESTABLISHED: that residue is the ONLY driver. One red did occur on a
clean slate -- but that run used a tree copied out of the main checkout while
another session was writing to it, so the copy may simply have been torn, and I
am not counting it either way. The concurrent pool runs 8 mutants that each
drive real containers, and the failure signature is always the same shape: the
reaper deletes nothing, `inventory()` comes back short (probed at 3 rows), and
cases that expect a deletion go red while the case the mutant targets passes for
the wrong reason.

So: residue is proven to matter and proven to be fixable. Whether the D cases
also need to stop competing with each other for one Docker daemon is open, and
it is the second half of the question above.

## Proceeding meanwhile

Shipped both fixes on my branch; neither touches the D cases or the leak.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T003636Z-ea530880`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T003636Z-ea530880 --disposition "<what you decided or did>"
