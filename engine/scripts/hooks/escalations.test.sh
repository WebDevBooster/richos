#!/usr/bin/env bash
#
# escalations.test.sh — the suite for the escalation channel:
#                       scripts/lib/escalations.{py,sh}, scripts/escalate.sh,
#                       scripts/hooks/notice-escalations.sh and
#                       scripts/hooks/session-start-escalations.sh.
#
# ===========================================================================
# WHAT THIS SUITE HAS TO PROVE, AND WHY EACH HALF EXISTS
# ===========================================================================
# The claim is not "a file was written". THAT WAS THE OLD MECHANISM, and it
# worked perfectly: on 2026-09-02 two teammates wrote `BLOCKED.md`, committed
# it, and the files sat unread until a worktree cleanup found them on
# 2026-09-04. A test that asserted "the escalation file exists" would have been
# green through the entire incident.
#
# So every case here asserts ARRIVAL, and the two hardest ones are built to
# reproduce the incident rather than the happy path:
#
#   CASE 3   THE BRANCH IS NEVER MERGED AND THE WORKTREE IS DELETED. This is
#            the incident, mechanically. If the escalation still arrives in
#            full, delivery does not depend on a merge — which is the whole
#            defect being fixed.
#   CASE 6   NOBODY ACKNOWLEDGES IT AND A DAY PASSES. If the notice went quiet
#            after announcing once, this mechanism would have reproduced the
#            two-day silence with a better audit trail. The age bucket must
#            make it speak again, LOUDER, and a new session must re-announce
#            it from scratch.
#
# TWO-SIDED THROUGHOUT. A checker that reports everything gets muted in a week;
# a checker that reports nothing passes every test it has. So the positive case
# has a negative twin one variable away, and case 12 is an explicit NEGATIVE
# CONTROL that rebuilds a mechanism which reports "clear" over an outstanding
# escalation — if the suite cannot go red there, cases 4 and 5 prove nothing.
#
# Usage:  scripts/hooks/escalations.test.sh [-v]

set -uo pipefail
# ERREXIT DELIBERATELY OFF. Most commands here are EXPECTED to exit non-zero —
# `list` is exit 1 when something is outstanding, a refused `raise` is exit 2 —
# so a stray `set -e` would end the run at the first case that works, which is
# how a suite reports green over the half it never reached.

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

SANDBOX="$(cd "$(mktemp -d -t escalations.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- the engine copy under test --------------------------------------------
ENG="$SANDBOX/engine"
mkdir -p "$ENG/scripts/hooks" "$ENG/scripts/lib" "$ENG/.claude/state"
cp "$SRC_DIR/notice-escalations.sh" "$SRC_DIR/session-start-escalations.sh" "$ENG/scripts/hooks/"
chmod +x "$ENG/scripts/hooks/notice-escalations.sh" "$ENG/scripts/hooks/session-start-escalations.sh"
cp "$ENGINE_ROOT/scripts/escalate.sh" "$ENG/scripts/"
chmod +x "$ENG/scripts/escalate.sh"
for l in escalations.py escalations.sh resolve-roots.sh resolve-main-checkout.sh \
         seat-jurisdiction.sh stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$ENG/scripts/lib/$l" 2>/dev/null || true
done
# The adoption marker. Without it every hook here stands down, and a suite that
# ran against a stood-down engine would be green over nothing at all.
printf 'PROTECTED_PATHS="app"\n' > "$ENG/orchestration.config"

ESCALATE="$ENG/scripts/escalate.sh"
STOP_HOOK="$ENG/scripts/hooks/notice-escalations.sh"
START_HOOK="$ENG/scripts/hooks/session-start-escalations.sh"

# --- the ledger under test, outside every repository ------------------------
LEDGER="$SANDBOX/state/escalations.jsonl"
export RICHOS_ESCALATION_LEDGER="$LEDGER"
# Every hook resolves the sandbox engine as its own governed root.
export RICHOS_ENTITY_ROOT="$ENG"

# --- THE TEAMMATE'S WORKTREE — a real git repository on its own branch -------
# Not a directory pretending to be one. The claim under test is about a branch
# that is never merged, so there has to be a branch.
WT="$SANDBOX/agent-worktree"
mkdir -p "$WT/docs"
git init -q "$WT" 2>/dev/null
git -C "$WT" config user.email "t@example.invalid" 2>/dev/null
git -C "$WT" config user.name "Test" 2>/dev/null
git -C "$WT" checkout -q -b worktree-zach-opus-e1demo 2>/dev/null
printf 'seed\n' > "$WT/docs/seed.md"
git -C "$WT" add -A 2>/dev/null
git -C "$WT" commit -q -m "seed" 2>/dev/null

stop_payload() { # <session-id>
    printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"%s","transcript_path":""}' \
        "$1" "$ENG"
}

# ===========================================================================
# 1. RAISE — one call, and everything mechanical is derived
# ===========================================================================
OUT="$("$ESCALATE" raise \
    --title "A premise in my brief is contradicted by the evidence" \
    --state work-complete --for ceo \
    --question "Do I follow the brief or the evidence? Only you can decide that." \
    --tried "read both records end to end and diffed them against the tree" \
    --meanwhile "finished every part of the row that does not depend on the answer" \
    --worktree "$WT" --teammate zach-opus-e1demo 2>&1)"
RC=$?
say "1 raise" "$OUT"
if [ "$RC" -eq 0 ]; then ok "1a  raise exits 0"; else bad "1a  raise exits 0" "rc=$RC: $OUT"; fi
ID="$(printf '%s\n' "$OUT" | sed -n 's/^escalation RAISED: //p' | head -1)"
case "$ID" in
    esc-*) ok "1b  it returns a derived id ($ID)" ;;
    *)     bad "1b  derived id" "got '$ID'" ;;
esac
if [ -f "$LEDGER" ] && grep -q '"event": "Escalation"' "$LEDGER"; then
    ok "1c  a ledger row was appended at $LEDGER"
else
    bad "1c  ledger row" "nothing at $LEDGER"
fi
# The fields nobody typed.
for f in '"teammate": "zach-opus-e1demo"' '"branch": "worktree-zach-opus-e1demo"' '"state": "work-complete"' '"for": "ceo"'; do
    if grep -qF "$f" "$LEDGER"; then ok "1d  derived from the workspace: $f"
    else bad "1d  derived field" "missing $f from $LEDGER"; fi
done
# THE ROOT IS CLOSED (ceo-decisions.md 27). The record goes under
# docs/verification/ and the worktree root must be untouched.
if [ -f "$WT/BLOCKED.md" ]; then
    bad "1e  no new root entry" "raise wrote BLOCKED.md at the repository root — the ruling this replaces"
else
    ok "1e  nothing was written at the repository root"
fi
REC="$(find "$WT/docs/verification/escalations" -name '*.md' 2>/dev/null | head -1)"
if [ -n "$REC" ]; then ok "1f  the record file went to docs/verification/escalations/"
else bad "1f  record file" "not found under $WT/docs/verification/escalations"; fi

# ===========================================================================
# 2. THE STOP HOOK ANNOUNCES IT — same session, one turn later
# ===========================================================================
S1="aaaaaaaa-1111-2222-3333-444444444444"
OUT="$(stop_payload "$S1" | "$STOP_HOOK" 2>&1)"
say "2 stop hook" "$OUT"
case "$OUT" in
    *systemMessage*) ok "2a  the Stop hook emits on the channel measured to reach the operator" ;;
    *) bad "2a  systemMessage" "got: $OUT" ;;
esac
case "$OUT" in
    *"ESCALATION OUTSTANDING"*) ok "2b  it names the condition" ;;
    *) bad "2b  names the condition" "got: $OUT" ;;
esac
case "$OUT" in
    *zach-opus-e1demo*) ok "2c  it names WHO raised it" ;;
    *) bad "2c  names the teammate" "got: $OUT" ;;
esac
case "$OUT" in
    *"for the CEO"*) ok "2d  it says the answer belongs to the CEO" ;;
    *) bad "2d  names the audience" "got: $OUT" ;;
esac
# THE STALL DISTINCTION. Both originals said "this is not a stall"; a channel
# that reads every escalation as a failure teaches teammates not to use it.
case "$OUT" in
    *"none is a stall"*) ok "2e  it says explicitly that this is NOT a stall" ;;
    *) bad "2e  not-a-stall" "got: $OUT" ;;
esac

# ===========================================================================
# 3. THE INCIDENT, MECHANICALLY: the branch is never merged and the worktree
#    is DELETED. If the escalation still arrives, delivery does not depend on
#    a merge — which is the entire defect.
# ===========================================================================
MERGE_BASE="$SANDBOX/main-checkout"
git init -q "$MERGE_BASE" 2>/dev/null
rm -rf "$WT"
if [ -d "$WT" ]; then bad "3a  worktree removed" "still present"; else ok "3a  the teammate's worktree is GONE (branch never merged)"; fi

OUT="$("$ESCALATE" list 2>&1)"
RC=$?
say "3 list after deletion" "$OUT"
if [ "$RC" -eq 1 ]; then ok "3b  list still reports it outstanding (exit 1)"; else bad "3b  list exit" "rc=$RC"; fi
case "$OUT" in
    *"Do I follow the brief or the evidence"*)
        ok "3c  THE WHOLE QUESTION SURVIVED the worktree that raised it" ;;
    *)  bad "3c  question survives" "got: $OUT" ;;
esac
case "$OUT" in
    *"read both records end to end"*) ok "3d  what was already tried survived too" ;;
    *) bad "3d  tried survives" "got: $OUT" ;;
esac
OUT="$(stop_payload "$S1" | "$STOP_HOOK" 2>&1)"
say "3 stop hook after deletion" "$OUT"
# Same session, same state key, so silence here is CORRECT de-duplication —
# what matters is that the predicate still sees it, which case 3b just proved,
# and that a NEW session speaks (case 7).
if [ -z "$OUT" ]; then ok "3e  same session, unchanged state: it does not repeat itself"
else ok "3e  same session: emitted again (state changed) — $OUT"; fi

# ===========================================================================
# 4. THE SessionStart HALF — the escalation reaches the MODEL's context, in
#    full, with nothing merged and no worktree left to read.
# ===========================================================================
OUT="$("$START_HOOK" </dev/null 2>&1)"
say "4 session start" "$OUT"
CTX="$(printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception:
    print("")' 2>/dev/null)"
SYS="$(printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("systemMessage",""))
except Exception:
    print("")' 2>/dev/null)"
case "$CTX" in
    *"Do I follow the brief or the evidence"*)
        ok "4a  the model's context carries the teammate's own question, verbatim" ;;
    *)  bad "4a  additionalContext" "got: $CTX" ;;
esac
case "$CTX" in
    *"$ID"*) ok "4b  it carries the id to acknowledge" ;;
    *) bad "4b  id in context" "got: $CTX" ;;
esac
case "$CTX" in
    *"NONE of these is a stall"*) ok "4c  and it says, to the model, that this is not a stall" ;;
    *) bad "4c  not-a-stall in context" "got: $CTX" ;;
esac
case "$CTX" in
    *"nothing has to be"*merged*) ok "4d  it states that nothing has to be merged to read it" ;;
    *) bad "4d  no-merge claim" "got: $CTX" ;;
esac
case "$SYS" in
    *"ESCALATION(S) OUTSTANDING"*) ok "4e  and the operator gets a line too — both channels, always" ;;
    *) bad "4e  systemMessage at SessionStart" "got: $SYS" ;;
esac

# ===========================================================================
# 5. THE NEGATIVE TWIN: an EMPTY ledger must produce SILENCE on both hooks.
#    Without this, cases 2 and 4 pass for a mechanism that shouts constantly.
# ===========================================================================
EMPTY="$SANDBOX/state/empty.jsonl"
OUT="$(RICHOS_ESCALATION_LEDGER="$EMPTY" "$START_HOOK" </dev/null 2>&1)"
if [ -z "$OUT" ]; then ok "5a  empty ledger: SessionStart says nothing"
else bad "5a  empty ledger silence" "got: $OUT"; fi
OUT="$(RICHOS_ESCALATION_LEDGER="$EMPTY" stop_payload "bbbbbbbb-0000-0000-0000-000000000000" | RICHOS_ESCALATION_LEDGER="$EMPTY" "$STOP_HOOK" 2>&1)"
if [ -z "$OUT" ]; then ok "5b  empty ledger: the Stop hook says nothing"
else bad "5b  empty ledger silence" "got: $OUT"; fi

# ===========================================================================
# 6. IT GETS LOUDER — the half that stops this becoming the two-day silence
#    with better paperwork. Backdate the row and the same session speaks again.
# ===========================================================================
python3 - "$LEDGER" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
p = sys.argv[1]
rows = [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]
old = (datetime.now(timezone.utc) - timedelta(hours=25)).replace(microsecond=0)
for r in rows:
    if r.get("event") == "Escalation":
        r["raised"] = old.isoformat().replace("+00:00", "Z")
with open(p, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
OUT="$(stop_payload "$S1" | "$STOP_HOOK" 2>&1)"
say "6 aged" "$OUT"
case "$OUT" in
    *"1d old"*)
        ok "6a  SAME SESSION, ALREADY ANNOUNCED, IT SPEAKS AGAIN because the age bucket crossed 24h" ;;
    *)  bad "6a  age bucket re-announce" "got: $OUT" ;;
esac
# And a further turn at the same age is quiet again — the loudness is a
# transition, not a nag. A hook that repeated every turn would be muted.
OUT2="$(stop_payload "$S1" | "$STOP_HOOK" 2>&1)"
if [ -z "$OUT2" ]; then ok "6b  and it goes quiet again at the same age — loudness is a transition, not a nag"
else bad "6b  quiet at the same age" "got: $OUT2"; fi

# ===========================================================================
# 7. A NEW SESSION RE-ANNOUNCES FROM SCRATCH. This is the case the incident
#    turned on: the session that could have surfaced them ENDED.
# ===========================================================================
S2="cccccccc-9999-8888-7777-666666666666"
OUT="$(stop_payload "$S2" | "$STOP_HOOK" 2>&1)"
say "7 new session" "$OUT"
case "$OUT" in
    *"ESCALATION OUTSTANDING"*) ok "7a  a NEW session is told about an escalation raised in an old one" ;;
    *) bad "7a  new session re-announce" "got: $OUT" ;;
esac

# ===========================================================================
# 8. THE ACK CLOSES IT — and only a real one does
# ===========================================================================
OUT="$("$ESCALATE" ack "$ID" --disposition "too short" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "8a  a one-word disposition is REFUSED (a dismissal wearing a ledger row)"
else bad "8a  short disposition refused" "rc=$RC: $OUT"; fi
OUT="$("$ESCALATE" ack "esc-does-not-exist" --disposition "this id was never raised by anyone at all" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "8b  acknowledging an id nobody raised is REFUSED"
else bad "8b  unknown id refused" "rc=$RC: $OUT"; fi
OUT="$("$ESCALATE" ack "$ID" --disposition "Put it to the CEO; he ruled the evidence wins and the brief was stale." 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then ok "8c  a real ack is recorded"
else bad "8c  ack recorded" "rc=$RC: $OUT"; fi
"$ESCALATE" list >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "8d  and nothing is outstanding afterwards (exit 0)"
else bad "8d  list clean after ack" "rc=$RC"; fi
if grep -q '"event": "EscalationAck"' "$LEDGER" && grep -q '"event": "Escalation"' "$LEDGER"; then
    ok "8e  the ack APPENDED — the original row is still there, nothing was rewritten"
else
    bad "8e  append-only" "one of the two rows is missing from $LEDGER"
fi
OUT="$(stop_payload "$S2" | "$STOP_HOOK" 2>&1)"
case "$OUT" in
    *"clear again"*) ok "8f  the operator is told the story ended, having been told it started" ;;
    *) bad "8f  recovery line" "got: $OUT" ;;
esac
OUT="$("$START_HOOK" </dev/null 2>&1)"
if [ -z "$OUT" ]; then ok "8g  and SessionStart is silent again"
else bad "8g  silent after ack" "got: $OUT"; fi

# ===========================================================================
# 9. A RAISE THAT DID NOT LAND SAYS SO — the failure mode that would rebuild
#    the whole defect quietly.
# ===========================================================================
UNWRITABLE="$SANDBOX/readonly/escalations.jsonl"
mkdir -p "$SANDBOX/readonly"
chmod 500 "$SANDBOX/readonly"
OUT="$(RICHOS_ESCALATION_LEDGER="$UNWRITABLE" "$ESCALATE" raise \
        --title "this one cannot be written" --state proceeding \
        --question "does a failed raise tell the teammate it failed?" \
        --worktree "$SANDBOX" --teammate zach-opus-e1demo 2>&1)"
RC=$?
chmod 700 "$SANDBOX/readonly"
say "9 unwritable" "$OUT"
if [ "$RC" -ne 0 ]; then ok "9a  a raise that could not be written exits non-zero"
else bad "9a  failed raise exits non-zero" "rc=$RC: $OUT"; fi
case "$OUT" in
    *"HAS NOT BEEN DELIVERED"*) ok "9b  and it says so in those words, with what to do instead" ;;
    *) bad "9b  says not delivered" "got: $OUT" ;;
esac

# ===========================================================================
# 10. ARGUMENT VALIDATION — the two fields that keep the channel usable
# ===========================================================================
OUT="$("$ESCALATE" raise --title "no state given" \
        --question "is the state field really required here?" \
        --worktree "$SANDBOX" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "10a --state is required"; else bad "10a --state required" "rc=$RC"; fi
case "$OUT" in
    *"separates an escalation from a stall"*) ok "10b and the refusal explains WHY it is required" ;;
    *) bad "10b refusal explains" "got: $OUT" ;;
esac
OUT="$("$ESCALATE" raise --title "no question" --state stopped --question "eh?" \
        --worktree "$SANDBOX" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "10c a record with no real question is refused — nothing could ever close it"
else bad "10c question required" "rc=$RC: $OUT"; fi

# ===========================================================================
# 11. A STOPPED ESCALATION READS DIFFERENTLY FROM A COMPLETE ONE.
#     The whole point of the `state` field, asserted rather than assumed.
# ===========================================================================
L2="$SANDBOX/state/stopped.jsonl"
OUT="$(RICHOS_ESCALATION_LEDGER="$L2" "$ESCALATE" raise \
        --title "the whole task depends on this answer" --state stopped \
        --question "which of the two records governs? I cannot proceed either way." \
        --worktree "$SANDBOX" --teammate zach-opus-e1stopped 2>&1)"
OUT="$(RICHOS_ESCALATION_LEDGER="$L2" "$ESCALATE" list --format hook-summary 2>&1)"
say "11 stopped" "$OUT"
case "$OUT" in
    *"has STOPPED work"*) ok "11a a stopped escalation is reported as stopped" ;;
    *) bad "11a stopped reported" "got: $OUT" ;;
esac
case "$OUT" in
    *"none is a stall"*) bad "11b stall wording" "a STOPPED escalation was described as not a stall: $OUT" ;;
    *) ok "11b and the not-a-stall wording is correctly absent for it" ;;
esac

# ===========================================================================
# 12. NEGATIVE CONTROL — prove cases 2, 4 and 7 can fail.
#
# A green tick means nothing if the assertion cannot go red. So the historical
# defect is rebuilt on purpose: the predicate is replaced by one that reports
# "clear" over an outstanding escalation, exactly as a mechanism that writes a
# file nobody reads does. Both hooks must go silent — and if they do NOT, then
# their earlier output was not coming from the ledger at all.
# ===========================================================================
cp "$ENG/scripts/lib/escalations.py" "$SANDBOX/escalations.py.real"
cat > "$ENG/scripts/lib/escalations.py" <<'STUB'
#!/usr/bin/env python3
# MUTATION (test-only): the pre-fix world — an escalation exists, and the thing
# that is supposed to surface it reports a clean sheet.
import sys
if "hook-summary" in sys.argv:
    sys.stdout.write("clear\n0\n")
sys.exit(0)
STUB
L3="$SANDBOX/state/control.jsonl"
cp "$SANDBOX/escalations.py.real" "$SANDBOX/real.py"
RICHOS_ESCALATION_LEDGER="$L3" python3 "$SANDBOX/real.py" raise --title "the control escalation" \
    --state proceeding --question "does the negative control actually go silent?" \
    --teammate zach-opus-e1control >/dev/null 2>&1
if [ -s "$L3" ]; then ok "12a  the control escalation really is in the ledger"
else bad "12a  control fixture" "nothing written to $L3"; fi
OUT="$(RICHOS_ESCALATION_LEDGER="$L3" stop_payload "dddddddd-0000-0000-0000-000000000000" | RICHOS_ESCALATION_LEDGER="$L3" "$STOP_HOOK" 2>&1)"
if [ -z "$OUT" ]; then
    ok "12b  NEGATIVE CONTROL: with a predicate that reports 'clear', the Stop hook is SILENT over a live escalation — the historical defect, reproduced"
else
    bad "12b  NEGATIVE CONTROL" "the stub predicate still produced output, so cases 2/6/7 are not proving the ledger is being read: $OUT"
fi
OUT="$(RICHOS_ESCALATION_LEDGER="$L3" "$START_HOOK" </dev/null 2>&1)"
if [ -z "$OUT" ]; then
    ok "12c  NEGATIVE CONTROL: SessionStart is silent too"
else
    bad "12c  NEGATIVE CONTROL SessionStart" "got: $OUT"
fi
cp "$SANDBOX/escalations.py.real" "$ENG/scripts/lib/escalations.py"
OUT="$(RICHOS_ESCALATION_LEDGER="$L3" stop_payload "eeeeeeee-0000-0000-0000-000000000000" | RICHOS_ESCALATION_LEDGER="$L3" "$STOP_HOOK" 2>&1)"
case "$OUT" in
    *"ESCALATION OUTSTANDING"*) ok "12d  and with the real predicate restored, the same fixture is announced — the control was the mutation, not the fixture" ;;
    *) bad "12d  restored predicate" "got: $OUT" ;;
esac

# ===========================================================================
# 13. A MISSING PREDICATE IS ANNOUNCED, NEVER SWALLOWED.
#     Layer K's lesson: a hook that is wired, hashed, executable and reading
#     nothing looks exactly like a hook with nothing to report.
# ===========================================================================
mv "$ENG/scripts/lib/escalations.py" "$SANDBOX/escalations.py.hidden"
OUT="$(RICHOS_ESCALATION_LEDGER="$L3" stop_payload "ffffffff-0000-0000-0000-000000000000" | RICHOS_ESCALATION_LEDGER="$L3" "$STOP_HOOK" 2>&1)"
case "$OUT" in
    *"ESCALATION WATCH IS OFF"*) ok "13a  a missing predicate is ANNOUNCED, not swallowed" ;;
    *) bad "13a  missing predicate announced" "got: $OUT" ;;
esac
OUT="$("$START_HOOK" </dev/null 2>&1)"
case "$OUT" in
    *"ESCALATION WATCH IS OFF"*) ok "13b  and SessionStart says the same rather than opening quietly" ;;
    *) bad "13b  SessionStart announces" "got: $OUT" ;;
esac
mv "$SANDBOX/escalations.py.hidden" "$ENG/scripts/lib/escalations.py"

# ===========================================================================
# 14. AN UNREADABLE LINE IS COUNTED, NOT DISCARDED. A half-corrupt ledger must
#     never report as a clean empty world.
# ===========================================================================
L4="$SANDBOX/state/corrupt.jsonl"
printf 'this is not json\n' > "$L4"
RICHOS_ESCALATION_LEDGER="$L4" "$ESCALATE" raise --title "a good row beside a bad one" \
    --state proceeding --question "is the malformed line reported to anyone?" \
    --teammate zach-opus-e1corrupt >/dev/null 2>&1
OUT="$(RICHOS_ESCALATION_LEDGER="$L4" "$ESCALATE" list 2>&1)"
case "$OUT" in
    *"malformed line"*) ok "14a  a malformed ledger line is reported, with a count" ;;
    *) bad "14a  malformed reported" "got: $OUT" ;;
esac
case "$OUT" in
    *"1 raised in all, 1 OUTSTANDING"*) ok "14b  and the good row beside it is still read" ;;
    *) bad "14b  good row survives" "got: $OUT" ;;
esac

# ===========================================================================
# 15. A REPOSITORY WITH NO docs/ GETS THE LEDGER ROW AND NO NEW ROOT ENTRY.
#     ceo-decisions.md 27 is the reason, and it is not negotiable.
# ===========================================================================
NODOCS="$SANDBOX/nodocs"
mkdir -p "$NODOCS"
BEFORE="$(ls -A "$NODOCS" | wc -l | tr -d ' ')"
L5="$SANDBOX/state/nodocs.jsonl"
OUT="$(RICHOS_ESCALATION_LEDGER="$L5" "$ESCALATE" raise --title "no docs directory here" \
        --state proceeding --question "does it invent a root entry when there is nowhere to put a file?" \
        --worktree "$NODOCS" --teammate zach-opus-e1nodocs 2>&1)"
RC=$?
AFTER="$(ls -A "$NODOCS" | wc -l | tr -d ' ')"
say "15 nodocs" "$OUT"
if [ "$RC" -eq 0 ]; then ok "15a raise still succeeds without a docs/ directory"; else bad "15a raise succeeds" "rc=$RC: $OUT"; fi
if [ "$BEFORE" = "$AFTER" ]; then ok "15b and it added NOTHING to the repository root ($BEFORE entries before and after)"
else bad "15b root untouched" "root went from $BEFORE to $AFTER entries"; fi
if [ -s "$L5" ]; then ok "15c the escalation was still delivered"; else bad "15c delivered" "nothing in $L5"; fi
case "$OUT" in
    *"no record file was written"*) ok "15d and it says why, rather than failing silently" ;;
    *) bad "15d explains" "got: $OUT" ;;
esac

# ===========================================================================
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
