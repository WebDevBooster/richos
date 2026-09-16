#!/usr/bin/env python3
"""Run the delivered entry points after relocation and verify immutable bytes."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime", type=Path)
args = parser.parse_args()
here = Path(__file__).resolve().parent
verify = ["/usr/bin/env", "python3", str(here / "verify-runtime.py")]
with tempfile.TemporaryDirectory(prefix="runtime relocation ") as temporary:
    copied = Path(temporary) / "delivered runtime"
    shutil.copytree(args.runtime, copied, symlinks=True)
    env = {"PATH": str(copied / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path(temporary) / "empty home")}
    Path(env["HOME"]).mkdir()
    # In particular PYTHONDONTWRITEBYTECODE is absent. The installed launcher
    # itself must keep Python imports from modifying inventoried bytecode.
    subprocess.run([str(copied / "bin/python3"), "-c", "import sqlite3, ssl, encodings, json; assert __import__('sys').dont_write_bytecode"], env=env, check=True)
    subprocess.run([str(copied / "bin/node"), "--version"], env=env, check=True)
    subprocess.run([str(copied / "bin/git"), "--version"], env=env, check=True)
    subprocess.run([str(copied / "bin/jq"), "--version"], env=env, check=True)
    subprocess.run(verify + [str(copied), str(here / "runtime-sources.json")], check=True)
print("PASS: relocated runtimes execute without changing their inventory")
