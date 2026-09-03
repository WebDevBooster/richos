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
# THE COPY LIST IS PART OF THE TEST. It lacked scripts/lib/git-jurisdiction.sh
# until 2026-09-02, so every mutant sandbox ran a guard that REFUSED TO START —
# and a guard that never ran refuses everything, which reads exactly like a
# guard that caught the mutation. Four mutants were reported as "the suite went
# red, but not at <case>" for that reason alone, and the whole harness was one
# missing library away from proving nothing at all. If a mutant here goes red in
# a place you did not expect, check this list before you check the property.
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
       "$ENGINE_ROOT/scripts/lib/git-jurisdiction.sh" \
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
    '    if got_sha != tip:' \
    '    if False:' \
    "A stale ack from a previous land would satisfy this one."

# 8. THE PATHS FIELD IS THE ONLY UNCOPYABLE ONE. Drop its check and the whole
#    ack becomes transcribable from the notice without looking at anything.
mutant ack-paths-unchecked "5e." scripts/lib/inflight.py \
    '            problems.append(
                "paths: %r is neither in the moved changeset nor present in "
                "this worktree — it cannot have been read off either" % p)' \
    '            pass' \
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
    '        to_aid = (note.get("to_agent_id") or "").strip()
        if not to_aid and names and to in names:
            to_aid = to                      # addressed by raw agent id
        hits = [w for w in worktrees if to_aid and w.get("agent_id") == to_aid]
        # 2. The address set: unique spawn name, agent id, directory name —
        #    against BOTH legal forms of the recipient'"'"'s address.
        if len(hits) != 1:
            forms = {to}
            if to_aid:
                forms.add(to_aid)
                forms.add("agent-" + to_aid)
                if names.get(to_aid):
                    forms.add(names[to_aid])
            hits = [w for w in worktrees
                    if forms & set(w.get("addresses", ()))]' \
    '        hits = []' \
    "A notice to zach-opus-s1 could not be credited to agent-<id> at all — the measured defect, verbatim."

# 14c. BOTH LEGAL ADDRESS FORMS. SendMessage takes the unique spawn name OR
#      the bare agentId, and the lead used the SECOND for every notice in this
#      machine's live ledger on 2026-09-01. Stop expanding one into the other
#      and a hand-rolled worktree — which carries a name and no id — can never
#      be credited for a notice that was genuinely sent to it.
mutant address-forms-not-expanded "10l." scripts/lib/inflight.py \
    '                if names.get(to_aid):
                    forms.add(names[to_aid])' \
    '                pass' \
    "A notice addressed by agent id would leave its recipient reported as never told."

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

# ==========================================================================
# 17-25. THE GENERATOR — added 2026-09-02
# ==========================================================================
# The guard already computed everything mechanical in the notice and then made
# the lander type it back by hand and checked the typing. That produced a
# 25-line message whose mandatory content is five short fields, and the CEO
# called it needlessly feeding piles of noise to agents in flight. The
# reply was "it stops now", and he rejected that on the spot — correctly,
# because an intention is not a mechanism, and his standing ruling on exactly
# this is "I cannot rely on your promises. There must be a guarantee."
#
# So every property of the generator is removed here one at a time. These are
# the ones most exposed to passing for free: "the body is short" and "the field
# was pre-filled" are both satisfied by a generator that emits nothing at all.

# 17. THE REFUSAL POINTS AT THE GENERATOR. Point it back at a message to
#     compose and the whole mechanism is a suggestion again.
mutant refusal-points-at-hand-composition "2d." scripts/hooks/guard-inflight-notify.sh \
    'echo "        scripts/inflight-notify.sh notice \\"' \
    'echo "        (compose it yourself, and name the sha) \\"' \
    "The lander would be told to write the message, which is what produced 25 lines."

# 18. AND IT DOES NOT ALSO HAND OUT A TEMPLATE. A refusal that prints a
#     fill-in-the-blanks ack command next to the generator invites the hand
#     path back in, and the hand path is the defect.
mutant refusal-reprints-ack-template "2e." scripts/hooks/guard-inflight-notify.sh \
    'echo "      Send the body VERBATIM: the SHA in it is what the witness matches"' \
    'echo "        scripts/inflight-ack.sh --sha $TIP --impact <kind> --detail x"
    echo "      Send the body VERBATIM: the SHA in it is what the witness matches"' \
    "Two paths would be offered, and the hand-typed one is the one that failed."

# 19. THE SHA IS PRE-FILLED. A generated notice that asks for the sha is a
#     template, and a typed sha is the 2026-09-01 in-flight notice that
#     discharged nothing because the lander typed it rather than read it.
mutant generator-asks-for-the-sha "2g." scripts/inflight-notify.sh \
    'print("  main moved to %s" % tip)' \
    'print("  main moved to <FILL: the tip sha>")' \
    "The one field that must never be typed would be typed."

# 20. THE TEAMMATE IS PRE-FILLED, from the exact name join. Addressing the
#     directory instead means the witness cannot credit the send.
mutant generator-drops-the-name "2h." scripts/inflight-notify.sh \
    '    to = wt.get("resolved_name") or ""' \
    '    wt["resolved_name"] = ""
    to = ""' \
    "The notice would be addressed to something the witness cannot join to a debt."

# 21. THE PATHS LINE IS PRE-FILLED, from the predicate own overlap computation.
mutant generator-drops-paths "2i." scripts/inflight-notify.sh \
    'print("  paths: %s" % paths)' \
    'pass' \
    "The teammate would not be told which of its own files moved."

# 22. EXACTLY TWO OPERATOR FIELDS. Not "few" — two. A third blank is a third
#     place to inflate, and the CEO rejected "shorter next time" as the fix.
mutant generator-third-blank-field "2j." scripts/inflight-notify.sh \
    'print("  paths: %s" % paths)' \
    'print("  paths: <FILL: type the paths yourself>")' \
    "A third fill-in field reopens the blank space the generator exists to close."

# 23. THE OPERATOR FIELDS ACTUALLY BAKE IN. A generator that ignores --impact
#     and --detail leaves the lander editing the output by hand, which is the
#     hand path with extra steps.
mutant generator-ignores-operator-fields "2l." scripts/inflight-notify.sh \
    'impact = (os.environ.get("IF_ARGS_IMPACT") or "").strip()' \
    'impact = ""' \
    "The two fields that ARE the operator's would have to be pasted in afterwards."

# 24. THE BODY IS FIVE LINES. This is the shape constraint itself.
mutant generator-body-grows "2m." scripts/inflight-notify.sh \
    'print("  ack: %s" % ack_cmd)' \
    'print("  context: %s" % wt["path"])
    print("  branch: %s" % wt["branch"])
    print("  ack: %s" % ack_cmd)' \
    "The body would grow back, one well-meant line at a time — exactly how it got to 25."

# 25. THE TWO OPERATOR FIELDS ARE VALIDATED, not merely requested. A
#     multi-line detail is the single easiest way back to a wall of text.
mutant generator-detail-unvalidated "2o." scripts/inflight-notify.sh \
    'if [ "$(printf '"'"'%s'"'"' "$DETAIL" | wc -l | tr -d '"'"' '"'"')" != "0" ]; then' \
    'if false; then' \
    "A pasted paragraph would go straight into the body."

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ %s/%s mutants killed — every property is load-bearing.\033[0m\n' "$PASS" "$PASS"
    exit 0
fi
printf '\033[31m✗ %s killed, %s SURVIVED.\033[0m\n' "$PASS" "$FAIL" >&2
exit 1
