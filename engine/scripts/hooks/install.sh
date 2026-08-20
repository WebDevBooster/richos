#!/usr/bin/env bash
#
# install.sh — establish the SINGLE canonical hook-registration source and
#               refresh the hook content-hash manifests.
#
# CANONICAL SOURCE (single-registration root-fix): hooks are registered in
# exactly ONE file, `.claude/settings.local.json` (committed, force-added — see
# .gitignore). It carries every hook stanza using `$CLAUDE_PROJECT_DIR` as the
# repo-root placeholder, which Claude Code expands when it runs the hook
# command — so the committed file wires enforcement on a fresh clone with ZERO
# install step. (This kit keeps the `.sha256` manifest sidecars gitignored and
# regenerated here, so a fresh clone still runs install.sh once to mint the
# sidecars the integrity probe's Layer B/C/K hashing needs.)
#
# THE DOUBLE-FIRE BUG THIS SCRIPT NOW PREVENTS: the PRE-fix install.sh wrote a
# SECOND settings file, `.claude/settings.json` (gitignored), holding a
# $CLAUDE_PROJECT_DIR-resolved COPY of the very same hook stanzas. Claude Code
# reads BOTH files and MERGES their hook arrays additively — so every hook fired
# TWICE per matching tool event (two byte-identical resume-acks.log lines; the
# sibling append-loggers doubled identically). Since $CLAUDE_PROJECT_DIR
# expansion makes the resolved copy redundant, this script no longer generates
# hook stanzas into settings.json at all.
#
# WHAT THIS SCRIPT DOES NOW:
#   1. VALIDATE the canonical source carries the two critical non-hook config
#      keys (env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1",
#      worktree.baseRef == "head") — refuse loudly if either is missing, never
#      proceed on a broken source (the "ghost team" incident; probe Layers I/J
#      re-check this independently).
#   2. MIGRATE / DE-DUPLICATE: if a stale `.claude/settings.json` exists, strip
#      its `hooks` key. If the hook-stripped remainder is a pure duplicate of
#      `.claude/settings.local.json` (minus hooks) — the state the old install.sh
#      produced — REMOVE settings.json entirely. If it carries genuine machine-
#      specific non-hook keys, keep the hook-stripped remainder so no operator
#      config is lost. Either way, settings.json ends up with NO hook stanzas.
#   3. REFRESH MANIFESTS: regenerate the `<hook>.sh.sha256` content sidecars
#      from the current on-disk hooks (the probe's Layer B/C/K/P/Q compare live
#      hooks against these).
#
# Idempotent. Re-running converges: an old duplicated settings.json is removed
# on the first run and stays absent on every subsequent run. The operator
# re-runs this at land time as the migration path. Run via:
#
#   scripts/hooks/install.sh
#
# Exit codes:
#   0  migration (or no-op) succeeded
#   1  unexpected error
#   2  canonical `.claude/settings.local.json` missing/unreadable or missing a
#      critical config key

set -eo pipefail

# The $CLAUDE_PROJECT_DIR substitution below shells out to python3's json
# module (no `|| true` guard — under `set -e` a missing interpreter already
# aborts the script with a raw "command not found"). Check explicitly up
# front so the failure is a clear, actionable message instead of a bare
# shell error.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: install.sh: python3 is required (JSON generation + sha256 fallback) — refusing" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SOURCE="$REPO_ROOT/.claude/settings.local.json"
TARGET="$REPO_ROOT/.claude/settings.json"

if [ ! -r "$SOURCE" ]; then
    echo "ERROR: source settings file missing: $SOURCE" >&2
    echo "       (this script requires .claude/settings.local.json — the committed source-of-truth)" >&2
    exit 2
fi

# --- Validate the canonical source's critical non-hook config ------------
# Two keys in settings.local.json are as load-bearing as any hook —
# env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS ("1", without it the orchestrator
# sees/spawns ZERO teammates at the next session start with no error shown — a
# real recorded incident) and worktree.baseRef ("head", which the worktree-
# isolation doctrine assumes). Refuse to proceed if the source is missing
# either — never migrate/refresh on a broken source. (contract-integrity-
# probe.sh Layers I/J re-check this on every probe run, independent of
# install.sh, so drift introduced by hand-editing AFTER an install is caught.)
python3 - "$SOURCE" <<'PY'
import json, sys
src_path = sys.argv[1]
with open(src_path, "r", encoding="utf-8") as f:
    data = json.load(f)

def get_path(d, dotted):
    cur = d
    for k in dotted.split("."):
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur

problems = []
teams_flag = get_path(data, "env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")
if teams_flag != "1":
    problems.append("env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS missing or not \"1\" (got: %r)" % (teams_flag,))
base_ref = get_path(data, "worktree.baseRef")
if base_ref != "head":
    problems.append("worktree.baseRef missing or not \"head\" (got: %r)" % (base_ref,))
if problems:
    sys.stderr.write("ERROR: install.sh: refusing to proceed — "
                      ".claude/settings.local.json is missing critical config:\n")
    for p in problems:
        sys.stderr.write("  - %s\n" % p)
    sys.stderr.write("Restore both keys in .claude/settings.local.json (see README.md's "
                      "\"Critical configuration\" section), then re-run install.sh.\n")
    sys.exit(2)
PY

# --- Migrate / de-duplicate settings.json --------------------------------
# settings.json is gitignored and, post-fix, must NEVER carry hook stanzas.
# The Python below decides the outcome and prints a one-word action so the
# shell can log it:
#   removed  — file existed, hook-stripped remainder was a pure duplicate of
#              settings.local.json (minus hooks); file deleted.
#   stripped — file existed with machine-specific non-hook keys; hooks removed,
#              remainder written back.
#   absent   — no settings.json to migrate (already single-source).
ACTION="$(python3 - "$SOURCE" "$TARGET" "$REPO_ROOT" <<'PY'
import json, os, sys

src_path, tgt_path, repo_root = sys.argv[1:4]

def resolve(obj):
    """Resolve $CLAUDE_PROJECT_DIR placeholders so a resolved settings.json
    remainder compares equal to the placeholder-carrying source."""
    if isinstance(obj, dict):
        return {k: resolve(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve(v) for v in obj]
    if isinstance(obj, str):
        return obj.replace("$CLAUDE_PROJECT_DIR", repo_root) \
                  .replace("${CLAUDE_PROJECT_DIR}", repo_root)
    return obj

if not os.path.exists(tgt_path):
    print("absent")
    sys.exit(0)

try:
    with open(tgt_path, "r", encoding="utf-8") as f:
        target = json.load(f)
except Exception:
    # Unreadable/garbage settings.json: remove it so the canonical source
    # is unambiguously the only settings file.
    os.remove(tgt_path)
    print("removed")
    sys.exit(0)

with open(src_path, "r", encoding="utf-8") as f:
    source = json.load(f)

# Hook-stripped views of both files, placeholder-resolved.
target_nohooks = resolve({k: v for k, v in target.items() if k != "hooks"})
source_nohooks = resolve({k: v for k, v in source.items() if k != "hooks"})

if target_nohooks == source_nohooks:
    # Pure duplicate of the canonical source — nothing unique here. Remove it
    # so settings.local.json is the sole settings file (clean single source).
    os.remove(tgt_path)
    print("removed")
else:
    # Genuine machine-specific non-hook config present — preserve it, but
    # drop every hook stanza so nothing double-fires.
    tmp = tgt_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(target_nohooks, f, indent=2)
        f.write("\n")
    os.replace(tmp, tgt_path)
    print("stripped")
PY
)"

case "$ACTION" in
    removed)
        echo "✓ migrated: removed stale hook-duplicating .claude/settings.json (hooks are canonical in settings.local.json)" ;;
    stripped)
        echo "✓ migrated: stripped hook stanzas from .claude/settings.json, kept machine-specific non-hook config" ;;
    absent)
        echo "✓ no settings.json to migrate — settings.local.json is the sole settings file" ;;
    *)
        echo "ERROR: settings.json migration returned unexpected action: '$ACTION'" >&2
        exit 1 ;;
esac

# Refresh the content-hash manifests for the canonical hook scripts. The
# integrity probe's Layer B/C/K compares the live hook file's sha256 against
# the value stored in its .sha256 sidecar. Regenerating here (from the current
# on-disk source) keeps the sidecars in sync whenever the operator runs
# install.sh. Scope covers every wired hook (the PreToolUse Agent chain, the
# write-guard, the PreToolUse Bash main-write guard, the secrets scanner, the
# PreToolUse SendMessage resume-guard, the PostToolUse Agent detector, and the
# idle/completed loggers), plus the definition-drift PAIR (the PreToolUse[Agent]
# guard and its SessionStart snapshotter) and the SessionStart worktree-reaper
# CHAIN.
#
# One entry is NOT under scripts/hooks/: scripts/reap-stale-worktrees.sh. The
# SessionStart wrapper is a thin shim, but the reaper it invokes with --execute
# is the only hook-reachable code in the kit that DELETES things (worktrees and
# branches). Hashing only the wrapper would be integrity theatre, so the reaper
# gets a sidecar too and probe Layer Q verifies BOTH.
HOOK_FILES=(
    "$REPO_ROOT/scripts/hooks/guard-worktree-isolation.sh"
    "$REPO_ROOT/scripts/hooks/guard-definition-drift.sh"
    "$REPO_ROOT/scripts/hooks/snapshot-agent-definitions.sh"
    "$REPO_ROOT/scripts/hooks/reader-teammate-hint.sh"
    "$REPO_ROOT/scripts/hooks/verify-agent-prompt.sh"
    "$REPO_ROOT/scripts/hooks/guard-main-checkout-writes.sh"
    "$REPO_ROOT/scripts/hooks/guard-bash-main-writes.sh"
    "$REPO_ROOT/scripts/hooks/scan-secrets.sh"
    "$REPO_ROOT/scripts/hooks/guard-resume-isolation.sh"
    "$REPO_ROOT/scripts/hooks/detect-nonnative-worktree.sh"
    "$REPO_ROOT/scripts/hooks/teammate-idle-handoff.sh"
    "$REPO_ROOT/scripts/hooks/task-completed-handoff.sh"
    "$REPO_ROOT/scripts/hooks/session-start-reap-worktrees.sh"
    "$REPO_ROOT/scripts/reap-stale-worktrees.sh"
)
for f in "${HOOK_FILES[@]}"; do
    [ -f "$f" ] || continue
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}' > "$f.sha256"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}' > "$f.sha256"
    else
        python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$f" > "$f.sha256"
    fi
done
echo "✓ refreshed hook sha256 manifests"
exit 0
