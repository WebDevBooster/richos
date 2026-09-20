"""Suite declarations consumed by the runner's skip proof (481ec7c2).

Only top-level *.test.sh files are discovered by the app runner. Helpers and
nested suites do not claim its input-declaration contract.
"""
from pathlib import PurePosixPath

RULES = {"suite-inputs": "blocking"}


def scan(path, text):
    p = PurePosixPath(path)
    if p.parent.as_posix() != "richos/app/scripts" or not p.name.endswith(".test.sh"):
        return []
    prefix = "# run-tests: inputs "
    if not any(line.startswith(prefix) and line[len(prefix):].strip() for line in text.splitlines()):
        return [("suite-inputs", 1)]
    return []
