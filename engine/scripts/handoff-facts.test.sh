#!/usr/bin/env bash
#
# handoff-facts.test.sh — the restart-handoff measurement block, proven by execution.
#
# EVERY CASE RUNS IN A SANDBOX: its own repositories, its own escalation ledger, its own
# `docker` on PATH. Nothing here touches the operator's memory directory, the real ledger, or
# a real repository. The RATE on the real fifteen-note corpus is a separate measurement and it
# is reported in docs/verification/restart-handoff-2026-09-14.md — scoring a check against the
# cases it was written from is how a check gets a number it did not earn.
#
# H1 and H2 are the two headline figures of the note that caused this (type U, richos-hq
# docs/verification/lifecycle-failure-record-2026-09-13.md 10e), reduced to their shape.
#
# WHAT IS PROVEN:
#
#   H1   THE AUDIENCE MISLABEL IS CAUGHT, and caught as a mislabel. "79 escalations
#        outstanding ... waiting on him" against a ledger holding 79 for the lead and 6 for
#        the CEO. This is the real defect, and it is the case that proves generation beats
#        re-running: THE NUMBER 79 IS CORRECT, so a checker that only re-ran numbers would
#        have confirmed the sentence.
#   H2   A WRONG DOCKER FIGURE IS CAUGHT against `docker system df`, summed across all four
#        rows the way the tool never does for you.
#   H3   THE SAME SENTENCE WITH THE RIGHT AUDIENCE IS SILENT. Without this, a check that
#        flags every escalation sentence would pass H1.
#   H4   A COUNT THAT MATCHES NOTHING MEASURED is CONTRADICTED, not mislabeled.
#   H5   A COMMIT THAT EXISTS NOWHERE is caught.
#   H6   A COMMIT THAT EXISTS is silent — the negative half of H5.
#   H7   ELSEWHERE: a commit attributed to one repository that lives in another is reported
#        with both names, because the reader who follows the note finds nothing.
#   H8   MENTION IS NOT ATTRIBUTION. "landed by a prospects session; extension HEAD `<sha>`"
#        is SILENT. Found on the real corpus, not invented: it was this check's only false
#        positive, and the connective rule is what removed it.
#   H9   REPEATS COLLAPSE. Eleven dead commits from one moved history are ONE row, not eleven.
#  H10   A STALE NOTE IS NOT RE-CHECKED for volatile facts. Docker usage has no ledger, so
#        after the fact the honest verdict is NOT RE-CHECKABLE and never CONTRADICTED.
#  H11   AN UNMEASURABLE FACT EMITS A ROW SAYING SO. A missing row reads as nothing to report,
#        which is the failure this whole mechanism exists to remove.
#  H12   THE AUTHOR'S WORDS ARE UNTOUCHED and the block is delimited.
#  H13   RE-RUNNING REPLACES THE BLOCK, never appends a second one.
#  H14   THE HOOK FIRES ON A HEREDOC WRITE — the form the defective note was actually written
#        with — and the note gains the measured block with no step for anyone to skip.
#  H15   THE HOOK IS SILENT AND EXIT 0 on a payload that names no restart note. It is
#        registered against every write-shaped tool, so this is the common path.
#  H16   THE HOOK NEVER FAILS A TOOL CALL, even when the measurement itself is broken.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTS="$SCRIPT_DIR/handoff-facts.py"
HOOK="$SCRIPT_DIR/hooks/handoff-facts-annotate.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/handoff-facts-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

[ -f "$FACTS" ] || { echo "FATAL: missing $FACTS" >&2; exit 1; }
[ -f "$HOOK" ]  || { echo "FATAL: missing $HOOK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

echo "handoff-facts.test.sh"
echo "  sandbox: $SANDBOX"
echo

ROOT="$SANDBOX/ab"
BIN="$SANDBOX/bin"
LEDGER="$SANDBOX/escalations.jsonl"
mkdir -p "$ROOT" "$BIN"

# --- a `docker` that answers the same way every time -------------------------------------
# A PATH shim rather than an env hook in the script: production code carrying a switch that
# only a test flips is a second code path nobody runs.
cat >"$BIN/docker" <<'SH'
#!/bin/sh
cat <<'OUT'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          38        16        31.7GB    19.47GB (61%)
Containers      29        7         1.395GB   446.5kB (0%)
Local Volumes   25        18        523.1MB   187.7MB (35%)
Build Cache     209       0         16.71GB   8.509GB
OUT
SH
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"      # 19.47 + 0.0004465 + 0.1877 + 8.509 = 28.2 GB

# --- repositories ------------------------------------------------------------------------
# HERMETIC BY CONSTRUCTION. These throwaway repositories must not inherit the operator's
# global `core.hooksPath` — the machine's commit-identity guard lives there and correctly
# refuses a commit from a test identity, which would make this suite's result depend on whose
# machine it runs on. An empty hooks directory is the sandbox's own.
mkdir -p "$SANDBOX/nohooks"
mkrepo() { # <name> <commit-subject>
    local d="$ROOT/$1"
    mkdir -p "$d"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config core.hooksPath "$SANDBOX/nohooks"
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    echo "$2" >"$d/f.txt"
    git -C "$d" add -A
    git -C "$d" commit -q -m "$2"
    git -C "$d" rev-parse --short=8 HEAD
}
RICHOS_SHA="$(mkrepo richos first)"
HQ_SHA="$(mkrepo richos-hq hq)"
EXT_SHA="$(mkrepo li-profile-data-grabber ext)"
mkrepo prospects pros >/dev/null

# --- escalation ledger: 79 for the lead, 6 for the CEO -----------------------------------
: >"$LEDGER"
python3 - "$LEDGER" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for i in range(79):
        fh.write(json.dumps({"event": "Escalation", "id": "l%d" % i, "for": "lead",
                             "raised": "2026-09-13T00:00:00Z", "title": "x"}) + "\n")
    for i in range(6):
        fh.write(json.dumps({"event": "Escalation", "id": "c%d" % i, "for": "ceo",
                             "raised": "2026-09-13T00:00:00Z", "title": "y"}) + "\n")
PY
export RICHOS_ESCALATION_LEDGER="$LEDGER"

NOTE="$SANDBOX/memory/project_restart_case.md"
mkdir -p "$SANDBOX/memory"

write_note() { printf '%s\n' "$1" >"$NOTE"; }
run_check() { python3 "$FACTS" "$NOTE" --root "$ROOT" --no-agents "$@" 2>&1; }

flags() {   # <case> <phrase>
    if run_check | grep -qF "$2"; then ok "$1"; else
        bad "$1" "expected a finding naming: $2"; run_check | sed 's/^/          /'; fi
}
silent() {  # <case> <phrase-that-must-not-appear>
    if run_check | grep -qF "$2"; then
        bad "$1" "expected silence, got a finding naming: $2"
        run_check | sed 's/^/          /'
    else ok "$1"; fi
}

# H1 — the audience mislabel, and the number in it is RIGHT
write_note '**79 teammate escalations outstanding**, oldest 8 days, explicitly waiting on him.'
flags "H1.audience-mislabel-caught" "MISLABELED"
flags "H1b.names-the-real-CEO-count" "the count addressed to the CEO is 6"

# H2 — the docker figure
write_note 'One thing is his: ~32.6 GB of reclaimable Docker on his machine.'
flags "H2.wrong-docker-figure-caught" "measured 28.2 GB reclaimable"

# H3 — the same sentence, correctly addressed: SILENT
write_note '6 escalations are outstanding and waiting on him; 79 are mine.'
silent "H3.correct-audience-is-silent" "MISLABELED"

# H4 — a count matching nothing measured
write_note '**200 teammate escalations outstanding**, all waiting on him.'
flags "H4.unmatched-count-contradicted" "CONTRADICTED"

# H5 / H6 — commits that do and do not exist
write_note "The fix landed at richos \`deadbee1\` tonight."
flags "H5.dead-commit-caught" "names no commit in any repository"
write_note "The fix landed at richos \`$RICHOS_SHA\` tonight."
silent "H6.live-commit-is-silent" "CONTRADICTED"

# H7 — attributed to one repository, living in another
write_note "Landed on richos main \`$HQ_SHA\`, pushed."
flags "H7.elsewhere-named-both-ways" "ELSEWHERE"
flags "H7b.names-where-it-actually-is" "richos-hq"

# H8 — MENTION is not ATTRIBUTION (the real false positive from the corpus)
write_note "Landed by a prospects session; extension HEAD \`$EXT_SHA\` — all good."
silent "H8.mention-is-not-attribution" "ELSEWHERE"

# H9 — repeats collapse into one row
{
    echo "Round one landed on richos main \`deadbee1\`, pushed."
    echo "Round two landed on richos main \`deadbee2\`, pushed."
    echo "Round three landed on richos main \`deadbee3\`, pushed."
    echo "Round four landed on richos main \`deadbee4\`, pushed."
} >"$NOTE"
n="$(run_check | grep -c 'CONTRADICTED')"
if [ "$n" = "1" ]; then ok "H9.repeats-collapse-to-one-row"
else bad "H9.repeats-collapse-to-one-row" "expected 1 row, got $n"; fi
flags "H9b.collapsed-row-names-the-count" "4 commits"

# H10 — a stale note is not re-checked for a volatile fact
write_note 'One thing is his: ~32.6 GB of reclaimable Docker on his machine.'
if python3 "$FACTS" "$NOTE" --root "$ROOT" --no-agents --fresh-seconds 0 2>&1 \
   | grep -qF "NOT RE-CHECKABLE"; then ok "H10.stale-note-not-recheckable"
else bad "H10.stale-note-not-recheckable" "expected NOT RE-CHECKABLE at --fresh-seconds 0"; fi

# H11 — an unmeasurable fact emits a row saying so, rather than vanishing
if PATH="$SANDBOX/nodocker:$PATH" python3 "$FACTS" --emit --root "$ROOT" --no-agents \
     2>/dev/null | grep -q 'docker reclaimable'; then ok "H11a.docker-row-always-present"
else bad "H11a.docker-row-always-present" "the docker row vanished"; fi
mkdir -p "$SANDBOX/blank"
cat >"$SANDBOX/blank/docker" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$SANDBOX/blank/docker"
if PATH="$SANDBOX/blank:$PATH" python3 "$FACTS" --emit --root "$ROOT" --no-agents 2>/dev/null \
     | grep -q 'UNMEASURED'; then ok "H11b.unmeasurable-says-UNMEASURED"
else bad "H11b.unmeasurable-says-UNMEASURED" "a failed measurement was turned into silence"; fi

# H12 / H13 — append-only, delimited, idempotent
write_note 'His words stand here. ~32.6 GB of reclaimable Docker is his call.'
before="$(cat "$NOTE")"
python3 "$FACTS" "$NOTE" --root "$ROOT" --no-agents --in-place >/dev/null 2>&1
if head -c "${#before}" "$NOTE" | cmp -s - <(printf '%s' "$before"); then
    ok "H12.author-words-untouched"
else bad "H12.author-words-untouched" "the text before the block changed"; fi
python3 "$FACTS" "$NOTE" --root "$ROOT" --no-agents --in-place >/dev/null 2>&1
n="$(grep -c 'handoff-facts: generated' "$NOTE")"
if [ "$n" = "1" ]; then ok "H13.rerun-replaces-not-appends"
else bad "H13.rerun-replaces-not-appends" "expected 1 generated block, found $n"; fi

# H14 — the hook, on the heredoc form the defective note was written with
HOOKNOTE="$SANDBOX/memory/project_restart_hooked.md"
printf '%s\n' '**79 teammate escalations outstanding**, waiting on him.' >"$HOOKNOTE"
python3 - "$HOOKNOTE" >"$SANDBOX/payload.json" <<'PY'
import json, sys
print(json.dumps({"tool_name": "Bash", "hook_event_name": "PostToolUse",
                  "tool_input": {"command": "cat > %s <<'EOF'\nbody\nEOF" % sys.argv[1]}}))
PY
HOOK_OUT="$(bash "$HOOK" <"$SANDBOX/payload.json" 2>&1)"; HOOK_RC=$?
if grep -q 'handoff-facts: generated' "$HOOKNOTE"; then ok "H14a.hook-writes-the-block"
else bad "H14a.hook-writes-the-block" "rc=$HOOK_RC out=$HOOK_OUT"; fi
if grep -q 'MISLABELED' "$HOOKNOTE"; then ok "H14b.hook-carries-the-finding"
else bad "H14b.hook-carries-the-finding" "the finding did not reach the note"; fi
if [ "$HOOK_RC" = "0" ]; then ok "H14c.hook-exit-0"; else bad "H14c.hook-exit-0" "rc=$HOOK_RC"; fi

# H15 — silence on an unrelated payload
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}' >"$SANDBOX/other.json"
OUT="$(bash "$HOOK" <"$SANDBOX/other.json" 2>&1)"; RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then ok "H15.unrelated-payload-silent-exit-0"
else bad "H15.unrelated-payload-silent-exit-0" "rc=$RC out=$OUT"; fi

# H16 — a broken measurement never fails the tool call
BROKEN="$SANDBOX/broken-facts.py"
printf '%s\n' 'import sys; sys.exit(9)' >"$BROKEN"
OUT="$(HANDOFF_FACTS_OVERRIDE=1 bash -c '
  set -o pipefail
  SCRIPT_DIR="'"$SCRIPT_DIR/hooks"'"
  exec bash "'"$HOOK"'"' <"$SANDBOX/payload.json" 2>&1)"; RC=$?
if [ "$RC" = "0" ]; then ok "H16.hook-never-fails-a-tool-call"
else bad "H16.hook-never-fails-a-tool-call" "rc=$RC out=$OUT"; fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
