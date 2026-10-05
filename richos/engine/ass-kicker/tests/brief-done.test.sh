#!/usr/bin/env bash
#
# brief-done.test.sh - the suite for ass-kicker/brief-done.py, driven through the hook
# that runs it (scripts/hooks/guard-brief-scope.sh) wherever the verdict is the point.
#
# EVERYTHING RUNS IN A SANDBOX: a fixture repository shaped like richos (the tree is
# richos/mobile/native-android at the repository root), a fixture session repository,
# and a workspace of the fixture repository standing where a cross-repo worktree would.
# The operator's repositories, state and logs are never read or written.
#
# THE ACCEPTANCE CASE IS THE 2026-09-28 BRIEF, RECONSTRUCTED. andy-opus-dfix1 was sent to
# fix D02, D03 and D04 after main had carried their fixes for four days, with a quoted
# `git log ... -- richos/mobile/native-android` said to show "no fix" that, run, printed
# 40 lines. The fixture history below has the same shape: fix and test commits naming
# each ID, a merge naming D02, a records-only commit naming D05 and D06.
#
# GUARD=<path> runs the hook-level cases against another copy of the hook, which is how
# "each case fails on the code before this change" was shown: against the unchanged hook
# every refusal case below exits 0.
#
# Exit 0 only when every case passes.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/../brief-done.py"
GUARD="${GUARD:-$ENGINE_ROOT/scripts/hooks/guard-brief-scope.sh}"

PASS=0; FAIL=0
ok()  { printf '      ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '      FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '           %s\n' "$(printf '%s' "${2:0:1200}" | tr '\n' '|')"; FAIL=$((FAIL+1)); }
want() { # <label> <expected-rc> <expected-substring-or-empty> <actual-rc> <actual-out>
    if [ "$2" != "$4" ]; then bad "$1  (wanted exit $2, got $4)" "$5"; return; fi
    if [ -n "$3" ] && ! printf '%s' "$5" | grep -F -- "$3" >/dev/null; then
        bad "$1  (exit right, but the output never says '$3')" "$5"; return
    fi
    ok "$1"
}
lacks() { # <label> <forbidden-substring> <actual-out>
    if printf '%s' "$3" | grep -F -- "$2" >/dev/null; then bad "$1  (output says '$2')" "$3"; else ok "$1"; fi
}

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/brief-done.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export RICHOS_WORKSPACES_DIR="$T/state/workspaces"
mkdir -p "$RICHOS_WORKSPACES_DIR"

# --- the fixture repository ------------------------------------------------------
REPO="$T/richos"; mkdir -p "$REPO"
g() { git -C "$REPO" "$@"; }
g init -q -b main
g config user.email webdevbooster@gmail.com; g config user.name "Alex Booster"
g config commit.gpgsign false
A="$REPO/richos/mobile/native-android/app"
commit_at() { # <date> <message> <file> [<file>...]
    local when="$1" msg="$2"; shift 2
    for f in "$@"; do mkdir -p "$(dirname "$REPO/$f")"; echo "$msg" >>"$REPO/$f"; g add "$f"; done
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" g commit -qm "$msg"
}
commit_at "2026-09-20T10:00:00Z" "android: the first screen" richos/mobile/native-android/app/Main.kt
commit_at "2026-09-21T10:00:00Z" "tooling: T3 Code release gating, adopted as-is" richos/tools/gate.sh
commit_at "2026-09-24T19:00:00Z" "test(android): reproduce D02, a cold launch restoring the last reply cut off" \
    richos/mobile/native-android/app/RestoredReplyTest.kt
commit_at "2026-09-24T19:30:00Z" "Android D03: failing test, a press after Don't allow shows nothing" \
    richos/mobile/native-android/app/MicrophoneDeniedTest.kt
commit_at "2026-09-24T20:00:00Z" "fix(android): a reply read in the conversation leaves the shade (D04)" \
    richos/mobile/native-android/app/ReadReplies.kt
g checkout -q -b cc/andy-opus-d02
commit_at "2026-09-24T20:30:00Z" "fix(android): save a reply's final state at once" \
    richos/mobile/native-android/app/LocalSessionStore.kt
g checkout -q main
GIT_AUTHOR_DATE="2026-09-24T21:00:00Z" GIT_COMMITTER_DATE="2026-09-24T21:00:00Z" \
    g merge -q --no-ff cc/andy-opus-d02 -m "Merge cc/andy-opus-d02: Android restores the reply the person last saw (D02)"
commit_at "2026-09-25T09:00:00Z" "docs: acceptance round 2 found D05 and D06" docs/verification/r2/defects.md
# Somebody else's G2: a reviewer's finding label, the namespace named in the subject.
commit_at "2026-09-25T10:00:00Z" "tooling: the land lock waits on a live lease (Frank G2)" richos/tools/lock.sh
# An item named only in a BODY, never in a subject.
mkdir -p "$REPO/richos/tools"; echo tidy >>"$REPO/richos/tools/tidy.sh"; g add richos/tools/tidy.sh
GIT_AUTHOR_DATE="2026-09-25T11:00:00Z" GIT_COMMITTER_DATE="2026-09-25T11:00:00Z" \
    g commit -qm "tooling: tidy the gate script" -m "Noticed while reading D07's reproduction."
D02_TEST="$(g log --format=%h -1 --grep='reproduce D02')"
D03_TEST="$(g log --format=%h -1 --grep='Android D03')"
D04_FIX="$(g log --format=%h -1 --grep='(D04)')"
D02_MERGE="$(g log --format=%h -1 --merges)"

# A cross-repo workspace, where spawn.sh would put it.
WS="$T/richos-wt/andy-opus-dfix1"
g worktree add -q -b cc/andy-opus-dfix1 "$WS" main

# The session's own repository: the payload's cwd, and where acknowledgements are logged.
SESSION="$T/femcboost"; mkdir -p "$SESSION"
git -C "$SESSION" init -q -b main
git -C "$SESSION" -c user.email=webdevbooster@gmail.com -c "user.name=Alex Booster" commit -q --allow-empty -m root

# payload <brief file> <out json> [live|check|planned] [subagent type]
payload() {
    python3 - "$1" "$2" "${3:-live}" "$SESSION" "$REPO" "${4:-andy}" <<'PY'
import json, sys
brief, out, mode, session, repo, kind = sys.argv[1:7]
p = {"session_id": "fixture-session", "cwd": session, "hook_event_name": "PreToolUse",
     "tool_name": "Agent",
     "tool_input": {"name": "andy-opus-fixture", "subagent_type": kind,
                    "prompt": open(brief).read(), "isolation": "worktree"}}
if mode == "live":
    p["tool_use_id"] = "toolu_fixture"
elif mode in ("check", "planned"):
    p["richos_spawn_check"] = {"planned": [{"repo": repo}] if mode == "planned" else []}
json.dump(p, open(out, "w"))
PY
}
run_hook() { # <brief> [mode] [type] -> RC, OUT (stderr of the hook: the refusal text)
    payload "$1" "$T/p.json" "${2:-live}" "${3:-andy}"
    OUT="$(CLAUDE_PROJECT_DIR="$SESSION" bash "$GUARD" <"$T/p.json" 2>&1 >/dev/null)"; RC=$?
}
run_lib() { # <brief> [mode] -> RC, OUT (the library's own report, including allow notes)
    payload "$1" "$T/p.json" "${2:-live}"
    OUT="$(CLAUDE_PROJECT_DIR="$SESSION" python3 "$LIB" check "$T/p.json" 2>&1)"; RC=$?
}
ACKLOG="$SESSION/.claude/state/already-done-acks.log"

# --- the briefs ------------------------------------------------------------------
# The 2026-09-28 brief, reconstructed: same structure, same claim, same command shape.
# The --since value carries a time and a zone. Git reads a bare date ("--since=2026-09-24")
# as that date at the CURRENT time of day, so once the clock passed the fixture's
# 2026-09-24 commit times the command printed nothing and D1f, D1g, D14 and D18b failed
# every evening (seen 2026-10-04 22:04Z). Midnight UTC keeps every 2026-09-24 commit in.
cat >"$T/andy.md" <<EOF
cross-repo-worktree: $WS

ceo-todos-deferred: the CEO ordered this work himself; TODO 2.2 stays pending.

## The job: fix the three open Android defects from the 2026-09-24 physical acceptance round

Each defect is written up, with its reproduction, in the private record (read each in full):
- D02: \`docs/defects/D02-android-cold-launch-restores-last-reply-truncated.md\`
- D03: \`docs/defects/D03-android-denied-microphone-does-nothing.md\`
- D04: \`docs/defects/D04-android-read-reply-notifications-stay-in-the-shade.md\`

\`git -C $REPO log --oneline main --since=2026-09-24T00:00:00Z -- richos/mobile/native-android\` shows no fix for any of them (checked 2026-09-28). Re-check each defect against current \`main\` first.

One commit per defect, each with a test that fails before and passes after.
EOF

echo "=== brief-done: fixture ready ($(g rev-list --count main) commits on main) ==="

# D1 - THE ACCEPTANCE CASE: the reconstructed andy-opus-dfix1 brief is refused, with the commits.
run_hook "$T/andy.md"
want "D1a the andy-opus-dfix1 brief is REFUSED" 2 "ALREADY-DONE" "$RC" "$OUT"
want "D1b it names D02's commits, the merge included" 2 "$D02_MERGE" "$RC" "$OUT"
want "D1c it names D02's test commit" 2 "$D02_TEST" "$RC" "$OUT"
want "D1d it names D03's commit" 2 "$D03_TEST" "$RC" "$OUT"
want "D1e it names D04's fix" 2 "$D04_FIX" "$RC" "$OUT"
want "D1f the quoted 'shows no fix' command is CONTRADICTED by its own output" 2 "CONTRADICTED" "$RC" "$OUT"
want "D1g the contradiction prints the line count the command really produced" 2 "line(s)" "$RC" "$OUT"
want "D1h the refusal carries the acknowledgement line to write" 2 "already-done-ack: <why" "$RC" "$OUT"
lacks "D1i the records-only commit (D05, D06) is not what refuses it" "acceptance round 2" "$OUT"

# D2 - the evidence claim on its own: no item named, the command contradicts the sentence.
cat >"$T/claim.md" <<EOF
## Context

\`git -C $REPO log --oneline main -- richos/mobile/native-android\` shows no fix. Look at the history yourself.
EOF
run_hook "$T/claim.md"
want "D2a 'shows no fix' beside a command that prints commits is REFUSED" 2 "CONTRADICTED" "$RC" "$OUT"
lacks "D2b and it is not mistaken for already-done work" "ALREADY-DONE:" "$OUT"

# D3 - genuinely new work passes, even with a negative claim, because the claim is true.
cat >"$T/new.md" <<EOF
cross-repo-worktree: $WS

## The job: fix defect D09, the pairing card that never closes

\`git -C $REPO log --oneline main -F --grep=D09\` returns nothing, so nobody has touched it.
EOF
run_hook "$T/new.md"
want "D3a a brief for genuinely new work PASSES" 0 "" "$RC" "$OUT"
run_lib "$T/new.md"
want "D3b and the library adds nothing to say about it" 0 "" "$RC" "$OUT"
[ -z "$OUT" ] && ok "D3c silent on a clean brief" || bad "D3c silent on a clean brief" "$OUT"

# D4 - the acknowledgement lets it through, and a live spawn is logged.
{ cat "$T/andy.md"; echo ""; echo "already-done-ack: the 2026-09-24 D04 fix regressed on the Honor today and this reopens it"; } >"$T/andy-ack.md"
rm -f "$ACKLOG"
run_hook "$T/andy-ack.md" live
want "D4a an already-done-ack with a reason lets the spawn through" 0 "" "$RC" "$OUT"
if [ -f "$ACKLOG" ] && grep -F "regressed on the Honor" "$ACKLOG" | grep -F "richos:D02" | grep -F "$D04_FIX" >/dev/null; then
    ok "D4b the live spawn is logged with its items, commits and reason"
else
    bad "D4b the live spawn is logged with its items, commits and reason" "$(cat "$ACKLOG" 2>/dev/null || echo 'no log')"
fi
N_BEFORE="$(wc -l <"$ACKLOG" 2>/dev/null | tr -d ' ')"
run_hook "$T/andy-ack.md" check
want "D4c spawn.sh's dry evaluation passes too" 0 "" "$RC" "$OUT"
N_AFTER="$(wc -l <"$ACKLOG" 2>/dev/null | tr -d ' ')"
[ "$N_BEFORE" = "$N_AFTER" ] && ok "D4d ...and does NOT log: one spawn, one row" || bad "D4d a dry evaluation logged a row" "$N_BEFORE -> $N_AFTER"
run_lib "$T/andy-ack.md" check
want "D4e the accepted line is echoed with what it waived" 0 "already-done-ack accepted" "$RC" "$OUT"

# D5 - a bare or token acknowledgement exempts nothing.
{ cat "$T/andy.md"; echo ""; echo "already-done-ack:"; } >"$T/bare.md"
run_hook "$T/bare.md"
want "D5a a bare marker is still REFUSED" 2 "ALREADY-DONE" "$RC" "$OUT"
{ cat "$T/andy.md"; echo ""; echo "already-done-ack: needed"; } >"$T/token.md"
run_hook "$T/token.md"
want "D5b a token reason is REFUSED and says why" 2 "NOT ACCEPTED" "$RC" "$OUT"
{ cat "$T/andy.md"; echo ""; echo '```'; echo "already-done-ack: the 2026-09-24 D04 fix regressed on the Honor today and this reopens it"; echo '```'; } >"$T/fenced.md"
run_hook "$T/fenced.md"
want "D5c an acknowledgement inside a code fence is an example, not a line" 2 "ALREADY-DONE" "$RC" "$OUT"

# D6 - an ID main only MENTIONS in records is not done work.
cat >"$T/mention.md" <<EOF
cross-repo-worktree: $WS

## The job: fix defect D05, the Tailscale line
EOF
run_hook "$T/mention.md"
want "D6 an item named only by a records-only commit PASSES" 0 "" "$RC" "$OUT"

# D7 - a brief that cites the history it is writing about is not refused for it.
cat >"$T/cited.md" <<EOF
cross-repo-worktree: $WS

## The job: harden the D02 restore

Defect D02 was fixed in $D02_TEST and landed in $D02_MERGE; add the missing edge case.
EOF
run_hook "$T/cited.md"
want "D7 an item whose commit the brief cites PASSES" 0 "" "$RC" "$OUT"

# D8 - what is NOT an item: a name with a digit, a protocol line, a quoted record.
cat >"$T/nonitems.md" <<EOF
cross-repo-worktree: $WS

ceo-todos-deferred: the CEO chose later; TODO 2.2 stays pending.

## The job: adopt T3 Code's release gating for the phone build

The old record said "routed to andy-opus-d02", which is history, not this job.
EOF
run_hook "$T/nonitems.md"
want "D8a T3, a protocol line's TODO 2.2 and a quoted 'routed to' are not items" 0 "" "$RC" "$OUT"
ITEMS="$(python3 "$LIB" items "$T/nonitems.md")"
[ "$ITEMS" = '{"ids": [], "names": []}' ] && ok "D8b nothing is extracted from it" || bad "D8b nothing is extracted from it" "$ITEMS"
ITEMS="$(printf 'Fix defects D02-D04 and item 3.41.\n' >"$T/range.md"; python3 "$LIB" items "$T/range.md")"
[ "$ITEMS" = '{"ids": ["D02", "D03", "D04", "3.41"], "names": []}' ] && ok "D8c a range expands and a framed dotted number counts" || bad "D8c range and dotted number" "$ITEMS"

# D9 - "routed to" names a teammate, and its landed merge refuses.
cat >"$T/routed.md" <<EOF
cross-repo-worktree: $WS

## The job

The restore fix was routed to andy-opus-d02 last week; finish what it started.
EOF
run_hook "$T/routed.md"
want "D9 work 'routed to' a teammate whose merge is on main is REFUSED" 2 "andy-opus-d02" "$RC" "$OUT"

# D10 - only read-only commands are ever run.
: >"$T/canary"
cat >"$T/unsafe.md" <<EOF
## Context

\`rm -f $T/canary\` shows nothing. \`git -C $REPO log --output=$T/written main\` shows nothing.
\`git -C $REPO -c core.pager=touch log main\` shows nothing. \`ls $T > $T/written2\` returns nothing.
EOF
run_hook "$T/unsafe.md"
want "D10a commands outside the read-only list are not judged" 0 "" "$RC" "$OUT"
[ -f "$T/canary" ] && [ ! -e "$T/written" ] && [ ! -e "$T/written2" ] \
    && ok "D10b ...and not run: nothing deleted, nothing written" \
    || bad "D10b a quoted command was executed" "$(ls -la "$T")"

# D11 - spawn.sh's dry run: the workspace does not exist yet, the plan names the repository.
sed "s#cross-repo-worktree: $WS#cross-repo-worktree: $T/richos-wt/not-created-yet#" "$T/andy.md" >"$T/planned.md"
run_hook "$T/planned.md" planned
want "D11 before the workspace exists, the planned repository is searched" 2 "ALREADY-DONE" "$RC" "$OUT"

# D12 - the sections the spawn path appends are not the lead's brief.
cat >"$T/generated.md" <<'EOF'
## The job

Tidy the gate script's help text.

## Evidence commands in this brief, run at spawn

- `git log --oneline main` printed: fix(android): a reply read leaves the shade (D04)
EOF
run_lib "$T/generated.md"
want "D12 an ID inside an appended evidence section is not an item" 0 "" "$RC" "$OUT"

# D13 - a command that fails here is not a contradiction; the annotation shows the failure.
cat >"$T/fails.md" <<EOF
## Context

\`git -C $T/no-such-dir log --oneline main\` shows no fix.
EOF
run_hook "$T/fails.md"
want "D13 a negative claim beside a command that cannot run here is not refused" 0 "" "$RC" "$OUT"

# D14 - the annotation: the real output goes beside the claim, and a clean brief is untouched.
ANN="$(python3 "$LIB" annotate "$T/andy.md" --repo "$REPO" 2>/dev/null)"
printf '%s' "$ANN" | grep -F "## Evidence commands in this brief, run at spawn" >/dev/null \
    && printf '%s' "$ANN" | grep -F "line(s)" >/dev/null \
    && printf '%s' "$ANN" | grep -F "$D04_FIX" >/dev/null \
    && ok "D14a the evidence command's real output is appended to the brief" \
    || bad "D14a the evidence command's real output is appended to the brief" "$ANN"
printf 'Tidy the help text.\n' >"$T/plain.md"
if cmp -s <(python3 "$LIB" annotate "$T/plain.md" --repo "$REPO" 2>/dev/null) "$T/plain.md"; then
    ok "D14b a brief with no evidence command is byte-identical"
else
    bad "D14b a brief with no evidence command was changed"
fi
printf '%s\n' "$ANN" >"$T/annotated.md"
run_hook "$T/annotated.md"
want "D14c the annotated brief is still refused for its own claim, and only once" 2 "CONTRADICTED" "$RC" "$OUT"
N_CLAIMS="$(printf '%s\n' "$OUT" | grep -c '^  the brief:  ')"
[ "$N_CLAIMS" = 1 ] && ok "D14d the appended output is not re-read as a second claim" \
    || bad "D14d the appended output was re-read as a claim ($N_CLAIMS claims)" "$OUT"

# D16-D19 - what the 313-brief corpus taught: each rule removed a class of false refusal.
cat >"$T/ns.md" <<EOF
cross-repo-worktree: $WS

## The job: fix defect G2 from Urban's audit, the settings row
EOF
run_hook "$T/ns.md"
want "D16a another list's G2 ('Frank G2' in the subject) does not refuse a brief that never mentions Frank" 0 "" "$RC" "$OUT"
printf '\nFrank raised this in his review too.\n' >>"$T/ns.md"
run_hook "$T/ns.md"
want "D16b ...and does refuse one that is about Frank's list" 2 "Frank G2" "$RC" "$OUT"
cat >"$T/floor.md" <<EOF
cross-repo-worktree: $WS

## The job: fix defect G2 from Frank's 2026-09-26 review
EOF
run_hook "$T/floor.md"
want "D17 a commit older than the round the item belongs to is not its fix" 0 "" "$RC" "$OUT"
grep -v 'shows no fix' "$T/andy.md" >"$T/andy-noclaim.md"
run_hook "$T/andy-noclaim.md" live ray
want "D18a a verifier (QA_TOOLKIT_AGENTS) is sent to re-check fixes, not refused for them" 0 "" "$RC" "$OUT"
run_hook "$T/andy.md" live ray
want "D18b ...but a verifier's brief with a false 'shows no fix' is still CONTRADICTED" 2 "CONTRADICTED" "$RC" "$OUT"
lacks "D18c ...and only that" "ALREADY-DONE:" "$OUT"
cat >"$T/body.md" <<EOF
cross-repo-worktree: $WS

## The job: fix defect D07, the long-press menu
EOF
run_hook "$T/body.md"
want "D19 an item named only in a commit BODY is not done work" 0 "" "$RC" "$OUT"

# D20-D22 - negative sentences that are not evidence about now.
cat >"$T/target.md" <<EOF
## The job

After your change, \`git -C $REPO log --oneline main\` returns nothing for the old name.

## Completion criterion

\`git -C $REPO log --oneline main\` shows no fix left to make.
EOF
run_hook "$T/target.md"
want "D20 a target state (after your change, completion criterion) is not refused" 0 "" "$RC" "$OUT"
cat >"$T/quoted.md" <<EOF
## What happened

The old brief said: "\`git -C $REPO log --oneline main\` shows no fix", and it was wrong.
EOF
run_hook "$T/quoted.md"
want "D21 a negative claim inside a quotation reports somebody else's words" 0 "" "$RC" "$OUT"
cat >"$T/judged.md" <<EOF
## Context

\`git -C $REPO log --oneline main\` shows nothing relevant to the pairing screen.
EOF
run_hook "$T/judged.md"
want "D22 'nothing relevant' is a judgment of lines that exist, not a claim there are none" 0 "" "$RC" "$OUT"

# D15 - speed: the added cost on a brief that names nothing is no subprocess at all.
python3 - "$LIB" <<'PY' && ok "D15 a brief with no item and no evidence runs no subprocess" || bad "D15 a clean brief ran a subprocess"
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("bd", sys.argv[1]); bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)
calls = []
real = subprocess.run
subprocess.run = lambda *a, **k: calls.append(a) or real(*a, **k)
payload = {"tool_name": "Agent", "cwd": "", "tool_input": {"prompt": "## The job\n\nTidy the help text of the gate script.\n"}}
bd.named_items(payload["tool_input"]["prompt"])
bd.already_done(payload["tool_input"]["prompt"], ["/nonexistent"])
bd.contradicted(payload["tool_input"]["prompt"], ["/nonexistent"])
sys.exit(1 if calls else 0)
PY

echo ""
echo "=== brief-done tests: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
