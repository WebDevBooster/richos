#!/usr/bin/env bash
#
# quota-watch.mutation.sh — PROVES THE 93% RULE'S SUITE CAN FAIL.
#
# Takes the SHIPPED scripts/lib/quota_watch.py, removes ONE property at a time
# in a throwaway copy of the engine, and asserts that (1) the suite fails,
# (2) the SPECIFIC named case fails, and (3) the mutation actually applied.
# The loop is scripts/lib/mutation-harness.sh; this file is the list of
# properties his rule rests on.
#
# Invoked by quota-watch.test.sh, so the runner that discovers *.test.sh runs
# it too. Run directly: scripts/quota-watch.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "quota-watch (the CEO's 93% rule)" "scripts/quota-watch.test.sh"
# The suite's cases share state and run in sequence, and a printed
# `FAIL  <case>` line always ends it red (check() counts it; the suite exits 1
# on any failure). So each mutant stops at its own FAIL line instead of running
# the rest: on 2026-09-25 the whole-suite form ran past ci-shard's 900 s unit
# deadline once the suite grew to cover get_usage and the 20-minute window.
mutation_focus stop-at-want

L="scripts/lib/quota_watch.py"

# 1. THE EDGE. "once it crosses the 93% threshold" — 93 itself is across.
mutant threshold-strict "Q02" "$L" \
    'if r["used"] >= threshold:' \
    'if r["used"] > threshold:' \
    "A reading of exactly 93% would read as below the threshold and nobody would be paused."

# 2. THE NUMBER IS HIS AND LIVES IN ONE PLACE. A built-in fallback is a second
#    place holding 93, which is how the number drifts.
mutant builtin-fallback "Q11" "$L" \
    'raw = (raw or "").strip()' \
    'raw = (raw or "93").strip()' \
    "An undeclared threshold would silently become 93 instead of being announced as missing."

mutant hardcoded-threshold "Q13" "$L" \
    'return v, ""' \
    'return 93.0, ""' \
    "The declared QUOTA_PAUSE_PERCENT would be read and ignored."

# 3. ABSENCE IS NEVER FINE (design notes R6).
mutant unknown-exits-zero "Q04" "$L" \
    'return {"below": 0, "at-or-above": 1, "near-reset": 3}.get(verdict, 2)' \
    'return {"below": 0, "at-or-above": 1, "near-reset": 3}.get(verdict, 0)' \
    "A missing or unreadable payload would exit exactly like a healthy reading below the threshold."

# Targets Q08, the direct case. R01 no longer depends on it: since the fallback
# is refreshed before it turns one poll old (W12), R01's lead is woken by
# QUOTA-REFRESH before the reading can go stale.
mutant stale-read-as-fresh "Q08" "$L" \
    'if r["age"] is not None and r["age"] > stale_after:' \
    'if False:' \
    "A reading an hour old would be reported as a fresh 'below the threshold': the 2026-09-25 failure."

mutant ended-window-read-as-current "Q10" "$L" \
    '    if r["ended"]:{NL}        return "unknown"' \
    '    if False:{NL}        return "unknown"' \
    "A reading of a window that no longer exists would be trusted."

mutant stale-bound-three-polls "Q16" "$L" \
    'a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", a.poll)' \
    'a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", 3 * a.poll)' \
    "A reading two polls old would pass as current, which is how the 93% crossing went unseen."

mutant stale-wakes-nobody "W05" "$L" \
    'stale = r["state"] == "ok" and not r["ended"]' \
    'stale = False' \
    "A stale reading would wait out a further poll on the watcher's own clock before telling the lead to refresh."

# 4. HIS "every 5 minutes".
mutant poll-not-five-minutes "W09" "$L" \
    'POLL_SECONDS = 300' \
    'POLL_SECONDS = 30' \
    "The watcher would poll ten times as often as he said."

# 5. THE PAUSE IS A REAL PAUSE. Without the pause-until: line the registry
#    records the agent's own end of run as FINISHED, and the wake at the reset
#    is refused: 2026-09-18, exactly.
mutant pause-message-without-pause-until "E02" "$L" \
    'return pause_protocol.render("quota", hhmm(r["resets_at"]))' \
    'return pause_protocol.render("quota", hhmm(r["resets_at"])).split("\npause-until:", 1)[0]' \
    "The pause message would read correctly and record nothing, and every paused agent would be finished at its first SubagentStop."

mutant resume-message-re-pauses "E09" "$L" \
    'Continue exactly where you stopped."' \
    'Continue exactly where you stopped.\npause-until: later"' \
    "The resume message would re-pause the agent it was meant to wake."

# 6. WAKE THE LEAD ONLY WHEN THERE IS SOMETHING TO DO.
mutant fires-with-nothing-working "W03" "$L" \
    '                if w["known"] and not w["working"]:{NL}                    print("  at the threshold with nothing working' \
    '                if False:{NL}                    print("  at the threshold with nothing working' \
    "After the lead paused everybody, restarting the watcher would wake it again at once, forever, until the reset."

mutant blind-wake-with-nothing-working "W06" "$L" \
    '                    if w["known"] and not w["working"]:{NL}                        print("  the reading is unknown but nothing' \
    '                    if False:{NL}                        print("  the reading is unknown but nothing' \
    "A quiet session would be woken for a stale reading when there is no spend it could hide."

# 7. HIS 2026-09-25 UPDATE (ruling §87). At or above the threshold, no pause
#    when the reset is LESS than 20 minutes away; exactly 20 still pauses; a
#    hold in place releases inside that window. And "Keep it consistent at 5
#    minutes": no usage tier.
mutant near-reset-ignored "Q17" "$L" \
    '    if verdict == "at-or-above" and in_last_twenty(r["resets_at"], now):' \
    '    if False:' \
    "Agents would be paused with 19 minutes left, for a hold that ends almost as soon as it starts."

mutant twenty-minutes-inclusive "Q18" "$L" \
    'return resets_at is not None and 0 < resets_at - now < RESET_EXEMPTION_SECONDS' \
    'return resets_at is not None and 0 < resets_at - now <= RESET_EXEMPTION_SECONDS' \
    "Exactly 20 minutes would skip the pause; his words keep it."

mutant exemption-ten-minutes "Q17" "$L" \
    'RESET_EXEMPTION_SECONDS = 20 * 60' \
    'RESET_EXEMPTION_SECONDS = 10 * 60' \
    "The window would shrink to 10 minutes and 19 minutes left would pause."

mutant exemption-thirty-minutes "Q19" "$L" \
    'RESET_EXEMPTION_SECONDS = 20 * 60' \
    'RESET_EXEMPTION_SECONDS = 30 * 60' \
    "The window would grow to 30 minutes and 21 minutes left would not pause."

mutant near-reset-exits-as-pause "Q17" "$L" \
    'return {"below": 0, "at-or-above": 1, "near-reset": 3}.get(verdict, 2)' \
    'return {"below": 0, "at-or-above": 1, "near-reset": 1}.get(verdict, 2)' \
    "--once would tell a caller to pause inside the last 20 minutes."

mutant watch-ignores-exception "W10" "$L" \
    '        verdict, why = rule_verdict(r, a.threshold, a.stale, now){NL}        print("%s  %s"' \
    '        verdict, why = classify(r, a.threshold, a.stale){NL}        print("%s  %s"' \
    "--once would say no pause while the watcher woke the lead to pause anyway."

mutant release-never-fires "E05" "$L" \
    '            if not w["known"] or w["quota_paused"]:{NL}                _emit_release' \
    '            if False:{NL}                _emit_release' \
    "A hold would last to the reset instead of releasing inside the last 20 minutes."

mutant release-with-nobody-held "W03" "$L" \
    '            if not w["known"] or w["quota_paused"]:{NL}                _emit_release' \
    '            if True:{NL}                _emit_release' \
    "The lead would be woken to release a hold nobody is in."

mutant release-a-poll-late "E05" "$L" \
    '            if to_release > 0:' \
    '            if False:' \
    "The release would come up to one 5-minute poll after the 20-minute mark."

mutant release-message-re-pauses "E06" "$L" \
    '"hold is released (%s). Continue exactly where you stopped."' \
    '"hold is released (%s). Continue exactly where you stopped.\npause-until: later"' \
    "The release message would re-pause the agent it was meant to wake."

mutant stale-bound-usage-tier "Q23" "$L" \
    'if r["age"] is not None and r["age"] > stale_after:' \
    'if r["age"] is not None and r["age"] > (stale_after if r["used"] >= 70 else 6 * stale_after):' \
    "Below 70% a reading 30 minutes old would pass as current: the schedule he dropped."

mutant status-omits-update "Q24" "$L" \
    '    print("  update    : %s" % RULE_UPDATE)' \
    '    pass' \
    "--status would state the rule without his 2026-09-25 update."

# 8. THE READING COMES FROM CLAUDE CODE ITSELF, AT EVERY POLL (2026-09-25).
mutant get-usage-never-used "G01" "$L" \
    '    g = read_get_usage(now){NL}    if g["state"] == "ok":' \
    '    g = {"state": "failed", "why": "mutated"}{NL}    if g["state"] == "ok":' \
    "The watcher would read only the status-line file, which an idle lead leaves ten minutes old."

mutant get-usage-process-left-running "G02" "$L" \
    '                os.killpg(proc.pid, sig)' \
    '                pass' \
    "Every poll would leave a claude process behind."

mutant get-usage-unbounded "G05" "$L" \
    '        until = time.time() + deadline_s' \
    '        until = time.time() + 3600' \
    "A claude that never answers would hang the watcher for an hour instead of falling back."

mutant get-usage-no-fallback "G03" "$L" \
    '    f = read_reading(a.payload, now){NL}    f["source"] = "the status line"' \
    '    f = dict(g){NL}    f["source"] = "the status line"' \
    "A failed get_usage would leave the watcher blind although the status-line file is fresh."

mutant watch-reads-file-only "R04" "$L" \
    '        r = read_source(a, now){NL}        w = workers(a.engine_root)' \
    '        r = read_reading(a.payload, now){NL}        w = workers(a.engine_root)' \
    "Every poll after the first would read the status-line file: the 07:57Z/08:07Z miss again."

# 9. THE FALLBACK IS REFRESHED BEFORE IT TURNS ONE POLL OLD (the pause fired at
#    95%, not 93%, on 2026-09-25: a 300 s poll first saw the file stale ~600 s on).
mutant refresh-never "W12" "$L" \
    '                if r["age"] >= at:{NL}                    w = workers' \
    '                if False:{NL}                    w = workers' \
    "An idle lead would be woken only once the reading was already a poll old: every 10 minutes."

mutant refresh-at-the-bound "W12" "$L" \
    '    return stale_after - min(REFRESH_AHEAD_SECONDS, stale_after // 10)' \
    '    return stale_after' \
    "The lead would be woken as the reading turns 300 s old, so its reply lands after it."

mutant refresh-not-scheduled "W12" "$L" \
    '            sleep_for = max(1, min(sleep_for, int(math.ceil(refresh_in))))' \
    '            pass' \
    "The poll would come a full interval later, past the refresh point, and see the reading stale."

mutant refresh-with-nothing-working "W13" "$L" \
    '                    if w["known"] and not w["working"]:{NL}                        print("  the reading is about to turn' \
    '                    if False:{NL}                        print("  the reading is about to turn' \
    "A quiet session would be woken every 5 minutes to refresh a number that nothing is spending."

mutation_end
