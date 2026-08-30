#!/usr/bin/env bash
#
# engine-status.test.sh — the session banner's guard fraction is DERIVED from
#                          the registration surface, and cannot go stale.
#
# WHY THIS FILE EXISTS
# ====================
# The first line an operator reads every session is "N/M guards". It is the
# number most likely to be trusted at a glance and the least likely to be
# re-checked. It has been wrong twice in two days, both times in the most
# dangerous possible direction — a FULL fraction over a STALE inventory:
#
#   13/13  guard-workflow-ban.sh wired, the banner's typed list not updated.
#          Seen live in a real ~/ab/prospects session. d55f54b fixed the
#          arithmetic (numerator and denominator now walked the same list) and
#          left the typing alone.
#   14/14  guard-worktree-removal.sh wired at 79d6958/084eed3. The typed list
#          was not touched. Within HOURS of the previous fix, femcboost
#          announced "14/14 guards" while 15 guards and the announcer loaded.
#
# The lesson of the second occurrence is that fixing the instance does not
# touch the class. So this suite does not assert "the numbers currently agree"
# — 16 == 16 is true today and would stay true after a seventeenth guard was
# added and miscounted, which is precisely the bug. Every case here CONSTRUCTS
# a drift condition and proves the banner tracks it, and case 3 reconstructs
# the historical defect on purpose to prove these assertions can fail at all.
#
# THE TWO QUESTIONS THE FRACTION ANSWERS, which must never collapse into one:
#   denominator  what the HOST WILL LOAD   (hooks/hooks.json)
#   numerator    which of those are ON DISK AND EXECUTABLE
# A fix that made both sides the same query would produce a permanently full
# fraction — reassuring, cheap, and incapable of ever reporting a gap. Case 4
# exists to stop that.
#
# Run directly:  scripts/hooks/engine-status.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAIL_NAMES=()

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# The launching session's own environment must not leak in as a candidate root.
unset CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT

SANDBOX="$(cd "$(mktemp -d -t engine-status.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------------------------------------------------------------------------
# Sandbox: a REAL engine (no stubs — a stubbed engine can pass this suite while
# the shipped one fails) and a separate adopted entity repository.
# ---------------------------------------------------------------------------
ENGINE="$SANDBOX/engine"
ENTITY="$SANDBOX/entity"

mkdir -p "$ENGINE" "$ENTITY"
cp -R "$SRC_ENGINE/scripts" "$ENGINE/scripts"
cp -R "$SRC_ENGINE/hooks"   "$ENGINE/hooks"
cp "$SRC_ENGINE/orchestration.config" "$ENGINE/orchestration.config"
cp "$SRC_ENGINE/VERSION" "$ENGINE/VERSION" 2>/dev/null || printf '0.0.0-test\n' >"$ENGINE/VERSION"

printf 'PROTECTED_PATHS="src"\nREADONLY_ALLOWLIST="Explore Plan"\n' >"$ENTITY/orchestration.config"
git -C "$ENTITY" init -q -b main >/dev/null 2>&1
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -q -m adopt >/dev/null 2>&1

HOOKS_JSON="$ENGINE/hooks/hooks.json"
PRISTINE_HOOKS_JSON="$SANDBOX/hooks.json.pristine"
PRISTINE_LIB="$SANDBOX/registered-hooks.sh.pristine"
cp "$HOOKS_JSON" "$PRISTINE_HOOKS_JSON"
cp "$ENGINE/scripts/lib/registered-hooks.sh" "$PRISTINE_LIB"

restore() {
    cp "$PRISTINE_HOOKS_JSON" "$HOOKS_JSON"
    cp "$PRISTINE_LIB" "$ENGINE/scripts/lib/registered-hooks.sh"
    rm -f "$ENGINE/scripts/hooks/guard-brand-new.sh"
    chmod +x "$ENGINE/scripts/hooks/scan-secrets.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# banner [extra env...] -> sets OUT, SYS_FRAC, MODEL_FRAC
#
# Runs the hook exactly as the host does: no arguments, stdin closed. Both
# channels are read separately and on purpose — the announcement reaching only
# one audience is the defect this hook was rebuilt around, and a fraction that
# silently stopped appearing on the operator's channel would be that defect in
# miniature.
banner() {
    OUT="$(cd "$SANDBOX" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT \
        -u RICHOS_ENGINE_ROOT "RICHOS_ENTITY_ROOT=$ENTITY" "$@" \
        bash "$ENGINE/scripts/hooks/engine-status.sh" </dev/null 2>/dev/null)"
    local sys="${OUT%%\"hookSpecificOutput\"*}"
    local model="${OUT#*\"hookSpecificOutput\"}"
    SYS_FRAC="$(printf '%s' "$sys"   | grep -o '[0-9?][0-9?]*/[0-9?][0-9?]* guards' | head -1)"
    MODEL_FRAC="$(printf '%s' "$model" | grep -o '[0-9?][0-9?]*/[0-9?][0-9?]* guards' | head -1)"
}

# expect_fraction <case> <want> — both channels must carry it, identically.
expect_fraction() {
    local case_name="$1" want="$2 guards"
    if [ "$SYS_FRAC" = "$want" ] && [ "$MODEL_FRAC" = "$want" ]; then
        ok "$case_name"
        return 0
    fi
    bad "$case_name" "want '$want' on both channels; operator='$SYS_FRAC' model='$MODEL_FRAC'"
    return 1
}

# wire_extra_guard — add a SEVENTEENTH registered hook to the plugin table and
# put it on disk, executable. This is the exact move that broke the banner
# twice; the shipped code must absorb it with no second edit anywhere.
wire_extra_guard() {
    printf '#!/usr/bin/env bash\nexit 0\n' >"$ENGINE/scripts/hooks/guard-brand-new.sh"
    chmod +x "$ENGINE/scripts/hooks/guard-brand-new.sh"
    python3 - "$HOOKS_JSON" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
d["hooks"].setdefault("PreToolUse", []).append({
    "matcher": "Bash",
    "hooks": [{
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-brand-new.sh",
        "timeout": 10,
    }],
})
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
PY
}

echo "=== the session banner's guard fraction is derived, not remembered ==="
echo ""

# ===========================================================================
# 1. BASELINE — and the expectation is itself derived, never typed.
#
# A test that asserted a literal "15/15" would be a THIRD hand-maintained
# inventory, failing on the next legitimate guard for the same reason the
# banner did. So the expected value is computed here from hooks.json by a
# method deliberately unlike the shipped one (a text scan, not a JSON parse):
# two independent readings of the registration surface must agree.
# ===========================================================================
REGISTERED_N="$(grep -o 'scripts/hooks/[A-Za-z0-9._+-]*\.sh' "$HOOKS_JSON" \
    | sed 's|.*/||' | LC_ALL=C sort -u | grep -c .)"
# The announcer is deliberately excluded from a count of GUARDS: it guards
# nothing, and its own term could never be unsatisfied (no announcer, no
# banner). engine-status.sh excludes it self-referentially, by its own
# filename, so the exclusion cannot itself become a stale list.
#
# 24 -> 25 on 2026-08-30: guard-completeness-commits.sh and
# guard-row-currency-commits.sh were wired on the same day, by two engineers who
# each bumped this line to 24 without knowing about the other. The merge
# conflicted here, which is the tripwire doing precisely its job: two additive
# registrations that a careless union would have counted once. Fourth firing.
EXPECT_N=$((REGISTERED_N - 1))
# The three fractions the mutations below produce, derived from the same
# reading rather than typed. They used to be literals, and every legitimate
# new guard turned six passing cases red at once for no reason connected to
# what they test — the same hand-maintained-inventory failure this suite was
# written to kill, reproduced inside the suite itself.
EXPECT_PLUS=$((EXPECT_N + 1))    # cases 2/3/6b: one extra guard wired
EXPECT_MINUS=$((EXPECT_N - 1))   # case 4: one guard unavailable or unwired
# Case 3's mutation ships its own hand-typed list; this is ITS length, a
# property of the mutation and not of the engine, so it stays a literal.
STALE_N=14

banner
expect_fraction "1a  baseline: banner reports ${EXPECT_N}/${EXPECT_N}, matching hooks.json minus the announcer" \
    "${EXPECT_N}/${EXPECT_N}"

# 20 -> 22 on 2026-08-29: guard-publication-writes.sh and
# guard-publication-commits.sh were wired, making the public/private repo split
# machinery instead of judgment. This tripwire did its job — it went red on the
# change and made the new count something a human had to acknowledge rather than
# absorb.
#
# 23 -> 24 on 2026-08-29: guard-row-currency-commits.sh was wired, making "the
# working record still describes the work" checkable at every landing.
# 22 -> 23 on 2026-08-29: guard-ceo-todos-commits.sh was wired, making "waiting
# on the CEO" a checkable claim instead of an unfalsifiable one. The tripwire
# fired again, exactly as intended — this line is the acknowledgement.
#
# 23 -> 24 on 2026-08-30: guard-completeness-commits.sh was wired, so the
# publication-COMPLETENESS contract — is everything the public tree claims
# actually delivered — stops being a check somebody has to remember to run. It
# had been CI-and-memory only, and it was red on main for a day because after a
# merge the lander ran the suites and not the check. Third firing, third
# acknowledgement; the tripwire has now caught every guard added since it was
# written, which is the only evidence that it works.
# 23 -> 24 on 2026-08-30: guard-unresolved-claims.sh was wired on Stop — the
# first guard here that reads the orchestrator's own turn rather than the
# repository's state. Tripwire fired, acknowledged.
#
# 25 -> 26 on 2026-08-30: THREE guards were wired on one day by three
# engineers, and each of them bumped this line to 24 without knowing about
# the other two. Every one of those merges conflicted HERE. That is the whole
# value of a typed count beside a derived one: the derivation absorbs a new
# guard silently, and this line refuses to.
if [ "$REGISTERED_N" -eq 26 ]; then
    ok "1b  sanity: the shipped hooks.json registers 26 scripts, so the banner reads ${EXPECT_N}/${EXPECT_N}"
else
    bad "1b  sanity" "hooks.json registers $REGISTERED_N scripts — if that is a deliberate change, the banner should now read $EXPECT_N/$EXPECT_N and this line is the only thing to update"
fi

case "$OUT" in
    *ENFORCEMENT\ ACTIVE*) ok "1c  the adopted entity still gets ENFORCEMENT ACTIVE" ;;
    *) bad "1c  ENFORCEMENT ACTIVE" "not reported: ${OUT:0:200}" ;;
esac

# ===========================================================================
# 2. THE REGRESSION — a SEVENTEENTH guard, counted with no second edit.
#
# THIS IS THE CASE THE SUITE EXISTS FOR. Against the pre-fix hook — a typed
# list of 14 names — this sandbox announces "14/14 guards" no matter what is
# in hooks.json, which is exactly what femcboost was showing in production.
# ===========================================================================
wire_extra_guard
banner
expect_fraction "2a  one more wired guard is counted immediately: ${EXPECT_PLUS}/${EXPECT_PLUS}" "${EXPECT_PLUS}/${EXPECT_PLUS}"

case "$OUT" in
    *"?/?"*) bad "2b  the extra guard did not break the derivation" "inventory came back unknown" ;;
    *) ok "2b  the extra guard did not break the derivation" ;;
esac

# ===========================================================================
# 3. NEGATIVE CONTROL — prove case 2 can fail.
#
# A green tick means nothing if the assertion cannot go red. So the historical
# defect is rebuilt here on purpose: the derivation library is replaced by a
# HAND-TYPED inventory, the same 14 names the banner carried before this fix.
# The sandbox still has 17 scripts registered. If case 2's assertion is
# load-bearing, the banner must now be visibly, measurably wrong.
# ===========================================================================
cat >"$ENGINE/scripts/lib/registered-hooks.sh" <<'STALE'
#!/usr/bin/env bash
# MUTATION (test-only): the pre-fix banner inventory — a list a human typed.
registered_hook_scripts() {
    printf '%s\n' \
        guard-worktree-isolation.sh guard-definition-drift.sh reader-teammate-hint.sh \
        verify-agent-prompt.sh guard-main-checkout-writes.sh scan-secrets.sh \
        guard-resume-isolation.sh guard-bash-main-writes.sh guard-workflow-ban.sh \
        detect-nonnative-worktree.sh session-start-reap-worktrees.sh \
        snapshot-agent-definitions.sh teammate-idle-handoff.sh task-completed-handoff.sh
}
STALE
banner
if [ "$SYS_FRAC" = "${STALE_N}/${STALE_N} guards" ] && [ "$MODEL_FRAC" = "${STALE_N}/${STALE_N} guards" ]; then
    ok "3a  NEGATIVE CONTROL: a hand-typed inventory reports a full ${STALE_N}/${STALE_N} while ${EXPECT_PLUS} guards are wired — the historical defect, reproduced"
else
    bad "3a  NEGATIVE CONTROL" "expected the stale mutation to yield '${STALE_N}/${STALE_N} guards'; got operator='$SYS_FRAC' model='$MODEL_FRAC'. If this cannot be reproduced, case 2 is not proving anything."
fi
if [ "$SYS_FRAC" != "${EXPECT_PLUS}/${EXPECT_PLUS} guards" ]; then
    ok "3b  NEGATIVE CONTROL: case 2's assertion is load-bearing — it goes red under the mutation"
else
    bad "3b  NEGATIVE CONTROL" "the mutated banner still read ${EXPECT_PLUS}/${EXPECT_PLUS}, so case 2 passes for a reason unrelated to the derivation"
fi
restore

# ===========================================================================
# 4. THE TWO QUESTIONS MUST STAY SEPARATE.
#
# The denominator answers "what will the host load?", the numerator "which of
# those are actually on disk and executable?". A fix that collapsed them into
# one query would give a permanently full fraction that could never report a
# gap — which is exactly as useless as the stale list it replaced, and harder
# to notice. These cases construct real gaps.
# ===========================================================================
chmod -x "$ENGINE/scripts/hooks/scan-secrets.sh"
banner
expect_fraction "4a  SHORTFALL: a registered guard that is not executable drops the numerator only (${EXPECT_MINUS}/${EXPECT_N})" "${EXPECT_MINUS}/${EXPECT_N}"
restore

mv "$ENGINE/scripts/hooks/scan-secrets.sh" "$SANDBOX/scan-secrets.parked"
banner
expect_fraction "4b  SHORTFALL: a registered guard missing from disk drops the numerator only (${EXPECT_MINUS}/${EXPECT_N})" "${EXPECT_MINUS}/${EXPECT_N}"
mv "$SANDBOX/scan-secrets.parked" "$ENGINE/scripts/hooks/scan-secrets.sh"
restore

# 4c — the mirror image. A script sitting on disk that nobody wired enforces
# nothing, and must not inflate the count. Deriving from a directory listing
# instead of from hooks.json would get this wrong (and would have hidden the
# original defect completely, since the file was always present).
python3 - "$HOOKS_JSON" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    d = json.load(fh)
for entries in d["hooks"].values():
    for entry in entries:
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "scan-secrets.sh" not in h.get("command", "")]
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
PY
banner
expect_fraction "4c  a guard UNWIRED from hooks.json leaves the count (present on disk, loads nothing): ${EXPECT_MINUS}/${EXPECT_MINUS}" "${EXPECT_MINUS}/${EXPECT_MINUS}"
restore

# ===========================================================================
# 5. NO REASSURING NUMBER WHEN THE INVENTORY CANNOT BE READ.
#
# Fail loud, never skip. If hooks.json is gone or malformed the honest answer
# is "unknown", said out loud on both channels — never a plausible integer,
# and never a silently scraped one.
# ===========================================================================
mv "$HOOKS_JSON" "$SANDBOX/hooks.json.parked"
banner
if [ "$SYS_FRAC" = "?/? guards" ] && [ "$MODEL_FRAC" = "?/? guards" ]; then
    ok "5a  a missing hooks.json yields '?/?', not a number"
else
    bad "5a  missing hooks.json" "operator='$SYS_FRAC' model='$MODEL_FRAC'"
fi
case "$OUT" in
    *"could NOT be derived"*) ok "5b  and says so, loudly, in the announcement" ;;
    *) bad "5b  missing hooks.json warning" "no warning in: ${OUT:0:300}" ;;
esac
mv "$SANDBOX/hooks.json.parked" "$HOOKS_JSON"

printf '{ this is not json\n' >"$HOOKS_JSON"
banner
if [ "$SYS_FRAC" = "?/? guards" ]; then
    ok "5c  a MALFORMED hooks.json yields '?/?' too — no count scraped out of a file the host cannot load either"
else
    bad "5c  malformed hooks.json" "operator='$SYS_FRAC'"
fi
restore

# A SessionStart hook must never block, whatever it finds.
mv "$HOOKS_JSON" "$SANDBOX/hooks.json.parked"
( cd "$SANDBOX" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT -u RICHOS_ENGINE_ROOT \
    "RICHOS_ENTITY_ROOT=$ENTITY" bash "$ENGINE/scripts/hooks/engine-status.sh" </dev/null ) >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    ok "5d  still exits 0 — a broken inventory is announced, never blocking"
else
    bad "5d  exit code" "rc=$RC"
fi
mv "$SANDBOX/hooks.json.parked" "$HOOKS_JSON"
restore

# ===========================================================================
# 6. THE python3-ABSENT PATH.
#
# emit_context already carries a hand-escaping fallback, so "no interpreter" is
# a supported environment for this hook — which means the derivation has to
# survive it too. A fallback path is exactly where a quietly-dropped field, or
# a quietly-different answer, would never be noticed.
# ===========================================================================
NOPY="$SANDBOX/nopy-bin"
mkdir -p "$NOPY"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        b="${f##*/}"
        case "$b" in python|python3|python3.*) continue ;; esac
        [ -e "$NOPY/$b" ] || ln -s "$f" "$NOPY/$b" 2>/dev/null
    done
done
# The check runs in a CHILD shell on purpose. `command -v` in THIS shell would
# consult bash's command hash table, which already holds /opt/homebrew/bin/
# python3 from the case-2 setup above, and would report python3 "found" on a
# PATH that does not contain it — declaring the sandbox unbuildable while it was
# in fact correct. A fresh bash starts with an empty hash table.
if [ -x "$NOPY/bash" ] && ! PATH="$NOPY" "$NOPY/bash" -c 'command -v python3' >/dev/null 2>&1; then
    banner "PATH=$NOPY"
    expect_fraction "6a  without python3 the fraction is unchanged: ${EXPECT_N}/${EXPECT_N}" \
        "${EXPECT_N}/${EXPECT_N}"
    wire_extra_guard
    banner "PATH=$NOPY"
    expect_fraction "6b  without python3 one more wired guard is still counted: ${EXPECT_PLUS}/${EXPECT_PLUS}" "${EXPECT_PLUS}/${EXPECT_PLUS}"
    restore
else
    bad "6   python3-absent sandbox" "could not build a python3-free PATH; the fallback went untested"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf 'engine-status: %d/%d cases pass\n' "$PASS" "$PASS"
    exit 0
fi
printf 'engine-status: %d passed, %d FAILED\n' "$PASS" "$FAIL"
for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
