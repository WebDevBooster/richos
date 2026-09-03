# The worktree transaction lifecycle — runbook

Specification: the private femcboost record `worktree-real-fix-2026-09-03.md`,
under that repository's docs/plans directory. The
history that produced it: `richos-hq/wiki/worktree-lifecycle.md` §11–§14.
Ruling, 2026-09-02: *"The system should stop trying to discover whether the
agent might return. It is forbidden to return."*

```
~/.claude/state/worktree-transactions/<session_id>/<agent_id>.json   the transaction
~/.claude/state/worktree-transactions/<session_id>/{intents,bound,starts}/  its facts
~/.claude/state/worktree-transactions/<session_id>/pending-terminal/<agent_id>.json  a terminal event that arrived before the seal
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
| terminal claim | `terminalize-agent-worktrees.sh` (SubagentStop, WorktreeRemove) | `terminal` on the transaction; backup refs; quarantines; the terminal indexes — the named native path first, one member at a time | never blocks; an agent with no sealed transaction produces no claim — its event is persisted as `pending-terminal/<agent_id>.json` instead (below) |
| pending terminal | `worktree-transactions.py claim_terminal` (unsealed) → `try_seal` (consumes) → `reconcile-terminal-worktrees.py process_pending_terminals` (fallback) | `pending-terminal/<agent_id>.json`; the agent-id index (terminal by policy at once) | recorded only for an agent this session has a bound or start record for; consumed the moment the manifest seals; after `PENDING_TERMINAL_GRACE_SECONDS` with no seal, the bound record's prepared members are verified and cleaned as a `pending-terminal-fallback` transaction — no bound record means nothing was owned and the record is dropped |
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
installs it (withheld from a worktree, an ephemeral checkout, a sandboxed
`CLAUDE_CONFIG_DIR`, or a HOME that is not the account's own, for the
engine-pointer reason — and `--force-engine-pointer` does not open a way
through: `gui/<uid>` is machine-wide, and the flag governs the pointer only).

## Recovering work

Every member's HEAD at terminalization is under
`refs/richos/handoffs/<session_id>/<agent_id>/<branch>` in its own repository,
written before the rename. Every non-disposable byte (tracked, staged,
untracked, ignored) is in `worktree-captures/.../member-N/tree.tar`, with
staged blobs under `blobs/<sha>` and `provenance.json` naming repo, path,
branch and HEAD. The member's branch is left alone.

## What the archive is verified against

Every manifest entry, not only regular files: a file's size, mode and
SHA-256; a symlink's mode and target; a directory's mode; no entry in the
archive that the manifest does not name; and the live quarantine's manifest
unchanged since capture. Every index entry whose object is not in the HEAD
tree (`needs_blob` in `index.json`) must have a standalone blob under
`blobs/<sha>` that hashes to it under the repository's object format
(`provenance.json` `object_format`). Any failure voids the capture: the
member goes back to `quarantined`, the quarantine is untouched, and the next
run captures again. Nothing is deleted on the strength of a capture that did
not verify, and every git command the capture needs (`rev-parse`,
`ls-files`, `ls-tree`, `cat-file`, `status`) must succeed or the member is
not `captured` at all.

## Capture privacy, and the encryption policy

A capture holds ignored evidence, and ignored is where secrets live
(`.env.local`, tokens in a log). The policy, stated so it can be argued with:

1. **Private by construction.** Every capture directory is 0700 and every
   archive and blob 0600, by explicit mode at creation and by a 0077 umask
   over the whole reconciler process; `reconcile-terminal-worktrees.test.sh`
   C34 asserts the modes and the mutation harness proves both layers
   load-bearing. Nothing on the machine but this account can read a capture.
2. **Bounded in time.** `CAPTURE_RETENTION_DAYS` (30) deletes the archive
   automatically, inside the launchd job — see Retention below. The window in
   which a captured secret exists at all is that long and no longer.
3. **At rest, the volume's encryption.** `~/.claude/state` lives on the
   operator's home volume; on macOS that is FileVault. The engine does NOT add
   a second, per-archive encryption layer, and the reason is structural: an
   unattended reconciler that must decrypt to verify needs a key it can read
   without a person present, and a key stored where the reconciler can read
   it is the secret again, one directory over. A key held elsewhere (Keychain
   with a user-presence requirement, an agent, a hardware token) turns
   verification into something a person has to be there for, which is the
   babysitting this lifecycle exists to remove.
4. **What changes the answer.** If captures ever leave the account boundary
   — synced, backed up off the volume, or read by another user — item 3 stops
   holding and per-archive encryption with an externally held key becomes
   the requirement. Until then, permissions plus retention plus volume
   encryption is the policy, and it is a decision, not an omission.

## Retention

Automatic, persistent (it runs at the end of every reconciler run, so the
launchd job does it), no user action. Ages count from the transaction's
`removed_ts`:

| What | Key (`orchestration.config`) | Default |
|---|---|---|
| capture directory (`tree.tar`, `blobs/`, `residue-*.tar`, manifests) | `CAPTURE_RETENTION_DAYS` | 30 |
| backup ref `refs/richos/handoffs/<session>/<agent>/<branch>` | `BACKUP_REF_RETENTION_DAYS` | 90 |
| the transaction record and its facts (intent, bound, start, pending, name index) | `TRANSACTION_RETENTION_DAYS` | 90 |

A transaction record is deleted only after every artifact it names is gone,
so nothing on disk is ever orphaned from the record that explains it. The
agent-id terminal index (`terminal/<agent_id>`, ~50 bytes) is kept forever:
an agent id is terminal forever and the resume guard reads it. Hard failures
(`failed`/`missing` members) never reach `removed` and are never expired;
they wait for a person, as they should.

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
`SESSION_START_RECONCILE_BUDGET`, `RICHOS_LAUNCH_AGENTS_DIR`,
`RICHOS_PENDING_TERMINAL_GRACE`, `RICHOS_CAPTURE_RETENTION_DAYS`,
`RICHOS_BACKUP_REF_RETENTION_DAYS`, `RICHOS_TRANSACTION_RETENTION_DAYS`,
`RICHOS_TX_CRASH_AFTER=tx|index|name` (crash injection in `claim_terminal`).
Every suite pins the first two; nothing they do reaches `~/.claude/state`.
