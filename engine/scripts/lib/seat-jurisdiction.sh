#!/usr/bin/env bash
#
# scripts/lib/seat-jurisdiction.sh — THE JURISDICTION CONTRACT.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Every guard answers two questions, and until 2026-08-30 it answered them from
# two different places that were never compared:
#
#   "Am I governed?"     -> the SESSION'S SEAT, via resolve_entity_root().
#   "What am I judging?" -> the COMMAND'S OWN REPOSITORY, via the hook payload
#                           (tool_input.file_path, or ct_repo_root of the
#                           payload cwd).
#
# With the engine loaded as a USER-SCOPE plugin those two are never the same
# repository by construction: the seat is wherever the session happens to sit,
# the artifact is wherever the command points. Measured that day
# (docs/audits/seat-vs-inspection-divergence-2026-08-30.md), across the 26
# scripts hooks/hooks.json actually registers: 20 resolve a seat and 7 derived
# their inspection target independently of it.
#
# The damage was not that the guards were wrong. It was that DIVERGENCE AND
# SUCCESS WERE THE SAME BYTE. A guard whose target fell outside its seat ran off
# the end of its loop and exited 0 — identical, to every observer, to a guard
# that had looked and approved. Three consequences, all reproduced:
#
#   * a write to the REAL product source (richos/app/) exited 0;
#   * a write to richos/engine/app/ — A DIRECTORY THAT DOES NOT EXIST — was
#     blocked, because the seat had resolved to the engine subdirectory and
#     PROTECTED_PATHS was joined onto it;
#   * richos-hq, seated `not-adopted`, exited 0 for everything, silently, while
#     taking 28 commits that day.
#
# ===========================================================================
# THE RULE — one sentence, and it holds for every guard
# ===========================================================================
#
#   A guard enforces on an artifact IF AND ONLY IF that artifact lies inside
#   the repository the guard resolved as its seat; an artifact outside the seat
#   is OUT OF JURISDICTION and is ANNOUNCED, never silently allowed.
#
# Note what the rule does NOT say. It does not say "block it". Blocking every
# out-of-jurisdiction artifact would brick every cross-repository operation on
# the machine, and this engine has already learned once that "refuse what you
# cannot resolve" is not the same rule as "never pretend you resolved it"
# (resolve-roots.sh, THE GOVERNING RULE). The rule says the guard must not be
# SILENT about it. Silence is the whole defect; the exit code is not.
#
# ===========================================================================
# WHY THE ANNOUNCEMENT IS DEDUPLICATED, AND WHY THAT IS NOT A MUTE
# ===========================================================================
# An out-of-jurisdiction artifact is normal and frequent — an agent reading
# another repository, a lander running from elsewhere. One line per (hook,
# repository, kind) per session is loud; the same line on every tool call is
# noise, and noise is how a real signal gets filtered out by a human. So the
# notice fires ONCE per triple and is then suppressed for that session.
#
# There is deliberately no configuration key that turns it off. A mute for "this
# artifact is not protected" is the silent skip walking back in through the door
# marked configuration — the exact reasoning engine-status.sh already records
# for the stood-down banner.
#
# STATE LIVES IN TMPDIR, NEVER IN A REPOSITORY. On 2026-08-28
# guard-definition-drift.sh wrote its state log into a repository that had
# nothing to do with the session; that is precisely the class of bug this file
# exists to end, so it must not reproduce it while doing so.
#
# Safe to source repeatedly. Never changes the caller's cwd.

if [ -n "${_SEAT_JURISDICTION_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_SEAT_JURISDICTION_SH_SOURCED=1

# --- notice state ----------------------------------------------------------
# One directory per user per session-ish lifetime. TMPDIR is cleared by the OS,
# which is the right retention: the guarantee is "once per session", not
# "once ever" — a new session must be told again.
_sj_notice_dir() {
    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    local uid d
    uid="$(id -u 2>/dev/null || echo 0)"
    d="$base/richos-engine-notices-$uid"
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
    printf '%s' "$d"
}

# _sj_once <key> — rc 0 the FIRST time this key is seen, rc 1 afterwards.
# Fails OPEN (rc 0, i.e. announce) if state cannot be written: an announcement
# repeated is a nuisance, an announcement lost is the bug.
_sj_once() {
    local key="$1" dir stamp
    dir="$(_sj_notice_dir)" || return 0
    stamp="$dir/$(printf '%s' "$key" | cksum | tr -d ' /')"
    [ -e "$stamp" ] && return 1
    : >"$stamp" 2>/dev/null || return 0
    return 0
}

# ---------------------------------------------------------------------------
# richos_repo_of <path>
# ---------------------------------------------------------------------------
# The repository a path belongs to: its git top-level, normalised to the MAIN
# checkout so a linked worktree answers with the checkout it shares. Prints
# nothing (rc 1) when the path is in no repository at all.
#
# Normalisation matters here for the same reason it matters in resolve-roots.sh:
# an agent editing inside .claude/worktrees/<x>/ IS editing the seat's
# repository, and a jurisdiction check that said otherwise would fire on every
# legitimate worktree edit and train people to ignore it.
richos_repo_of() {
    local p="${1:-}" dir top
    [ -n "$p" ] || return 1
    if [ -d "$p" ]; then dir="$p"; else dir="$(dirname "$p")"; fi
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return 1
    if command -v resolve_main_checkout >/dev/null 2>&1; then
        top="$(resolve_main_checkout "$top" "$top" 2>/dev/null || printf '%s' "$top")"
    fi
    ( cd "$top" 2>/dev/null && pwd ) || printf '%s\n' "$top"
}

# ---------------------------------------------------------------------------
# richos_in_jurisdiction <seat> <target>
# ---------------------------------------------------------------------------
# rc 0  the target lies inside the seat (path containment OR same repository)
# rc 1  it does not
# rc 2  undecidable — the target is in no repository and is not under the seat
#
# Path containment is checked FIRST and answers on its own. A target under the
# seat is in jurisdiction even when it is untracked, ignored, or not yet
# created — all three are ordinary for a Write, and asking git about a file that
# does not exist yet would make the answer depend on creation order.
richos_in_jurisdiction() {
    local seat="${1:-}" target="${2:-}"
    [ -n "$seat" ] && [ -n "$target" ] || return 2
    seat="${seat%/}"

    case "$target" in
        "$seat"|"$seat"/*) return 0 ;;
    esac

    local trepo
    trepo="$(richos_repo_of "$target" 2>/dev/null || true)"
    [ -n "$trepo" ] || return 2
    [ "${trepo%/}" = "$seat" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# richos_assert_jurisdiction <hook> <seat> <target> [what]
# ---------------------------------------------------------------------------
# THE CALL EVERY DIVERGING GUARD MAKES. Returns:
#
#   rc 0  in jurisdiction  -> the guard proceeds and enforces
#   rc 1  out of jurisdiction -> the guard must NOT enforce, and the caller's
#         `exit 0` is now an ANNOUNCED non-enforcement rather than a silent one
#
# The announcement is the product. It names the hook, the seat, the artifact and
# the repository the artifact actually belongs to, so the reader can see the two
# repositories that failed to be the same one.
richos_assert_jurisdiction() {
    local hook="${1:-<unknown hook>}" seat="${2:-}" target="${3:-}" what="${4:-artifact}"
    local rc=0
    richos_in_jurisdiction "$seat" "$target" || rc=$?
    [ "$rc" = 0 ] && return 0

    local trepo reason
    trepo="$(richos_repo_of "$target" 2>/dev/null || true)"
    if [ "$rc" = 2 ]; then
        reason="it is in no git repository at all"
        trepo="<none>"
    else
        reason="it belongs to a different repository"
    fi

    if _sj_once "jurisdiction|$hook|${trepo:-none}|${seat:-none}"; then
        {
            echo "=== RichOS engine: OUT OF JURISDICTION — NOT ENFORCED ==="
            printf '  %-9s: %s\n' "hook" "$hook"
            printf '  %-9s: %s   (the repository this session governs)\n' "seat" "${seat:-<unresolved>}"
            printf '  %-9s: %s\n' "$what" "$target"
            printf '  %-9s: %s\n' "its repo" "${trepo:-<none>}"
            echo "  This guard is seated in one repository and was handed an artifact in"
            echo "  another, so $reason and the guard did NOT judge it."
            echo "  THIS IS NOT A PASS. Nothing about that artifact was checked."
            echo "  To have it enforced, work from a session seated in its repository, or"
            echo "  adopt the engine there (commit an orchestration.config at its root)."
            echo "  (said once per hook+repository per session)"
            echo "=========================================================="
        } >&2
    fi
    return 1
}

# ---------------------------------------------------------------------------
# richos_announce_stand_down <hook> [reason]
# ---------------------------------------------------------------------------
# The LOUD stand-down. Called on the `not-adopted` arm, where every guard used
# to `exit 0` with no output whatsoever.
#
# engine-status.sh already announces the stand-down once at SessionStart. That
# is necessary and it is not sufficient: it fires before any work happens, it
# names no specific action, and a session that scrolls past it has no second
# chance. This fires at the MOMENT OF THE DECISION and names the guard that just
# declined — which is the only moment at which the absence actually costs
# something.
richos_announce_stand_down() {
    local hook="${1:-<unknown hook>}" reason="${2:-}"
    local where="${CLAUDE_PROJECT_DIR:-$PWD}"
    local repo
    repo="$(richos_repo_of "$where" 2>/dev/null || true)"
    [ -n "$repo" ] || repo="$where"

    _sj_once "standdown|$hook|$repo" || return 0
    {
        echo "=== RichOS engine: STOOD DOWN — $hook DID NOT RUN ==="
        echo "  repository : $repo"
        echo "  reason     : ${reason:-no orchestration.config at any candidate root, so this repository has not adopted the engine}"
        echo "  This guard declined to enforce. That is a STAND-DOWN, not a pass —"
        echo "  nothing it checks for was checked in this repository."
        echo "  Adopt by committing an orchestration.config at the repository root."
        echo "  (said once per hook per repository per session)"
        echo "===================================================="
    } >&2
    return 0
}
