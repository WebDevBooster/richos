# RESOLVED — was: every commit from this worktree is refused, and the cause was not my work

**Teammate:** zach-opus-p8
**Worktree:** `/Users/alex/ab/richos-wt/zach-opus-p8` (branch `zach-opus-p8`, cut from `1dd74c8`)
**Written:** 2026-09-04
**Status:** RESOLVED at 1c2c192. Kept as the durable record of the block and how it
ended, rather than deleted — a blocker that leaves no trace is a blocker somebody
rediscovers.

**How it ended.** The lead authorized the route below in the in-flight notice for
`fc56c20`: take main's `.richos/publication-completeness` into this branch byte-identical.
Done at `1c2c192`, verified byte-identical against `fc56c20` before staging, committed on
its own so a change I merely transported is visible as exactly that. No guard was
weakened and the guard's own escape token was not used.

## What I am blocked on

`guard-completeness-commits.sh` refuses every `git commit` in this worktree, before
any of my files are considered. The refusal, verbatim:

```
=== PUBLICATION COMPLETENESS: BROKEN — REFUSING (fail-closed) ===
  repository : /Users/alex/ab/richos-wt/zach-opus-p8
  checker    : /Users/alex/ab/richos/engine/scripts/publication-completeness.sh
  ERROR: /Users/alex/ab/richos-wt/zach-opus-p8/.richos/publication-completeness:
  'INSTANCE_MECHANISMS' is RETIRED and this file no longer reads it.
```

This is the wall named in the in-flight notice for `999d63c`, arriving from the other
direction. It is a **version skew between two things neither of which is mine**:

- The guard runs the checker from the **installed** engine at
  `/Users/alex/ab/richos/engine/scripts/`, which is now `zach-opus-p6`'s post-migration
  version that refuses the retired key.
- My worktree was cut at `1dd74c8`, so it carries the **pre**-migration
  `.richos/publication-completeness`, which still declares
  `INSTANCE_MECHANISMS="richos-hq/.../pubcheck.sh"` at line 71.

Main already has the fix. `git diff 999d63c -- .richos/publication-completeness` in this
worktree shows the whole delta, and every line of it is p6's.

## What I already tried

1. Ran the checker **from my own worktree** — exit 0, clean. My work introduces no
   completeness finding; the registry's declaration stem is classified in
   `declaration-path.sh` and `.vendored-material` is named in `engine/README.md`, so both
   arms of Check 2 are satisfied.
2. Read the refusal to the end to be certain it names a file of mine. It does not. It
   names `.richos/publication-completeness`, which the brief assigns to `zach-opus-p6`
   and tells me to stay off.
3. Confirmed the guard is a `PreToolUse[Bash]` hook, so there is no `--no-verify` and no
   git-hook path around it. There is an in-command escape token; I have not used it,
   because using an escape hatch to get past a gate that is correctly reporting a real
   staleness is improvising past the thing the notice told me to stop at.

## The smallest question that would unblock me

**May I take main's version of that one file into my branch, verbatim?**

```
git checkout 999d63c -- .richos/publication-completeness
```

It adopts `zach-opus-p6`'s landed bytes with no authorship of mine, and because the
content would then be byte-identical to main, your merge of this branch produces no
change to that file at all. The alternative, if you would rather it not appear in my
diff, is that you merge `999d63c` into `zach-opus-p8` yourself — a main-checkout action,
which your notice says is yours rather than mine.

Either way it is one action and I am unblocked. I am not choosing between them.

## What I am proceeding on meanwhile

Everything that does not depend on the answer is done and verified in the working tree:

- `.richos/vendored-material` — 34 entries, all fifteen third-party skills, `gpt-exporter`
  and the four font families, RichOS-authored material recorded as such.
- `engine/scripts/lib/vendored-material.sh` — the single parser.
- `engine/scripts/hooks/guard-vendoring-commits.sh` — refuses an unrecorded vendoring at
  `git commit`; registered on both surfaces and in every inventory a Bash-matcher guard
  has to appear in.
- `engine/scripts/hooks/guard-dialect.sh` — reads the registry and leaves third-party
  paths alone, including both files the 2026-08-30 sweep damaged, while still firing on
  RichOS-authored prose.
- Test coverage: `guard-vendoring-commits.test.sh` 60/60 with a 20-mutant harness, and
  `guard-dialect.test.sh` 85/85 with a 20-mutant harness. Every mutant was run RED first.

All of it is now committed — `65b0211`, `2e4eb39`, `7f6190b`, `40f43fa`, on top of the
transport commit `1c2c192`.

## Two findings raised separately, neither of which blocks me

1. **`richos_assert_jurisdiction` tells the reader the opposite of what happened.**
   `engine/scripts/lib/seat-jurisdiction.sh` lines 244-245 hardcode "the guard did NOT
   judge it" and "THIS IS NOT A PASS", which is correct for guards that decline and false
   for the three that proceed and only report (`guard-dialect.sh`,
   `guard-vendoring-commits.sh`, `guard-row-currency-commits.sh`). Measured, not reasoned:
   replaying the reported configuration returns exit 2 with a full refusal. Fix is a fifth
   parameter with two wordings — a shared signature change, out of scope here.

2. **`guard-row-currency-commits.sh`'s command classifier cuts inside quotes.** Its
   `re.split(r"(?:\|\||&&|[;\n|])", cmd)` splits a multi-line commit message at the
   blank line, both halves fail to shlex, and no `git commit` is recognized at all — so
   that guard does not fire on any commit written in this project's house style. My guard
   carries a quote-aware splitter instead and pins the difference as a mutant
   (`naive-segment-split`), whose `new` text is that sibling's line verbatim.

3. **A mutation harness that edits the SHIPPED tree in place.**
   `engine/scripts/hooks/guard-worktree-isolation.mutation.sh` mutates
   `engine/scripts/hooks/guard-worktree-isolation.sh` where it lives and restores it
   afterwards (`restore()` plus an EXIT trap), unlike `scripts/lib/mutation-harness.sh`,
   which builds a throwaway copy. `contract-integrity.test.sh` runs it, so during any
   integrity run the working tree contains a deliberately broken guard — I watched
   `git status` report exactly that, mid-run, in this worktree. Nothing was captured here
   because every commit used an explicit pathspec, but a `git add -A` during an integrity
   run would commit a mutant, and the diff is one line that reads as a plausible edit.
   Not mine to fix and not in scope; recorded because it is quiet and it is real.
