# Improvement suggestions (unrelated to this repair)

These are **suggestions only**. Nothing here has been implemented, and none of it is
required by `requirements.md`. Acting on any of them would need its own decision and,
in most cases, a change to files that were out of scope for this repair.

## 1. `README.md` recommends a validation command that is not permitted here
`README.md` tells the reader to validate `diagnosis.json` with
`python3 -c 'import json; json.load(open("diagnosis.json"))'`. That form of command is
refused in this workspace. A permitted equivalent that does the same job is
`python3 -m json.tool diagnosis.json`. Suggest updating the README wording so the
documented workflow matches what can actually be run. (README.md was out of scope, so
it has been left exactly as-is.)

## 2. Stale contract history and open decisions live in the same file
`backlog.md` holds two unrelated things: the superseded lifecycle contract, and a note
about a pending, unrelated business decision. Mixing superseded contract text with live
open items makes it easy to mistake stale history for current authority — which is
precisely the trap in this repair. Suggest keeping superseded contract history in a file
that is clearly labelled as history, separate from any open-items tracking.

## 3. `requirements.md` does not define behaviour for unrecognised owners
The contract specifies only the `native` and `external` cases. `status()` therefore has
undefined-by-contract behaviour for any other owner value (today it silently falls into
one of the two branches). Suggest deciding explicitly what an unknown owner should do —
raise, or return a documented sentinel — and writing that into the contract *first*,
then implementing and testing it. It was deliberately not changed here because inventing
that behaviour would be adding a feature the contract does not ask for.

## 4. No test coverage beyond the two contract cases
The suite covers exactly the two owners named in the contract. Once item 3 is decided,
a case for an unrecognised owner would be worth adding. Not added now, for the same
reason.

## 5. Nothing detects drift between the contract and the tests
The root cause of one of the two failures was a test that still encoded a superseded
contract. There is no mechanism that would have surfaced that. Suggest, at minimum, a
convention of citing the contract line in each test's docstring so a contract change has
an obvious set of tests to revisit. Not implemented — it would mean touching tests
beyond what this repair requires.

## Explicitly not addressed
The repository records a pending business decision (`decision-D7.md`, `ceo-items.md`
item 1.1) about a paid provider for a separate project. That is outside this repair's
scope, it is not an engineering improvement, and it remains undecided. No
recommendation on it is offered or implied here.
