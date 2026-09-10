#!/usr/bin/env bash
#
# land-disposition.test.sh — FINISHED WORK IS LANDED, OR HELD FOR A WRITTEN
#                            REASON. BOTH HALVES, AND THE THINGS THAT MUST
#                            NEVER HAPPEN.
#
# ===========================================================================
# WHAT IS UNDER TEST
# ===========================================================================
#   scripts/lib/land-disposition.py           the check and the demand
#   scripts/land-disposition.sh               the same, by hand
#   scripts/hooks/notice-land-disposition.sh  the Stop notice
#   scripts/land-disposition-measure.py       the threshold's derivation
#
# ===========================================================================
# EVERY CASE HAS ITS OPPOSITE, AND THAT IS THE WHOLE DESIGN
# ===========================================================================
# A check that ALWAYS demands and a check that NEVER demands are both useless
# and both look like a passing test. So each firing case is paired with a silent
# one built to be as similar as possible: same repository, same branch shape,
# ONE FACT CHANGED. If a pair ever agrees, one of them is wrong.
#
#   D01/D02  past the threshold is DEMANDED   <-> under it is YOUNG and silent
#   D03      the same demand twice is ONE row (idempotent on repo|branch|tip)
#   D04      a NEW COMMIT on a demanded branch demands again, deliberately
#   D05/D06  a demand whose work LANDED closes itself <-> one that did not stays
#   D07      a demand whose tip cannot be read is UNDECIDED, never closed
#   D08      a branch a LOCKED worktree holds is never demanded on
#   D09      an acknowledged demand is HELD, and the REASON is printed
#   D10      a codex/ branch is named, never demanded, never the reason for a 3
#   D11      NOTHING IS EVER DELETED — every branch and worktree survives
#   D12      no mutating git verb exists anywhere in the tool (mechanical)
#   D13      the notice never blocks: exit 0 on every payload
#   D14/D15  the notice announces every way it can stop working
#   D16      the three exit codes never collapse into each other
#   D17      writes per run are bounded, and the overflow is COUNTED not lost
#   D18      COULD NOT DECIDE and NOT EXAMINED print even when empty (R5)
#   D19      the report and the exit code come from ONE sweep and agree
#   D20      the escape hatch works IN THE STATE WHERE THE DEMAND FIRES (R7)
#   D21      the measuring script proposes no threshold and says so
#
# THE CASE IDS ARE TWO DIGITS AND NO ID IS A PREFIX OF ANOTHER. A mutation
# harness greps `FAIL  <id>` as a raw regex, so `D1` and `D12` in one suite
# would let nine mutants each report "the red is unrelated" while every one had
# turned exactly the right case red.
#
# Usage: scripts/hooks/land-disposition.test.sh
# Exit:  0 all cases passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$ENGINE_ROOT/scripts/lib/land-disposition.py"
CMD="$ENGINE_ROOT/scripts/land-disposition.sh"
NOTICE="$SCRIPT_DIR/notice-land-disposition.sh"
MEASURE="$ENGINE_ROOT/scripts/land-disposition-measure.py"
ESCALATE="$ENGINE_ROOT/scripts/escalate.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "ERROR: needs git" >&2; exit 1; }
[ -f "$CHECK" ] || { echo "ERROR: missing $CHECK" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t landdisp.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== finished work: landed, or held for a written reason ==="
echo ""

SEAT="$SANDBOX/seat"
FAR="$SANDBOX/far"
LEDGER="$SANDBOX/worktree-ledger.jsonl"
SESSION="abcd1234-0000-4000-8000-000000000000"

mk_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "tester@example.invalid"
    git -C "$1" config user.name  "tester"
    # A global core.hooksPath (an identity guard, a linter) would fail this
    # suite for reasons that have nothing to do with what is under test.
    mkdir -p "$SANDBOX/nohooks"
    git -C "$1" config core.hooksPath "$SANDBOX/nohooks"
    printf 'seed\n' > "$1/README.md"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -qm seed >/dev/null 2>&1
}

adopt() {
    : > "$1/orchestration.config"
    mkdir -p "$1/.claude/state"
    # EXCLUDED, NOT COMMITTED. With `git add -A` these get committed onto the
    # first branch, and every later `checkout main` then DELETES
    # orchestration.config from the working tree, so the repository silently
    # stops being adopted halfway through the suite. A broken fixture reads
    # exactly like a finding.
    printf 'orchestration.config\n.claude/\n' > "$1/.git/info/exclude"
}

# AGE IS THE WHOLE SUBJECT, so the fixture sets committer dates rather than
# hoping. A branch's age here is the age of its TIP, which is what the check
# reads, and both halves of the D01/D02 pair are built by this one function with
# one argument different.
mk_branch_aged() { # <repo> <branch> <file> <hours-ago>
    local repo="$1" branch="$2" file="$3" hours="$4"
    local when
    when="$(python3 -c "
import time, sys
print(int(time.time()) - int(float(sys.argv[1]) * 3600))" "$hours")"
    git -C "$repo" checkout -q -b "$branch" main
    printf '%s\n' "$file" > "$repo/$file"
    git -C "$repo" add -- "$file" >/dev/null 2>&1
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
        git -C "$repo" commit -qm "work on $branch" >/dev/null 2>&1
    git -C "$repo" checkout -q main
}

mk_repo "$SEAT"; adopt "$SEAT"
mk_repo "$FAR";  adopt "$FAR"

# --- the fixture -----------------------------------------------------------
mk_branch_aged "$SEAT" old-and-orphaned  old.txt      9      # past 3h
mk_branch_aged "$SEAT" young-and-orphaned young.txt   0.25   # under 3h
mk_branch_aged "$SEAT" landed-later       landed.txt  9      # past 3h, lands below
mk_branch_aged "$SEAT" held-by-a-live-agent held.txt  9      # past 3h, but locked
mk_branch_aged "$SEAT" codex/ceo-owned     codex.txt  9      # past 3h, the CEO's
git -C "$SEAT" worktree add -q --checkout "$SANDBOX/held" held-by-a-live-agent >/dev/null 2>&1
git -C "$SEAT" worktree lock "$SANDBOX/held" >/dev/null 2>&1

python3 - "$LEDGER" "$SESSION" "$SEAT" "$FAR" <<'PY'
import json, sys
path, sid, seat, far = sys.argv[1:5]
rows = [
    {"event": "registered", "class": "hand-rolled", "session_id": sid,
     "teammate": "dev-opus-a1", "repo": seat, "branch": "old-and-orphaned",
     "worktree": seat + "-wt-a1", "agent_id": "aaa1"},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY

ESC="$SANDBOX/escalations.jsonl"
export RICHOS_ESCALATION_LEDGER="$ESC"
export RICHOS_WORKTREE_LEDGER="$LEDGER"

# ===========================================================================
# DRIVERS
# ===========================================================================
RUN_OUT=""; RUN_RC=0
check() { # [extra args...]
    RUN_OUT="$(python3 "$CHECK" --entity-root "$SEAT" --session "$SESSION" \
        --ledger "$LEDGER" --escalation-ledger "$ESC" "$@" 2>&1)"
    RUN_RC=$?
    return 0
}

# ONE number, always. The first draft was
#   [ -f "$ESC" ] && grep -c ... || echo 0
# which on a MISSING file printed BOTH branches and gave `0\n0`, and `[ 0\n0 -gt
# 0 ]` is a shell error that reads as a failing case. A fixture that miscounts
# looks exactly like a finding, which is the thing this suite exists to avoid.
esc_rows()  { python3 -c '
import json, sys
try:
    print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("event") == "Escalation"))
except Exception:
    print(0)' "$ESC"; }
ack_rows()  { python3 -c '
import json, sys
try:
    print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("event") == "EscalationAck"))
except Exception:
    print(0)' "$ESC"; }
state_of() { # <branch> — the state the check gives one branch
    printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("UNPARSEABLE"); raise SystemExit
want = sys.argv[1]
for i in d.get("items", []):
    if i.get("branch") == want:
        print(i.get("state", "")); break
else:
    print("ABSENT")
' "$1"
}

# ===========================================================================
# D01/D02 — the pair the whole thing rests on
# ===========================================================================
check --format json
S="$(state_of old-and-orphaned)"
if [ "$S" = "undisposed" ]; then
    ok "D01 finished work standing longer than the threshold is UNDISPOSED"
else
    bad "D01 finished work standing longer than the threshold is UNDISPOSED" "state was '$S'"
fi

S="$(state_of young-and-orphaned)"
if [ "$S" = "young" ]; then
    ok "D02 the identical branch under the threshold is YOUNG and owes nothing"
else
    bad "D02 the identical branch under the threshold is YOUNG and owes nothing" "state was '$S'"
fi

# ===========================================================================
# D23 — THE AGE IS MEASURED, NOT INHERITED ROUNDED
# ===========================================================================
# The branch sweep this is built on carries `age_days` rounded to ONE DECIMAL,
# which is right for its own job (it orders a list and prints "3.4 days old")
# and quietly wrong here: a tenth of a day is 2.4 HOURS. Reading the threshold
# off that value means comparing a number derived to a hundredth of an hour
# against one that can only ever be 0, 2.4, 4.8, 7.2... and a branch standing
# 3.1 hours rounds DOWN to 2.4 and escapes the demand entirely.
#
# This is a REGRESSION PIN with a number chosen to sit in the gap: 3.1 hours is
# past the 3-hour threshold and would round to 2.4. The acceptance
# demonstration is what caught the defect -- it printed a branch built at 3.95
# hours as "4.8h" -- and the unit suite said nothing, so the unit suite now
# holds the line.
mk_branch_aged "$SEAT" just-past-the-line line.txt 3.1
check --format json
AGE="$(printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
for i in json.load(sys.stdin).get("items", []):
    if i.get("branch") == "just-past-the-line":
        print("%s %.2f" % (i.get("state"), i.get("age_hours") or 0)); break
else:
    print("ABSENT 0")')"
PRECISE="$(printf '%s' "$AGE" | python3 -c '
import sys
state, hours = sys.stdin.read().split()
print("yes" if state == "undisposed" and abs(float(hours) - 3.1) < 0.05 else "no")')"
if [ "$PRECISE" = "yes" ]; then
    ok "D23 3.1h past a 3h threshold is DEMANDED, and reads 3.1h not 2.4h ($AGE)"
else
    bad "D23 3.1h past a 3h threshold is DEMANDED, and reads 3.1h not 2.4h" \
        "state+age='$AGE'"
fi
git -C "$SEAT" merge -q --no-edit just-past-the-line >/dev/null 2>&1
check --format json

# ===========================================================================
# D08 — live work is never demanded on
# ===========================================================================
S="$(state_of held-by-a-live-agent)"
if [ "$S" = "ABSENT" ]; then
    ok "D08 a branch a LOCKED worktree holds is not a finding at all"
else
    bad "D08 a branch a LOCKED worktree holds is not a finding at all" "state was '$S'"
fi

# ===========================================================================
# D10 — the codex/ prefix is the CEO's
# ===========================================================================
S="$(state_of codex/ceo-owned)"
if [ "$S" = "ceo-owned" ]; then
    ok "D10a a codex/ branch is NAMED rather than passed over in silence"
else
    bad "D10a a codex/ branch is NAMED rather than passed over in silence" "state was '$S'"
fi

# ===========================================================================
# D16 — the exit codes never collapse
# ===========================================================================
if [ "$RUN_RC" = "3" ]; then
    ok "D16a something is owed and the exit code says 3"
else
    bad "D16a something is owed and the exit code says 3" "rc=$RUN_RC"
fi

# ===========================================================================
# D01 continued — the demand is actually WRITTEN
# ===========================================================================
BEFORE="$(esc_rows)"
check --demand --format json
AFTER="$(esc_rows)"
RAISED="$(printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
try:
    print(len(json.loads(sys.stdin.read()).get("raised", [])))
except Exception:
    print(-1)')"
if [ "$RAISED" = "2" ] && [ "$AFTER" -gt "$BEFORE" ]; then
    # two: old-and-orphaned and landed-later. young/live/codex raise nothing.
    ok "D01b --demand writes exactly one row per undisposed piece of work"
else
    bad "D01b --demand writes exactly one row per undisposed piece of work" \
        "raised=$RAISED rows $BEFORE -> $AFTER"
fi

if grep -q '"kind": *"land-disposition"' "$ESC" 2>/dev/null \
   && grep -q '"state": *"work-complete"' "$ESC" 2>/dev/null; then
    ok "D01c the demand is a work-complete record, not a stall"
else
    bad "D01c the demand is a work-complete record, not a stall"
fi

if ! grep -q 'codex/ceo-owned' "$ESC" 2>/dev/null; then
    ok "D10b a codex/ branch is NEVER demanded on"
else
    bad "D10b a codex/ branch is NEVER demanded on" "a demand names it"
fi

# ===========================================================================
# D03 — idempotent on (repo, branch, tip)
# ===========================================================================
BEFORE="$(esc_rows)"
check --demand --format json
AFTER="$(esc_rows)"
if [ "$AFTER" = "$BEFORE" ]; then
    ok "D03 the same demand raised twice is still ONE row"
else
    bad "D03 the same demand raised twice is still ONE row" "$BEFORE -> $AFTER"
fi

S="$(state_of old-and-orphaned)"
if [ "$S" = "demanded" ]; then
    ok "D03b once raised, the work reads as DEMANDED rather than undisposed"
else
    bad "D03b once raised, the work reads as DEMANDED rather than undisposed" "state '$S'"
fi

# ===========================================================================
# D04 — a new commit is new work at risk, so it demands again
# ===========================================================================
NEWWHEN="$(python3 -c 'import time; print(int(time.time()) - 9*3600)')"
git -C "$SEAT" checkout -q old-and-orphaned
printf 'more\n' > "$SEAT/more.txt"
git -C "$SEAT" add -- more.txt >/dev/null 2>&1
GIT_AUTHOR_DATE="$NEWWHEN +0000" GIT_COMMITTER_DATE="$NEWWHEN +0000" \
    git -C "$SEAT" commit -qm "more work" >/dev/null 2>&1
git -C "$SEAT" checkout -q main
BEFORE="$(esc_rows)"
check --demand --format json
AFTER="$(esc_rows)"
if [ "$AFTER" -gt "$BEFORE" ]; then
    ok "D04 a NEW COMMIT on a demanded branch demands again — new work at risk"
else
    bad "D04 a NEW COMMIT on a demanded branch demands again — new work at risk" \
        "$BEFORE -> $AFTER"
fi

# ===========================================================================
# D05/D06 — auto-satisfaction, and its twin that must NOT close
# ===========================================================================
ACKS_BEFORE="$(ack_rows)"
git -C "$SEAT" merge -q --no-edit landed-later >/dev/null 2>&1
check --demand --format json
ACKS_AFTER="$(ack_rows)"
# Counted BY KIND, not in total. This run closes two demands and both are
# right: `landed-later` because it landed, and the older `old-and-orphaned`
# demand because D04's new commit superseded it. A total would have made the
# two indistinguishable, and the first draft asserted 1 and went red on
# correct behavior.
CLOSED="$(printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
try:
    c = json.loads(sys.stdin.read()).get("closed", [])
except Exception:
    print("-1 -1"); raise SystemExit
sup = [x for x in c if "superseded" in str(x.get("trunk_head", ""))]
print("%d %d" % (len(c) - len(sup), len(sup)))')"
if [ "$CLOSED" = "1 1" ] && [ "$ACKS_AFTER" -gt "$ACKS_BEFORE" ]; then
    ok "D05 a demand whose work LANDED closes itself, with no hand on it"
else
    bad "D05 a demand whose work LANDED closes itself, with no hand on it" \
        "closed 'landed superseded' = '$CLOSED' acks $ACKS_BEFORE -> $ACKS_AFTER"
fi

if [ "${CLOSED#* }" = "1" ]; then
    ok "D22 a demand a newer one replaced is CLOSED as superseded, not left standing"
else
    bad "D22 a demand a newer one replaced is CLOSED as superseded, not left standing" \
        "closed 'landed superseded' = '$CLOSED'"
fi

if grep -q 'is an ancestor of' "$ESC" 2>/dev/null \
   && grep -q 'established this with' "$ESC" 2>/dev/null; then
    ok "D05b the closing ack states the FACT that closed it, with the SHA"
else
    bad "D05b the closing ack states the FACT that closed it, with the SHA"
fi

OPEN_OLD="$(python3 - "$ESC" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acked = {r.get("id") for r in rows if r.get("event") == "EscalationAck"}
open_branches = {r.get("branch") for r in rows
                 if r.get("event") == "Escalation" and r.get("id") not in acked}
print("yes" if "old-and-orphaned" in open_branches else "no")
PY
)"
if [ "$OPEN_OLD" = "yes" ]; then
    ok "D06 the demand whose work did NOT land is still standing"
else
    bad "D06 the demand whose work did NOT land is still standing"
fi

# ===========================================================================
# D11 — NOTHING IS EVER DELETED. The CEO's constraint, checked on the tree.
# ===========================================================================
MISSING=""
for b in old-and-orphaned young-and-orphaned held-by-a-live-agent codex/ceo-owned; do
    git -C "$SEAT" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 \
        || MISSING="$MISSING $b"
done
[ -d "$SANDBOX/held" ] || MISSING="$MISSING the-locked-worktree"
if [ -z "$MISSING" ]; then
    ok "D11 after three --demand runs every branch and worktree still exists"
else
    bad "D11 after three --demand runs every branch and worktree still exists" \
        "gone:$MISSING"
fi

# ===========================================================================
# D12 — mechanical, because "it does not delete" must not rest on anyone's word
# ===========================================================================
# EXTRACT THE VERBS, DO NOT GREP FOR STRINGS. The first draft grepped for the
# word `commit` anywhere in the file and turned red on `cat-file -e <tip>^{commit}`
# — a READ, and the very read that makes auto-satisfaction survive a deleted
# branch. A check that cannot tell a git subcommand from a rev-parse suffix
# would have to be waived on its first true run, and a check that gets waived
# is how g11, g12 and g13 died. So this pulls out the SUBCOMMAND POSITION of
# every git invocation and holds it against an allowlist of readers.
# The extractor goes to a FILE rather than into $( <<HEREDOC ), because a
# heredoc body carrying regular expressions full of quotes and parentheses is
# read by bash's command-substitution parser before python ever sees it, and it
# refused the whole suite with a syntax error 30 lines further down.
cat > "$SANDBOX/verbs.py" <<'PY'
import re, sys
# python:  git(root, ["<verb>", ...])   and   ["git", "-C", x, "<verb>", ...]
# `worktree` alone is not an answer: `worktree list` reads and `worktree remove`
# destroys, so the sub-verb is captured with it and the pair is what is judged.
PY_A = re.compile(r'\bgit\(\s*[A-Za-z_][\w.\[\]"\']*\s*,\s*\[\s*"(worktree"\s*,\s*"[a-z-]+|[a-z][a-z-]*)"')
PY_B = re.compile(r'\[\s*"git"\s*,\s*"-C"\s*,\s*[^,\]]+,\s*"(worktree"\s*,\s*"[a-z-]+|[a-z][a-z-]*)"')
# shell:   git -C <x> <verb>            and   git <verb>
SH_A = re.compile(r'(?m)(?<!\w)git\s+(?:-C\s+\S+\s+)?(worktree\s+[a-z-]+|[a-z][a-z-]*)')
found = set()
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    # Comments go, and so do double-quoted string literals. Without the second
    # step the sentence "git is not on PATH" -- an operator message, in a hook
    # whose whole subject is saying so out loud -- is read as the git subcommand
    # `is`, and the case goes red on prose. A check that has to be waived on
    # prose is a check that gets waived.
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    body = re.sub(r'"[^"\n]*"', '""', body)
    for rx in (PY_A, PY_B):
        found.update(rx.findall(text))
    if path.endswith((".sh",)):
        found.update(SH_A.findall(body))
# normalize `worktree",  "list` and `worktree list` to one token pair
print(" ".join(sorted(re.sub(r'["\s,]+', ":", v).strip(":") for v in found)))
PY
VERBS="$(python3 "$SANDBOX/verbs.py" "$CHECK" "$CMD" "$NOTICE" "$MEASURE")"
READERS=" rev-parse rev-list for-each-ref worktree:list merge-base cat-file log show-ref "
MUTATORS=""
for v in $VERBS; do
    case "$READERS" in *" $v "*) : ;; *) MUTATORS="$MUTATORS $v" ;; esac
done
if [ -z "$MUTATORS" ]; then
    ok "D12 every git verb in the tool is a reader (found:${VERBS:-none})"
else
    bad "D12 every git verb in the tool is a reader (found:${VERBS:-none})" \
        "not readers:$MUTATORS"
fi

# ===========================================================================
# D07 — a tip that cannot be read is UNDECIDED, and is NEVER closed
# ===========================================================================
# A demand naming a tip this repository has never contained. The honest answer
# is "unknown", and the dishonest one that must not happen is "not landed, so
# still owed" or, worse, "landed, closed".
python3 - "$ESC" "$SEAT" <<'PY'
import json, sys
path, seat = sys.argv[1:3]
row = {"event": "Escalation", "kind": "land-disposition",
       "id": "esc-20260101T000000Z-deadbeef", "raised": "2026-01-01T00:00:00Z",
       "teammate": "ghost", "worktree": "", "branch": "vanished",
       "repo": seat, "head": "0" * 40, "state": "work-complete", "for": "lead",
       "title": "a tip nothing can read", "question": "x" * 25,
       "tried": "", "meanwhile": "", "record": "", "session_id": "",
       "actor": "test"}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
PY
check --demand --format json
UND="$(printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(len([u for u in d.get("undecided", []) if u.get("branch") == "vanished"]))')"
STILL_OPEN="$(python3 - "$ESC" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acked = {r.get("id") for r in rows if r.get("event") == "EscalationAck"}
print("yes" if "esc-20260101T000000Z-deadbeef" not in acked else "no")
PY
)"
if [ "$UND" = "1" ] && [ "$STILL_OPEN" = "yes" ]; then
    ok "D07 a demand whose tip cannot be read is UNDECIDED and stays open"
else
    bad "D07 a demand whose tip cannot be read is UNDECIDED and stays open" \
        "undecided=$UND still_open=$STILL_OPEN"
fi

# ===========================================================================
# D09 / D20 — the escape hatch, USED IN THE STATE WHERE THE DEMAND FIRES (R7)
# ===========================================================================
OLD_ID="$(python3 - "$ESC" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acked = {r.get("id") for r in rows if r.get("event") == "EscalationAck"}
# the NEWEST outstanding demand for this branch: the one about the tip that is
# actually standing today.
last = ""
for r in rows:
    if (r.get("event") == "Escalation" and r.get("branch") == "old-and-orphaned"
            and r.get("id") not in acked):
        last = r["id"]
print(last)
PY
)"
if [ -n "$OLD_ID" ] && [ -x "$ESCALATE" ]; then
    ACK_OUT="$(bash "$ESCALATE" ack "$OLD_ID" --disposition \
        "Held: the merge conflicts with a decision only the CEO can make, and it lands the moment he rules." 2>&1)"
    ACK_RC=$?
else
    ACK_OUT="no id or no escalate.sh"; ACK_RC=1
fi
if [ "$ACK_RC" = "0" ]; then
    ok "D20 the escape hatch runs in the state where the demand fires (R7)"
else
    bad "D20 the escape hatch runs in the state where the demand fires (R7)" "$ACK_OUT"
fi

check --format json
S="$(state_of old-and-orphaned)"
REASON_SHOWN=0
check --format text
printf '%s' "$RUN_OUT" | grep -q "REASON   : Held: the merge conflicts" && REASON_SHOWN=1
if [ "$S" = "held" ] && [ "$REASON_SHOWN" = "1" ]; then
    ok "D09 an acknowledged demand reads as HELD and the REASON is printed"
else
    bad "D09 an acknowledged demand reads as HELD and the REASON is printed" \
        "state='$S' reason_shown=$REASON_SHOWN"
fi

# ===========================================================================
# D18 — R5: the two honest sections print even when they are empty
# ===========================================================================
check --format text
if printf '%s' "$RUN_OUT" | grep -q "COULD NOT DECIDE" \
   && printf '%s' "$RUN_OUT" | grep -q "NOT EXAMINED"; then
    ok "D18 COULD NOT DECIDE and NOT EXAMINED are printed, empty or not"
else
    bad "D18 COULD NOT DECIDE and NOT EXAMINED are printed, empty or not"
fi

# ===========================================================================
# D19 — one sweep, so the report and the code cannot disagree
# ===========================================================================
check --format text
TEXT_RC=$RUN_RC
check --format json
JSON_RC=$RUN_RC
if [ "$TEXT_RC" = "$JSON_RC" ]; then
    ok "D19 the same state gives the same exit code in every format"
else
    bad "D19 the same state gives the same exit code in every format" \
        "text=$TEXT_RC json=$JSON_RC"
fi

# ===========================================================================
# D16b/D16c — nothing owed is 0; unexamined is 4 and never 0
# ===========================================================================
CLEAN="$SANDBOX/clean"
mk_repo "$CLEAN"; adopt "$CLEAN"
RUN_OUT="$(python3 "$CHECK" --entity-root "$CLEAN" --ledger "$SANDBOX/none.jsonl" \
    --escalation-ledger "$SANDBOX/none-esc.jsonl" --format json 2>&1)"
if [ "$?" = "0" ]; then
    ok "D16b a repository with nothing outstanding exits 0"
else
    bad "D16b a repository with nothing outstanding exits 0" "rc=$?"
fi

RUN_OUT="$(python3 "$CHECK" --entity-root "$SANDBOX/not-a-repo-at-all" \
    --ledger "$SANDBOX/none.jsonl" --escalation-ledger "$SANDBOX/none-esc.jsonl" \
    --format json 2>&1)"
NRC=$?
if [ "$NRC" = "4" ]; then
    ok "D16c nothing examinable exits 4 — an unexamined main is not a clean one"
else
    bad "D16c nothing examinable exits 4 — an unexamined main is not a clean one" "rc=$NRC"
fi

# ===========================================================================
# D17 — writes per run are bounded, and the overflow is COUNTED not lost
# ===========================================================================
BULK="$SANDBOX/bulk"
BULK_ESC="$SANDBOX/bulk-esc.jsonl"
mk_repo "$BULK"; adopt "$BULK"
for i in 1 2 3 4 5 6 7 8 9; do
    mk_branch_aged "$BULK" "bulk-$i" "b$i.txt" 9
done
RUN_OUT="$(python3 "$CHECK" --entity-root "$BULK" --ledger "$SANDBOX/none.jsonl" \
    --escalation-ledger "$BULK_ESC" --demand --format json 2>&1)"
NRAISED="$(printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print("%d %d %d" % (len(d.get("raised", [])), d.get("n_deferred", -1),
                    d.get("n_undisposed", -1)))')"
# six written, three deferred, nine still owed. The middle number is the one
# that matters: "six demands were raised" and "six were raised and three more
# were owed and were not" are different facts, and only one of them is true on
# a busy day. It was invisible until this case asked for it.
if [ "$NRAISED" = "6 3 3" ]; then
    ok "D17 nine owed raise six demands, and the three deferred are COUNTED"
else
    bad "D17 nine owed raise six demands, and the three deferred are COUNTED" \
        "got 'raised deferred still-undisposed' = '$NRAISED' (want '6 3 3')"
fi
if printf '%s' "$RUN_OUT" | python3 -c '
import json, sys
sys.exit(0 if "NOT written this run" in json.loads(sys.stdin.read())["summary"] else 1)'; then
    ok "D17b the deferred overflow is named in the one line the operator reads"
else
    bad "D17b the deferred overflow is named in the one line the operator reads"
fi

# ===========================================================================
# D13/D14/D15 — the notice: never blocks, and announces every way it stops
# ===========================================================================
mk_payload() { # <variant>
    python3 - "${1:-control}" "$SEAT" "$SESSION" <<'PY'
import json, sys
variant, cwd, sid = sys.argv[1:4]
d = {"hook_event_name": "Stop", "stop_hook_active": False, "session_id": sid,
     "cwd": cwd, "last_assistant_message": "done", "padding": "z" * 300}
s = json.dumps(d)
if variant == "control":
    sys.stdout.write(s)
elif variant == "empty":
    sys.stdout.write("")
elif variant == "truncated":
    sys.stdout.write(s[:s.index('"padding"') + 30])
else:
    sys.stdout.write("not json at all " + "z" * 100)
PY
}

BLOCKED=""
for v in control empty truncated garbage; do
    OUT="$(mk_payload "$v" | RICHOS_ESCALATION_LEDGER="$ESC" \
        RICHOS_WORKTREE_LEDGER="$LEDGER" bash "$NOTICE" 2>/dev/null)"
    RC=$?
    [ "$RC" = "0" ] || BLOCKED="$BLOCKED $v(rc=$RC)"
done
if [ -z "$BLOCKED" ]; then
    ok "D13 the notice exits 0 on every payload — it never refuses a turn"
else
    bad "D13 the notice exits 0 on every payload — it never refuses a turn" "$BLOCKED"
fi

OUT="$(mk_payload control | RICHOS_ESCALATION_LEDGER="$ESC" \
    RICHOS_WORKTREE_LEDGER="$LEDGER" CHECK_LAND_DISPOSITION=0 bash "$NOTICE" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q "STOOD DOWN"; then
    ok "D14 standing the check down ANNOUNCES itself — never a silent permission"
else
    bad "D14 standing the check down ANNOUNCES itself — never a silent permission" "$OUT"
fi

BROKEN="$SANDBOX/broken-engine"
mkdir -p "$BROKEN/scripts/hooks" "$BROKEN/scripts/lib"
cp "$NOTICE" "$BROKEN/scripts/hooks/"
for f in resolve-roots.sh stop-hook-notice.sh unevaluated-notice.sh; do
    [ -f "$ENGINE_ROOT/scripts/lib/$f" ] && cp "$ENGINE_ROOT/scripts/lib/$f" "$BROKEN/scripts/lib/"
done
OUT="$(mk_payload control | RICHOS_ESCALATION_LEDGER="$ESC" \
    RICHOS_WORKTREE_LEDGER="$LEDGER" \
    bash "$BROKEN/scripts/hooks/notice-land-disposition.sh" 2>/dev/null)"
RC=$?
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "NOT RUNNING\|IS OFF\|SWEPT NOTHING\|UNCHECKED"; then
    ok "D15 a missing analyzer is ANNOUNCED, not mistaken for a clean main"
else
    bad "D15 a missing analyzer is ANNOUNCED, not mistaken for a clean main" \
        "rc=$RC out='$OUT'"
fi

# ===========================================================================
# D21 — the measuring script proposes nothing, and says so where it is read
# ===========================================================================
if [ -f "$MEASURE" ]; then
    OUT="$(python3 "$MEASURE" --repo "$SEAT" --ledger "$SANDBOX/none.jsonl" 2>&1)"
    if printf '%s' "$OUT" | grep -q "NO THRESHOLD IS PROPOSED HERE" \
       || printf '%s' "$OUT" | grep -q "NOTHING MEASURED"; then
        ok "D21 the derivation refuses to propose a threshold, in the output"
    else
        bad "D21 the derivation refuses to propose a threshold, in the output" "$OUT"
    fi
else
    bad "D21 the derivation refuses to propose a threshold, in the output" "missing $MEASURE"
fi

echo ""
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
