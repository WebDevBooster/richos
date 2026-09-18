#!/usr/bin/env bash
#
# scratch-allocation-lint.test.sh — A LINT IS JUDGED ON WHAT IT LETS THROUGH.
#
#   L1  a bare `mktemp -d` is FOUND, and the message says how to fix it.
#   L2  an ALLOCATED directory is not found. The positive control: without it,
#       every case here passes against a lint that flags everything.
#   L3  a plain `mktemp` for a FILE is not found. Deliberate scope: a one-line
#       temp file is not what fills a disk, and flagging every one would make
#       this fire across the engine and be waived on the day it landed.
#   L4  `mktemp -dt`, `-d -t` and `--directory` are all found. One flag spelling
#       missed is a hole the next author walks through without knowing.
#   L5  a COMMENT mentioning `mktemp -d` is NOT found. This was the lint's own
#       first false positive: it flagged the two files that had just been
#       migrated, because the comments explaining the migration quote the line
#       they replaced.
#   L6  `# scratch-exempt: <reason>` exempts, on the line or the line before.
#   L7  A BARE MARKER WITH NO REASON EXEMPTS NOTHING, and is itself a finding.
#   L8  the BASELINE holds: at or under it, exit 0; one over, exit 1 naming the
#       excess. This is the property that makes the lint enforceable on a tree
#       with 45 pre-existing sites instead of red-and-waived.
#   L9  --zero ignores the baseline.
#   L10 the allocator and this lint are never their own findings.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/scratch-allocation-lint.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LINT" ] || { echo "FATAL: missing $LINT" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scratch-lint-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== scratch-allocation-lint tests ==="

# A throwaway engine: scripts/ plus whatever the case under test puts in it. The
# lint takes its root from SCRATCH_LINT_ROOT, so nothing here reads the real tree.
fresh() {
    rm -rf "$SANDBOX/engine"
    mkdir -p "$SANDBOX/engine/scripts/lib" "$SANDBOX/engine/scripts/hooks"
}

# run <baseline> -> OUT, RC
run() {
    OUT="$(SCRATCH_LINT_ROOT="$SANDBOX/engine" \
           SCRATCH_LINT_BASELINE="${1:-0}" \
           bash "$LINT" "${@:2}" 2>&1)"
    RC=$?
}

# ---------------------------------------------------------------------------
# L1 / L2 — the finding, and the control that makes it mean something
# ---------------------------------------------------------------------------
fresh
cat >"$SANDBOX/engine/scripts/bad.sh" <<'EOF'
#!/usr/bin/env bash
D="$(mktemp -d -t something.XXXXXX)"
EOF
run 0
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'bad.sh:2' \
   && printf '%s' "$OUT" | grep -q 'scratch_new'; then
    ok "L1  a bare \`mktemp -d\` is found, and the fix is named"
else
    bad "L1  a bare \`mktemp -d\` was not found (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

fresh
cat >"$SANDBOX/engine/scripts/good.sh" <<'EOF'
#!/usr/bin/env bash
. "$ENGINE/scripts/lib/scratch.sh"
D="$(scratch_new something)"
EOF
run 0
if [ "$RC" = "0" ]; then
    ok "L2  CONTROL: an ALLOCATED directory is not a finding"
else
    bad "L2  CONTROL FAILED: the lint flags correct code, so L1 proves nothing"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

# ---------------------------------------------------------------------------
# L3 — a temp FILE is out of scope, on purpose
# ---------------------------------------------------------------------------
fresh
cat >"$SANDBOX/engine/scripts/file.sh" <<'EOF'
#!/usr/bin/env bash
F="$(mktemp)"
G="$(mktemp -t prefix)"
EOF
run 0
if [ "$RC" = "0" ]; then
    ok "L3  a plain \`mktemp\` for a FILE is out of scope"
else
    bad "L3  a temp file was flagged — that scope makes this lint unwaivable-in-name-only"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi

# ---------------------------------------------------------------------------
# L4 — every spelling of the directory flag
# ---------------------------------------------------------------------------
for spelling in 'mktemp -d -t p.XXXXXX' 'mktemp -dt p.XXXXXX' 'mktemp --directory' 'mktemp -qd'; do
    fresh
    printf '#!/usr/bin/env bash\nD="$(%s)"\n' "$spelling" \
        >"$SANDBOX/engine/scripts/spell.sh"
    run 0
    if [ "$RC" = "1" ]; then
        ok "L4  found: $spelling"
    else
        bad "L4  MISSED: $spelling — one spelling missed is a hole"
    fi
done

# ---------------------------------------------------------------------------
# L5 — a comment is not code
# ---------------------------------------------------------------------------
fresh
cat >"$SANDBOX/engine/scripts/commented.sh" <<'EOF'
#!/usr/bin/env bash
# This used to be `mktemp -d -t root-mutation.XXXXXX` and left 105.3 GB behind.
    # mktemp -d is what the old line did
D="$(scratch_new thing)"
EOF
run 0
if [ "$RC" = "0" ]; then
    ok "L5  a COMMENT quoting \`mktemp -d\` is not a finding"
else
    bad "L5  the lint flags its own documentation — its first false positive"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

# ---------------------------------------------------------------------------
# L6 / L7 — the escape hatch, and the bare marker that is not one
# ---------------------------------------------------------------------------
fresh
cat >"$SANDBOX/engine/scripts/exempt.sh" <<'EOF'
#!/usr/bin/env bash
D="$(mktemp -d -t p.XXXXXX)"  # scratch-exempt: runs before the engine is resolvable
# scratch-exempt: the allocator's own bootstrap cannot call itself
E="$(mktemp -d -t q.XXXXXX)"
EOF
run 0
if [ "$RC" = "0" ]; then
    ok "L6  a declared exemption is accepted on the line AND the line before"
else
    bad "L6  a declared exemption was not accepted (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi
run 0 --list
if printf '%s' "$OUT" | grep -q 'runs before the engine is resolvable'; then
    ok "L6b --list prints every exemption WITH its reason"
else
    bad "L6b --list does not show the reasons, so they cannot be reviewed"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi

fresh
cat >"$SANDBOX/engine/scripts/bare.sh" <<'EOF'
#!/usr/bin/env bash
D="$(mktemp -d -t p.XXXXXX)"  # scratch-exempt:
EOF
run 0
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'BARE scratch-exempt'; then
    ok "L7  a BARE marker with no reason exempts nothing and is a finding"
else
    bad "L7  a reasonless marker was accepted — the reason is the whole point"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi

# ---------------------------------------------------------------------------
# L8 — the baseline
# ---------------------------------------------------------------------------
fresh
for n in 1 2 3; do
    printf '#!/usr/bin/env bash\nD="$(mktemp -d -t p%s.XXXXXX)"\n' "$n" \
        >"$SANDBOX/engine/scripts/b$n.sh"
done
run 3
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q 'AT OR UNDER'; then
    ok "L8  three findings against a baseline of three is exit 0"
else
    bad "L8  the baseline was not honored (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi
run 2
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q '1 MORE THAN'; then
    ok "L8b one over the baseline is exit 1, naming the excess"
else
    bad "L8b going over the baseline did not fail (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi
run 9
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q 'DOWN 6 from the baseline'; then
    ok "L8c under the baseline says so, and says to lower it"
else
    bad "L8c coming in under the baseline was not reported"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -6
fi

# ---------------------------------------------------------------------------
# L9 — --zero ignores the baseline
# ---------------------------------------------------------------------------
run 99 --zero
if [ "$RC" = "1" ]; then
    ok "L9  --zero ignores the baseline entirely"
else
    bad "L9  --zero still honored the baseline (rc=$RC)"
fi

# ---------------------------------------------------------------------------
# L10 — the mechanism is never its own finding
# ---------------------------------------------------------------------------
fresh
cat >"$SANDBOX/engine/scripts/lib/scratch.sh" <<'EOF'
#!/usr/bin/env bash
# the allocator itself may talk about scratch directly
D="$(mktemp -d -t richos-scratch-bootstrap.XXXXXX)"
EOF
cp "$LINT" "$SANDBOX/engine/scripts/scratch-allocation-lint.sh"
run 0
if [ "$RC" = "0" ]; then
    ok "L10 the allocator and the lint are never their own findings"
else
    bad "L10 the lint flagged the mechanism it exists to enforce"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
