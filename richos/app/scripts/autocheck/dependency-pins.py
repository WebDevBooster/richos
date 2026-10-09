#!/usr/bin/env python3
"""dependency-pins.py — a commit that changes a file the engine's verification-input selector
pins must renew that pin in the same change.

WHY (2026-09-30, twice in one day): `richos/engine/scripts/lib/verification-dependencies.json`
pins every reviewed reader by SHA-256 (a node's `source`, a node's `external` readers, a hook
reader's `sources`). `verification_inputs.py` refuses any unit that reaches a pin that no longer
matches ("changed reader requires input qualification"), and `verification-inputs.test.sh`
fails. Nothing at the commit compared a changed file to its pin, so each branch left its own
pins stale and the expensive suite found the sum hours later on main: 95 failures after five
merges (renewed in 5a632d0e), then 108 after ten more. The same comparison runs here, over the
branch's changed files only, in well under a second; the JSON is parsed only when a changed
path is named in it.

  dependency-pins.py                 the commit check (autocheck.py calls it for every branch
                                     commit): exit 1 refuses, naming each stale pin and the
                                     command that renews it
  dependency-pins.py --renew PATH..  set every pin of each repository-relative PATH to the
                                     working-tree bytes, in the working-tree JSON
  dependency-pins.py --all [--rev R] list every stale pin in the whole file (R: a commit, or the
                                     index by default); exit 1 when there is one

The hash is taken exactly as the selector takes it: a node source and a hook-reader source are
read as text (universal newlines, surrogateescape) and re-encoded; an external reader is read
as raw bytes. Pins outside this repository (HOME, or an environment root with an absolute
default) are not this repository's to check and are skipped.
"""
import hashlib
import json
import subprocess
import sys
import types
from pathlib import Path

DECLARATION = "richos/engine/scripts/lib/verification-dependencies.json"
ENGINE = "richos/engine/"
LAND_BRANCH = "main"
SELF = "richos/app/scripts/autocheck/dependency-pins.py"
INPUTS = ENGINE + "scripts/lib/verification_inputs.py"
OMITTED = "omitted known key reads in "
UNQUALIFIED = "unqualified reader "


def git(*args, check=True, text=True):
    result = subprocess.run(["git", *args], capture_output=True, text=text, stdin=subprocess.DEVNULL)
    if check and result.returncode:
        raise SystemExit(f"dependency-pins: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def say(text=""):
    print(text, file=sys.stderr, flush=True)


def digest(data, as_text):
    """SHA-256 as verification_inputs.py computes it for this kind of pin."""
    if as_text:
        text = data.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n").replace("\r", "\n")
        data = text.encode("utf-8", errors="surrogateescape")
    return hashlib.sha256(data).hexdigest()


def pins(declaration):
    """Every pin this repository can check: (repository path, where, pinned digest, as_text)."""
    found = []
    for name, row in sorted((declaration.get("nodes") or {}).items()):
        if isinstance(row, dict) and row.get("source") and row.get("sha256"):
            found.append((ENGINE + row["source"], f'node "{name}"', row["sha256"], True))
        for external in (row.get("external") or []) if isinstance(row, dict) else []:
            path, root = external.get("path"), external.get("root")
            if not path or not external.get("sha256"):
                continue
            if root == "repository":
                where = path
            elif root == "environment" and external.get("default_engine") is True:
                where = ENGINE + path
            else:
                continue  # HOME, or a root outside this repository
            found.append((where, f'node "{name}" external reader', external["sha256"], False))
    for unit, row in sorted((declaration.get("hook_readers") or {}).items()):
        if isinstance(row, dict) and isinstance(row.get("sources"), dict):
            for path, pinned in sorted(row["sources"].items()):
                found.append((ENGINE + path, f'hook reader "{unit}"', pinned, True))
    return found


def read_blob(rev, path):
    """Bytes of PATH at REV (":" is the index being committed); None when absent."""
    spec = (":" if rev is None else rev + ":") + path
    got = git("show", spec, check=False, text=False)
    return got.stdout if got.returncode == 0 else None


class Batch:
    """One `git cat-file --batch` for many blob reads (a process per file costs seconds over the
    declaration's ~900 readers)."""
    def __init__(self):
        self.proc = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def read(self, rev, path):
        spec = (":" if rev is None else rev + ":") + path
        self.proc.stdin.write(spec.encode("utf-8", errors="surrogateescape") + b"\n")
        self.proc.stdin.flush()
        header = self.proc.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            if header and header[-1] not in (b"missing", b"ambiguous"):
                raise RuntimeError("git cat-file --batch: unexpected reply " + repr(header))
            return None
        data = self.proc.stdout.read(int(header[2]))
        self.proc.stdout.read(1)
        return data

    def close(self):
        self.proc.stdin.close()
        self.proc.wait()


def branch_paths():
    """The branch's change as the land will see it: merge-base(main, HEAD) against the index
    being committed. With no main to compare to, the staged change alone."""
    base = git("merge-base", f"refs/heads/{LAND_BRANCH}", "HEAD", check=False)
    against = [base.stdout.strip()] if base.returncode == 0 and base.stdout.strip() else []
    listed = git("diff", "--cached", "--name-only", "--no-renames", *against).stdout
    return [p for p in listed.splitlines() if p], (against[0] if against else None)


def stale(declaration, rev, only=None, also=()):
    """Pins that do not match REV's bytes, for paths in ONLY (every path when None) plus the
    individual pins in ALSO (the ones this branch retyped)."""
    out, cache = [], {}
    for path, where, pinned, as_text in pins(declaration):
        if only is not None and path not in only and (path, where, pinned) not in also:
            continue
        key = (path, as_text)
        if key not in cache:
            blob = read_blob(rev, path)
            cache[key] = "(file removed)" if blob is None else digest(blob, as_text)
        if cache[key] != pinned:
            out.append((path, where, pinned, cache[key]))
    return out


def report(found, title):
    say("")
    say(f"=== {title} ===")
    for path, where, pinned, now in found:
        say(f"  {path} ({where}): pinned {pinned[:12]}, now {now[:12]}")
    paths = sorted({path for path, *_ in found})
    say("")
    say(f"  {DECLARATION} pins each of these files by SHA-256. The engine's input selector")
    say("  refuses every unit that reaches a stale pin (\"changed reader requires input")
    say("  qualification\"), so verification-inputs.test.sh fails once this reaches main.")
    say("  Fix, in this commit:")
    say("    1. Read the file's added lines for a new config key, environment variable or file")
    say("       it now reads, and declare it in that row (keys, edges, external, evidence).")
    say("    2. Renew the pin:")
    say(f"       python3 {SELF} --renew {' '.join(paths)}")
    say(f"    3. Stage {DECLARATION} with the change.")
    say("")


def reader_floor(declaration, old, base):
    """The selector's own refusals over the WHOLE staged declaration, from the selector's own code
    and with its message: `omitted known key reads` (a known config key a reader reads that its row
    does not declare) and `unqualified reader` (a node edge or a unit root with no node). Text is
    read as the verifier reads it (newlines normalized). Anything that is also found over the
    merge-base's declaration and files is not this commit's and is not refused. Dependencies.node
    stops at a reader's first problem (a stale pin is reported before this runs), so only these two
    messages are taken from it. An exception propagates: check() refuses the commit on it."""
    code = read_blob(None, INPUTS)
    if code is None:
        return []
    module = types.ModuleType("verification_inputs")
    exec(compile(code.decode("utf-8"), INPUTS, "exec"), module.__dict__)
    top = Path(git("rev-parse", "--show-toplevel").stdout.strip())

    def findings(doc, rev, only=None):
        def read(path):
            blob = batch.read(rev, ENGINE + path)
            if blob is None:
                raise FileNotFoundError(path)
            return blob.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n").replace("\r", "\n")

        nodes = doc.get("nodes") or {}
        graph = module.Dependencies(top / ENGINE.rstrip("/"), doc, read)
        found = {}
        for name in sorted(nodes):
            row = nodes[name]
            if not isinstance(row, dict) or (only is not None and name not in only):
                continue
            try:
                graph.node(name)
            except module.Unsupported as exc:
                if str(exc).startswith(OMITTED):
                    found.setdefault(str(exc), (row.get("source", name), name))
            for edge in row.get("edges") or []:
                if edge["to"] not in nodes:
                    found.setdefault(UNQUALIFIED + edge["to"], (row.get("source", name), name))
        for root in (doc.get("units") or {}).values():
            if root not in nodes:
                found.setdefault(UNQUALIFIED + str(root), (DECLARATION, None))
        return found

    batch = Batch()
    try:
        now = findings(declaration, None)
        if not now:
            return []
        # Only the rows that produced a finding are asked again at the merge-base.
        before = findings(old, base, {name for _, name in now.values() if name}) if base and old else {}
    finally:
        batch.close()
    return [(source, message) for message, (source, _) in now.items() if message not in before]


def report_floor(found):
    say("")
    say("=== COMMIT REFUSED: a changed reader is not fully declared in verification-dependencies.json ===")
    for source, message in found:
        say(f"  {source}: {message}")
    say("")
    say("  verification-inputs.test.sh refuses this once it reaches main. Fix, in this commit: declare each")
    say("  config key the file reads in its row's keys (or literal_keys, with a reason), and give every edge")
    say(f"  target a node of its own in {DECLARATION}; then renew the pin with --renew and stage it.")
    say("")


def check():
    paths, base = branch_paths()
    if not paths:
        return 0
    got = read_blob(None, DECLARATION)
    if got is None:
        return 0  # this tree has no declaration, so nothing is pinned
    text = got.decode("utf-8", errors="replace")
    retyped = DECLARATION in paths
    # The common case: nothing the branch changed is named in the declaration; no parse.
    named = [p for p in paths if (p[len(ENGINE):] if p.startswith(ENGINE) else p) in text]
    if not named and not retyped:
        return 0
    try:
        declaration = json.loads(text)
    except ValueError:
        return 0  # verification-inputs.test.sh reports a malformed file; not this check's job
    also = set()
    if retyped and base:
        # A pin this branch typed by hand is checked too, whether or not its file changed.
        before = read_blob(base, DECLARATION)
        try:
            old = {(p, w, d) for p, w, d, _ in pins(json.loads(before or b"{}"))}
        except ValueError:
            old = set()
        also = {(p, w, d) for p, w, d, _ in pins(declaration)} - old
    found = stale(declaration, None, only=set(paths), also=also)
    if found:
        report(found, "COMMIT REFUSED: a changed file is pinned in verification-dependencies.json")
        return 1
    try:
        old = json.loads(read_blob(base, DECLARATION) or b"{}") if base else {}
    except ValueError:
        old = {}
    try:
        floor = reader_floor(declaration, old, base)
    except Exception as exc:  # a check that cannot run refuses; it never passes by silence
        say("")
        say(f"=== COMMIT REFUSED: the reader check could not run ({type(exc).__name__}: {exc}) ===")
        return 1
    if floor:
        report_floor(floor)
        return 1
    return 0


def renew(targets):
    top = git("rev-parse", "--show-toplevel").stdout.strip()
    target = f"{top}/{DECLARATION}"
    with open(target, encoding="utf-8") as handle:
        declaration = json.load(handle)
    wanted, renewed = set(targets), []

    def now(path, as_text):
        try:
            with open(f"{top}/{path}", "rb") as handle:
                return digest(handle.read(), as_text)
        except OSError:
            raise SystemExit(f"dependency-pins: cannot read {path}; a removed reader is removed from "
                             f"{DECLARATION} by hand, with the units that reached it")

    for name, row in (declaration.get("nodes") or {}).items():
        if not isinstance(row, dict):
            continue
        if ENGINE + str(row.get("source", "")) in wanted:
            fresh = now(ENGINE + row["source"], True)
            if fresh != row.get("sha256"):
                row["sha256"] = fresh
                renewed.append((ENGINE + row["source"], f'node "{name}"'))
        for external in row.get("external") or []:
            root, path = external.get("root"), external.get("path", "")
            where = (path if root == "repository"
                     else ENGINE + path if root == "environment" and external.get("default_engine") is True
                     else None)
            if where in wanted:
                fresh = now(where, False)
                if fresh != external.get("sha256"):
                    external["sha256"] = fresh
                    renewed.append((where, f'node "{name}" external reader'))
    for unit, row in (declaration.get("hook_readers") or {}).items():
        if isinstance(row, dict) and isinstance(row.get("sources"), dict):
            for path in list(row["sources"]):
                if ENGINE + path in wanted:
                    fresh = now(ENGINE + path, True)
                    if fresh != row["sources"][path]:
                        row["sources"][path] = fresh
                        renewed.append((ENGINE + path, f'hook reader "{unit}"'))
    unknown = sorted(wanted - {p for p, *_ in pins(declaration)})
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(declaration, indent=2) + "\n")
    for path, where in renewed:
        print(f"renewed {path} ({where})")
    for path in unknown:
        print(f"not pinned: {path}")
    print(f"{len(renewed)} pin(s) renewed in {DECLARATION}; stage it with the change.")
    return 1 if unknown else 0


def main(argv):
    if argv[:1] == ["--renew"]:
        if len(argv) < 2:
            raise SystemExit("usage: dependency-pins.py --renew PATH [PATH ...]")
        return renew(argv[1:])
    if argv[:1] == ["--all"]:
        rev = argv[argv.index("--rev") + 1] if "--rev" in argv else None
        blob = read_blob(rev, DECLARATION)
        if blob is None:
            raise SystemExit(f"dependency-pins: no {DECLARATION} at {rev or 'the index'}")
        found = stale(json.loads(blob), rev)
        for path, where, pinned, now in found:
            print(f"{path}\t{where}\t{pinned}\t{now}")
        say(f"dependency-pins: {len(found)} stale pin(s) at {rev or 'the index'}")
        return 1 if found else 0
    if argv:
        raise SystemExit("usage: dependency-pins.py [--renew PATH ... | --all [--rev REV]]")
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
