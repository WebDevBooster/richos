#!/usr/bin/env bash
#
# left-off.mutation.sh — PROVES THE "WHERE HE LEFT OFF" SUITE CAN FAIL.
#
# Thirty-five green ticks are evidence of nothing until somebody has watched
# them go red for the right reason, and this suite is unusually exposed to that
# for two reasons:
#
#   1. HALF OF WHAT IT ASSERTS IS SILENCE. Eight cases pass by observing that
#      nothing was reported, and a predicate that never runs reports nothing
#      too. A suite made largely of silent cases will pass over a mechanism
#      that is simply switched off.
#
#   2. THE THING UNDER TEST IS A REPORT, and a report that says something is
#      easy to confuse with a report that says the RIGHT thing. LO20 and LO23
#      differ only in which git fact decides, and a check that answered LANDED
#      to everything would pass one of them.
#
# So: take the shipped source, remove ONE property at a time in a throwaway
# copy of the engine, and assert that
#   1. left-off.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied.
#
# The loop is scripts/lib/mutation-harness.sh. Run directly, or let
# left-off.test.sh run it, which it does.
#
# Run directly: scripts/hooks/left-off.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "where he left off" "scripts/hooks/left-off.test.sh"

S="scripts/lib/left-off.py"
H="scripts/hooks/left-off-report.sh"

# --- 1. WHICH MESSAGES ARE HIS --------------------------------------------
# `queued` is him typing while the assistant is mid-turn, which he does
# constantly: 53 messages on this machine, and on the morning this exists for
# he sent the same one twice in forty seconds. A predicate keyed to `typed`
# alone drops them, silently, and picks an older message as the anchor.
mutant typed-only "LO02" "$S" \
    '        if rec.get("promptSource") == "sdk":' \
    '        if rec.get("promptSource") != "typed":' \
    "messages he queued while the assistant was busy would stop being his, and the report would anchor on an older message than the one he actually left on."

# Without the origin check a task notification is indistinguishable from him,
# and the transcript is full of them: 1348 across this machine against 2047 of
# his.
mutant ignores-origin "LO05" "$S" \
    '        if origin.get("kind") != "human":' \
    '        if False:' \
    "a task notification would anchor the report, so the thing he 'left on' would be the machine announcing a job to itself."

# Hook feedback arrives as a `user` row too, and it arrives constantly through
# a gap. Counting it closes the gap.
mutant ignores-meta "LO06" "$S" \
    '    if rec.get("isMeta") or rec.get("isSidechain") or rec.get("isCompactSummary"):' \
    '    if rec.get("isSidechain") or rec.get("isCompactSummary"):' \
    "a Stop-hook feedback line would count as him, and since those arrive all night the nine-hour gap would read as minutes and nothing would be reported at all."

# --- 2. THE ANCHOR IS THE LAST OF HIS MESSAGES ----------------------------
mutant anchor-is-oldest "LO30" "$S" \
    '    anchor_when, anchor_text = humans[-1]' \
    '    anchor_when, anchor_text = humans[0]' \
    "the report would open with the first thing he said in the sitting instead of the last, which is a different question and usually an answered one."

# --- 3. THE GAP IS A GAP --------------------------------------------------
mutant no-threshold "LO11" "$S" \
    '    if gap < gap_minutes * 60:' \
    '    if False:' \
    "every message would carry a full return report, and a line under every message is the muting failure this engine has recorded three times."

# --- 4. THE ARRIVING MESSAGE IS NOT THE ANCHOR ----------------------------
# If the host has already written the prompt when the hook fires, the gap is
# zero and NOTHING is ever reported. This is the failure mode where the whole
# mechanism is silently inert.
mutant keeps-current-prompt "LO13" "$S" \
    '    if (now - last_when).total_seconds() > CURRENT_PROMPT_WINDOW_S:{NL}        return humans{NL}    return humans[:-1]' \
    '    return humans' \
    "when the host writes the arriving message before the hook runs, the gap measures zero and the report never fires -- the mechanism switched off by a host-ordering detail."

# ... and the other way: dropping the last message by TIMING rather than by
# identity throws away his actual pre-gap message when the host has NOT
# written the prompt yet.
mutant drops-by-timing "LO15" "$S" \
    '    if last_text.strip() != target:{NL}        return humans' \
    '    if False:{NL}        return humans' \
    "the last message would be discarded whether or not it is the arriving one, so a message he sent thirty seconds ago would be thrown away and a nine-hour gap INVENTED under it -- a return report for a return that never happened."

# --- 5. THE OUTCOME COMES FROM GIT, AND FROM TWO FACTS -----------------
# The reflog names the merge; ancestry proves the merge survived. One without
# the other is the 19-jobs error with git's authority behind it.
mutant no-reflog "LO20" "$S" \
    '    out = git(repo, ["reflog", "show", branch, "--date=iso",' \
    '    out = None if True else git(repo, ["reflog", "show", branch, "--date=iso",' \
    "every job that landed AND was cleaned up would read NO TRACE, which is every successful job -- the report would be blind to success and loud about nothing."

mutant trusts-reflog-alone "LO23" "$S" \
    '            still = git_ok(repo, ["merge-base", "--is-ancestor", sha, info["branch"]])' \
    '            still = True' \
    "work that was merged and then reset away would be reported as landed, on the strength of a reflog entry naming a commit the branch no longer contains."

mutant sees-the-future "LO25" "$S" \
    '            if as_of is not None and when is not None and when > as_of:{NL}                continue' \
    '            if False:{NL}                continue' \
    "a replay would answer with today's knowledge about an instant that did not have it, so any evidence that this report would have said the right thing at the time proves nothing."

# --- 6. A CLAIM IS NEVER A VERDICT ----------------------------------------
# The exact trap of failure type 61: a ledger field read as an outcome.
mutant claim-becomes-verdict "LO24" "$S" \
    '        claim = (" [registry claims %s]" % work["claimed"]) if work.get("claimed") else ""' \
    '        claim = ""{NL}        if work.get("claimed"):{NL}            return "LANDED", work["claimed"]' \
    "the workspace registry's own word would become the answer, which is precisely the field that produced '19 jobs were never closed out' about 19 jobs that had all landed."

mutant no-trace-reads-as-not-landed "LO22" "$S" \
    '        "this is '"'"'not seen'"'"', NOT '"'"'not landed'"'"'" % name)' \
    '        "this did not land" % name)' \
    "a job in a repository nobody swept would be reported as UNLANDED WORK, and somebody would go looking for a branch that was never there."

# --- 7. THE REPORT ITSELF -------------------------------------------------
mutant no-dedup "LO32" "$S" \
    '        if key in seen:' \
    '        if False:' \
    "the same message repeated four times would fill the sitting and crowd out the earlier one carrying the number he is asking about -- measured: it pushed out '46% of tokens'."

mutant no-budget "LO34" "$S" \
    '    while budget and len(text) > budget:' \
    '    while False:' \
    "a long sitting would exceed the measured 8000-character channel cap and the host would drop the WHOLE object, so the report would be silent exactly when there is most to say."

# --- 8. THE CHANNEL -------------------------------------------------------
# systemMessage is measured to reach the PERSON and not the model. A report
# delivered there is how a staleness notice named a dead guard all day.
mutant wrong-channel "LO42" "$H" \
    '_say "$ANCHOR" "$REPORT"' \
    '_say "$REPORT" ""' \
    "the report would go to the operator and never to the model -- visible to a person, invisible to the thing that writes the answer, which is the defect this whole file exists downstream of."

# --- 9. THE HOOK'S OWN BEHAVIOR -------------------------------------------
mutant repeats-every-message "LO44" "$H" \
    'if [ "$PRIOR" = "$KEY" ]; then' \
    'if false; then' \
    "the full report would be re-emitted on every message of the gap, and a 6 KB block under every message is the noise that gets a channel muted."

mutant silent-standdown "LO47" "$H" \
    '    _say "WHERE-HE-LEFT-OFF — STOOD DOWN by CHECK_LEFT_OFF=0 in $CONFIG. $HOOK_TAG" \' \
    '    _silent' \
    "an opt-out nobody can see decays into a rumour: the report would be off and the session would look exactly like one with nothing to report."

mutant silent-unreadable "LO48" "$H" \
    'if [ -n "$TRANSCRIPT" ] && [ ! -f "$TRANSCRIPT" ]; then' \
    'if false; then' \
    "a broken install would look identical to a session with no gap in it -- the absence of a CHECK rendered as the absence of a FINDING."

# --- 10. THE MEASURED STDIN HAZARD ----------------------------------------
# engine-status.sh measured 92 seconds of hang from exactly this.
mutant reads-stdin-at-session-start "LO49" "$H" \
    'if [ "$REPORT_ONLY" != "1" ] && [ "$EVENT" = "UserPromptSubmit" ]; then' \
    'if [ "$REPORT_ONLY" != "1" ]; then' \
    "SessionStart would block on an inherited pipe nobody closes, which is a hung session start rather than a missing report."

# --- 11. SESSION START FINDS ITS OWN TRANSCRIPT ---------------------------
# SessionStart reads no payload by design, so discovery is the ONLY way it can
# find the conversation he left off in. Without it the morning case -- a new
# session opened after a night away -- is silent.
mutant no-transcript-discovery "LO50" "$H" \
    '        TRANSCRIPT="$(ls -t "$CANDIDATE_DIR"/*.jsonl 2>/dev/null | head -1 || true)"' \
    '        TRANSCRIPT=""' \
    "SessionStart could never find a transcript, so the report would be silent in exactly the case it was built for: a fresh session the morning after."

mutation_end
