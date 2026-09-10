#!/usr/bin/env bash
# G0 probe wrapper: scrub inherited Claude Code session env, pin an isolated config dir, exec the pinned binary.
# usage: run-claude.sh <config-dir> <cwd> <claude args...>
CFG="$1"; shift; WD="$1"; shift
for v in $(env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC)'); do unset "$v"; done
if [ "$CFG" != "default" ]; then export CLAUDE_CONFIG_DIR="$CFG"; fi
export TERM="${TERM:-xterm-256color}"
cd "$WD" || exit 97
exec /Users/alex/.local/share/claude/versions/2.1.267 "$@"
