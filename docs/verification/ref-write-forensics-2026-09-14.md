# Who moved `refs/heads/main` without a reflog message — /Users/alex/ab/richos

**Every event is identified. None is left unattributed.** Five are now known:
the three from 2026-09-13 in the original brief, and two more that fired at
00:09 on 2026-09-14 while this was being written.

| # | Local time | main moved | Writer | Deliberate? |
|---|---|---|---|---|
| 1 | 09-13 18:09:09 | `74b3c02b` → `71698811` | Lead session `16a15be1`: `git commit-tree` + `git update-ref refs/heads/main "$c" main` | Yes |
| 2 | 09-13 18:23:13 | `ced9cfb8` → `2af4f032` | Lead session `16a15be1`: `git commit-tree` + `git update-ref refs/heads/main "$C"` | Yes |
| 3 | 09-13 23:41:29 | `082ef5cd` → `2ed41109` | **Running engine**, `workspaces.py:2318`, for agent `zach-opus-ci4` | **No** |
| 4 | 09-14 00:09:14 | `953b0369` → `082ef5cd` | **Running engine**, same line, for agent `sage-opus-v1` | **No** |
| 5 | 09-14 00:09:26 | `082ef5cd` → `953b0369` | **Running engine**, same line, for agent `tom-opus-h3` | **No** |

Events 1 and 2 are one phenomenon — a person curating main by hand through
plumbing. Events 3, 4 and 5 are a second phenomenon that leaves the same trace.
**They are two mechanisms, not one fired five times, and only the second is a
defect.**

---

## 1. Why the reflog message was empty, established by experiment

`commit`, `merge`, `reset`, `pull` and `checkout` all supply a reflog message.
An empty one means the ref went through git's ref backend with no message.

Run in a throwaway clone under `/tmp` with `GIT_CONFIG_GLOBAL=/dev/null`, every
candidate against `refs/heads/main`:

| Candidate | Reflog message produced |
|---|---|
| `git update-ref <ref> <sha>` (no `-m`) | **EMPTY** |
| `printf 'update <ref> <sha>' \| git update-ref --stdin` | **EMPTY** |
| `git commit-tree ...` then `git update-ref <ref> <new>` | **EMPTY** |
| `git update-ref --no-deref <ref> <sha>` (no `-m`) | **EMPTY** |
| `git update-ref -m <msg> <ref> <sha>` | the message |
| `git update-ref -m "" <ref> <sha>` | *refused*: `fatal: Refusing to perform update with empty message.` |
| `GIT_REFLOG_ACTION="" git reset --hard <sha>` | `: updating HEAD` — **not empty** |
| `printf '%s\n' <sha> > .git/refs/heads/main` | **no reflog entry at all** |

Two results narrow the field rather than widen it, and both matter:

- **`-m ""` is impossible.** The message was *absent*, never blank.
- **A raw write to `.git/refs/heads/main` leaves NO entry.** Every event left an
  entry, so none was a direct file or `packed-refs` write. That entire class is
  ruled out by evidence, not by argument.

### The line reproduced, next to the real one

```
### reflog: refs/heads/main ###            <- REPRODUCED (throwaway clone)
031fcda main@{2026-09-14 01:09:55 +0100}:
fa52f7f main@{2026-09-14 01:09:55 +0100}:
cb3ae93 main@{2026-09-14 01:09:53 +0100}: commit: second
```

```
### reflog: refs/heads/main ###            <- REAL, /Users/alex/ab/richos
082ef5cd main@{2026-09-13 23:42:55 +0100}: reset: moving to 082ef5cd
2ed41109 main@{2026-09-13 23:41:29 +0100}:
082ef5cd main@{2026-09-13 23:41:28 +0100}: merge cc/zach-opus-ci4: Fast-forward
```

Identical shape: the sha, `main@{...}`, `: `, nothing after it. **The same write
also lands in HEAD's reflog** when the branch is checked out, with the same
empty message — reproduced, and true of every real event. That is what makes
these entries look like a checkout or a reset when they are neither.

---

## 2. Events 1 and 2 — the lead's own hand, verbatim

Both are in the lead session's transcript
(`~/.claude/projects/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143.jsonl`),
matching the reflog to the second (transcript UTC, reflog BST).

**Event 1 — `2026-09-13T17:09:09.484Z` = 18:09:09 BST:**

```
cd /Users/alex/ab/richos && c=$(git commit-tree 92d459ad8ff8... -p main -m "Round 9's engineer report and its logs, documents only
...") && echo "commit $c" && git update-ref refs/heads/main "$c" main && git log -1 --format='%H %s' main
```

**Event 2 — `2026-09-13T17:23:13.075Z` = 18:23:13 BST:**

```
cd /Users/alex/ab/richos && T=$(git rev-parse a6a9e888^{tree}) && C=$(git commit-tree "$T" -p ced9cfb8 -m "Reset main to a6a9e888 — the install, and nothing else
...") && git update-ref refs/heads/main "$C" && git reset --hard main >/dev/null && ...
```

`git update-ref refs/heads/main "$c" main` — no `-m`. That is the whole
explanation. The `git reset --hard main` in event 2 produced the
`reset: moving to main` entry on HEAD in the same second; `git reset --hard
71698811` seven seconds after event 1 produced the `18:09:16` one.

`2af4f032`'s own message says why plumbing was used at all:

> main is protected, so this restores the tree instead of rewriting history.

**A person doing a deliberate, documented thing — not a defect.** What it cost
was attribution: the reflog recorded that main moved and nothing about who.

---

## 3. Events 3, 4 and 5 — the running engine

**This is the defect. It is in the shipped engine and it is live.**

The engine attributes all three itself, in `~/.claude/state/workspaces/events.jsonl`:

```json
{"branch":"main","event":"protected-ref-restored","found":"082ef5cdf96e...","key":"8b149a24-...--zach-opus-ci4","repo":"/Users/alex/ab/richos","tip":"2ed41109...","ts":"2026-09-13T22:41:29Z","why":"moved to 082ef5cdf96e, which carries this agent's own unlanded work (it committed or merged onto it)"}
{"branch":"main","event":"protected-ref-restored","found":"953b0369fead...","key":"b7d89f44-...--sage-opus-v1","repo":"/Users/alex/ab/richos","tip":"082ef5cdf96e...","ts":"2026-09-14T00:09:14Z","why":"moved to 953b0369fead, which carries this agent's own unlanded work (it committed or merged onto it)"}
{"branch":"main","event":"protected-ref-restored","found":"082ef5cdf96e...","key":"b7d89f44-...--tom-opus-h3","repo":"/Users/alex/ab/richos","tip":"953b0369fead...","ts":"2026-09-14T00:09:26Z","why":"moved to 082ef5cdf96e, which does not descend from 953b0369fead (a rewind, a force-move or a symref)"}
```

Each timestamp is the same second as its empty-message reflog entry, with the
same old and new shas, the same repository and the same branch.

The writer is `engine/scripts/lib/workspaces.py:2318`, in
`_restore_protected_refs`:

```python
rc, _o, err = git(repo, "update-ref", "--no-deref", "refs/heads/" + b, old)
```

No `-m`, which is why its writes are invisible in the reflog. No old-value
argument either, which matters and is picked up in §5.

---

## 4. Q1 — WHAT decides the value it restores to

**A per-agent, per-tool-call snapshot. There is no single "protected tip" for a
branch; there is one per running agent, and they disagree by construction.**

Where it is recorded:

```
~/.claude/state/workspaces/refs/<session-id>--<agent-name>/c.<toolUseId>.json
~/.claude/state/workspaces/refs/<session-id>--<agent-name>/latest.json
```

Measured on this machine right now: five agents, each holding four to seven of
these files.

When it is written — `_snapshot()`, at the **start of every tool call** that
agent makes. Each row is:

```python
row = {"key": rec["key"], "call": call, "at": now(), "repos": snap, "tips": tips}
```

where `tips[repo] = _protected_tips(refs)` is `{branch: sha}` for every ref that
is a recorded integration branch or a `codex/` ref — **so each file contains the
sha `refs/heads/main` happened to hold at the instant that agent's call began.**

Which one wins, in `_restore_protected_refs`:

```python
ordered = sorted([...priors...], key=lambda p: p.get("at", 0))
for prior in ordered:                       # oldest first
    for b, sha in (prior["tips"].get(repo) or {}).items():
        before.setdefault(b, sha)
```

`setdefault` over an oldest-first list means **the OLDEST still-open window of
that agent wins**. So the value restored is: *the sha main held when this
particular agent's oldest in-flight tool call started* — which can be many
minutes stale, and which is nobody's decision about anything.

**Why two live agents hold different ones.** They start calls at different
times. Between 00:09:14 and 00:09:26 the lead landed three merges; `sage-opus-v1`
had opened a call while main was `082ef5cd`, `tom-opus-h3` had opened one while
main was `953b0369`. Each agent's Post-call check then "restored" main to its
own snapshot. Twelve seconds, opposite directions, both writing main.

**And it is self-triggering, which is the part that turns a bug into a loop.**
Read the two `why` strings: `sage-opus-v1` fired on the *own-work* branch of the
logic; `tom-opus-h3` then fired on the *non-descendant* branch — because
`sage-opus-v1`'s restore had left main on a non-descendant. **The check's own
write is an input to the check.** Every restore manufactures the exact condition
that makes another agent's restore fire. It will keep alternating for as long as
two agents hold different snapshots and keep making tool calls.

**A second, independent scoping bug in the same function.** `_protected_tips`
matches on branch **name** only:

```python
return {b: sha for b, sha in refs.items() if b.startswith(CODEX_PREFIX) or b in recorded}
```

`recorded` is a set of branch names gathered from **all** bodies of work across
**all** repositories. `main` is the recorded branch for femcboost, richos and
richos-hq simultaneously, so the name `main` recorded anywhere protects — and
makes restorable — `refs/heads/main` **everywhere**. It should be `(repo,
branch)` pairs.

---

## 5. Q2 — can a rewind land somewhere that is NOT an ancestor?

**Yes. It can destroy a merge, and tonight it did; only a coincidence put it
back.**

Three properties of the write, each from the code:

1. **No compare-and-swap.** `git update-ref --no-deref refs/heads/<b> <old>` is
   called with no old-value argument. It clobbers whatever main currently holds,
   whatever that is, with no check that main is still where the decision was
   made on. Git offers the safe form for free — the engine's own
   `commit-ceo-inputs.py:702` uses it (`update-ref -m <msg> <branch> <new>
   <old>`) and says why in a comment. This call site does not.

2. **It is not a rewind — it is an assignment, in either direction.** Event 4
   moved main backward; event 5 moved it forward. `old` is simply "what this
   agent last saw", so a "restore" can also **re-introduce commits that were
   deliberately removed**.

3. **The target need not be an ancestor of the tip it replaces, and the engine
   knows it.** Event 5's own recorded reason is *"moved to 082ef5cdf96e, which
   does not descend from 953b0369fead"* — the engine observed main sitting on a
   non-descendant. It was in that state because **the engine had put it there**
   twelve seconds earlier.

**What that means concretely.** Any commit made to main between an agent's
snapshot and its restore is dropped from main's history. At 00:09:14 three
landed merges — `9529c475`, `d28dc3b2`, `953b0369` — stopped being reachable
from main. They came back only because a *different* agent happened to restore
*forward* twelve seconds later. Had the lead merged anything onto `082ef5cd`
inside that window, `tom-opus-h3`'s restore to `953b0369` would have dropped
that merge and `953b0369` would not have been an ancestor of it. The objects
survive in the reflog until gc; `main` does not keep them, and a push of the
restored tip is a non-fast-forward — refused by origin if protected, a public
loss if forced.

So: oscillation is the *lucky* outcome. Destruction is the same mechanism with
different timing.

---

## 6. Q3 — the shape the correct behavior has

Not a patch. The shape, in the order I would take it.

**The root cause is that an effects check is taking an irreversible action on
evidence that cannot support it.** `_restore_protected_refs` infers the *writer*
from the *shape of the result*, and the lead's ordinary land has the same shape
as the abuse it hunts. Its own docstring concedes this ("the one shape this
cannot tell apart is Rich rewinding the recorded branch"), but understates it:
the collision is not with a rare lead rewind, it is with **the normal land**,
which is the single most common write main ever receives.

1. **Detect and report; do not write.** This is the fix I would take. A check
   that cannot identify the writer should not be moving refs. Record the event,
   raise it at turn end, escalate — and let a human decide. The cost is a slower
   response to a genuine doorway commit, which a human can undo from the reflog.
   The benefit is that an entire class of destruction disappears, including the
   self-triggering loop, because a report is not an input to the check.

2. **If it must write, restore only DELETIONS.** A deleted protected ref is
   unambiguous — no legitimate workflow deletes the integration branch — and
   re-creating it is information-preserving, since the objects are still there.
   A *move* is ambiguous and "restoring" it is destructive. Deletion and
   movement are being handled by one code path and they are not one problem.

3. **If it must handle moves: compare-and-swap, fast-forward only, and `-m`.**
   Pass the old value so a concurrent write refuses instead of clobbering.
   Refuse to set a ref to anything that is not a descendant of its current tip —
   that single rule makes the operation incapable of dropping a commit, and it
   would have blocked events 3 and 4 while still allowing event 5's recovery.
   And always pass `-m`: an automated system writing a ref with no reflog
   message is indefensible, and it is what cost a day of investigation here. The
   `-m` is free.

4. **Attribute the writer instead of inferring it.** The engine already knows
   which session is the lead. A move made by the lead's session should never be
   restored, decided structurally rather than guessed from shape. As of tonight
   there is also a `reference-transaction` hook that records the writing PID and
   its full command line, so the writer is now an observable fact rather than an
   inference.

5. **Scope the protected set by `(repo, branch)`, not by branch name.** See §4.

6. **One agent must not be able to act on a stale global.** Even with all of the
   above, the window value is per-agent and minutes old. Anything that acts on a
   shared ref needs to re-read that ref under a lock at the moment it acts, or
   it is deciding about a world that no longer exists.

**Not fixed here.** Escalated as `esc-20260914T000810Z-9d8ae652`, state
`proceeding`, for the lead. A defect found in the running engine is escalated,
not quietly repaired.

### Correcting the record

An investigation on 2026-09-13 recorded event 3 as *"Grep of the entire engine
for update-ref, symbolic-ref and reset --hard finds no writer […] So the mover
is outside the engine. Unidentified."* That verdict is **wrong**, and the
mechanism deserves naming because it is the house failure mode. The grep behind
it was:

```
grep -rn 'update-ref\|symbolic-ref\|reset --hard\|reset --soft' engine/scripts/ \
  | grep -v '\.test\.\|\.mutation\.' | head -12
```

`head -12`. The `lib/workspaces.py` hit falls past the twelfth line. A truncated
search returned nothing and was written down as *there is nothing*. The same
command without `head` names the writer on the first run.

---

## 7. The two orphaned commits and the "four force-dropped commits"

**YES — the same event.** Definitively.

```
$ git log --format='%h %ad | %s' --date=iso a6a9e888..2af4f032
2af4f032 2026-09-13 18:23:13 | Reset main to a6a9e888 — the install, and nothing else
ced9cfb8 2026-09-13 18:12:28 | The wearable-integration assessment and its verification record
71698811 2026-09-13 18:09:09 | Round 9's engineer report and its logs, documents only
74b3c02b 2026-09-13 18:03:18 | Both round-9 certifications, documents only
```

Four commits. The dropping is one deliberate act:

```
17:22:44Z  git tag -f discarded-docs-2026-09-13 ced9cfb8 && git reset --hard a6a9e888
18:24:17   refs/heads/main            reset: moving to a6a9e888    <- the drop, locally
18:24:33   refs/remotes/origin/main   update by push               <- 2af4f032 -> a6a9e888, non-fast-forward
```

and the surviving tag names the same four documents:

```
$ git for-each-ref refs/tags/discarded-docs-2026-09-13 --format='%(subject)'
Round 9 docs discarded from main on 2026-09-13: both round-9 certifications,
the engineer report and its logs, and the wearable-integration assessment +
verification. Promised by 2af4f032 but never created; tagged now so the content
survives gc.
```

Precisely:

- `71698811` and `2af4f032` are **two of the four**. The other two, `74b3c02b`
  and `ced9cfb8`, were dropped by the same reset but had reached main through an
  ordinary `merge` and `commit`, so they carry reflog messages and never stood
  out as anomalies.
- **The empty-message writes are how two of those commits were PUT ON main.
  They are not how the four were dropped.** The drop is the ordinary,
  fully-messaged `reset: moving to a6a9e888` plus the non-fast-forward push.
- **Events 3, 4 and 5 have nothing to do with the four.** Different commits,
  hours later, a different mechanism.

**What this changes for the open CEO decision.** "Should the four force-dropped
commits be restored?" is a decision about content a person deliberately and
reversibly set aside, creating a recovery tag for exactly that purpose. It is
not evidence of an unattributed process eating history. The two questions were
entangled only because the reflog could not say who wrote what. They are now
separate, and the restore question is unchanged in substance — it is a content
decision and it remains the CEO's.

All four commits are intact, reachable from
`refs/tags/discarded-docs-2026-09-13` (`74c6986f`), which is what keeps them
from gc.

---

## 8. Containment — installed, and proved

`engine/scripts/hooks/ref-transaction-forensics.sh`, installed to
`/Users/alex/ab/richos/.git/hooks/reference-transaction` by
`engine/scripts/install-ref-forensics.sh`. Git invokes `reference-transaction`
for every ref write including plumbing — precisely the class that was evading
the reflog. It records timestamp, phase, repository, ref, old sha, new sha, the
writing PID, its full command line, its whole parent chain, the cwd, and
`GIT_REFLOG_ACTION` (unset and present-but-empty kept distinct, since that
variable is what decides the reflog message).

Log: `~/.claude/state/ref-forensics/ref-transactions.jsonl` — outside every
repository, so it survives a reset, a worktree removal and a reclone.

**It can never fail a git operation.** A non-zero exit during the `prepared`
phase aborts the caller's transaction, so the hook runs without `set -e`,
swallows every error, and ends in an unconditional `exit 0`.

### Proof — a real ref write, caused deliberately

`git commit` in this worktree at `8a056821`, abridged:

```json
{"ts":"2026-09-14T00:08:43Z","phase":"committed","repo":"/Users/alex/ab/richos/.git",
 "ref":"refs/heads/cc/sage-opus-w1",
 "old":"953b0369feadff6467ea37d2ba8030c13ad89a21",
 "new":"8a056821b8a2b2f73597740f38528918609862bb",
 "hook_pid":98533,"writer_pid":98099,
 "writer_cmd":"git commit -q -F /private/tmp/.../msg1.txt",
 "cwd":"/Users/alex/ab/richos-wt/sage-opus-w1","reflog_action":null,
 "chain":[{"pid":98099,"cmd":"git commit -q -F ..."},
          {"pid":98091,"cmd":"/bin/zsh -c ... cd /Users/alex/ab/richos-wt/sage-opus-w1 && git commit ..."},
          {"pid":75476,"cmd":"claude --dangerously-skip-permissions"},
          {"pid":75454,"cmd":"-zsh"},
          {"pid":1203,"cmd":".../Terminal.app/Contents/MacOS/Terminal"}],
 "env":{"GIT_DIR":"/Users/alex/ab/richos/.git/worktrees/sage-opus-w1", ...}}
```

And against the two shapes that started this, in a throwaway clone — the hook
names what the reflog could not:

```
2026-09-14T00:09:55Z  refs/heads/main  cb3ae939caa1 -> fa52f7fb31f9
    writer_cmd    : git update-ref refs/heads/main fa52f7fb31f9... main
    reflog_action : None
2026-09-14T00:09:55Z  refs/heads/main  000000000000 -> 031fcdad319d
    writer_cmd    : git update-ref --no-deref refs/heads/main 031fcdad319d...
    reflog_action : None
```

### Three operational notes

- **`core.hooksPath` is set globally** to `/Users/alex/.config/git/hooks`, and it
  REPLACES `.git/hooks` wholesale. A hook dropped into `.git/hooks` on this
  machine is normally **dead and silent**. It works here only because that
  directory's dispatcher (`git-identity-guard-dispatch`, installed by
  femcboost's `scripts/hooks/install-git-identity-guard.sh`) explicitly chains
  to `"$(git rev-parse --git-common-dir)/hooks/<name>"`. The installer verifies
  that chain and **refuses rather than installing a hook that would never run** —
  a containment measure that silently does nothing is the worst outcome
  available. `install-ref-forensics.sh --check` re-verifies it at any time.

- **A `--no-deref` write reports `old` as all zeros** in the transaction (visible
  in the lab output above). Useful fingerprint: it tells the engine's
  `_restore_protected_refs` apart from an ordinary `update-ref` at a glance.

- `.git/hooks` is untracked and machine-local, so this hook is **not** installed
  anywhere else. Any other clone or machine needs
  `engine/scripts/install-ref-forensics.sh <repo>` run once.

---

## Reproduce everything here

```
cd /Users/alex/ab/richos
git reflog show main --date=iso -n 40
git reflog show HEAD --date=iso -n 30
git log --format='%h %ad | %s' --date=iso a6a9e888..2af4f032
git for-each-ref refs/tags/discarded-docs-2026-09-13 --format='%(subject)'
grep -n protected-ref-restor ~/.claude/state/workspaces/events.jsonl
ls ~/.claude/state/workspaces/refs/
sed -n '2228,2330p' engine/scripts/lib/workspaces.py
engine/scripts/install-ref-forensics.sh --check /Users/alex/ab/richos
```
