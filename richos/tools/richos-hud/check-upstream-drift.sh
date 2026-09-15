#!/usr/bin/env bash
#
# Has open-wispr moved past the commit our patches are built against?
#
# The build pins an audited base commit, so upstream moving cannot break the
# build — a pinned SHA is immutable. What upstream movement DOES mean is that
# the freeze has started costing something: fixes exist that our dictation
# will never receive, and the patches would need rebasing to collect them.
#
# This check exists so that moment is noticed rather than discovered. It reads
# the pin from build.sh so there is exactly one copy of the SHA.
#
# Usage:
#   tools/richos-hud/check-upstream-drift.sh
#
# Exit codes:
#   0  level with upstream, or upstream unreachable (reported, not failed)
#   1  upstream has moved past the pin — a decision is due
#   2  the check itself is broken (pin unreadable)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${SCRIPT_DIR}/build.sh"
REPO="https://github.com/human37/open-wispr.git"

[ -r "${BUILD}" ] || { echo "FAIL: cannot read ${BUILD} — the pin lives there" >&2; exit 2; }

PINNED="$(sed -n 's/^AUDITED_COMMIT="\([0-9a-f]\{40\}\)".*/\1/p' "${BUILD}" | head -1)"
[ -n "${PINNED}" ] || { echo "FAIL: no 40-char AUDITED_COMMIT found in ${BUILD}" >&2; exit 2; }

# git ls-remote needs no auth and no API token, so an adopter can run this.
if ! REMOTE="$(git ls-remote "${REPO}" HEAD 2>/dev/null | awk '{print $1}')" || [ -z "${REMOTE}" ]; then
  echo "upstream unreachable — cannot tell whether ${PINNED:0:9} is still the tip."
  echo "Not treated as drift: an offline machine is not evidence of an upstream change."
  exit 0
fi

if [ "${REMOTE}" = "${PINNED}" ]; then
  echo "level: upstream HEAD is ${REMOTE:0:9}, the same commit the patches are built against."
  exit 0
fi

cat <<EOF
UPSTREAM HAS MOVED.

  pinned (ours):  ${PINNED:0:9}
  upstream HEAD:  ${REMOTE:0:9}

The build is unaffected — it checks out the pinned commit, which still exists.
What has changed is the cost of staying frozen: there is now upstream work the
patched build will not receive.

A decision is due, not an emergency:
  - stay pinned, deliberately, and record why; or
  - rebase the patches onto the new tip and re-audit the diff before trusting it.

Nothing here should be automated. Moving the pin means running unaudited
upstream code on the machine that captures dictation.
EOF
exit 1
