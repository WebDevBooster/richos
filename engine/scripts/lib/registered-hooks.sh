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
