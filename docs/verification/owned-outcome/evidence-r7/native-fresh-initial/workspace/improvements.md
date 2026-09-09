# Unrelated improvement suggestions

Observations noticed while doing the lifecycle repair. These are **suggestions only** — none
of them were implemented, and all are outside the scope of that repair.

## 1. `status()` silently accepts unknown owners

`lifecycle.py` branches on `owner == "native"` and treats *everything else* as external.
`status("nativ")`, `status(None)` or `status("")` all return `"verified"` rather than failing.
A typo in a caller therefore produces a confident wrong answer instead of an error.
Consider an explicit mapping that raises `ValueError` on unknown owners.

## 2. No test coverage for unknown owner values

The suite has exactly two cases, one per known owner. There is no test pinning the behaviour
for an unrecognised owner, which is why item 1 can regress unnoticed.

## 3. Contract documents carry no effective date or supersession marker

`requirements.md` ("Current approved contract") and `backlog.md` ("Previous contract") state
contradictory values, and only the prose adjectives distinguish which one governs. This is the
exact ambiguity that let a stale assertion survive in the test suite. A dated header, a version
number, or an explicit `Supersedes:` line in `requirements.md` would make the precedence
mechanical rather than interpretive.

## 4. `diagnosis.json` has no documented schema

`README.md` tells the reader how to *validate that it parses*, but nothing records what keys it
must contain. A short schema section in the README (or a JSON Schema file) would make the
required shape checkable rather than something each author has to be told.

## 5. Repository has no commits and no `.gitignore`

Every file is currently untracked, so there is no baseline to diff a repair against and no
history explaining when the contract changed. An initial commit plus a `.gitignore`
(`__pycache__/`, `*.pyc`) would help. Committing was out of scope here and was not done.

## 6. No automated test execution

Nothing runs `python3 -m unittest` other than a human following the README. A minimal CI
workflow would catch a contract regression at push time.
