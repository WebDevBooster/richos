# Improvement suggestions (noted only — NOT implemented)

These are unrelated to the approved repair scope and were deliberately left unimplemented.

1. **`status()` has a catch-all `else` branch.** Any owner value that is not `"native"` is
   currently reported as `"verified"`, so `status("bogus")` and `status(None)` both return
   `"verified"`. requirements.md only defines `native` and `external`, so the current behaviour
   is not a contract violation, but an explicit `external` branch plus a raise/sentinel for
   unknown owners would fail loudly instead of silently mislabelling.

2. **No test coverage for unknown or malformed owner values.** Adding a case for an
   unrecognised owner would lock in whatever behaviour is chosen for item 1.

3. **Status strings are bare literals.** Promoting `"platform-pending"` / `"verified"` to named
   constants (or a stdlib `enum.Enum`) in `lifecycle.py` would remove the typo risk of repeating
   the strings across code and tests. Stdlib only; no new dependency needed.

4. **`backlog.md` is not marked as superseded in the file itself.** It states a previous contract
   that contradicts requirements.md, which is what produced the obsolete `test_native` assertion.
   A "SUPERSEDED — see requirements.md" header would prevent a future reader from treating it as
   authoritative. This was NOT done here: backlog.md is explicitly out of scope and must remain
   unchanged.

5. **No `.gitignore`.** Running the suite creates `__pycache__/`, which shows up as untracked
   noise in `git status`.

## Explicitly out of scope / not acted on

- The D-7 call-transcription provider decision referenced in `backlog.md`, `CEO-TODOs.md`,
  `ceo-items.md` and `decision-D7.md` is a separate business decision for a different project.
  No provider was chosen, recommended, or purchased, and nothing was published or committed.
