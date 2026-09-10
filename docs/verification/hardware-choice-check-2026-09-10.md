# The hardware-choice check: the corpus, the rate, and why it does not block

**2026-09-10.** The artifact is `engine/scripts/hardware-choice-check.py`; its mechanism is proven
by `engine/scripts/hardware-choice-check.test.sh` (14 cases, all green). This file is the other
half: what it was measured against, what it got wrong, and the decision that measurement forced.

The enumeration it serves is [`../hardware-choices-2026-09-10.md`](../hardware-choices-2026-09-10.md).

## The rule

A hardware-dependent choice must either be **resolved at run time**, or carry a **declaration, at
the site**, saying why a fixed value is correct:

```
hardware-fixed: <the reason, where a reviewer will meet it>
```

on the flagged line or in the comment block above it. **A bare marker exempts nothing** —
a reason under `MIN_REASON_CHARS` (20) is reported as a finding in its own right, with its own
message. That is the discipline the contrast floor and the dialect guard already use, and it is
the half that makes a declaration a decision rather than a magic word.

## The corpus

**This repository's real shipping code.** Not fixtures, not the cases the check was written from.

| | |
|---|---|
| Files scanned | **130** |
| Lines scanned | **94,576** |
| Candidate sites the four shapes examined | **2,291** |
| Trees | `app/crates`, `app/src-tauri/src`, `app/src-tauri/tauri.conf.json`, `app/ui`, `tools/richos-service/{lib,bin}` |
| Excluded | tests, examples, benches, fixtures, `#[cfg(test)]` blocks, `node_modules`, `target` |
| Measured | 2026-09-10, against the shipped script, at `9e7c55c4` + this change |

Reproduce the flagged set with

```sh
python3 engine/scripts/hardware-choice-check.py --root . --explain
```

A **candidate** is a site where a shape's vocabulary appears at all — every quoted `-t`/`-p`/
`--threads`, every identifier named for parallelism, every `*_BYTES`/`*_MEMORY`/`*_DISK` constant,
every window `width`/`height`. It is the honest denominator: the number of places the check looked
and had to decide.

## The rate, as first measured

**Scored before any site was declared**, which is the only run whose false-positive rate means
anything — after a false positive has been declared away, re-measuring on the same corpus measures
the declaration, not the check.

| # | Finding | Verdict |
|---|---|---|
| 1 | `journal.rs:96` `RAW_MAX_TOTAL_BYTES = 2 GiB` | **TRUE** — audit D3 |
| 2 | `stt.rs:245` `-t 4` | **TRUE** — audit D1 |
| 3 | `tauri.conf.json:14` `width = 1400` | **TRUE** — audit D2 |
| 4 | `tauri.conf.json:15` `height = 880` | **TRUE** — audit D2 |
| 5 | `config.js:592` `threads = 4` | **TRUE** — audit D1, the other decoder |
| 6 | `richos-user-update/src/lib.rs:25` `MAX_BYTES = 8 GiB` | **FALSE** — a decompression-bomb ceiling, a property of what we ship, not of any disk |

```
  false positives among findings   1 / 6  = 16.7 %
  false positives among candidates 1 / 2,291 = 0.044 %
```

Per shape:

| shape | candidates | flagged | true | false | FP among findings |
|---|---|---|---|---|---|
| `TOOL_FLAG` | 8 | 1 | 1 | 0 | 0.0 % |
| `WORKER_COUNT` | 2,267 | 1 | 1 | 0 | 0.0 % |
| `ABS_BUDGET` | 14 | 2 | 1 | 1 | **50.0 %** |
| `WINDOW_SIZE` | 2 | 2 | 2 | 0 | 0.0 % |

Finding 6 has since been **declared** at its site — the declaration is true, it belongs there, and
it is the in-situ demonstration that the mechanism works. So a run today reports **5 findings, all
of them real defects**. The 16.7 % above is the number that decided the mode and it is kept for
that reason.

## The decision: REPORTING, not blocking

`--strict` exists and exits 1 on a firm finding. **Nothing passes it.** The shipping mode reports
and exits 0, and `hardware-choice-check.test.sh` H13 asserts both, so this is a property of the
artifact rather than a claim in a document.

**Three reasons, in the order they weigh:**

1. **The corpus says it fires on ordinary correct code.** `MAX_BYTES` is not a defect; it is a
   security limit doing its job. The brief's rule for this project is explicit — if the corpus says
   a blocking check would fire on ordinary correct code, ship it reporting and say so with the
   numbers. It does, so it is.

2. **`TOOL_FLAG`'s sample is too thin to claim a rate.** Eight candidates. And it is the shape with
   the clearest future false-positive mode: `ffmpeg -t` is a *duration*, and an integer one —
   `'-t', '10'` for a ten-second clip — would be flagged. The repository happens to pass `'0.1'`
   and computed values today (all seven suppressions are exactly that), so the mode is real and
   simply has not occurred yet. A rate measured on eight instances is an anecdote.

3. **`g11`, `g12` and `g13` all died the same way** and all three were recorded on one day: a
   blocking gate whose false positives got waived on the day it fired, until waiving was the habit
   and the gate was a formality with a hook attached. One false positive per codebase is not a daily
   habit — but the way to find that out is to run in reporting mode and look, not to assert it.

**`WINDOW_SIZE` is the one shape that could go firm today**: 2 candidates, 2 flagged, 2 true, 0
suppressed, and it can only ever match a `width`/`height` in a Tauri window config. Shipping a
per-shape blocking mode for one shape is complexity nobody asked for; it is recorded here so the
next person does not have to re-derive it.

**What would promote this to blocking**, stated so it is a decision somebody can make rather than a
vague someday: `TOOL_FLAG` measured against a second corpus with a real integer-duration `ffmpeg -t`
in it, plus one season of reporting-mode output in which the findings that appeared were defects.
Flip `--strict` on in the caller; the script needs no change.

## Where it runs, and the honest limit of that

**It requires no registration and no session restart**, which was a constraint of the brief.
`engine/scripts/ci-units.sh:131` discovers suites with `find "$ENGINE_ROOT" -type f -name
'*.test.sh'` — from disk, never a typed list — so `hardware-choice-check.test.sh` is picked up the
moment it exists. `engine-self-verify.yml` triggers on `push:` with **no path filter**; main
pushes, `workflow_dispatch` and the 04:17 UTC cron run the full sharded pass.

So it runs **on every push to main** — which is where Rich lands — **and daily**. No hook, no
plugin manifest, no restart.

**Two limits, named rather than left to be discovered:**

- On a *branch* push the fast `affected` gate selects units from the diff. Whether an `app/`-only
  diff selects this engine suite is **unverified** — I read `ci-affected-units.sh` far enough to see
  the selection is diff-driven and did not trace it to an answer. The main-push and cron paths are
  verified from the workflow's own `on:` block and are what the enforcement claim rests on.
- The suite proves the **mechanism**. It does not assert the repository is clean, deliberately:
  a test that pinned today's five findings would have to be edited by the same commit that adds a
  sixth, which is a gate that asks its own violator for permission.

## What the corpus changed, because a corpus that changes nothing was not consulted

Three design changes, each forced by running against real code rather than by review:

1. **`TOOL_FLAG` was line-scoped and missed `stt.rs:245` entirely** — the headline defect of the
   whole audit — because rustfmt puts the flag and its value on separate lines:

   ```rust
   "-t".into(),
   "4".into(),
   ```

   A false negative on the one finding the check exists to catch, invisible to any review that
   reads the pattern instead of running it. It now matches across the file, with comment spans
   excluded so a flag quoted in prose cannot pair with an integer in the code below. Regression
   test: H9.

2. **`WORKER_COUNT` was 83.3 % false** — 5 of its first 6 findings were
   `std::thread::sleep(Duration::from_millis(200))`, matching the *module* `thread` followed by a
   number that is a delay in milliseconds. One `(?<!::)` lookbehind plus a time-context exclusion
   took it to 0. Regression test: H10.

3. **The declaration lookbehind was a fixed 3 lines, and the first real declaration written against
   this check did not fit it.** A Rust `///` block attaches to the *item*, so the signature sits
   between the declaration and the flagged value, and a doc comment worth reading is longer than
   three lines. A line budget quietly pushes an author toward a thinner reason, which is the exact
   opposite of what "a bare marker exempts nothing" is for. It now follows the comment block, across
   up to `MAX_CODE_GAP` (3) non-comment lines. Regression tests: H5 (it reaches) and H6 (it does not
   reach a sibling item).

The third was caught by the suite's own first run, which is the argument for writing the suite
before believing the check.

## What it does not catch

Recall against the hand enumeration is **3 of 5**. It finds D1 (both halves), D2 and D3. It does not
find:

- **D4**, `aec.rs:172 MAX_DELAY_BLOCKS = 32` — a hardware assumption encoded as a *search range*.
  Nothing about the name or the value says "machine"; the assumption lives in the prose beside it.
- **D5**, `transcribe.js:165 opts.model || DEFAULT_MODEL` — a *bypass* of a resolver rather than a
  fixed value. Catching it means knowing which function is the resolver, which is a different and
  much harder check.

Both are named in the audit document. **A check with 3/5 recall and one false positive is worth
having and is not worth trusting alone**, and saying so here is cheaper than someone discovering it
by shipping D4 twice.
