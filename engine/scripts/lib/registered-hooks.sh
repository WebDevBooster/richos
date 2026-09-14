#!/usr/bin/env bash
#
# scripts/lib/registered-hooks.sh — THE GUARD INVENTORY, DERIVED FROM THE
#                                    REGISTRATION SURFACE.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# "How many guards are there?" was answered, in two different places, by a list
# a human had typed. It drifted twice in two days:
#
#   13/13  guard-workflow-ban.sh added, list not updated. Observed live in a
#          real ~/ab/prospects session. Fixed at d55f54b by making the banner's
#          numerator and denominator walk the SAME typed list — which removed
#          the arithmetic error and left the typing in place.
#   14/14  79d6958 / 084eed3 wired guard-worktree-removal.sh. The typed list was
#          not touched. Within hours of the previous fix, femcboost sessions at
#          engine 1.0.0 announced "14/14 guards" — a full, reassuring fraction
#          over a stale inventory — with 15 guards plus the announcer loaded.
#
# Both times the guard was present, executable, hash-matched and firing. The
# defect was never in the guard; it was that the count of guards was a SECOND,
# INDEPENDENT record of the same fact, maintained by memory. A list a human must
# remember to update is not a mitigation for drift, it is a source of it.
#
# So the count is no longer recorded anywhere. It is DERIVED, here, from
# hooks/hooks.json — the file that actually determines what the host loads.
# Nothing else can be the source: a script present on disk but never wired
# enforces nothing (and must not inflate a count), and a script wired but absent
# from disk enforces nothing either (and must show as a SHORTFALL, which is the
# whole signal the banner's fraction carries). Those are two different questions
# and this library answers only the first one — "what does the host load?".
# Callers answer the second themselves, against the disk.
#
# ===========================================================================
# WHY A SHARED LIBRARY RATHER THAN A SECOND PARSER
# ===========================================================================
# engine-status.sh needs this inventory to size its fraction, and
# contract-integrity-probe.sh needs it to check that the banner and the probe
# are looking at the same set. Two hand-rolled parsers of the same file is how
# the original defect was born, one level down. There is one parser, both use
# it, and the probe (BR2) additionally compares this library's answer against
# its OWN independent python3 parse of hooks.json — so a bug in here cannot
# quietly shrink the inventory for both readers at once.
#
# ===========================================================================
# NO SILENT DEGRADATION
# ===========================================================================
# The engine's governing rule is fail LOUD, never skip. A parser that returned
# "0 guards" or a partial list when it could not read the registration surface
# would hand its caller a number that looks like an answer, which is the exact
# failure this file exists to remove. So the contract is: either a complete
# inventory and rc 0, or NOTHING on stdout and a non-zero rc the caller must
# report rather than paper over.

# registered_hook_scripts <path-to-hooks.json> [event]
#
# Prints one hook-script BASENAME per line ("guard-bash-main-writes.sh"),
# sorted and de-duplicated — every script the given hook table registers, on
# any event, under any matcher. Inline hooks that run no script (the knowledge-
# verification echo) contribute nothing, correctly: they are not scripts and
# cannot be present-or-missing on disk.
#
# With [event] ("Stop", "PreToolUse", …) the answer is narrowed to the scripts
# that table registers ON THAT EVENT. The narrowed form exists so that "which
# hooks run at turn-end?" is DERIVED like every other inventory here rather than
# typed: stop-hook-visibility.test.sh asks this question, and a typed answer of
# 14 where the registration held 15 is the exact defect the whole file was
# written about. A Stop hook added tomorrow is in the answer with no edit here
# and no edit there.
#
# The event filter REQUIRES python3 and says so with rc 3 rather than degrading.
# The text-scan fallback below cannot see event boundaries at all, so filtering
# through it would silently return the WHOLE inventory under an event's name —
# an over-count wearing a precise label, which is worse than the honest refusal.
#
# Exit codes — a caller MUST distinguish these from an empty inventory:
#   0  complete inventory printed
#   1  no such file (the path is wrong, or the engine install is incomplete)
#   2  present but unparseable, or parseable and registering no script at all
#      (with [event]: no script registered on that event)
#   3  [event] was requested and python3 is unavailable — cannot filter
registered_hook_scripts() {
    local f="${1:-}"
    local event="${2:-}"
    local out=""
    local rc=0

    [ -n "$f" ] && [ -f "$f" ] || return 1

    if [ -n "$event" ]; then
        command -v python3 >/dev/null 2>&1 || return 3
        out="$(python3 -c '
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
want = sys.argv[2]
found = set()
hooks = doc.get("hooks", {})
if isinstance(hooks, dict):
    for name, entries in hooks.items():
        if name != want or not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            for h in entry.get("hooks", []) or []:
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                if not isinstance(cmd, str):
                    continue
                for m in re.findall(r"scripts/hooks/([A-Za-z0-9._+-]+\.sh)", cmd):
                    found.add(m)
for name in sorted(found):
    print(name)
' "$f" "$event" 2>/dev/null)"
        rc=$?
        [ "$rc" -eq 0 ] || return 2
        [ -n "$out" ] || return 2
        printf '%s\n' "$out"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        # The authoritative path: a real JSON parse. If the file is present but
        # malformed, python exits non-zero and we STOP — we do not fall through
        # to the text scan. Malformed JSON means the host loads no hooks from
        # this file either, so a count scraped out of the wreckage would be a
        # number describing enforcement that is not there.
        out="$(python3 -c '
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
found = set()
hooks = doc.get("hooks", {})
if isinstance(hooks, dict):
    for entries in hooks.values():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            for h in entry.get("hooks", []) or []:
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                if not isinstance(cmd, str):
                    continue
                for m in re.findall(r"scripts/hooks/([A-Za-z0-9._+-]+\.sh)", cmd):
                    found.add(m)
for name in sorted(found):
    print(name)
' "$f" 2>/dev/null)"
        rc=$?
        [ "$rc" -eq 0 ] || return 2
    else
        # No python3. engine-status.sh already carries a python3-absent path for
        # its JSON output, so "no interpreter" is a supported environment and
        # this cannot be left to fail open. A text scan of the same file is a
        # weaker parser — it would also match a path mentioned in a description
        # string — but it is weaker in the direction of OVER-counting, never
        # under-counting, and the probe's BR2 cross-check catches a divergence
        # between this answer and its own parse.
        out="$(grep -o 'scripts/hooks/[A-Za-z0-9._+-]*\.sh' "$f" 2>/dev/null \
               | sed 's|.*/||' | LC_ALL=C sort -u)"
    fi

    [ -n "$out" ] || return 2
    printf '%s\n' "$out"
}

# registered_hook_rows <path-to-hooks.json>
#
# The same registration surface, read at one more level of detail: prints one
# TAB-separated row per registered hook script,
#
#     <event>\t<matcher>\t<script-basename>
#
# sorted and de-duplicated, with an absent or empty matcher normalized to "-".
# Inline hooks that run no script contribute nothing, exactly as above.
#
# WHY A SECOND FUNCTION RATHER THAN A RICHER FIRST ONE
# ----------------------------------------------------
# registered_hook_scripts answers "which guards does the host load?", and its
# consumers — the session banner's fraction, install.sh's sidecar minting — want
# a flat set of filenames. The staleness pair (snapshot-enforcing-hooks.sh /
# notice-hook-staleness.sh) has to know WHERE each script is wired, because "the
# same guard newly wired onto a second event" is drift that a set of basenames
# cannot see. Widening the existing function would have meant editing three call
# sites to throw two thirds of the answer away. Both functions parse the same
# file, the same way, in the same place — which is the entire point of this
# file: one parser, not four.
#
# NO TEXT-SCAN FALLBACK, DELIBERATELY. registered_hook_scripts degrades to a
# grep when python3 is absent, and can afford to: over-counting a filename is
# survivable, and BR2 cross-checks it. This function cannot. A text scan cannot
# tell which event or matcher a command sits under — it would have to GUESS the
# association, and a guessed row is precisely the invented fact that would turn
# a staleness comparison into a false positive. So with no interpreter this
# returns 2, and its callers say out loud that they could not make the
# comparison rather than making a bad one.
#
# Exit codes — identical contract to registered_hook_scripts:
#   0  complete inventory printed
#   1  no such file
#   2  present but unparseable, registering no script at all, or no python3
registered_hook_rows() {
    local f="${1:-}"
    local out=""
    local rc=0

    [ -n "$f" ] && [ -f "$f" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 2

    out="$(python3 -c '
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
rows = set()
hooks = doc.get("hooks", {})
if isinstance(hooks, dict):
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            matcher = entry.get("matcher", "")
            if not isinstance(matcher, str) or matcher == "":
                matcher = "-"
            for h in entry.get("hooks", []) or []:
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                if not isinstance(cmd, str):
                    continue
                for m in re.findall(r"scripts/hooks/([A-Za-z0-9._+-]+\.sh)", cmd):
                    rows.add("%s\t%s\t%s" % (event, matcher, m))
for row in sorted(rows):
    print(row)
' "$f" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || return 2

    [ -n "$out" ] || return 2
    printf '%s\n' "$out"
}

# ===========================================================================
# THE PreToolUse[Agent] CHAIN — ORDERED, AND ITS ORDER INTENT
# ===========================================================================
# Everything above answers "which scripts does the host load?" as a SET. The
# Agent chain is the one place where the ANSWER IS A SEQUENCE: every registered
# gate runs on every spawn, in the order the table lists them, and the FIRST
# refusal is the one the operator reads.
#
# WHY THESE TWO FUNCTIONS EXIST, which is the whole lesson of 2026-09-14.
# guard-brief-scope.sh was registered as the ninth entry in hooks/hooks.json.
# Two consumers inside contract-integrity-probe.sh held their own TYPED copy of
# the chain — CANONICAL_AGENT_CHAIN for Layer C, BR_AGENT_WANT for BR2 — and
# both still said eight. Nothing was broken from the author's seat: the hook
# loaded, fired, and did its job. The engine went red on `main` because a list
# somebody typed weeks earlier disagreed with the registration, and the remedy
# those consumers PRINTED — "run scripts/hooks/install.sh" — could not fix it:
# install.sh validates two config keys, migrates a stale settings.json and mints
# sha256 sidecars, and never writes a hook stanza or touches either list.
#
# A list that must be edited when a hook is added is not a mitigation for drift.
# It IS the drift. So the MEMBERSHIP and the ORDER of the chain are derived here
# from the registration, and what stays typed is the only thing the registration
# cannot state about itself: WHY that order and not another.
#
# THE SPLIT IS THE DESIGN. Do not collapse it:
#
#   MEMBERSHIP + ORDER  are FACTS about the registration. Derived. A tenth hook
#                       registered tomorrow appears in both with no edit here.
#
#   THE ORDER INTENT    is a SPEC the registration cannot check against itself.
#                       Typed. Deriving it too would compare hooks.json against
#                       hooks.json and could never fail — failure type Z, a
#                       check that passes for a reason unrelated to what it
#                       checks, which is the type this engine keeps retiring.
#
# THE INTENT IS A PREFIX RULE, NOT A SEQUENCE, and that is deliberate. The four
# STRUCTURAL gates settle whether the SPAWN IS WELL FORMED — is it isolated and
# truthfully named, is the booted definition the one on disk, is a reading task
# routed to the reader, does the prompt carry what it must. They come first, in
# that order, because a dispatch that is malformed AND something else should
# hear about the malformed half first: that is the half the operator can fix
# without leaving the keyboard.
#
# Everything after them is a POLICY question — cost, environment, standing
# state, scope, whether the CEO was asked — and the probe's own comments already
# concede that their relative order is not load-bearing ("Against the CEO-ask
# gate the order is not load-bearing (both are policy questions), so the tie was
# broken by the merge-safe choice: appending"). Four such hooks have been
# appended since, and the comment on each one claims it is LAST. So the tail is
# left UNCONSTRAINED on purpose. A tenth policy hook appended tomorrow satisfies
# this rule untouched — the property that was missing — while a hook inserted
# AHEAD of the structural four still fails as loudly as it must.
AGENT_CHAIN_STRUCTURAL_PREFIX="guard-worktree-isolation.sh guard-definition-drift.sh reader-teammate-hint.sh verify-agent-prompt.sh"

# registered_agent_chain <path-to-hooks.json>
#
# Prints one hook-script BASENAME per line, IN REGISTRATION ORDER — every script
# the table runs on PreToolUse under a matcher that names Agent. Deliberately
# NOT sorted and NOT de-duplicated: a duplicate registration is a real defect
# (the hook fires twice on every spawn, and Layer M exists for it), so this
# function's job is to show it, not to tidy it away.
#
# NO TEXT-SCAN FALLBACK, for registered_hook_rows' reason and one more: a grep
# cannot see which event or matcher a command sits under, and it cannot see
# order at all. A guessed sequence is worse than a refusal here, because its
# only consumer is a check on that exact sequence.
#
# Exit codes — a caller MUST distinguish these from an empty chain:
#   0  complete chain printed
#   1  no such file (wrong path, or an incomplete engine install)
#   2  present but unparseable, registering nothing on PreToolUse[Agent], or
#      no python3 to read it with
registered_agent_chain() {
    local f="${1:-}"
    local out=""
    local rc=0

    [ -n "$f" ] && [ -f "$f" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 2

    out="$(python3 -c '
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
chain = []
entries = (doc.get("hooks") or {}).get("PreToolUse")
if isinstance(entries, list):
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        matcher = entry.get("matcher", "")
        if not isinstance(matcher, str) or "Agent" not in matcher:
            continue
        for h in entry.get("hooks", []) or []:
            if not isinstance(h, dict):
                continue
            cmd = h.get("command", "")
            if not isinstance(cmd, str):
                continue
            for m in re.findall(r"scripts/hooks/([A-Za-z0-9._+-]+\.sh)", cmd):
                chain.append(m)
for name in chain:
    print(name)
' "$f" 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || return 2

    [ -n "$out" ] || return 2
    printf '%s\n' "$out"
}

# agent_chain_order_violations <name> [<name> ...]
#
# Judges an ORDERED Agent chain against AGENT_CHAIN_STRUCTURAL_PREFIX above.
# Prints one human-readable violation per line and returns 1 if there are any;
# prints nothing and returns 0 when the order is sound.
#
# It says nothing whatever about the tail. That is not an omission — see the
# intent above: the tail's order is explicitly not load-bearing, and a rule that
# constrained it would have to be edited by every future appender, which is the
# defect this whole section exists to end.
agent_chain_order_violations() {
    local -a chain=("$@")
    local -a want=()
    local i=0 bad=0 seen=""
    # shellcheck disable=SC2206
    want=($AGENT_CHAIN_STRUCTURAL_PREFIX)

    for i in "${!want[@]}"; do
        if [ "${#chain[@]}" -le "$i" ] || [ "${chain[$i]}" != "${want[$i]}" ]; then
            seen="${chain[$i]:-<nothing — the chain ends here>}"
            printf 'position %d of the PreToolUse[Agent] chain must be %s, and is %s. The four structural gates settle whether the SPAWN is well formed, and they run ahead of every policy gate so that a dispatch which is malformed AND something else hears about the malformed half first.\n' \
                "$((i+1))" "${want[$i]}" "$seen"
            bad=1
        fi
    done

    for i in "${!chain[@]}"; do
        [ "$i" -lt "${#want[@]}" ] && continue
        case " $AGENT_CHAIN_STRUCTURAL_PREFIX " in
            *" ${chain[$i]} "*)
                printf '%s is a STRUCTURAL gate wired at position %d, behind a policy gate. It belongs in the first %d entries: a spawn that fails it should never have been reasoned about by anything downstream.\n' \
                    "${chain[$i]}" "$((i+1))" "${#want[@]}"
                bad=1
                ;;
        esac
    done

    return "$bad"
}
