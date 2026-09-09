# Improvement suggestions (NOT implemented)

These are unrelated to the approved contract repair and were deliberately left unimplemented.

1. **Unknown owner values fall through silently.** `status()` uses an `else` branch, so any owner string that is neither `native` nor `external` (typos, `None`, empty string) returns `verified`. Consider an explicit mapping plus a raised error or a defined default for unrecognised owners — but only once requirements.md states what the contract is for them.

2. **No test coverage for unrecognised owners.** Once the above is specified, add a case asserting the behaviour for an unknown owner so the fall-through cannot silently change meaning again.

3. **Contract values are bare string literals.** `"platform-pending"` and `"verified"` are duplicated across `lifecycle.py` and `test_lifecycle.py`. Named constants or an enum would make a future contract change a single-site edit and prevent typo-level drift between code and tests.

4. **backlog.md is easy to mistake for the spec.** The stale `native -> verified` assertion in the test suite matched backlog.md exactly, which suggests someone previously read it as authoritative. A one-line header in backlog.md marking it as historical (and requirements.md as the authority) would reduce the chance of a repeat. Not done here: backlog.md is out of scope and must stay unchanged.

5. **No type hints or docstring on `status()`.** A signature such as `def status(owner: str) -> str:` plus a docstring citing requirements.md would make the contract discoverable from the code.

6. **Test suite has no regression guard tying tests to requirements.md.** Consider referencing the requirements line in a test docstring so a future contract change surfaces the tests that must move with it.
