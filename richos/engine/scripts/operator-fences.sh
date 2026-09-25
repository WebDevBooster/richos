#!/usr/bin/env bash
#
# operator-fences.sh: install the Git fence, and turn it on and off (spec r3 e8,
# Frank G10 and G12).
#
#   operator-fences.sh install   [--repo <path>]... [--entity <path>]
#   operator-fences.sh on        [--repo <path>]... [--entity <path>]
#   operator-fences.sh off       [--repo <path>]...
#   operator-fences.sh status    [--repo <path>]... [--entity <path>] [--declaration-check]
#   operator-fences.sh uninstall [--repo <path>]...
#
# install    writes the launcher as each repository's reference-transaction hook,
#            moves the hook that was there into its chain, and records the
#            repositories. It keeps each launcher's current state; a first install
#            is OFF. Repositories default to the entity's OPERATOR_FENCES_REPOS.
# on / off   rewrite one line in each installed launcher. `on` refuses unless the
#            entity's orchestration.config declares OPERATOR_FENCES="on" and every
#            install is current. `off` needs nothing and touches no working tree:
#            it is the one-command way out if a fence defect ever refuses a land.
# status     exit 0 only when the switch is on and the fence is installed, current
#            and reachable in every recorded repository (the operator lead's init
#            check). With --declaration-check, exit 0 when the launchers agree with
#            the declaration, on or off (the integrity probe's question).
# uninstall  restores each repository's previous hook and removes the launcher.
#
# This command never edits ~/.codex/AGENTS.md. See the as-built record,
# richos-hq docs/verification/2026-09-24-operator-fences/README.md.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
exec "$PY" "$SCRIPT_DIR/lib/operator_fences.py" admin "$@"
