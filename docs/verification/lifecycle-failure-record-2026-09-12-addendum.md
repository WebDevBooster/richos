# Addendum to `lifecycle-failure-record-2026-09-12.md` — the live failures of the daytime, each with its command and output

**Status:** an extension of the CEO's evidence pack, written to be appended to
`richos-hq/docs/verification/lifecycle-failure-record-2026-09-12.md` as its section 11 · **Author:** zach-fable-m1 (round 6) · **Written:** 2026-09-12, 18:31Z–19:05Z
**Why it is a file in this repository rather than an edit of that one:** the round-6 brief (§6) orders the record extended before any RECORDED mutation is derived, and its CEO constraints forbid touching any main checkout; `/Users/alex/ab/richos-hq` is the main checkout of that repository and no richos-hq workspace was cut for this round. So the text is here, numbered as the section it becomes, and every mutation that cites it cites `lifecycle-failure-record-2026-09-12.md addendum §A<n>`. Rich appends it at the land; nothing below changes when he does.
**Which engine every number below is about:** the RUNNING engine, `main` @ `dcabcbd9` via `~/.claude/richos-engine`, which writes `~/.claude/state/worktree-ledger.jsonl` and `~/.claude/state/workspace-retirement/`. The one exception is §A1, which is about the spec store `~/.claude/state/workspaces/` that only the dev branch writes. Nothing here was measured on `c5bce604`, and nothing below compares across the two.
**The command for every number:** `measure-live.py`, committed beside this file's logs at `round6-measurement-2026-09-12-logs/measure-live.py`, run once at 18:32Z; its full output is `round6-measurement-2026-09-12-logs/measure-live.out`. It reads the two ledgers and asks git read-only questions of worktrees of the same repositories; it writes nothing, and the census in the measurement report shows that.

---

## 11. Type A again, in the machinery: four live failures on 2026-09-12, each derivable

### A1. A test wrote four fixture rows into the operator's live spec store

```
$ python3 measure-live.py            # section 1
events.jsonl rows: 7
  2026-09-12T12:44:07Z repo=/private/var/folders/mx/.../T/land-completeness.rSiULs/clean/repo exists=False why='the land-completeness fixture' work=repo-001
  2026-09-12T12:44:07Z repo=/private/var/folders/mx/.../T/land-completeness.rSiULs/mixed/repo exists=False why='the land-completeness fixture' work=repo-002
  2026-09-12T12:44:23Z repo=/private/var/folders/mx/.../T/land-completeness.URJ6Yc/clean/repo exists=False why='the land-completeness fixture' work=repo-003
  2026-09-12T12:44:24Z repo=/private/var/folders/mx/.../T/land-completeness.URJ6Yc/mixed/repo exists=False why='the land-completeness fixture' work=repo-004
integration.json present: False
```

Four `integration-recorded` events, at 12:44Z, for repositories under the temporary directory that no longer exist, written by `land-completeness.test.sh` of the dev lineage into `~/.claude/state/workspaces/events.jsonl` — the operator's own store, not a sandbox. The `integration.json` they created has since been removed; the events remain. This is failure S1/S2 of the 2026-09-11 record recurring (tests writing into his real files, fifth and sixth instance), and it is why the round-6 brief makes a before/after sha256 census of the store a precondition of the round. The dev branch's own fix is `b208ec07` ("No test writes to the operator's real workspace registry"); these four rows predate it.

**Mechanism, for a mutation:** a suite that inherits `CLAUDE_CONFIG_DIR`/`RICHOS_WORKSPACES_DIR` from its environment instead of pinning a sandbox writes wherever the operator's shell points. (Points 3 and 12: a record that a test can write is a record that says nothing.)

### A2. Twenty-two `cc/` branches deleted today, and no deletion event exists anywhere in the running engine's ledger

```
$ python3 measure-live.py            # sections 2 and 3
rows today: 1049
  finished       974
  registered     50
  prepared       25
every distinct event type in the whole ledger: ['finished', 'prepared', 'registered', 'retracted', 'terminated']
prepared cc/ rows today: 25
  cc/zach-opus-f4 ... cc/frank-opus-c6     richos     GONE      (22 rows)
  cc/sage-fable-b1, cc/frank-fable-b1, cc/zach-fable-m1   richos     present   (3 rows)
gone: 22  present: 3
ledger rows (all time) whose event type names a deletion/removal/retirement/discard/land: 0
rows of any OTHER event type mentioning one of the gone branches: 0
```

The running engine's ledger has five event types in its whole history and none of them is a deletion. Twenty-two `cc/` branches it registered today are gone from git (`git rev-parse --verify refs/heads/cc/<name>` fails for each), and not one row anywhere says when, by what, or why. Point 7 ("with the reason recorded") and point 4 ("the branch ... deleted — automatically") both fail on the live machine by this measurement: the deletions were Rich's by hand (the 09-12 record §2c and §5 describe two of them), and the system recorded nothing.

**Mechanism, for a mutation:** a land or discard that deletes and writes no disposition, or a branch deletion that happens outside the two events (point 3). RECORDED mutations `R-p04-branch-left-after-land` and `R-p07-discard-records-no-reason` derive from here.

### A3. 974 `finished` rows for 25 teammates, 973 distinct ids, none carrying a branch

```
$ python3 measure-live.py            # section 4
finished rows today: 974
  carrying a non-empty 'branch': 0
  naming a teammate: 893
  distinct agent_id: 973
  signals: {'SubagentStop': 974}
  sources: {'worker-ended-handoff.sh': 974}
registered rows today: 50 (distinct teammates 25)
native workspaces registered today: 25; of those, whose agent id appears on ANY finished row: 20
  finished rows per native worktree path (top 5): [('.../agent-af5c34ceefd5ffd35', 96), ('.../agent-a008bcb88102957d7', 81), ('/Users/alex/ab/femcboost', 78), ('.../agent-ac1ed926cc7928ccf', 68), ('.../agent-ae0baff6960a09edf', 59)]
```

The platform's `SubagentStop` fires roughly forty times per teammate, once per sub-run, under a per-run id, and the running engine records every one as `finished` — 974 today, 973 distinct ids for 25 teammates, none naming a branch (the 09-10 record §3.4 measured the same over 15,882 rows). That is the incident point 11's first clause exists for: *a `SubagentStop` for a sub-run does not finish the teammate.*

**One fact this measurement adds, and it matters for how the spec code was judged:** for 20 of the 25 native workspaces registered today, the teammate's OWN bound agent id does appear on at least one `finished` row (the five that do not are the agents killed mid-start and the one writing this). So the platform does emit the teammate's own id at its real end of run; the sub-run ids are extra, not instead. The spec code on `c5bce604` keys `record_end` on the bound id and ignores an id it has no registration for (measured as check C11.1 in the round-6 harness), which is the right reading of this data. Whether the FINAL `SubagentStop` of a teammate always carries the bound id is not settled by this measurement (unverified: it would need the ordering of rows per teammate, which the ledger's timestamps could give next round).

**Mechanism, for a mutation:** an end-of-run signal resolved to the teammate by its folder or its session rather than by its own id (09-10 §3.5). RECORDED mutation `R-p11-sub-run-end-finishes-the-teammate` derives from here.

### A4. Two quarantines the removal path created, that no cleanup lane owns

```
$ python3 measure-live.py            # section 5
  worktree /Users/alex/ab/richos-wt/.richos-retired/frank-opus-c6.richos-retired-ws-e1cde08e09b169ca-20260912T161306.969904Z
  worktree /Users/alex/ab/richos-wt/.richos-retired/sage-opus-c6.richos-retired-ws-64577978b30eb0ad-20260912T161239.771266Z
retirements.jsonl rows naming *-opus-c6: 6
  2026-09-12T16:12:40Z retire note           {... 'branch': 'cc/sage-opus-c6', 'id': 'ws-64577978b30eb0ad', 'path': '/Users/alex/ab/richos-wt/sage-opus-c6' ...}
  2026-09-12T16:13:06Z retire in-progress    {... 'branch': 'cc/frank-opus-c6', 'id': 'ws-e1cde08e09b169ca', 'path': '/Users/alex/ab/richos-wt/frank-opus-c6' ...}
  2026-09-12T16:13:07Z retire quarantined quarantined {... 'cc/frank-opus-c6' ...}
  branch cc/frank-opus-c6: GONE
  branch cc/sage-opus-c6: GONE
  femcboost worktree-agent-* branches now: ['worktree-agent-a8350de8d312d2b0d']
```

At 16:12Z and 16:13Z the running engine's `remove-agent-worktree.sh` / `workspace-retire.py` path *renamed* the two reviewers' `cc/` workspaces into `richos-wt/.richos-retired/` (outcome `quarantined`) instead of deleting them. Both are still registered git worktrees of richos, detached at `37bb361c` and `a8fc4203` — commits that ARE on `dev/workspace-spec`. Their branches are gone (§A2), their native halves are gone (the harness auto-cleaned an unchanged tree), and the `cc/` halves remain. The running engine's reconciler reported them as `not-examined=2` in both reviewers' `--preview` runs (brief-audit-frank-round6 P5, brief-audit-sage-round6 §4.3; not re-run here, because that tool is `main`'s and its run could append to the ledger under census). Point 10 ("none is left behind") and point 4 ("no quarantine directory", the round-6 check) fail on the live machine by this measurement.

**Mechanism, for a mutation:** a removal that moves the workspace instead of deleting it, and deletes only one of an agent's two workspaces. RECORDED mutations `R-p04-quarantine-instead-of-delete` and `R-p10-cc-workspace-left-behind` derive from here.

### A5. The ledger moves through nobody's action, which the census must allow for

```
$ bash census.sh                                   # 18:31:38Z, before the round's first command
e6bf7d4a...  /Users/alex/.claude/state/worktree-ledger.jsonl (19691 lines)
$ cp ~/.claude/state/worktree-ledger.jsonl ledger-before.jsonl; wc -l ledger-before.jsonl    # ~90 s later
19701
```

Ten rows appended in ninety seconds by the running engine's own hooks (`worker-ended-handoff.sh`, every `SubagentStop` of the 27 agents live in this session), through no command of this round. A census that hashes the ledger will always differ after; the honest form is a line-level diff of the after-copy against the before-copy showing only appended rows, each from a hook source, none from any command the round ran. The measurement report does exactly that.
