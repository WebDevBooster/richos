#!/usr/bin/env python3
"""hook-dependencies.py — the predicate behind scripts/lib/hook-dependencies.sh.

Prints one engine-relative path per line: every file under scripts/ that a
registered hook needs, transitively, and that is not itself a registered hook.

    hook-dependencies.py <engine-dir>

The whole decision — what counts as a reference, why a sentence containing a
path is not one, what the anchor is and why a broken deriver must print nothing
— is stated in hook-dependencies.sh. This file is the implementation of it, kept
separate for the reason ceo-todos.sh keeps ceo-todos.py: one predicate, callable
from shell, with no heredoc inside a command substitution (bash 3.2 on macOS
mis-parses that shape, which is how this file came to exist).

Exit codes, identical to the wrapper's contract:
  0  complete closure printed
  1  no such engine directory, or no hooks/hooks.json in it
  2  hooks/hooks.json unparseable, or registering no hook script at all
  4  ANCHOR FAILED — nothing printed
"""
import json
import os
import re
import sys

SCAFFOLD = (".test.sh", ".test.py", ".mutation.sh")

# A REFERENCE IS A QUOTED TOKEN WHOSE ENTIRE CONTENT IS A PATH. Leading shell
# expansions are stripped first: $VAR, ${VAR}, and $(cd "$(dirname
# "${BASH_SOURCE[0]}")" && pwd), which is how the two handoff hooks reach
# scripts/lib/worktree-ledger.py.
EXPANSION = (r'(?:(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'
             r'|\$\([^()]*(?:\([^()]*\)[^()]*)*\))/)+')
BODY = r'[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)*\.(?:sh|py|json|tsv|dict|md|txt)'
WHOLE_TOKEN = re.compile(r'^' + EXPANSION + r'?' + BODY + r'$')
LEADING_EXPANSION = re.compile(r'^' + EXPANSION)


def quoted_tokens(line):
    """The quoted spans of a line, at the TOP LEVEL of quoting only.

    Scanned rather than regex-matched, because a regex cannot tell a token from
    punctuation inside a sentence. `REST=" (... '$ENGINE_ROOT/scripts/x.sh'
    --session <id>.)"` contains a single-quoted path, and a regex sees a
    perfectly-formed token; a shell sees literal text inside one double-quoted
    string. Measured, not feared: that exact line in session-start-ceo-ask.sh
    and one in engine-status.sh made three advice paths look like dependencies.
    """
    out = []
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch in '"\'':
            j = i + 1
            buf = []
            while j < n:
                if ch == '"' and line[j] == '\\' and j + 1 < n:
                    buf.append(line[j + 1])
                    j += 2
                    continue
                # A command substitution inside a double-quoted span carries
                # its own quoting, and the shell does not end the span at the
                # quotes inside it. Consumed whole, parens balanced, so that
                # `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/x.py"`
                # stays ONE token -- the shape both handoff hooks use to reach
                # scripts/lib/worktree-ledger.py.
                if ch == '"' and line.startswith("$(", j):
                    depth, k = 0, j
                    while k < n:
                        if line[k] == "(":
                            depth += 1
                        elif line[k] == ")":
                            depth -= 1
                            if depth == 0:
                                k += 1
                                break
                        k += 1
                    buf.append(line[j:k])
                    j = k
                    continue
                if line[j] == ch:
                    break
                buf.append(line[j])
                j += 1
            if j < n:
                out.append("".join(buf))
                i = j + 1
                continue
            return out
        i += 1
    return out

ANCHOR = "scripts/lib/resolve-roots.sh"
# Keyed on a USE, not a mention: `resolve_engine_root` is defined in
# resolve-roots.sh and cannot be called without sourcing it, so a hook that
# merely NAMES the library in prose does not enter the expected set. That
# matters -- an anchor with a false-positive class is a check that gets
# waived, and a waived check is the failure this engine keeps finding.
ANCHOR_TEXT = "resolve_engine_root"


def is_scaffold(rel):
    return os.path.basename(rel).endswith(SCAFFOLD)


def in_scope(rel):
    """Code and data under scripts/. Configuration and record files are the
    consumer's own to synthesize — see the wrapper's SCOPE section."""
    return rel.startswith("scripts/") and not is_scaffold(rel)


def registered_hooks(eng):
    try:
        with open(os.path.join(eng, "hooks/hooks.json"), encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        raise SystemExit(2)
    found = set()
    hooks = doc.get("hooks", {})
    if isinstance(hooks, dict):
        for entries in hooks.values():
            if not isinstance(entries, list):
                continue
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                for h in entry.get("hooks", []) or []:
                    if not isinstance(h, dict):
                        continue
                    cmd = h.get("command", "")
                    if not isinstance(cmd, str):
                        continue
                    for m in re.findall(
                            r"scripts/hooks/([A-Za-z0-9._+-]+\.(?:sh|py))", cmd):
                        found.add(m)
    if not found:
        raise SystemExit(2)
    return found


def build_basename_index(eng):
    """One index, so a `.sh` half reaches its `.py` half without guessing."""
    index = {}
    for dirpath, dirnames, filenames in os.walk(eng):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "__pycache__", "node_modules")]
        for fn in filenames:
            index.setdefault(fn, []).append(
                os.path.relpath(os.path.join(dirpath, fn), eng))
    return index


def resolve(eng, index, tok, owner_rel):
    owner_dir = os.path.dirname(os.path.join(eng, owner_rel))
    expanded = bool(LEADING_EXPANSION.match(tok))
    body = LEADING_EXPANSION.sub("", tok)
    cands = []
    if body.startswith(("../", "./")):
        cands.append(os.path.join(owner_dir, body))
    elif body.startswith(("scripts/", "hooks/")):
        cands.append(os.path.join(eng, body))
        if expanded:
            cands.append(os.path.join(owner_dir, body))
    elif expanded:
        cands.append(os.path.join(owner_dir, body))
        hits = index.get(body, [])
        if len(hits) == 1:
            cands.append(os.path.join(eng, hits[0]))
    for cand in cands:
        cand = os.path.normpath(cand)
        try:
            if os.path.commonpath([cand, eng]) != eng:
                continue
        except ValueError:
            continue
        if os.path.isfile(cand):
            return os.path.relpath(cand, eng)
    # A token that resolves to no file is DROPPED. A hook cannot depend on a
    # file that is not there, and demanding one would be inventing a fact.
    return None


def references(eng, index, rel):
    path = os.path.join(eng, rel)
    if not os.path.isfile(path):
        return set()
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except Exception:
        return set()
    if b"\0" in raw[:4096]:
        return set()
    found = set()
    for line in raw.decode("utf-8", "replace").splitlines():
        if line.lstrip().startswith("#"):
            continue
        for tok in quoted_tokens(line):
            if not WHOLE_TOKEN.match(tok):
                continue
            got = resolve(eng, index, tok, rel)
            if got and not is_scaffold(got):
                found.add(got)
    return found


def check_anchor(eng, seeds, direct):
    """Every hook carrying the shared root bootstrap must come out of the
    derivation depending on it. The expected set is taken by a PLAIN TEXT SCAN —
    a weaker, differently shaped predicate that the extraction rules cannot
    break in the same direction."""
    expected, derived = set(), set()
    for seed in sorted(seeds):
        path = os.path.join(eng, seed)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception:
            continue
        if ANCHOR_TEXT in text:
            expected.add(seed)
        if ANCHOR in direct.get(seed, set()):
            derived.add(seed)
    if not expected:
        sys.stderr.write(
            "hook-dependencies.py: ANCHOR FAILED — no registered hook calls "
            "%s(). Either this is not a richos engine, or the registration "
            "surface was just rewritten wholesale; neither is something to "
            "answer with a list.\n" % ANCHOR_TEXT)
        raise SystemExit(4)
    missed = sorted(expected - derived)
    if missed:
        sys.stderr.write(
            "hook-dependencies.py: ANCHOR FAILED — %d of %d hooks call %s() and "
            "the derivation did not resolve scripts/lib/resolve-roots.sh for: %s\n"
            "  The extraction rules have stopped matching a reference shape "
            "this engine uses. A shorter closure is indistinguishable from a "
            "correct one, so nothing is printed.\n"
            % (len(missed), len(expected), ANCHOR_TEXT,
               ", ".join(os.path.basename(m) for m in missed)))
        raise SystemExit(4)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: hook-dependencies.py <engine-dir>\n")
        return 1
    eng = os.path.abspath(argv[1])
    if not os.path.isdir(eng) or not os.path.isfile(
            os.path.join(eng, "hooks/hooks.json")):
        return 1

    reg = registered_hooks(eng)
    index = build_basename_index(eng)
    seeds = set("scripts/hooks/" + b for b in reg)

    direct = {}
    seen = set(seeds)
    work = list(seeds)
    while work:
        cur = work.pop()
        refs = references(eng, index, cur)
        direct[cur] = refs
        for ref in refs:
            if ref not in seen:
                seen.add(ref)
                work.append(ref)

    check_anchor(eng, seeds, direct)

    for rel in sorted(x for x in seen - seeds if in_scope(x)):
        print(rel)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
