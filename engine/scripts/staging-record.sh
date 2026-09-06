#!/usr/bin/env bash
#
# staging-record.sh — WRITE DOWN WHAT STAGING ACTUALLY HAS.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# guard-stale-staging.sh refuses a product dispatch while landed product
# commits have not reached staging. To do that it has to know one fact —
# WHICH COMMIT STAGING IS RUNNING — and before this script there was nowhere
# on disk that fact was written down. The deploy pipeline it serves posts a
# GitHub deployment and hits the platform API, and every local artifact it
# makes is a temp file it deletes.
#
# A network lookup is the wrong answer twice over. The founder's ruling 11.4
# leaves the platform login restored only when product work resumes, so a
# check that phoned the platform would fail exactly when it matters; and a
# PreToolUse hook that spends seconds on HTTP is a hook that gets disabled.
#
# ===========================================================================
# WHEN THE DEPLOY CALLS THIS — AND IT IS NOT "AT THE END"
# ===========================================================================
# AFTER the deploy's own freshness gate has returned its verdict, and with that
# verdict passed in. Never before, and never unconditionally:
#
#     "$ENGINE/scripts/staging-record.sh" --sha "$SHA" --tree avelor \
#         --outcome "$FRESHNESS_GATE_OUTCOME"
#
# A record written at the START of a deploy would claim a deploy that had not
# happened, which is the "the deploy said success" failure the whole freshness
# contract exists to end. A record written unconditionally at the end would
# make a FAILED deploy and a current staging produce the same file. So the
# outcome is a required field and the reader treats anything but `success` as
# NO RECORD.
#
# ===========================================================================
# WHY A FLAT FILE AND NOT JSON
# ===========================================================================
# The consumer is a shell hook on a PreToolUse path. `grep` + `sed` reads this
# with no interpreter and no parse failure mode; a JSON record would make the
# guard's verdict depend on python3 being present, and the guard already has to
# fail open when it is not. Four fields, one per line, and unknown fields are
# ignored by the reader so a future one costs nothing.
#
# Usage:
#   staging-record.sh --sha <commit> [--tree <name>] [--outcome <word>]
#                     [--root <entity root>] [--record <path>]
#   staging-record.sh --show [--root <entity root>]
#
# Exit codes: 0 written (or shown); 2 bad usage / unusable arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHA=""
TREE=""
OUTCOME="success"
ROOT=""
RECORD=""
SHOW=0

die() { printf 'staging-record.sh: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --sha)     SHA="${2:-}"; shift 2 ;;
        --tree)    TREE="${2:-}"; shift 2 ;;
        --outcome) OUTCOME="${2:-}"; shift 2 ;;
        --root)    ROOT="${2:-}"; shift 2 ;;
        --record)  RECORD="${2:-}"; shift 2 ;;
        --show)    SHOW=1; shift ;;
        -h|--help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument '$1'. See --help." ;;
    esac
done

# --- Where the record lives ------------------------------------------------
# The entity root, then the declaration, then the default — the same order
# every other consumer of orchestration.config uses.
if [ -z "$ROOT" ]; then
    ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || printf '%s' "$PWD")"
    # An engine loaded BY REFERENCE lives outside the repository it serves, so
    # its own parent is the wrong root. Prefer the caller's checkout when the
    # caller is in one.
    if command -v git >/dev/null 2>&1; then
        CALLER_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        [ -n "$CALLER_ROOT" ] && ROOT="$CALLER_ROOT"
    fi
fi
[ -d "$ROOT" ] || die "entity root '$ROOT' is not a directory."

if [ -z "$RECORD" ]; then
    CONFIG="$ROOT/orchestration.config"
    # shellcheck disable=SC1090
    [ -f "$CONFIG" ] && . "$CONFIG"
    RECORD="${STAGING_DEPLOY_RECORD:-.claude/state/staging-deployed}"
fi
case "$RECORD" in
    /*) : ;;
    *)  RECORD="$ROOT/$RECORD" ;;
esac

if [ "$SHOW" = "1" ]; then
    if [ -f "$RECORD" ]; then
        printf 'record: %s\n' "$RECORD"
        cat "$RECORD"
    else
        printf 'record: %s (does not exist — staging content is UNKNOWN)\n' "$RECORD"
    fi
    exit 0
fi

# --- Validate --------------------------------------------------------------
[ -n "$SHA" ] || die "--sha is required. A record with no commit is not a record."
printf '%s' "$SHA" | grep -qE '^[0-9a-f]{7,40}$' \
    || die "--sha '$SHA' is not a commit hash (7-40 lowercase hex). Pass the SHA the deploy actually shipped, read from git rather than typed."
[ -n "$OUTCOME" ] || die "--outcome is required and must be the deploy's real verdict. A record that omits it would make a FAILED deploy and a current staging produce the same file."

# --- Write, atomically -----------------------------------------------------
# A half-written record read by the guard mid-deploy would be a malformed
# record, which the guard reads as "unknown" — safe, but noisy. mv(1) within
# one filesystem is atomic, so a reader sees the old record or the new one.
mkdir -p "$(dirname "$RECORD")" 2>/dev/null || die "cannot create $(dirname "$RECORD")"
TMP="$RECORD.$$.tmp"
{
    echo "# Written by scripts/staging-record.sh — read by scripts/hooks/guard-stale-staging.sh."
    echo "# WHAT STAGING IS RUNNING. Never edited by hand: a hand-edited record is a"
    echo "# claim about a deploy nobody ran, which is the failure the guard exists to catch."
    echo "sha=$SHA"
    [ -n "$TREE" ] && echo "tree=$TREE"
    echo "outcome=$OUTCOME"
    echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$TMP"
mv -f "$TMP" "$RECORD"

printf 'staging deploy recorded: sha=%s outcome=%s -> %s\n' "$SHA" "$OUTCOME" "$RECORD"
