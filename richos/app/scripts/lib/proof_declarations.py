"""Read script-suite dependencies separately from explicit behavioral coverage."""
from pathlib import Path, PurePosixPath
import re
import sys


class InvalidDeclaration(ValueError):
    pass


def read_declarations(root, directory):
    rows = []
    suites = sorted(directory.glob("*.test.sh"))
    if not suites:
        raise InvalidDeclaration(f"{directory}: no script suites")
    for suite in suites:
        declarations = {"inputs": [], "covers": []}
        for number, line in enumerate(suite.read_text().splitlines(), 1):
            match = re.fullmatch(r"# run-tests: (inputs|covers)(?:\s+(.*))?", line)
            if match:
                declarations[match[1]].append((number, (match[2] or "").split()))
        for kind, claims in declarations.items():
            if len(claims) != 1:
                raise InvalidDeclaration(f"{suite}: expected exactly one '# run-tests: {kind}' row")
            number, paths = claims[0]
            if not paths or ("-" in paths and (kind != "covers" or paths != ["-"])):
                raise InvalidDeclaration(f"{suite}:{number}: {kind} must list paths; use 'covers -' for no coverage")
        inputs = declarations["inputs"][0][1]
        number, covers = declarations["covers"][0]
        if covers == ["-"]:
            covers = []
        for path in covers:
            where = f"{suite}:{number}: covers {path}"
            if (not re.fullmatch(r"[A-Za-z0-9_./-]+", path)
                    or PurePosixPath(path).is_absolute()
                    or any(part in {"", ".", ".."} for part in path.split("/"))):
                raise InvalidDeclaration(f"{where}: expected a literal repository-relative path")
            if (root / path).is_dir():
                raise InvalidDeclaration(f"{where}: directory coverage would hide an orphan; list tested files instead")
            if not (root / path).is_file():
                raise InvalidDeclaration(f"{where}: path is not in the tree")
            if not any(path == dep or path.startswith(dep + "/") for dep in inputs):
                raise InvalidDeclaration(f"{where}: not selected by this suite's inputs")
        rows.append((suite.name, inputs, covers))
    return rows


def main():
    try:
        rows = read_declarations(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, InvalidDeclaration) as exc:
        print(f"proof-for.sh: {exc}", file=sys.stderr)
        return 2
    for suite, inputs, covers in rows:
        print("inputs", suite, " ".join(inputs), sep="\t")
        for path in covers:
            print("covers", suite, path, sep="\t")
    return 0


if __name__ == "__main__":
    sys.exit(main())
