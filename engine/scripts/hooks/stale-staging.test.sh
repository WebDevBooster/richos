#!/usr/bin/env bash
#
# stale-staging.test.sh — the staging-staleness guard and its recorder.
#
# THE CASE THIS WHOLE SUITE EXISTS FOR IS THE PAIR 3a/3b, and they must be read
# together: the SAME repository, the SAME dispatch, differing only in whether
# the undeployed commits touched a product tree. A suite that only proved the
# refusal would prove nothing about whether the guard survives contact with a
# week of docs landings — and this project has three recorded instances, in one
# day, of a blocking check with a large false-positive class being waived and
# then deleted. 3b is the case that keeps this guard alive; 3a is the case that
# makes it worth having.
#
# Exit codes: 0 all cases pass and every mutation property is load-bearing;
#             1 a case failed or a property survived its own removal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$SCRIPT_DIR/guard-stale-staging.sh"
RECORDER="$ENGINE_ROOT/scripts/staging-record.sh"

# The governed repository is DECLARED, never inherited from the launching
# session: run from a session seated elsewhere, every case below would pass by
# standing down.
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; }

SB="$(cd "$(mktemp -d -t stale-staging.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SB"' EXIT

ENTITY="$SB/entity"
mkdir -p "$ENTITY/avelor" "$ENTITY/fitapp" "$ENTITY/docs" "$ENTITY/scripts"

git -C "$ENTITY" init -q -b main
git -C "$ENTITY" config user.name  "stale-staging-test"
git -C "$ENTITY" config user.email "stale-staging-test@example.invalid"

commit_file() {  # <path> <content> <message>
    mkdir -p "$ENTITY/$(dirname "$1")"
    printf '%s\n' "$2" >"$ENTITY/$1"
    git -C "$ENTITY" add -A
    git -C "$ENTITY" commit -q --no-verify -m "$3"
}

commit_file avelor/src/app.js  "v1" "avelor: the state staging was deployed from"
commit_file fitapp/legacy.js   "v1" "fitapp: legacy"
DEPLOYED="$(git -C "$ENTITY" rev-parse --short=12 HEAD)"

write_config() {   # <extra lines...>
    {
        printf 'PROTECTED_PATHS=""\n'
        printf 'STAGING_TREES="avelor fitapp"\n'
        printf 'STAGING_DEPLOY_COMMAND="scripts/deploy-avelor-staging.sh"\n'
        while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    } >"$ENTITY/orchestration.config"
}
write_config

write_record() {   # <sha> [outcome]
    mkdir -p "$ENTITY/.claude/state"
    {
        printf 'sha=%s\n' "$1"
        printf 'outcome=%s\n' "${2:-success}"
    } >"$ENTITY/.claude/state/staging-deployed"
}
write_record "$DEPLOYED"

payload() {   # <prompt> [name] [subagent]
    python3 - "$1" "${2:-ray-sonnet-t1}" "${3:-ray}" <<'PY'
import json, sys
prompt, name, subagent = sys.argv[1:4]
print(json.dumps({"tool_name": "Agent",
                  "tool_input": {"prompt": prompt, "name": name,
                                 "subagent_type": subagent,
                                 "isolation": "worktree"},
                  "session_id": "ss000000-0000-4000-8000-000000000000",
                  "tool_use_id": "toolu_ss_test"}))
PY
}

run() {   # <json>
    # NO `set -e` ON THE WAY OUT. This suite runs under `set -uo pipefail` and
    # deliberately not errexit: nearly every case here EXPECTS a non-zero exit
    # from the guard. An earlier version restored errexit at the end of this
    # helper, and the suite then died silently at the first `find` over a
    # directory that was supposed to be absent - no message, no failing case,
    # just a truncated run that looked like a hang. A test harness that can
    # exit without saying which case it was on is the same defect this engine
    # keeps finding elsewhere.
    set +e
    OUT="$(printf '%s' "$1" | env RICHOS_ENTITY_ROOT="$ENTITY" bash "$HOOK" 2>&1)"
    RC=$?
}

case_rc() {   # <id+name> <expected-rc> <prompt>
    run "$(payload "$3")"
    [ "$RC" -eq "$2" ] && ok "$1" || bad "$1" "expected exit $2, got $RC: $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
}

case_silent() {   # <id+name> <prompt> — exit 0 AND not one byte of output
    run "$(payload "$2")"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"
    else bad "$1" "rc=$RC out='$(printf '%s' "$OUT" | head -2 | tr '\n' ' ')'"; fi
}

QA_PROMPT='Run the coach PWA QA pass. Test every screen in avelor/src against staging and report a verdict.'

echo "=== the stale-staging guard: the refusal, and the silence that keeps it alive ==="

# ---------------------------------------------------------------------------
echo ""
echo "=== 1. STAND-DOWN — a repository that never adopted this pays nothing ==="
# ---------------------------------------------------------------------------
# NOTE ON 1a. `orchestration.config` IS the adoption marker, so removing it
# while RICHOS_ENTITY_ROOT names this directory is not "unadopted" — it is a
# DECLARED root that is not adopted, which the resolver calls `broken` and
# refuses to substitute away from. The correct behavior there is to fail OPEN
# and say so, and that is what is asserted. The genuinely-unadopted case is
# unreachable from a suite that must declare its own root; it is covered by the
# resolver's own suite.
mv "$ENTITY/orchestration.config" "$SB/config.bak"
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'GUARD IS OFF'; then
    ok "1a  a declared root that is not an adopted engine root fails OPEN and announces"
else
    bad "1a  a broken root did not fail open loudly" "rc=$RC out='$(printf '%s' "$OUT" | head -2 | tr '\n' ' ')'"
fi
mv "$SB/config.bak" "$ENTITY/orchestration.config"

printf 'PROTECTED_PATHS=""\n' >"$ENTITY/orchestration.config"
case_silent "1b  a config that declares no STAGING_TREES is the adoption switch, and it is SILENT" "$QA_PROMPT"
write_config

run "$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"}}))')"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "1c  a call for a different tool is not this guard's business"
else bad "1c  a non-Agent call was not passed silently" "rc=$RC"; fi

# 1d IS WHERE THE ADOPTION SWITCH IS ACTUALLY OBSERVABLE, and finding that out
# was worth more than the case it replaced. An unadopted repository does not
# merely go quiet — it must accumulate NO STATE. With the switch removed the
# guard reaches the unevaluated-payload notice, announces on a malformed call
# and writes .claude/state/unevaluated-payloads.log into a repository that
# never adopted this contract. Silence alone would not have caught that: the
# degenerate empty-tree regex matches nothing, so the mutated guard still exits
# 0 on every well-formed dispatch. Measured, not assumed.
printf 'PROTECTED_PATHS=""\n' >"$ENTITY/orchestration.config"
rm -rf "$ENTITY/.claude"
run "$(printf '{"tool_name":"Agent","tool_input":')"
LEFTOVER="$( { find "$ENTITY/.claude" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$LEFTOVER" = "0" ]; then
    ok "1d  an unadopted repository says nothing AND writes nothing — the switch is checked before the payload is ever read"
else
    bad "1d  an unadopted repository was spoken to or written into" "rc=$RC files=$LEFTOVER out='$(printf '%s' "$OUT" | head -1 | cut -c1-60)'"
fi
write_config
mkdir -p "$ENTITY/.claude/state"
write_record "$DEPLOYED"

# ---------------------------------------------------------------------------
echo ""
echo "=== 2. THE REFUSAL — product commits landed, staging does not have them ==="
# ---------------------------------------------------------------------------
commit_file avelor/src/app.js "v2 — a real product change" "avelor: change the thing QA is about to look at"
UNDEPLOYED_TIP="$(git -C "$ENTITY" rev-parse --short=12 HEAD)"

case_rc "2a  a QA dispatch against a product tree with undeployed commits is REFUSED" 2 "$QA_PROMPT"
case "$OUT" in
    *"1 commit(s) touching"*) ok "2b  ...and the refusal states HOW MANY commits are missing, not that something is wrong" ;;
    *) bad "2b  the refusal did not count the undeployed commits" "$(printf '%s' "$OUT" | head -4 | tr '\n' ' ')" ;;
esac
case "$OUT" in
    *"deploy-avelor-staging.sh"*) ok "2c  ...and it names the DECLARED deploy command, so the fix is a paste" ;;
    *) bad "2c  the refusal did not name the deploy command from the declaration" ;;
esac
case "$OUT" in
    *"$DEPLOYED"*) ok "2d  ...and it names what staging actually has, so the claim can be checked" ;;
    *) bad "2d  the refusal did not name the deployed SHA" ;;
esac
case "$OUT" in
    *"change the thing QA is about to look at"*) ok "2e  ...and it lists the commits themselves, not just a number" ;;
    *) bad "2e  the refusal did not list the undeployed commits" ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== 3. THE PAIR — the 2026-09-02 amendment, mechanized ==="
# A deploy failure on a land touching only scripts/, docs/, .claude/ or skills/
# is RECORDED, NEVER REPORTED, because nothing shipped and nothing is at risk.
# 3a and 3b are the same repository and the same dispatch.
# ---------------------------------------------------------------------------
write_record "$UNDEPLOYED_TIP"      # staging is caught up...
for i in 1 2 3 4 5 6 7 8 9 10; do
    commit_file "docs/note-$i.md" "landing $i" "docs: the kind of land that happened 35 times in one day"
done
for i in 1 2 3; do
    commit_file "scripts/tool-$i.sh" "#!/bin/sh" "scripts: repo-wide work that ships no product code"
done
BEHIND="$(git -C "$ENTITY" rev-list --count "${UNDEPLOYED_TIP}..HEAD")"

case_silent "3b  staging is $BEHIND commits behind on docs/ and scripts/ — SILENT, not warned, not noted" "$QA_PROMPT"

commit_file avelor/src/app.js "v3 — one product commit among thirteen" "avelor: one product commit among the docs"
case_rc "3a  ...and ONE product commit among those $BEHIND makes the SAME dispatch a refusal" 2 "$QA_PROMPT"
case "$OUT" in
    *"1 commit(s) touching"*) ok "3c  ...counting ONLY the product commit — the 13 docs landings are not the debt" ;;
    *) bad "3c  the docs landings were counted as deploy debt" "$(printf '%s' "$OUT" | grep undeployed | head -1)" ;;
esac

# THE NEGATIVE CONTROL THAT MATTERS: remove the mechanism, not the symptom.
# With STAGING_TREES undeclared the identical repository state and the
# identical dispatch must go silent — so 3a fires because of the declaration
# and the pathspec, and not because the fixture happens to be noisy.
printf 'PROTECTED_PATHS=""\n' >"$ENTITY/orchestration.config"
case_silent "3d  NEGATIVE CONTROL: same tree, same dispatch, declaration REMOVED — silent" "$QA_PROMPT"
write_config
case_rc "3e  ...and putting the declaration back refuses it again — the effect follows the mechanism" 2 "$QA_PROMPT"

# ---------------------------------------------------------------------------
echo ""
echo "=== 4. SCOPE — both halves are required, because prose is not a dispatch ==="
# ---------------------------------------------------------------------------
case_silent "4a  a dispatch naming no product path is not this guard's business, debt or no debt" \
    'Read wiki/open-items.md in full and enumerate every governed row. Verify each against current state.'
case_silent "4b  a product path with no work or QA verb — a plain read — is silent" \
    'Summarize what avelor/src/lib contains. Do not change anything.'
case_rc "4c  ENGINEERING work on a product tree is in scope too, not only QA" 2 \
    'Fix the broken step count in avelor/src/lib/components/Home.svelte and commit it.'
case_silent "4d  another repository's trees are not this one's — an undeclared path is silent" \
    'Test everything in richos/app/ui and report a verdict against staging.'

# ---------------------------------------------------------------------------
echo ""
echo "=== 5. THE ESCAPE HATCH — a declaration, and a bare marker exempts nothing ==="
# ---------------------------------------------------------------------------
case_rc "5a  a BARE marker with no reason is refused — the reason is the whole mechanism" 2 \
    "$QA_PROMPT
stale-staging-ack:"
case_rc "5b  a token reason under the length floor is refused" 2 \
    "$QA_PROMPT
stale-staging-ack: later"
run "$(payload "$QA_PROMPT
stale-staging-ack: this dispatch only reads the avelor source and writes a plan; it never runs against staging")"
if [ "$RC" -eq 0 ]; then ok "5c  a real reason lets THIS dispatch through"
else bad "5c  a well-formed ack was refused" "rc=$RC"; fi
if grep -q 'stale-staging-ack: this dispatch only reads' "$ENTITY/.claude/state/stale-staging-acks.log" 2>/dev/null; then
    ok "5d  ...and it is logged, so a habit of waiving is visible rather than invisible"
else
    bad "5d  the accepted ack was not written to .claude/state/stale-staging-acks.log"
fi
case_rc "5e  ...and the ack does NOT carry to the next dispatch — it clears one call, not the rule" 2 "$QA_PROMPT"

# ---------------------------------------------------------------------------
echo ""
echo "=== 6. FAIL OPEN, AND ONLY WHERE IT MATTERS ==="
# ---------------------------------------------------------------------------
rm -f "$ENTITY/.claude/state/staging-deployed"
case_silent "6a  NO RECORD + an out-of-scope dispatch — silent, so mid-adoption costs nothing" \
    'Read wiki/open-items.md and enumerate the rows.'
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'CANNOT DECIDE'; then
    ok "6b  NO RECORD + an in-scope dispatch — ALLOWED and ANNOUNCED at the one moment it matters"
else
    bad "6b  a missing record did not announce on an in-scope dispatch" "rc=$RC out='$(printf '%s' "$OUT" | head -2 | tr '\n' ' ')'"
fi

write_config 'STAGING_RECORD_REQUIRED="1"'
case_rc "6c  ...and STAGING_RECORD_REQUIRED=1 turns that announcement into a refusal — teeth are one declared line" 2 "$QA_PROMPT"
write_config

write_record "$DEPLOYED" failure
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "outcome='failure'"; then
    ok "6d  a record whose deploy FAILED is read as no record — 'ran and failed' and 'current' never look the same"
else
    bad "6d  a failed-deploy record was treated as a current staging" "rc=$RC"
fi

write_record "deadbeefdead"
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'does not exist'; then
    ok "6e  a record pointing at a commit this repository does not have is not a record"
else
    bad "6e  an unknown deployed commit was not announced" "rc=$RC"
fi

write_record "$DEPLOYED"
write_config 'STAGING_MAIN_REF="refs/heads/nonexistent"'
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'does not resolve'; then
    ok "6f  an unresolvable landing branch fails OPEN and says so — 'I cannot tell' is never 'forbidden'"
else
    bad "6f  an unresolvable STAGING_MAIN_REF did not fail open loudly" "rc=$RC"
fi
write_config

run "$(printf '{"tool_name":"Agent","tool_input":')"
if [ "$RC" -eq 0 ]; then ok "6g  an unparseable payload is ALLOWED — a refusal nobody could permit is worse than none"
else bad "6g  an unparseable payload was blocked" "rc=$RC"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 7. THE RECORDER — the only sanctioned way the record comes to exist ==="
# ---------------------------------------------------------------------------
rm -f "$ENTITY/.claude/state/staging-deployed"
FULL="$(git -C "$ENTITY" rev-parse HEAD)"
if bash "$RECORDER" --root "$ENTITY" --sha "$(printf '%s' "$FULL" | cut -c1-12)" --tree avelor --outcome success >/dev/null 2>&1; then
    ok "7a  staging-record.sh writes a record"
else
    bad "7a  staging-record.sh refused a well-formed call"
fi
run "$(payload "$QA_PROMPT")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "7b  ...and the guard reads it: a freshly recorded deploy makes the same dispatch SILENT"
else
    bad "7b  the guard did not accept the recorder's own output" "rc=$RC out='$(printf '%s' "$OUT" | head -2 | tr '\n' ' ')'"
fi
if bash "$RECORDER" --root "$ENTITY" --sha "not-a-sha" >/dev/null 2>&1; then
    bad "7c  the recorder accepted something that is not a commit hash"
else
    ok "7c  the recorder refuses a --sha that is not a commit hash — a typed SHA is the failure it prevents"
fi
if bash "$RECORDER" --root "$ENTITY" --outcome success >/dev/null 2>&1; then
    bad "7d  the recorder wrote a record with no commit in it"
else
    ok "7d  the recorder refuses to write a record with no commit"
fi
if bash "$RECORDER" --root "$ENTITY" --show 2>/dev/null | grep -q 'sha='; then
    ok "7e  --show prints what staging carries, for a human who wants to check"
else
    bad "7e  --show did not print the record"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 8. WIRING — a guard nobody registered is a guard nobody runs ==="
# ---------------------------------------------------------------------------
if python3 - "$ENGINE_ROOT/hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get("hooks", d)
for m in d.get("PreToolUse", []):
    if m.get("matcher") == "Agent":
        if any("guard-stale-staging.sh" in h.get("command", "") for h in m.get("hooks", [])):
            sys.exit(0)
sys.exit(1)
PY
then ok "8a  guard-stale-staging.sh is registered on PreToolUse[Agent] in hooks/hooks.json"
else bad "8a  guard-stale-staging.sh is not registered on PreToolUse[Agent]"; fi

if grep -q 'guard-stale-staging.sh' "$ENGINE_ROOT/.claude/settings.local.json" 2>/dev/null; then
    ok "8b  ...and in the engine's own settings.local.json, so the engine governs itself by it"
else
    bad "8b  guard-stale-staging.sh is missing from .claude/settings.local.json"
fi

if grep -q 'resolve-roots.sh' "$HOOK"; then
    ok "8c  the guard carries the shared root-resolution bootstrap (probe Layer R)"
else
    bad "8c  the guard does not carry the shared root bootstrap"
fi

if grep -q 'unevaluated_or_continue' "$HOOK"; then
    ok "8d  ...and the unevaluated-payload notice, so 'not mine' and 'could not tell' are different silences"
else
    bad "8d  the guard does not distinguish an unevaluated payload from a foreign one"
fi

# ---------------------------------------------------------------------------
echo ""
if [ -x "$SCRIPT_DIR/stale-staging.mutation.sh" ] && [ -z "${RICHOS_MUTATION_INNER:-}" ]; then
    echo "=== running the mutation harness: stale-staging.mutation.sh ==="
    if "$SCRIPT_DIR/stale-staging.mutation.sh"; then
        ok "9a  every property of this guard was proven load-bearing by removing it"
    else
        bad "9a  a mutation survived — a property this suite claims to prove is not proven"
    fi
fi

echo ""
printf '  %s passed, %s FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
