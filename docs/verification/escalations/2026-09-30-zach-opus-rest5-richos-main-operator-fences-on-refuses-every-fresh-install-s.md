# Escalation: richos main: operator-fences 'on' refuses every fresh install since dd95bd6d7 (P5-44); operator-leads suite 15 red on main

- id: `esc-20260930T230125Z-b28e2ff2`
- raised: 2026-09-30T23:01:25Z
- from: zach-opus-rest5
- worktree: `/Users/alex/ab/richos-wt/zach-opus-rest5` (branch `cc/zach-opus-rest5`)
- head: `5ab7eaa24e6e88c5b5ad39589cfcd5e5afcf5e8c`
- state: **proceeding**
- for: lead

## The question

I am including a one-line installer fix (chmod 0755 on the copied fence program) as its own separate commit on cc/zach-opus-rest5 so the owning suites can prove P5-60 and P5-61. Land it with the branch, or drop that one commit and route it elsewhere?

## What was already tried

operator-leads.test.sh (RICHOS_MUTATION_INNER=1) on richos main bca29be6 fence code: 20 passed, 15 FAILED (C0c, C1, C5-C12, S1, S3, S7, D1, N1). Root cause reproduced alone: operator-fences.sh install then on refuses with 'the fence program .../.git/hooks/operator-fences/operator_fences.py is not executable'. operator_fences_admin.py install uses shutil.copyfile (mode from umask, 0644) and check_one line 269 refuses a non-executable program since dd95bd6d7, although the launcher runs the program through python3 and never needs the bit. On a real machine, a reinstall followed by on is refused the same way. With os.chmod(program, 0o755) after the copy, the same reproduction prints ON, rc=0.

## Proceeding meanwhile

Proceeding with P5-36 (committed), P5-61 and P5-60, each its own commit; the installer fix is a separate commit Rich can drop.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T230125Z-b28e2ff2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T230125Z-b28e2ff2 --disposition "<what you decided or did>"
