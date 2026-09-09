# Improvement suggestions (not implemented)

These are unrelated observations noticed while repairing lifecycle.py / test_lifecycle.py
to satisfy requirements.md. They are out of scope for this fix and are recorded here only.

1. `status(owner)` uses an `if/else` that treats any non-"native" value as "external"
   (returns "verified" for it). There is no explicit handling or validation for unknown
   owner strings (e.g. typos, `None`, or a future third workspace type), so such inputs
   would silently be classified as "external" rather than raising an error. Consider an
   explicit `if owner == "native": ... elif owner == "external": ... else: raise ValueError(...)`
   once requirements.md defines behavior for unrecognized owners.

2. There is no test coverage for an unrecognized/invalid `owner` value. Once the desired
   behavior for that case is specified in requirements.md, a corresponding test case
   should be added.
