#!/usr/bin/env bash
#
# mutation-anchors.test.sh — the static anchor check refuses a mutant whose target text is gone,
# reads each harness in its own dialect, and never counts what it cannot read as present.
#
# The incident (nightly attempt 6, 2026-10-01, run log 20261001T022754Z-f673d370): the
# workspace-mutants gate failed after 1762 s on S-p02-agent-writes-inside-codex-pass-the-lock-out,
# "MUTATION TARGET ABSENT", because a change to mega-lander/workspaces.py renamed the line the
# mutant edits and no check before the nightly read the anchor. Case A8 rebuilds exactly that
# drift from the real harness and the real file, and the check must name that mutant.
#
# Fixtures live in a throwaway directory; the real engine is only read (A1, A8).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/mutation-anchors.py"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'; FAIL=$((FAIL + 1)); return 0; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mutation-anchors-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

run() { # <root> -> sets RC and OUT
    OUT="$(python3 "$CHECK" --root "$1" 2>&1)"
    RC=$?
}

echo "=== mutation-anchors: every mutant's target text still exists ==="

# --- A1: the real engine ----------------------------------------------------------------
run "$ENGINE_ROOT"
N="$(printf '%s\n' "$OUT" | sed -n 's/^mutation-anchors: [0-9]* harness(es), \([0-9]*\) anchor(s) present.*/\1/p')"
if [ "$RC" -eq 0 ] && [ -n "$N" ] && [ "$N" -gt 500 ]; then
    ok "A1  the real engine: every readable anchor is present ($N anchors)"
else
    bad "A1  the real engine: every readable anchor is present (rc=$RC, anchors='$N')" "$(printf '%s\n' "$OUT" | grep -v '^  ok ' | tail -20)"
fi

# --- a fixture engine: the shared library's dialect -------------------------------------
F="$SANDBOX/lib-engine"
mkdir -p "$F/scripts/lib"
cp "$ENGINE_ROOT/scripts/lib/mutation-harness.sh" "$F/scripts/lib/"
cat >"$F/scripts/target.py" <<'EOF'
def guard(x):
    if x:
        raise SystemExit(2)
    return 0
EOF
cat >"$F/scripts/demo.mutation.sh" <<'EOF'
#!/usr/bin/env bash
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "demo" "scripts/demo.test.sh"
T="scripts/target.py"
mutant one-line "D1 " "$T" \
    '    return 0' \
    '    return 1' \
    "a single line"
mutant two-lines "D2 " "$T" \
    '    if x:{NL}        raise SystemExit(2)' \
    '    if False:{NL}        raise SystemExit(2)' \
    "two lines through {NL}; the reason carries an apostrophe: it's prose"
mutant quoted-quote "D3 " "$T" \
    'def guard(x):' \
    'def guard(x):'"'"' '"'"'' \
    "a quote spliced in the bash way"
mutation_end
EOF
run "$F"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'demo.mutation.sh: 3 anchor(s) present'; then
    ok "A2  the shared library's dialect ({NL}, '\"'\"' splices, \$T): 3 of 3 anchors present"
else
    bad "A2  the shared library's dialect: 3 of 3 anchors present (rc=$RC)" "$OUT"
fi

# --- A3: the target text is gone -> refused, naming the mutant --------------------------
python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("SystemExit(2)", "SystemExit(3)"))' "$F/scripts/target.py"
run "$F"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'FAIL  scripts/demo.mutation.sh: two-lines — TARGET ABSENT' \
        && ! printf '%s\n' "$OUT" | grep -q 'one-line —'; then
    ok "A3  a drifted target refuses (rc=1) and names exactly the mutant that lost its text"
else
    bad "A3  a drifted target refuses (rc=$RC) and names exactly the mutant that lost its text" "$OUT"
fi
rm "$F/scripts/target.py"
run "$F"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'one-line — FILE ABSENT'; then
    ok "A3b a deleted target file refuses (rc=1)"
else
    bad "A3b a deleted target file refuses (rc=$RC)" "$OUT"
fi

# --- A4: a harness with its own mutate.py and its own dialect (\\n for a newline) -------
G="$SANDBOX/own-engine"
mkdir -p "$G/scripts/hooks"
printf 'line one\nline two\n' >"$G/scripts/hooks/guarded.sh"
cat >"$G/scripts/hooks/own.mutation.sh" <<'OUTER'
#!/usr/bin/env bash
SANDBOX="$(mktemp -d)"
cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
src = open(path).read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
_mutant_body() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"
}
mutant() { mut_pool_submit "$1" _mutant_body "$@"; }
mutant joined "J1" "scripts/hooks/guarded.sh" 'line one\nline two' 'x' "its own \\n dialect"
mutant computed "J2" "$(echo scripts/hooks/guarded.sh)" 'line one' 'x' "a command substitution"
OUTER
run "$G"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'own.mutation.sh: 1 anchor(s) present' \
        && printf '%s\n' "$OUT" | grep -qE 'NOT CHECKED  scripts/hooks/own.mutation.sh: mutant at line [0-9]+: its words need a command substitution'; then
    ok "A4  a harness's own mutate.py decides its dialect; a word that needs a command is NOT CHECKED, never present"
else
    bad "A4  a harness's own mutate.py decides its dialect; a word that needs a command is NOT CHECKED" "$OUT"
fi
printf 'line one\nline 2\n' >"$G/scripts/hooks/guarded.sh"
run "$G"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'joined — TARGET ABSENT'; then
    ok "A4b the same dialect refuses when its decoded text is gone (rc=1)"
else
    bad "A4b the same dialect refuses when its decoded text is gone (rc=$RC)" "$OUT"
fi

# --- A5: prose that starts a line with "mutant" inside a quoted reason is not a declaration
H="$SANDBOX/prose-engine"
mkdir -p "$H/scripts/lib"
cp "$ENGINE_ROOT/scripts/lib/mutation-harness.sh" "$H/scripts/lib/"
printf 'alpha\n' >"$H/scripts/t.txt"
cat >"$H/scripts/prose.mutation.sh" <<'EOF'
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutant real "P1" "scripts/t.txt" 'alpha' 'beta' \
    "a reason long enough to wrap, so the next line begins
     mutant on its own, which is prose inside this string and not a declaration"
EOF
run "$H"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'prose.mutation.sh: 1 anchor(s) present' && ! printf '%s\n' "$OUT" | grep -q MALFORMED; then
    ok "A5  a line of a quoted reason that begins with 'mutant' is not read as a declaration"
else
    bad "A5  a line of a quoted reason that begins with 'mutant' is not read as a declaration (rc=$RC)" "$OUT"
fi

# --- A6: an empty inventory is not a pass ----------------------------------------------
mkdir -p "$SANDBOX/empty"
run "$SANDBOX/empty"
if [ "$RC" -eq 2 ]; then
    ok "A6  no harness found is exit 2, never a green tick over nothing"
else
    bad "A6  no harness found is exit 2 (rc=$RC)" "$OUT"
fi

# --- A7: a harness that keeps its mutants in its own table is named, not counted ---------
K="$SANDBOX/table-engine"
mkdir -p "$K/scripts"
printf '#!/usr/bin/env bash\nfor m in a b; do echo "$m"; done\n' >"$K/scripts/table.mutation.sh"
run "$K"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'NOT CHECKED  scripts/table.mutation.sh: declares no `mutant` statement' \
        && printf '%s\n' "$OUT" | grep -q ' 0 anchor(s) present'; then
    ok "A7  a harness this reader cannot read is named NOT CHECKED and counts 0 present"
else
    bad "A7  a harness this reader cannot read is named NOT CHECKED (rc=$RC)" "$OUT"
fi

# --- A8: the 2026-10-01 incident, rebuilt from the real harness and the real file --------
R="$SANDBOX/incident-engine"
mkdir -p "$R/scripts/lib" "$R/scripts/hooks" "$R/mega-lander/tests"
cp "$ENGINE_ROOT/scripts/lib/mutation-harness.sh" "$R/scripts/lib/"
cp "$ENGINE_ROOT/mega-lander/tests/workspace-spec-fourteen.mutation.sh" "$R/mega-lander/tests/"
for f in mega-lander/workspaces.py scripts/hooks/guard-worktree-removal.sh mega-lander/create-teammate-worktree.sh \
         scripts/lib/unlanded-branches.py scripts/hooks/guard-unresolved-claims.py; do
    mkdir -p "$R/$(dirname "$f")"
    cp "$ENGINE_ROOT/$f" "$R/$f"
done
run "$R"
if [ "$RC" -eq 0 ]; then
    ok "A8a the real fourteen harness against the real files: every anchor present"
else
    bad "A8a the real fourteen harness against the real files: every anchor present (rc=$RC)" "$OUT"
fi
# The drift that reached the nightly: the codex lock-out's guard line, reworded.
python3 - "$R/mega-lander/workspaces.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '        cx = _codex_workspace_of(fp, str(payload.get("cwd") or ""))\n        if cx:'
assert old in s, "the fixture's anchor moved; re-aim A8 at the p02 mutant's current text"
open(p, "w").write(s.replace(old, '        codex_ws = _codex_workspace_of(fp, str(payload.get("cwd") or ""))\n        if codex_ws:', 1))
PY
run "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'S-p02-agent-writes-inside-codex-pass-the-lock-out — TARGET ABSENT'; then
    ok "A8b the incident's drift is refused at once, naming S-p02-agent-writes-inside-codex-pass-the-lock-out"
else
    bad "A8b the incident's drift is refused at once, naming the p02 mutant (rc=$RC)" "$OUT"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== mutation-anchors: $FAIL failed, $PASS passed ==="
    exit 1
fi
echo "=== mutation-anchors: all $PASS cases hold ==="
exit 0
