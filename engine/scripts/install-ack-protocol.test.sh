#!/usr/bin/env bash
#
# install-ack-protocol.test.sh — the ack-protocol installer, in a sandbox.
#
# The property that matters is byte-identity across every definition, and the
# property that is easiest to fake is "nothing to do". Both are pinned here,
# and so is the refusal that stops a run over zero seams reporting success.
#
# Run directly: scripts/install-ack-protocol.test.sh

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SRC_DIR/install-ack-protocol.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }

SANDBOX="$(mktemp -d -t ack-protocol.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

PLACEHOLDER='*ACK-PROTOCOL-SEAM — how you acknowledge a correction sent TO you by the lead is defined
elsewhere and deliberately not specified here. Escalation (you → lead, unprompted) and
acknowledgement (lead → you → proof) are different problems; do not collapse them.*'

mk_repo() { # <dir> <n-definitions>
    local dir="$1" n="$2" i
    mkdir -p "$dir/.claude/agents"
    for i in $(seq 1 "$n"); do
        {
            printf -- '---\nname: role%s\nmodel: sonnet\n---\n\n' "$i"
            printf '# Role %s\n\nSome body text.\n\n' "$i"
            printf '%s\n' "$PLACEHOLDER"
            printf '\n## Something After\n\nMore body.\n'
        } > "$dir/.claude/agents/role$i.md"
    done
}

seam_hash() { awk '/ACK-PROTOCOL-SEAM:BEGIN/,/ACK-PROTOCOL-SEAM:END/' "$1" | shasum | cut -d' ' -f1; }

echo "=== ack protocol: installed once, identically, and never over nothing ==="

# --- 1. first install -----------------------------------------------------
R1="$SANDBOX/r1"; mk_repo "$R1" 5
OUT="$(bash "$INSTALLER" --repo "$R1" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "1a. a first install succeeds" || bad "1a. first install succeeds" "exit $RC: $OUT"
case "$OUT" in *"seams found    : 5"*) ok "1b. it finds every seam and says how many" ;;
                *) bad "1b. it reports the seam count" "$OUT" ;; esac
if grep -q "Acknowledging a Correction" "$R1/.claude/agents/role1.md"; then
    ok "1c. the protocol is in the definition"
else
    bad "1c. the protocol is in the definition"
fi
if grep -q "ACK-PROTOCOL-SEAM — how you acknowledge" "$R1/.claude/agents/role1.md"; then
    bad "1d. the placeholder is REPLACED, not appended" "the 'defined elsewhere' sentence is still there and is now false"
else
    ok "1d. the placeholder is REPLACED — 'defined elsewhere' would now be a lie"
fi
if grep -q "ACK-PROTOCOL-SEAM:BEGIN" "$R1/.claude/agents/role1.md"; then
    ok "1e. the token survives as a machine-findable marker"
else
    bad "1e. the token survives as a marker"
fi
# The surrounding definition must be untouched.
grep -q "## Something After" "$R1/.claude/agents/role1.md" \
    && ok "1f. the rest of the definition is untouched" || bad "1f. the rest is untouched"

# --- 2. byte-identity, the whole point ------------------------------------
N_DISTINCT="$(for f in "$R1/.claude/agents"/*.md; do seam_hash "$f"; done | sort -u | wc -l | tr -d ' ')"
[ "$N_DISTINCT" = "1" ] && ok "2a. all five definitions carry a BYTE-IDENTICAL block" \
                        || bad "2a. byte-identical across definitions" "$N_DISTINCT distinct blocks"

# --- 3. idempotence -------------------------------------------------------
B4="$(seam_hash "$R1/.claude/agents/role1.md")"
bash "$INSTALLER" --repo "$R1" >/dev/null 2>&1
[ "$(seam_hash "$R1/.claude/agents/role1.md")" = "$B4" ] \
    && ok "3a. a second install changes nothing" || bad "3a. second install is a no-op"
bash "$INSTALLER" --repo "$R1" --check >/dev/null 2>&1
[ $? -eq 0 ] && ok "3b. --check is green once installed" || bad "3b. --check green once installed"

# --- 4. drift: a block edited by hand is repaired, and reported ------------
python3 - "$R1/.claude/agents/role3.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("at least 40 characters", "at least 4 characters")
open(p, "w").write(s)
PY
bash "$INSTALLER" --repo "$R1" --check >/dev/null 2>&1
[ $? -eq 1 ] && ok "4a. a hand-edited block is DRIFT, and --check exits 1" \
             || bad "4a. hand-edited block is caught by --check"
OUT="$(bash "$INSTALLER" --repo "$R1" 2>&1)"
case "$OUT" in *"STALE COPY REPLACED"*) ok "4b. the repair says it replaced a stale copy, rather than doing it quietly" ;;
                *) bad "4b. the repair names what it did" "$OUT" ;; esac
[ "$(seam_hash "$R1/.claude/agents/role3.md")" = "$B4" ] \
    && ok "4c. and the drifted definition is back to byte-identical" || bad "4c. drift repaired"

# --- 5. two seams in one file (the hiring-template shape) -----------------
R2="$SANDBOX/r2"; mk_repo "$R2" 1
{ printf '\n## Hiring template\n\n'; printf '%s\n' "$PLACEHOLDER"; } >> "$R2/.claude/agents/role1.md"
bash "$INSTALLER" --repo "$R2" >/dev/null 2>&1
[ "$(grep -c 'ACK-PROTOCOL-SEAM:BEGIN' "$R2/.claude/agents/role1.md")" = "2" ] \
    && ok "5a. BOTH seams in one definition are filled (own body + hiring template)" \
    || bad "5a. both seams in one file are filled"

# --- 6. a prose MENTION of the token is not a seam ------------------------
R3="$SANDBOX/r3"; mk_repo "$R3" 1
printf '\nFrontmatter rule: copy the block at ACK-PROTOCOL-SEAM character-for-character.\n' \
    >> "$R3/.claude/agents/role1.md"
bash "$INSTALLER" --repo "$R3" >/dev/null 2>&1
if grep -q "Frontmatter rule: copy the block at ACK-PROTOCOL-SEAM character-for-character." "$R3/.claude/agents/role1.md"; then
    ok "6a. a RULE ABOUT the seam is left alone — a rule about a seam is not a seam"
else
    bad "6a. a prose mention of the token is not treated as a seam"
fi

# --- 7. NO SILENT SUCCESS OVER NOTHING ------------------------------------
R4="$SANDBOX/r4"; mkdir -p "$R4/.claude/agents"
printf -- '---\nname: x\n---\n\nNo seam here at all.\n' > "$R4/.claude/agents/x.md"
OUT="$(bash "$INSTALLER" --repo "$R4" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "7a. zero seams is a REFUSAL (exit 2), never 'nothing to do'" \
               || bad "7a. zero seams refuses" "exit $RC: $OUT"
case "$OUT" in *"has not been installed here"*) ok "7b. and it says WHY there are none, rather than just failing" ;;
                *) bad "7b. the refusal explains itself" "$OUT" ;; esac

# --- 8. --diff writes nothing ---------------------------------------------
R5="$SANDBOX/r5"; mk_repo "$R5" 2
BEFORE="$(shasum "$R5/.claude/agents/role1.md" | cut -d' ' -f1)"
OUT="$(bash "$INSTALLER" --repo "$R5" --diff 2>&1)"
[ "$(shasum "$R5/.claude/agents/role1.md" | cut -d' ' -f1)" = "$BEFORE" ] \
    && ok "8a. --diff writes nothing" || bad "8a. --diff writes nothing"
case "$OUT" in *"+## Acknowledging a Correction"*) ok "8b. --diff shows what it would write" ;;
                *) bad "8b. --diff shows the change" "$(printf '%s' "$OUT" | head -5)" ;; esac

# --- 9. missing inputs fail loudly ----------------------------------------
OUT="$(bash "$INSTALLER" --repo "$SANDBOX/does-not-exist" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "9a. a repo with no .claude/agents refuses" || bad "9a. missing agents dir refuses" "exit $RC"

CANON_BAK="$SANDBOX/canon.bak"
cp "$SRC_DIR/../reference/ack-protocol-seam.md" "$CANON_BAK"
FAKE_ENGINE="$SANDBOX/fake-engine"
mkdir -p "$FAKE_ENGINE/scripts"
cp "$INSTALLER" "$FAKE_ENGINE/scripts/"
OUT="$(bash "$FAKE_ENGINE/scripts/install-ack-protocol.sh" --repo "$R5" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "9b. a missing canonical text refuses rather than installing nothing" \
               || bad "9b. missing canonical text refuses" "exit $RC: $OUT"

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ ack protocol: all %s checks passed.\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m✗ ack protocol: %s/%s passed, %s FAILED.\033[0m\n' "$PASS" "$((PASS + FAIL))" "$FAIL" >&2
exit 1
