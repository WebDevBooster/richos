"""Read-only engine selection. The shell entry point delegates here.

Ordinary paths retain the established sibling/name/section rules. Config values
use content-bound reader closures. An unknown closure is explicit and conservative;
this module does not infer independence from an absent grep match.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from verification_inputs import Dependencies, Snapshot, Unsupported, config, config_change, revisions

SECTIONED = "scripts/hooks/contract-integrity.test.sh"
GLOBAL_CONFIG = "scripts/verification-config.test.sh"


def sections(text):
    bodies, current = {}, None
    for line in text.splitlines():
        match = re.fullmatch(r"if _section ([A-Za-z0-9_.-]+); then", line)
        if match:
            current = match[1]
            if current in bodies:
                raise Unsupported("duplicate section marker: " + current)
            bodies[current] = []
        elif line.startswith("fi  # _section"):
            current = None
        elif current:
            bodies[current].append(line)
    if not bodies:
        raise Unsupported("sectioned suite has no section markers")
    return {name: "\n".join(lines) for name, lines in bodies.items()}


def validate_config(engine):
    declaration = json.loads((engine / "scripts/lib/verification-dependencies.json").read_text())
    known = set(declaration["config_keys"])
    known.update(key for row in declaration["nodes"].values() for key in row.get("keys", []))
    parsed = config((engine / "orchestration.config").read_text())
    unknown = set(parsed) - known
    if unknown:
        raise Unsupported("unknown config keys require reader declarations: " + ", ".join(sorted(unknown)))
    return len(parsed)


class Selection:
    def __init__(self, engine, suites, read, declaration):
        self.engine, self.read, self.declaration = engine, read, declaration
        self.suites = {path: read(path) for path in suites}
        if any(text is None for text in self.suites.values()):
            raise Unsupported("suite disappeared while planning")
        self.bodies = sections(self.suites[SECTIONED]) if SECTIONED in self.suites else {}
        self.units = [unit for suite in self.suites for unit in
                      ([suite + ":" + part for part in self.bodies] if suite == SECTIONED else [suite])]
        self.selected, self.unmapped = {}, []

    def add(self, unit, reason):
        self.selected.setdefault(unit, set()).add(reason)

    def suite(self, suite, path, reason):
        if suite == SECTIONED:
            basename = Path(path).name
            hits = [part for part, body in self.bodies.items() if basename in body]
            for part in hits or self.bodies:
                why = reason if hits else reason + "; ALL sections: named outside any section body"
                self.add(suite + ":" + part, path + ": " + why)
        else:
            self.add(suite, path + ": " + reason)

    def ordinary(self, path):
        before = sum(len(reasons) for reasons in self.selected.values())
        basename, stem = Path(path).name, str(Path(path).with_suffix(""))
        if path.startswith("voice/") and Path(path).suffix in (".js", ".mjs", ".json", ".sh"):
            self.suite("voice/tests/run.test.sh", path, "voice component inputs")
        if path in self.suites:
            self.suite(path, path, "changed suite")
        for sibling in (stem + ".test.sh", path + ".test.sh", str(Path(stem).parent / "tests" / (Path(stem).name + ".test.sh"))):
            if sibling in self.suites:
                self.suite(sibling, path, "sibling suite")
        for suite, text in self.suites.items():
            if basename in text:
                self.suite(suite, path, "basename dependency (conservative)")
        matched = sum(len(reasons) for reasons in self.selected.values()) > before
        if not matched and (Path(path).suffix in (".sh", ".py", ".bash") or (self.read(path) or "").startswith("#!")):
            self.unmapped.append(path)

    def configuration(self, before, after, unknown=False):
        change = config_change(before, after)
        if unknown:
            change.update(content=True, presence=True, fallback="path-only request has no before/after config identity")
        graph = Dependencies(self.engine, self.declaration, read=self.read)
        for unit, reasons in graph.config_units(change, self.units).items():
            for reason in reasons:
                self.add(unit, "orchestration.config: " + reason)
        # Validation remains a genuine whole-config obligation even when no
        # behavior reader consumes a newly introduced setting.
        if change["content"]:
            if GLOBAL_CONFIG not in self.units:
                raise Unsupported("global config validation unit is missing from the target inventory")
            self.add(GLOBAL_CONFIG, "orchestration.config: global syntax and unknown-key validation")


def git(root, *argv):
    result = subprocess.run(["git", "-C", str(root), *argv], capture_output=True, text=True)
    if result.returncode:
        raise Unsupported("Git input unavailable: " + " ".join(argv) + ": " + result.stderr.strip())
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--range")
    parser.add_argument("--base")
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--working", action="store_true")
    parser.add_argument("--paths-file", type=Path)
    parser.add_argument("--paths", action="append", default=[])
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--explain", action="store_true")
    parser.add_argument("--validate-config", action="store_true")
    args = parser.parse_args(argv)
    engine = Path(__file__).resolve().parents[2]
    try:
        if args.validate_config:
            print("PASS: global config syntax and declarations (%d keys)" % validate_config(engine))
            return 0
        root = Path(git(engine, "rev-parse", "--show-toplevel").strip())
        prefix = engine.relative_to(root).as_posix()
        prefix = "" if prefix == "." else prefix + "/"
        explicit = bool(args.paths or args.paths_file)
        if sum(bool(value) for value in (args.range, args.staged, args.working)) > 1:
            raise Unsupported("choose one of --range, --staged or --working")
        if args.staged:
            old, new = "HEAD", "INDEX"
            diff = ["--cached"]
        elif args.working:
            old, new = args.base or "HEAD", "WORKTREE"
            diff = [old]
        elif args.range or args.base or not explicit:
            old, new = revisions(root, args.range or (args.base or "HEAD^") + "..HEAD")
            diff = [old, new]
        else:
            old, new, diff = None, "WORKTREE", []
        after = Snapshot(root, new)
        read = lambda path: after.read(prefix + str(path))
        if args.paths_file:
            changed = args.paths_file.read_text().splitlines()
        elif args.paths:
            changed = [part for value in args.paths for part in value.split(",")]
        else:
            changed = git(root, "diff", "--name-only", *diff).splitlines()
            if new == "WORKTREE":
                changed += git(root, "ls-files", "--others", "--exclude-standard").splitlines()
        changed = sorted({path.strip() for path in changed if path.strip()})
        if new == "WORKTREE":
            suites = sorted(path.relative_to(engine).as_posix() for path in engine.rglob("*.test.sh") if path.is_file())
        else:
            files = (git(root, "ls-files") if new == "INDEX" else git(root, "ls-tree", "-r", "--name-only", after.revision)).splitlines()
            suites = sorted(path[len(prefix):] for path in files if path.startswith(prefix) and path.endswith(".test.sh"))
        declaration = json.loads((engine / "scripts/lib/verification-dependencies.json").read_text())
        selection = Selection(engine, suites, read, declaration)
        for path in changed:
            if not path.startswith(prefix):
                continue
            relative = path[len(prefix):]
            if relative == "orchestration.config":
                before = Snapshot(root, old).read(path) if old else None
                selection.configuration(before, read(relative), unknown=old is None)
            else:
                selection.ordinary(relative)
        for unit, reasons in sorted(selection.selected.items()):
            print(unit)
            if args.explain:
                for reason in sorted(reasons):
                    print("    %s -> %s" % (reason, unit), file=sys.stderr)
        print("%d changed path(s) -> %d unit(s)" % (len(changed), len(selection.selected)), file=sys.stderr)
        if not selection.selected:
            print("NOTHING TO RUN: no affected suite for these paths.", file=sys.stderr)
        if selection.unmapped:
            print("%d changed executable file(s) are named by NO suite:" % len(selection.unmapped), file=sys.stderr)
            print("\n".join("    " + path for path in selection.unmapped), file=sys.stderr)
            if args.strict:
                return 1
        return 0
    except (OSError, ValueError, Unsupported, subprocess.SubprocessError) as exc:
        print("ERROR: ci-affected-units.sh: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
