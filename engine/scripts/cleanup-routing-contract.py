#!/usr/bin/env python3
"""cleanup-routing-contract.py — A ROUTING KEY CANNOT BE ADDED QUIETLY.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
Two engine suites were red for three days in September 2026 and both were
read as Linux portability. Neither was. Each is one commit, and they are the
same commit twice:

  2afb9703  terminalize() started branching on a SECOND cleanup-routing key,
            `cleanup_policy`. Three test fixtures convert a freshly sealed
            record into a "historical" one by stripping the routing keys off
            the member; two of the three were updated on that commit and
            hooks/terminalize-agent-worktrees.test.sh was not. Its eleven
            quarantine cases were then handed a record that no longer
            selected the quarantine route, and asserted a route their own
            fixture had stopped taking.  Fixed at 7d0c838f.

  6472bb60  eligible() in shell-worktree-sparse.py started refusing any
            member carrying `cleanup_owner`, and every native binding began
            carrying it unconditionally. lib/shell-worktree-sparse.test.sh
            named that key on no line at all, so six seal-time cases went on
            asserting a sparsification that could no longer happen.
            Fixed at af8d277d.

THE SHAPE THEY SHARE IS NOT "A CONVERTER'S POP-LIST WENT STALE." That is
true of the first and false of the second: shell-worktree-sparse.test.sh has
no converter, never had one, and was fixed by re-pointing its cases rather
than by stripping a key. The shape they actually share is one step earlier
and is mechanically visible in the diff of the commit that caused it:

    THE SET OF MEMBER-RECORD KEYS A ROUTING FUNCTION BRANCHES ON CHANGED.

Everything downstream — which fixtures still select which route, which
converters are now incomplete, which suites are asserting a dead branch —
follows from that one event, and that one event is a grep away. So this
check locks the set. It derives, from source, every member key that every
lifecycle routing function tests, compares it against a recorded signature,
and when they differ it fails and prints the whole downstream picture:
each converter in the tree and whether it covers the new key, and each
suite that exercises the function whose signature moved.

===========================================================================
WHAT IT ASSERTS
===========================================================================
R1  SIGNATURE.  The derived map (module, function, key, test-shape) equals
    lib/cleanup-routing.signature.  Update with --record, which preserves
    every existing route/structural classification and writes `?` for a key
    it has never seen — so a NEW key cannot be recorded without a human
    typing what it is.  R1 is the assertion that fires on the CAUSING
    commit, before any fixture has had a chance to go quietly wrong.

R2  CONVERTER COVERAGE.  A `historical` fixture converter is any place in
    the tree that removes a `route`-classified key from a member record.
    It must remove EVERY route key, because terminalize() sends a member
    down the quarantine/capture path only when it is neither platform-owned
    (`cleanup_owner`) nor daily-reclaimed (`cleanup_policy:
    integrated-daily`), and a converter that strips one of the two hands
    back a record that is historical in name only.  A converter that
    deliberately strips a subset declares it on the spot:

        historical-fixture-partial: <key>[,<key>] — <reason>

    in the comment block attached to the removal — the comments immediately
    above it, across the one `def`/`fn() {` header it may sit inside.  Three
    such declarations exist and each records a checked fact: a member built
    by _verify_native_member (worktree-transactions.py:477) and persisted
    without a seal has no cleanup_policy to strip, because try_seal
    (worktree-transactions.py:684) is the only thing that stamps it.

R3  EXTRACTOR CANARY.  A static extractor that has quietly stopped matching
    reports a green tick over nothing.  So the places this extractor is
    STRUCTURALLY BLIND are rows in the lock like any other: a function that
    reads `members` without naming a member variable, and a member key read
    through a variable rather than a literal.  They may exist; they may not
    grow.  A refactor that moves a routing decision into one of those shapes
    fails R3 instead of silently emptying R1.

===========================================================================
WHAT IT CANNOT SEE, stated rather than glossed
===========================================================================
R1's extraction is an AST walk, not a grep, so it is not fooled by the key
appearing in a comment, a docstring or a string literal — the two failure
modes a plain `grep 'cleanup_'` has.  It is still defeated by four shapes:

  1. AN INDIRECT KEY.  `member.get(KEY_CONST)` or `member.get(k) for k in
     KEYS` reads a key the walk cannot resolve to a name.  Such a site is
     LOCKED as *indirect-key-read* rather than dropped — that is the
     difference between a heuristic that degrades loudly and one that
     degrades to green.  There are zero such sites today.

  2. A ROUTING DECISION MADE OUTSIDE A NAMED MEMBER VARIABLE.  The walk
     recognizes a member as a variable named `member`/`m`/`native`/`mem`
     that is either a bare parameter or bound from an expression mentioning
     `members`.  `t["members"][index].get("path")` — subscripted inline,
     never named — is invisible.  FIVE functions read members that way
     today and all five are locked as *no-member-variable*; each was read
     and none makes a routing decision (bound_members and close_if_empty
     test the members LIST, not a member key; notice_once subscripts inline
     to build a log line; process_pending_terminals delegates to try_seal
     and terminalize; verify_receipt walks receipt rows, not members).

  3. A ROUTING FUNCTION IN A MODULE THIS DOES NOT SCAN.  Modules are
     discovered from disk (a `.py` under scripts/ that mentions `members`
     and one of the transaction entry points), never listed, so a new
     lifecycle module is picked up automatically — but a routing decision
     moved into, say, a shell script would not be.

  4. R2's removal scan IS textual, because the converters live inside bash
     heredocs that no Python parser will accept.  It matches `pop('key'`,
     `pop("key"`, `del x['key']`, `del x["key"]`.  A removal spelled
     `{k: v for k, v in member.items() if k not in KEYS}` is invisible to
     it.  There are zero such sites today.

The honest summary: R1 cannot be fooled by prose and can be fooled by
indirection, and every indirection it meets it locks.

===========================================================================
USAGE
===========================================================================
    scripts/cleanup-routing-contract.py            # check; exit 0/1
    scripts/cleanup-routing-contract.py --record   # re-lock the signature
    scripts/cleanup-routing-contract.py --root DIR --signature FILE
                                                   # for the test harness

Exit codes: 0 contract holds; 1 the contract is broken (R1, R2 or R3);
2 the engine root or the signature file is unreadable — refusing to report
a green tick over a tree it could not read.
"""

import argparse
import ast
import os
import pathlib
import re
import sys

# The names a member record is bound to in this engine. A name here counts as
# a member only when it is a bare parameter or is bound from an expression
# mentioning `members` (see _member_names) — that second test is what keeps
# `m = metrics(root)` in reconcile-terminal-worktrees.status out of the
# signature without a single hard-coded exclusion.
MEMBER_NAMES = ("member", "m", "native", "mem")

# A module is scanned when it mentions members AND one of the transaction
# entry points. Discovered from disk on every run; there is no list.
MODULE_MARKERS = ("tx_path", "load_tx", "worktree-transactions", "update_member")

SKIP_NAME_PARTS = (".test.", ".mutation.", ".acceptance.", ".selftest.")

PARTIAL_MARKER = "historical-fixture-partial:"
PARTIAL_LOOKBACK = 40

REMOVAL_RE = re.compile(
    r"""(?:\.pop\(\s*(?P<q1>['"])(?P<k1>[A-Za-z_][A-Za-z0-9_]*)(?P=q1)"""
    r"""|\bdel\s+[A-Za-z_][A-Za-z0-9_.\[\]'"()]*\[\s*(?P<q2>['"])(?P<k2>[A-Za-z_][A-Za-z0-9_]*)(?P=q2)\s*\])"""
)

# A converter is a run of removals no further apart than this many lines.
CONVERTER_GAP = 4


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
def discover_modules(scripts_root):
    """Every lifecycle module, from disk. Never a typed list."""
    found = []
    self_name = pathlib.Path(__file__).name
    for path in sorted(scripts_root.rglob("*.py")):
        if any(part in path.name for part in SKIP_NAME_PARTS):
            continue
        if path.name == self_name:
            continue  # the checker reads member records too; it routes nothing
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        if "members" not in text:
            continue
        if not any(marker in text for marker in MODULE_MARKERS):
            continue
        found.append(path)
    return found


# ---------------------------------------------------------------------------
# R1 — the signature
# ---------------------------------------------------------------------------
def _mentions_members(node):
    """True when the expression reads the transaction's `members` list.

    Matched EXACTLY, never as a substring of a longer identifier or string.
    The substring form is not a hypothetical: reconcile-terminal-worktrees.
    status() builds a metrics mapping named `m` whose keys include
    `terminal_members_present`, and a substring test read that dict literal
    as a members expression and put four counter names in the signature."""
    for sub in ast.walk(node):
        if isinstance(sub, ast.Constant) and sub.value == "members":
            return True
        if isinstance(sub, ast.Attribute) and sub.attr == "members":
            return True
        if isinstance(sub, ast.Name) and sub.id == "members":
            return True
    return False


def _member_names(fn):
    """Names inside `fn` that hold a member record.

    A candidate name qualifies when it is a parameter (nothing to trace), or
    when at least one of its bindings is an expression mentioning `members`.
    A name with bindings, none of which mention members, is NOT a member —
    that single rule is what keeps a metrics mapping named `m` out."""
    params = {a.arg for a in list(fn.args.args) + list(fn.args.kwonlyargs)}
    bindings = {}
    for node in ast.walk(fn):
        targets = []
        value = None
        if isinstance(node, ast.Assign):
            targets, value = node.targets, node.value
        elif isinstance(node, (ast.For, ast.AsyncFor)):
            targets, value = [node.target], node.iter
        elif isinstance(node, (ast.comprehension,)):
            targets, value = [node.target], node.iter
        elif isinstance(node, ast.withitem) and node.optional_vars is not None:
            targets, value = [node.optional_vars], node.context_expr
        if value is None:
            continue
        for target in targets:
            for sub in ast.walk(target):
                if isinstance(sub, ast.Name):
                    bindings.setdefault(sub.id, []).append(value)
    names = set()
    for candidate in MEMBER_NAMES:
        bound = bindings.get(candidate)
        if bound is None:
            if candidate in params:
                names.add(candidate)
            continue
        if any(_mentions_members(v) for v in bound):
            names.add(candidate)
    return names


def _key_read(node, names):
    """(key, 'ok') for a constant key read off a member; (None, 'indirect')
    for a member key read the walk cannot resolve to a name."""
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
            and node.func.attr == "get" and node.args \
            and isinstance(node.func.value, ast.Name) and node.func.value.id in names:
        arg = node.args[0]
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            return arg.value, "ok"
        return None, "indirect"
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) \
            and node.value.id in names:
        key = node.slice
        if isinstance(key, ast.Constant) and isinstance(key.value, str):
            return key.value, "ok"
        return None, "indirect"
    return None, ""


def _shape(value):
    if value is None:
        return "is-none"
    if isinstance(value, str):
        return "literal(%s)" % value
    return "literal(%r)" % (value,)


class _Signature(ast.NodeVisitor):
    """Every member key TESTED against a literal or for presence, per function.

    A read that merely fetches a value (`norm_path(member.get("path"))`) is not
    a routing decision and is deliberately not recorded: a signature that moved
    every time a path was read would be re-locked reflexively, and a lock
    nobody reads is a lock nobody keeps."""

    def __init__(self):
        self.stack = []
        self.names = [set()]
        self.rows = []          # (function, key, shape, lineno)
        self.indirect = []      # (function, lineno)

    # -- scoping -----------------------------------------------------------
    def visit_FunctionDef(self, node):
        self.stack.append(node.name)
        self.names.append(self.names[-1] | _member_names(node))
        self.generic_visit(node)
        self.names.pop()
        self.stack.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def _fn(self):
        return ".".join(self.stack) or "<module>"

    def _record(self, node, shape):
        key, how = _key_read(node, self.names[-1])
        if how == "indirect":
            self.indirect.append((self._fn(), node.lineno))
        elif key is not None:
            self.rows.append((self._fn(), key, shape, node.lineno))

    # -- the three test shapes --------------------------------------------
    def visit_Compare(self, node):
        for op, right in zip(node.ops, node.comparators):
            if isinstance(op, (ast.In, ast.NotIn)) and isinstance(node.left, ast.Constant) \
                    and isinstance(node.left.value, str) and isinstance(right, ast.Name) \
                    and right.id in self.names[-1]:
                self.rows.append((self._fn(), node.left.value, "presence", node.lineno))
            if isinstance(right, ast.Constant):
                self._record(node.left, _shape(right.value))
            if isinstance(node.left, ast.Constant):
                self._record(right, _shape(node.left.value))
        self.generic_visit(node)

    def _truthy(self, test):
        parts = list(test.values) if isinstance(test, ast.BoolOp) else [test]
        for part in parts:
            if isinstance(part, ast.UnaryOp) and isinstance(part.op, ast.Not):
                self._record(part.operand, "truthy")
            else:
                self._record(part, "truthy")

    def visit_If(self, node):
        self._truthy(node.test)
        self.generic_visit(node)

    def visit_IfExp(self, node):
        self._truthy(node.test)
        self.generic_visit(node)

    def visit_While(self, node):
        self._truthy(node.test)
        self.generic_visit(node)


# R3's two blind spots are LOCKED, not printed. A note printed on every green
# run is a note nobody reads by the third week; a row in the lock is a diff a
# reviewer cannot miss and a failure the runner cannot swallow.
BLIND_KEY = "*no-member-variable*"
INDIRECT_KEY = "*indirect-key-read*"
CANARY_CLASS = "canary"


def derive(scripts_root):
    """-> sorted list of (module, function, key, shape).

    Real rows are one member key TESTED by one function. Two synthetic keys
    carry R3: BLIND_KEY for a function that touches `members` with no member
    variable this walk can see, and INDIRECT_KEY for a member key read through
    a variable rather than a literal. Both are places R1 is structurally
    blind, so both are locked: they may exist, they may not grow, and a
    refactor that moves a routing decision into one of those shapes fails the
    check instead of quietly emptying it."""
    rows = set()
    for path in discover_modules(scripts_root):
        rel = str(path.relative_to(scripts_root))
        try:
            tree = ast.parse(path.read_text())
        except SyntaxError as error:
            raise SystemExit("cleanup-routing-contract: cannot parse %s: %s" % (rel, error))
        visitor = _Signature()
        visitor.visit(tree)
        for fn, key, shape, _line in visitor.rows:
            rows.add((rel, fn, key, shape))
        for fn, _line in visitor.indirect:
            rows.add((rel, fn, INDIRECT_KEY, "unresolvable key expression"))
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if not _member_names(node) and any(
                    isinstance(sub, ast.Constant) and sub.value == "members"
                    for sub in ast.walk(node)):
                rows.add((rel, node.name, BLIND_KEY, "reads members, names none"))
    return sorted(rows)


def line_numbers(scripts_root, module, function, key):
    """Where a signature row lives, for the failure message only. Line numbers
    are never stored in the lock: they churn on every edit above them."""
    path = scripts_root / module
    try:
        tree = ast.parse(path.read_text())
    except (OSError, SyntaxError):
        return []
    visitor = _Signature()
    visitor.visit(tree)
    return sorted({ln for fn, k, _s, ln in visitor.rows if fn == function and k == key})


# ---------------------------------------------------------------------------
# the signature file
# ---------------------------------------------------------------------------
SIGNATURE_HEADER = """\
# cleanup-routing.signature — THE LOCK ON WHICH MEMBER KEYS ROUTE CLEANUP.
#
# DERIVED FROM SOURCE, then locked. Every line is one member-record key that
# one lifecycle function TESTS — against a literal, for presence, or for
# truth. scripts/cleanup-routing-contract.py re-derives this on every run and
# fails when it differs, because a change here is exactly the event that
# silently invalidated eleven quarantine cases at 2afb9703 and six sparse
# cases at 6472bb60.
#
# THE CLASS COLUMN IS THE ONLY THING A HUMAN TYPES, and it is the decision the
# two commits above skipped:
#
#   route       a HISTORICAL fixture must NOT carry this key. Every fixture
#               converter in the tree is required to strip it, and the check
#               names the converter that does not.
#   structural  a historical member carries this key like any other; a
#               converter that stripped it would be corrupting the record,
#               not ageing it.
#   ?           written by --record for a key it has never seen. The check
#               FAILS on a `?`. Classifying it is the whole point.
#
# Re-lock with:  scripts/cleanup-routing-contract.py --record
# Columns: module<TAB>function<TAB>key<TAB>class<TAB>test-shape
"""


def read_signature(path):
    if not path.exists():
        return None
    classes, rows = {}, []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 5:
            raise SystemExit("cleanup-routing-contract: malformed signature line: %r" % raw)
        module, function, key, klass, shape = (p.strip() for p in parts)
        rows.append((module, function, key, shape))
        classes[key] = klass
    return rows, classes


def classify(key, classes):
    """The class column. The two synthetic R3 keys classify themselves: they
    are not member keys and there is nothing for a human to decide about
    them — they are locked so they cannot grow, and that is all."""
    if key in (BLIND_KEY, INDIRECT_KEY):
        return CANARY_CLASS
    return classes.get(key, "?")


def write_signature(path, rows, classes):
    out = [SIGNATURE_HEADER]
    for module, function, key, shape in rows:
        out.append("%s\t%s\t%s\t%s\t%s" % (module, function, key, classify(key, classes), shape))
    path.write_text("\n".join(out) + "\n")


# ---------------------------------------------------------------------------
# R2 — converters
# ---------------------------------------------------------------------------
def scan_converters(engine_root, route_keys):
    """Every place in the engine that removes a route key from a record.

    Textual on purpose: five of the eight live converters are Python written
    inside a bash heredoc, which no Python parser will accept."""
    converters = []
    for path in sorted(engine_root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if path.suffix not in (".sh", ".py", ".bash", ""):
            continue
        if ".git/" in str(path):
            continue
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        if not any(k in line for line in lines for k in route_keys):
            continue
        hits = []
        for index, line in enumerate(lines, start=1):
            for match in REMOVAL_RE.finditer(line):
                key = match.group("k1") or match.group("k2")
                if key in route_keys:
                    hits.append((index, key))
        if not hits:
            continue
        # group contiguous removals into one converter
        block = []
        for line_no, key in hits:
            if block and line_no - block[-1][0] > CONVERTER_GAP:
                converters.append((path, block))
                block = []
            block.append((line_no, key))
        if block:
            converters.append((path, block))
    return converters


def _preceding_comment_block(lines, first_line):
    """The comment block attached to the converter, read upward.

    Attached means: from the removal, walk up through blank lines, comment
    lines and the one definition header the removal may sit inside (`def x():`,
    `x() {`), and stop at the first other line of code. A fixed line budget was
    the first shape of this and it was wrong on its first real declaration —
    a five-line explanation above a `def` is eight lines from the `pop` it
    explains, which is exactly where a reviewer would write it."""
    block, index, seen_header = [], first_line - 2, False
    while index >= 0 and (first_line - index) <= PARTIAL_LOOKBACK:
        stripped = lines[index].strip()
        if not stripped:
            index -= 1
            continue
        if stripped.startswith("#") or stripped.startswith("//"):
            block.append(lines[index])
            index -= 1
            continue
        if not seen_header and (stripped.startswith("def ")
                                or stripped.startswith("function ")
                                or re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{", stripped)
                                or stripped.endswith("<<'HISTORICAL'")):
            seen_header = True
            index -= 1
            continue
        break
    return block


def declared_partial(path, first_line):
    """The `historical-fixture-partial:` declaration for a converter, if any.
    -> (keys, reason) or None."""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for raw in _preceding_comment_block(lines, first_line):
        if PARTIAL_MARKER not in raw:
            continue
        tail = raw.split(PARTIAL_MARKER, 1)[1].strip()
        if not tail:
            return None
        keys_part, _, reason = tail.partition("—")
        if not reason:
            keys_part, _, reason = tail.partition("--")
        keys = {k.strip() for k in keys_part.split(",") if k.strip()}
        return keys, reason.strip()
    return None


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------
def suites_exercising(engine_root, module):
    """Suites that name the module or its stem on a live line. Loose on
    purpose, and loose in the safe direction: the list is printed to be read
    by a human who has just been told a routing function moved."""
    stem = pathlib.Path(module).stem
    out = []
    for path in sorted(engine_root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if not any(part in path.name for part in (".test.", ".mutation.")):
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for raw in text.splitlines():
            stripped = raw.strip()
            if stripped and not stripped.startswith("#") and stem in stripped:
                out.append(str(path.relative_to(engine_root)))
                break
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--record", action="store_true",
                        help="re-lock the signature, preserving every existing classification")
    parser.add_argument("--root", default=None, help="engine root (default: this script's parent)")
    parser.add_argument("--signature", default=None, help="signature file path")
    args = parser.parse_args(argv)

    here = pathlib.Path(__file__).resolve().parent
    engine_root = pathlib.Path(args.root).resolve() if args.root else here.parent
    scripts_root = engine_root / "scripts"
    if not scripts_root.is_dir():
        sys.stderr.write("cleanup-routing-contract: no scripts/ under %s — refusing to report a "
                         "contract over a tree it cannot read.\n" % engine_root)
        return 2
    sig_path = pathlib.Path(args.signature).resolve() if args.signature \
        else scripts_root / "lib" / "cleanup-routing.signature"

    derived = derive(scripts_root)
    if not derived:
        sys.stderr.write("cleanup-routing-contract: derived NO member-key tests under %s. That is "
                         "not a passing run with nothing to do — either discovery is broken or "
                         "this is not an engine checkout.\n" % scripts_root)
        return 2

    existing = read_signature(sig_path)
    if args.record:
        classes = existing[1] if existing else {}
        write_signature(sig_path, derived, classes)
        unknown = sorted({k for _m, _f, k, _s in derived if classify(k, classes) == "?"})
        sys.stdout.write("recorded %d routing tests to %s\n" % (len(derived), sig_path))
        if unknown:
            sys.stdout.write("UNCLASSIFIED, and the check stays red until each is `route` or "
                             "`structural`: %s\n" % ", ".join(unknown))
            return 1
        return 0

    if existing is None:
        sys.stderr.write("cleanup-routing-contract: no signature at %s. Create it with --record.\n"
                         % sig_path)
        return 2

    locked_rows, classes = existing
    failures = []

    # ---- R1 -------------------------------------------------------------
    added = [r for r in derived if r not in set(locked_rows)]
    removed = [r for r in locked_rows if r not in set(derived)]
    unclassified = sorted({k for _m, _f, k, _s in derived
                           if classify(k, classes) not in ("route", "structural", CANARY_CLASS)})

    route_keys = {k for k, c in classes.items() if c == "route"}
    # A key the lock has never classified is treated as routing for R2's
    # purposes, so a converter gap is reported on the same run as the key.
    route_keys |= set(unclassified)

    canary_moved = [r for r in added + removed if r[2] in (BLIND_KEY, INDIRECT_KEY)]
    real_moved = [r for r in added + removed if r[2] not in (BLIND_KEY, INDIRECT_KEY)]

    if real_moved:
        detail = ["R1  THE ROUTING SIGNATURE MOVED. %d test(s) added, %d removed."
                  % (len([r for r in added if r in real_moved]),
                     len([r for r in removed if r in real_moved])), ""]
        for module, function, key, shape in added:
            if key in (BLIND_KEY, INDIRECT_KEY):
                continue
            lines = line_numbers(scripts_root, module, function, key)
            detail.append("    + %s:%s  %s() now tests member[%r]  (%s)"
                          % (module, ",".join(str(n) for n in lines) or "?", function, key, shape))
        for module, function, key, shape in removed:
            if key in (BLIND_KEY, INDIRECT_KEY):
                continue
            detail.append("    - %s  %s() no longer tests member[%r]  (%s)"
                          % (module, function, key, shape))
        detail.append("")
        detail.append("    WHAT THIS INVALIDATES, and it is why the suites went red for three days:")
        detail.append("    a fixture built through a real seal now takes a DIFFERENT branch than the")
        detail.append("    one its cases assert. Below is every place that has to agree with the new")
        detail.append("    signature. Re-lock with: scripts/cleanup-routing-contract.py --record")
        for module in sorted({m for m, _f, k, _s in real_moved if k}):
            suites = suites_exercising(engine_root, module)
            detail.append("")
            detail.append("    suites exercising %s:" % module)
            for suite in suites:
                detail.append("        %s" % suite)
            if not suites:
                detail.append("        (none found — that is itself worth a look)")
        failures.append("\n".join(detail))

    # ---- R3, the extractor canary ---------------------------------------
    # Locked, not printed: a blind spot that appears or disappears is a change
    # in what R1 can see, and a change in what a check can see is exactly the
    # thing that must never happen quietly.
    if canary_moved:
        detail = ["R3  EXTRACTOR CANARY: R1's BLIND SPOTS MOVED.", "",
                  "    R1 reads member keys off variables it can name. These rows record the",
                  "    places it cannot, and locking them is what stops a refactor from turning",
                  "    a green R1 into a green nothing.", ""]
        for module, function, key, _shape in added:
            if key in (BLIND_KEY, INDIRECT_KEY):
                detail.append("    + %s  %s()  %s" % (module, function, key))
        for module, function, key, _shape in removed:
            if key in (BLIND_KEY, INDIRECT_KEY):
                detail.append("    - %s  %s()  %s" % (module, function, key))
        detail.append("")
        detail.append("    A `+` is a NEW place a routing decision could hide. Read the function")
        detail.append("    and confirm it routes nothing on a member key; then re-lock.")
        failures.append("\n".join(detail))

    if unclassified:
        failures.append(
            "R1  UNCLASSIFIED ROUTING KEY: %s\n"
            "    The signature records the key and not what it means. Set the class column in\n"
            "    %s to `route` (a historical fixture must not carry it, and every converter must\n"
            "    strip it) or `structural` (a historical member carries it like any other).\n"
            "    This is the decision 2afb9703 and 6472bb60 both skipped."
            % (", ".join(unclassified), sig_path))

    # ---- R2 -------------------------------------------------------------
    if route_keys:
        for path, block in scan_converters(engine_root, route_keys):
            stripped = {key for _line, key in block}
            missing = route_keys - stripped
            if not missing:
                continue
            rel = str(path.relative_to(engine_root))
            first = block[0][0]
            partial = declared_partial(path, first)
            if partial is not None:
                keys, reason = partial
                if keys == stripped and reason:
                    continue
                failures.append(
                    "R2  DECLARATION DOES NOT MATCH THE CONVERTER: %s:%d\n"
                    "    declared partial for {%s}%s, but the converter strips {%s}."
                    % (rel, first, ", ".join(sorted(keys)) or "nothing",
                       "" if reason else " with NO reason given",
                       ", ".join(sorted(stripped))))
                continue
            consumers = sorted({"%s.%s()" % (m, f) for m, f, k, _s in derived if k in missing})
            failures.append(
                "R2  INCOMPLETE HISTORICAL FIXTURE CONVERTER\n"
                "    converter:  %s:%s\n"
                "    strips:     %s\n"
                "    MISSING:    %s\n"
                "    routed by:  %s\n"
                "    A record that keeps %s is historical in name only: it still selects the\n"
                "    current route, so every case below this converter asserts a branch its own\n"
                "    fixture no longer takes. Add the missing removal, or declare the subset\n"
                "    within %d lines above line %d:\n"
                "        %s %s — <why this member never carries the other key>"
                % (rel, ",".join(str(n) for n, _k in block),
                   ", ".join(sorted(stripped)),
                   ", ".join(sorted(missing)),
                   ", ".join(consumers) or "(nothing in the signature — check --record)",
                   ", ".join(sorted(missing)),
                   PARTIAL_LOOKBACK, first,
                   PARTIAL_MARKER, ",".join(sorted(stripped))))

    if failures:
        sys.stderr.write("\n=== cleanup-routing contract: BROKEN ===\n\n")
        sys.stderr.write("\n\n".join(failures) + "\n\n")
        return 1
    real = [r for r in derived if r[2] not in (BLIND_KEY, INDIRECT_KEY)]
    sys.stdout.write("cleanup-routing contract holds: %d routing test(s) across %d function(s), "
                     "%d route key(s) (%s), every converter complete; %d locked blind spot(s).\n"
                     % (len(real), len({(m, f) for m, f, _k, _s in real}),
                        len({k for k, c in classes.items() if c == "route"}),
                        ", ".join(sorted(k for k, c in classes.items() if c == "route")),
                        len(derived) - len(real)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
