# Escalation: Two premises in the five-place hook-inventory list are false, and the record now carries them

- id: `esc-20260914T071054Z-70e23623`
- raised: 2026-09-14T07:10:54Z
- from: zach-opus-n9
- worktree: `/Users/alex/ab/richos-wt/zach-opus-n9` (branch `cc/zach-opus-n9`)
- head: `c730240e33a528d1ade17fa25b178b5afc615e45`
- state: **work-complete**
- for: lead

## The question

Should the five-place table in the lifecycle failure record and in zach-opus-n8's finding be corrected before the next engineer is briefed from it?

## What was already tried

Re-derived every row of the table from the suites themselves rather than from the relay, then built the guard on the re-derivation. Both corrections are encoded in the shipped predicate and its suite, so the MECHANISM is right whatever the record says; what is still wrong is the RECORD, which is what the next brief will be written from. (1) install.sh's hashed set is NOT an inventory a new guard must be added to: it has been DERIVED from hooks.json since the sixteen typed paths were removed, and its own header says so -- 'wiring a seventeenth guard mints its sidecar with no edit here'. Independently measured: install.sh names 20 of 68 registered hooks, far below the unanimity the other four reach. An engineer obeying the relayed list would go looking for a list that is not there. (2) The trigger 'a staged diff that touches engine/hooks/hooks.json' would MISS the sharpest instance the record itself names: ref-transaction-forensics.sh appears in hooks.json ZERO times (grep -c, on this tree) -- it is a git reference-transaction hook. A hooks.json-only trigger would never have seen the case the section was written about. The shipped guard therefore also triggers on a new *.sh appearing in scripts/hooks/. (3) Minor, same origin: the 'SC1 list' in the relayed conditional list is not an inventory. SC1 in contract-integrity-probe.sh is a shellcheck directive; the phrase comes from a 2026-09-06 prose comment in engine-status.test.sh and there is no such list in the probe today.

## Proceeding meanwhile

Both commits are landed on the branch and every affected suite is green; nothing is waiting on the answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T071054Z-70e23623`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T071054Z-70e23623 --disposition "<what you decided or did>"
