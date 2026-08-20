#!/usr/bin/env bash
#
# guard-definition-drift.test.sh — regression tests for the definition-drift
# guard PAIR:
#   scripts/hooks/snapshot-agent-definitions.sh  (SessionStart snapshotter)
#   scripts/hooks/guard-definition-drift.sh      (PreToolUse[Agent] blocker)
#
# Every case runs against an isolated sandbox root (DEFINITION_DRIFT_ROOT), so
# the real repo's .claude/agents and .claude/state are never read or written.
#
# Covers:
#   (a)  unchanged definition                      -> exit 0  (silent allow)
#   (a2) unchanged, second unrelated agent         -> exit 0
#   (b)  MODIFIED definition, no ack               -> exit 2  (block)
#   (b2) block message names both hashes + paths   -> stderr shape
#   (c)  MODIFIED + matching full-64 ack           -> exit 0  + acks.log line
#   (c2) MODIFIED + matching 16-char prefix ack    -> exit 0
#   (c3) MODIFIED + STALE (non-matching) ack       -> exit 2  (block)
#   (c4) MODIFIED + too-short (8-char) ack         -> exit 2  (block)
#   (c5) ack line inside prose (not line-start)    -> exit 2  (block)
#   (d)  CREATED since snapshot                    -> exit 0  + drift.log warn
#   (e)  snapshot file missing entirely            -> exit 0  + warn
#   (e2) snapshot for a DIFFERENT session          -> exit 0  + warn (no
#        cross-session comparison — never invents drift)
#   (f)  built-in subagent types (no definition)   -> exit 0
#   (f2) unknown type with no definition file      -> exit 0
#   (g)  non-Agent tool payload                    -> exit 0  (passthrough)
#   (g2) unparseable payload                       -> exit 0  (fail OPEN, by
#        design — only DRIFT blocks; sibling guard fails closed)
#   (h)  definition deleted since snapshot         -> exit 0  + warn
#   (i)  snapshotter: records every *.md, latest symlink, session filename
#   (i2) snapshotter: session id read from stdin payload
#   (j)  end-to-end: snapshot -> edit -> block -> revert -> allow
#   (k)  double-fire dedup on the acks log (one line for two identical fires)
#
# Run directly: scripts/hooks/guard-definition-drift.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/guard-definition-drift.sh"
SNAPSHOT="$SCRIPT_DIR/snapshot-agent-definitions.sh"

if [ ! -x "$GUARD" ] || [ ! -x "$SNAPSHOT" ]; then
    echo "FATAL: guard-definition-drift.sh or snapshot-agent-definitions.sh missing/non-exec" >&2
    exit 1
fi

PASS=0
FAIL=0
FAIL_NAMES=()

SESSION_ID="cafebabe-0000-4000-8000-000000000000"
OTHER_SESSION="deadbeef-0000-4000-8000-000000000000"

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_root — a sandbox with two agent definitions and NO snapshot yet.
make_root() {
    local root
    root="$(mktemp -d -t guard-definition-drift.XXXXXX)"
    mkdir -p "$root/.claude/agents" "$root/.claude/state"
    printf -- '---\nname: dev\nmodel: sonnet\n---\n\ndev v2.0 body.\n' >"$root/.claude/agents/dev.md"
    printf -- '---\nname: arch\nmodel: sonnet\n---\n\narch body.\n' >"$root/.claude/agents/arch.md"
    echo "$root"
}

# take_snapshot <root> [session]
take_snapshot() {
    local root="$1" sid="${2:-$SESSION_ID}"
    DEFINITION_DRIFT_ROOT="$root" "$SNAPSHOT" --session "$sid" >/dev/null 2>&1
}

# spawn_payload <subagent_type> <prompt> [session]
spawn_payload() {
    local st="$1" prompt="$2" sid="${3:-$SESSION_ID}"
    python3 - "$st" "$prompt" "$sid" <<'PY'
import json, sys
st, prompt, sid = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "tool_name": "Agent",
    "tool_input": {"subagent_type": st, "name": f"{st}-sonnet-t1",
                   "prompt": prompt, "isolation": "worktree"},
    "session_id": sid,
}))
PY
}

ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  FAIL  %s  %s\n' "$1" "${2:-}"; }

# run_case <name> <expected-exit> <root> <payload>
run_case() {
    local name="$1" want="$2" root="$3" payload="$4" got
    printf '%s' "$payload" | DEFINITION_DRIFT_ROOT="$root" "$GUARD" >/dev/null 2>&1
    got=$?
    [ "$got" -eq "$want" ] && ok "$name" || bad "$name" "(expected exit $want, got $got)"
}

# run_case_msg <name> <needle> <root> <payload>
run_case_msg() {
    local name="$1" needle="$2" root="$3" payload="$4" out
    out="$(printf '%s' "$payload" | DEFINITION_DRIFT_ROOT="$root" "$GUARD" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then ok "$name"
    else bad "$name" "(stderr missing \"$needle\")"; fi
}

echo "=== guard-definition-drift tests ==="

# ---------------------------------------------------------------------------
# (i) snapshotter shape
# ---------------------------------------------------------------------------
R="$(make_root)"
take_snapshot "$R"
SNAP="$R/.claude/state/agent-definitions-cafebabe.snapshot"
if [ -f "$SNAP" ]; then ok "i. snapshot written to session-scoped filename"
else bad "i. snapshot written to session-scoped filename" "(missing $SNAP)"; fi

if [ -L "$R/.claude/state/agent-definitions-latest.snapshot" ] || [ -f "$R/.claude/state/agent-definitions-latest.snapshot" ]; then
    ok "i. latest handle created"
else bad "i. latest handle created"; fi

if grep -q "  .claude/agents/dev.md$" "$SNAP" && grep -q "  .claude/agents/arch.md$" "$SNAP"; then
    ok "i. snapshot records every .claude/agents/*.md with a repo-relative path"
else bad "i. snapshot records every .claude/agents/*.md with a repo-relative path"; fi

SNAP_DEV="$(awk '$2==".claude/agents/dev.md"{print $1}' "$SNAP")"
if [ "$SNAP_DEV" = "$(sha_of "$R/.claude/agents/dev.md")" ]; then
    ok "i. snapshot hash equals the on-disk sha256"
else bad "i. snapshot hash equals the on-disk sha256"; fi

# (i2) session id from a stdin SessionStart payload (no --session flag)
R2="$(make_root)"
printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$OTHER_SESSION" \
    | DEFINITION_DRIFT_ROOT="$R2" "$SNAPSHOT" >/dev/null 2>&1
if [ -f "$R2/.claude/state/agent-definitions-deadbeef.snapshot" ]; then
    ok "i2. session id parsed from the stdin SessionStart payload"
else bad "i2. session id parsed from the stdin SessionStart payload"; fi
rm -rf "$R2"

# ---------------------------------------------------------------------------
# (a) unchanged -> allow
# ---------------------------------------------------------------------------
run_case "a. unchanged definition -> allow" 0 "$R" "$(spawn_payload dev 'draft the openers')"
run_case "a2. unchanged, other agent -> allow" 0 "$R" "$(spawn_payload arch 'add the schema field')"

# ---------------------------------------------------------------------------
# (b) MODIFIED -> block
# ---------------------------------------------------------------------------
printf -- '---\nname: dev\nmodel: sonnet\n---\n\ndev v2.1 body — the mid-session upgrade.\n' >"$R/.claude/agents/dev.md"
CUR_DEV="$(sha_of "$R/.claude/agents/dev.md")"
run_case "b. MODIFIED definition, no ack -> BLOCK" 2 "$R" "$(spawn_payload dev 'draft the openers')"
run_case "b1. sibling agent unaffected by another agent's drift -> allow" 0 "$R" "$(spawn_payload arch 'add the schema field')"
run_case_msg "b2. block names the session-start hash" "$SNAP_DEV" "$R" "$(spawn_payload dev 'draft')"
run_case_msg "b2. block names the current hash" "$CUR_DEV" "$R" "$(spawn_payload dev 'draft')"
run_case_msg "b2. block offers the fresh-session path" "restart into a FRESH session" "$R" "$(spawn_payload dev 'draft')"
run_case_msg "b2. block offers the ack path with the current sha" "definition-drift-ack: $CUR_DEV" "$R" "$(spawn_payload dev 'draft')"
run_case_msg "b2. block cites the upstream incident" "2026-08-06 upstream incident" "$R" "$(spawn_payload dev 'draft')"

# ---------------------------------------------------------------------------
# (c) ack handling
# ---------------------------------------------------------------------------
run_case "c. MODIFIED + matching full ack -> allow" 0 "$R" \
    "$(spawn_payload dev "definition-drift-ack: $CUR_DEV
Read the on-disk definition in full and follow it.")"
ACKLOG="$R/.claude/state/definition-drift-acks.log"
if [ -f "$ACKLOG" ] && grep -q "current=$CUR_DEV" "$ACKLOG"; then
    ok "c. ack appended to definition-drift-acks.log"
else bad "c. ack appended to definition-drift-acks.log"; fi

run_case "c2. MODIFIED + 16-char prefix ack -> allow" 0 "$R" \
    "$(spawn_payload dev "definition-drift-ack: ${CUR_DEV:0:16}
Read the on-disk definition.")"
run_case "c3. MODIFIED + STALE ack (snapshot hash) -> BLOCK" 2 "$R" \
    "$(spawn_payload dev "definition-drift-ack: $SNAP_DEV")"
run_case_msg "c3. stale-ack block says the ack does not match" "does NOT match the current" "$R" \
    "$(spawn_payload dev "definition-drift-ack: $SNAP_DEV")"
run_case "c4. MODIFIED + too-short (8-char) ack -> BLOCK" 2 "$R" \
    "$(spawn_payload dev "definition-drift-ack: ${CUR_DEV:0:8}")"
run_case "c5. ack mentioned mid-prose (not line-start) -> BLOCK" 2 "$R" \
    "$(spawn_payload dev "please add a definition-drift-ack: $CUR_DEV to the prompt")"

# (k) double-fire dedup — two identical fires append ONE acks.log line
R3="$(make_root)"
take_snapshot "$R3"
printf -- 'changed\n' >>"$R3/.claude/agents/dev.md"
CUR3="$(sha_of "$R3/.claude/agents/dev.md")"
P3="$(spawn_payload dev "definition-drift-ack: $CUR3")"
printf '%s' "$P3" | DEFINITION_DRIFT_ROOT="$R3" "$GUARD" >/dev/null 2>&1
printf '%s' "$P3" | DEFINITION_DRIFT_ROOT="$R3" "$GUARD" >/dev/null 2>&1
LINES="$(wc -l < "$R3/.claude/state/definition-drift-acks.log" 2>/dev/null | tr -d ' ')"
if [ "${LINES:-0}" = "1" ]; then ok "k. double-fire dedup: 2 identical fires -> 1 acks.log line"
else bad "k. double-fire dedup: 2 identical fires -> 1 acks.log line" "(got ${LINES:-0} lines)"; fi
rm -rf "$R3"

# ---------------------------------------------------------------------------
# (d) CREATED since snapshot -> allow + warn
# ---------------------------------------------------------------------------
printf -- '---\nname: newhire\nmodel: sonnet\n---\n\nFresh hire body.\n' >"$R/.claude/agents/newhire.md"
run_case "d. CREATED since snapshot -> allow (fail open)" 0 "$R" "$(spawn_payload newhire 'do the new thing')"
run_case_msg "d. CREATED emits the NEW DEFINITION warning" "NEW DEFINITION" "$R" "$(spawn_payload newhire 'do it')"
if grep -q "created" "$R/.claude/state/definition-drift.log" 2>/dev/null; then
    ok "d. CREATED logged to definition-drift.log"
else bad "d. CREATED logged to definition-drift.log"; fi

# ---------------------------------------------------------------------------
# (h) definition deleted since snapshot -> allow + warn
# ---------------------------------------------------------------------------
rm -f "$R/.claude/agents/arch.md"
run_case "h. definition deleted since snapshot -> allow" 0 "$R" "$(spawn_payload arch 'schema work')"
run_case_msg "h. deleted definition warns" "MISSING on disk" "$R" "$(spawn_payload arch 'schema work')"

# ---------------------------------------------------------------------------
# (e) no snapshot / cross-session
# ---------------------------------------------------------------------------
R4="$(make_root)"   # no snapshot taken at all
run_case "e. no snapshot for this session -> allow" 0 "$R4" "$(spawn_payload dev 'draft')"
run_case_msg "e. no snapshot warns about the next-session activation" "activates from the NEXT one" "$R4" \
    "$(spawn_payload dev 'draft')"

R5="$(make_root)"
take_snapshot "$R5" "$OTHER_SESSION"
printf -- 'drifted\n' >>"$R5/.claude/agents/dev.md"
run_case "e2. snapshot belongs to a DIFFERENT session -> allow, never cross-compare" 0 "$R5" \
    "$(spawn_payload dev 'draft' "$SESSION_ID")"
rm -rf "$R4" "$R5"

# ---------------------------------------------------------------------------
# (f)(g) passthrough cases
# ---------------------------------------------------------------------------
for t in Explore Plan general-purpose claude claude-code-guide statusline-setup; do
    run_case "f. built-in type '$t' -> allow" 0 "$R" "$(spawn_payload "$t" 'read something')"
done
run_case "f2. unknown type with no definition file -> allow" 0 "$R" "$(spawn_payload nosuchagent 'anything')"
run_case "g. non-Agent tool payload -> passthrough" 0 "$R" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"cafebabe-0000-4000-8000-000000000000"}'
run_case "g2. unparseable payload -> allow (fail OPEN by design)" 0 "$R" 'not json at all'

# ---------------------------------------------------------------------------
# (j) end-to-end: snapshot -> edit -> block -> revert -> allow
# ---------------------------------------------------------------------------
R6="$(make_root)"
ORIG="$(cat "$R6/.claude/agents/dev.md")"
take_snapshot "$R6"
run_case "j1. e2e baseline -> allow" 0 "$R6" "$(spawn_payload dev 'draft')"
printf -- 'mid-session install\n' >>"$R6/.claude/agents/dev.md"
run_case "j2. e2e after mid-session install -> BLOCK" 2 "$R6" "$(spawn_payload dev 'draft')"
printf '%s\n' "$ORIG" >"$R6/.claude/agents/dev.md"
run_case "j3. e2e after revert to snapshot content -> allow" 0 "$R6" "$(spawn_payload dev 'draft')"
# a FRESH session snapshot re-baselines the drifted definition (path (a))
printf -- 'mid-session install\n' >>"$R6/.claude/agents/dev.md"
run_case "j4. e2e drifted again -> BLOCK" 2 "$R6" "$(spawn_payload dev 'draft')"
take_snapshot "$R6" "feedface-0000-4000-8000-000000000000"
run_case "j5. e2e fresh-session snapshot re-baselines -> allow" 0 "$R6" \
    "$(spawn_payload dev 'draft' 'feedface-0000-4000-8000-000000000000')"
rm -rf "$R6"

rm -rf "$R"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-definition-drift tests: $FAIL FAILED, $PASS passed ==="
    for n in "${FAIL_NAMES[@]}"; do echo "    - $n"; done
    exit 1
fi
echo "=== guard-definition-drift tests: all $PASS passed ==="
exit 0
