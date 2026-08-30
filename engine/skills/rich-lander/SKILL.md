---
name: rich-lander
description: The orchestrator's per-handoff git landing sequence. The orchestrator is the only writer to main. This skill is the full procedure run for every engineer handoff — detect completion, verify from the worktree branch, collect evidence, merge from the main checkout, verify clean state, push, deploy, and remove the worktree deliberately. Do not delegate any step; engineers must never execute it.
---

# rich-lander — how the orchestrator lands agent work onto `main`

**Audience:** the orchestrator only. Engineers must NOT run this sequence — it is
not part of their job. If an engineer is reading this, they are off-policy.
Redirect them to `skills/using-git-worktrees/SKILL.md`.

**Policy:** the orchestrator is the only writer to `main`. Every teammate that
writes files runs in its own native-isolation worktree (`.claude/worktrees/agent-<id>/`
on a `worktree-<id>` branch) and commits there; the **commit is the handoff**. The
orchestrator serializes every land — one at a time, no concurrency, no race. See
CLAUDE.md → "Git Worktree Isolation" for the full rationale.

**Non-delegation rule:** every step here is run by the orchestrator personally. Do
not delegate the VCS-touching parts to any engineer — those are exactly the parts
that break when delegated (silent commit loss, detached HEAD, merge-into-self
no-ops, wrong deploy target).

## Detecting a handoff — durable signals, NEVER the mailbox

The agent↔lead `SendMessage` mailbox is lossy (~50% drop). The orchestrator never
waits on, or trusts, a chat message as the trigger or the source of truth. Two
durable event logs in the session team dir are the wake signal:

1. **`~/.claude/teams/session-<id>/idle-events.jsonl`** — the `TeammateIdle`
   hook appends a line every time a teammate goes idle (it idles right after
   committing + completing its task). It also annotates the idling agent's
   `uncommitted_changes` count — a nonzero value on a handoff is a red flag.
2. **`~/.claude/teams/session-<id>/task-events.jsonl`** — the `TaskCompleted`
   hook appends a line every time a teammate marks its task complete, stamped
   with teammate name + task id/subject.

A *completed* task is pruned from the queryable store (`TaskGet`/`TaskList`
won't show it) — the durable completion record is `task-events.jsonl` plus the
commit, not the task file. A teammate's courtesy summary may help orient, but it
is advisory: if it never arrived, reconstruct from ground truth and land anyway.
Never block a land waiting for a message; never reject work because a message was
missing.

## The per-handoff land sequence

Run these in order, every time. No step is skipped. If any step fails, stop and
diagnose — do not barrel forward.

### 1. Detect completion via the durable signals

On a new line in `idle-events.jsonl` or `task-events.jsonl` for a teammate,
begin its land. Do not rely on a chat message to trigger — the logs are the
trigger. Identify the teammate's worktree (`.claude/worktrees/agent-<id>/`) and
branch (`worktree-<id>`).

### 2. Read ground truth from the teammate's worktree

Verify the actual committed work — never a self-marked task status, never an
"it's clean" claim, never working-tree state.

```bash
WT=.claude/worktrees/agent-<id>
BR=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
BASE=$(git merge-base main "$BR")
git -C "$WT" log --oneline "$BASE..$BR"        # the commits in this handoff
git -C "$WT" diff --stat "$BASE" "$BR"         # what changed vs the MERGE-BASE
git -C "$WT" status --short                     # must be empty
```

- **Diff against the merge-base, not `main`.** A branch that started behind
  current main shows unrelated files under a plain `git diff main` (branch-
  behind artifact) and triggers false alarms. `$BASE..$BR` shows only this
  teammate's changes.
- **Verify commit count matches distinct changes** (the atomic-commit check).
  If the teammate batched 5 changes into 1 commit, or left work uncommitted
  (`$BASE..$BR` empty, or untracked files present), that is a bad handoff —
  re-engage the teammate before landing.
- **Derive `Touches`** from the changed paths (which of your source trees,
  `docs-only`, `scripts-only`, or an explicit mix). Never guess — read the
  paths; guessing is how work ships to the wrong deploy target.

### 3. Collect gitignored evidence BEFORE any removal

Committed deliverables ride the merge; gitignored test/QA evidence lives only in
the worktree and dies with it. Mirror it into the main checkout now:

```bash
scripts/collect-worktree-artifacts.sh .claude/worktrees/agent-<id>
```

Run this even if you are not removing the worktree yet — the evidence is only
guaranteed while the worktree exists. (The dirs it collects are configured as
`ARTIFACT_MERGE_DIRS` / `ARTIFACT_REPLACE_DIRS` in `orchestration.config`.)

### 4. Merge FROM THE MAIN CHECKOUT

```bash
cd <repo root>          # the main checkout — NOT inside any worktree
git merge --no-ff worktree-<id>
```

- **Merging from inside a worktree merges the branch into itself — a silent
  no-op.** Always `cd` to the repo root first.
- Fast-forward is fine when main hasn't moved; a merge commit is fine when it
  has. On a **conflict**, stop: `git merge --abort`, and re-engage the engineer
  durably (re-spawn with the conflicted files + "rebase onto latest main,
  resolve, recommit" in the spawn prompt, or write the correction to their
  task — a message to an idled teammate can drop). **The orchestrator never
  resolves semantic conflicts silently** — the engineer knows the intent.

### 5. Post-land verification (non-negotiable)

Run every check before proceeding.

```bash
git status --short          # empty
git symbolic-ref HEAD       # refs/heads/main (attached)
```

If any fails, STOP and diagnose — do not report done, do not deploy. A detached
HEAD or dirty main checkout is an IDE-visibility failure. (If you adopted the
advanced freshness tier, also run `scripts/freshness-check.sh` here and require
its layers green before deploy.)

### 6. Push origin main

```bash
git push origin main
```

The orchestrator is the only pusher. This makes the landed commit visible on the
remote and keeps the local main / origin / worktree base window small.

### 7. Deploy to staging (deploy-always)

Every land deploys — there is no docs-only exception (a SHA mismatch on staging
costs QA more than a short no-op deploy).

<!-- TODO (adopter): plug in your deploy command(s) here. If you have more than one
     deploy tree/environment, pick the script by `Touches` from step 2 using the
     tree-aware table from CLAUDE.md, so a mixed change never ships to the wrong
     target. **Verify the deploy actually succeeded** — agents and scripts have
     reported false success. Check the platform's deployment id and confirm the
     post-deploy build identity matches the landed commit. Never trust a
     "deployed successfully" claim without an independent check. -->

### 8. Remove the worktree — DELIBERATELY, and only after shutdown

Worktree removal is a **separate, deliberate act — landing is not a cleanup
trigger.** A worktree with commits/changes is never auto-cleaned.

- **Only after the teammate is shut down** (a positive termination signal). A
  `locked` worktree in `git worktree list` means the agent is still running —
  **never remove a locked worktree.** Never infer death from filesystem
  inactivity.
- Then, and only then:

```bash
git worktree remove .claude/worktrees/agent-<id>
git branch -d worktree-<id>
```

If work was rejected or abandoned, record why before removing.

### 8b. SWEEP THE IN-FLIGHT TEAMMATES — the step that is forgotten

**Added 2026-08-30, after it was forgotten twice in one day and cost two extra agents.**

Landing moves `main`. Every teammate still working was cut from an older base and is
now, silently, one revision behind. **Nothing tells them. You are the only thing that
can.**

Before this land is finished, enumerate every live worktree and ask, per teammate:

1. **Did their base move under them in a way that touches their files?** If yes, they
   will hit a merge conflict they could have avoided, or build on a fact that is no
   longer true.
2. **Did a record they were told to READ change?** A worktree is a snapshot: their copy
   of a wiki page, a decision file or a plan is frozen at their base. A ruling landed
   after they were cut does not exist for them.
3. **Did the thing they are consuming grow?** New source material, more variations,
   more entries — work sized to what existed at spawn time silently ships incomplete.

**Where the answer is yes, MESSAGE THEM, in this land, before you report.** The mailbox
is lossy, so a bare send is not enough:

- Say what changed, name the SHA, and say which of their assumptions it breaks.
- Ask for a reply that **only a teammate holding the new fact could write** — quote it
  back, name the file, state the number. "Did you get it?" confirms nothing; a correct
  restatement confirms content.
- **Confirm the reply arrived.** No reply is not consent. If none comes and the fact is
  load-bearing, escalate to a fresh spawn with a corrected brief.

**`TaskStop` + respawn is the FALLBACK, not the first move.** It destroys whatever the
teammate has written; it is free only when they have written nothing, and checking that
first is luck management, not method. Message, confirm, and respawn only when
confirmation does not arrive.

**The two failures that produced this step, both on 2026-08-30, both mine:**

- The techy renderer landed while a second agent built the splash screen from the same
  base. Both were known to be in `app/`. Nothing was sent. Result: eight conflicting
  hunks across five files and a whole extra agent to resolve them.
- Twelve new design variations landed while an agent was building a library from the
  seven that existed at its spawn. Nothing was sent. Result: the library shipped at 7 of
  19 and needed another agent and another round to finish.

Both were reported to the CEO as news. He had to point out that the message was never
sent at all.

### 9. Strict serialization — process the next queued handoff

One handoff at a time. When this land finishes, re-check `task-events.jsonl` /
`idle-events.jsonl` for teammates that completed while you were landing, and
process them one by one. Never parallelize a land — serial landing is the
entire point of single-writer.

### 10. Kick off QA pipeline (if user-facing)

If the change touches UI, API, or anything a user could perceive, run the QA
gate in order: automation QA → functional QA (audits committed to `qa-audits/`)
→ design-gatekeeper signoff (`ui-ux-signoffs/SIGNOFF_YYYY-MM-DD_HH.MM.md`). See
CLAUDE.md → QA Pipeline. All required gates pass before the CEO sees the work.
Docs/scripts/agent-file-only changes skip QA — report directly to the CEO.

## Wedged / lossy-agent rules that affect landing

- **Never infer an agent is dead from filesystem inactivity.** A quiet worktree
  is not a corpse — agents do substantial in-session work before flushing to
  disk. Require a positive termination signal, or send a shutdown and WAIT for
  confirmation. Liveness = the worktree lock (`git worktree list` → `locked`).
  Background native-isolation agents do NOT appear in the SendMessage roster —
  absence there ≠ terminated.
- **Non-handoff recovery = resume once, then take over.** An agent that kicks
  off a background run and stops fires a completion notification with a stub
  ("waiting on the run") — it has NOT reported. Inspect its worktree; resume it
  ONCE to commit + verify + report. If it loops on the same wait, take over —
  its work is in the still-present worktree: commit it, verify, land.
- **Tangle recovery.** If concurrent same-type agents wandered into each
  other's state, shut down ALL suspect agents, wait for their terminations,
  then spawn ONE replacement under a NEW name on a FRESH worktree path.

## Hard do-not rules at land time

- Do not delegate any step of this sequence.
- Do not merge from inside a worktree (merge-into-self no-op) — always from the
  main checkout.
- Do not resolve semantic conflicts yourself — abort and re-engage the engineer.
- Do not skip step 5 (clean-state verification) — ever.
- Do not remove a locked worktree, or any worktree before the teammate is shut
  down.
- Do not process two handoffs in parallel.
- Do not trust a "deployed successfully" claim — verify independently at step 7.
- Do not report user-facing work to the CEO before the design-gatekeeper signoff.
