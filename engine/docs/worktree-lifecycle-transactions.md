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
| spawn intent | `guard-worktree-isolation.sh` clause 7 (PreToolUse[Agent]) | `intents/<tool_use_id>.json` — the exact member set | an external path has no `prepared` record for this session and teammate, its repo or branch drifted, `run_in_background: false`, a lifecycle component is missing, or the spawn is cwd-only (external-only: no platform-owned lifecycle witness — spawn with `isolation: "worktree"` and a `cross-repo-worktree:` line instead; CEO specification 2026-09-03 section 6) |
| bind | `detect-nonnative-worktree.sh` (PostToolUse[Agent]) | `bound/<agent_id>.json` — intent + agent id | no intent, no agent id (synchronous run), or a rebind: announced loudly, exit 2 |
| start fact | `record-subagent-start.sh` (SubagentStart) | `starts/<agent_id>.json` — the worker's exact cwd | never; it cannot block and does not pretend to |
| seal | `worktree-transactions.py try_seal` (called by both writers above and by the barrier) | `<agent_id>.json` with `sealed: true` | the cwd is not `agent-<id>`, not a linked worktree git lists, or not the prepared external path |
| de-materialize the shell | `scripts/lib/shell-worktree-sparse.py` (called by `try_seal`, once, straight after the seal) | `sparse` on the native member — applied or refused, with the reason and the measured before/after sizes | the spawn is not `native+external`, the member is past `bound`, the transaction is terminal, the shell has any uncommitted path, it is already sparse, a submodule is initialized, a git operation is in progress, the path is not the registered non-prunable worktree recorded, `SHELL_SPARSE` is off, or enabling `extensions.worktreeConfig` would change how the main checkout reads its own config; a git failure or a failed post-condition is rolled back with `sparse-checkout disable` |
| write barrier | `guard-sealed-worktree.sh` (PreToolUse, matcherless, first) | nothing | the manifest is not sealed (after waiting `SEAL_WAIT_SECONDS`): every tool but `SEAL_READONLY_TOOLS` is refused; a terminal agent (by index, by transaction, or by a pending terminal event) is refused everything; and the barrier FAILS CLOSED on its own error — python3 missing, the library missing, the root unresolvable, the payload unparseable, the resolver raising — refusing every potentially writing or unknown tool and passing only a proven lead call or a proven read-only tool (probe Layer Q6 proves it live) |
| terminal claim | `terminalize-agent-worktrees.sh` (SubagentStop by its OWN agent id — never a cwd, nested agents run inside the parent's cwd; WorktreeRemove by exact native path; PostToolUse[TaskStop] by the task id the RESULT returned, never the requested name) | `terminal` on the transaction; backup refs; quarantines; the terminal indexes — the named native path first, one member at a time | never blocks; an agent with no sealed transaction produces no claim — its event is persisted as `pending-terminal/<agent_id>.json` instead (below) |
| pending terminal | `worktree-transactions.py claim_terminal` (unsealed) → `try_seal` (consumes) → `reconcile-terminal-worktrees.py process_pending_terminals` (fallback) | `pending-terminal/<agent_id>.json`; the agent-id index (terminal by policy at once) | recorded only for an agent this session has a bound or start record for; consumed the moment the manifest seals; after `PENDING_TERMINAL_GRACE_SECONDS` with no seal, the creation-time members are verified and cleaned as a `pending-terminal-fallback` transaction: the bound record's prepared trees, plus the exact native worktree a start fact or a WorktreeRemove first_path names (with or without a bound record); an agent with no verifiable member becomes a zero-member terminal tombstone — a recorded terminal event is never reinterpreted as if it had not happened |
| native-gone backstop | `scripts/reconcile-terminal-worktrees.py orphan_backstop_pass` (every reconciler pass) | the claim (ingress `NativeMemberGone`) on a sealed transaction whose exact native member is absent or no longer registered in its recorded repository; the native member closed absent with its backup ref from `head_at_seal`; every hand-rolled member quarantined and retired by the normal state machine | git that cannot be read decides nothing; a present, registered native member is never claimed |
| TeammateIdle (not an ingress) | `teammate-idle-handoff.sh` (log-only) | each payload's top-level key names and identity/type/task fields in `idle-events.jsonl` — the measurement fixture | it never fired live on this machine; it holds no destructive authority until an observed field is proven to join to the ownership id |
| resume refusal | `guard-resume-isolation.sh` (PreToolUse[SendMessage]) | nothing | the recipient's agent id or session-scoped name is terminal — before `resume-ack:`, before protocol bodies |
| capture → removal | `scripts/reconcile-terminal-worktrees.py` (launchd every `RECONCILE_INTERVAL_SECONDS`; SessionStart with a budget) | member states `captured → verified → unregistered → removed`; the archive | never permanently: a transient failure is recorded on the member and retried with persistent backoff (`RECONCILE_RETRY_BACKOFF_SECONDS`, doubling to `RECONCILE_RETRY_BACKOFF_MAX_SECONDS`), reported once after repeated failures and retried on; both-present, a vanished path, a drifted HEAD, a lost backup ref, an unreadable git state and a legacy `failed` record each have an automatic close (below) |

## The never-read shell, and why it is not a full checkout

A cross-repository teammate owns **two** worktrees: the one it edits, in the
repository it was sent to, and a native isolation worktree in the session's own
repository. The second is not a workspace. It exists because no `WorktreeRemove`
ever names a hand-rolled worktree, so without it the worker's death is
permanently undecidable (`richos-hq/wiki/worktree-lifecycle.md` §1). **The shell
buys decidability and it stays.**

Measured on this machine, 2026-09-04: one such shell was **266 MB**, of which
**202 MB** was accumulated screenshots under `qa-audits` and 17 MB was
application code. The capture store held 16 GB; `member-0` — the shell — was
**38 archives, 9.9 GB, mean 266 MB**, against `member-1`'s 41 archives and
6.5 GB. Nothing had ever read or written a byte of it.

So at seal — the first moment the member set is known and bound to an agent id —
`scripts/lib/shell-worktree-sparse.py` runs

```
git -C <shell> sparse-checkout set --cone .claude .githooks
```

Cone mode keeps every **top-level file** and skips every subdirectory. In a
fixture that took a 3936 KB shell to **20 KB**. The archive shrinks with it and
**no archive code changed**, because `build_manifest` walks the disk rather than
git's index: a shell with nothing materialized produces a near-empty manifest.

Top-level files are kept deliberately. An agent told to write `BLOCKED.md` at
the root of its worktree and commit it can still do exactly that; under an
empty pattern set `git add` would have refused the path. Cheap is not worth a
broken escalation channel.

**Why not the platform's own setting.** `worktree.sparsePaths` (Claude Code
2.1.76) checks out only named directories "via git sparse-checkout", and a later
release fixed `extensions.worktreeConfig` cleanup "after the last
`worktree.sparsePaths` worktree was removed". The platform therefore creates
sparse worktrees deliberately and tolerates them by design — which is
corroboration worth having. It is still the wrong instrument for this: its
changelog entry names `claude --worktree` only, where the `worktree.baseRef`
entry explicitly enumerates "`--worktree`, `EnterWorktree`, and agent-isolation
worktrees", so whether it reaches an agent-isolation worktree is **unproven**;
and it is repository-wide, so it cannot tell a never-read shell from a plain
native worker's workspace. Stripping the second is the outcome this design
exists to avoid. The decision belongs to the transaction, which knows the spawn
kind.

**What is never removed.** Only tracked files whose content is at HEAD, and
therefore in the object store, are de-materialized. Untracked files are
untouched, ignored files are untouched (the `.worktreeinclude`-seeded `.env`
copies survive), and a modified file is left where it is — git says so in a
warning and this module refuses before git gets the chance: `git status
--porcelain` must be EMPTY or the shell is left at full size with the reason
recorded on the member. A teammate that writes into a sparsified shell anyway
has its bytes archived byte-for-byte, proven end-to-end in
`reconcile-terminal-worktrees.test.sh` C64.

**It refuses** an already-sparse shell, a shell that has been written to, a
transaction already terminal (never race the capture), a plain `native`
spawn — whose worktree *is* its workspace — a shell with an initialized
submodule, one mid-merge or mid-rebase, anything that is not the registered
non-prunable linked worktree the transaction recorded, and a repository where
enabling `extensions.worktreeConfig` would change how the **main checkout**
reads `core.bare` / `core.worktree`. After the operation it re-verifies status,
registration and existence, and rolls back with `sparse-checkout disable` if any
of the three is missing.

**Git exits 0 when it could not remove a file** (an unwritable directory, a file
that is not up to date). The exit code cannot tell a shell that shrank from one
that did not, so the warnings are recorded verbatim beside the before and after
sizes.

To restore one by hand, or to see one before deciding:

```
python3 <engine>/scripts/lib/shell-worktree-sparse.py inspect --path <shell>
python3 <engine>/scripts/lib/shell-worktree-sparse.py restore --path <shell>
```

Policy: `SHELL_SPARSE` and `SHELL_SPARSE_KEEP` in `orchestration.config`; `off`
restores the previous behavior exactly. `--status` carries `shells_sparsified`,
`shells_sparse_refused` and `shell_bytes_freed`; the refusal counter is there
because a number that only went up would report a policy that sometimes
declines as one that always applies.

**What would falsify this, and what would close it.** It is falsified by any of:
a shell whose bytes were lost rather than de-materialized; a `WorktreeRemove`,
`SubagentStop` or `TaskStop` that stops joining to a sparsified shell; a
native-disappearance backstop that stops firing for one; a teammate that needed
its shell materialized and found it empty; or a platform that starts treating a
sparse worktree it created as damaged. The round is **not closed**: closure is
30 days of live operation in which `shells_sparsified` climbs, `shell_bytes_freed`
is non-trivial, no member reaches `failed` with a `sparse` block recorded, and
no capture verification fails — measured from `--status`, not from memory.

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

**A real install FAILS (exit 1) unless that job is loaded and verified**
(review 2026-09-03, blocker 7): `install.sh` boots the old job out,
bootstraps the new plist, and requires `launchctl print` to show the job
loaded and naming this checkout's reconciler. It never asks anybody to load
anything by hand; re-running it from the landed main checkout IS the upgrade
path. Until the job is healthy, `guard-worktree-isolation.sh` clause 7e
refuses every file-writing spawn on the machine and names that command as
the fix (a job pointing at a reconciler that no longer exists — a removed
worktree — is refused the same way). The reconciler writes
`~/.claude/state/worktree-transactions/last-run.json` on every run, so
"loaded" and "ran" are separately checkable. Tests load a live job under
`com.richos.worktree-reconciler.test-<id>` — the only label
`RICHOS_LAUNCHD_LABEL` may name — against a store redirected through the
plist's `EnvironmentVariables`, and boot it out.

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
an agent id is terminal forever and the resume guard reads it. No member
waits for a person: every condition retries or closes automatically (next
section), so every transaction reaches `removed` and expires.

## What a persistent failure looks like, and why nobody has to act

Landed review 2026-09-03, blocker 3: until that revision `failed` and
`missing` were permanent member states that "remain until an operator
resolves them" — babysitting as a lifecycle state. Now every condition has one
of two automatic policies, and `--status` reports trouble without ever
transferring cleanup to a user.

**Retry, with persistent backoff.** Anything transient — disk full, a git
command that failed, an archive that did not verify, a manifest that would
not settle, a process that would not die — keeps the quarantine exactly where
it is and records the attempt, the reason and a `retry_after` time on the
member (base `RECONCILE_RETRY_BACKOFF_SECONDS`, doubling per attempt up to
`RECONCILE_RETRY_BACKOFF_MAX_SECONDS`, persisted so the schedule survives a
restart). After `MAX_SOFT_ATTEMPTS_BEFORE_NOTICE` attempts it is reported once
(`<agent_id>.json.member-N.notice` beside the transaction) and the retries
continue. When the external condition clears, the next run finishes it.

**Blocked, and reported apart from a retry.** Some conditions do not clear by
waiting at all, and calling them a retry reports a deadlock as a process under
control. A blocked member is still retried — nothing is parked for a person —
but it is retried at the BASE interval rather than a compounding one (its
condition changes discontinuously, so there is no gradient to back off along),
it carries `blocked: true` and `blocked_reason` naming the precondition that
refused, and `--status` counts it separately as
`members_blocked_on_a_condition_waiting_cannot_clear`. When any member is
blocked the SessionStart banner's verdict word is BLOCKED, not PENDING.

Measured 2026-09-04, and the reason this class exists: thirty verified members
sat behind the harness lock (below) for a full day, each reported as a normal
retry with a backoff compounded to 21600 seconds.

**The harness lock, and the only place a lock is ever broken.** Claude Code
locks an agent's native worktree, and git refuses to remove a locked working
tree with a single `--force`. That lock names the SESSION's pid — one process,
every agent of that session — so it is released when Claude Code exits and
never when an agent finishes. Inside one long session a quarantine could
therefore never be removed, and one accumulated per dispatch.

`unregister_member` releases that lock, on this member's own quarantine only,
under five preconditions read at the instant of the act: the member is
`verified` with its archive directory on disk; the transaction is terminal
with a recorded per-agent ingress; the path is exactly the canonical
quarantine name for this session and agent and git lists it as that exact
non-prunable registration; the lock is signed by this member's own agent id;
and the backup ref is present. Any refusal is BLOCKED — the quarantine stands
untouched and the refused precondition is named on the member. The lock line
that was broken is recorded (`lock_broken_line`) as evidence.

This is not a new authority to remove. The authority was exercised at the
terminal ingress that renamed the directory out of the agent's path; what is
left is the last mechanical step of a decision already on disk, over a
directory that is nobody's workspace and whose bytes are archived and
re-verified. A lock signed by any OTHER agent is never broken.

**Archive-and-close, deterministically.** Anything that will never change by
waiting:

| Condition | Automatic outcome |
|---|---|
| both the original and the quarantine exist | the quarantine (its name embeds the session prefix and the agent id, so it is this member's own) proceeds; the original is archived as `residue-<n>.tar`, verified against `residue-<n>.manifest.json`, then removed — unless git registers it as ANOTHER worktree, in which case it is recorded (`foreign_worktree_at_original`) and never touched |
| the path vanished | closed absent: the backup ref re-created from the recorded head while the commit object survives, the absence recorded (`closed: absent`, `head_preserved`), the member removed |
| the quarantine's HEAD moved after the ref was saved | the exact bytes are already captured; the moved HEAD is saved under `<backup-ref>@drift-<n>`, the drift recorded (`head_drift`), the member proceeds |
| git can neither read the directory nor list it | the raw bytes are captured and verified (`capture_kind: raw-bytes`); the backup ref comes from `head_at_seal` |
| the backup ref is gone | re-created from the recorded head while the object survives, else recorded lost (`backup_ref_lost`; the verified archive holds the tree) |
| no repository is recorded | read from the quarantine; if neither, there is no registration to remove |
| a state this revision does not drive (`failed` from an earlier revision, or unknown) | re-derived from what exists on disk (`rederived_from`): bound, ref_saved, or closed absent |

Nothing here searches for something with a similar name, and nothing here
asks a person to look.

## Test affordances

`RICHOS_WORKTREE_TX_DIR`, `RICHOS_WORKTREE_CAPTURE_DIR`,
`RICHOS_RECONCILE_SETTLE`, `RICHOS_RECONCILE_NO_KILL=1`, `SEAL_WAIT_SECONDS`,
`SESSION_START_RECONCILE_BUDGET`, `RICHOS_LAUNCH_AGENTS_DIR`,
`RICHOS_PENDING_TERMINAL_GRACE`, `RICHOS_RECONCILE_BACKOFF_BASE` (0 disables
backoff), `RICHOS_RECONCILE_BACKOFF_MAX`, `RICHOS_CAPTURE_RETENTION_DAYS`,
`RICHOS_BACKUP_REF_RETENTION_DAYS`, `RICHOS_TRANSACTION_RETENTION_DAYS`,
`RICHOS_TX_CRASH_AFTER=tx|index|name` (crash injection in `claim_terminal`).
Every suite pins the first two; nothing they do reaches `~/.claude/state`.
