# Improvement suggestions (NOT implemented)

These are unrelated to the lifecycle repair and are recorded here as suggestions only,
per the scope constraint. None of them has been implemented.

## 1. Make the unspecified-owner behavior explicit in the contract
`status()` returns `"bound"` for any owner that is neither `native` nor `external`.
This fallback predates the repair and was preserved, but `requirements.md` says nothing
about it. Someone should decide whether unknown owners should return `"bound"`, raise a
`ValueError`, or be rejected earlier, and then record that decision in `requirements.md`.
Until then the behavior is untested and undocumented.

## 2. Add test coverage for the unspecified-owner path
There is no test for `status("something-else")`. Once suggestion 1 is decided, add a
case for it so the fallback stops being silent behavior.

## 3. Represent statuses as named constants or an enum
The literals `"platform-pending"`, `"verified"` and `"bound"` are duplicated across
`lifecycle.py` and `test_lifecycle.py`. Module-level constants (or a `StrEnum`) would
make a future contract change a one-line edit and would turn a typo into an
`AttributeError` at import time rather than a silent wrong-string return.

## 4. Date or version the contract documents
`requirements.md` says "Current approved contract" and `backlog.md` says "Previous
contract" with no dates, versions or supersession pointer. This is precisely the
ambiguity that let the stale `native` assertion survive. Adding an effective date and
an explicit "superseded by requirements.md" line to `backlog.md` would make staleness
detectable rather than a matter of inference.

## 5. Split the superseded contract note out of the backlog
`backlog.md` mixes a superseded engineering contract with an unrelated pending business
decision (D-7, transcription provider). Keeping contract history separate from the
work backlog would reduce the chance of a reader implementing the wrong one.

## 6. Reconcile the README validation command with the authorized one
`README.md` documents validating `diagnosis.json` with
`python3 -c 'import json; json.load(open("diagnosis.json"))'`, while the project's
authorized command is `python3 -m json.tool diagnosis.json`. They are equivalent in
effect; aligning the README on the authorized form avoids a needless permission prompt.

## 7. Add a type hint and a docstring-level contract test
`status(owner)` has no annotations. `def status(owner: str) -> str:` plus a doctest
would let the approved contract be checked by tooling as well as by the unit tests.
