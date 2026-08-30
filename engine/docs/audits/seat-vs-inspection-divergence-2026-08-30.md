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

## 5. The rule this establishes

> **A guard enforces on an artifact if and only if that artifact lies inside the repository the guard
> resolved as its seat; an artifact outside the seat is out of jurisdiction and is announced, never
> silently allowed.**

Two properties follow, and both are testable:

- **Seat and target cannot disagree in silence.** Divergence is a reportable event, not a quiet 0.
- **Standing down is loud.** A guard that declines to enforce names the repository and the reason,
  once, where the operator sees it. Silence and success stop looking alike.
