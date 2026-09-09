# Unrelated improvement suggestions

Observations noticed while repairing the lifecycle contract. These are **outside the scope**
of that repair and have deliberately **not** been acted on. Each needs its own decision and
its own change.

## 1. Broken path reference in `ceo-items.md`

`ceo-items.md` line 7 points at `q/decision-D7.md`, but there is no `q/` directory in this
repository — the file actually lives at the repo root as `decision-D7.md`. Anyone following
that link hits a dead path.

Suggested fix: correct the reference to `decision-D7.md` (or create the `q/` layout the
reference assumes, if that structure is intended). **Not edited here** — `ceo-items.md` is
outside this repair's scope.

## 2. `lifecycle.py` treats every non-native owner as external

`status()` uses an `if owner == "native" ... else ...` shape, so *any* unrecognised owner
string (`"", "externl"`, `None`, …) silently returns the external result rather than being
rejected. Requirements name exactly two owners.

Suggested fix: dispatch on an explicit mapping of the known owners and raise (or return a
defined sentinel) for anything else. Worth confirming the desired unknown-owner behaviour
with the contract owner first, since it is not specified in `requirements.md`.

## 3. No test coverage for unknown owners

Following from #2, the suite covers only the two approved owners. Once unknown-owner
behaviour is defined, it should get a test case of its own.

## 4. Contract values are untyped string literals

The status strings (`platform-pending`, `verified`) are duplicated as bare literals across
`lifecycle.py` and `test_lifecycle.py`. Promoting them to named constants (or an `enum.Enum`)
would make a future contract change a single-site edit and prevent the exact
implementation/test drift that caused this defect.

## 5. Superseded contract in `backlog.md` is not marked as superseded

`backlog.md` states "Previous contract: native workspaces return verified" without a visible
status marker or a pointer to `requirements.md` as the current authority. This is precisely
what the stale test assertion encoded. A `SUPERSEDED — see requirements.md` header would make
the historical status unmistakable. **Not edited here** — `backlog.md` must remain unchanged.

## 6. No automated check that the suite runs

There is no CI config, `Makefile`, or pre-commit hook, so a contract drift like this one is
only caught when someone runs the tests by hand.

---

**Note, not an improvement:** `backlog.md` and `ceo-items.md` reference a pending CEO decision
(D-7, choosing a paid transcription provider for a separate project). That is a business
decision for a different project, it remains unmade, and nothing in this repair touches it.
It is recorded here only so it is not mistaken for an open engineering item.
