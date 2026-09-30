#!/usr/bin/env bash
# mutant-suite-run.sh — run the suite under test for ONE mutant, and stop it the
# moment the mutant's named case has failed.
#
# WHO USES IT. The mutation harnesses that keep their own mutant loop instead of
# the shared one in mutation-harness.sh (the dialect, resume-isolation, host
# display/power, inflight-notify, interactive-prompt, public-record-repo,
# reference-ledger and phone-surface harnesses). The shared loop already stops a
# mutant's run at its named line when a harness declares `mutation_focus
# stop-at-want`; these did not, so every one of their mutants ran its WHOLE suite
# (hunt 2026-09-29 part 3, finding 9) although the verdict is settled the
# instant the `FAIL  <want>` line is written. The mechanism is the shared one,
# unchanged: scripts/lib/stop-at-line.py.
#
# THE CLAIM A CALLER MAKES by using this: in its suite, a printed `FAIL  <case>`
# line always ends the run red. If the line never appears, the run finishes and
# is judged exactly as it was before this helper existed.
#
#   mutant_suite_run <out-file> <want> <command...>
#
# sets MUTANT_RC (the suite's exit status, or 0 when it was stopped at the line)
# and MUTANT_STOPPED (1 when it was stopped at the line, else 0). A caller that
# sees MUTANT_STOPPED=1 has its verdict: the named case went red.
# RICHOS_MUTATION_FOCUS=off runs the whole suite instead, as the shared harness
# does, for a before/after measurement on one tree.

_MSR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mutant_suite_run() {
    local out="$1" want="$2"
    shift 2
    MUTANT_STOPPED=0
    MUTANT_RC=0
    if [ "${RICHOS_MUTATION_FOCUS:-}" = off ]; then
        "$@" >"$out" 2>&1
        MUTANT_RC=$?
        return 0
    fi
    local marker="$out.stopped"
    rm -f "$marker"
    python3 "$_MSR_DIR/stop-at-line.py" --out "$out" --line "FAIL  $want" --marker "$marker" -- "$@"
    MUTANT_RC=$?
    if [ "$MUTANT_RC" -eq 0 ] && [ -f "$marker" ]; then
        MUTANT_STOPPED=1
    fi
    return 0
}
