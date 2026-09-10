#!/usr/bin/env bash
#
# scripts/lib/stopwatch.sh — a millisecond clock that works on the two shells
# this engine actually runs on, and that SAYS which one it got.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Every wall-clock number ever quoted about this engine's test suites was
# either hand-timed by an agent watching a terminal or read off a CI run log.
# The runner itself printed PASS and FAIL and nothing else. So the numbers that
# drove three plans and two adversarial reviews — "2977.9s", "the two that
# dominate it", "WTI1 alone is 599s" — all came from OUTSIDE the thing being
# measured. They went stale silently and were re-derived wrongly at least
# twice; the 2977.9s figure was dead by 2026-09-09 and nothing in the runner
# noticed, because nothing in the runner was looking.
#
# A suite that reports its own duration cannot go stale, because the number
# arrives with the run that produced it.
#
# ===========================================================================
# WHY IT IS NOT ONE LINE OF `date`
# ===========================================================================
# The obvious `date +%s%3N` is a GNU extension. On the macOS bash that is the
# operator's default shell, BSD `date` does not know `%N` and emits it
# LITERALLY — measured here rather than assumed:
#
#   /bin/bash 3.2.57 on darwin 24.6.0:   date +%s%3N   ->   17889976023N
#
# That is not an error and does not exit non-zero. It is a string that looks
# like a timestamp, parses as an integer under most arithmetic, and is wrong by
# a factor of ten. A duration computed from two of them is garbage that reads
# like data — the exact defect class this engine exists to refuse.
#
# `$EPOCHREALTIME` is the right answer and needs bash >= 5. The operator's
# machine ships bash 3.2.57 (2007, GPLv2 — Apple will not ship newer), while
# `ubuntu-latest` in CI ships bash 5.x. So BOTH paths are live, always, and
# neither may be the one that gets assumed:
#
#   EPOCHREALTIME unset on /bin/bash 3.2.57       -> must fall back
#   `wait -n` also absent there                   -> see mutation-pool.sh
#
# So the method is PROBED ONCE at init, by running the candidate and checking
# that what came back is all digits and plausibly a millisecond epoch. A
# candidate that prints `17889976023N` fails the digit check and is skipped
# rather than trusted. The chosen method lands in SW_METHOD and is PRINTED by
# consumers, so a reader of a timing table can tell a sub-millisecond clock
# from a one-second one instead of inferring precision from tidy output.
#
# THE LAST RESORT IS COARSE AND SAYS SO. `date +%s` exists everywhere and has
# one-second granularity. On a run whose fast suites are ~1s each that is a
# 100% error bar, so SW_METHOD is `date-s-COARSE` and consumers carry the word
# into their banner. A coarse number marked coarse is usable; a coarse number
# formatted to three decimals is a lie with a decimal point.
#
# Usage:
#   . "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
#   sw_init                                  # probes; sets SW_METHOD; never fails
#   t0="$(sw_now_ms)"
#   ...
#   sw_fmt "$(( $(sw_now_ms) - t0 ))"        # -> "4.1s" / "2m03.4s"

SW_METHOD="${SW_METHOD:-}"

# _sw_plausible_ms <string> — true when the argument is all digits and is
# thirteen of them. The width check is what rejects a SECOND-resolution epoch
# returned by mistake (1.7e9, ten digits), which would make every duration come
# out 1000x too small, and a microsecond epoch for the mirror-image reason.
# Both bugs are silent without it, and both produce plausible-looking tables.
_sw_plausible_ms() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -eq 13 ]
}

_sw_epochrealtime_ms() {
    # 1788997602.829123 -> 1788997602829. Integer part plus exactly three
    # fractional digits; a locale may use a comma, hence the two-character
    # class. Pure parameter expansion, so this costs no fork.
    local t="${EPOCHREALTIME:-}" int frac
    int="${t%%[.,]*}"
    frac="${t#*[.,]}"
    [ "$frac" = "$t" ] && frac=000
    frac="${frac}000"
    printf '%s%s' "$int" "$(printf '%s' "$frac" | cut -c1-3)"
}

sw_init() {
    [ -n "$SW_METHOD" ] && return 0
    local probe
    # 1. bash >= 5 builtin. No subprocess at all, so it is also the only method
    #    that does not add a fork to every measurement it takes.
    if [ -n "${EPOCHREALTIME:-}" ]; then
        probe="$(_sw_epochrealtime_ms)"
        if _sw_plausible_ms "$probe"; then SW_METHOD="epochrealtime"; return 0; fi
    fi
    # 2. GNU date. Skipped on BSD by the DIGIT CHECK, not by a `uname` test — a
    #    uname test is a guess about which `date` is on PATH, and this is an
    #    observation of what it actually returned.
    probe="$(date +%s%3N 2>/dev/null)"
    if _sw_plausible_ms "$probe"; then SW_METHOD="gnu-date"; return 0; fi
    # 3. perl. In the macOS base system, so this is the path the operator's
    #    own machine actually takes.
    if command -v perl >/dev/null 2>&1; then
        probe="$(perl -MTime::HiRes -e 'printf("%d", Time::HiRes::time()*1000)' 2>/dev/null)"
        if _sw_plausible_ms "$probe"; then SW_METHOD="perl"; return 0; fi
    fi
    # 4. python3. Already a hard requirement of every mutation harness, so not
    #    a new dependency — it is below perl only because it starts slower.
    if command -v python3 >/dev/null 2>&1; then
        probe="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null)"
        if _sw_plausible_ms "$probe"; then SW_METHOD="python3"; return 0; fi
    fi
    SW_METHOD="date-s-COARSE"
    return 0
}

sw_now_ms() {
    case "$SW_METHOD" in
        epochrealtime) _sw_epochrealtime_ms ;;
        gnu-date)      date +%s%3N ;;
        perl)          perl -MTime::HiRes -e 'printf("%d", Time::HiRes::time()*1000)' ;;
        python3)       python3 -c 'import time; print(int(time.time()*1000))' ;;
        date-s-COARSE) printf '%s000' "$(date +%s)" ;;
        *)             sw_init; sw_now_ms ;;
    esac
}

# sw_fmt <ms> — a duration a human reads at a glance. Sub-minute keeps one
# decimal, because the difference between 0.4s and 1.4s is the difference
# between a check and a pause; over a minute the decimal is noise and the
# minute/second split is what carries. A non-numeric argument prints `?` rather
# than 0.0s: a missing measurement must not read as an instant one.
sw_fmt() {
    local ms="${1:-}" s tenths m
    case "$ms" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
    s=$(( ms / 1000 ))
    tenths=$(( (ms % 1000) / 100 ))
    if [ "$s" -lt 60 ]; then
        printf '%s.%ss' "$s" "$tenths"
    else
        m=$(( s / 60 ))
        s=$(( s % 60 ))
        printf '%sm%02d.%ss' "$m" "$s" "$tenths"
    fi
}
