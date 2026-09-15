#!/usr/bin/env bash
#
# scripts/lib/entrypoints.sh — WHICH COMMAND IS THE CURRENT ONE IS DATA, READ
#                              HERE, AND NOWHERE ELSE IS ALLOWED TO ASSUME IT.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-13 `scripts/spawn.sh` landed at 23:24: one command that resolves
# the repository, assembles the payload, evaluates every PreToolUse[Agent]
# guard from every surface, and creates the workspace only once nothing can
# refuse it. The next session did not use it. It used the four-step path it
# replaced, was refused twice along the way, and took 130 seconds where the new
# command takes 1.3 — because `scripts/hooks/engine-status.sh`, the SessionStart
# announcement every session boots with, still said "prepare its task-specific
# JSON with prepare-agent-spawn.py" and had never heard of spawn.sh.
#
# Nothing was broken. Both paths worked. Nothing went red, no test failed, and
# the new path simply went unused — because the mechanism was replaced and the
# instruction that points at it was not. The founder found it by paying the old
# cost and recognizing the number, which is the most expensive way a project can
# learn anything. Recorded as failure type V in
# richos-hq/docs/verification/lifecycle-failure-record-2026-09-13.md.
#
# The general rule it is an instance of: WHEN A MECHANISM IS REPLACED, THE
# CHANGE IS NOT LANDED UNTIL THE THING THAT TELLS PEOPLE WHAT TO DO NAMES THE
# NEW ONE. Shipping the capability is half; redirecting the instruction is the
# other half, and it is the half that decides whether anybody uses it.
#
# So supersession is DATA: one declaration, orchestration.config ENTRYPOINTS,
# beside the other declarations an adopter edits. Every consumer — the currency
# lint, the integrity probe's Layer EP — reads THAT value through the functions
# below. No consumer decides for itself which command is current, and no
# consumer infers it from a file's age, its name, or which one it saw last.
#
# This is the MODEL_TIERS shape, deliberately and without invention: a fact
# nobody is permitted to guess at, declared once, quoted where it is relied on,
# and a probe layer that refuses any drift between the prose and the
# declaration.
#
# ===========================================================================
# WHAT THIS GOVERNS, AND WHAT IT DELIBERATELY DOES NOT
# ===========================================================================
# It governs WHAT WE TELL PEOPLE. It never governs what is ALLOWED: a superseded
# entrypoint keeps working, keeps its tests, and may be called by the canonical
# one (spawn.sh calls both of the commands it supersedes). Making the old path
# fail would break every caller for the sake of a documentation problem, and the
# documentation problem is the whole problem.
#
# ===========================================================================
# THE GRAMMAR
# ===========================================================================
#     ENTRYPOINTS="<task> | <canonical> | <superseded>...; <task> | ... "
#
#   - RECORDS are separated by `;`
#   - FIELDS inside a record are separated by `|`, and there are exactly three:
#       1. TASK       free text naming the job a person is trying to do
#       2. CANONICAL  exactly one repo-relative path: the command to use today
#       3. SUPERSEDED zero or more whitespace-separated repo-relative paths
#   - a path may not contain `|`, `;` or whitespace
#   - a path may appear as CANONICAL in at most one record
#   - a path may never be both CANONICAL and SUPERSEDED (that is a cycle, and a
#     cycle here means the declaration is telling people to use the thing it is
#     telling them not to use)
#   - an empty SUPERSEDED field is legal and useful: it declares the canonical
#     command for a task that never had a predecessor, so a future predecessor
#     has somewhere to be written down
#
# MATCHING IS BY BASENAME. An instruction in a governed repository names an
# engine script by whatever path reaches it from there — `scripts/spawn.sh`,
# `$ENGINE_ROOT/scripts/spawn.sh`, `~/.claude/richos-engine/scripts/spawn.sh` —
# and all three are the same instruction. The declaration stores full
# repo-relative paths so existence can be checked; consumers match on the
# basename so the check survives every spelling of the path. The cost is that
# two different files with the same basename would be conflated; declare
# distinctive names, and the lint says which record it matched.
#
# ===========================================================================
# CONTRACT — every function always returns 0 and speaks on stdout only
# ===========================================================================
# Consumers run under `set -e`; a library call returning non-zero inside a
# command substitution would kill the caller mid-decision, which is a crash
# dressed as a verdict. So: empty output means "no", "unknown" or "no problem"
# depending on the function, and the caller tests the string.
#
#   entrypoints_problem <spec>
#       Prints WHY the spec is malformed, or nothing when it is well-formed.
#   entrypoints_records <spec>
#       One record per line, tab-separated: task<TAB>canonical<TAB>superseded...
#   entrypoints_canonical_names <spec>
#       Every canonical BASENAME, space-separated, in declared order.
#   entrypoints_superseded_names <spec>
#       Every superseded BASENAME, space-separated, in declared order.
#   entrypoint_record_for_superseded <basename> <spec>
#       For a superseded basename, prints
#       "canonical-basename<TAB>canonical-path<TAB>task".
#       Prints nothing when the basename is not superseded by anything.
#
# Plain bash 3.2 (macOS's /bin/bash): no associative arrays, no ${var,,}.

# _ep_basename <path> — internal, and deliberately not `basename(1)`: this is
# called once per declared path per scanned line, and a fork there is the
# difference between a lint that runs at every land and one that gets skipped.
_ep_basename() {
    printf '%s' "${1##*/}"
}

# _ep_trim <string> — internal. Strips leading/trailing whitespace.
_ep_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

entrypoints_problem() {
    local spec="$1" rec rest field_count task canon sup tok
    local seen_canon="" seen_sup="" nrec=0

    if [ -z "$(printf '%s' "$spec" | tr -d '[:space:]')" ]; then
        printf 'ENTRYPOINTS is blank'
        return 0
    fi

    rest="$spec"
    while [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ]; do
        case "$rest" in
            *";"*) rec="${rest%%;*}"; rest="${rest#*;}" ;;
            *)     rec="$rest";       rest="" ;;
        esac
        [ -n "$(printf '%s' "$rec" | tr -d '[:space:]')" ] || continue
        nrec=$((nrec + 1))

        field_count="$(printf '%s' "$rec" | awk -F'|' '{print NF}')"
        if [ "$field_count" -ne 3 ]; then
            printf "record %s has %s field(s) separated by '|', expected exactly 3 (task | canonical | superseded...): '%s'" \
                "$nrec" "$field_count" "$(_ep_trim "$rec")"
            return 0
        fi

        task="$(_ep_trim "$(printf '%s' "$rec" | awk -F'|' '{print $1}')")"
        canon="$(_ep_trim "$(printf '%s' "$rec" | awk -F'|' '{print $2}')")"
        sup="$(printf '%s' "$rec" | awk -F'|' '{print $3}')"

        if [ -z "$task" ]; then
            printf "record %s names no task — the first field says what a person is trying to DO, and it is what the refusal quotes back at them" "$nrec"
            return 0
        fi
        if [ -z "$canon" ]; then
            printf "record %s ('%s') declares no canonical entrypoint — a record that supersedes without naming a replacement tells a reader to stop and nothing else" "$nrec" "$task"
            return 0
        fi
        case "$canon" in
            *[[:space:]]*)
                printf "record %s ('%s') names %s canonical entrypoints; exactly one command is current for a task, or the declaration is a menu" \
                    "$nrec" "$task" "$(printf '%s' "$canon" | wc -w | tr -d ' ')"
                return 0
                ;;
        esac

        case " $seen_canon " in
            *" $canon "*)
                printf "'%s' is declared canonical in two records — one command may be current for many tasks, but it is declared once" "$canon"
                return 0
                ;;
        esac
        seen_canon="$seen_canon $canon"

        for tok in $sup; do
            if [ "$tok" = "$canon" ]; then
                printf "record %s ('%s') declares '%s' as both the canonical entrypoint and a superseded one — that is a cycle, and it tells a reader to use the thing it tells them not to use" \
                    "$nrec" "$task" "$tok"
                return 0
            fi
            case " $seen_sup " in
                *" $tok "*)
                    printf "'%s' is declared superseded in two records — a path is replaced once, by one thing, or a reader cannot be told where to go" "$tok"
                    return 0
                    ;;
            esac
            seen_sup="$seen_sup $tok"
        done
    done

    # A canonical path in one record may not be a superseded path in another:
    # the reader would be sent to a command the declaration has already retired.
    for tok in $seen_canon; do
        case " $seen_sup " in
            *" $tok "*)
                printf "'%s' is canonical in one record and superseded in another — the declaration would send a reader to a command it has already retired" "$tok"
                return 0
                ;;
        esac
    done

    if [ "$nrec" -eq 0 ]; then
        printf 'ENTRYPOINTS declares no records'
        return 0
    fi

    printf ''
    return 0
}

entrypoints_records() {
    local spec="$1" rest rec task canon sup
    [ -z "$(entrypoints_problem "$spec")" ] || { printf ''; return 0; }
    rest="$spec"
    while [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ]; do
        case "$rest" in
            *";"*) rec="${rest%%;*}"; rest="${rest#*;}" ;;
            *)     rec="$rest";       rest="" ;;
        esac
        [ -n "$(printf '%s' "$rec" | tr -d '[:space:]')" ] || continue
        task="$(_ep_trim "$(printf '%s' "$rec" | awk -F'|' '{print $1}')")"
        canon="$(_ep_trim "$(printf '%s' "$rec" | awk -F'|' '{print $2}')")"
        sup="$(_ep_trim "$(printf '%s' "$rec" | awk -F'|' '{print $3}')" | tr '\n' ' ')"
        printf '%s\t%s\t%s\n' "$task" "$canon" "$sup"
    done
    return 0
}

entrypoints_canonical_names() {
    local spec="$1" out="" _task canon _sup
    while IFS="$(printf '\t')" read -r _task canon _sup; do
        [ -n "$canon" ] || continue
        out="${out:+$out }$(_ep_basename "$canon")"
    done <<EP_CN_EOF
$(entrypoints_records "$spec")
EP_CN_EOF
    printf '%s' "$out"
    return 0
}

entrypoints_superseded_names() {
    local spec="$1" out="" _task _canon sup tok
    while IFS="$(printf '\t')" read -r _task _canon sup; do
        for tok in $sup; do
            out="${out:+$out }$(_ep_basename "$tok")"
        done
    done <<EP_SN_EOF
$(entrypoints_records "$spec")
EP_SN_EOF
    printf '%s' "$out"
    return 0
}

entrypoint_record_for_superseded() {
    local want="$1" spec="$2" task canon sup tok
    [ -n "$want" ] || { printf ''; return 0; }
    while IFS="$(printf '\t')" read -r task canon sup; do
        for tok in $sup; do
            if [ "$(_ep_basename "$tok")" = "$want" ]; then
                printf '%s\t%s\t%s' "$(_ep_basename "$canon")" "$canon" "$task"
                return 0
            fi
        done
    done <<EP_RS_EOF
$(entrypoints_records "$spec")
EP_RS_EOF
    printf ''
    return 0
}
