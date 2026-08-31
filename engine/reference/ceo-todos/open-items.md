# Open items

The source of truth for everything in flight. `@@TODO_VIEW@@` at the repository
root is generated from this file — edit here, then run
`scripts/ceo-todos-render.sh` (RichOS engine).

**Sections 1 and 2 are the CEO's.** An item may sit there only when it is
*prepared*: the thing he opens already exists on disk, the time cost is stated,
"done" is written down, and what it unblocks is named. The commit guard
enforces exactly that, so an item that is not ready cannot quietly sit here
looking like his problem.

**Section 3 is everyone else's.** Unprepared work goes here, marked
`BLOCKED-ON-RICH`. Moving an item down here is the system working, not a
failure — "waiting on the CEO" is a promise that everything else is done, and
one unprepared row destroys that promise for every other row on the page.

Every item takes this shape. The first four fields are required; the fifth is
optional and is the one that keeps this page honest over time:

```
### <section>.<n> READY-FOR-CEO — <a short title>

- **Open:** `<prefix>/path/to/the/one/thing/he/opens`
- **Time:** 20 minutes
- **Done:** what has to be true for this to be finished, checkable by whoever takes it back
- **Unblocks:** what starts moving once it is done
- **Done-check:** `lacks <prefix>/path "<the marker that disappears when it is done>"`
```

**`Done-check` is the same sentence as `Done`, in a shape a machine can test.**
Without it, an item that has already been finished goes on sitting here asking
the CEO to do it, and nothing notices until a person reads the page — which is
exactly what happened on 2026-08-31 with an app icon that had been made hours
earlier. Four verbs, none of which runs a program:

```
`exists <prefix>/path`                 done when that file is there
`contains <prefix>/path "<regex>"`     done when the page says this
`lacks <prefix>/path "<regex>"`        done when this marker is gone
`manual "<why it leaves no trace>"`    nobody can check this one; say why
```

Most CEO work ends with a marker disappearing — an `OPEN` token on a decision,
a `SIGNED OFF / NOT SIGNED OFF (delete one)` line — so `lacks` is the common
case. Write the check against a marker that is in the file **today**, then run
`scripts/ceo-todos-lint.sh <this repo>` once before committing it: a pattern
that never matched anything reads as already-done and the guard will say so.

---

## 1. Waiting on the CEO — a decision

_Nothing yet._

---

## 2. Waiting on the CEO — his hands

_Nothing yet._

---

## 3. Buildable now — nobody blocked

### 3.1 BLOCKED-ON-RICH — Example: an item that is NOT ready, parked where it belongs

This is a worked example, and it lives in section 3 on purpose. Delete it when
you have real work here.

It is the shape of the defect the whole mechanism exists to remove: a row that
*reads* like it is waiting on the CEO ("we need him to sign off on the pricing")
while it is really waiting on somebody to write the one page he would sign off
on. Left in section 1, it would sit for weeks looking like his fault.

To promote it, prepare it: create the artifact, fill in all four fields, change
the state to `READY-FOR-CEO`, renumber it into section 1 or 2, and re-render.
The guard will tell you, precisely, if you have missed something.
