# The worktree transaction lifecycle — runbook

Specification: the private femcboost record `worktree-real-fix-2026-09-03.md`,
under that repository's docs/plans directory. The
history that produced it: `richos-hq/wiki/worktree-lifecycle.md` §11–§14.
Ruling, 2026-09-02: *"The system should stop trying to discover whether the
agent might return. It is forbidden to return."*

```
~/.claude/state/worktree-transactions/<session_id>/<agent_id>.json   the transaction
~/.claude/state/worktree-transactions/<session_id>/{intents,bound,starts}/  its facts
~/.claude/state/worktree-transactions/terminal/<agent_id>              terminal index
~/.claude/state/worktree-captures/<session_id>/<agent_id>/member-N/    the archive
~/.claude/state/worktree-ledger.jsonl                                  prepared records
~/.claude/state/worktree-reconciler.log                                launchd output
```

## The flow, and the file that does each step

| Step | Hook / script | What it writes | Refuses when |
|---|---|---|---|
| prepare an external worktree | `scripts/create-teammate-worktree.sh` | `prepared` (ledger) — repo, exact path, branch, session id | the path is not in `git worktree list`, no session id resolves, or the record does not read back: the tree is **rolled back** |
| spawn intent | `guard-worktree-isolation.sh` clause 7 (PreToolUse[Agent]) | `intents/<tool_use_id>.json` — the exact member set | an external path has no `prepared` record for this session and teammate, its repo or branch drifted, `run_in_background: false`, or a lifecycle component is missing |
| bind | `detect-nonnative-worktree.sh` (PostToolUse[Agent]) | `bound/<agent_id>.json` — intent + agent id | no intent, no agent id (synchronous run), or a rebind: announced loudly, exit 2 |
| start fact | `record-subagent-start.sh` (SubagentStart) | `starts/<agent_id>.json` — the worker's exact cwd | never; it cannot block and does not pretend to |
| seal | `worktree-transactions.py try_seal` (called by both writers above and by the barrier) | `<agent_id>.json` with `sealed: true` | the cwd is not `agent-<id>`, not a linked worktree git lists, or not the prepared external path |
| write barrier | `guard-sealed-worktree.sh` (PreToolUse, matcherless, first) | nothing | the manifest is not sealed (after waiting `SEAL_WAIT_SECONDS`): every tool but `SEAL_READONLY_TOOLS` is refused; a terminal agent is refused everything |
| terminal claim | `terminalize-agent-worktrees.sh` (SubagentStop, WorktreeRemove) | `terminal` on the transaction; backup refs; quarantines; the terminal indexes | never blocks; an agent with no sealed transaction produces no claim |
| resume refusal | `guard-resume-isolation.sh` (PreToolUse[SendMessage]) | nothing | the recipient's agent id or session-scoped name is terminal — before `resume-ack:`, before protocol bodies |
| capture → removal | `scripts/reconcile-terminal-worktrees.py` (launchd every `RECONCILE_INTERVAL_SECONDS`; SessionStart with a budget) | member states `captured → verified → unregistered → removed`; the archive | a member has both its original and its quarantine present, or provenance contradicts git: `failed`, reported once, counted as dead-present |

## What to run

```
python3 <engine>/scripts/reconcile-terminal-worktrees.py --status
```
prints the definition of done and exits 1 while anything is dead-present or
pending. `--agent <session>/<agent>` reconciles one transaction;
`--max-seconds N` bounds a run.

```
python3 <engine>/scripts/lib/worktree-transactions.py list
python3 <engine>/scripts/lib/worktree-transactions.py show --session-id S --agent-id A
```
lists every transaction with its member states; `show` prints one.

```
launchctl print gui/$(id -u)/com.richos.worktree-reconciler
```
shows the scheduled job; `scripts/hooks/install.sh` from the main checkout
installs it (withheld from a worktree, an ephemeral checkout, or a sandboxed
`CLAUDE_CONFIG_DIR`, for the engine-pointer reason).

## Recovering work

Every member's HEAD at terminalization is under
`refs/richos/handoffs/<session_id>/<agent_id>/<branch>` in its own repository,
written before the rename. Every non-disposable byte (tracked, staged,
untracked, ignored) is in `worktree-captures/.../member-N/tree.tar`, with
staged blobs under `blobs/<sha>` and `provenance.json` naming repo, path,
branch and HEAD. The member's branch is left alone.

## What a hard failure looks like, and what to do

`reconcile-terminal-worktrees.py --status` reports
`hard_failures_counted_as_dead_present > 0`; a `<agent_id>.json.member-N.notice`
file sits beside the transaction with the reason. The two causes: both the
original path and the quarantine exist (something recreated the original
after the rename and the reconciler refused to choose), or the quarantine's
HEAD no longer matches the backup ref. Resolve by hand — inspect both, keep
what matters, remove the one that is residue — then set the member's state
back to the last good one in the JSON (`ref_saved` or `quarantined`) and run
`--agent`. Nothing automated will do this; it is the one place a person is
supposed to look.

## Test affordances

`RICHOS_WORKTREE_TX_DIR`, `RICHOS_WORKTREE_CAPTURE_DIR`,
`RICHOS_RECONCILE_SETTLE`, `RICHOS_RECONCILE_NO_KILL=1`, `SEAL_WAIT_SECONDS`,
`SESSION_START_RECONCILE_BUDGET`, `RICHOS_LAUNCH_AGENTS_DIR`. Every suite pins
the first two; nothing they do reaches `~/.claude/state`.
