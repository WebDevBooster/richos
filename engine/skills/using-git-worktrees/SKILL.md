---
name: using-git-worktrees
description: Git worktree workflow for every teammate that writes files in this repo. Covers your isolated worktree, atomic-commit discipline, the commit-is-the-handoff model, courtesy-summary format, and the hard prohibitions (no merge into main, no push, no deploy). Read this before you write your first file.
---

# using-git-worktrees — how you work in this repo

**Audience:** every teammate that writes files (engineers, QA, designers).
This repo uses plain **git**. The orchestrator is the only writer to `main`; you
commit on your own worktree branch and hand off.

## Your worktree

- Native isolation puts you in a **dedicated git worktree** under
  `.claude/worktrees/agent-<id>/`, on a dedicated `worktree-<id>` branch,
  branched from the local `main` HEAD. That worktree IS your environment.
- Any gitignored files an app needs to boot (`.env` and friends) are auto-seeded
  into your worktree via `.worktreeinclude` (if the adopter configured one). You
  start in a checkout that can run the app.
- **You never work in the shared main checkout.** A PreToolUse hook
  (`guard-main-checkout-writes.sh`) blocks any write to the main checkout's
  protected source trees (the `PROTECTED_PATHS` configured in
  `orchestration.config`). If you hit that block, you drifted: an absolute path
  resolved outside your worktree. Re-issue the exact edit against your worktree
  path (`.claude/worktrees/agent-<id>/...`) and continue.
- Always use absolute paths rooted in your worktree. Confirm with
  `git rev-parse --show-toplevel` if unsure where you are.

## Commit discipline

- **Atomic commits are mandatory.** One meaningful change = one commit, made
  immediately — never batched, never deferred. If you fix 5 things, there are
  5 commits. The orchestrator verifies commit-count against distinct-changes at
  land time.
- **Idle means committed.** Commit as your FINAL step before going idle. Never
  go idle with uncommitted or untracked work — the handoff is the commit, and
  anything not committed does not exist for the orchestrator.
- Multi-paragraph commit messages: use `git commit -F <file>` or a quoted
  heredoc (`git commit -F - <<'EOF' ... EOF`). Do not cram body text with
  backticks / `<` / `>` / `$` into `-m` — the shell chews it.

## Handoff = the commit + marking your task complete

Your deliverable is your **git commit(s) on your worktree branch** plus
marking your task complete (`TaskUpdate` status=completed). That is the
handoff. Both live on durable substrates (the commit on disk, the completion
in an append-only event log) and cannot be dropped.

The chat mailbox is **advisory only** — it has historically dropped ~50% of
messages. So:

- Commit → mark task complete → send a one-line courtesy summary → go idle.
- **Do NOT wait for an ack. Do NOT retry-loop.** The orchestrator detects your
  completion via durable idle/task-completed event logs and reads ground truth
  from your branch. If your courtesy message drops, the work is still found.

**Courtesy summary format** (SendMessage to the orchestrator):

```
Handoff: <one-line summary>
Worktree: .claude/worktrees/agent-<id>
Branch:   worktree-<id>
Commits:  <sha1>[, <sha2>, ...]   (oldest first)
Touches:  <source-tree> | docs-only | scripts-only | explicit mix
Notes:    <anything the orchestrator needs — e.g. where test evidence lives>
```

## Prohibitions

- **Never `git merge` into main.** The orchestrator lands your branch.
- **Never `git push`.** The orchestrator is the only writer to the remote.
- **Never run any deploy script.** Deploy is the orchestrator's final land step.
- **Never touch another agent's worktree.** One agent = one worktree.
- **Never edit the main checkout's protected source trees.** All source reaches
  main only via the orchestrator's merge.

## Don't produce a "non-handoff"

If you kick off a long or background run (a test suite, a build), **WAIT for
it to finish**, then commit + verify + report. Stopping while a background run
is still going and firing a completion notification is a non-handoff — the
orchestrator sees a stub, not your result. Finish the run, commit the outcome,
then idle.

## Mid-work corrections

Corrections and new constraints arrive via your **task in the shared task
store**, not via a load-bearing chat message. When signaled, re-read your task
(`TaskGet`/`TaskList`) before continuing. If a correction is large you may be
re-spawned fresh with the corrected brief in the spawn prompt — that is normal.

## Test evidence

Gitignored outputs — `test-results/`, `playwright-report/`, `output/`, and any
screenshot dirs — live only inside your worktree and **die with it** when the
orchestrator removes the worktree after landing. Committed deliverables
(`qa-audits/*`, `ui-ux-signoffs/*`, code) ride your branch into main and are safe. For the
ephemeral evidence, the orchestrator runs
`scripts/collect-worktree-artifacts.sh <worktree-path>` at land time to mirror
it into the main checkout before removal (the dirs it collects are configured as
`ARTIFACT_MERGE_DIRS` / `ARTIFACT_REPLACE_DIRS` in `orchestration.config`).
**Tell the orchestrator where you left evidence** in your courtesy summary so it
gets collected.
