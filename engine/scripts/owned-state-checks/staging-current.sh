#!/usr/bin/env bash
#
# staging-current.sh — IS STAGING CARRYING WHAT MAIN CARRIES?
#
# A standing-ownership check for the `staging` row of
# owned-systems.declaration. It answers ONE question, for the repository as a
# whole, with no dispatch in front of it:
#
#     for every declared product tree, has the commit staging is running got
#     everything main has that touches that tree?
#
# ===========================================================================
# THIS IS NOT guard-stale-staging.sh, AND THE DIFFERENCE IS THE POINT
# ===========================================================================
# That guard asks "is THIS DISPATCH about to work on or test against a product
# tree whose landed commits have not reached staging?" — a question about a
# dispatch, answerable only when there is a dispatch to look at. This asks "is
# staging current, right now, whether or not anybody is about to touch it?".
#
# They read THE SAME DATA through the SAME DECLARED KEYS — STAGING_TREES,
# STAGING_DEPLOY_RECORD — so the facts cannot drift. The derivation is written
# twice, and that is stated here rather than discovered later: if the record
# format changes, both readers change. The alternative was to make the guard
# import a library, which would put a new failure mode on a PreToolUse path
# that currently has none.
#
# ===========================================================================
# MODES
# ===========================================================================
#   --declared     JURISDICTION. Exit 0 if this repository declares any
#                  product tree at all, 1 if it does not. Most repositories on
#                  this machine have no staging and must be silent about it.
#   (default)      THE CHECK. Exit 0 current · 1 stale or unrecorded · 2 the
#                  question could not be answered (no config, no git, no main).
#                  2 is NEVER 0: "staging is current" and "nothing was read"
#                  are the two answers this whole engine exists to keep apart.
#
# Options: --root <entity root>  (default: the caller's git toplevel)
#
# WHY "NO RECORD" IS STALE AND NOT UNKNOWN. A deploy writes the record as its
# last act (scripts/staging-record.sh). No record means no deploy has ever
# finished here, which is a true statement about staging, not an absence of
# information about it. The line says exactly that, so nobody reads it as a
# broken instrument.

set -eo pipefail

ROOT=""
MODE="check"
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="${2:-}"; shift 2 ;;
        --declared) MODE="declared"; shift ;;
        -h|--help)  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'staging-current.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -z "$ROOT" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "staging-current.sh: no entity root" >&2; exit 2; }

CONFIG="$ROOT/orchestration.config"
if [ ! -f "$CONFIG" ]; then
    [ "$MODE" = "declared" ] && exit 1
    echo "staging-current.sh: $CONFIG is missing, so STAGING_TREES cannot be read" >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$CONFIG"

STAGING_TREES="${STAGING_TREES:-}"
if [ -z "$(printf '%s' "$STAGING_TREES" | tr -d '[:space:]')" ]; then
    [ "$MODE" = "declared" ] && exit 1
    echo "staging-current.sh: this repository declares no product tree" >&2
    exit 2
fi
[ "$MODE" = "declared" ] && exit 0

: "${STAGING_DEPLOY_RECORD:=.claude/state/staging-deployed}"
: "${STAGING_MAIN_REF:=refs/heads/main}"

RECORD_BASE="$STAGING_DEPLOY_RECORD"
case "$RECORD_BASE" in
    /*) : ;;
    *)  RECORD_BASE="$ROOT/$RECORD_BASE" ;;
esac

command -v git >/dev/null 2>&1 || { echo "staging-current.sh: git is not on PATH" >&2; exit 2; }

# The main checkout, from any invocation location: a worktree's HEAD is a
# proposal, not what landed.
MAIN_ROOT="$ROOT"
_MC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-main-checkout.sh"
if [ -f "$_MC_LIB" ]; then
    # shellcheck source=../lib/resolve-main-checkout.sh
    . "$_MC_LIB"
    MAIN_ROOT="$(resolve_main_checkout "$ROOT" "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
fi

MAIN_TIP="$(git -C "$MAIN_ROOT" rev-parse --verify --quiet "$STAGING_MAIN_REF" 2>/dev/null || true)"
if [ -z "$MAIN_TIP" ]; then
    echo "staging-current.sh: '${STAGING_MAIN_REF}' does not resolve in ${MAIN_ROOT}" >&2
    exit 2
fi

TREE_COUNT="$(printf '%s\n' "$STAGING_TREES" | awk '{ n += NF } END { print n+0 }')"
STALE=0

for tree in $STAGING_TREES; do
    ENCODED="$(printf '%s' "$tree" | sed 's|/|%2F|g')"
    RECORD="$RECORD_BASE.trees/$ENCODED"
    if [ ! -f "$RECORD" ] && [ "$TREE_COUNT" -eq 1 ] && [ -f "$RECORD_BASE" ]; then
        RECORD="$RECORD_BASE"
    fi
    if [ ! -f "$RECORD" ]; then
        echo "NO RECORD  $tree — no deploy has ever finished here (expected $RECORD)"
        STALE=1
        continue
    fi
    SHA="$(sed -n 's/^[[:space:]]*sha[[:space:]]*=[[:space:]]*//p' "$RECORD" | sed -n '1p' | tr -d '[:space:]')"
    OUTCOME="$(sed -n 's/^[[:space:]]*outcome[[:space:]]*=[[:space:]]*//p' "$RECORD" | sed -n '1p' | tr -d '[:space:]')"
    if [ -n "$OUTCOME" ] && [ "$OUTCOME" != "success" ]; then
        echo "NO RECORD  $tree — the last deploy recorded outcome='$OUTCOME', so what staging carries is unknown"
        STALE=1
        continue
    fi
    if ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{7,40}$'; then
        echo "NO RECORD  $tree — the record carries no readable sha= line"
        STALE=1
        continue
    fi
    if ! git -C "$MAIN_ROOT" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
        echo "NO RECORD  $tree — the recorded commit $SHA is not in this repository"
        STALE=1
        continue
    fi
    BEHIND="$(git -C "$MAIN_ROOT" rev-list --count "${SHA}..${MAIN_TIP}" -- "$tree" 2>/dev/null || echo 0)"
    if [ "${BEHIND:-0}" -gt 0 ]; then
        echo "STALE      $tree — $BEHIND commit(s) touching $tree/ landed since staging's $SHA"
        STALE=1
    else
        echo "current    $tree — staging at $SHA has every $tree/ commit on main"
    fi
done

exit "$STALE"
