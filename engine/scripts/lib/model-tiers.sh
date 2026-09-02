#!/usr/bin/env bash
#
# scripts/lib/model-tiers.sh — THE MODEL CAPABILITY ORDER IS DATA, READ HERE,
#                              AND NOWHERE ELSE IS ALLOWED TO GUESS AT IT.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-02 the orchestrator decided, out of nothing, that one model alias
# was less capable than another, killed a correctly-configured teammate on
# that belief, told the CEO he was correcting an error that did not exist, and
# commissioned a guard whose fixtures would have refused the correct spawn
# shape permanently. The doctrine had said "don't downgrade" for weeks and had
# never once said which direction down was. A rule left as prose was broken;
# a guard built on the same prose would have made the error permanent and
# given it authority.
#
# So the ordering is DATA: one declaration, orchestration.config MODEL_TIERS,
# beside ALLOWED_MODELS which already names the same aliases. Every consumer
# — the spawn guard's clause 6, the integrity probe's Layer MT, the doctrine
# file's own quotation of the order — reads THAT value through the functions
# below. No consumer infers capability from an alias's name, its length, its
# novelty, or the order it happens to appear in ALLOWED_MODELS.
#
# ===========================================================================
# THE GRAMMAR
# ===========================================================================
#     MODEL_TIERS="fable opus > sonnet > haiku"
#
#   - tiers are separated by `>`; the LEFTMOST tier is the most capable
#   - aliases inside one tier are separated by whitespace and are EQUAL —
#     moving between them in either direction is neither an upgrade nor a
#     downgrade, and needs no justification
#   - rank 1 is the highest tier; a larger rank is a LOWER tier
#   - aliases are lowercase alphanumeric, declared exactly once
#   - the set of aliases MUST equal ALLOWED_MODELS (the probe refuses a
#     mismatch; the guard fails OPEN on one, with a notice, because an alias
#     the declaration cannot rank is unknowable rather than forbidden)
#
# WHY TIERS AND NOT A TOTAL ORDER: because tiers are the honest shape. Two
# frontier models are not ranked against each other by anyone who has
# measured it, and an ordering that pretends otherwise is the same invented
# belief this file exists to end, with a `>` instead of a hunch.
#
# ===========================================================================
# CONTRACT — every function always returns 0 and speaks on stdout only
# ===========================================================================
# The spawn guard runs under `set -e`; a library call that returns non-zero
# inside a command substitution would kill the guard mid-decision, which is a
# crash dressed as a verdict. So: empty output means "no", "unknown" or "no
# problem" depending on the function, and the caller tests the string.
#
#   model_tiers_problem <spec>
#       Prints WHY the spec is malformed, or nothing when it is well-formed.
#   model_tier_rank <alias> <spec>
#       Prints the alias's rank (1 = highest tier), or nothing when the spec
#       is malformed or does not declare the alias.
#   model_tiers_aliases <spec>
#       Prints every declared alias, space-separated, in declared order.
#   model_tiers_set_problem <spec> <allowed-models>
#       Prints WHY the two alias sets differ, or nothing when they are equal.
#
# Plain bash 3.2 (macOS's /bin/bash): no associative arrays, no ${var,,}.

# _mt_split_next <rest-var-name> — internal. Pops the next tier off the
# named variable into MT_PART, sets MT_MORE=1 when another tier follows.
_mt_split_next() {
    local _v="$1" _rest
    eval "_rest=\"\$$_v\""
    case "$_rest" in
        *">"*)
            MT_PART="${_rest%%>*}"
            _rest="${_rest#*>}"
            MT_MORE=1
            ;;
        *)
            MT_PART="$_rest"
            _rest=""
            MT_MORE=0
            ;;
    esac
    eval "$_v=\"\$_rest\""
}

model_tiers_problem() {
    local spec="$1" rest="$1" tok seen="" ntiers=0 n
    if [ -z "$(printf '%s' "$spec" | tr -d '[:space:]')" ]; then
        printf 'MODEL_TIERS is blank'
        return 0
    fi
    while :; do
        _mt_split_next rest
        ntiers=$((ntiers + 1))
        n=0
        for tok in $MT_PART; do
            case "$tok" in
                *[!a-z0-9]*)
                    printf "alias '%s' is not lowercase alphanumeric" "$tok"
                    return 0
                    ;;
            esac
            case " $seen " in
                *" $tok "*)
                    printf "alias '%s' is declared twice" "$tok"
                    return 0
                    ;;
            esac
            seen="$seen $tok"
            n=$((n + 1))
        done
        if [ "$n" -eq 0 ]; then
            printf "tier %s is empty (a '>' with nothing on one side of it)" "$ntiers"
            return 0
        fi
        [ "$MT_MORE" -eq 1 ] || break
    done
    printf ''
    return 0
}

model_tier_rank() {
    local alias="$1" spec="$2" rest="$2" tok rank=0
    [ -n "$alias" ] || { printf ''; return 0; }
    [ -z "$(model_tiers_problem "$spec")" ] || { printf ''; return 0; }
    while :; do
        _mt_split_next rest
        rank=$((rank + 1))
        for tok in $MT_PART; do
            if [ "$tok" = "$alias" ]; then
                printf '%s' "$rank"
                return 0
            fi
        done
        [ "$MT_MORE" -eq 1 ] || break
    done
    printf ''
    return 0
}

model_tiers_aliases() {
    local spec="$1" out="" tok
    [ -z "$(model_tiers_problem "$spec")" ] || { printf ''; return 0; }
    for tok in $(printf '%s' "$spec" | tr '>' ' '); do
        out="${out:+$out }$tok"
    done
    printf '%s' "$out"
    return 0
}

model_tiers_set_problem() {
    local spec="$1" allowed="$2" problem tiers tok missing="" extra=""
    problem="$(model_tiers_problem "$spec")"
    if [ -n "$problem" ]; then
        printf '%s' "$problem"
        return 0
    fi
    tiers="$(model_tiers_aliases "$spec")"
    for tok in $allowed; do
        case " $tiers " in
            *" $tok "*) ;;
            *) missing="${missing:+$missing, }$tok" ;;
        esac
    done
    for tok in $tiers; do
        case " $allowed " in
            *" $tok "*) ;;
            *) extra="${extra:+$extra, }$tok" ;;
        esac
    done
    if [ -n "$missing" ]; then
        printf 'ALLOWED_MODELS names %s but MODEL_TIERS ranks it nowhere' "$missing"
    fi
    if [ -n "$extra" ]; then
        [ -z "$missing" ] || printf '; '
        printf 'MODEL_TIERS ranks %s but ALLOWED_MODELS does not allow it' "$extra"
    fi
    return 0
}
