#!/usr/bin/env bash
#
# guard-shared-scratchpad.test.sh — behavioral tests for
# scripts/hooks/guard-shared-scratchpad.sh (the rule: scripts/lib/shared_scratchpad.py).
#
# The two commands that destroyed live work on 2026-10-01 are replayed exactly, as a
# teammate's PreToolUse[Bash] payload against a sandbox session directory: each must be
# refused, and the files in the shared scratchpad must still be there afterwards (the
# refusal is what stops the shell from ever running the command). Beside each refusal
# its pass: the same command from the lead, and a teammate deleting its own named
# directory.
#
# Nothing here deletes anything outside the sandbox: every command under test is only
# shown to the hook, never executed.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-shared-scratchpad.sh"
MANIFEST="$SCRIPT_DIR/dispatch-pretooluse.manifest"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$HOOK" ]; then
    echo "FAIL  $HOOK is missing or not executable: no teammate's delete of the shared scratchpad is refused"
    exit 1
fi

SANDBOX="$(cd "$(mktemp -d -t shared-scratchpad-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# A Claude scratch root laid out exactly as the harness lays it out.
ROOT="$SANDBOX/claude-501"
SID="58a70f1b-5fb0-437f-b6a7-146d5090a3df"
SESSION="$ROOT/-Users-alex-ab-femcboost/$SID"
SP="$SESSION/scratchpad"
mkdir -p "$SP/briefs" "$SESSION/tasks"
printf 'lead brief\n' >"$SP/briefs/isaac-r3floor.md"          # the lead's
printf 'helper\n' >"$SP/rs_mutant.py"                          # a live teammate's
printf 'backup\n' >"$SP/tailnet.rs.orig"                       # a live teammate's
OWN="$SANDBOX/E1TB/tmp/claude/quint-sonnet-huntb4"            # the teammate's own named dir
mkdir -p "$OWN"
printf 'mine\n' >"$OWN/notes.txt"
export SCRATCH_CLAUDE_ROOTS="$ROOT"

payload() { # <command> [agent_id] [cwd]
    python3 -c '
import json, sys
cmd, aid, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"session_id": "'"$SID"'", "hook_event_name": "PreToolUse", "tool_name": "Bash",
     "tool_input": {"command": cmd}, "tool_use_id": "toolu_x", "cwd": cwd}
if aid:
    d["agent_id"] = aid
    d["agent_type"] = "quint"
print(json.dumps(d))' "$1" "${2-}" "${3:-$SANDBOX}"
}
run() { OUT="$(printf '%s' "$1" | bash "$HOOK" 2>&1)"; RC=$?; }
intact() { [ -f "$SP/briefs/isaac-r3floor.md" ] && [ -f "$SP/rs_mutant.py" ] && [ -f "$SP/tailnet.rs.orig" ]; }

TEAMMATE="a816c96bdad4c925d"
echo "=== guard-shared-scratchpad tests ==="

# S01 — echo-opus-hunta, 22:08:59Z, verbatim but for the sandbox path.
run "$(payload "rm -rf $SP/* && ls -A $SP | wc -l; ls -d /Volumes/E1TB/tmp/claude/echo-opus-hunta 2>&1 || true" "$TEAMMATE")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "shared" && intact \
    && ok "S01  a teammate's \`rm -rf <session>/scratchpad/*\` is refused and the shared files survive" \
    || bad "S01  rm -rf scratchpad/* rc=$RC: $OUT"

# S02 — quint-sonnet-huntb4, 22:34:19Z, verbatim but for the sandbox path.
run "$(payload "git -C /x log --format=%H -3 --reverse; rm -f $SP/*; ls $SP | wc -l" "$TEAMMATE")"
[ "$RC" -eq 2 ] && intact \
    && ok "S02  a teammate's \`rm -f <session>/scratchpad/*\` is refused" \
    || bad "S02  rm -f scratchpad/* rc=$RC: $OUT"

# S03 — the teammate deleting its own named directory passes.
run "$(payload "rm -rf $OWN; ls -d $OWN 2>&1 || true" "$TEAMMATE")"
[ "$RC" -eq 0 ] && ok "S03  a teammate deleting its own /Volumes/E1TB/tmp/claude/<name>/ passes" || bad "S03  own dir rc=$RC: $OUT"
run "$(payload "rm -rf /Volumes/E1TB/tmp/claude/quint-sonnet-huntb4" "$TEAMMATE")"
[ "$RC" -eq 0 ] && ok "S03b ...and the real path form passes too" || bad "S03b real own dir rc=$RC: $OUT"

# S04 — the lead's own identical call passes (it carries no agent_id).
run "$(payload "rm -rf $SP/*")"
[ "$RC" -eq 0 ] && ok "S04  the LEAD's own \`rm -rf <session>/scratchpad/*\` passes" || bad "S04  lead rc=$RC: $OUT"

# S05 — the variable form secalerts1 used, which a literal match would miss.
run "$(payload "S=$SP; rm -rf \$S/testvm-red && cp -R /x \$S/testvm-red" "$TEAMMATE")"
[ "$RC" -eq 2 ] && ok "S05  \`S=<scratchpad>; rm -rf \$S/x\` is refused (assignment followed)" || bad "S05  variable form rc=$RC: $OUT"

# S06 — relative to a cd into the scratchpad, and relative to the call's own cwd.
run "$(payload "cd $SP; rm -f ./mobile_mac_server::serve" "$TEAMMATE")"
[ "$RC" -eq 2 ] && ok "S06  \`cd <scratchpad>; rm -f ./x\` is refused (cd followed)" || bad "S06  cd form rc=$RC: $OUT"
run "$(payload "rm -rf *" "$TEAMMATE" "$SP")"
[ "$RC" -eq 2 ] && ok "S06b \`rm -rf *\` with the scratchpad as the call's cwd is refused" || bad "S06b cwd glob rc=$RC: $OUT"

# S07 — find -delete and the session's other directories.
run "$(payload "find $SP -name '*.log' -delete" "$TEAMMATE")"
[ "$RC" -eq 2 ] && ok "S07  \`find <scratchpad> ... -delete\` is refused" || bad "S07  find -delete rc=$RC: $OUT"
run "$(payload "rm -rf $SESSION/tasks" "$TEAMMATE")"
[ "$RC" -eq 2 ] && ok "S07b the session's tasks/ directory is protected too" || bad "S07b tasks rc=$RC: $OUT"

# S08 — a directory ABOVE the session (removing it removes every session).
run "$(payload "rm -rf $ROOT/-Users-alex-ab-femcboost" "$TEAMMATE")"
[ "$RC" -eq 2 ] && ok "S08  removing the project directory above the session is refused" || bad "S08  ancestor rc=$RC: $OUT"

# S09 — controls: reading or naming the scratchpad is not deleting it.
run "$(payload "ls -la $SP; echo rm -rf $SP; cat $SP/rs_mutant.py" "$TEAMMATE")"
[ "$RC" -eq 0 ] && ok "S09  reading the scratchpad, or printing the words rm -rf, passes" || bad "S09  control rc=$RC: $OUT"
run "$(payload "rm -rf /tmp/some-other-dir" "$TEAMMATE")"
[ "$RC" -eq 0 ] && ok "S09b deleting outside every session directory passes" || bad "S09b outside rc=$RC: $OUT"

# S10 — any error in the check is a pass.
run "not json"
[ "$RC" -eq 0 ] && ok "S10  an unreadable payload passes (this rule never blocks on its own error)" || bad "S10  unparseable rc=$RC: $OUT"

# S11 — it is wired: the dispatcher's manifest runs it on every Bash call.
grep -qx 'Bash|guard-shared-scratchpad.sh' "$MANIFEST" \
    && ok "S11  dispatch-pretooluse.manifest runs it in the Bash chain" \
    || bad "S11  not in $MANIFEST"

intact && [ -f "$OWN/notes.txt" ] && ok "S12  nothing under test was executed: every sandbox file is still present" || bad "S12  a sandbox file is gone"

echo ""
echo "=== guard-shared-scratchpad tests: $FAIL FAILED, $PASS passed ==="
[ "$FAIL" -eq 0 ]
