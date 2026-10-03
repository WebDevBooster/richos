#!/usr/bin/env bash
# P5-65: a once-per-session notice is announced again in a new session.
# LIB_DIR overrides which copy of seat-jurisdiction.sh is tested.
set -uo pipefail
D="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export TMPDIR; TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
# shellcheck disable=SC1091
. "$D/seat-jurisdiction.sh"
CLAUDE_SESSION_ID=s1 _sj_once k || { echo "FAIL P5-65: s1 first"; exit 1; }
CLAUDE_SESSION_ID=s1 _sj_once k && { echo "FAIL P5-65: s1 repeat announced"; exit 1; }
CLAUDE_SESSION_ID=s2 _sj_once k || { echo "FAIL P5-65: new session silenced"; exit 1; }
echo "ok   P5-65 new session is told again"
