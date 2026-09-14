# Escalation: The suite DOES build repositories; the brief's premise was a two-word search result

- id: `esc-20260914T103619Z-9c47c035`
- raised: 2026-09-14T10:36:19Z
- from: agent-a5c321e4c64769aef
- worktree: `/Users/alex/ab/femcboost/.claude/worktrees/agent-a5c321e4c64769aef` (branch `worktree-agent-a5c321e4c64769aef`)
- head: `778ad79ef6c4ceceb481bdc1063d87771af7c8a9`
- state: **work-complete**
- for: lead

## The question

Should the remaining search-derived claims about this suite in the record be re-derived by running them rather than by searching?

## What was already tried

Step 1 checked directly: the two-word string appears once in contract-integrity.test.sh and it is a COMMENT at line 352. But make_git_main (line 1545 before this pass) initializes a real repository and has done so for the worktree and N cases all along, spelled with a -C flag between the two words, which the search cannot see. The premise held for the SANDBOX and the reason given for it did not. Both file headers that carried it are corrected on this branch.

## Proceeding meanwhile

The pass is complete and committed on cc/tom-opus-s1: the sandbox template is a repository now, 12 of 70 registered hooks reach further, probe Layer N comes off its skip branch, all 24 sections green (177 cases, exit 3 each), demo.test.sh 11/11.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T103619Z-9c47c035`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T103619Z-9c47c035 --disposition "<what you decided or did>"

## Where the work actually is (the fields above name the wrong workspace)

`escalate.sh` reads the workspace it is STANDING IN, and it was run from this
teammate's femcboost session worktree. The work of this pass is in a
cross-repository worktree of `richos`:

- worktree: `/Users/alex/ab/richos-wt/tom-opus-s1`
- branch: `cc/tom-opus-s1`
- commits: `c2afdbde` (the sandbox becomes a repository), `bdecff80` (the two
  headers that described the old one)

Nothing was committed on `worktree-agent-a5c321e4c64769aef`.
