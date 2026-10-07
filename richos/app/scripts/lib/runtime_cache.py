"""Where a nightly state directory keeps the runtime built from one runtime recipe.

The directory name carries the first 12 hex digits of the recipe file's SHA-256, so a changed
`runtime-sources.json` names a directory that does not exist yet and the nightly builds it,
instead of finding the previous recipe's runtime at a fixed path and refusing it at
`verify-runtime.py` (Frank's media-tools review M3, 2026-10-07). A runtime built from an older
recipe is simply no longer used; nothing deletes it.

It also names the speech model gui-boot's fixture needs (`gui_speech_model`, below).

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


# THE SPEECH MODEL gui-boot.test.sh's healthy machine carries (RICHOS_GUI_SPEECH_MODEL). Since
# 2026-10-07 the video tools are a setup essential (media-tools plan, slice 3), and they are
# present only when a pinned speech model verifies, so a fixture without one boots to "my video
# tools is NOT installed" instead of "nothing missing". This is the pinned small.en already on
# the Mac the nightlies run on (487,614,201 B, engine/voice/models/model-pins.json); nothing is
# downloaded for it. Read by `nightly-local.py` (`Runner.runtime`) and `proof-run.py`
# (`supply_runtime`), so the build and the checks before it hand gui-boot the same file.
GUI_SPEECH_MODEL = Path.home() / "Models" / "Whisper" / "ggml-small.en.bin"


def gui_speech_model():
    """GUI_SPEECH_MODEL when it is a file on this Mac, else None (gui-boot then refuses and
    names the input it needs)."""
    return GUI_SPEECH_MODEL if GUI_SPEECH_MODEL.is_file() else None
