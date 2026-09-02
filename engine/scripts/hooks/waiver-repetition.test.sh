#!/usr/bin/env bash
#
# waiver-repetition.test.sh — the suite for notice-waiver-repetition.{sh,py}
#                             and scripts/waiver-repetition-lint.sh.
#
# ===========================================================================
# WHAT THIS SUITE IS FOR
# ===========================================================================
# The mechanism claims two things that pull in opposite directions:
#
#   A HATCH USED REPEATEDLY FOR THE SAME REASON IS SURFACED.
#   A SINGLE CONSIDERED WAIVER IS NOT.
#
# Either one alone is easy and useless. A checker that reports everything gets
# muted in a week; a checker that reports nothing passes every test it has. So
# every case here is TWO-SIDED — the positive case has a negative twin one
# variable away, and both are asserted.
#
# Every case in this file was run RED before it was run green, by breaking the
# shipped source rather than the fixture: the mutations are enumerated in
# scripts/hooks/waiver-repetition.mutation.sh, which re-derives that proof on
# demand instead of asking anyone to take this paragraph's word for it.
#
# Usage:  scripts/hooks/waiver-repetition.test.sh [-v]

set -uo pipefail
# ERREXIT DELIBERATELY OFF. Nearly every command in this suite is EXPECTED to
# exit non-zero — a flagged verdict is exit 1 and an unreadable target is exit
# 2 — so a stray `set -e` would end the run at the first case that works, which
# is precisely how a suite reports green over the half it never reached.

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t waiver-repetition.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib" "$REPO/.claude/state"

cp "$SRC_DIR/notice-waiver-repetition.sh" "$REPO/scripts/hooks/"
cp "$SRC_DIR/notice-waiver-repetition.py" "$REPO/scripts/hooks/"
chmod +x "$REPO/scripts/hooks/notice-waiver-repetition.sh"
for l in resolve-roots.sh resolve-main-checkout.sh seat-jurisdiction.sh \
         stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$REPO/scripts/lib/$l" 2>/dev/null || true
done
cp "$ENGINE_ROOT/scripts/waiver-repetition-lint.sh" "$REPO/scripts/"
chmod +x "$REPO/scripts/waiver-repetition-lint.sh"

HOOK="$REPO/scripts/hooks/notice-waiver-repetition.sh"
PY="$REPO/scripts/hooks/notice-waiver-repetition.py"
LINT="$REPO/scripts/waiver-repetition-lint.sh"
STATE="$REPO/.claude/state"

printf 'PROTECTED_PATHS="app"\n' > "$REPO/orchestration.config"

# ---------------------------------------------------------------------------
# THE SANDBOX'S OWN GUARDS. Discovery reads these, not a list — so the fixture
# has to contain real append sites for the scan to find, exactly as the engine
# does. One declares an escape hatch; one writes a plain event record and
# declares nothing. The pair is what proves the classifier is doing work
# rather than accepting everything.
# ---------------------------------------------------------------------------
cat > "$REPO/scripts/hooks/fixture-hatch-guard.sh" <<'GUARD'
#!/usr/bin/env bash
# fixture-hatch-guard.sh — refuses a thing, with one way through.
#
# The escape hatch is a live prompt line 'fixture-ack: <reason>'. Allowed and
# logged, never silent.
LOG_DIR="$ENTITY_ROOT/.claude/state"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '%s\tto=%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET" "$FIXTURE_ACK" \
    >>"$LOG_DIR/fixture-acks.log" 2>/dev/null || true
GUARD

cat > "$REPO/scripts/hooks/fixture-record-writer.sh" <<'REC'
#!/usr/bin/env bash
# fixture-record-writer.sh — writes down what happened.
#
# This file permits nothing and refuses nothing. Every spawn's name is
# appended so a later sweep can enumerate them; there is no way through it
# because there is nothing to get through.
printf '%s\n' "$NAME" >>"$TEAM_DIR/fixture-names.log" 2>/dev/null || true
REC

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
LEDGER="$STATE/fixture-acks.log"
TODAY="2026-09-02"

write_ledger() { : > "$LEDGER"; }
add() { # <YYYY-MM-DD> <subject> <reason>
    printf '%sT12:00:00Z\tto=%s\tfixture-ack: %s\n' "$1" "$2" "$3" >> "$LEDGER"
}

run_py() { # extra args...
    python3 "$PY" --engine-root "$REPO" --entity-root "$REPO" \
        --teams-root "$SANDBOX/no-teams" --today "$TODAY" "$@" 2>&1
}
run_hook() { # <session-id>
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop","transcript_path":"/dev/null"}' \
        "$1" "$REPO" | "$HOOK" 2>&1
}

echo "=== waiver-repetition.test.sh ==="
echo ""

# ===========================================================================
# 1 — THE QUIET SIDE. A single considered waiver says nothing.
# ===========================================================================
write_ledger
add 2026-09-02 alpha "one-off: the recipient is a live agent I verified by hand"
OUT="$(run_py --one-liner)"; RC=$?
say "1" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "1. ONE considered waiver is silent"
else
    bad "1. ONE considered waiver is silent" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 2 — still quiet at two. Two is that exception recurring, not a class.
# ===========================================================================
add 2026-09-01 beta "one-off: the recipient is a live agent I verified by hand"
OUT="$(run_py --one-liner)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "2. TWO waivers of the same reason are still silent"
else
    bad "2. TWO waivers of the same reason are still silent" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 3 — THE LOUD SIDE. The third use of the same reason is a false-positive
#     class, and it is named with its guard and its count.
# ===========================================================================
add 2026-08-31 gamma "one-off: the recipient is a live agent I verified by hand"
OUT="$(run_py --one-liner)"; RC=$?
say "3" "rc=$RC out=$OUT"
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q "fixture-hatch-guard.sh" \
   && printf '%s' "$OUT" | grep -q "3x one reason"; then
    ok "3. THREE waivers of one reason surface, naming the guard and the count"
else
    bad "3. THREE waivers of one reason surface, naming the guard and the count" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 4 — REWORDED EVERY TIME, and still one class. This is the case exact-match
#     grouping fails: the real ledger holds 226 distinct strings for what is
#     substantially two reasons.
# ===========================================================================
# The three lines below are the shape of the real 88-entry class, and no two
# of them are the same string — so exact-text grouping finds three groups of
# one and says nothing at all. That is the property under test.
write_repeated_class() {
    write_ledger
    add 2026-09-02 alpha "recipient is the currently-running teammate spawned this session with native isolation:worktree; background agents never appear in the session roster, so every write still lands in its own existing isolated worktree"
    add 2026-09-01 beta  "the recipient is a live background teammate spawned minutes ago with native isolation:worktree and absent from the session roster by design; every write still lands in its own existing isolated worktree"
    add 2026-08-30 gamma "recipient is a currently-running background agent holding native isolation:worktree - background agents are absent from the session roster, and every write lands in its own existing isolated worktree as before"
}
write_repeated_class
if [ "$(sort -u "$LEDGER" | wc -l | tr -d ' ')" -eq 3 ]; then
    ok "4a. the fixture is three DISTINCT strings — exact-text grouping would see nothing"
else
    bad "4a. the fixture is three DISTINCT strings — exact-text grouping would see nothing"
fi
OUT="$(run_py --one-liner)"; RC=$?
say "4" "rc=$RC out=$OUT"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "3x one reason"; then
    ok "4. the same reason RETYPED three ways is one class"
else
    bad "4. the same reason RETYPED three ways is one class" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 5 — its twin. Three waivers, three genuinely different reasons, silence.
#     Without this, case 4 passes for a checker that clusters everything.
# ===========================================================================
write_ledger
add 2026-09-02 alpha "recipient is an active background teammate holding an isolated worktree"
add 2026-09-01 beta  "cross-repository land notice required by the push gate before a merge"
add 2026-08-30 gamma "pure question with no file-bearing follow-up of any kind"
OUT="$(run_py --one-liner)"; RC=$?
say "5" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "5. three DIFFERENT reasons stay silent"
else
    bad "5. three DIFFERENT reasons stay silent" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 6 — INDEPENDENCE. Three uses of one reason on one day for ONE subject is one
#     act restated, not a class, and stays quiet.
# ===========================================================================
write_ledger
add 2026-09-02 alpha "the recipient is a live background agent holding its own worktree"
add 2026-09-02 alpha "the recipient is a live background agent holding its own worktree today"
add 2026-09-02 alpha "the recipient is a live background agent still holding its own worktree"
OUT="$(run_py --one-liner)"; RC=$?
say "6" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "6. one day, ONE subject: an act restated is not a class"
else
    bad "6. one day, ONE subject: an act restated is not a class" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 7 — its twin, one variable away: same day, same reason, THREE subjects.
#     Three independent acts excused identically is the ceo-todos-defers shape.
# ===========================================================================
write_ledger
add 2026-09-02 alpha "the recipient is a live background agent holding its own worktree"
add 2026-09-02 beta  "the recipient is a live background agent holding its own worktree today"
add 2026-09-02 gamma "the recipient is a live background agent still holding its own worktree"
OUT="$(run_py --one-liner)"; RC=$?
say "7" "rc=$RC out=$OUT"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "3 subjects"; then
    ok "7. one day, THREE subjects: three independent acts, surfaced"
else
    bad "7. one day, THREE subjects: three independent acts, surfaced" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 8 — THE FIX MUST BUY SILENCE. A class whose last use is outside the activity
#     window is history, not a live defect. Without this the notice becomes the
#     permanent line the operator learns to skip.
# ===========================================================================
write_ledger
add 2026-08-01 alpha "the recipient is a live background agent holding its own worktree"
add 2026-08-02 beta  "the recipient is a live background agent holding its own worktree today"
add 2026-08-03 gamma "the recipient is a live background agent still holding its own worktree"
OUT="$(run_py --one-liner)"; RC=$?
say "8" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "8. a class last used 30 days ago has aged out"
else
    bad "8. a class last used 30 days ago has aged out" "rc=$RC out=$OUT"
fi

# 8b — its twin: the identical class, one day inside the window, speaks.
write_ledger
add 2026-08-20 alpha "the recipient is a live background agent holding its own worktree"
add 2026-08-21 beta  "the recipient is a live background agent holding its own worktree today"
add 2026-08-22 gamma "the recipient is a live background agent still holding its own worktree"
OUT="$(run_py --one-liner)"; RC=$?
if [ "$RC" -eq 1 ]; then
    ok "8b. the same class 11 days old still speaks"
else
    bad "8b. the same class 11 days old still speaks" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 9 — THE DOUBLE-FIRE ARTIFACT. install.sh documents a host that fires a hook
#     twice, producing two byte-identical rows for ONE act. Counting them would
#     turn every pair into a class.
# ===========================================================================
write_ledger
for _i in 1 2; do
    printf '2026-09-02T12:00:00Z\tto=alpha\tfixture-ack: %s\n' \
        "the recipient is a live background agent holding its own worktree" >> "$LEDGER"
    printf '2026-09-01T12:00:00Z\tto=beta\tfixture-ack: %s\n' \
        "the recipient is a live background agent holding its own worktree today" >> "$LEDGER"
done
OUT="$(run_py --one-liner)"; RC=$?
say "9" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "9. four lines that are two acts double-fired stay silent"
else
    bad "9. four lines that are two acts double-fired stay silent" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 10 — DISCOVERY IS DERIVED FROM THE GUARDS. The hatch ledger is found because
#      a guard appends to it and declares a way through; the event record is
#      found and deliberately NOT treated as a hatch.
# ===========================================================================
write_ledger
add 2026-09-02 alpha "a single considered waiver"
OUT="$(run_py)"
say "10" "$OUT"
if printf '%s' "$OUT" | grep -q "fixture-acks.log" \
   && printf '%s' "$OUT" | grep -A3 "NOT CLASSIFIED AS A HATCH" | grep -q "fixture-names.log"; then
    ok "10. the hatch is derived from its guard; the plain record is not a hatch"
else
    bad "10. the hatch is derived from its guard; the plain record is not a hatch" "$OUT"
fi

# ===========================================================================
# 11 — A LEDGER NOBODY CLAIMS IS NAMED, NOT DROPPED. This is where a broken
#      deriver stops being invisible: a shorter list would otherwise read as a
#      cleaner report.
# ===========================================================================
printf '2026-09-02T12:00:00Z\tsomething\n' > "$STATE/orphan-acks.log"
OUT="$(run_py)"
if printf '%s' "$OUT" | grep -A3 "CLAIMED BY NO GUARD" | grep -q "orphan-acks.log"; then
    ok "11. a ledger no guard claims is reported as unattributed"
else
    bad "11. a ledger no guard claims is reported as unattributed" "$OUT"
fi
rm -f "$STATE/orphan-acks.log"

# ===========================================================================
# 12 — FINDING NOTHING IS A FAILURE, NOT AN ALL-CLEAR. The engine's own
#      history is a typed sandbox list that fell behind and turned a dead
#      scanner into a passing layer. A discovery scan that matches nothing must
#      never be indistinguishable from a clean engine.
# ===========================================================================
EMPTY="$SANDBOX/empty-engine"
mkdir -p "$EMPTY/scripts/hooks"
printf '#!/usr/bin/env bash\necho nothing\n' > "$EMPTY/scripts/hooks/inert.sh"
OUT="$(python3 "$PY" --engine-root "$EMPTY" --entity-root "$REPO" \
        --teams-root "$SANDBOX/no-teams" --today "$TODAY" 2>&1)"; RC=$?
say "12" "rc=$RC out=$OUT"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "BROKEN"; then
    ok "12. an engine with no append site at all is BROKEN, never all-clear"
else
    bad "12. an engine with no append site at all is BROKEN, never all-clear" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 13 — THE GROUPING CONSTANT IS NOT LOAD-BEARING. The verdict is asserted to
#      be identical across the whole measured range of the Jaccard threshold,
#      so a later edit cannot quietly make one number decide the answer.
# ===========================================================================
sweep_jaccard() { # <expected-rc>
    local want="$1" j rc all_ok=1 seen=""
    for j in 0.25 0.35 0.45 0.55; do
        set +e
        python3 "$PY" --engine-root "$REPO" --entity-root "$REPO" \
            --teams-root "$SANDBOX/no-teams" --today "$TODAY" --jaccard "$j" \
            --one-liner >/dev/null 2>&1
        rc=$?
        set +e
        seen="$seen $j=$rc"
        [ "$rc" -eq "$want" ] || all_ok=0
    done
    J_SEEN="$seen"
    return $(( 1 - all_ok ))
}

write_repeated_class
if sweep_jaccard 1; then
    ok "13. a repeated class is flagged at Jaccard 0.25 / 0.35 / 0.45 / 0.55 alike"
else
    bad "13. a repeated class is flagged at Jaccard 0.25 / 0.35 / 0.45 / 0.55 alike" "$J_SEEN"
fi

# 13b — the other direction, which is the one a loose threshold breaks: three
#       genuinely different reasons must stay silent even at 0.25, where
#       single-linkage chains hardest.
write_ledger
add 2026-09-02 alpha "recipient is an active background teammate holding an isolated worktree of its own"
add 2026-09-01 beta  "cross-repository land notice required by the push gate before a merge can complete"
add 2026-08-30 gamma "a pure question with no file-bearing follow-up of any kind is being sent here"
if sweep_jaccard 0; then
    ok "13b. three different reasons stay silent at all four thresholds, 0.25 included"
else
    bad "13b. three different reasons stay silent at all four thresholds, 0.25 included" "$J_SEEN"
fi

# ===========================================================================
# 14 — THE STATE KEY. Stable while the situation is, different when a class
#      doubles. This is what keeps the notice from being repeated under every
#      turn, which is the failure mode that gets a notice muted.
# ===========================================================================
write_repeated_class
K1="$(run_py --state-key)"
K2="$(run_py --state-key)"
add 2026-08-29 delta "recipient is a currently-running teammate spawned this session with native isolation:worktree; background agents never appear in the session roster, so every write still lands in its own existing isolated worktree"
add 2026-08-28 epsilon "the recipient is a live background teammate spawned minutes ago with native isolation:worktree, absent from the session roster by design; every write still lands in its own existing isolated worktree"
add 2026-08-27 zeta "recipient is a currently-running background agent with native isolation:worktree — background agents are absent from the session roster, and every write lands in its own existing isolated worktree"
K3="$(run_py --state-key)"
if [ "$K1" = "$K2" ] && [ "$K1" != "$K3" ] && [ "${K1#repeated:}" != "$K1" ]; then
    ok "14. the state key is stable while the situation is, and moves when it doubles"
else
    bad "14. the state key is stable while the situation is, and moves when it doubles" "K1=$K1 K2=$K2 K3=$K3"
fi

write_repeated_class

# ===========================================================================
# 15 — THE HOOK, END TO END. It says the sentence on the one channel measured
#      to reach the operator, and it does NOT block.
# ===========================================================================
OUT="$(run_hook waivtst1)"; RC=$?
say "15" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] \
   && printf '%s' "$OUT" | grep -q '"systemMessage"' \
   && printf '%s' "$OUT" | grep -q "REPEATED WAIVERS"; then
    ok "15. the Stop hook emits systemMessage and exits 0 — it reports, never blocks"
else
    bad "15. the Stop hook emits systemMessage and exits 0 — it reports, never blocks" "rc=$RC out=$OUT"
fi

# 15b — the second identical turn is silent. A line under every turn is a line
#       the eye skips, and this hook of all hooks must not become that.
OUT="$(run_hook waivtst1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "15b. the same condition on the next turn is silent"
else
    bad "15b. the same condition on the next turn is silent" "rc=$RC out=$OUT"
fi

# 15c — and when the hatches go quiet, the operator is told the story ended.
write_ledger
add 2026-09-02 alpha "a single considered waiver, and nothing else"
OUT="$(run_hook waivtst1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "clear again"; then
    ok "15c. a recovery is announced, so silence means no-change and not hope"
else
    bad "15c. a recovery is announced, so silence means no-change and not hope" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 16 — THE WRAPPER DECIDES NOTHING, AND SAYS SO. Five Stop wrappers in this
#      engine hand their entire verdict to a sibling .py; a wrapper that went
#      quiet without its analyzer would be wired, hashed, executable and
#      reading nothing.
# ===========================================================================
write_repeated_class
mv "$PY" "$PY.hidden"
OUT="$(run_hook waivtst2)"; RC=$?
mv "$PY.hidden" "$PY"
say "16" "rc=$RC out=$OUT"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "WATCH IS OFF"; then
    ok "16. no analyzer -> the hook announces it is off, never quiet"
else
    bad "16. no analyzer -> the hook announces it is off, never quiet" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 17 — NOT ADOPTED, NOT ANNOUNCED. The plugin loads in every directory on the
#      machine; a notice in each is the noise this engine already refused.
# ===========================================================================
UNADOPTED="$SANDBOX/unadopted"
mkdir -p "$UNADOPTED"
OUT="$(printf '{"session_id":"waivtst3","cwd":"%s","hook_event_name":"Stop","transcript_path":"/dev/null"}' \
        "$UNADOPTED" | "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "17. an unadopted repository gets no notice at all"
else
    bad "17. an unadopted repository gets no notice at all" "rc=$RC out=$OUT"
fi

# ===========================================================================
# 18 — THE LINT IS THE POSITIVE PROBE. Same code, same verdict, and it prints
#      what it looked at — so a silence with nothing behind it is visible.
# ===========================================================================
set +e
OUT="$("$LINT" "$REPO" --today "$TODAY" 2>&1)"; RC=$?
set +e
say "18" "rc=$RC out=$OUT"
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q "ESCAPE-HATCH LEDGERS DERIVED FROM THE GUARDS" \
   && printf '%s' "$OUT" | grep -q "SUSPECTED BROKEN GUARD: fixture-hatch-guard.sh"; then
    ok "18. the lint shows its work and agrees with the hook"
else
    bad "18. the lint shows its work and agrees with the hook" "rc=$RC out=$OUT"
fi

# 18b — exit 2 is reserved for "nothing was read", never shared with "clean".
set +e
"$LINT" "$SANDBOX/does-not-exist" >/dev/null 2>&1
RC=$?
set +e
if [ "$RC" -eq 2 ]; then
    ok "18b. an unreadable target exits 2, never 0"
else
    bad "18b. an unreadable target exits 2, never 0" "rc=$RC"
fi

# ===========================================================================
# 19 — REGISTERED. A guard on disk and in no hook table is a guard that never
#      runs, which is the failure this engine has shipped before.
# ===========================================================================
HOOKS_JSON="$ENGINE_ROOT/hooks/hooks.json"
if [ -f "$HOOKS_JSON" ] && grep -q "notice-waiver-repetition.sh" "$HOOKS_JSON"; then
    ok "19. notice-waiver-repetition.sh is registered on the Stop event in hooks/hooks.json"
else
    bad "19. notice-waiver-repetition.sh is registered on the Stop event in hooks/hooks.json" \
        "not found in $HOOKS_JSON"
fi

# ===========================================================================
# 20 — IT HAS NO ESCAPE HATCH. The one property that stops this mechanism
#      going the way of the 228: there is nothing to waive it with.
# ===========================================================================
# 20a — STRUCTURAL. It reads no configuration, so there is no key to set to
#       zero. Every other guard in this engine can be stood down; this one is
#       the exception, deliberately.
if ! grep -qE 'orchestration\.config|CHECK_[A-Z_]+' \
        "$REPO/scripts/hooks/notice-waiver-repetition.sh" \
        "$REPO/scripts/hooks/notice-waiver-repetition.py"; then
    ok "20a. the waiver watcher reads no config — there is no key to stand it down with"
else
    bad "20a. the waiver watcher reads no config — there is no key to stand it down with"
fi

# 20b — BEHAVIORAL, which is the half a grep cannot give. A marker written into
#       the waivers themselves changes nothing: the count is the count.
write_repeated_class
: > "$LEDGER"
add 2026-09-02 alpha "waiver-repetition-ack: known and accepted — recipient is the currently-running teammate spawned this session with native isolation:worktree; background agents never appear in the session roster, so every write still lands in its own existing isolated worktree"
add 2026-09-01 beta  "waiver-repetition-ack: known and accepted — the recipient is a live background teammate spawned minutes ago with native isolation:worktree and absent from the session roster by design; every write still lands in its own existing isolated worktree"
add 2026-08-30 gamma "waiver-repetition-ack: known and accepted — recipient is a currently-running background agent holding native isolation:worktree, absent from the session roster, and every write lands in its own existing isolated worktree as before"
OUT="$(run_py --one-liner)"; RC=$?
say "20b" "rc=$RC out=$OUT"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "3x one reason"; then
    ok "20b. a marker inside the waivers waives nothing — the count is still the count"
else
    bad "20b. a marker inside the waivers waives nothing — the count is still the count" "rc=$RC out=$OUT"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
