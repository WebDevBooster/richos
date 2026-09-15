#!/usr/bin/env bash
#
# left-off.test.sh — "WHERE HE LEFT OFF": THE PREDICATE, THE GAP, AND THE
#                    OUTCOME THAT COMES FROM GIT.
#
# ===========================================================================
# WHAT IS UNDER TEST
# ===========================================================================
#   scripts/lib/left-off.py             the analysis
#   scripts/hooks/left-off-report.sh    the SessionStart + UserPromptSubmit hook
#
# ===========================================================================
# EVERY CASE HAS ITS OPPOSITE
# ===========================================================================
# A report that ALWAYS fires and a report that NEVER fires are both useless and
# both look like a passing test. So each firing case is paired with a silent one
# built to be as similar as possible, one fact changed:
#
#   LO01/LO04  a typed message is his   <->  the same text arriving by `sdk` is not
#   LO02/LO03  `queued` and `suggestion_accepted` are his too -- the two a
#              hand-written predicate drops, and `queued` is 53 real messages
#              on this machine
#   LO05..LO08 task notifications, hook feedback, peer messages and tool
#              results are NOT him, one case each
#   LO10/LO11  a gap over the threshold reports  <->  one under it is silent
#   LO12       THE INCIDENT SHAPE: machine rows arriving DURING the gap must not
#              hide it. Without this the 2026-09-15 gap reads as 8 minutes.
#   LO13/LO14  the arriving prompt is excluded whether or not the host has
#              already written it to the transcript -- both orders, because
#              which one happens is not knowable and not stable
#   LO20..LO24 the outcome, from git: merged-and-deleted, ahead, unknown,
#              undone-by-reset, and a registry claim that never becomes a verdict
#   LO30..LO33 what the report actually contains
#   LO40..LO48 the hook: the channel, the event name, once-per-gap, the
#              stand-down, and the stdin hazard
#
# THE CASE IDS ARE FOUR CHARACTERS AND NO ID IS A PREFIX OF ANOTHER. The
# mutation harness greps `FAIL  <id>` as a raw regex; with `LO1` and `LO13` in
# one suite every mutant would report "the red is unrelated" while having turned
# exactly the right case red. That happened to a sibling suite and cost nine
# mutants.
#
# Usage: scripts/hooks/left-off.test.sh
# Exit:  0 all cases passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ENGINE_ROOT/scripts/lib/left-off.py"
HOOK="$SCRIPT_DIR/left-off-report.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "ERROR: needs git" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t left-off.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# THE REGISTRY IS SANDBOXED. Without this every fixture repository recorded
# here lands in the OPERATOR's real ~/.claude/state/workspaces, pointing at
# temp directories that stop existing when the trap fires. A test never writes
# to the operator's state.
export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"

echo "=== where he left off: his message, the gap, and git's answer ==="
echo ""

SEAT="$SANDBOX/seat"        # the repository the session is seated in
FAR="$SANDBOX/far"          # where the teammates actually work
SESSION="abcd1234-0000-4000-8000-000000000000"


mk_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "tester@example.invalid"
    git -C "$1" config user.name  "tester"
    mkdir -p "$SANDBOX/nohooks"
    git -C "$1" config core.hooksPath "$SANDBOX/nohooks"
    printf 'seed\n' > "$1/README.md"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -qm seed >/dev/null 2>&1
}

mk_repo "$SEAT"
mk_repo "$FAR"
: > "$SEAT/orchestration.config"
mkdir -p "$SEAT/.claude/state"

# ---------------------------------------------------------------------------
# THE FAR REPOSITORY'S HISTORY, built to contain all four outcomes at once
# ---------------------------------------------------------------------------
#   cc/landed-one     merged, then DELETED   -> LANDED, findable only by reflog
#   cc/ahead-one      still there, ahead     -> NOT LANDED
#   cc/undone-one     merged, then reset away-> NOT LANDED (the reflog names it,
#                                               ancestry refuses it)
#   nothing at all for `ghost-one`           -> NO TRACE
# ---------------------------------------------------------------------------
build_far() {
    git -C "$FAR" checkout -q -b cc/landed-one
    printf 'landed\n' > "$FAR/landed.txt"
    git -C "$FAR" add -A >/dev/null 2>&1
    git -C "$FAR" commit -qm "the work that landed" >/dev/null 2>&1
    git -C "$FAR" checkout -q main
    git -C "$FAR" merge -q --no-ff -m "Merge branch 'cc/landed-one'" cc/landed-one >/dev/null 2>&1
    git -C "$FAR" branch -q -D cc/landed-one >/dev/null 2>&1

    git -C "$FAR" checkout -q -b cc/ahead-one
    printf 'ahead\n' > "$FAR/ahead.txt"
    git -C "$FAR" add -A >/dev/null 2>&1
    git -C "$FAR" commit -qm "the work that did not land" >/dev/null 2>&1
    git -C "$FAR" checkout -q main

    BEFORE_UNDO="$(git -C "$FAR" rev-parse HEAD)"
    git -C "$FAR" checkout -q -b cc/undone-one
    printf 'undone\n' > "$FAR/undone.txt"
    git -C "$FAR" add -A >/dev/null 2>&1
    git -C "$FAR" commit -qm "the work that was undone" >/dev/null 2>&1
    git -C "$FAR" checkout -q main
    git -C "$FAR" merge -q --no-ff -m "Merge branch 'cc/undone-one'" cc/undone-one >/dev/null 2>&1
    git -C "$FAR" branch -q -D cc/undone-one >/dev/null 2>&1
    git -C "$FAR" reset -q --hard "$BEFORE_UNDO"
}
build_far

# ---------------------------------------------------------------------------
# THE REGISTRY — through workspaces.py's own API, never a guess at its shape
# ---------------------------------------------------------------------------
register() {
    SEAT="$SEAT" FAR="$FAR" SESSION="$SESSION" ENGINE_ROOT="$ENGINE_ROOT" python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ws", os.path.join(os.environ["ENGINE_ROOT"], "scripts", "lib", "workspaces.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
session = os.environ["SESSION"]
for repo in (os.environ["SEAT"], os.environ["FAR"]):
    ws.record_integration(repo, "main", why="suite fixture", by_session=session)
def agent(name, repo, branch, disposition=None):
    key = ws.named_key(session, name)
    rec = ws.new_record(key, name=name, session_id=session)
    rec["workspaces"] = [{"kind": "cc", "repo": repo, "branch": branch,
                          "path": os.path.join(repo + "-wt", name),
                          "source": "suite"}]
    if disposition:
        rec["disposition"] = disposition
    ws.save_agent(rec)
agent("landed-one", os.environ["FAR"], "cc/landed-one")
agent("ahead-one",  os.environ["FAR"], "cc/ahead-one")
agent("undone-one", os.environ["FAR"], "cc/undone-one")
agent("claimed-one", os.environ["FAR"], "cc/claimed-one",
      {"kind": "landed", "reason": "the registry says so and git does not"})
PY
}
register >/dev/null 2>&1

# ---------------------------------------------------------------------------
# THE CLOCK IS RELATIVE TO THIS RUN, AND THAT IS A CORRECTION
# ---------------------------------------------------------------------------
# The first version of this suite used the literal timestamps of the 2026-09-15
# incident. Every git-outcome case failed, and the reason is the analyzer being
# RIGHT: an explicit --now is a replay, and a replay refuses reflog entries
# written after the instant it reproduces. The fixture repository's reflog is
# written NOW, hours after a 2026-09-14 anchor, so every merge was correctly
# ignored as "the future". Fixed by moving the fixture's clock rather than by
# weakening the check the suite exists to protect.
eval "$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc).replace(microsecond=0)
def iso(**kw):
    return (now - timedelta(**kw)).isoformat()
print('NOW="%s"' % now.isoformat())
print('T_GAP="%s"'      % iso(hours=9, minutes=1, seconds=30))  # his last word
print('T_EARLIER="%s"'  % iso(hours=9, minutes=38))             # earlier, same sitting
print('T_TWICE_A="%s"'  % iso(hours=9, minutes=10))
print('T_TWICE_B="%s"'  % iso(hours=9, minutes=6))
print('T_REPLY="%s"'    % iso(hours=9, minutes=1))              # what I said back
print('T_RECENT="%s"'   % iso(hours=1))                         # not a gap
print('T_MID="%s"'      % iso(hours=5))                         # machine rows
print('T_LATE="%s"'     % iso(minutes=6))
print('T_JOB_D="%s"'    % iso(hours=8))                         # a job dispatched
print('T_JOB_E="%s"'    % iso(hours=7))                         # ... and finished
print('T_OTHER="%s"'    % iso(hours=11))                        # a different gap
print('T_JUSTNOW="%s"'  % iso(seconds=30))                      # he spoke 30s ago
print('HHMM_TWICE_B="%s"' % (now - timedelta(hours=9, minutes=6)).strftime('%H:%M'))
PY
)"

# ---------------------------------------------------------------------------
# TRANSCRIPT FIXTURES
# ---------------------------------------------------------------------------
# One builder, driven by a compact spec, so a case differs from its opposite by
# exactly the fact under test and by nothing else.
cat > "$SANDBOX/mk_transcript.py" <<'PY'
import json, sys

# argv: <out> <spec-json>
# spec rows: [iso, kind, text]  kind in:
#   typed queued suggestion sdk task meta peer toolresult assistant
out, spec = sys.argv[1], json.loads(sys.argv[2])
rows = []
for iso, kind, text in spec:
    base = {"timestamp": iso, "sessionId": "s", "version": "2.1.270",
            "isSidechain": False}
    if kind == "assistant":
        base.update({"type": "assistant",
                     "message": {"role": "assistant",
                                 "content": [{"type": "text", "text": text}]}})
    elif kind == "toolresult":
        base.update({"type": "user", "origin": {"kind": "human"},
                     "promptSource": "typed",
                     "message": {"role": "user",
                                 "content": [{"type": "tool_result",
                                              "tool_use_id": "t1",
                                              "content": text}]}})
    else:
        origin = {"typed": {"kind": "human"},
                  "queued": {"kind": "human"},
                  "suggestion": {"kind": "human"},
                  "sdk": {"kind": "human"},
                  "task": {"kind": "task-notification"},
                  "peer": {"kind": "peer"},
                  "meta": None}[kind]
        source = {"typed": "typed", "queued": "queued",
                  "suggestion": "suggestion_accepted", "sdk": "sdk",
                  "task": "system", "peer": "system", "meta": None}[kind]
        base.update({"type": "user", "origin": origin, "promptSource": source,
                     "message": {"role": "user",
                                 "content": [{"type": "text", "text": text}]}})
        if kind in ("meta", "peer"):
            base["isMeta"] = True
    rows.append(base)
with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY

mk() { # <name> <spec-json>  -> path
    python3 "$SANDBOX/mk_transcript.py" "$SANDBOX/$1.jsonl" "$2"
    printf '%s' "$SANDBOX/$1.jsonl"
}

run() { # <transcript> [extra args...] -> report on stdout, rc in RC
    local t="$1"; shift
    set +e
    OUT="$(python3 "$LIB" --transcript "$t" --now "$NOW" --session "$SESSION" \
        --entity-root "$SEAT" --gap-minutes 120 "$@" 2>&1)"
    RC=$?
    set -e
}

# ===========================================================================
# 1. THE PREDICATE — which messages are HIS
# ===========================================================================
echo "--- 1. whose message is it ---"

for pair in "LO01 typed" "LO02 queued" "LO03 suggestion"; do
    id="${pair%% *}"; kind="${pair##* }"
    T="$(mk "his-$kind" "[[\"$T_GAP\",\"$kind\",\"MARKER-HIS-MESSAGE-$kind\"]]")"
    run "$T"
    if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "MARKER-HIS-MESSAGE-$kind"; then
        ok "$id a \`$kind\` message is HIS and anchors the report"
    else
        bad "$id a \`$kind\` message is his" "rc $RC: $(printf '%s' "$OUT" | head -3)"
    fi
done

T="$(mk "not-sdk" '[["'"$T_GAP"'","sdk","MARKER-HIS-MESSAGE-sdk"]]')"
run "$T"
if [ "$RC" != "0" ]; then
    ok "LO04 the SAME text arriving by \`sdk\` is a harness, not him, and reports nothing"
else
    bad "LO04 an sdk prompt is not him" "it produced a report: $(printf '%s' "$OUT" | head -3)"
fi

for pair in "LO05 task" "LO06 meta" "LO07 peer" "LO08 toolresult"; do
    id="${pair%% *}"; kind="${pair##* }"
    T="$(mk "not-$kind" "[[\"$T_GAP\",\"$kind\",\"MARKER-MACHINE-$kind\"]]")"
    run "$T"
    if [ "$RC" != "0" ]; then
        ok "$id a \`$kind\` row is the machine talking, not him"
    else
        bad "$id a $kind row is not him" "it anchored a report: $(printf '%s' "$OUT" | head -3)"
    fi
done

# ===========================================================================
# 2. THE GAP
# ===========================================================================
echo ""
echo "--- 2. the gap ---"

T="$(mk "gap-over" '[["'"$T_GAP"'","typed","MARKER-NINE-HOURS-AGO"]]')"
run "$T"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "9h 01m"; then
    ok "LO10 a nine-hour gap is reported, and the gap is named"
else
    bad "LO10 a nine-hour gap reports" "rc $RC: $(printf '%s' "$OUT" | head -3)"
fi

T="$(mk "gap-under" '[["'"$T_RECENT"'","typed","MARKER-ONE-HOUR-AGO"]]')"
run "$T"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
    ok "LO11 an hour is not a gap: silent, and silent means SILENT"
else
    bad "LO11 an hour is not a gap" "rc $RC: $(printf '%s' "$OUT" | head -3)"
fi

# THE INCIDENT SHAPE. Between his last message and his return, the transcript
# filled with task notifications, hook feedback and peer messages. If any of
# them counted, the gap would read as minutes and nothing would be reported --
# which is the session that cost him 39 minutes.
T="$(mk "gap-noisy" '[["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"],
                      ["'"$T_MID"'","task","<task-notification> finished"],
                      ["'"$T_MID"'","peer","Another Claude session sent a message"],
                      ["'"$T_LATE"'","meta","Stop hook feedback: CI IS RED"]]')"
run "$T"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "9h 01m" \
   && printf '%s' "$OUT" | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO12 machine rows arriving DURING the gap do not hide it (the incident shape)"
else
    bad "LO12 machine rows do not close the gap" "rc $RC: $(printf '%s' "$OUT" | head -5)"
fi

# ===========================================================================
# 3. THE ARRIVING PROMPT — both host write orders
# ===========================================================================
echo ""
echo "--- 3. the message being handled right now ---"

printf 'TLDR, plain English' > "$SANDBOX/prompt.txt"

# (a) the host HAS already appended it
T="$(mk "prompt-present" '[["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"],
                           ["'"$NOW"'","typed","TLDR, plain English"]]')"
run "$T" --prompt-file "$SANDBOX/prompt.txt"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO13 the arriving prompt is excluded when the host already wrote it"
else
    bad "LO13 arriving prompt already in the transcript" "rc $RC: $(printf '%s' "$OUT" | head -3)"
fi

# (b) the host has NOT appended it yet -- same answer, no timing assumption
T="$(mk "prompt-absent" '[["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"]]')"
run "$T" --prompt-file "$SANDBOX/prompt.txt"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO14 ... and when it has not, which is the same answer either way"
else
    bad "LO14 arriving prompt not yet in the transcript" "rc $RC: $(printf '%s' "$OUT" | head -3)"
fi

# (c) A RECENT message that is NOT the arriving prompt is KEPT. Drop the last
# row by TIMING instead of by IDENTITY and this fixture invents a nine-hour gap
# thirty seconds after he spoke -- a return report for a return that never
# happened, which is worse than no report at all.
T="$(mk "prompt-other" '[["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"],
                         ["'"$T_JUSTNOW"'","typed","something else entirely"]]')"
run "$T" --prompt-file "$SANDBOX/prompt.txt"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
    ok "LO15 a RECENT message that is not the arriving prompt is kept, so no gap is invented"
else
    bad "LO15 a recent non-prompt message is kept" "rc $RC: $(printf '%s' "$OUT" | head -3)"
fi

# ===========================================================================
# 4. THE OUTCOME COMES FROM GIT
# ===========================================================================
echo ""
echo "--- 4. what happened to the work, asked of git ---"

job() { # <teammate> -> a transcript with that job dispatched and finished in the gap
    python3 - "$SANDBOX/job-$1.jsonl" "$1" "$T_GAP" "$T_JOB_D" "$T_JOB_E" <<'PY'
import json, sys
out, name, t_gap, t_dispatched, t_ended = sys.argv[1:6]
rows = [
    {"type": "user", "timestamp": t_gap,
     "origin": {"kind": "human"}, "promptSource": "typed", "isSidechain": False,
     "message": {"role": "user", "content": [{"type": "text",
                                              "text": "MARKER-HIS-LAST-WORD"}]}},
    {"type": "assistant", "timestamp": t_dispatched,
     "isSidechain": False,
     "message": {"role": "assistant", "content": [
         {"type": "tool_use", "id": "toolu_x", "name": "Agent",
          "input": {"name": name, "description": "the job under test",
                    "subagent_type": "zach"}}]}},
    {"type": "user", "timestamp": t_ended,
     "origin": {"kind": "task-notification"}, "promptSource": "system",
     "isSidechain": False,
     "message": {"role": "user", "content": [{"type": "text", "text":
         "<task-notification><tool-use-id>toolu_x</tool-use-id>"
         "<status>completed</status><subagent_tokens>12345</subagent_tokens>"
         '<summary>Agent "the job under test" finished</summary>'
         "</task-notification>"}]}},
]
with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
    printf '%s' "$SANDBOX/job-$1.jsonl"
}

T="$(job landed-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "landed-one  *LANDED"; then
    ok "LO20 a branch that was MERGED AND DELETED is LANDED, found by reflog + ancestry"
else
    bad "LO20 merged-and-deleted is LANDED" "$(printf '%s' "$OUT" | grep -A2 'tokens  teammate')"
fi

T="$(job ahead-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "ahead-one  *NOT LANDED" \
   && printf '%s' "$OUT" | grep -q "commit(s) ahead"; then
    ok "LO21 a branch still ahead of the integration branch is NOT LANDED, with its count"
else
    bad "LO21 an ahead branch is NOT LANDED" "$(printf '%s' "$OUT" | grep -i 'ahead-one')"
fi

T="$(job ghost-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "ghost-one  *NO TRACE" \
   && printf '%s' "$OUT" | grep -q "'not seen', NOT 'not landed'"; then
    ok "LO22 a name git has never heard of is NO TRACE, and SAYS it is not the same as not landed"
else
    bad "LO22 an unknown name is NO TRACE, not a verdict" "$(printf '%s' "$OUT" | grep -i 'ghost-one')"
fi

T="$(job undone-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "undone-one  *NOT LANDED" \
   && printf '%s' "$OUT" | grep -q "it was undone"; then
    ok "LO23 a reflog merge whose commit was RESET AWAY is NOT LANDED -- the reflog alone would lie"
else
    bad "LO23 a reset-away merge is not LANDED" "$(printf '%s' "$OUT" | grep -i 'undone-one')"
fi

T="$(job claimed-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "claimed-one  *NO TRACE" \
   && printf '%s' "$OUT" | grep -q "registry claims landed"; then
    ok "LO24 the registry's own 'landed' is QUOTED as a claim and never becomes the verdict"
else
    bad "LO24 a registry claim is not a verdict" "$(printf '%s' "$OUT" | grep -i 'claimed-one')"
fi

# A REPLAY MUST NOT SEE THE FUTURE. `cc/late-one` is merged AFTER the clock
# above was taken, so a replay at that instant cannot honestly call it landed
# and a live run must. The pair is the whole property: remove the as-of filter
# and LO25 goes green-by-accident, so LO26 is what makes the mutant killable.
git -C "$FAR" checkout -q -b cc/late-one
printf 'late\n' > "$FAR/late.txt"
git -C "$FAR" add -A >/dev/null 2>&1
git -C "$FAR" commit -qm "the work that landed after the replay instant" >/dev/null 2>&1
git -C "$FAR" checkout -q main
git -C "$FAR" merge -q --no-ff -m "Merge branch 'cc/late-one'" cc/late-one >/dev/null 2>&1
git -C "$FAR" branch -q -D cc/late-one >/dev/null 2>&1
SEAT="$SEAT" FAR="$FAR" SESSION="$SESSION" ENGINE_ROOT="$ENGINE_ROOT" python3 - <<'PY' >/dev/null 2>&1
import importlib.util, os
spec = importlib.util.spec_from_file_location(
    "ws", os.path.join(os.environ["ENGINE_ROOT"], "scripts", "lib", "workspaces.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
session = os.environ["SESSION"]
key = ws.named_key(session, "late-one")
rec = ws.new_record(key, name="late-one", session_id=session)
rec["workspaces"] = [{"kind": "cc", "repo": os.environ["FAR"], "branch": "cc/late-one",
                      "path": os.path.join(os.environ["FAR"] + "-wt", "late-one"),
                      "source": "suite"}]
ws.save_agent(rec)
PY

T="$(job late-one)"
run "$T"
if printf '%s' "$OUT" | grep -q "late-one  *NO TRACE"; then
    ok "LO25 a replay refuses a merge recorded AFTER the instant it reproduces"
else
    bad "LO25 a replay does not see the future" "$(printf '%s' "$OUT" | grep -i 'late-one')"
fi

set +e
OUT="$(python3 "$LIB" --transcript "$T" --session "$SESSION" --entity-root "$SEAT" \
    --gap-minutes 120 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "late-one  *LANDED"; then
    ok "LO26 ... and a LIVE run, with no replay instant, sees the same merge and calls it LANDED"
else
    bad "LO26 a live run sees the merge" "rc $RC: $(printf '%s' "$OUT" | grep -i 'late-one')"
fi

# ===========================================================================
# 5. WHAT THE REPORT CONTAINS
# ===========================================================================
echo ""
echo "--- 5. the report itself ---"

T="$(mk "content" '[["'"$T_EARLIER"'","typed","Burning 46 percent of tokens is unacceptable. MARKER-THE-NUMBER"],
                    ["'"$T_TWICE_A"'","typed","MARKER-ASKED-TWICE"],
                    ["'"$T_TWICE_B"'","typed","MARKER-ASKED-TWICE"],
                    ["'"$T_REPLY"'","assistant","MARKER-WHAT-I-SAID-BACK"],
                    ["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"]]')"
run "$T"
if printf '%s' "$OUT" | grep -q "HIS LAST MESSAGE BEFORE THE GAP, VERBATIM" \
   && printf '%s' "$OUT" | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO30 his last message is carried VERBATIM and named as the thing to answer"
else
    bad "LO30 his last message, verbatim" "$(printf '%s' "$OUT" | head -12)"
fi

if printf '%s' "$OUT" | grep -q "MARKER-THE-NUMBER"; then
    ok "LO31 the sitting carries the earlier message that holds the number he is asking about"
else
    bad "LO31 the sitting carries the thread" "$(printf '%s' "$OUT" | head -20)"
fi

if [ "$(printf '%s\n' "$OUT" | grep -c 'MARKER-ASKED-TWICE')" = "1" ] \
   && printf '%s' "$OUT" | grep -q "he sent this again at $HHMM_TWICE_B"; then
    ok "LO32 a message he sent twice appears ONCE, and the repeat is reported as a missed answer"
else
    bad "LO32 repeats collapse and are noted" "$(printf '%s' "$OUT" | grep -n 'MARKER-ASKED-TWICE')"
fi

if printf '%s' "$OUT" | grep -q "MARKER-WHAT-I-SAID-BACK"; then
    ok "LO33 the last thing YOU told him is carried too, in your own words"
else
    bad "LO33 the last reply is carried" "$(printf '%s' "$OUT" | head -20)"
fi

# The budget: a long sitting must come back UNDER the measured channel cap
# rather than being dropped whole by the host, and his last message must
# survive the trimming.
python3 - "$SANDBOX/huge.jsonl" "$T_GAP" <<'PY'
import json, sys
from datetime import datetime, timedelta
anchor = datetime.fromisoformat(sys.argv[2])
rows = []
for i in range(40):
    rows.append({"type": "user",
                 "timestamp": (anchor - timedelta(minutes=(41 - i))).isoformat(),
                 "origin": {"kind": "human"}, "promptSource": "typed",
                 "isSidechain": False,
                 "message": {"role": "user", "content": [
                     {"type": "text", "text": ("padding %d " % i) + "x" * 900}]}})
rows.append({"type": "user", "timestamp": sys.argv[2],
             "origin": {"kind": "human"}, "promptSource": "typed",
             "isSidechain": False,
             "message": {"role": "user", "content": [
                 {"type": "text", "text": "MARKER-HIS-LAST-WORD"}]}})
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
run "$SANDBOX/huge.jsonl" --budget 1400
# CHARACTERS, not bytes: the measured channel cap is 8000 CHARACTERS and this
# report is full of em-dashes, so `wc -c` overcounts a compliant report by the
# number of multibyte characters in it and fails a case that passed.
SIZE="$(printf '%s' "$OUT" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
if [ "$RC" = "0" ] && [ "$SIZE" -le 1400 ] \
   && printf '%s' "$OUT" | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO34 a long sitting is trimmed to the channel budget and HIS LAST MESSAGE survives it ($SIZE chars)"
else
    bad "LO34 the report fits the channel and keeps his message" "rc $RC size $SIZE"
fi

# ===========================================================================
# 6. THE HOOK
# ===========================================================================
echo ""
echo "--- 6. the hook: the channel, the event, once per gap ---"

HOOK_T="$(mk "hook" '[["'"$T_GAP"'","typed","MARKER-HIS-LAST-WORD"]]')"
payload() { # <prompt>
    PROMPT="$1" TR="$HOOK_T" SEAT="$SEAT" SESSION="$SESSION" python3 -c '
import json, os
print(json.dumps({"session_id": os.environ["SESSION"],
                  "transcript_path": os.environ["TR"],
                  "cwd": os.environ["SEAT"],
                  "hook_event_name": "UserPromptSubmit",
                  "prompt": os.environ["PROMPT"]}))'
}

fire() { # <prompt> -> HOUT / HRC
    set +e
    HOUT="$(payload "$1" | bash "$HOOK" --event UserPromptSubmit --now "$NOW" 2>/dev/null)"
    HRC=$?
    set -e
}

rm -f "$SEAT/.claude/state/left-off."*.state
fire "TLDR, plain English"
if [ "$HRC" = "0" ]; then
    ok "LO40 the hook exits 0 (it refuses nothing, ever)"
else
    bad "LO40 the hook exits 0" "rc $HRC"
fi

CTX="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
h=d.get("hookSpecificOutput") or {}
print(h.get("hookEventName",""))
print(h.get("additionalContext",""))' 2>/dev/null)"
EVT="$(printf '%s\n' "$CTX" | sed -n '1p')"
if [ "$EVT" = "UserPromptSubmit" ]; then
    ok "LO41 hookEventName matches the event -- a mismatch makes the host DROP the whole object"
else
    bad "LO41 hookEventName matches the event" "got '$EVT'"
fi

if printf '%s\n' "$CTX" | tail -n +2 | grep -q "MARKER-HIS-LAST-WORD"; then
    ok "LO42 the report reaches the MODEL, on additionalContext -- the measured channel"
else
    bad "LO42 the report is on additionalContext" "$(printf '%s' "$HOUT" | head -c 300)"
fi

SYS="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("systemMessage") or ""))
except Exception: pass' 2>/dev/null)"
if printf '%s' "$SYS" | grep -q "HE IS BACK" \
   && [ "$(printf '%s\n' "$SYS" | wc -l | tr -d ' ')" = "1" ]; then
    ok "LO43 the PERSON gets one line, not the report"
else
    bad "LO43 the person gets one line" "systemMessage: $SYS"
fi

fire "and again"
CTX2="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if printf '%s' "$CTX2" | grep -q "already been given the full return report" \
   && ! printf '%s' "$CTX2" | grep -q "HOW TO RE-DERIVE"; then
    ok "LO44 the second message in the same gap gets the one-line anchor, not the report again"
else
    bad "LO44 second message gets the anchor only" "$(printf '%s' "$CTX2" | head -c 200)"
fi

fire "third"
fire "fourth"
CTX4="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if [ -z "$(printf '%s' "$CTX4" | tr -d '[:space:]')" ]; then
    ok "LO45 by the fourth message in the same gap it is silent"
else
    bad "LO45 it goes silent after two anchors" "$(printf '%s' "$CTX4" | head -c 200)"
fi

# A NEW gap reports afresh: same session, a different anchor.
HOOK_T="$(mk "hook2" '[["'"$T_OTHER"'","typed","MARKER-A-DIFFERENT-LAST-WORD"]]')"
fire "back again"
CTX5="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if printf '%s' "$CTX5" | grep -q "MARKER-A-DIFFERENT-LAST-WORD" \
   && printf '%s' "$CTX5" | grep -q "HOW TO RE-DERIVE"; then
    ok "LO46 a NEW gap reports in full again -- the key is the anchor, not the session"
else
    bad "LO46 a new gap reports afresh" "$(printf '%s' "$CTX5" | head -c 200)"
fi

# The stand-down is ANNOUNCED. An opt-out nobody can see decays into a rumour.
printf 'CHECK_LEFT_OFF=0\n' > "$SEAT/orchestration.config"
rm -f "$SEAT/.claude/state/left-off."*.state
fire "TLDR, plain English"
CTX6="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if printf '%s' "$CTX6" | grep -q "STOOD DOWN"; then
    ok "LO47 CHECK_LEFT_OFF=0 ANNOUNCES the stand-down instead of going quiet"
else
    bad "LO47 the stand-down is announced" "$(printf '%s' "$CTX6" | head -c 200)"
fi
: > "$SEAT/orchestration.config"

# An unreadable transcript is the absence of a CHECK, not the absence of a gap.
UNREADABLE="$SANDBOX/nope/none.jsonl"
set +e
HOUT="$(SEAT="$SEAT" SESSION="$SESSION" python3 -c '
import json, os
print(json.dumps({"session_id": os.environ["SESSION"],
                  "transcript_path": "/nonexistent/none.jsonl",
                  "cwd": os.environ["SEAT"], "hook_event_name": "UserPromptSubmit",
                  "prompt": "hello"}))' \
    | bash "$HOOK" --event UserPromptSubmit --transcript "$UNREADABLE" --now "$NOW" 2>/dev/null)"
HRC=$?
set -e
CTX7="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if [ "$HRC" = "0" ] && printf '%s' "$CTX7" | grep -qi "could not read\|NOT RUNNING\|absence of a check"; then
    ok "LO48 an unreadable transcript is ANNOUNCED as the absence of a check, never as no gap"
else
    bad "LO48 an unreadable transcript is announced" "rc $HRC ctx: $(printf '%s' "$CTX7" | head -c 200)"
fi

# THE STDIN HAZARD. engine-status.sh measured 92 seconds of hang from an
# unconditional `cat` at SessionStart against an inherited pipe nobody closes.
# This fires the hook on that exact shape and demands it come back.
FIFO="$SANDBOX/fifo"
rm -f "$FIFO"; mkfifo "$FIFO"
( exec 9>"$FIFO"; sleep 20 ) &
WRITER=$!
( bash "$HOOK" --event SessionStart --transcript "$HOOK_T" --now "$NOW" \
      >"$SANDBOX/ss.out" 2>"$SANDBOX/ss.err" < "$FIFO"
  echo done > "$SANDBOX/sessionstart.done" ) &
RUNNER=$!
WAITED=0
while [ ! -f "$SANDBOX/sessionstart.done" ] && [ "$WAITED" -lt 10 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ -f "$SANDBOX/sessionstart.done" ]; then
    ok "LO49 SessionStart returns against an inherited pipe nobody closes (it never reads stdin)"
else
    bad "LO49 SessionStart does not hang on stdin" \
        "still running after ${WAITED}s -- the measured 92-second hazard; stderr: $(head -c 300 "$SANDBOX/ss.err" 2>/dev/null)"
fi
kill "$WRITER" "$RUNNER" >/dev/null 2>&1
wait "$WRITER" "$RUNNER" >/dev/null 2>&1

# SESSION START FINDS THE TRANSCRIPT BY ITSELF. It never reads the payload (see
# LO49), so it has nothing but CLAUDE_PROJECT_DIR -- and this is the path that
# actually runs in production every morning. HOME is redirected at the
# invocation so the discovery looks inside the sandbox instead of the
# operator's own ~/.claude/projects; the fixture repositories carry local
# user.name/user.email, so git is unaffected by it.
SLUG="$(printf '%s' "$SEAT" | sed 's|[/.]|-|g')"
mkdir -p "$SANDBOX/home/.claude/projects/$SLUG"
cp "$HOOK_T" "$SANDBOX/home/.claude/projects/$SLUG/discovered.jsonl"
rm -f "$SEAT/.claude/state/left-off."*.state
set +e
HOUT="$(HOME="$SANDBOX/home" CLAUDE_PROJECT_DIR="$SEAT" \
        bash "$HOOK" --event SessionStart --now "$NOW" < /dev/null 2>/dev/null)"
HRC=$?
set -e
CTX8="$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: print(((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext") or ""))
except Exception: pass' 2>/dev/null)"
if [ "$HRC" = "0" ] && printf '%s' "$CTX8" | grep -q "MARKER-A-DIFFERENT-LAST-WORD"; then
    ok "LO50 SessionStart finds the project's newest transcript with no payload and no argument"
else
    bad "LO50 SessionStart discovers its own transcript" "rc $HRC ctx: $(printf '%s' "$CTX8" | head -c 200)"
fi

# ===========================================================================
# 7. THE MUTATION HARNESS
# ===========================================================================
echo ""
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$SCRIPT_DIR/left-off.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/left-off.mutation.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
    fi
    echo ""
fi

if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$PASS"
    exit 0
fi
printf '  %s passed, %s FAILED\n' "$PASS" "$FAIL"
exit 1
