# The seat/inspection divergence

**Audited 2026-08-30 against `richos` `bc9a775`.** Every claim below is a command with its real
output or a file and line. Nothing here is inferred from a guard that was not read.

---

## 1. The shape

Every guard answers two questions, and it answers them from two different places:

| Question | Answered from | Example |
|---|---|---|
| *Am I governed?* — whether to run at all | the **session's seat**, via `resolve_entity_root` | `guard-row-currency-commits.sh:85` |
| *What am I inspecting?* — the artifact to judge | the **command's own repository**, via the payload | `guard-row-currency-commits.sh:286` |

In this installation those are **never the same repository**. The engine is loaded as a user-scope
plugin, so it is seated wherever the session happens to be, while the artifact is wherever the
command points. Nothing compares the two, and when they differ the guard exits 0 — indistinguishable
from a pass.

The seat decision at `guard-row-currency-commits.sh:85-92`:

```bash
if resolve_entity_root "$INPUT"; then
    :
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0                      # <-- SILENT. Success and stand-down are the same byte.
```

The inspection target at `guard-row-currency-commits.sh:277-287`:

```bash
ANCHOR="${REPO_HINT:-${PAYLOAD_CWD:-$PWD}}"
...
REPO="$(ct_repo_root "$ANCHOR" 2>/dev/null || true)"
[ -n "$REPO" ] || exit 0
```

`REPO` is derived entirely from the payload. It is never checked against the seat.

---

## 2. What the seat actually resolves to

`scripts/lib/resolve-roots.sh`, driven directly, one seat per row:

| Session seat | rc | status | resolved ENTITY_ROOT |
|---|---|---|---|
| `/Users/alex/ab/richos` | 0 | `engine-self` | **`/Users/alex/ab/richos/engine`** |
| `/Users/alex/ab/richos-hq` | 1 | `not-adopted` | *(none)* |
| `/Users/alex/ab/femcboost` | 0 | `governed` | `/Users/alex/ab/femcboost` |

The cause is the adoption marker, and it is a fact about the disk:

```
$ ls /Users/alex/ab/richos/orchestration.config
ls: /Users/alex/ab/richos/orchestration.config: No such file or directory
$ ls /Users/alex/ab/richos-hq/orchestration.config
ls: /Users/alex/ab/richos-hq/orchestration.config: No such file or directory
```

Only `richos/engine/orchestration.config` exists. So in a `richos` session no candidate carries the
marker, the `engine-self` branch (`resolve-roots.sh:346-357`) fires, and the seat becomes the
**engine subdirectory** rather than the product repository the session is actually working in.

---

## 3. The three consequences, re-derived

Driving `guard-main-checkout-writes.sh` with real payloads. `PROTECTED_PATHS="app packages"`
(`engine/orchestration.config:39`).

```
SEAT = /Users/alex/ab/richos (the product repo)
write REAL product source app/                 -> rc=0
write NON-EXISTENT engine/app/                 -> rc=2  === Main-checkout write BLOCKED ===
write REAL packages/                           -> rc=0
write engine/packages/                         -> rc=2  === Main-checkout write BLOCKED ===

SEAT = /Users/alex/ab/richos-hq (CEO private record)
write richos-hq wiki                           -> rc=0
write RICHOS product from hq seat              -> rc=0

POSITIVE CONTROL (must be rc=2, else the probe proves nothing)
write femcboost protected avelor/              -> rc=2  === Main-checkout write BLOCKED ===
```

The positive control matters: without it, a probe that returned 0 everywhere would be
indistinguishable from a probe that ran nothing.

1. **`richos-hq` enforces nothing — CONFIRMED.** Status `not-adopted`; every guard exits 0. It has a
   `.row-currency` declaration and no `orchestration.config`: a contract declared with nothing
   reading it.

2. **The product source is unprotected — CONFIRMED.** A write to
   `/Users/alex/ab/richos/app/crates/richos-core/src/live.rs` exits 0.

3. **The `engine/app` claim — CONFIRMED, and it is the more serious half.** A write to
   `/Users/alex/ab/richos/engine/app/nonexistent.rs` is **blocked**, and that directory does not
   exist (`ls: /Users/alex/ab/richos/engine/app: No such file or directory`). The guard is protecting
   a tree that is not there and ignoring the one that is. Reproducing it requires *changing the
   resolved seat* — with `CLAUDE_PROJECT_DIR` left pointing elsewhere both paths return 0, which is
   why an earlier probe could not see it.

**`richos` is worse off than `richos-hq`, not better.** `richos-hq` is honestly stood down.
`richos` announces `ENFORCEMENT ACTIVE` (`engine-status.sh:203`, the `engine-self` arm) over a seat
that guards an empty directory. A false green outranks an honest red.

---

## 4. The divergence across every registered guard

Derived from `hooks/hooks.json` via `scripts/lib/registered-hooks.sh` — never a typed list, because a
typed list of 14 over a registration of 15 is the drift that opened this whole sequence.

```
scanned=26  with-seat=20  DIVERGENT=7
```

The 7, each read individually and confirmed:

| Guard | Seat | Inspection target derived from |
|---|---|---|
| `guard-main-checkout-writes.sh` | `resolve_entity_root` | `tool_input.file_path` (`:86`) |
| `scan-secrets.sh` | `resolve_entity_root` | `tool_input.file_path` (`:123`) |
| `guard-publication-writes.sh` | `resolve_entity_root` | `tool_input.file_path` (`:87`) |
| `guard-row-currency-commits.sh` | `resolve_entity_root` | `ct_repo_root(REPO_HINT‖cwd)` (`:286`) |
| `guard-ceo-todos-commits.sh` | `resolve_entity_root` | `ct_repo_root(REPO_HINT‖cwd)` (`:187`) |
| `guard-completeness-commits.sh` | `resolve_entity_root` | `REPO_HINT‖cwd` (`:324`) |
| `guard-publication-commits.sh` | `resolve_entity_root` | `pb_repo_root(REPO_HINT‖cwd)` (`:334`) |

The other 13 seat-resolving guards constrain their target *through* the seat — for example
`guard-bash-main-writes.sh` only matches paths under `$ENTITY_ROOT` — so they cannot diverge. The
6 handoff hooks resolve no seat and inspect no path.

---

## 5. The rule — first draft, and why it was wrong

The rule I wrote here first was:

> ~~A guard enforces on an artifact if and only if that artifact lies inside the repository the guard
> resolved as its seat; an artifact outside the seat is out of jurisdiction and is announced, never
> silently allowed.~~

It is recorded rather than deleted because **it is the obvious answer and it is a regression**, and
the next person to look at this will think of it too.

Implemented literally, it closes the divergence by *skipping* when the artifact is outside the seat.
The test suites went red within minutes — 5 of 31, and they were 5 of the 7 guards I had just wired.
The reason is that `guard-row-currency-commits.sh` and its four siblings read their contract **out of
the target repository** (`.row-currency`, `.ceo-todos`, `.publication-boundary`); the seat
contributes nothing to what they judge. Skipping on a seat mismatch would have switched off a guard
that was working: the merge into `richos-hq` that was correctly refused that morning would have
sailed through.

**A jurisdiction rule is never allowed to move enforcement in the less safe direction.**

## 6. The rule that holds

> **A guard resolves its governance from the repository of the artifact it is about to inspect, not
> from where the session happens to sit — so "am I governed?" and "what am I inspecting?" are the
> same question about the same repository, and cannot disagree.**

The two questions are not reconciled by adding a comparison between them. They are reconciled by
being **one question**. Two families, one rule:

| Family | Guards | Where the rule lives | What changed |
|---|---|---|---|
| Declaration-driven | row-currency, ceo-todos, completeness, publication-commits, publication-writes | the target repo's own declaration file | the seat's **veto is removed** — an unadopted seat used to exit before the declaration was ever read |
| Config-driven | main-checkout-writes, scan-secrets | `orchestration.config` | the config is loaded from the **file's** repository, via `richos_governing_root` |

Three properties follow, and all three are tested
(`scripts/lib/seat-jurisdiction.test.sh`, 12/12):

- **Seat and target cannot disagree**, because they are no longer two answers.
- **Standing down is loud**, at the moment of the decision, naming the repository and the reason.
- **A new guard with the old shape turns the suite red** on the day it is written — derived from
  `hooks/hooks.json`, with a negative control asserting the scan examined a non-zero number of guards.

### What this does NOT fix

Adoption. `richos` and `richos-hq` still carry no root `orchestration.config`, and no code change can
decide that. Proven in a throwaway copy of the nested shape:

```
before adoption  write richos/app/crates/live.rs -> rc=0, LOUD stand-down
                 (was: rc=0 in silence, while richos/engine/app — which does not exist — blocked)
after adoption   write richos/app/crates/live.rs -> rc=2 BLOCKED
                 write richos/docs/notes.md      -> rc=0 (not a protected tree)
```

The engine now does the right thing the moment either repository adopts. Whether they should is a
decision, and for `richos-hq` it is the CEO's — put to him as item 1.8.
