#!/usr/bin/env bash
# Mutation harness for guard-worktree-isolation.sh, CLAUSE 5 (the staffing gate
# added 2026-09-02 after an engine-wide audit was dispatched to `Explore`, a
# generic built-in, because a roster teammate would have needed a worktree
# created first).
#
# WHY THIS FILE EXISTS AT ALL. Clause 5's suite is 37 green cases. Green is not
# evidence: on 2026-09-02 five separate checks in this engine were found green
# over code that never ran, including a mutation harness that killed 11 of 18
# mutants because its sandboxes lacked a dependency, so the guard REFUSED TO
# START and that read exactly like a guard catching the mutation. Each mutant
# below therefore asserts THREE things, not one:
#   (a) the mutation actually applied     -- a sed that matched nothing gives a
#       green run that looks like a green run;
#   (b) the guard STILL STARTS AND RUNS   -- a control payload (a well-formed
#       isolated roster spawn, which no clause-5 mutant should touch) must still
#       exit 0. A guard that refuses to start exits 2 on everything and would
#       "catch" every mutation while proving nothing;
#   (c) the suite goes red AT THE NAMED CASES, not merely somewhere.
# There is no sandbox copy anywhere in this harness: every mutant runs the REAL
# file from the REAL engine root, so the missing-dependency trap cannot recur.
#
# BOTH DIRECTIONS ARE MUTATED. Under-blocking is the obvious one (M1-M4, M8,
# M9, M10). Over-blocking has its own mutants (M5, M6, M7) because the cheapest
# way to make any guard "pass" is to make it refuse everything, and the cheapest
# way to kill a false positive is to disable the check -- an over-broad staffing
# gate that fires on a statusline change is how a defense becomes a nuisance and
# then a formality typed by reflex.
#
# ONE FINDING FROM THIS HARNESS'S OWN FIRST RUN, kept here because it is the
# whole argument for writing it: M9 originally mutated the `: "${GENERIC_AGENT_
# TYPES:=general-purpose}"` DEFAULT and the suite stayed green. The guard sources
# the entity's orchestration.config BEFORE that line and the config sets the
# variable explicitly, so the default is dead code in any adopted repository.
# The mutant had proven nothing and looked like it had proven the opposite.
set -uo pipefail
ENG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ENG/scripts/hooks/guard-worktree-isolation.sh"
SUITE="$ENG/scripts/hooks/guard-worktree-isolation.test.sh"
BAK="$(mktemp)"
cp "$GUARD" "$BAK"
restore() { cp "$BAK" "$GUARD"; }
trap 'restore; rm -f "$BAK"' EXIT

PROVEN=0; UNPROVEN=0
BASE_MD5="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"

# applied <id> <desc> — returns 1 (and scores UNPROVEN) if the file is unchanged.
applied() {
    local id="$1" desc="$2" after
    after="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"
    if [ "$after" = "$BASE_MD5" ]; then
        printf 'UNPROVEN  %-4s %s  <- MUTATION DID NOT APPLY\n' "$id" "$desc"
        UNPROVEN=$((UNPROVEN+1)); return 1
    fi
    return 0
}

# alive <id> <desc> — the mutated guard must still START and run a control
# payload to a normal verdict. This is the arm that would have caught the
# 11-of-18 incident: a guard that cannot start exits 2 on everything.
alive() {
    local id="$1" desc="$2" rc
    if ! bash -n "$GUARD" >/dev/null 2>&1; then
        printf 'UNPROVEN  %-4s %s  <- mutant does not PARSE; a syntax error is not a mutation\n' "$id" "$desc"
        UNPROVEN=$((UNPROVEN+1)); return 1
    fi
    printf '{"tool_name":"Agent","session_id":"mut00000-0000-4000-8000-000000000000","tool_input":{"subagent_type":"dev","name":"dev-sonnet-alive","isolation":"worktree","prompt":"control payload"}}' \
        | RICHOS_ENTITY_ROOT="$ENG" "$GUARD" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'UNPROVEN  %-4s %s  <- mutant guard REFUSED THE CONTROL SPAWN (rc=%s): it is not running, it is dying\n' "$id" "$desc" "$rc"
        UNPROVEN=$((UNPROVEN+1)); return 1
    fi
    return 0
}

# check <id> <desc> <expected-red-case-regexes...>
check() {
    local id="$1" desc="$2"; shift 2
    local out rc missing=""
    out="$("$SUITE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'UNPROVEN  %-4s %s  <- suite still GREEN\n' "$id" "$desc"
        UNPROVEN=$((UNPROVEN+1)); return
    fi
    local want
    for want in "$@"; do
        printf '%s' "$out" | grep -qE "^  FAIL  ${want}" || missing="$missing ${want}"
    done
    if [ -z "$missing" ]; then
        printf 'PROVEN    %-4s %s\n' "$id" "$desc"
        PROVEN=$((PROVEN+1))
    else
        printf 'UNPROVEN  %-4s %s  <- red but NOT at:%s\n' "$id" "$desc" "$missing"
        printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/            /'
        UNPROVEN=$((UNPROVEN+1))
    fi
}

echo "=== guard-worktree-isolation CLAUSE 5 mutation harness ==="

# --- M1: the whole staffing gate deleted — the state the engine shipped in on
# the morning of 2026-09-02, when READONLY_ALLOWLIST's isolation exemption was
# read as a staffing permission and nothing refused the Explore dispatch.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
start = s.index("NEEDS_STAFFING_HATCH=0\n")
end = s.index("# Read-only agent types are exempt from the teammate contract")
open(p, "w", encoding="utf-8").write(s[:start] + s[end:])
PY
if applied M1 "the staffing gate deleted entirely (the pre-fix engine)" \
   && alive M1 "the staffing gate deleted entirely (the pre-fix engine)"; then
    check M1 "the staffing gate deleted entirely (the pre-fix engine)" \
        "Explore with NO generic-agent: line -> BLOCKED" \
        "Plan with NO generic-agent: line -> BLOCKED" \
        "general-purpose, isolated \+ well-named, NO hatch -> BLOCKED" \
        "undeclared allowlist type waved through"
fi

# --- M2: the hatch is required, but ANY non-empty text satisfies it — the
# "escape hatch degrades into a formality" failure. A bare marker is still
# empty, so this mutant is caught only by the quality cases.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("MIN_CHARS = 30", "MIN_CHARS = 0", 1)
s = s.replace("MIN_WORDS = 5", "MIN_WORDS = 0", 1)
s = s.replace("MIN_CONTENT = 3", "MIN_CONTENT = 0", 1)
assert "\n    elif speed:\n" in s, "speed arm anchor not found"
s = s.replace("\n    elif speed:\n", "\n    elif False:\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
if applied M2 "any non-empty reason accepted (hatch as formality)" \
   && alive M2 "any non-empty reason accepted (hatch as formality)"; then
    check M2 "any non-empty reason accepted (hatch as formality)" \
        "'generic-agent: because' -> BLOCKED" \
        "'generic-agent: n/a' -> BLOCKED" \
        "'generic-agent: -' -> BLOCKED" \
        "a long-but-empty reason \(stopwords only\) -> BLOCKED" \
        "reason 'faster to dispatch' -> BLOCKED"
fi

# --- M3: the SPEED/CONVENIENCE arm alone removed. This is the incident's own
# rationale ("it let him dispatch immediately"), so it gets a mutant to itself
# rather than sharing M2's.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
assert "\n    elif speed:\n" in s, "speed arm anchor not found"
open(p, "w", encoding="utf-8").write(s.replace("\n    elif speed:\n", "\n    elif False:\n", 1))
PY
if applied M3 "the speed/convenience refusal removed" \
   && alive M3 "the speed/convenience refusal removed"; then
    check M3 "the speed/convenience refusal removed" \
        "reason 'faster to dispatch' -> BLOCKED" \
        "reason 'saves time' -> BLOCKED" \
        "reason 'more convenient' -> BLOCKED" \
        "the speed refusal names create-teammate-worktree.sh as the answer"
fi

# --- M4: the substance (content-word) floor alone removed, so a long string of
# stopwords passes as a justification.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2 = s.replace("MIN_CONTENT = 3", "MIN_CONTENT = 0", 1)
assert s2 != s, "MIN_CONTENT anchor not found"
open(p, "w", encoding="utf-8").write(s2)
PY
if applied M4 "the substantive-word floor removed (filler passes)" \
   && alive M4 "the substantive-word floor removed (filler passes)"; then
    check M4 "the substantive-word floor removed (filler passes)" \
        "a long-but-empty reason \(stopwords only\) -> BLOCKED" \
        "the filler refusal says so in those terms"
fi

# --- M5 (OVER-BLOCKING): the harness-utility exemption removed, so a
# statusline change now demands a staffing justification. A defense that fires
# on harness configuration becomes a nuisance, then a formality, then noise.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'if ! _type_in_set "$SUBAGENT_TYPE" "$HARNESS_UTILITY_TYPES"; then'
assert old in s, "harness-utility anchor not found"
open(p, "w", encoding="utf-8").write(s.replace(old, "if true; then", 1))
PY
if applied M5 "harness utilities lose their exemption (over-blocking)" \
   && alive M5 "harness utilities lose their exemption (over-blocking)"; then
    check M5 "harness utilities lose their exemption (over-blocking)" \
        "statusline-setup needs NO hatch \(harness utility\)" \
        "claude-code-guide needs NO hatch \(harness utility\)" \
        "read-only type claude-code-guide" \
        "read-only type statusline-setup"
fi

# --- M6 (INDEPENDENCE): the staffing gate is allowed to swallow the ISOLATION
# exemption — an allowlisted type that PASSES clause 5 is now also required to
# be isolated. The two properties must hold independently; this mutant is the
# only thing that proves the suite would notice if they were collapsed.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = """for a in $READONLY_ALLOWLIST; do
  if [ "$SUBAGENT_TYPE" = "$a" ]; then
    exit 0
  fi
done"""
assert old in s, "readonly early-exit anchor not found"
new = """for a in $READONLY_ALLOWLIST; do
  if [ "$SUBAGENT_TYPE" = "$a" ] && [ "$ISOLATION" = "worktree" ]; then
    exit 0
  fi
done"""
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
if applied M6 "the isolation exemption folded into the staffing gate" \
   && alive M6 "the isolation exemption folded into the staffing gate"; then
    check M6 "the isolation exemption folded into the staffing gate" \
        "read-only type Explore, no isolation/name \(isolation exemption holds\)" \
        "read-only type Plan, no isolation/name \(isolation exemption holds\)" \
        "Explore WITH a well-formed generic-agent: reason -> allowed"
fi

# --- M7 (OVER-BLOCKING): the staffing gate fires for EVERY subagent_type, so
# roster teammates are taxed too. "Make it stricter until it cannot be wrong"
# is the other way to kill a guard, and it is the way that gets it deleted.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = """  if _type_in_set "$SUBAGENT_TYPE" "$READONLY_ALLOWLIST" \\
     || _type_in_set "$SUBAGENT_TYPE" "$GENERIC_AGENT_TYPES"; then
    NEEDS_STAFFING_HATCH=1
  fi"""
assert old in s, "membership anchor not found"
open(p, "w", encoding="utf-8").write(s.replace(old, "  NEEDS_STAFFING_HATCH=1", 1))
PY
if applied M7 "the gate fires for every type, roster included (over-blocking)"; then
    # NOTE: `alive` is deliberately NOT called here — this mutant's whole point
    # is that the control roster spawn stops passing, which is exactly what
    # `alive` refuses. The suite check below is the evidence instead.
    check M7 "the gate fires for every type, roster included (over-blocking)" \
        "roster-style type, isolated, no hatch -> allowed \(clause 5 inert\)" \
        "roster-style type, isolated, no hatch, second name -> allowed" \
        "a roster-type refusal is the ISOLATION message, never the staffing one"
fi

# --- M8: the accepted hatch stops being logged. A waiver nobody can count is a
# waiver that becomes a habit invisibly.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '>>"$GA_LOG_DIR/generic-agent-dispatches.log" 2>/dev/null || true'
assert old in s, "log anchor not found"
open(p, "w", encoding="utf-8").write(s.replace(old, ">/dev/null 2>&1 || true", 1))
PY
if applied M8 "the accepted-hatch log removed" \
   && alive M8 "the accepted-hatch log removed"; then
    check M8 "the accepted-hatch log removed" \
        "accepted generic-agent: hatch was NOT logged"
fi

# --- M9: the GENERIC_AGENT_TYPES ARM removed from the membership test,
# reopening the obvious detour — `general-purpose` is file-capable and NOT on
# the read-only allowlist, so before clause 5 it passed the whole contract on
# isolation and a name alone. Mutating the `:=` default instead proves nothing
# (see this file's header).
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = """  if _type_in_set "$SUBAGENT_TYPE" "$READONLY_ALLOWLIST" \\
     || _type_in_set "$SUBAGENT_TYPE" "$GENERIC_AGENT_TYPES"; then"""
assert old in s, "GENERIC_AGENT_TYPES membership anchor not found"
new = '  if _type_in_set "$SUBAGENT_TYPE" "$READONLY_ALLOWLIST"; then'
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
if applied M9 "the general-purpose detour reopened" \
   && alive M9 "the general-purpose detour reopened"; then
    check M9 "the general-purpose detour reopened" \
        "general-purpose, isolated \+ well-named, NO hatch -> BLOCKED"
fi

# --- M10: the refusal stops NAMING THE ALTERNATIVE. It still blocks, so every
# exit-code case stays green; only the message cases notice. A refusal that
# says only "no" gets routed around instead of obeyed.
# ("create-teammate-worktree.sh" is deliberately NOT asserted here: it also
# appears in the speed refusal's own REASON text, which this mutant leaves
# intact, so that assertion is M3's.)
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
start = s.index('      echo "  WHY THIS IS REFUSED, not merely discouraged:"')
end = s.index('      echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"')
open(p, "w", encoding="utf-8").write(s[:start] + '      echo "  Refused."\n' + s[end:])
PY
if applied M10 "the refusal no longer names the alternative" \
   && alive M10 "the refusal no longer names the alternative"; then
    check M10 "the refusal no longer names the alternative" \
        "refusal names the roster teammate as the fix" \
        "refusal says a generic agent is invisible in the team display" \
        "refusal says a generic agent leaves no commit" \
        "refusal names the hatch line by its exact shape" \
        "refusal separates the isolation exemption from the staffing question"
fi

# --- M11 (OVER-BLOCKING, the speed check's OWN false-positive arm): the
# speed/convenience pattern is widened to catch a bare mention of "worktree".
# That is the tempting version -- the incident's reason was "a roster teammate
# would have needed a worktree set up first" -- and it is wrong, because a
# genuine justification may name worktrees innocently ("no worktree is needed
# for a read-only sweep"). Refusing that is a false positive on a TRUE reason,
# which is how an escape hatch stops being usable and starts being lied to.
restore
python3 - "$GUARD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'r"(fastest|faster|quickest|quicker|save[sd]?\\s+time|saving\\s+time|"'
assert old in s, "speed pattern anchor not found"
new = 'r"(worktree|fastest|faster|quickest|quicker|save[sd]?\\s+time|saving\\s+time|"'
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
if applied M11 "the speed pattern widened to catch any mention of worktrees" \
   && alive M11 "the speed pattern widened to catch any mention of worktrees"; then
    check M11 "the speed pattern widened to catch any mention of worktrees" \
        "a genuine reason mentioning worktrees is NOT read as a speed excuse"
fi

# --- DELIBERATE PINS (no mutant, and that is the honest answer). Three cases
# hold under every mutation above because they assert that the NORMAL path is
# still normal, and every mutant here changes an ABNORMAL path:
#   - "the hatch is recognized anywhere in the prompt, not only on line 1"
#   - "the hatch tolerates leading whitespace"
#   - "general-purpose, isolated + well-named, WITH hatch -> allowed"
# They are regression pins on the grep anchor and on the hatch actually
# working, not claims of mutation coverage. Naming them here is cheaper than
# letting a future reader assume a silent green means a proven check.

restore
echo ""
echo "=== summary: $PROVEN proven load-bearing, $UNPROVEN unproven ==="
# The tree must be byte-identical to where we started, or a mutation harness is
# a source of drift instead of a source of evidence.
FINAL_MD5="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"
if [ "$FINAL_MD5" != "$BASE_MD5" ]; then
    echo "ERROR: the guard was NOT restored byte-for-byte (md5 $FINAL_MD5 != $BASE_MD5)" >&2
    exit 1
fi
echo "guard restored byte-for-byte (md5 $FINAL_MD5)"
[ "$UNPROVEN" -eq 0 ] || exit 1
exit 0
