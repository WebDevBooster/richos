# Improvement opportunities (observations only — not acted on)

These were noticed while repairing `lifecycle.py` against `requirements.md`. They are
out of scope for that repair and have deliberately **not** been implemented.

## 1. `status()` treats every non-native owner as external
`lifecycle.py` branches on `owner == "native"` and returns the external value for
everything else. `status("banana")`, `status("")` and `status(None)` all return
`"verified"`. If the owner set is meant to be closed, an explicit mapping plus an
error (or an explicit unknown state) for unrecognised owners would be safer than a
silent fallthrough. This would need a contract decision, since `requirements.md`
does not say what unknown owners should do.

## 2. No test coverage for unknown / edge-case owners
`test_lifecycle.py` covers exactly the two owners named in the contract. There is no
test pinning behaviour for an unrecognised owner, empty string, `None`, or differing
case (`"Native"`). Adding those would lock in whatever answer item 1 settles on.

## 3. Contract values are bare string literals
`"platform-pending"` and `"verified"` are duplicated as literals across the
implementation and the tests. Naming them as module-level constants would make a
future contract change a single edit and would make stale assertions (exactly the
`native` failure diagnosed here) harder to introduce.

## 4. No docstring or type hints on `status()`
The function has no docstring stating the approved contract and no signature types.
A short docstring citing `requirements.md` would have made the superseded
`backlog.md` contract visibly distinguishable at the call site.

## 5. Superseded contract in `backlog.md` is not marked as superseded
`backlog.md` states "Previous contract: native workspaces return verified" without
flagging that it is historical. That wording is what the stale test assertion
mirrored. A "SUPERSEDED — see requirements.md" marker would reduce the chance of the
same confusion recurring. Note: `backlog.md` is out of scope and was not modified.
