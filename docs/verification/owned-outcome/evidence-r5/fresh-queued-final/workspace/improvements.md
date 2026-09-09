# Improvement suggestions (unrelated to the lifecycle repair)

Suggestions only. None of these were implemented, and none is required for the
current repair. Each would need its own approval before any work starts.

## 1. `status()` has no defined behavior for unknown owners

`lifecycle.py` uses a two-branch expression, so every owner value that is not
`"native"` falls into the external branch. `status("")`, `status(None)` and
`status("typo")` all silently return `"verified"`. The contract in
`requirements.md` only defines `native` and `external`, so the behavior for any
third value is undefined rather than intentional. Consider an explicit mapping
plus a raised error (or a documented default) for unrecognized owners — but this
needs a contract decision first, since requirements.md does not say what should
happen.

## 2. No input validation or type hints

`status(owner)` accepts any object. Adding a type hint (`owner: str -> str`) and
normalizing case/whitespace would make misuse visible at the call site. Worth
doing only if the contract is extended to say how malformed input is handled.

## 3. Status strings are bare literals

`"platform-pending"` and `"verified"` are duplicated between `lifecycle.py` and
`test_lifecycle.py` as raw strings. A module-level constant or an `enum.Enum`
(stdlib) would make a future contract change a one-line edit and would stop
typos from passing silently.

## 4. Test suite does not cover the contract's negative space

The suite has exactly one assertion per owner. Useful additions: a test that
pins the exact set of owners the contract defines, and a test asserting that the
two owners return *different* statuses (which would have caught the superseded
assertion faster, since it required both owners to return `"verified"`).

## 5. Contract documents are prose with no machine-readable form

`requirements.md` states the contract in a single English sentence, and
`backlog.md` states the superseded one in a nearly identical sentence. The two
are easy to confuse — that confusion is the direct cause of the stale assertion
fixed in this repair. Consider a small table or a stdlib-parseable block in
`requirements.md`, and a clear `SUPERSEDED` banner at the top of `backlog.md`,
so the authoritative source is unmistakable at a glance.

## 6. Superseded contract text lives in an active-sounding file

`backlog.md` reads like a live backlog but actually holds historical contract
text mixed with an unrelated pending decision (D-7). Splitting the historical
contract record from the open-items list would reduce the chance of a future
engineer treating it as current.

## 7. No CI or pre-commit check

Nothing runs `python3 -m unittest test_lifecycle` automatically. A minimal
stdlib-only pre-commit hook or CI step would catch a contract/implementation
divergence at commit time rather than during a dedicated repair.
