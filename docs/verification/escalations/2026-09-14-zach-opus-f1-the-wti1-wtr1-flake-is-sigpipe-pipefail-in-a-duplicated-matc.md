# Escalation: The WTI1/WTR1 flake is SIGPIPE+pipefail in a DUPLICATED matcher, not a shared check() helper — cause found and fixed

- id: `esc-20260914T103559Z-7a197bbb`
- raised: 2026-09-14T10:35:59Z
- from: zach-opus-f1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-f1` (branch `cc/zach-opus-f1`)
- head: `474bb30de69440b536ed4f8a33156aded53a85ad`
- state: **work-complete**
- for: lead

## The question

The rescope question assumes a shared check() helper. There is none: check() is defined in exactly the two files that flake (grep -rnE '^check\(\) \{' --include='*.mutation.sh' returns 2 hits) and in no shared lib; the other 17 harnesses define mutant() and grep a FILE, which is why they were never affected. Rescope esc-20260913T224044Z-13ca1557 to the IDIOM in three named files instead of a helper that does not exist?

## What was already tried

CAUSE FOUND AND PROVEN. Both harnesses detected a case with: printf '%s' "$out" | grep -qE ... || missing=. grep -q exits on match and closes the pipe; $out is ~11KB, which bash's printf writes in several stdio-sized write(2)s, so the next write takes EPIPE; set -o pipefail then reports the WRITER's failure and || missing= fired on a case grep had just FOUND. The self-contradiction is exact: the dump three lines below greps WITHOUT -q, reads to EOF, never SIGPIPEs the writer, and so printed the very case detection had just lost. Reproduced on ubuntu:24.04 at the REAL 11KB size with the match on line 1: 1/300 idle, 9/300 under 48-way CPU oversubscription, all rc=141; 0/300 with the match at the END of the output; 0/300 on macOS. The variable is match POSITION, not output size — which is exactly why 700 clean iterations at 11KB did not clear it and why macOS would not reproduce it. Fixed with a here-string plus exit-code triage, so 'red but NOT at' is reachable only on a POSITIVE no-match. Pinned by a negative control that is deterministic on both platforms (20/20 false misses at 1MB). No assertion weakened; the guards were always sound, as tom-opus-w1 said.

## Proceeding meanwhile

Fixed in all three carriers on cc/zach-opus-f1 (guard-worktree-isolation.mutation.sh, guard-worktree-removal.mutation.sh, root-contract.mutation.sh — the third had never been seen to fail, which is not evidence it cannot). NOT touched: scripts/lib/sandbox-completeness.sh:187 carries the same idiom, where a false nonzero silently SKIPS a hook's completeness check; tom-opus-s1 holds that file. Separately: guard-worktree-removal.sh false-positives on 'docker run -w <dir>', reading it as 'claude --worktree / -w', and refused a plain container invocation during this work.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T103559Z-7a197bbb`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T103559Z-7a197bbb --disposition "<what you decided or did>"

## The measurements, with the commands that produced them

Every number below was produced by running the command, not read off a record.
The probes are not paraphrases of the idiom: the end-to-end one drives the REAL
`check()` bodies, the pre-fix one lifted verbatim from `26e85da2`.

### 1. The idiom, at the real payload size (`printf '%s' "$out" | grep -qE`)

| platform | payload | match position | load | false misses | rc |
|---|---|---|---|---|---|
| ubuntu:24.04 | 11 KB | line 1 | idle | 1 / 300 | 141 |
| ubuntu:24.04 | 11 KB | line 1 | 48-way | 9 / 300 | 141 |
| ubuntu:24.04 | 11 KB | **last line** | 48-way | **0 / 300** | — |
| darwin 24.6.0 | 11 KB | line 1 | idle | 0 / 300 | — |
| darwin 24.6.0 | 680 KB | line 1 | idle | 40 / 40 | 141 |

**Match POSITION, not payload size, is the variable.** With the match at the end
`grep` reads to EOF, so there is no early close and no race. That is why
iteration counts at 11 KB came back clean, and it is the one thing that made
this look like it was not the pipeline.

### 2. End-to-end, the real `check()` bodies, same scenario before and after

Stub `$SUITE` exiting 1 and printing a 9,633-byte report with the looked-for
case among the first FAIL lines; ubuntu:24.04, 48-way oversubscription:

```
iters=200 load=48  BEFORE_false_UNPROVEN=2  AFTER_false_UNPROVEN=0
```

The two BEFORE failures are the escalated signature exactly: `UNPROVEN M12
<- red but NOT at: S3` printed while `S3` stands in the harness's own FAIL dump.

### 3. Why the report contradicts itself

Detection and the diagnostic dump read the same string with different greps:

- detection `printf '%s' "$out" | grep -qE ...` — `-q` leaves on first match,
  closes the pipe, the writer takes EPIPE, `pipefail` surfaces the writer's
  status, `|| missing=` fires on a case that WAS found.
- dump `printf '%s\n' "$out" | grep '^  FAIL'` — no `-q`, reads to EOF, never
  closes early, never SIGPIPEs the writer. It prints what detection lost.

### 4. The discriminator asked for: what the two noisy harnesses share

```
grep -rnE '^(check|expect|mutant)\(\) \{' --include='*.mutation.sh' engine/
```

17 harnesses define `mutant()` and match against a FILE (`$dir/out.txt`) — no
pipe, no `pipefail` exposure, never affected. Exactly 2 define `check()` and
pipe: `guard-worktree-isolation.mutation.sh` and
`guard-worktree-removal.mutation.sh` — the two that flake. No shared lib
defines either function, so **`check()` is duplicated, not shared**, and the
proposed rescope target does not exist.

`root-contract.mutation.sh` is a third carrier of the same line, via a
differently-named function. It had never been seen to fail, which is not
evidence that it cannot.

### 5. Not touched

- `engine/scripts/lib/sandbox-completeness.sh:187` — same idiom, where a false
  nonzero makes the loop `continue` and silently SKIP a hook's completeness
  check. `tom-opus-s1` holds that file. (At `60e1e1dc` this moved to line
  197 and still carries the idiom verbatim; hooks now executing further in the
  sandbox make its payload LONGER, which by the table above raises the rate.)
- `guard-worktree-removal.sh` refuses `docker run -w <dir>`, reading it as
  `claude --worktree / -w`. It blocked a plain container invocation during this
  work and there is no override for that refusal. Separate defect, not mine to
  fix here.
