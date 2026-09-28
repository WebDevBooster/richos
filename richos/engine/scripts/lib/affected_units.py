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

from verification_inputs import (Dependencies, Snapshot, Unsupported, config, config_change,
                                 hook_command_path, hook_entries, hook_reader, hooks_change, revisions)

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

    def suite(self, suite, path, reason, all_sections=False):
        if suite == SECTIONED:
            basename = Path(path).name
            hits = list(self.bodies) if all_sections else [
                part for part, body in self.bodies.items() if basename in body]
            for part in hits or self.bodies:
                why = reason if hits else reason + "; ALL sections: named outside any section body"
                self.add(suite + ":" + part, path + ": " + why)
        else:
            self.add(suite, path + ": " + reason)

    def unchanged_seated_reader(self, suite, before, after):
        """Only a reviewed raw-text observer can ignore unrelated settings lines."""
        row = self.declaration.get('hook_readers', {}).get(suite)
        if not isinstance(row, dict) or 'seated_text_needles' not in row:
            return False
        needles = row['seated_text_needles']
        if (not isinstance(needles, list) or not needles
                or any(not isinstance(needle, str) or not needle or '\n' in needle for needle in needles)
                or not isinstance(before, str) or not isinstance(after, str)):
            return False
        try:
            hook_reader(row, self.read)
            if suite not in row['sources']:
                return False
            # Missing, malformed or unknown documents retain the old selection.
            if any(not isinstance(json.loads(text), dict) for text in (before, after)):
                return False
            if 'seated_dispatch_reader' in row:
                if row['seated_dispatch_reader'] is not True:
                    return False
                # The registration helper searches all events for dispatcher
                # commands. Keep every argument/dispatch-key change visible.
                def dispatchers(text):
                    return sorted(entry['command'] for entry in hook_entries(text, settings=True).values()
                                  if 'dispatch-pretooluse' in entry['command'])
                if dispatchers(before) != dispatchers(after):
                    return False
        except (Unsupported, ValueError):
            return False
        return all([line for line in before.splitlines() if needle in line] ==
                   [line for line in after.splitlines() if needle in line]
                   for needle in needles)

    def unchanged_probe_reader(self, suite, before, after):
        """Ignore only unrelated literal oracle rows for qualified text readers."""
        row = self.declaration.get('hook_readers', {}).get(suite)
        if not isinstance(row, dict) or 'probe_registration_needles' not in row:
            return False
        needles = row['probe_registration_needles']
        if (not isinstance(needles, list) or not needles
                or any(not isinstance(n, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', n) for n in needles)
                or not isinstance(before, str) or not isinstance(after, str)):
            return False
        try:
            hook_reader(row, self.read)
            if suite not in row['sources']:
                return False
            def observed(text):
                blocks = list(re.finditer(r'(?m)^    BR_EXPECTED="\\\n([^"]*)"', text))
                if len(blocks) != 1:
                    raise Unsupported('ambiguous probe registration oracle')
                block = blocks[0]
                lines = block[1].splitlines(keepends=True)
                if not lines or any(not re.fullmatch(r'[A-Za-z0-9_.-]+\.sh\|[A-Za-z][A-Za-z0-9]*\n?', line)
                                    for line in lines):
                    raise Unsupported('nonliteral probe registration oracle')
                retained = ''.join(line for line in lines if any(n in line for n in needles))
                return text[:block.start(1)] + retained + text[block.end(1):]
            return observed(before) == observed(after)
        except Unsupported:
            return False

    def ordinary(self, path, before=None, after=None):
        prior_count = sum(len(reasons) for reasons in self.selected.values())
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
                if path == '.claude/settings.local.json' and self.unchanged_seated_reader(suite, before, after):
                    continue
                if path == 'scripts/hooks/contract-integrity-probe.sh' and self.unchanged_probe_reader(suite, before, after):
                    continue
                self.suite(suite, path, "basename dependency (conservative)")
        matched = sum(len(reasons) for reasons in self.selected.values()) > prior_count
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

    def hooks(self, before, after, unknown=False):
        change = hooks_change(before, after)
        if unknown:
            change.update(content=True, fallback='path-only request has no before/after hook identity')
        if not change['content']:
            return
        paths = set()
        if not change['fallback']:
            try:
                paths = {path for command in change['commands']
                         if (path := hook_command_path(command)) is not None}
            except Unsupported as exc:
                change['fallback'] = str(exc)
        if change['fallback']:
            for unit in self.units:
                self.add(unit, 'hooks/hooks.json: syntax/command fallback: ' + change['fallback'])
            return
        # A removed command still selects its behavior consumers. Registration
        # and ordering checks below are additional obligations, not substitutes.
        for path in sorted(paths):
            self.ordinary(path)
        contracts = self.declaration.get('hook_readers', {})
        for suite, text in self.suites.items():
            row = contracts.get(suite)
            if row is None:
                if 'hooks.json' in text:
                    self.suite(suite, 'hooks/hooks.json', 'unqualified manifest reader (conservative)',
                               all_sections=True)
                continue
            try:
                row = hook_reader(row, self.read)
                if suite not in row['sources']:
                    raise Unsupported('hook reader omits its own source: ' + suite)
            except Unsupported as exc:
                self.suite(suite, 'hooks/hooks.json', str(exc), all_sections=True)
                continue
            affected = paths & set(row['commands'])
            events = (set(change['events']) if row.get('all_events')
                      else set(change['events']) & set(row.get('events', [])))
            # Existing grep-based registration assertions also inspect raw
            # text. Preserve their behavior on duplicate lines, formatting and
            # description edits, even when parsed hook semantics are unchanged.
            needles = row.get('text_needles', [])
            changed_text = any([line for line in before.splitlines() if needle in line] !=
                               [line for line in after.splitlines() if needle in line]
                               for needle in needles)
            if affected or events or changed_text:
                why = ('changed registration/ordering for ' + ', '.join(sorted(affected))
                       if affected else 'changed event ordering/inventory for ' + ', '.join(sorted(events))
                       if events else 'changed text consumed by registration assertions')
                # A suite-level inventory contract includes shared setup.
                # Basename matches inside a section cannot narrow that scope.
                self.suite(suite, 'hooks/hooks.json', why, all_sections=True)


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
            elif relative == 'hooks/hooks.json':
                before = Snapshot(root, old).read(path) if old else None
                selection.hooks(before, read(relative), unknown=old is None)
            elif relative in ('.claude/settings.local.json', 'scripts/hooks/contract-integrity-probe.sh'):
                before = Snapshot(root, old).read(path) if old else None
                selection.ordinary(relative, before, read(relative))
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
