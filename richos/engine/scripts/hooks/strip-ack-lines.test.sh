#!/usr/bin/env bash
#
# strip-ack-lines.test.sh — scripts/hooks/strip-ack-lines.sh.
#
# A spawn whose brief carries an acknowledgment line is still accepted by the guard
# that requires it, and the prompt the teammate boots on does not contain that line.
# Fixture data only: a sandbox entity with a model ceiling, never a real repository.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/guard-model-ceiling.sh"
STRIP="$SCRIPT_DIR/strip-ack-lines.sh"
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; }

SB="$(cd "$(mktemp -d -t strip-ack-lines.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
ENTITY="$SB/entity"
mkdir -p "$ENTITY/.claude/agents"
printf -- '---\nname: mcjudge\nmodel: opus\n---\nA sandbox role.\n' >"$ENTITY/.claude/agents/mcjudge.md"
{
    printf 'PROTECTED_PATHS=""\nREADONLY_ALLOWLIST="Explore Plan"\n'
    printf 'ALLOWED_MODELS="fable opus sonnet haiku"\n'
    printf 'MODEL_TIERS="fable > opus > sonnet > haiku"\nMODEL_CEILING="opus"\n'
} >"$ENTITY/orchestration.config"

# payload <prompt> : a spawn above the ceiling, so the guard needs the ack line.
payload() {
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"tool_name": "Agent", "tool_input": {
    "prompt": sys.argv[1], "subagent_type": "mcjudge", "name": "mcjudge-fable-1",
    "model": "fable", "isolation": "worktree"},
    "session_id": "sa000000-0000-4000-8000-000000000000", "tool_use_id": "toolu_sa_test"}))
PY
}

# stripped_prompt <payload-json> : the prompt after the hook ("" if the hook changed nothing).
stripped_prompt() {
    printf '%s' "$1" | "$STRIP" | python3 -c '
import json, sys
raw = sys.stdin.read()
print(json.loads(raw)["hookSpecificOutput"]["updatedInput"]["prompt"] if raw.strip() else "")'
}

PROMPT='Build it.
cross-repo-worktree: /tmp/ws/richos
model-ceiling-ack: creating the design system every later screen inherits, once.
owned-state-ack: ecs - historical gaps only.
   ceo-todos-deferred: he ordered it.
reference: ledger row 4, taken as is.
full-suite-ack: one suite, cannot be scoped.
Mention of model-ceiling-ack: in the middle of a sentence stays.

Done when it is committed.'
P="$(payload "$PROMPT")"

echo "=== strip-ack-lines tests ==="

# 1. the guard that requires the ack line accepts the ORIGINAL (what the guards see).
if printf '%s' "$P" | env RICHOS_ENTITY_ROOT="$ENTITY" "$GUARD" >/dev/null 2>&1; then
    ok "the guard accepts the spawn with the acknowledgment line in the original prompt"
else
    bad "the guard accepts the spawn with the acknowledgment line in the original prompt"
fi

# 2. the teammate's prompt has none of the acknowledgment lines.
OUT="$(stripped_prompt "$P")"
for prefix in model-ceiling-ack owned-state-ack ceo-todos-deferred reference full-suite-ack; do
    if printf '%s\n' "$OUT" | grep -qiE "^[[:space:]]*${prefix}:"; then
        bad "teammate prompt carries no ${prefix}: line"
    else
        ok "teammate prompt carries no ${prefix}: line"
    fi
done

# 3. what the teammate needs stays.
for keep in 'cross-repo-worktree: /tmp/ws/richos' 'Build it.' 'Done when it is committed.' 'Mention of model-ceiling-ack: in the middle'; do
    if printf '%s\n' "$OUT" | grep -qF "$keep"; then ok "teammate prompt keeps: $keep"
    else bad "teammate prompt keeps: $keep"; fi
done

# 4. the stripped prompt really would have been refused: the guard needs the line.
S="$(payload "$OUT")"
set +e
printf '%s' "$S" | env RICHOS_ENTITY_ROOT="$ENTITY" "$GUARD" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -eq 2 ]; then ok "without the line the guard refuses (so it must read the original)"
else bad "without the line the guard refuses" "exit $RC"; fi

# 5. a prompt with no acknowledgment line is not rewritten at all; a non-Agent payload is ignored.
if [ -z "$(printf '%s' "$(payload 'Plain brief.')" | "$STRIP")" ]; then ok "no acknowledgment line -> no rewrite"
else bad "no acknowledgment line -> no rewrite"; fi
if [ -z "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo"}}' | "$STRIP")" ]; then ok "non-Agent payload ignored"
else bad "non-Agent payload ignored"; fi
if [ -z "$(printf 'not json' | "$STRIP")" ]; then ok "unparseable payload passes silently"
else bad "unparseable payload passes silently"; fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
