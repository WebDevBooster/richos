#!/usr/bin/env bash
#
# land-disposition.acceptance.sh — REPRODUCE 2026-09-10 AND WATCH IT NOT HAPPEN.
#
# ===========================================================================
# WHAT IT REPRODUCES
# ===========================================================================
# Five finished agents, five workspaces held because their branches were
# unmerged, no land, no deadline, no demand, and nobody the hold belonged to.
# The founder found them by looking at the branch list in his own IDE. The real
# names and the real standing times, measured from the landings themselves:
#
#     echo-opus-win1                     7 commits    3.95 h
#     zach-opus-dor1                     1 commit     6.90 h
#     zach-opus-prem1                    3 commits    6.93 h
#     worktree-agent-a69a6328ea2c81817   1 commit    12.45 h
#     echo-opus-dr1                      2 commits   47.44 h
#
# `echo-opus-win1` is the one that matters most: the off-screen-window fix he
# had already asked about twice, sitting at 3.95 hours — under four — which is
# why a threshold picked casually at "a day" would have been useless.
#
# This is a DEMONSTRATION, not a unit test. land-disposition.test.sh proves the
# mechanism case by case in a sandbox; this shows the whole lifecycle end to end
# on the shape the incident actually had, in the order it actually happened,
# and prints what an operator would have seen. Run it when the question is "and
# would it have caught THAT?" rather than "does the code work".
#
# Nothing outside the sandbox is read or written: its own repository, its own
# ownership ledger, its own escalation ledger, all under mktemp.
#
# Usage: scripts/hooks/land-disposition.acceptance.sh
# Exit:  0 the demonstration held at every step, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$ENGINE_ROOT/scripts/lib/land-disposition.py"
ESCALATE="$ENGINE_ROOT/scripts/escalate.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "ERROR: needs git" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t landdisp-acc.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/richos"
ESC="$SANDBOX/escalations.jsonl"
LED="$SANDBOX/worktree-ledger.jsonl"
SESSION="d0eef867-0000-4000-8000-000000000000"

mkdir -p "$REPO" "$SANDBOX/nohooks"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "tester@example.invalid"
git -C "$REPO" config user.name  "tester"
git -C "$REPO" config core.hooksPath "$SANDBOX/nohooks"
printf 'seed\n' > "$REPO/README.md"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm seed >/dev/null 2>&1
: > "$REPO/orchestration.config"
mkdir -p "$REPO/.claude/state"
printf 'orchestration.config\n.claude/\n' > "$REPO/.git/info/exclude"

age() { python3 -c "import time,sys;print(int(time.time())-int(float(sys.argv[1])*3600))" "$1"; }

# <branch> <commits> <hours standing>
finished_agent() {
    local br="$1" n="$2" hours="$3" i when flat
    # A branch name may contain a slash (`codex/owned-outcome-prd`) and a FILE
    # name may not, unless the directory exists. The first draft used the branch
    # name as the file name, the write failed, the codex branch was created with
    # NO COMMIT — so it was not ahead of main, so it was not a finding, so the
    # case that proves a codex branch is never demanded on PASSED BY EXAMINING
    # NOTHING. A negative case needs a positive probe.
    flat="${br//\//-}"
    git -C "$REPO" checkout -q -b "$br" main
    for i in $(seq 1 "$n"); do
        printf '%s %s\n' "$br" "$i" > "$REPO/$flat-$i.txt"
        git -C "$REPO" add -- "$flat-$i.txt" >/dev/null 2>&1
        when="$(age "$hours")"
        GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
            git -C "$REPO" commit -qm "$br commit $i" >/dev/null 2>&1
    done
    git -C "$REPO" checkout -q main
}

echo "=== 2026-09-10, reproduced: five finished agents and nobody landing them ==="
echo ""

finished_agent echo-opus-win1                   7 3.95
finished_agent zach-opus-dor1                   1 6.90
finished_agent zach-opus-prem1                  3 6.93
finished_agent worktree-agent-a69a6328ea2c81817 1 12.45
finished_agent echo-opus-dr1                    2 47.44
# ...and the two that must stay silent, built the same way, one fact changed.
finished_agent zach-opus-still-working          1 0.20     # young
finished_agent codex/owned-outcome-prd          1 19.20    # the CEO's

python3 - "$LED" "$SESSION" "$REPO" <<'PY'
import json, sys
path, sid, repo = sys.argv[1:4]
owners = [("echo-opus-win1", "echo-opus-win1"), ("zach-opus-dor1", "zach-opus-dor1"),
          ("zach-opus-prem1", "zach-opus-prem1"),
          ("worktree-agent-a69a6328ea2c81817", ""),
          ("echo-opus-dr1", "echo-opus-dr1"),
          ("zach-opus-still-working", "zach-opus-still-working")]
with open(path, "w", encoding="utf-8") as fh:
    for branch, teammate in owners:
        fh.write(json.dumps({
            "event": "registered", "class": "hand-rolled", "session_id": sid,
            "teammate": teammate, "repo": repo, "branch": branch,
            "worktree": repo + "-wt-" + branch.replace("/", "-"),
            "agent_id": ""}) + "\n")
PY

run() {
    python3 "$CHECK" --entity-root "$REPO" --session "$SESSION" --ledger "$LED" \
        --escalation-ledger "$ESC" "$@"
}

# ---------------------------------------------------------------------------
# STEP 1 — the turn ends. Before this work, nothing happened here at all.
# ---------------------------------------------------------------------------
echo "--- STEP 1: the turn ends with five finished agents unlanded"
OUT="$(run --demand --format json 2>&1)"; RC=$?
SUMMARY="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"])')"
NRAISED="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["raised"]))')"
echo ""
echo "  what the operator sees:"
printf '%s\n' "$SUMMARY" | fold -s -w 76 | sed 's/^/      /'
echo ""

if [ "$NRAISED" = "5" ]; then
    ok "A01 all five carry a demand — one per piece of finished work"
else
    bad "A01 all five carry a demand — one per piece of finished work" "raised=$NRAISED"
fi
if printf '%s' "$SUMMARY" | grep -q "echo-opus-win1"; then
    ok "A02 the window fix he asked about twice is NAMED in the line he reads"
else
    bad "A02 the window fix he asked about twice is NAMED in the line he reads"
fi
if [ "$RC" = "3" ]; then
    ok "A03 the exit code says something is owed"
else
    bad "A03 the exit code says something is owed" "rc=$RC"
fi
if ! grep -q "zach-opus-still-working" "$ESC" 2>/dev/null; then
    ok "A04 the agent that finished twelve minutes ago is NOT demanded on"
else
    bad "A04 the agent that finished twelve minutes ago is NOT demanded on"
fi
# THE POSITIVE PROBE FIRST. "No demand names it" is satisfied just as well by a
# branch the check never saw, which is exactly how the first draft of this case
# passed while its fixture was broken. So: it must be a finding, it must be
# nineteen hours old — six times the threshold — and only THEN does the absence
# of a demand mean anything.
CEO_STATE="$(printf '%s' "$OUT" | python3 -c '
import json, sys
for i in json.load(sys.stdin).get("items", []):
    if i.get("branch") == "codex/owned-outcome-prd":
        print("%s %.0f" % (i.get("state"), i.get("age_hours") or 0)); break
else:
    print("ABSENT 0")')"
if [ "$CEO_STATE" = "ceo-owned 19" ] && ! grep -q "codex/owned-outcome-prd" "$ESC" 2>/dev/null; then
    ok "A05 the codex/ branch is SEEN at 19h and still never demanded on (ruling 31)"
else
    bad "A05 the codex/ branch is SEEN at 19h and still never demanded on (ruling 31)" \
        "state+age='$CEO_STATE' (want 'ceo-owned 19')"
fi

# ---------------------------------------------------------------------------
# STEP 2 — a working day passes with nobody looking. THE OLD DEFECT'S HOME.
# ---------------------------------------------------------------------------
echo "--- STEP 2: nobody looks. Does it fade, or does it get louder?"
python3 - "$ESC" <<'PY'
# Age the demands by 25 hours in place: the ledger's ladder is what makes an
# ignored demand louder, and this is the fact it reads.
import json, sys
from datetime import datetime, timedelta, timezone
path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()]
old = (datetime.now(timezone.utc) - timedelta(hours=25)).replace(microsecond=0)
for r in rows:
    if r.get("event") == "Escalation":
        r["raised"] = old.isoformat().replace("+00:00", "Z")
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
BUCKETS="$(python3 - "$ENGINE_ROOT" "$ESC" <<'PY'
import importlib.util, os, sys
root, esc = sys.argv[1:3]
os.environ["RICHOS_ESCALATION_LEDGER"] = esc
spec = importlib.util.spec_from_file_location("e", os.path.join(root, "scripts", "lib", "escalations.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows, _ = m.read_rows(esc)
print(" ".join(sorted({e["bucket"] for e in m.outstanding(rows)})))
PY
)"
if [ "$BUCKETS" = "24h" ]; then
    ok "A06 a day later every demand has crossed into the 24h bucket — LOUDER, not quieter"
else
    bad "A06 a day later every demand has crossed into the 24h bucket — LOUDER, not quieter" \
        "buckets='$BUCKETS'"
fi

# ---------------------------------------------------------------------------
# STEP 3 — three of the five get landed. They must close THEMSELVES.
# ---------------------------------------------------------------------------
echo "--- STEP 3: three are landed. Nobody acknowledges anything."
for br in echo-opus-win1 zach-opus-dor1 echo-opus-dr1; do
    git -C "$REPO" merge -q --no-edit "$br" >/dev/null 2>&1
done
OUT="$(run --demand --format json 2>&1)"
NCLOSED="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["closed"]))')"
if [ "$NCLOSED" = "3" ]; then
    ok "A07 the three that landed closed themselves, with no hand on them"
else
    bad "A07 the three that landed closed themselves, with no hand on them" "closed=$NCLOSED"
fi
# READ THE LEDGER, not the run's summary. The disposition is what a person will
# find months later; the run's `closed` list is a convenience that does not
# carry it, and the first draft grepped the convenience.
FACTUAL="$(python3 - "$ESC" <<'PY'
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
n = 0
for r in rows:
    if r.get("event") != "EscalationAck":
        continue
    d = r.get("disposition") or ""
    if "is an ancestor of main at" in d and re.search(r"\b[0-9a-f]{12}\b", d):
        n += 1
print(n)
PY
)"
if [ "$FACTUAL" = "3" ]; then
    ok "A08 each closure states the FACT that closed it, with the integrating SHA"
else
    bad "A08 each closure states the FACT that closed it, with the integrating SHA" \
        "acks carrying an ancestor fact and a SHA: $FACTUAL (want 3)"
fi

# ---------------------------------------------------------------------------
# STEP 4 — one is genuinely held. The hatch runs in the state where it fires.
# ---------------------------------------------------------------------------
echo "--- STEP 4: one has a real conflict. It is HELD, with a reason."
HELD_ID="$(python3 - "$ESC" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acked = {r.get("id") for r in rows if r.get("event") == "EscalationAck"}
for r in rows:
    if (r.get("event") == "Escalation" and r.get("branch") == "zach-opus-prem1"
            and r.get("id") not in acked):
        print(r["id"]); break
PY
)"
ACK_OUT="$(RICHOS_ESCALATION_LEDGER="$ESC" bash "$ESCALATE" ack "$HELD_ID" --disposition \
    "HELD: the merge conflicts over a test count where both sides are wrong (984 vs 1035, measured 985). It lands when the true count is settled." 2>&1)"
ACK_RC=$?
if [ "$ACK_RC" = "0" ]; then
    ok "A09 the escape hatch runs in exactly the state the demand fires in (R7)"
else
    bad "A09 the escape hatch runs in exactly the state the demand fires in (R7)" "$ACK_OUT"
fi

OUT="$(run --format text 2>&1)"
if printf '%s' "$OUT" | grep -q "\[HELD\]" \
   && printf '%s' "$OUT" | grep -q "984 vs 1035"; then
    ok "A10 it reads as HELD and the REASON is printed where a person sees it"
else
    bad "A10 it reads as HELD and the REASON is printed where a person sees it"
fi

# ---------------------------------------------------------------------------
# STEP 5 — one is still owed. The line must still say so.
# ---------------------------------------------------------------------------
echo "--- STEP 5: one is still neither landed nor explained."
OUT="$(run --demand --format json 2>&1)"; RC=$?
SUMMARY="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"])')"
echo ""
echo "  what the operator sees now:"
printf '%s\n' "$SUMMARY" | fold -s -w 76 | sed 's/^/      /'
echo ""
if printf '%s' "$SUMMARY" | grep -q "worktree-agent-a69a6328ea2c81817" \
   && ! printf '%s' "$SUMMARY" | grep -q "echo-opus-win1"; then
    ok "A11 the one still owed is named; the three that landed are gone from the line"
else
    bad "A11 the one still owed is named; the three that landed are gone from the line"
fi
if [ "$RC" = "3" ]; then
    ok "A12 still owed, so still 3 — it does not go quiet because time passed"
else
    bad "A12 still owed, so still 3 — it does not go quiet because time passed" "rc=$RC"
fi

# ---------------------------------------------------------------------------
# STEP 6 — THE CONSTRAINT. Nothing was swept, deleted, merged or moved.
# ---------------------------------------------------------------------------
echo "--- STEP 6: what survived."
GONE=""
for b in echo-opus-win1 zach-opus-dor1 zach-opus-prem1 \
         worktree-agent-a69a6328ea2c81817 echo-opus-dr1 \
         zach-opus-still-working codex/owned-outcome-prd; do
    git -C "$REPO" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 \
        || GONE="$GONE $b"
done
if [ -z "$GONE" ]; then
    ok "A13 every branch still exists — the unmerged ones above all"
else
    bad "A13 every branch still exists — the unmerged ones above all" "deleted:$GONE"
fi

UNMERGED_TIP="$(git -C "$REPO" rev-parse worktree-agent-a69a6328ea2c81817)"
if git -C "$REPO" cat-file -e "$UNMERGED_TIP^{commit}" 2>/dev/null \
   && ! git -C "$REPO" merge-base --is-ancestor "$UNMERGED_TIP" main 2>/dev/null; then
    ok "A14 the unmerged branch is untouched and still outside main"
else
    bad "A14 the unmerged branch is untouched and still outside main"
fi

echo ""
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
