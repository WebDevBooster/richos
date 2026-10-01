#!/usr/bin/env python3
"""mutation-anchors.py — every mutant's target text still exists in the source it mutates.

WHY (2026-10-01). Nightly attempt 6 (run log 20261001T022754Z-f673d370) failed its
`gates/workspace-mutants` gate on `S-p02-agent-writes-inside-codex-pass-the-lock-out`:
"MUTATION TARGET ABSENT — the source has drifted". A change to mega-lander/workspaces.py had
renamed the line that mutant edits, every check of the merge passed (the merge runs no mutation
pass: autocheck/README.md), and the first thing that read the anchor was the nightly, hours later,
after a 1762 s gate. Nothing has to RUN a suite to know that: whether a mutant's text is in its
file is a string search. So this reads every harness's declared mutants and searches, in seconds,
and the merge gate runs it (autocheck.py) for any land that changes the engine.

WHAT IT READS. A harness declares a mutant as one shell statement,

    mutant <name> <want> <file relative to the engine root> <old> <new> <why>

either through scripts/lib/mutation-harness.sh or through its own copy of that loop. The words are
parsed as bash parses them (single and double quotes, `$'...'`, backslash escapes and line
continuations, and `$NAME` from the harness's own plain assignments such as W="..."), and <old> is
applied with the harness's OWN mutate.py (the heredoc it writes into its sandbox, or the shared
library's), run here against a throwaway copy of the target file. So `{NL}`, `\\n`, `{AND}`, or
whatever a harness's dialect is, means exactly what it means in the nightly. A mutate.py exit of 3
is the nightly's "MUTATION TARGET ABSENT"; it refuses here.

WHAT IT CANNOT READ, and says so. A statement whose words need a command substitution, an unset
variable or a heredoc, a harness whose mutate step is not `mutate.py "$dir/$rel" "$old" "$new"`,
and a harness that declares no `mutant` statements at all (its own loop over its own table) are
each named on a NOT CHECKED line with the reason. NOT CHECKED is never counted as present and
never refuses: the nightly still runs every harness.

Usage:
    mutation-anchors.py [--root ENGINE_ROOT] [--quiet]
Exit: 0 every readable anchor is present; 1 at least one is absent (or its file is gone, or its
mutant is malformed); 2 no harness was found (an empty inventory is never a pass).
"""
import argparse
import io
import os
import re
import shutil
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout

HARNESS_LIB = "scripts/lib/mutation-harness.sh"
MUTATE_BLOCK = re.compile(
    r"""cat\s*>\s*"\$\{?[A-Z_]*SANDBOX[A-Z_]*\}?/mutate\.py"\s*<<-?\s*'?(\w+)'?[ \t]*\n(.*?)\n\1[ \t]*\n""", re.S)
MUTATE_CALL = re.compile(r'mutate\.py"\s+"\$dir/\$rel"\s+"\$old"\s+"\$new"')
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(?=\S|$)")
MUTANT_LINE = re.compile(r"^([ \t]*)mutant[ \t]")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


class Unreadable(Exception):
    """A statement whose words this reader will not guess at."""


def words(text, pos, env):
    """Parse one shell simple command starting at text[pos]. Returns (words, end, heredoc).
    Stops at an unquoted newline, `;`, `&`, `|` or `#` comment. Raises Unreadable for what a
    static reader cannot know (command substitution, unset variables)."""
    out, cur, have = [], [], False
    i, n = pos, len(text)
    heredoc = False

    def expand(j, quoted):
        # text[j] == "$"
        if j + 1 < n and text[j + 1] == "(":
            raise Unreadable("a command substitution")
        if j + 1 < n and text[j + 1] == "{":
            k = text.find("}", j + 2)
            if k < 0:
                raise Unreadable("an unterminated ${...}")
            name = text[j + 2:k]
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise Unreadable("a parameter expansion ${%s}" % name)
            end = k + 1
        else:
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[j + 1:])
            if not m:
                return "$", j + 1
            name = m.group(0)
            end = j + 1 + len(name)
        if name not in env:
            raise Unreadable("the variable $%s, which no plain assignment in the harness sets" % name)
        return env[name], end

    while i < n:
        c = text[i]
        if c in " \t":
            if have:
                out.append("".join(cur))
                cur, have = [], False
            i += 1
        elif c == "\\":
            if i + 1 < n and text[i + 1] == "\n":
                i += 2                      # a line continuation
            else:
                cur.append(text[i + 1] if i + 1 < n else "")
                have = True
                i += 2
        elif c == "'":
            k = text.find("'", i + 1)
            if k < 0:
                raise Unreadable("an unterminated single quote")
            cur.append(text[i + 1:k])
            have = True
            i = k + 1
        elif c == "$" and i + 1 < n and text[i + 1] == "'":
            i += 2
            buf = []
            while i < n and text[i] != "'":
                if text[i] == "\\" and i + 1 < n:
                    e = text[i + 1]
                    buf.append({"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"', "r": "\r"}.get(e, "\\" + e))
                    i += 2
                else:
                    buf.append(text[i])
                    i += 1
            if i >= n:
                raise Unreadable("an unterminated $'...'")
            cur.append("".join(buf))
            have = True
            i += 1
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                d = text[i]
                if d == "\\" and i + 1 < n and text[i + 1] in '"\\$`\n':
                    if text[i + 1] != "\n":
                        cur.append(text[i + 1])
                    i += 2
                elif d == "$":
                    val, i = expand(i, True)
                    cur.append(val)
                elif d == "`":
                    raise Unreadable("a backquoted command substitution")
                else:
                    cur.append(d)
                    i += 1
            if i >= n:
                raise Unreadable("an unterminated double quote")
            have = True
            i += 1
        elif c == "$":
            val, i = expand(i, False)
            cur.append(val)
            have = True
        elif c == "`":
            raise Unreadable("a backquoted command substitution")
        elif c == "#" and not have:
            k = text.find("\n", i)
            i = n if k < 0 else k
        elif c in "\n;&|":
            break
        elif c == "<" and text.startswith("<<", i):
            heredoc = True
            break
        else:
            cur.append(c)
            have = True
            i += 1
    if have:
        out.append("".join(cur))
    return out, i, heredoc


def code_lines(text):
    """The line numbers that begin as shell code: not inside a quoted string, a command
    substitution or a heredoc body. A `mutant` word at the start of a line inside a long
    double-quoted reason is prose, not a declaration."""
    code = {1}
    stack = ["N"]          # N code, C $(...), P (...) inside it, S '...', A $'...', D "...", B `...`
    heredocs = []          # terminators whose bodies start at the next newline
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        top = stack[-1]
        if c == "\n":
            line += 1
            i += 1
            if top == "N" and heredocs:
                for word in heredocs:
                    while i < n:
                        k = text.find("\n", i)
                        body = text[i:] if k < 0 else text[i:k]
                        line += 1
                        i = n if k < 0 else k + 1
                        if body.strip() == word:
                            break
                heredocs = []
            if stack == ["N"]:
                code.add(line)
            continue
        if top in "NCP":
            if c == "\\":
                line += text.startswith("\\\n", i)    # an escaped newline still ends a line
                i += 2
                continue
            if c == "#" and (i == 0 or text[i - 1] in " \t\n;|&("):
                k = text.find("\n", i)
                i = n if k < 0 else k
                continue
            if c == "'":
                stack.append("S")
            elif c == "$" and text.startswith("$'", i):
                stack.append("A")
                i += 1
            elif c == '"':
                stack.append("D")
            elif c == "`":
                stack.append("B")
            elif c == "$" and text.startswith("$(", i):
                stack.append("C")
                i += 1
            elif c == "(" and top in "CP":
                stack.append("P")
            elif c == ")" and top in "CP":
                stack.pop()
            elif c == "<" and text.startswith("<<", i) and not text.startswith("<<<", i):
                h = HEREDOC.match(text, i)
                if h:
                    heredocs.append(h.group(2))
                    i = h.end()
                    continue
        elif top == "S":
            if c == "'":
                stack.pop()
        elif top == "A":
            if c == "\\":
                line += text.startswith("\\\n", i)    # an escaped newline still ends a line
                i += 2
                continue
            if c == "'":
                stack.pop()
        elif top == "D":
            if c == "\\":
                line += text.startswith("\\\n", i)    # an escaped newline still ends a line
                i += 2
                continue
            if c == '"':
                stack.pop()
            elif c == "$" and text.startswith("$(", i):
                stack.append("C")
                i += 1
            elif c == "`":
                stack.append("B")
        elif top == "B":
            if c == "\\":
                line += text.startswith("\\\n", i)    # an escaped newline still ends a line
                i += 2
                continue
            if c == "`":
                stack.pop()
        i += 1
    return code


def statements(text):
    """(kind, line number, indent, offset) of every `mutant` statement and every plain
    top-level assignment, in file order, on lines that begin as code."""
    code = code_lines(text)
    found = []
    offset = 0
    for number, line in enumerate(text.split("\n"), 1):
        start = offset
        offset += len(line) + 1
        if number not in code:
            continue
        m = MUTANT_LINE.match(line)
        if m:
            found.append(("mutant", number, len(m.group(1)), start + len(m.group(1))))
        elif ASSIGNMENT.match(line):
            found.append(("assign", number, 0, start))
    return found


def mutate_program(harness_text, lib_text):
    """The harness's own mutate.py, or the shared library's when it uses the library's loop."""
    own = MUTATE_BLOCK.search(harness_text)
    if own:
        return own.group(2), bool(MUTATE_CALL.search(harness_text))
    if "mutation-harness.sh" in harness_text and lib_text:
        lib = MUTATE_BLOCK.search(lib_text)
        if lib:
            return lib.group(2), bool(MUTATE_CALL.search(lib_text))
    return None, False


def run_mutate(code, path, old, new):
    """Run a harness's mutate.py on a throwaway copy of `path`: (exit code, stderr)."""
    tmp = tempfile.mkdtemp(prefix="mutation-anchors.")
    try:
        target = os.path.join(tmp, "target")
        shutil.copyfile(path, target)
        saved = sys.argv
        err, sink = io.StringIO(), io.StringIO()
        sys.argv = ["mutate.py", target, old, new]
        rc = 0
        try:
            with redirect_stderr(err), redirect_stdout(sink):
                exec(compile(code, "mutate.py", "exec"), {"__name__": "__main__"})
        except SystemExit as stop:
            rc = stop.code if isinstance(stop.code, int) else (0 if stop.code is None else 1)
        except Exception as exc:  # a mutate.py that crashed is not a present anchor
            rc, _ = 1, err.write("%s: %s\n" % (type(exc).__name__, exc))
        finally:
            sys.argv = saved
        return rc, err.getvalue()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_harness(root, rel_harness, lib_text):
    """(present, problems, not_checked) for one harness."""
    with open(os.path.join(root, rel_harness), encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    stmts = statements(text)
    mutants = [s for s in stmts if s[0] == "mutant"]
    if not mutants:
        return 0, [], ["declares no `mutant` statement (its mutants live in its own loop or table)"]
    code, call_ok = mutate_program(text, lib_text)
    if code is None:
        return 0, [], ["has no mutate.py of its own and does not use %s" % HARNESS_LIB]
    if not call_ok:
        return 0, [], ["its mutate step is not mutate.py \"$dir/$rel\" \"$old\" \"$new\""]
    env = {}
    present, problems, skipped = 0, [], []
    for kind, number, indent, start in stmts:
        try:
            ws, _end, heredoc = words(text, start, env)
        except Unreadable as why:
            if kind == "mutant":
                skipped.append("line %d: its words need %s" % (number, why))
            continue
        if kind == "assign":
            if len(ws) == 1:
                name, _, value = ws[0].partition("=")
                env[name] = value
            continue
        if heredoc:
            skipped.append("line %d: takes its patch from a heredoc" % number)
            continue
        args = ws[1:]
        if len(args) != 6:
            problems.append(("line %d" % number, "MALFORMED",
                             "%d words after `mutant`, not 6 (name want file old new why)" % len(args)))
            continue
        name, _want, rel, old, new, _why = args
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            problems.append((name, "FILE ABSENT", "%s does not exist" % rel))
            continue
        rc, err = run_mutate(code, path, old, new)
        if rc == 0:
            present += 1
        elif rc == 3 and "ABSENT" in err:
            first = old.replace("{NL}", "\n").split("{AND}")[0].strip().splitlines()
            problems.append((name, "TARGET ABSENT", "%s no longer contains: %s" % (
                rel, (first[0] if first else old)[:160])))
        else:
            problems.append((name, "DID NOT APPLY", "%s: mutate.py exit %s: %s" % (
                rel, rc, " ".join(err.split())[:200])))
    return present, problems, skipped


def harnesses(root):
    found = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in (".git", "node_modules", "target", "__pycache__"))
        for f in sorted(files):
            if f.endswith(".mutation.sh"):
                found.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(found)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="the engine root (default: this script's)")
    ap.add_argument("--quiet", action="store_true", help="print only problems and the verdict")
    args = ap.parse_args(argv)
    sys.dont_write_bytecode = True
    started = time.monotonic()
    root = os.path.abspath(args.root)
    found = harnesses(root)
    if not found:
        print("mutation-anchors: found NO *.mutation.sh under %s; an empty inventory is not a pass" % root)
        return 2
    lib_path = os.path.join(root, HARNESS_LIB)
    lib_text = open(lib_path, encoding="utf-8").read() if os.path.isfile(lib_path) else ""
    total_present, total_bad, total_skipped, unread = 0, 0, 0, 0
    for rel in found:
        present, problems, skipped = check_harness(root, rel, lib_text)
        total_present += present
        total_bad += len(problems)
        for name, what, detail in problems:
            print("  FAIL  %s: %s — %s: %s" % (rel, name, what, detail))
        if skipped and not present and not problems and len(skipped) == 1 and not skipped[0].startswith("line "):
            unread += 1
            print("  NOT CHECKED  %s: %s" % (rel, skipped[0]))
        else:
            total_skipped += len(skipped)
            for why in skipped:
                print("  NOT CHECKED  %s: mutant at %s" % (rel, why))
            if not args.quiet and not problems:
                print("  ok    %s: %d anchor(s) present" % (rel, present))
    seconds = time.monotonic() - started
    print("mutation-anchors: %d harness(es), %d anchor(s) present, %d absent or malformed, "
          "%d mutant(s) and %d harness(es) not statically readable (named above; the nightly runs them) "
          "in %.1fs" % (len(found), total_present, total_bad, total_skipped, unread, seconds))
    if total_bad:
        print("mutation-anchors: REFUSED. A mutant above edits text its file no longer has, so the nightly's "
              "mutation pass would fail on it with MUTATION TARGET ABSENT. Re-aim the mutant at the "
              "property's current line (same property, new text) in the same change.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
