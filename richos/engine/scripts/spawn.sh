#!/usr/bin/env bash
#
# spawn.sh - STARTING ONE TEAMMATE IS ONE COMMAND.
#
# It resolves the repository (absolute path OR bare name), resolves and where
# necessary RECORDS or REPAIRS the branch this work integrates on, assembles the
# complete Agent payload including its acknowledgement contract, evaluates EVERY
# PreToolUse[Agent] guard from EVERY surface against it and reports ALL failures
# together, creates the isolated workspace only once nothing can refuse it,
# re-evaluates the guards against the real thing, and prints the finished
# payload. On any failure it leaves nothing behind.
#
# This file only finds python3 and the library. The mechanism, and the reason it
# exists, are in scripts/lib/spawn.py.
#
#   spawn.sh <teammate-name> --repo <repo> [--repo <repo> ...]
#            --type <subagent-type> --brief <file>
#            [--model <alias>] [--description <text>] [--base [<repo>=]<ref>]
#            [--dir [<repo>=]<path>] [--integration [<repo>=]<branch>]
#            [--integration-why <text>] [--payload-out <file>] [--json] [--dry-run]
#
# --repo IS GIVEN ONCE PER REPOSITORY the teammate works in. It creates and
# REGISTERS one cc/ workspace in each, all under the ONE name, and the payload
# carries one `cross-repo-worktree:` line per workspace. All of an agent's
# workspaces go together when its work is landed or discarded
# (docs/plans/worktree-spec-2026-09-11.md, point 10).
#
# The payload goes to STDOUT; everything a person reads goes to stderr, so
# `spawn.sh ... > payload.json` is a payload and nothing else.
#
# Exit: 0 ready; 1 refused (nothing created); 2 usage; 4 created and rolled back.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/spawn.py"
command -v python3 >/dev/null 2>&1 || { echo "spawn.sh: python3 is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "spawn.sh: git is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "spawn.sh: $LIB is missing" >&2; exit 2; }
exec python3 "$LIB" "$@"
