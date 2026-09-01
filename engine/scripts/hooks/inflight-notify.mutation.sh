#!/usr/bin/env bash
#
# inflight-notify.mutation.sh — PROVES THE IN-FLIGHT SUITE CAN FAIL.
#
# 38 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. That is not a general anxiety, it is this project's
# most-repeated defect, and this guard is unusually exposed to it: almost every
# property here is of the form "it did not quietly wave something through", and
# a test for "it did not quietly do the wrong thing" is exactly the kind that
# passes for free — including when the guard never ran at all.
#
# So: take the shipped source, remove ONE property at a time, and assert that
#   1. inflight-notify.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives
#      a green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/inflight-notify.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t inflight-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-inflight-notify.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-inflight-sends.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-inflight-acks.sh" \
       "$ENGINE_ROOT/scripts/hooks/inflight-notify.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/inflight.sh" "$ENGINE_ROOT/scripts/lib/inflight.py" \
       "$ENGINE_ROOT/scripts/lib/teammate-identity.py" \
       "$ENGINE_ROOT/scripts/lib/agent-liveness.py" \
       "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/scripts/inflight-notify.sh" "$ENGINE_ROOT/scripts/inflight-ack.sh" "$dir/scripts/"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/inflight-notify.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

echo "=== in-flight sweep: every property, proven load-bearing by removing it ==="

# 1. THE SHA IS WHAT TIES A NOTICE TO A LAND. Without it "I messaged them at
#    some point" clears a debt about a commit that did not exist yet.
mutant notice-ignores-sha "3a." scripts/lib/inflight.py \
    '        if not any(tip.startswith(tok) and len(tok) >= 7 for tok in note.get("sha_tokens", [])):
            continue' \
    '        pass' \
    "Any message to anyone would clear any land."

# 2. AMBIGUITY MUST CREDIT NOTHING. Crediting the first match makes the guard
#    report a teammate as told when a different teammate was told.
mutant credit-first-match "9a." scripts/lib/inflight.py \
    '        if len(hits) != 1:
            continue  # zero matches, or ambiguous — credit nothing' \
    '        if not hits:
            continue' \
    "A notice to someone else would be credited to whoever matched loosely."

# 3. THE ATTRIBUTION GATE. Logging worker sends into the lead's notice ledger
#    lets a teammate discharge the lead's obligation to itself.
mutant witness-logs-workers "3d." scripts/hooks/notice-inflight-sends.sh \
    'if payload.get("agent_id"):
    finish()' \
    'if False:
    finish()' \
    "A teammate's own message would satisfy the guard on its behalf."

# 4. THE BODY IS NEVER LOGGED. An evidence log that accumulates model output is
#    a privacy defect; the sibling hook settled this and this one inherits it.
mutant witness-logs-body "4d." scripts/hooks/notice-inflight-sends.sh \
    '    "sha_tokens": shas,' \
    '    "sha_tokens": shas,
    "body": body,' \
    "Message bodies would accumulate in a log nobody thinks of as sensitive."

# 5. LIVENESS: a hand-rolled worktree takes no lock, so absence of a lock is
#    absence of evidence. Treating it as death is how the whole sweep goes
#    quiet in exactly the topology this operation runs in.
mutant handrolled-presumed-dead "2a." scripts/lib/inflight.py \
    '            wt["liveness"] = "presumed LIVE (hand-rolled worktree — no lock is ever taken here, so quiet is not death)"
            wt["live"] = True' \
    '            wt["liveness"] = "assumed dead"
            wt["live"] = False' \
    "Every hand-rolled worktree — the shape this was built in — would be invisible."

# 6. ONLY AT A LANDING. Without the main-checkout test the guard fires on an
#    engineer pushing their own branch from their own worktree: the wrong
#    person, blocked on a file they do not own.
mutant fires-inside-worktrees "7g." scripts/hooks/guard-inflight-notify.sh \
    '[ "$(cd "$REPO" && pwd -P)" = "$(cd "$MAIN_CHECKOUT" && pwd -P)" ] || exit 0' \
    ': ' \
    "Engineers would be blocked by a guard aimed at the lander."

# 7. THE ACK IS ABOUT ONE COMMIT. An ack that matches any sha is a teammate
#    acknowledging a land it has never heard of.
mutant ack-any-sha "5m." scripts/lib/inflight.py \
    '        if got_sha != tip:' \
    '        if False:' \
    "A stale ack from a previous land would satisfy this one."

# 8. THE PATHS FIELD IS THE ONLY UNCOPYABLE ONE. Drop its check and the whole
#    ack becomes transcribable from the notice without looking at anything.
mutant ack-paths-unchecked "5e." scripts/lib/inflight.py \
    '                problems.append(
                    "paths: %r is neither in the moved changeset nor present in "
                    "this worktree — it cannot have been read off either" % p)' \
    '                pass' \
    "The ack could be filled in entirely by copying the message back."

# 9. THE POSITIVE PROBE ITSELF. If the guard leaves no footprint, "silent no-op"
#    and "never executed" become the same observation — which is how a guard
#    passes for the wrong reason.
mutant no-footprint "6c." scripts/lib/inflight.sh \
    '    printf '"'"'%s\n'"'"' "$repo" >> "$f" 2>/dev/null || true' \
    '    :' \
    "6a and 6b would both pass on a guard that never ran."

# 10. A WAIVER WITHOUT A REASON is a silent skip wearing a ledger row.
mutant waiver-needs-no-reason "5l." scripts/inflight-notify.sh \
    '        [ -n "$REASON" ] || { echo "inflight-notify.sh waive: --reason is required. A waiver with no reason is a silent skip wearing a ledger row." >&2; exit 2; }' \
    '        :' \
    "Waiving would become as cheap as forgetting, which is the thing being fixed."

# 11. THE TIMEOUT. Without it an ack that never comes is never surfaced, and the
#     §8b fallback is never reached.
mutant no-timeout "8b." scripts/lib/inflight.py \
    '            out["overdue"] = age > timeout_min * 60' \
    '            out["overdue"] = False' \
    "A teammate that never acks would go unreported forever."

# 12. PATH NORMALIZATION — a regression pin, not a hypothetical. On macOS git
#     returns /private/var/... for a /var/... tmpdir, so a waiver recorded
#     against a worktree failed to match the same worktree. Caught by 5j.
mutant abspath-not-realpath "5j." scripts/lib/inflight.py \
    '    return os.path.realpath(os.path.abspath(path)).rstrip("/")' \
    '    return os.path.abspath(path).rstrip("/")' \
    "The symlinked-tmpdir mismatch would come straight back."

# 13. IDENTITY IS THE UNIQUE NAME, NEVER THE ROLE. This is the 2026-08-31
#     defect itself: resolve a teammate as its agent_type and the debt side
#     writes `zach` while the witness writes `zach-opus-s1`, so a notice that
#     was genuinely sent can never be credited and the land is waived through.
mutant identity-is-the-role "10c." scripts/lib/inflight.py \
    '        name = index["names"].get(agent_id, "")' \
    '        name = index["roles"].get(agent_id, "")' \
    "The sweep would call the teammate 'zach' again — the exact string that could not be joined to 'zach-opus-s1'."

# 14. THE ROLE IS NOT AN ADDRESS. The tempting shortcut — credit a notice to
#     any live worktree whose role matches — reports a teammate as told when a
#     DIFFERENT teammate of the same role was told. Three Zachs ran at once on
#     the day this was measured.
mutant credits-by-role "10d." scripts/lib/inflight.py \
    '        addresses = {a for a in (name, base, agent_id,' \
    '        addresses = {a for a in (name, base, agent_id, role,' \
    "A notice to the bare role would clear one arbitrary teammate's debt."

# 14b. BOTH EXACT JOINS AT ONCE. The reproduction is defended twice over —
#      by the agent id the witness resolved at send time, and by the unique
#      name the debt side resolves at push time. Removing either alone leaves
#      the other standing (which is the point of having two). Removing both in
#      one edit leaves only the token readings, which is precisely the state
#      that produced the 2026-08-31 false positive.
mutant credit-by-tokens-only "10b." scripts/lib/inflight.py \
    '        hits = [w for w in worktrees if to_aid and w.get("agent_id") == to_aid]
        # 2. The address set: unique spawn name, agent id, directory name.
        if len(hits) != 1:
            hits = [w for w in worktrees if to in w.get("addresses", ())]' \
    '        hits = []' \
    "A notice to zach-opus-s1 could not be credited to agent-<id> at all — the measured defect, verbatim."

# 15. THE OPERATOR'S DIAGNOSTIC MUST RESOLVE. Reverting the team-directory
#     ladder to "exactly one session directory or nothing" is what printed
#     `notice ledger: <no team dir resolved>` on a machine with four of them.
mutant teams-dir-single-or-nothing "11a." scripts/lib/teammate-identity.py \
    '    active = [d for d in sessions if _has_team_stream(d)]' \
    '    return "", "more than one session team directory"' \
    "status goes blind exactly when the operator reaches for it."

# 16. THE DOCUMENTED ESCAPE HATCH MUST WORK AS DOCUMENTED. `waive` names
#     INFLIGHT_TEAMS_DIR in its own error message; a variable that fails for
#     whoever follows the instructions printed on it is worse than none.
mutant teams-dir-pointer-ignored "11c." scripts/lib/teammate-identity.py \
    '    if explicit and not sessions:' \
    '    if False and not sessions:' \
    "The escape hatch fails for whoever reads the error message it prints."

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ %s/%s mutants killed — every property is load-bearing.\033[0m\n' "$PASS" "$PASS"
    exit 0
fi
printf '\033[31m✗ %s killed, %s SURVIVED.\033[0m\n' "$PASS" "$FAIL" >&2
exit 1
