#!/usr/bin/env bash
#
# row-headline-verify.sh — RE-RUN WHAT THE ROWS CLAIM.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# guard-row-currency-commits.sh answers "has this row moved since somebody read
# its first sentence?". It cannot answer "is that first sentence TRUE", and no
# check that refuses to execute anything ever will be able to. On 2026-09-06
# sixteen rows of one record were found overtaken and ELEVEN OF THEM HAD A
# MATCHING BLOB PIN — the work had not moved, the world had. The only thing
# that can see that is running the command again.
#
# CHECK 3 in scripts/lib/row-currency.py makes every governed row carry that
# command and the output it produced. This is the tool that re-runs them.
#
# ===========================================================================
# WHY IT IS NOT A HOOK, AND WILL NOT BECOME ONE
# ===========================================================================
# Two reasons, both disqualifying on their own.
#
# COST. One of the commands in the record this was built for takes 2,168
# seconds. A landing gate that took half an hour would be waived on its first
# use, and a habitually waived gate is a dead gate. The whole design of the
# row-currency family is that the BLOCKING half is instant and reads no prose.
#
# TRUST. A record file is a document, not a trusted script. Executing a string
# somebody typed into a wiki cell, automatically, at every land, with the
# lander's credentials, is a code-execution path wearing a check's clothes. So
# this runs when a person asks it to, it PRINTS every command before running
# it, and it refuses two classes outright:
#
#   * anything that could make this machine produce SOUND. There is a standing
#     order about that on this machine, and a tool that executes arbitrary
#     strings is exactly how such an order gets broken by accident at 3 AM.
#   * anything that writes, publishes or destroys — `git push`, `rm -rf`,
#     `sudo`, a redirect into a file. A verifier that can change the thing it
#     is verifying is not a verifier.
#
# A refusal is REPORTED, never skipped silently: REFUSED is its own outcome and
# it is counted in the totals, because "nothing to check" and "we declined to
# check" are the two facts this whole engine keeps finding conflated.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scripts/row-headline-verify.sh <repo>              re-run every row
#   scripts/row-headline-verify.sh <repo> --list       print them, run none
#   scripts/row-headline-verify.sh <repo> --only 3.34  one row
#   scripts/row-headline-verify.sh <repo> --timeout 60 per-command ceiling
#
# Exit codes:
#   0  every row that could be re-run matched what it recorded
#   1  at least one row's command no longer produces what the row says
#   2  broken: no declaration, a malformed one, CHECK 3 not adopted, or a
#      checker that could not run

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/row-currency.sh"
[ -f "$LIB" ] || { echo "ERROR: row-headline-verify.sh: scripts/lib/row-currency.sh is missing at $LIB" >&2; exit 2; }
# shellcheck source=lib/row-currency.sh
. "$LIB"

REPO=""
LIST=""
ONLY=""
TIMEOUT=300
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)    LIST=1; shift ;;
        --only)    ONLY="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-300}"; shift 2 ;;
        -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
        -*)        echo "ERROR: row-headline-verify.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)         [ -n "$REPO" ] && { echo "ERROR: row-headline-verify.sh: more than one repository given" >&2; exit 2; }
                   REPO="$1"; shift ;;
    esac
done
[ -n "$REPO" ] || { echo "ERROR: row-headline-verify.sh: expected a repository path" >&2; exit 2; }
[ -d "$REPO" ] || { echo "ERROR: row-headline-verify.sh: no such directory: $REPO" >&2; exit 2; }
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "ERROR: row-headline-verify.sh: --timeout wants a whole number of seconds" >&2; exit 2 ;;
esac

rc_require_ceo_todos_lib || { rc_broken_banner "row-headline-verify.sh" "$RC_BROKEN_REASON" >&2; exit 2; }
ROOT="$(ct_repo_root "$REPO")" || { echo "ERROR: row-headline-verify.sh: $REPO is not inside a repository" >&2; exit 2; }

DECL_RC=0
rc_load_declaration "$ROOT" || DECL_RC=$?
case "$DECL_RC" in
  0) ;;
  1) echo "ERROR: row-headline-verify.sh: there is no $ROW_CURRENCY_DECLARATION in $ROOT, so no row is governed and nothing was checked. That is not a clean record; it is no record." >&2; exit 2 ;;
  *) rc_broken_banner "row-headline-verify.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

RES_RC=0
rc_resolve_record "$ROOT" || RES_RC=$?
case "$RES_RC" in
  0) ;;
  1) echo "ERROR: row-headline-verify.sh: $RC_STANDDOWN_REASON" >&2; exit 2 ;;
  *) rc_broken_banner "row-headline-verify.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

# NOT ADOPTED is its own answer, and it is loud. A verifier that printed
# "0 rows, all fine" over a record that never declared CHECK 3 would be the
# green tick over a scanner that never ran, which is the exact failure this
# family of checks was built to stop reporting.
if [ -z "$RC_HEADLINE_SECTIONS" ]; then
    {
        echo "=== ROW HEADLINES: NOT ADOPTED IN THIS RECORD ==="
        echo "  record : $RC_RECORD_REPO/$RC_RECORD_REL"
        echo "  $RC_DECLARATION_FILE declares no ROW_HEADLINE_SECTIONS, so no row"
        echo "  carries a **Headline:** warrant and there is nothing here to re-run."
        echo "  That is not a clean verification. It is no verification."
    } >&2
    exit 2
fi

WORK="$(mktemp -d -t row-headline-verify.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

RECORD="$RC_RECORD_REPO/$RC_RECORD_REL"
[ -f "$RECORD" ] || { echo "ERROR: row-headline-verify.sh: the declared record is not on disk: $RECORD" >&2; exit 2; }

RC_EMIT_HEADLINES=1
export RC_EMIT_HEADLINES
JOB="$WORK/job.json"
rc_build_job "$JOB" "$RECORD" "-" "-" "-" "by hand" "verify" "-" || {
    echo "ERROR: row-headline-verify.sh: could not assemble the check" >&2; exit 2; }

RESULT="$(rc_run "$JOB")" || { echo "ERROR: row-headline-verify.sh: the predicate could not run" >&2; exit 2; }
printf '%s\n' "$RESULT" | awk -F'\t' '$1=="HL"' > "$WORK/rows.tsv"

echo "=== ROW HEADLINES: re-deriving what the rows claim ==="
echo "  record   : $RECORD"
echo "  sections : $RC_HEADLINE_SECTIONS"
echo ""

RH_ROOTS="$CT_ROOTS_OK" RH_RECORD_REPO="$RC_RECORD_REPO" \
RH_ROWS="$WORK/rows.tsv" RH_LIST="$LIST" RH_ONLY="$ONLY" RH_TIMEOUT="$TIMEOUT" \
python3 - <<'PYEOF'
import os
import re
import subprocess
import sys

roots = {}
for pair in (os.environ.get("RH_ROOTS") or "").split("\t"):
    if "=" in pair:
        k, v = pair.split("=", 1)
        roots[k] = v
record_repo = os.environ["RH_RECORD_REPO"]
only = (os.environ.get("RH_ONLY") or "").strip()
listing = bool(os.environ.get("RH_LIST"))
timeout = int(os.environ.get("RH_TIMEOUT") or "300")

# ---------------------------------------------------------------------------
# THE TWO REFUSALS. Both are patterns over the command TEXT, which is a weaker
# test than a sandbox and is the honest one to state: a determined string can
# get past either. It is aimed at the accident, not at an attacker — a row
# whose evidence command happens to run an acceptance suite that speaks, or a
# row that pastes a `git push` into a cell.
# ---------------------------------------------------------------------------
SOUND = re.compile(
    r"(?:^|[\s;&|(])(?:say|afplay|osascript|spd-say|espeak|paplay|aplay|"
    r"ffplay|caffeinate\s+-d\b.*\bsay)\b|\\a|\btput\s+bel\b|--speak\b|"
    r"\bvoiced?_acceptance\b|\brichos-voice\b", re.I)
MUTATES = re.compile(
    r"(?:^|[\s;&|(])(?:sudo|rm|mv|cp|dd|mkfs|shutdown|reboot|kill|pkill|"
    r"killall|chmod|chown|npm|pip|cargo\s+publish|railway|convex)\b|"
    r"\bgit\s+(?:push|commit|merge|reset|clean|checkout|rebase|am|apply)\b|"
    r"[^<>]>[^&]|>>", re.I)

rows = []
with open(os.environ["RH_ROWS"], encoding="utf-8") as fh:
    for line in fh:
        f = line.rstrip("\n").split("\t")
        if len(f) < 6 or f[0] != "HL":
            continue
        rows.append({"id": f[1], "kind": f[2], "prefix": f[3],
                     "cmd": f[4], "expect": f[5]})

if not rows:
    sys.stderr.write(
        "ERROR: row-headline-verify.sh: the record declares headline sections "
        "and not one row carries a readable **Headline:** warrant. Nothing was "
        "re-run, and that is a finding rather than a pass.\n")
    sys.exit(2)

counts = {"MATCH": 0, "MISMATCH": 0, "UNVERIFIED": 0, "REFUSED": 0,
          "ERROR": 0, "LISTED": 0}
worst = 0

for row in rows:
    if only and row["id"] != only:
        continue
    rid = row["id"]

    if row["kind"] == "unverified":
        counts["UNVERIFIED"] += 1
        print("  UNVERIFIED  %-6s declared: %s" % (rid, row["cmd"]))
        continue

    cwd = roots.get(row["prefix"]) or record_repo
    cmd = row["cmd"]

    # THE REFUSALS COME BEFORE THE ANNOUNCEMENT, so that no line of this output
    # ever reads as though a refused command was attempted. "RUN" then
    # "REFUSED" is a report of something that did not happen, and this whole
    # engine is about not writing those.
    if SOUND.search(cmd):
        counts["REFUSED"] += 1
        worst = max(worst, 1)
        print("  REFUSED     %-6s this command could make the machine speak or "
              "beep, and a tool that executes strings out of a document does "
              "not get to find that out by trying." % rid)
        continue
    if MUTATES.search(cmd):
        counts["REFUSED"] += 1
        worst = max(worst, 1)
        print("  REFUSED     %-6s this command writes, publishes or destroys. A "
              "verifier that can change what it is verifying is not one." % rid)
        continue
    if listing:
        counts["LISTED"] += 1
        print("  LISTED      %-6s [%s] %s" % (rid, os.path.basename(cwd), cmd))
        continue

    print("  RUN         %-6s [%s] %s" % (rid, os.path.basename(cwd), cmd))
    try:
        p = subprocess.run(["/bin/sh", "-c", cmd], cwd=cwd, timeout=timeout,
                           capture_output=True, text=True)
        out = (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        counts["ERROR"] += 1
        worst = max(worst, 1)
        print("  ERROR       %-6s no answer within %ds. A headline whose evidence "
              "cannot finish is a headline nobody is re-deriving; shorten the "
              "command or say `unverified`." % (rid, timeout))
        continue
    except Exception as exc:
        counts["ERROR"] += 1
        worst = max(worst, 1)
        print("  ERROR       %-6s could not run: %s" % (rid, exc))
        continue

    want = row["expect"].strip()
    if want and want in out:
        counts["MATCH"] += 1
        print("  MATCH       %-6s still prints: %s" % (rid, want[:90]))
    else:
        counts["MISMATCH"] += 1
        worst = max(worst, 1)
        got = " / ".join(l.strip() for l in out.strip().split("\n")[-3:])
        print("  MISMATCH    %-6s the row records: %s" % (rid, want[:90]))
        print("              %-6s it now prints  : %s" % ("", got[:160] or "<nothing>"))
        print("              %-6s THE HEADLINE OF THIS ROW IS THE THING TO "
              "RE-READ. Rewrite it, then re-stamp its **Headline:** warrant."
              % "")

print("")
print("  %d matched, %d MISMATCHED, %d unverified by declaration, %d refused, "
      "%d could not run%s"
      % (counts["MATCH"], counts["MISMATCH"], counts["UNVERIFIED"],
         counts["REFUSED"], counts["ERROR"],
         (", %d listed only" % counts["LISTED"]) if listing else ""))
if counts["MISMATCH"]:
    print("")
    print("  A MISMATCH IS NOT A BROKEN CHECK. It is the row's first sentence")
    print("  having gone false while its pin sat there matching, which is what")
    print("  happened to eleven rows on 2026-09-06 with nothing watching.")
sys.exit(1 if worst else 0)
PYEOF
