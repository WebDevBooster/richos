# The ownership ledger: census, consumers, and 5,072 rows that were never real

**Zach — 2026-09-14.** Worktree `/Users/alex/ab/richos-wt/zach-opus-n7`, branch `cc/zach-opus-n7`.
Subject: `~/.claude/state/worktree-ledger.jsonl`, the durable ownership record named in `CLAUDE.md`.

This is the operator's real machine state, not a repository. Nothing below was deleted before it was
shown to be dead, and the 163 rows that could not be shown to be dead are still in the file.

---

## 0. The answer first

The file was carrying **5,072 test-fixture rows — 23% of it — that nothing reads.** They are gone,
after a backup, and every consumer gives the same answers it gave before. **But the leak that put them
there is still open**, and its fix site is one line in a file this task put out of scope. The backlog
was the symptom; the open writer is the problem, and it is raised as
`esc-20260914T015351Z-7f951af7`.

**Two premises in my brief were false, and both mattered:**

| Briefed | Measured |
|---|---|
| "21,316 rows" | **21,993** at session start, **22,015** at the prune. It grows ~1,800/day, so any single number is a timestamp, not a size. |
| "a prior session's record says 3,536 fixture rows" | **5,235** rows name a sandbox path. The 3,536 figure matches nothing I can reproduce. |
| "`containers.test.py` gained a per-process sandbox and `land-completeness.test.sh` L21 exists to catch exactly this class" | **Both guard a different file.** They cover `RICHOS_WORKSPACES_DIR`, the workspace registry. The ledger is reached through `HOME` and neither touches it. **No guard covers this class.** |

That last row is the finding. The class was believed covered, so nobody looked.

---

## 1. What was in it

Measured at 22,014 rows (the file is appended to continuously; counts drift between commands).

```
$ wc -l ~/.claude/state/worktree-ledger.jsonl
   21993
$ stat -f '%z bytes' ~/.claude/state/worktree-ledger.jsonl
7951160 bytes
```

**By event:** `finished` 21,115 · `registered` 692 · `prepared` 158 · `terminated` 48 · `retracted` 1.

**By writer:**

```
  18130  worker-ended-handoff.sh          166  create-teammate-worktree.sh
   1750  teammate-idle-handoff.sh          41  reaper-observation
   1215  task-completed-handoff.sh          3  remove-agent-worktree
    680  detect-nonnative-worktree.sh       3  rich-observed-return
                                            2  rich-land-binding
                                            2  rich-operator-amnesty
                                            1  platform-terminal-record
                                            1  round-15-record
```

**By day:** 2026-09-02 through 2026-09-14, never fewer than 39 rows a day and as many as 3,445.
**48** distinct sessions, **220** distinct teammate names — and **16,512 rows carry a blank
`teammate`**, which is not corruption: `assignment_workspaces()` documents that the `SubagentStop`
payload does not carry the name.

**96% of the file is one row type from one hook:** a `finished` row per teammate turn. That is the
growth curve, and it is working as designed.

---

## 2. The fixture rows: what they are and how one is told from a real one

A fixture row is distinguishable with certainty, and the distinguishing mark is not a name or a
session — it is the **path**. Every one names a directory under the system temp root, created by
`mktemp`:

```json
{"agent_id": "", "event": "registered", "repo": "/var/folders/mx/.../T/contract-integrity.XXXXXX.O4pkHUUxOn",
 "session_id": "", "source": "detect-nonnative-worktree.sh", "teammate": "reed-sonnet-sc1",
 "ts": "2026-09-02T09:10:30.719266+00:00", "worktree": ""}
```

No real workspace has ever lived in `$TMPDIR`. Grouped by the `mktemp` prefix, which names the suite
that made it:

```
  3576  newest=2026-09-13T22:11:02  contract-integrity.XXXXXX.*
  1448  newest=2026-09-13T16:58:48  richos-engine-demo.*
    54  newest=2026-09-03T01:16:27  detect-nonnative-worktree.XXXXXX.*
    16  newest=2026-09-04T10:14:25  sc1probe.XXXXXX.*
   ~140  newest=2026-09-09T15:47:01  richos-owned-wake-native-* (many single-run dirs)
```

`contract-integrity.XXXXXX` is minted at `engine/scripts/hooks/contract-integrity.test.sh:841`.

**The prior record's `3,536` is wrong.** Its one checkable component is right: `certification-sage-
round5-2026-09-11.md` line 252 reports **325** rows for `reed-sonnet-sc1`, and `grep -c` returns 325
today. The total was not.

---

## 3. Is the leak closed? No.

**The mechanism.** `worktree-ledger.py:184` sets
`DEFAULT_PATH = os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-ledger.jsonl")`,
read once at import, and `ledger_path()` (line 232) accepts exactly one override:

```python
def ledger_path():
    return (os.environ.get("RICHOS_WORKTREE_LEDGER") or "").strip() or DEFAULT_PATH
```

So the ledger is reached through **`HOME`**. It does not read `CLAUDE_CONFIG_DIR`, and that is
deliberate and already proven by experiment — `demo.sh:139-142` records pointing `HOME` and
`CLAUDE_CONFIG_DIR` at two different empty directories and finding that every file landed under
`HOME/.claude`. A suite that sandboxes itself with `CLAUDE_CONFIG_DIR` alone and then drives a real
hook writes to the operator's ledger.

**Two of the three arms are closed:**

- `demo.sh` exports `RICHOS_WORKTREE_LEDGER` (line 151) as of **`631ddbdd`, 2026-09-13 18:59Z**. Its
  last leaked row is **16:58Z** — before the fix. Closed, and the timestamps agree.
- `sandbox-completeness.sh` gained `export HOME="$root/.sandbox-completeness-home"` at **`7b26344c`,
  2026-09-13 20:52Z**, with a header naming this exact class. Closed.

**The third arm is open.** At `a620ac1e`:

```
$ grep -n 'HOME=' engine/scripts/hooks/contract-integrity.test.sh
$ echo $?
1
```

**Zero `HOME` assignments in the file.** Every hook it drives against a `make_sandbox` root that does
not route through `sandbox-completeness.sh` appends to the real ledger. **40 rows arrived after the
`7b26344c` fix**, in four batches of ten, all naming `contract-integrity.XXXXXX.*` roots, the newest at
`2026-09-13T22:11:02Z`.

**Why nothing caught it.** `record-canary.sh` watches the ledger per suite but **excludes `finished`
rows by design** — the platform writes them constantly — and `finished` is exactly what the three
handoff hooks write. `sandbox-completeness.sh`'s own header says the leak "happened on every
workstation run too; it was simply invisible there."

**The fix is one line** in that suite's setup, of the shape `7b26344c` already used:
`export HOME="$SANDBOX_HOME"` beside the existing `CLAUDE_CONFIG_DIR` at line 209.
**I did not write it: my brief puts that file out of scope and a teammate was committing to it
tonight** (`48cd5e13`, 02:46). Raised as `esc-20260914T015351Z-7f951af7`, state `proceeding`.

---

## 4. Who reads this file, and what a wrong row costs

This decided what could be deleted. Thirty-six files reference the ledger; after excluding
`.test.`/`.mutation.` harnesses the production readers are:

| Reader | Reads | What a wrong row does |
|---|---|---|
| `worktree-ledger.append()` | **`read_all()` on EVERY write**, via `resolve_assignment()` | Enriches a finish row with `workspaces`/`teammate`. A fixture row cannot contribute: it is filtered by `session_id` and its `worktree` is `""`, which `add()` discards. |
| `registrations()` | exact `worktree` path | **Exact-path match, and name matching is off for every destructive caller** by explicit design ("tombstone poisoning", finding 4). A fixture path matches no real worktree. |
| `prepared_records()` | every filter exact | Same. No prefix, no basename, no convention. |
| `terminations()` / `retractions()` | `agent_id` | Fixture ids (`a2222222222222222`, `q4dead`, `deadbeefcafe0001`) collide with no platform id. |
| `registered_paths()` → `paths` CLI | all ownership rows | **Did carry 14 fixture paths.** Reporting. |
| `registered_names()` → `names` CLI | all ownership rows | **Did carry 4 fixture names.** Used "by the reaper for repository ELIGIBILITY only — never as liveness". |
| `land-completeness.py` | `read_all` + `registrations(worktree=)` | Exact path. |
| `agent-liveness.sh`, `unlanded-branches.py`, `judge` | via the above | Unaffected. |
| `bound_members()` | — | Returns `[]` always; the transaction store was removed 2026-09-11. |

**The conclusion that authorized the deletion:** every reader with destructive or decisive authority
matches on an **exact path or an exact agent id**. A fixture row names a path that has not existed
since the suite exited. It is unreachable by every one of them. The only readers that saw the fixture
rows at all were the two **reporting** CLIs — and what they reported was noise.

**Cost of size, measured rather than assumed:**

```
read_all() over 22,000 rows, 5 runs: 0.035 0.038 0.037 0.039 0.035 s  (median 0.037)
```

**37 ms.** Eight megabytes is not an operational emergency today, and it would have been dishonest to
sell this as a performance fix. It matters because `append()` calls `read_all()` on every write, so
the cost is quadratic in a file that grows ~1,800 rows/day with no upper bound.

---

## 5. What was removed, and what deliberately was not

A row was removed only when **all four** held — it parses as an object, it names at least one path,
**every** path is under a temp root, and **none** of those paths exists on disk — plus a flat refusal
on any row mentioning `codex` (`ceo-decisions.md` §31). **Zero candidate rows mentioned `codex`**, so
no CEO ruling was needed.

```
rows before  : 22015  (7962192 bytes)
provably dead: 5072
rows after   : 16943  (6417958 bytes)
kept because :
      16779  names a real (non-temp) path
        163  sandbox still on disk
          1  names no path
backup       : /Users/alex/.claude/state/ledger-backups/worktree-ledger.20260914T020004Z.jsonl (22015 rows)
```

**163 rows stayed because their sandbox directory still exists** and might belong to a suite running
right now. They are ambiguous, so they stayed, and they are counted here rather than absorbed.
**0 rows named both a sandbox and a real path** — worth re-measuring, never assuming.

**Backup:** `/Users/alex/.claude/state/ledger-backups/worktree-ledger.20260914T020004Z.jsonl`, outside
every repository, verified at 22,015 rows before a byte was changed. The tool refuses to prune if the
backup is short.

---

## 6. Proof that nothing broke

Every read-only consumer was run against the file **before** and **after**
(`scratchpad/consumers.sh`). **Every exit code is identical.**

| Consumer | before | after |
|---|---|---|
| `paths` | rc=0, 321 | rc=0, **307** |
| `names` | rc=0, 191 | rc=0, **187** |
| `shells` | rc=0, 138 | rc=0, 138 |
| `branches --repo richos` | rc=0, 152 | rc=0, 152 |
| `branches --repo femcboost` | rc=0, 143 | rc=0, 143 |
| `registrations --worktree …` (×2) | rc=1, 0 | rc=1, 0 |
| `prepared --worktree …` | rc=1, 0 | rc=1, 0 |
| `judge --entity … --worktree …` | rc=0, 6 | rc=0, 6 |
| `agent-liveness.sh` | rc=10, 14 | rc=10, 14 |
| `unlanded-branches.py` | rc=0, 12 | rc=0, 12 |

Two outputs shrank, and **every item they lost is named here** rather than asserted to be harmless:

- **14 paths**: 13 under `/var/folders/.../T/detect-nonnative-worktree.XXXXXX.*/​.claude/worktrees/agent-deadbeefcafe0001`, plus `/private/tmp/fable-check/victim` (its row names `teammate: victim-opus-v1`, `repo: /private/tmp/fable-check/repo`; both absent from disk).
- **4 names**: `dev-sonnet-led1`, `dev-sonnet-led2`, `reed-sonnet-sc1`, `victim-opus-v1` — all fixtures.

**Nothing was added to any output**, which is the check that would have caught a rewrite.
No real workspace path and no real teammate name was lost.

---

## 7. The tool

`engine/scripts/ledger-prune-sandbox.py`, with `engine/scripts/ledger-prune-sandbox.test.sh`
(**13 passed, 0 failed**).

Default mode is a **census that changes nothing**; `--apply` backs up first and refuses `--no-backup`
on the real ledger. Surviving lines are copied **byte-for-byte**, so the append-only record is never
rewritten. Because the hooks append without a lock, the tool records its read offset and copies any
bytes that arrive during the prune verbatim onto the end, repeating until the file stops growing;
rows arriving in the final milliseconds before `os.replace()` are the residual race, so run it on an
idle machine.

**Eleven of the thirteen test cases are rows the tool must NOT touch** — a real workspace, a mixed
sandbox/real row, a sandbox still on disk, an unparseable line, a path-less row, a `codex` row.
**P7 is the positive control**: without a case proving the predicate can fire, a tool that never
deletes anything would pass every other case and look perfect.

**Idempotence, on the real file, not a fixture:**

```
second --apply run:  rows before 16944 · provably dead: 0 · "nothing to remove; ledger left untouched"
```

(16,943 → 16,944 between runs: a live agent appended a row, which is the tail preservation working.)

---

## 8. Commands, to re-derive any number above

```bash
wc -l ~/.claude/state/worktree-ledger.jsonl
grep -c 'reed-sonnet-sc1' ~/.claude/state/worktree-ledger.jsonl                    # 325
grep -n 'HOME=' engine/scripts/hooks/contract-integrity.test.sh ; echo $?          # no output, 1
sed -n '184p;232,233p' engine/scripts/lib/worktree-ledger.py                       # DEFAULT_PATH, ledger_path
git log --format='%h %ad %s' --date=iso -S'RICHOS_WORKTREE_LEDGER' -- engine/scripts/demo.sh
git log --format='%h %ad %s' --date=iso -S'sandbox-completeness-home' -- engine/scripts/lib/sandbox-completeness.sh
engine/scripts/ledger-prune-sandbox.py            # census, changes nothing
engine/scripts/ledger-prune-sandbox.test.sh       # 13 passed, 0 failed
```

---

## 9. What is still owed

1. **The open writer.** One `export HOME=` in `contract-integrity.test.sh`. Out of my scope;
   `esc-20260914T015351Z-7f951af7`. **Until it lands, the backlog regrows** — about 3,576 rows'
   worth since 2026-09-02.
2. **No guard covers the ledger.** L21 proves no sibling suite leaves `RICHOS_WORKSPACES_DIR`
   un-redirected. **There is no equivalent asking the same question of `HOME` or
   `RICHOS_WORKTREE_LEDGER`**, and `record-canary.sh` cannot see it because it excludes `finished`
   rows. Building one means changing a guard's refusal conditions, which this task forbids, so it is
   named here rather than done.
3. **The 163 ambiguous rows** will become removable once their directories are gone. Re-running the
   tool takes them; it is safe to run on a schedule.
