#!/usr/bin/env bash
# Time every engine PreToolUse[Bash] hook on a plain payload, from a worktree.
# Usage: hook-latency.sh [<worktree-dir>]   (default: the current directory)
E="${RICHOS_ENGINE:-$HOME/.claude/richos-engine}"
F="${1:-$PWD}"
P="$(mktemp -t hook-payload.XXXXXX)"
trap 'rm -f "$P"' EXIT
printf '{"session_id":"measure","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s"}\n' "$F" > "$P"
cd "$F" || exit 9
tot=0
for h in guard-sealed-worktree guard-interactive-prompt guard-bash-main-writes guard-inflight-notify guard-worktree-removal guard-publication-commits guard-named-persons-commands guard-ceo-todos-commits guard-completeness-commits guard-row-currency-commits guard-vendoring-commits shell-evidence; do
  s=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  CLAUDE_PLUGIN_ROOT=$E CLAUDE_PROJECT_DIR=$F bash "$E/scripts/hooks/$h.sh" < "$P" >/dev/null 2>&1; rc=$?
  e=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  d=$(echo "$e - $s" | bc); tot=$(echo "$tot + $d" | bc)
  printf '%-32s rc=%s %6.3fs\n' "$h" "$rc" "$d"
done
echo "engine PreToolUse[Bash] total: ${tot}s"
