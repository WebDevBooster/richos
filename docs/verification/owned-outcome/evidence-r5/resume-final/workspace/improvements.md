# Unrelated improvement suggestions

These are observations made while diagnosing lifecycle.py / test_lifecycle.py.
They are not required by requirements.md and were NOT acted on.

- `status(owner)` uses `owner == "native"` and treats any other value as
  "external", with no validation. Consider an explicit check/whitelist for
  known owner values (e.g. raise on an unrecognized owner) so typos or new
  owner types fail loudly instead of silently falling into the "external"
  branch.
- There is no test coverage for unexpected/invalid `owner` inputs (e.g. `None`,
  empty string, or an unrecognized owner string). Adding such a case would
  make the current binary native/external contract more robust to change.
- requirements.md and backlog.md both live at the repo root with similar
  names; a short note in README.md distinguishing "current contract" vs
  "historical/superseded contract" documents could reduce future confusion
  about which file is authoritative (this file already partially does this,
  but a pointer from backlog.md's own text would help future readers land
  on requirements.md first).
