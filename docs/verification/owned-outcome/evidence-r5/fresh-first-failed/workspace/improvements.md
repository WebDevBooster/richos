# Improvement suggestions

Unrelated to the native/external repair. Suggestions only — none of these were implemented.

## 1. `status()` has no coverage for unspecified owners

`requirements.md` names only `native` and `external`. Every other owner falls through to
`"bound"`, and no test pins that. During this repair a concurrent edit briefly changed the
fallback so that *every* non-native owner returned `"verified"` — tests still passed, because
nothing asserts the fallback. A test for an unspecified owner would have caught it.

## 2. The contract lives in prose, not in one place the code can reference

`requirements.md` states the contract in a sentence, `lifecycle.py` encodes it in branches, and
`test_lifecycle.py` encodes it a third time in assertions. Three copies drift independently —
which is exactly how the stale `native` assertion survived. A single mapping table (owner →
status) that the tests iterate over would collapse this to one source of truth.

## 3. No signal for an unknown owner

`status()` accepts any string and silently returns `"bound"`. A typo like `"externl"` gets a
plausible-looking answer instead of an error. Consider raising on unrecognized owners, or
documenting `"bound"` as the deliberate default in `requirements.md`.

## 4. Contract-history hygiene

`backlog.md` mixes a superseded technical contract with an unrelated pending business decision
(D-7 transcription provider). It was useful here as evidence of *which* side was stale, but that
only worked because someone read it carefully. Superseded contracts would be easier to trust as
evidence if they carried the date and the change that superseded them.

## 5. Test file has no runner config

`test_lifecycle.py` is run by hand per `README.md`. There is no CI config, no `pytest.ini`, and
no exit-code-checked entry point, so nothing prevents a stale assertion from sitting unnoticed
between manual runs — the condition that produced this repair.
