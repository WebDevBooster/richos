#!/usr/bin/env bash
# A VALID comparison this time. The first attempt ran the reverted hook from a
# bare temp directory, so it could not find scripts/lib/resolve-roots.sh and
# exited on the broken-install path in 9.7ms — a measurement of nothing.
#
# Both arms now run from a full MIRROR of the engine's scripts tree, so each
# hook resolves its libraries exactly as it does in place. The only difference
# between the arms is the hook file itself.
W=/Users/alex/ab/richos-wt/zach-opus-si1
S="$(mktemp -d)"
mkdir -p "$S/engine"
cp -R "$W/engine/scripts" "$S/engine/scripts"
cp -R "$W/engine/hooks" "$S/engine/hooks" 2>/dev/null
cp "$W/engine/orchestration.config" "$S/engine/" 2>/dev/null
cp "$W/engine/VERSION" "$S/engine/" 2>/dev/null

REPO="$S/entity"
mkdir -p "$REPO/.claude/state" "$REPO/docs"
printf 'PROTECTED_PATHS="docs"\n' > "$REPO/orchestration.config"
echo "# s" > "$REPO/README.md"
git -C "$REPO" init -q -b main; git -C "$REPO" config user.email t@e.invalid
git -C "$REPO" config user.name t; git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m base >/dev/null 2>&1

python3 -c "
import json,sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'echo hello'},
 'session_id':'tc000001-0000-4000-8000-000000000000','cwd':sys.argv[1]}))" "$REPO" > "$S/p.json"

N=20
run() { # <hook path>
    local h="$1" t0 t1 i
    # one warm-up, then N timed
    RICHOS_ENTITY_ROOT="$REPO" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$S/engine" \
        /bin/bash "$h" < "$S/p.json" >/dev/null 2>&1
    t0=$(python3 -c 'import time;print(time.time())')
    i=0
    while [ "$i" -lt "$N" ]; do
        RICHOS_ENTITY_ROOT="$REPO" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$S/engine" \
            /bin/bash "$h" < "$S/p.json" >/dev/null 2>&1
        i=$((i + 1))
    done
    t1=$(python3 -c 'import time;print(time.time())')
    python3 -c "print('  %.1f ms per call' % ((($t1)-($t0))/$N*1000))"
}

for hook in guard-bash-main-writes.sh guard-interactive-prompt.sh guard-worktree-removal.sh; do
    echo "### $hook"
    H="$S/engine/scripts/hooks/$hook"
    echo " wired:"; run "$H"
    git -C "$W" show "ba84014:engine/scripts/hooks/$hook" > "$H"
    echo " unwired:"; run "$H"
    git -C "$W" show "HEAD:engine/scripts/hooks/$hook" > "$H"
done
rm -rf "$S"
