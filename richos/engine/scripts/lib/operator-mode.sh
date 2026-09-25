#!/usr/bin/env bash
# operator-mode.sh: is the operator switch on for this entity? Sourced, never run.
#
#   operator_mode_on <entity root>     0 = on, 1 = off, absent or not ours
#
# The switch lives in the entity repository's own `reference-transaction`
# launcher (OPERATOR_FENCES_STATE, Frank G12), the file the Git fence itself
# reads. This reader uses bash builtins only, so a hook whose switch is off
# starts no interpreter and no process at all: with the switch off, the
# operator-lead hooks (the claim, shared writes, live names) cost his terminal
# one small file read per call and change nothing it does.
#
# It reads <root>/.git/hooks/reference-transaction, which is where
# `operator-fences.sh install` writes the launcher of a main checkout (the
# common directory's hooks). A root whose .git is not a directory has no
# launcher of ours there and reads as off; the Python side
# (operator_leads.operator_on) asks Git and is the authority whenever this says on.

operator_mode_on() {
    local root="${1:-}" file line marker=0 on=1
    [ -n "$root" ] || return 1
    file="$root/.git/hooks/reference-transaction"
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '# richos-operator-fence-launcher') marker=1 ;;
            'OPERATOR_FENCES_STATE="on"') on=0 ;;
        esac
    done < "$file"
    [ "$marker" = 1 ] || return 1
    return "$on"
}
