#!/usr/bin/env python3
"""hardware-choice-check.py — refuse a hardware-dependent choice that neither asks the machine
nor says why it does not have to.

===========================================================================================
WHAT THIS IS FOR
===========================================================================================
The CEO, 2026-09-10:

    "WHEN WILL THE CUSTOMER'S HARDWARE CHOICES STOP -- PERMANENTLY STOP -- BEING HARDCODED
     INTO THE APP???"

The instance he found was fixed the same day (`c1df6f24`). The word that governs this file is
PERMANENTLY: fixing a list changes nothing about next month. So the rule is the one this project
already uses for contrast and for dialect --

    a hardware-dependent choice must either be RESOLVED AT RUN TIME, or carry a DECLARATION,
    AT THE SITE, saying why a fixed value is correct.

and, as with those, **a bare marker exempts nothing**. The reason is where a reviewer meets it.

    hardware-fixed: <why a fixed value is right here>

on the flagged line, or anywhere in the contiguous comment block directly above it (so a Rust
`///` or a JSDoc block carries it, at whatever length the reason actually needs -- see
MAX_COMMENT_BLOCK for why that is not a fixed line budget).
A declaration whose reason is shorter than MIN_REASON_CHARS is reported as a
DEFECT IN ITS OWN RIGHT rather than accepted -- an exemption that says nothing is a failure
wearing a justification.

===========================================================================================
WHAT IT IS *NOT* FOR, AND THIS MATTERS MORE THAN WHAT IT IS FOR
===========================================================================================
It does not ask you to make the value depend on the machine. Two of the four shapes exist
precisely to catch the OPPOSITE error, because the measurements say the naive fix is worse than
the defect:

  - `-p 4` (whisper --processors, one per core) is 35.5 % SLOWER and holds 52.9 % more memory
    than `-p 1`, because the decode is carried by one Metal device.
  - `-t 10` (the machine's own logical core count, exactly what `available_parallelism()` returns)
    is 67.5 % SLOWER than the shipped `-t 4`.

Both measured on 2026-09-10; derivations in
`docs/measurements/hardware-choice-audit-2026-09-10/`. So WORKER_COUNT flags a count arriving as
a literal, and the right response is frequently a DECLARATION rather than a resolver.

The check asks for a DECISION, made once, written down. Not for more machine-reading.

===========================================================================================
THE FOUR SHAPES, AND WHY EACH IS DRAWN THIS TIGHTLY
===========================================================================================
Every boundary below was moved by the corpus, not argued into place. The measurement, the
per-shape false-positive rate and the reason this ships REPORTING rather than BLOCKING are in
`docs/verification/hardware-choice-check-2026-09-10.md`.

  TOOL_FLAG    A parallelism flag handed to a subprocess with a LITERAL INTEGER value:
               `-t`/`-p`/`--threads`/`--processors`/`-j`/`--jobs` immediately followed by an
               integer literal.
               THE INTEGER IS LOAD-BEARING. `ffmpeg -t` is a DURATION, and
               `tools/richos-service/lib/normalize.js` passes it as `'0.1'`, as
               `dur.toFixed(3)` and as `Math.max(...)`. Requiring a bare integer removes all
               of those without a tool-name heuristic that would rot.

  WORKER_COUNT An identifier whose NAME is about parallelism -- threads, processors, workers,
               concurrency, parallelism, jobs, pool_size -- taking a literal integer as its
               value or as its `||`/`unwrap_or` fallback.
               This is the shape that catches a count arriving as a default rather than as an
               argv literal, which is where `config.js` keeps its 4.

  ABS_BUDGET   A constant whose NAME is about memory or disk -- *_BYTES, *_MEMORY, *_RAM,
               *_DISK, *_SPACE -- assigned a literal >= MIN_BUDGET_BYTES (64 MiB).
               THE THRESHOLD IS LOAD-BEARING and it was raised by the corpus: below it sit
               frame caps, payload caps and buffer sizes (`PAYLOAD_MAX_BYTES = 32 * 1024`,
               `MAX_FRAME_BYTES = 128 * 1024`) which are protocol limits, not shares of a disk.
               64 MiB is the point above which a number is plausibly a fraction of a machine.

  WINDOW_SIZE  A `"width"`/`"height"` integer >= MIN_WINDOW_PX in a Tauri window config.
               A window is sized against a display, and `app/src-tauri/src/` contains zero calls
               that ask the machine anything.

===========================================================================================
WHAT IS DELIBERATELY OUT OF SCOPE
===========================================================================================
  - tests, examples, benchmarks, fixtures and `#[cfg(test)]` blocks. A test that builds a
    forced 4 GB machine as a struct literal is the POINT of `hardware.rs`, not a violation of
    it, and gating it would make the fix harder to test than to skip.
  - `docs/`, `.md`, and anything under `node_modules/` or `target/`.
  - a choice that is neither a named constant nor an argv literal -- inline, or expressed as
    control flow. Named as a gap in the audit document rather than pretended away.

===========================================================================================
USAGE
===========================================================================================
    hardware-choice-check.py [--root DIR] [--explain] [--json] [--strict]

    (default)   report findings, exit 0 -- the shipping mode, see the verification record
    --strict    exit 1 on any FIRM finding; the mode a future gate would use
    --explain   print the matched line for each finding
    --json      machine-readable, for the test suite

Exit codes:  0 clean, or findings in reporting mode
             1 findings, under --strict
             2 bad usage or unreadable root
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# --- the tunables, named once, quoted by the verification record ---------------------------

#: A declaration must actually say something. A bare `hardware-fixed:` is 0 and fails.
MIN_REASON_CHARS = 20

#: Above this, a byte count is plausibly a share of a machine rather than a protocol limit.
#: Raised from 1 MiB to 64 MiB by the corpus -- see the module header.
MIN_BUDGET_BYTES = 64 * 1024 * 1024

#: Below this a "width" is a rail, an inspector pane or an icon, not a window.
MIN_WINDOW_PX = 640

DECLARATION = re.compile(r"hardware-fixed:\s*(.*)$")

#: A declaration may sit on the flagged line, or anywhere in the CONTIGUOUS COMMENT BLOCK
#: directly above it -- `///`, `//`, `*`, `#`. Not a fixed line count.
#:
#: IT WAS A FIXED COUNT OF 3, AND THE FIRST REAL DECLARATION WRITTEN AGAINST THIS CHECK DID NOT
#: FIT IT. A doc comment that explains why a value is fixed is worth more than three lines, so a
#: line budget silently pushes the author toward a thinner reason -- the exact opposite of what
#: "a bare marker exempts nothing" is for. The comment block is the right unit because it is the
#: unit a reviewer reads. `MAX_COMMENT_BLOCK` only stops a runaway scan up a whole file header.
MAX_COMMENT_BLOCK = 40
COMMENT_LINE = re.compile(r"^\s*(///|//!|//|/\*|\*|#)")

#: How many NON-comment lines may sit between the flagged line and the comment block that
#: declares it.
#:
#: THIS IS NOT SLACK, IT IS THE SHAPE OF A DOC COMMENT. A Rust `///` block attaches to the
#: ITEM, so the flagged value is inside a body and the signature sits between them:
#:
#:     /// hardware-fixed: <reason>          <- the declaration
#:     pub fn decode_args() -> Vec<String> { <- one non-comment line
#:         vec!["-t".into(), "4".into()]     <- the flagged line
#:
#: The check's own test suite caught this: H5 and H6 both failed on the first run because the
#: scan stopped at the function signature, which would have made the documented way of writing
#: a declaration the one way that does not work. Three lines reaches a signature, an attribute
#: and an opening brace, and stops well short of the previous item -- H6 proves the second half
#: by asserting a declaration does NOT reach a sibling function further down.
MAX_CODE_GAP = 3

# --- shapes ---------------------------------------------------------------------------------

# `"-t", "4"` / `'-t', '4'` / `"-t".into(), "4".into()` / `'-t', 4`
#
# MATCHED OVER THE WHOLE FILE, NOT LINE BY LINE, and that is not a stylistic choice: the first
# draft of this check was line-scoped and MISSED `stt.rs`, the very defect the audit is about,
# because rustfmt puts the flag and its value on separate lines --
#
#     "-t".into(),
#     "4".into(),
#
# A false negative on the headline finding, caught by running the check against the real corpus
# rather than against the cases it was written from. `[\s,]*` spans the newline; a comment
# between the two is excluded by `_comment_spans` below, so `"-t", /* 4 */ "8"` cannot be read
# as `-t 4`.
TOOL_FLAG = re.compile(
    r"""["'](?P<flag>-t|-p|-j|--threads|--processors|--jobs|-threads)["']      # the flag, quoted
        (?:\.into\(\))?                                                        # Rust `.into()`
        [\s,]*                                                                 # may cross a newline
        (?:["'])?(?P<value>\d+)(?:["'])?                                       # a LITERAL INTEGER
        (?:\.into\(\))?
        (?!\s*\.)                                                              # not `4.5`, not `.toFixed`
    """,
    re.VERBOSE,
)

_WORKER_WORD = (
    r"(?:n_)?(?:threads?|processors?|workers?|concurrency|parallelism|jobs?"
    r"|pool_size|poolSize|maxWorkers|max_workers)"
)
# `const threads = ... || 4;`  `let n_threads: usize = 8;`  `threads: 4,`
#
# `(?<!::)` IS THE WHOLE DIFFERENCE BETWEEN THIS SHAPE AND NOISE. Without it the corpus
# returned six findings of which five were `std::thread::sleep(Duration::from_millis(200))` --
# the MODULE `thread`, followed by a number that is a delay in milliseconds and has nothing to
# do with any machine. 83.3 % false, from one missing lookbehind. It is measured in the
# verification record rather than described, because "I tightened the regex" is not a result.
#
# The `sleep`/`Duration` exclusion is belt and braces on the same class: a line that is plainly
# about time is not about parallelism.
WORKER_COUNT = re.compile(
    rf"""(?<!::)\b(?P<name>{_WORKER_WORD})\b
         \s*(?::\s*[A-Za-z0-9_<>:\ ]+)?\s*      # an optional type annotation
         (?:=|:)\s*
         (?P<expr>[^;\n]*?)
         (?P<value>\b\d+\b)\s*[;,)\n]
    """,
    re.VERBOSE | re.IGNORECASE,
)

#: A line that is plainly about elapsed time is not about parallelism, whatever it is named.
TIME_CONTEXT = re.compile(r"\bsleep\s*\(|\bDuration\b|from_millis|from_secs|recv_timeout|setTimeout")

_BUDGET_WORD = r"[A-Za-z0-9_]*(?:BYTES|MEMORY|RAM|DISK|SPACE)"
ABS_BUDGET = re.compile(
    rf"""\b(?P<name>{_BUDGET_WORD})\b
         \s*(?::\s*[A-Za-z0-9_]+)?\s*=\s*
         (?P<expr>[0-9_]+(?:\s*\*\s*[0-9_]+)*)
         \s*[;,\n]
    """,
    re.VERBOSE,
)

WINDOW_SIZE = re.compile(r'"(?P<name>width|height)"\s*:\s*(?P<value>\d+)')

# --- what is scanned ------------------------------------------------------------------------

SCAN = [
    ("app/crates", (".rs",)),
    ("app/src-tauri/src", (".rs",)),
    ("app/ui", (".js",)),
    ("tools/richos-service/lib", (".js",)),
    ("tools/richos-service/bin", (".js",)),
]
SCAN_FILES = ["app/src-tauri/tauri.conf.json"]

SKIP_DIR = re.compile(
    r"(^|/)(node_modules|target|\.git|tests?|examples?|benches|fixtures|__pycache__)(/|$)"
)
SKIP_FILE = re.compile(r"(\.test\.js|\.spec\.js|_test\.rs|_tests\.rs|\.corpus\.md)$")


def _cfg_test_lines(text: str) -> set:
    """1-based line numbers inside a Rust `#[cfg(test)]` module.

    Brace-counted rather than regexed. A test module that builds a forced 4 GB machine as a
    struct literal is `hardware.rs`'s whole testing strategy; flagging it would make the fix
    harder to test than to skip, which is how a gate teaches people to route around it.
    """
    lines = text.splitlines()
    out = set()
    i = 0
    while i < len(lines):
        if re.match(r"\s*#\[cfg\(test\)\]", lines[i]):
            depth, j, opened = 0, i, False
            while j < len(lines):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    opened = True
                out.add(j + 1)
                if opened and depth <= 0:
                    break
                j += 1
            i = j
        i += 1
    return out


def _comment_spans(text: str):
    """(start, end) character spans of `//` line comments and `/* */` blocks.

    TOOL_FLAG spans newlines, so without this a flag quoted in a doc comment above real argv
    could pair with the first integer it finds in the code below it. Deliberately crude — it
    does not understand a `//` inside a string literal — because the cost of being crude here
    is a missed finding, never a false one, and this check's whole standing rests on not crying
    wolf.
    """
    spans = []
    for m in re.finditer(r"//[^\n]*|/\*.*?\*/", text, re.DOTALL):
        spans.append((m.start(), m.end()))
    return spans


def _declared(lines, lineno):
    """Is this finding declared, and is the declaration worth anything?

    Returns (accepted, bare_reason) -- `bare_reason` is set when a marker was found but its
    reason is too thin to count, which is reported as its own finding rather than silently
    ignored.
    """
    bare = None
    gap = 0          # non-comment lines crossed so far
    in_block = False # true once the comment block above has been entered
    for back in range(0, MAX_COMMENT_BLOCK + 1):
        idx = lineno - 1 - back
        if idx < 0:
            break
        is_comment = COMMENT_LINE.match(lines[idx]) is not None
        if back > 0:
            if is_comment:
                in_block = True
            elif in_block:
                break            # the block ended; anything above belongs to something else
            else:
                gap += 1
                if gap > MAX_CODE_GAP:
                    break        # too far to be this site's declaration
                continue
        m = DECLARATION.search(lines[idx])
        if m:
            reason = m.group(1).strip().strip("*/#-").strip()
            if len(reason) >= MIN_REASON_CHARS:
                return True, None
            bare = reason
    return False, bare


def _budget_value(expr: str) -> int:
    try:
        parts = [int(p.replace("_", "")) for p in re.split(r"\*", expr)]
    except ValueError:
        return 0
    v = 1
    for p in parts:
        v *= p
    return v


def scan_file(path: str, rel: str):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return []
    lines = text.splitlines()
    skip = _cfg_test_lines(text) if path.endswith(".rs") else set()
    found = []

    def add(shape, lineno, what, firm=True):
        if lineno in skip:
            return
        line = lines[lineno - 1] if lineno - 1 < len(lines) else ""
        if re.match(r"\s*(//|#|\*|///)", line) and "hardware-fixed:" not in line:
            return  # a mention in prose is not a choice
        accepted, bare = _declared(lines, lineno)
        if accepted:
            return
        found.append(
            {
                "shape": shape,
                "file": rel,
                "line": lineno,
                "what": what,
                "text": line.strip(),
                "firm": firm,
                "bare_declaration": bare,
            }
        )

    if path.endswith((".rs", ".js")):
        # TOOL_FLAG spans lines, so it is matched against the whole file and the offset is
        # mapped back to a line. See the pattern's own note for the false negative that forced
        # this.
        comments = _comment_spans(text)
        for m in TOOL_FLAG.finditer(text):
            if any(s <= m.start() < e or s < m.end() <= e for s, e in comments):
                continue
            add(
                "TOOL_FLAG",
                text.count("\n", 0, m.start()) + 1,
                f"{m.group('flag')} {m.group('value')}",
            )
        for n, line in enumerate(lines, 1):
            if not TIME_CONTEXT.search(line):
                for m in WORKER_COUNT.finditer(line):
                    add("WORKER_COUNT", n, f"{m.group('name')} = {m.group('value')}")
            for m in ABS_BUDGET.finditer(line):
                v = _budget_value(m.group("expr"))
                if v >= MIN_BUDGET_BYTES:
                    add("ABS_BUDGET", n, f"{m.group('name')} = {v} B")
    if path.endswith("tauri.conf.json"):
        for n, line in enumerate(lines, 1):
            for m in WINDOW_SIZE.finditer(line):
                if int(m.group("value")) >= MIN_WINDOW_PX:
                    add("WINDOW_SIZE", n, f"{m.group('name')} = {m.group('value')}")
    return found


def walk(root: str):
    out = []
    for base, exts in SCAN:
        top = os.path.join(root, base)
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [
                d for d in dirnames if not SKIP_DIR.search(os.path.join(dirpath, d))
            ]
            if SKIP_DIR.search(dirpath):
                continue
            for fn in sorted(filenames):
                if not fn.endswith(exts) or SKIP_FILE.search(fn):
                    continue
                p = os.path.join(dirpath, fn)
                out += scan_file(p, os.path.relpath(p, root))
    for rel in SCAN_FILES:
        p = os.path.join(root, rel)
        if os.path.exists(p):
            out += scan_file(p, rel)
    return sorted(out, key=lambda f: (f["file"], f["line"], f["shape"]))


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=os.environ.get("RICHOS_ROOT", "."))
    ap.add_argument("--explain", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()

    root = os.path.abspath(a.root)
    if not os.path.isdir(root):
        print(f"hardware-choice-check: not a directory: {root}", file=sys.stderr)
        return 2

    findings = walk(root)
    if a.json:
        print(json.dumps(findings, indent=2))
        return 1 if (a.strict and any(f["firm"] for f in findings)) else 0

    firm = [f for f in findings if f["firm"]]
    maybe = [f for f in findings if not f["firm"]]

    print("=== hardware-choice check ===")
    print(f"root: {root}\n")
    if not findings:
        print("Every hardware-dependent choice in scope is resolved at run time or declared.")
        return 0

    for label, group in (("FIRM", firm), ("MAYBE", maybe)):
        if not group:
            continue
        print(f"--- {label} ({len(group)}) ---")
        for f in group:
            print(f"  {f['file']}:{f['line']}  [{f['shape']}]  {f['what']}")
            if f["bare_declaration"] is not None:
                print(
                    f"      A `hardware-fixed:` marker is present but its reason is "
                    f"{len(f['bare_declaration'])} characters ({MIN_REASON_CHARS} required). "
                    f"A bare marker exempts nothing."
                )
            if a.explain:
                print(f"      {f['text']}")
        print()

    print(
        "Each of these is a choice that depends on the machine, made without asking it.\n"
        "Resolve it at run time, or declare why a fixed value is right, ON THE LINE or within\n"
        "the comment block directly above it:\n\n"
        "    hardware-fixed: <the reason, at least "
        f"{MIN_REASON_CHARS} characters, where a reviewer will meet it>\n\n"
        "Before reaching for the machine's core count: `-t 10` on the reference host is 67.5 %\n"
        "SLOWER than the shipped `-t 4`, and `-p 4` is 35.5 % slower while holding 52.9 % more\n"
        "memory. A declaration is very often the correct answer. See\n"
        "docs/measurements/hardware-choice-audit-2026-09-10/."
    )
    return 1 if (a.strict and firm) else 0


if __name__ == "__main__":
    sys.exit(main())
