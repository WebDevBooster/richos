"""Where a nightly state directory keeps the runtime built from one runtime recipe.

The directory name carries the first 12 hex digits of the recipe file's SHA-256, so a changed
`runtime-sources.json` names a directory that does not exist yet and the nightly builds it,
instead of finding the previous recipe's runtime at a fixed path and refusing it at
`verify-runtime.py` (Frank's media-tools review M3, 2026-10-07). A runtime built from an older
recipe is simply no longer used; nothing deletes it.

Read by `nightly-local.py` (`Runner.runtime`, which builds it), `proof-run.py`
(`supply_runtime`) and `operator-probes/run-probes.py` (`--runtime` default), so all three name
the same directory for the same recipe.
"""
import hashlib
from pathlib import Path


def cache_path(state, recipe):
    """`<state>/runtime-<sha256(recipe bytes)[:12]>`. Raises if the recipe cannot be read."""
    digest = hashlib.sha256(Path(recipe).read_bytes()).hexdigest()[:12]
    return Path(state) / f"runtime-{digest}"
