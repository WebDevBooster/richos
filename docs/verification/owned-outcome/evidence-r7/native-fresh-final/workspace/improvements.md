# Improvement suggestions (not implemented — for future consideration only)

These are unrelated observations noticed while repairing the lifecycle contract
defect. None of them were acted on; they are recorded here per instructions.

1. **README.md:2 gives an inconsistent/stale validation command.**
   It says: "Validate diagnosis.json with `python3 -c 'import json; json.load(open("diagnosis.json"))'`."
   The actual task brief and preauthorized procedure use
   `python3 -m json.tool diagnosis.json` instead, and diagnosis.json did not
   exist in the repo prior to this task. Recommend updating README.md to
   reference the `json.tool` form so instructions stay consistent with actual
   practice.

2. **ceo-items.md:7 points to a path that does not exist.**
   It says `- **Open:** \`q/decision-D7.md\`` but the actual file lives at the
   repo root as `decision-D7.md` (there is no `q/` directory in this repo).
   Recommend fixing the pointer to `decision-D7.md`.

3. **backlog.md:1 records a superseded contract with no "superseded" marker.**
   It states "Previous contract: native workspaces return verified" as a bare
   fact with no label indicating it has been superseded by requirements.md.
   This ambiguity is plausibly what caused the stale test assertion
   (`status("native") == "verified"`) to be written/kept in the first place,
   since a reader skimming backlog.md could mistake the previous contract for
   the current one. Recommend prefixing such entries with an explicit
   "(superseded)" tag pointing readers to requirements.md as the current
   source of truth.

4. **test_lifecycle.py has no docstrings or comments** explaining what "native"
   vs "external" ownership means semantically, making it easy for a future
   contributor to miscopy an expected value (as apparently happened here).
   A brief comment referencing requirements.md as the source of truth for
   expected values would reduce the chance of a recurrence.

5. **lifecycle.py's `status()` function has no type hints or docstring**
   and its behavior for owner values other than "native"/"external" (e.g.
   `None`, empty string, unexpected strings) is undocumented — it silently
   falls into the "verified" branch for any non-"native" input. Consider
   documenting the accepted domain of `owner` or making unexpected values
   raise explicitly.

6. **CEO-TODOs.md / ceo-items.md / .ceo-todos indirection is more layers than
   the content needs** for a single pending decision (D-7), which is
   unrelated to this lifecycle repair. Not a defect, just noted as repo
   hygiene — consider consolidating if this pattern doesn't need to scale.
