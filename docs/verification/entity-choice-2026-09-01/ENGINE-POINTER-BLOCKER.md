# BLOCKED (for the CEO's install tonight, not for my task) — the engine install pointer on this machine is a dangling symlink into a deleted scratch directory

Raised by `echo-opus-e1`, 2026-09-01, from branch `echo-opus-e1` (richos).

**My own task is complete and committed.** This file exists because a real double-click of
the shipping bundle, run as the last verification step of that task, no longer reaches a
compute lease on this machine — and the reason is nothing in my branch.

## What I am flagging

`/Users/alex/.claude/richos-engine` — the engine install pointer, candidate 4 of
`engine.rs`'s resolution order and the ONLY one a double-clicked bundle can satisfy on this
machine — is a symlink, dated **1 Sep 04:17**, pointing at:

```
/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad/g4/red/layerR
```

That directory **does not exist**. `test -d /Users/alex/.claude/richos-engine` fails.

The path is a red-run fixture — `g4`, `red`, `layerR` are this session's contract-integrity
probe naming, not mine — so another agent's negative-control fixture appears to have been
pointed at the shared install pointer and then cleaned up, leaving the pointer dangling.

## What it costs, measured

Same bundle, same commit, two launches an hour apart. Earlier
(`docs/verification/entity-choice-2026-09-01/raw/dclick-fixed-saved-choice.log`):

```
[richos] engine directory: /Users/alex/.claude/richos-engine (via engine install pointer)
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

Now:

```
[richos] engine directory: NOT FOUND — 5 place(s) tried
[richos]   looked in /Users/alex/.claude/richos-engine (engine install pointer)
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.
[richos]   cause : the engine directory /Users/alex/Library/Application Support/RichOS/engine
                   does not exist — RichOS runs Claude with that directory as its working
                   directory and cannot start without it (this is NOT a missing claude binary)
```

So a RichOS installed on this machine tonight opens, says it has no compute lease, and
cannot be talked to — for a reason that has nothing to do with entities and everything to do
with one symlink.

## What I already tried

- Confirmed it is the pointer and not the app: the identical bundle
  (cdhash `6283989dc15eb378b9147464543b4f0a29d43fac`) attached the lease through this exact
  pointer earlier today; only the symlink target has changed since.
- Confirmed the target is gone rather than merely unreadable (`ls` on its parent: no such
  file or directory).
- Confirmed a real engine still exists at `/Users/alex/ab/richos/engine`.

## What would unblock it — the smallest question

**May the pointer be repointed at `/Users/alex/ab/richos/engine`, and by whom?**

I have deliberately NOT touched it. It is outside my worktree, it is shared machine state,
and if a probe's red run is still using it a repoint would corrupt somebody else's evidence
mid-flight. One `ln -sfn /Users/alex/ab/richos/engine /Users/alex/.claude/richos-engine`
fixes it, but whoever owns the fixture should say so first, and the durable fix is that a
red-run fixture must never be pointed at the live install pointer at all.

## What I am proceeding on meanwhile

Nothing of mine depends on this. My six commits are landed on this branch, `cargo test` is
green (573 richos-core / 40 src-tauri / 163 richos-voice), all 18 browser suites pass
(345 checks) and the contrast walk is 1148 measured nodes, 0 failures, both themes. The
entity work is verified by the boot lines above — which are the same launches that surfaced
this.

---

## RESOLVED 2026-09-01 by Rich, at the land

The pointer was dangling exactly as reported: `~/.claude/richos-engine` ->
`.../scratchpad/g4/red/layerR`, a red-run fixture deleted after the run that made it.
Repointed to `/Users/alex/ab/richos/engine` and verified: the contract-integrity probe
exits 0 through the restored pointer, all layers green.

**echo-opus-e1 was right not to touch it.** It is shared state, it was owned by a
then-live probe, and a second writer racing a live fixture is how a good fix becomes an
incident. Reporting it and leaving it was the correct call.

**The defect is not the dangling link, it is that a red-run fixture can repoint global
shared state and leave it repointed.** `install.sh` writes this pointer; a test that
exercises Layer R by moving it must restore it, or must never touch the real one.
Filed as its own row.
