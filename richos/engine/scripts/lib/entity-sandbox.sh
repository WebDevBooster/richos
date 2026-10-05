#!/usr/bin/env bash
#
# scripts/lib/entity-sandbox.sh — a governed entity root for a hook suite that is NOT the engine.
#
# A hook writes its runtime record under <entity>/.claude/state/ (acks, unparseable payloads,
# the return report's state). A suite that seats its hooks on the engine checkout itself
# (RICHOS_ENTITY_ROOT=<engine>) therefore writes into the engine's own state folder: in the merge
# gate that is the main checkout, which is the live plugin's audit record and an input of every
# engine check running beside the suite (2026-10-05, richos-hq
# docs/operations/2026-10-04-merge-check-speed.md, section 2). ci-shard.sh fails such a unit as
# STATE-WRITTEN. This makes the seat a suite should use instead.
#
#   . "$ENGINE_ROOT/scripts/lib/entity-sandbox.sh"
#   ENT="$(entity_sandbox "$ENGINE_ROOT")"            # the adoption only
#   ENT="$(entity_sandbox "$ENGINE_ROOT" --git)"      # and a git repository on `main`
#   RICHOS_ENTITY_ROOT="$ENT" "$HOOK" ...
#   rm -rf "$ENT"                                      # the caller removes it
#
# The sandbox holds a copy of the engine's adoption: orchestration.config and, when present,
# .claude/agents/ (the roster the spawn guards read model defaults from). With --git it is also a
# repository with one commit on `main`, for a hook or a registry that needs a real checkout with
# an integration branch. Its .claude/state/ is ignored there, as it is in the engine.

entity_sandbox() { # <engine-root> [--git] -> prints the new directory
    local engine="$1" dir
    dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/entity-sandbox.XXXXXX")" && pwd -P)" || return 1
    cp "$engine/orchestration.config" "$dir/orchestration.config" || return 1
    if [ -d "$engine/.claude/agents" ]; then
        mkdir -p "$dir/.claude" && cp -R "$engine/.claude/agents" "$dir/.claude/agents" || return 1
    fi
    if [ "${2:-}" = "--git" ]; then
        printf '/.claude/state/\n' > "$dir/.gitignore"
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir" init -q -b main || return 1
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir" add -A || return 1
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir" -c core.hooksPath=/dev/null \
            -c user.name="entity sandbox" -c user.email=entity-sandbox@example.invalid \
            commit -qm "the engine's adoption, for a hook suite" || return 1
    fi
    printf '%s\n' "$dir"
}
