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
import os
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path

DECLARATION = "richos/engine/scripts/lib/verification-dependencies.json"
ENGINE = "richos/engine/"
LAND_BRANCH = "main"
SELF = "richos/app/scripts/autocheck/dependency-pins.py"
INPUTS = ENGINE + "scripts/lib/verification_inputs.py"


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


EXPORTED = ("richos/engine", "richos/app/scripts", "richos/mobile")  # what the declaration's readers live in


def export_tree(tree, into):
    """The files of TREE (a commit or tree id) the verifier reads, extracted under INTO as the
    verifier sees a checkout: bytes, modes and layout from the tree, nothing from the working copy.
    That is the engine, the app scripts, the mobile tools, and every repository-rooted external
    reader the tree's own declaration names."""
    wanted = list(EXPORTED)
    shown = subprocess.run(["git", "show", f"{tree}:{DECLARATION}"], capture_output=True,
                           stdin=subprocess.DEVNULL)
    if shown.returncode == 0:
        try:
            rows = (json.loads(shown.stdout).get("nodes") or {}).values()
        except ValueError:
            rows = ()  # a malformed declaration names no external reader; check() refuses it itself
        for row in rows:
            for external in (row.get("external") or []) if isinstance(row, dict) else []:
                if external.get("root") == "repository" and external.get("path"):
                    wanted.append(external["path"])
    # The committed blobs themselves: no .gitattributes (export-ignore, substitution, eol) applies.
    listed = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", tree, "--", *wanted],
                            capture_output=True, stdin=subprocess.DEVNULL)
    if listed.returncode:
        raise RuntimeError(f"git ls-tree {tree} failed: {listed.stderr.decode(errors='replace').strip()}")
    entries = []
    for record in listed.stdout.split(b"\0"):
        if not record:
            continue
        meta, _, name = record.partition(b"\t")
        mode, kind, sha = meta.decode().split()
        if kind == "blob":
            entries.append((mode, sha, name.decode("utf-8", errors="surrogateescape")))
    if not entries:
        return
    blobs = subprocess.run(["git", "cat-file", "--batch"], capture_output=True,
                           input="".join(f"{sha}\n" for _, sha, _ in entries).encode())
    if blobs.returncode:
        raise RuntimeError(f"git cat-file for {tree} failed: {blobs.stderr.decode(errors='replace').strip()}")
    data, at = blobs.stdout, 0
    for mode, sha, name in entries:
        end = data.index(b"\n", at)
        header = data[at:end].split()
        if len(header) != 3 or header[1] != b"blob":
            raise RuntimeError(f"git cat-file gave {data[at:end]!r} for {name}")
        size = int(header[2])
        content = data[end + 1:end + 1 + size]
        at = end + 1 + size + 1
        dest = Path(into, name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if mode == "120000":
            os.symlink(content, dest)
            continue
        dest.write_bytes(content)
        dest.chmod(0o755 if mode == "100755" else 0o644)


def verifier_messages(module, root):
    """Every refusal the verifier's own Dependencies.node gives for the checkout at ROOT: each node,
    each edge target and each unit root, with its own message and its own file reads (exactly as
    verification-inputs.test.py builds it: Dependencies(<engine>, <declaration>)). None when the
    checkout has no declaration."""
    engine = Path(root) / ENGINE.rstrip("/")
    path = Path(root) / DECLARATION
    if not path.is_file():
        return None
    doc = json.loads(path.read_text())
    graph = module.Dependencies(engine, doc)
    nodes = doc.get("nodes") or {}
    names = set(nodes) | set((doc.get("units") or {}).values())
    for row in nodes.values():
        names.update(edge["to"] for edge in (row.get("edges") or []) if isinstance(row, dict))
    found = set()
    for name in sorted(names, key=str):
        try:
            graph.node(name)
        except module.Unsupported as exc:
            found.add(str(exc))
    return found


def reader_floor(base):
    """The selector's own refusals (`unqualified reader`, `omitted known key reads`, and every other
    reason Dependencies.node gives) over the WHOLE declaration as it would be committed, from the
    selector's own code run on an export of the staged tree. A message that the merge-base's export
    gives too is not this commit's and is not refused. An exception propagates: check() refuses the
    commit on it."""
    scratch = tempfile.mkdtemp(prefix="dependency-pins-")
    try:
        staged, parent = Path(scratch, "staged"), Path(scratch, "base")
        export_tree(git("write-tree").stdout.strip(), staged)
        code = Path(staged, INPUTS)
        if not code.is_file():
            raise RuntimeError(f"{INPUTS} is not in the staged tree's export, so the verifier cannot run")
        if not Path(staged, DECLARATION).is_file():
            raise RuntimeError(f"{DECLARATION} is not in the staged tree's export")
        module = types.ModuleType("verification_inputs")
        exec(compile(code.read_text(), str(code), "exec"), module.__dict__)

        def plain(message, root):
            # the export folder differs between the two trees; the refusal is the same
            for form in {str(root), str(root.resolve())}:
                message = message.replace(form, "<export>")
            return message

        now = {plain(m, staged) for m in verifier_messages(module, staged) or ()}
        if not now:
            return []
        before = set()
        if base:
            export_tree(base, parent)
            try:
                before = {plain(m, parent) for m in verifier_messages(module, parent) or ()}
            except ValueError:
                before = set()  # a merge-base declaration that does not parse has no baseline refusals
        return [(DECLARATION, message) for message in sorted(now - before)]
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


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
        if base and read_blob(base, DECLARATION) is not None:
            say("")
            say(f"=== COMMIT REFUSED: the reader check could not run ({DECLARATION} exists at the merge-base but is not in the staged tree) ===")
            return 1
        return 0  # this tree never had a declaration, so nothing is pinned
    text = got.decode("utf-8", errors="replace")
    retyped = DECLARATION in paths
    # The common case: nothing the branch changed is named in the declaration; no parse.
    named = [p for p in paths if (p[len(ENGINE):] if p.startswith(ENGINE) else p) in text]
    if not named and not retyped:
        return 0
    try:
        declaration = json.loads(text)
    except ValueError as exc:  # a check that cannot read the declaration refuses
        say("")
        say(f"=== COMMIT REFUSED: the reader check could not run ({type(exc).__name__}: {DECLARATION} does not parse: {exc}) ===")
        return 1
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
        floor = reader_floor(base)
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
