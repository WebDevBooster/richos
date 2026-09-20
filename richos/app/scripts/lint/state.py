"""Green records are runtime state, never tracked ratchet data."""
import json
import os
from pathlib import Path
import tempfile
from common import Refusal


def green(path, fingerprint):
    try:
        data = json.loads(path.read_text())
        return data.get("schema") == 1 and data.get("fingerprint") == fingerprint and data.get("green") is True
    except (OSError, ValueError, AttributeError):
        return False


def save(path, fingerprint, revision, root):
    if path.resolve().is_relative_to(root.resolve()):
        raise Refusal("last-green state must be outside the source checkout")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".lint-green-", delete=False) as output:
            temporary = Path(output.name)
            json.dump(dict(schema=1, green=True, fingerprint=fingerprint, revision=revision), output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
