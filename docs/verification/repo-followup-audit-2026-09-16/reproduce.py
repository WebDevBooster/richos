#!/usr/bin/env python3
"""Reproduce four defects in a disposable archive of the audited revision.

These assertions establish defective behavior. They are not post-fix regression
gates: after repairs, invert the affected assertions in the product's test suite.
No live accounts, model downloads or product/user state are used.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

REVISION = "2c1a48463da1d2028dfec958ff49924bab33828c"
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def main():
    node = shutil.which("node")
    if not node:
        raise SystemExit("Node is required")
    with tempfile.TemporaryDirectory(prefix="richos-followup-audit-") as directory:
        root = Path(directory)
        archive = root / "source.tar"
        subprocess.run(["git", "archive", "--format=tar", "--output", str(archive), REVISION],
                       cwd=REPO, check=True, timeout=60)
        source = root / "source"
        source.mkdir()
        subprocess.run(["tar", "-xf", str(archive), "-C", str(source)], check=True, timeout=60)
        for probe in ("loro-scope", "loro-read-links", "loro-concurrent", "watcher"):
            print(f"\n{probe}", flush=True)
            subprocess.run([node, str(HERE / (probe + ".mjs")), str(source)],
                           check=True, timeout=30)
    print("\nAll four defects reproduced against the audited revision.")


if __name__ == "__main__":
    main()
