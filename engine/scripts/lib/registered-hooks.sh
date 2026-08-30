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

# registered_hook_scripts <path-to-hooks.json>
#
# Prints one hook-script BASENAME per line ("guard-bash-main-writes.sh"),
# sorted and de-duplicated — every script the given hook table registers, on
# any event, under any matcher. Inline hooks that run no script (the knowledge-
# verification echo) contribute nothing, correctly: they are not scripts and
# cannot be present-or-missing on disk.
#
# Exit codes — a caller MUST distinguish these from an empty inventory:
#   0  complete inventory printed
#   1  no such file (the path is wrong, or the engine install is incomplete)
#   2  present but unparseable, or parseable and registering no script at all
registered_hook_scripts() {
    local f="${1:-}"
    local out=""
    local rc=0

    [ -n "$f" ] && [ -f "$f" ] || return 1

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
# sorted and de-duplicated, with an absent or empty matcher normalised to "-".
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
