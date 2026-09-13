#!/usr/bin/env bash
#
# containers.sh — container residue, as the one command anyone runs.
#
# The mechanism, and the argument for every refusal in it:
# scripts/lib/containers.py. This file only finds python3 and the library.
#
#   containers.sh status
#       every container on the machine, split into the ones a LIVE workspace
#       owns (never touched), the ones a workspace that is GONE declared
#       (reported with age and size, never deleted by a sweep), and the ones
#       with no ownership evidence at all (a person's, almost certainly).
#       Ends with what `docker system df` calls reclaimable — reported,
#       because spending it is the founder's call and not a script's.
#   containers.sh reap --workspace <path> [--dry-run]
#       remove the containers that DECLARE that workspace as their owner.
#       This is what the workspace deleter calls (scripts/lib/workspaces.py,
#       _delete) when a workspace lands or is discarded. Running it by hand
#       against a LIVE workspace removes nothing and says so.
#   containers.sh label-args
#       the `--label` arguments a container created for this workspace must
#       carry, so no caller invents a second spelling of what the reaper
#       greps for:   docker run $(containers.sh label-args) ...
#
# DOCKER ABSENT, OR ITS DAEMON DOWN, IS NOT A FAILURE HERE. Every entry point
# says so and exits 0: this is called from a land, and a machine without
# Docker must land work exactly as it did before this file existed.
#
# THE ONLY THING IN THE ENGINE THAT DELETES A CONTAINER IS `reap`, AND IT ONLY
# EVER DELETES ONE THAT DECLARED THE WORKSPACE THAT JUST ENDED. There is no
# prune here and there will not be one.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/containers.py"
command -v python3 >/dev/null 2>&1 || { echo "containers.sh: python3 is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "containers.sh: $LIB is missing" >&2; exit 2; }
exec python3 "$LIB" "$@"
