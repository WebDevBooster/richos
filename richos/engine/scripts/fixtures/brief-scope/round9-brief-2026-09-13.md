# Round 9 — two items

**Base:** `dev/workspace-spec` @ **`a6a9e888`** in `/Users/alex/ab/richos`.
**Spec:** `/Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md` — read the CEO's fourteen
sentences there, by that path. A file at the same relative path exists in your worktree; it is a copy, and
you neither read it as the spec nor edit it.
**`main` is `dcabcbd9` and stays there.**

**The fourteen headings of the check harness are FROZEN.** Add sub-assertions under them; never remove or
reword a heading.

**Starting state, re-measure it rather than assume it:** the fourteen read `14 green, 0 red · self-check:
green` with 83/83 mutants proven; the runner reads `GREEN 8, RETIRED 2, RED 2`.

---

## 1 · A probe that still runs but no longer asserts anything reads GREEN

Replace a listed probe, on the branch under test, with a file that imports the library and returns 0 — or
flip a reviewer's `return 1` to `return 0`. The file is still present, still listed, still named the same.
The gate reads it GREEN and exits 0:

```
before:  8 GREEN  2 RED  2 RETIRED   exit 1
after:   9 GREEN         2 RETIRED   exit 0
```

**Already closed, do not rebuild:** gutting and delisting → `MISSING`; gutting while still listed →
`UNRUNNABLE`; delisting only → `UNLISTED` and `MISSING`; renaming with the manifest line updated → caught.

**Do:** run each listed probe against **the recorded branch's content**, not the working tree's.

**Observable:** a probe whose assertions are removed or inverted on the branch under test does not read
GREEN. A legitimately retired probe still reads RETIRED. A legitimately green probe still reads GREEN.

## 2 · A protected ref is restored only inside a tool-call window

Outside a window, an agent's own process acts unseen. Four measured shapes:

- a `codex/` ref **deleted between two of the agent's closed calls** is never restored — the CEO's point 2
  says *"never deleted"*;
- a `codex/` ref force-moved **after the agent's last PostToolUse** stands;
- the agent's own branch **self-merged onto the recorded branch** after its last PostToolUse stands, and the
  land then reports `landed` with nothing pending;
- a stray branch left between two calls stays.

And the same cause from the other side: **where the main checkout already sits on the recorded branch — the
ordinary case — an agent's commit there is spared as "the lead's land"**, because the own-work rule looks
only at the agent's registered tips.

**Inside a window the existing pair restores everything both reviewers threw at it.** The window is the
defect, not the mechanism.

**Do:** record the lead's own windows. The lead's calls pass through the same PreToolUse/PostToolUse hooks
with no `agent_id`. A ref that appears inside one of the lead's own call windows is the lead's, by the
platform's own stamp, exactly as a ref inside an agent's window is the agent's. With the lead's windows
recorded, the rule becomes:

> **a ref at an agent's unlanded tip that appears at any point in its run is the agent's, UNLESS it appeared
> inside a lead window.**

That decides the backgrounded call, the forked child, the lead's bookmark and the main-checkout commit on
stamped facts rather than on timing.

**Do NOT build the alternative that attributes every ref between two closed calls to the agent** — it
deletes the lead's bookmark at the agent's tip.

**Observable:** each of the four shapes above is restored or correctly attributed; the main-checkout commit
is restored; the lead's bookmark at an agent's unlanded tip is still recognised as the lead's and is **not**
deleted by a discard; `c4-control-no-refused-call.py`, `leaked-window-widens` and
`test_point_08_…never_created_in_it` all stay green.

---

## The two RED reviewer cases

They assert the half round 8 did not close. **When item 2 is built they should go green on their own.** If
either does not, that is a finding for its author, not something to retire.

## Also run

The unit mutation harness, 53 mutants. Report its own tally line.

## The bar

**No mutation survives.** Each labelled **RECORDED** (incident file, section, date) or **SPEC-DERIVED** (the
sentence's negation, labelled constructed). Where the record holds a mechanical incident for a point, at
least one RECORDED mutation is required. Report per point how many of each.

## Constraints

**Run one mutation pool at a time.** Before starting one, check that none is already running and that none
has reparented to init.

Every measurement names **which engine** it ran against. The running engine is `main` @ `dcabcbd9` and
writes `~/.claude/state/worktree-ledger.jsonl`; this base writes `~/.claude/state/workspaces/`.
**Check that the file you measure is the file the code reads.**

Every claim carries its command and that command's output. **A number you did not see printed does not go
in** — mark it UNVERIFIED by name. **sha256-census `~/.claude/state/workspaces` and
`~/.claude/state/workspace-retirement` before your first command and after your last; any change is a failed
round.** Sandbox with `RICHOS_WORKSPACES_DIR` / `CLAUDE_CONFIG_DIR` and `RICHOS_SESSION_PID` /
`RICHOS_SESSIONS_DIR`. Nothing `codex/` outside a fixture. No merge, no push, no `install.sh`, nothing
written into `/Users/alex/ab/richos/engine`, no touching any main checkout.

**Commit the report incrementally, with each item you finish.**

## Deliver

Create `<your worktree>/docs/verification/round9-fixes-2026-09-13.md` — your worktree is the absolute path
on the `cross-repo-worktree:` line of your spawn prompt. First line exactly
`FOURTEEN: <N> green, <K> red · self-check: <green|red> · runner: RED <n>`. Per item: the check, which
engine, the command, its real output, the verdict, and the mutations by label with counts. Plus the unit
harness tally, the census hashes, anything you believe is wrong with a frozen check, and what you did not do.

---

*Source: `<your worktree>/docs/verification/certification-sage-round8-2026-09-13.md` and
`<your worktree>/docs/verification/certification-frank-round8-2026-09-13.md`.*
