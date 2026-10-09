#!/bin/bash
# replay-capture-walk.sh — record the long replay session with the guest's own signed-in `claude`.
#
#   run-walk.py --no-app --home <empty dir> --engine <engine.tar.gz> --report <json> \
#     -- replay-capture-walk.sh <out-dir> [--model MODEL]
#
# Plan: richos-hq docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md §4 row 6 ("one
# test VM session to record the long session"). run.sh --no-app boots the guest with the host's
# `claude` synced in and the host's sign-in pushed into the run's fixture home, and launches
# nothing; this runs ../replay/record-long-session.py there, headless (no window, no app), and
# pulls the capture back. Scrub it with ../replay/scrub-capture.py before it goes anywhere public.
#
# run-walk.py passes the VM name first and stops the guest and deletes the clone when this
# returns (CEO §54). In <out-dir>: long-session.raw.jsonl (NOT scrubbed: it stays private),
# summary.json (the recorder's one line), walk.log. EXIT STATUS: the recorder's (0 only when the
# session took the shape the tests need), or 1 when the guest could not be prepared or read.
set -u
VM="$1"
S="${2:?usage: replay-capture-walk.sh <vm> <out-dir> [--model MODEL]}"
MODEL=haiku
[ "${3:-}" = "--model" ] && MODEL="${4:?--model needs a value}"
T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$T/lib.sh"
mkdir -p "$S"
note() { echo "[walk] $(date -u +%H:%M:%SZ) $*" | tee -a "$S/walk.log"; }
die_walk() { note "FAILED: $1"; exit 1; }

PAYLOAD="$(cat "$TESTVM_RUN/$VM/payload" 2>/dev/null)"
[ -n "$PAYLOAD" ] || die_walk "no payload recorded for $VM (was it booted with run-walk.py --no-app?)"
HOMEDIR="$PAYLOAD/home"
G="$PAYLOAD/replay-capture"
"$T/guest.sh" "$VM" "mkdir -p '$G'" || die_walk "the guest folder"
"$T/guest.sh" "$VM" --push "$T/../replay/record-long-session.py" "$G/record-long-session.py" \
  || die_walk "pushing the recorder"
note "recording the long session in the guest (model $MODEL, claude $("$T/guest.sh" "$VM" "'$TESTVM_GUEST_CLAUDE' --version" 2>/dev/null))"
# The same environment the app gives its `claude` in the guest (run.sh step 4), and no window.
"$T/guest.sh" "$VM" "cd '$G' && env HOME='$HOMEDIR' CLAUDE_CONFIG_DIR='$HOMEDIR/.claude' \
  $TESTVM_CLAUDE_PIN_VAR=$TESTVM_CLAUDE_PIN_VALUE \
  python3 record-long-session.py '$G/long-session.raw.jsonl' --claude '$TESTVM_GUEST_CLAUDE' --model '$MODEL'" \
  > "$S/summary.json" 2>> "$S/walk.log"
RC=$?
note "recorder exit $RC: $(cat "$S/summary.json")"
"$T/guest.sh" "$VM" --pull "$G/long-session.raw.jsonl" "$S/long-session.raw.jsonl" \
  || die_walk "pulling the capture"
note "capture: $(wc -l < "$S/long-session.raw.jsonl") lines in $S/long-session.raw.jsonl"
exit "$RC"
