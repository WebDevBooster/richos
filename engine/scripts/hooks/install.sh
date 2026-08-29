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
# install step. (The engine keeps the `.sha256` manifest sidecars gitignored and
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
#   4. MINT THE ENGINE POINTER (~/.claude/richos-engine), unless this checkout
#      is a LINKED GIT WORKTREE — see the pointer section at the bottom for why
#      that one step, and only that step, is withheld there.
#
# Idempotent. Re-running converges: an old duplicated settings.json is removed
# on the first run and stays absent on every subsequent run. The operator
# re-runs this at land time as the migration path. Run via:
#
#   scripts/hooks/install.sh [--force-engine-pointer]
#
#   --force-engine-pointer   mint the engine pointer even from a linked git
#                            worktree. Deliberate, auditable, and almost never
#                            what you want; the pointer section explains.
#
# Exit codes:
#   0  migration (or no-op) succeeded
#   1  unexpected error
#   2  canonical `.claude/settings.local.json` missing/unreadable or missing a
#      critical config key, or an unrecognised command-line argument

set -eo pipefail

# The $CLAUDE_PROJECT_DIR substitution below shells out to python3's json
# module (no `|| true` guard — under `set -e` a missing interpreter already
# aborts the script with a raw "command not found"). Check explicitly up
# front so the failure is a clear, actionable message instead of a bare
# shell error.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: install.sh: python3 is required (JSON generation + sha256 fallback) — refusing" >&2; exit 2; }

# --- Arguments -----------------------------------------------------------
# This script took none until the engine-pointer footgun below needed a
# deliberate, auditable opt-in. Unknown arguments are REFUSED rather than
# ignored: a typo'd --force-engine-pointer that silently did nothing would
# hand the operator a green run and none of the effect they asked for.
FORCE_ENGINE_POINTER=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force-engine-pointer)
            FORCE_ENGINE_POINTER=1 ;;
        *)
            echo "ERROR: install.sh: unrecognised argument '$1'. Usage: install.sh [--force-engine-pointer]" >&2
            exit 2 ;;
    esac
    shift
done

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
# install.sh. Scope is EVERY hook the engine registers — enumerated below from
# hooks/hooks.json rather than described here, because a prose list of "which
# hooks" is a stale inventory with extra steps. (This paragraph used to carry
# such a list, and it had already drifted: it said "two entries are not under
# scripts/hooks/" while three were.)
#
# Three managed files are NOT hooks and appear in no hook table, so they are
# named explicitly further down: the worktree reaper, its sanctioned removal
# helper, and the root-resolution contract. The SessionStart reaper wrapper is
# a thin shim, but the reaper it invokes with --execute is the only
# hook-reachable code in the engine that DELETES things (worktrees and
# branches). Hashing only the wrapper would be integrity theatre, so the reaper
# gets a sidecar too and probe Layer Q verifies BOTH.
# THE hooks/ HALF OF THIS LIST IS DERIVED, NEVER TYPED.
#
# It used to be sixteen hand-written paths, and it was the THIRD copy of "the
# set of guards" in this engine. The first two both went stale within two days
# of each other (13/13 and 14/14 in the session banner, over a guard that was
# wired, present, executable and firing), which is all the evidence needed that
# a fourth reader maintaining its own copy would eventually skip a guard's
# sidecar and leave its tamper check silently not running.
#
# So it comes from hooks/hooks.json — the same registration surface the session
# banner and the probe's BR2 derive from — via the one shared parser.
# Consequence: wiring a seventeenth guard mints its sidecar with no edit here.
_RH_LIB="$REPO_ROOT/scripts/lib/registered-hooks.sh"
[ -f "$_RH_LIB" ] || { echo "ERROR: install.sh: $_RH_LIB is missing — cannot determine which hooks to hash, and hashing a guessed subset would leave real guards with no tamper check. Refusing." >&2; exit 2; }
# shellcheck source=../lib/registered-hooks.sh
. "$_RH_LIB"
# Fail loud, never skip: an unreadable hook table here means an unknown guard
# set, and minting "the sidecars we could work out" is precisely the silent
# partial success this engine refuses everywhere else.
if ! _REGISTERED_HOOKS="$(registered_hook_scripts "$REPO_ROOT/hooks/hooks.json")"; then
    echo "ERROR: install.sh: could not derive the managed hook set from $REPO_ROOT/hooks/hooks.json (missing, unreadable, or registering nothing). Refusing rather than minting an incomplete set of sidecars." >&2
    exit 2
fi

HOOK_FILES=()
while IFS= read -r _h; do
    [ -n "$_h" ] || continue
    HOOK_FILES+=("$REPO_ROOT/scripts/hooks/$_h")
done <<REGISTERED_EOF
$_REGISTERED_HOOKS
REGISTERED_EOF

# The managed files that are NOT hooks, and therefore appear in no hook table.
# These stay explicit because there is no registration surface to derive them
# from — each is here for a reason stated at its own line.
HOOK_FILES+=(
    "$REPO_ROOT/scripts/reap-stale-worktrees.sh"
    # Not a hook either, and hashed for the same reason as the reaper: it is the
    # OTHER piece of engine code that DELETES worktrees, and it is the escape
    # route guard-worktree-removal.sh points every blocked operator at. The two
    # ship as a pair; hashing the guard while leaving its sanctioned helper
    # unverified would check the lock and ignore the key.
    "$REPO_ROOT/scripts/remove-agent-worktree.sh"
    # Not a hook, and hashed anyway. Every guard's bootstrap refuses to start
    # without scripts/lib/resolve-roots.sh, and every guard's answer to "which
    # repository am I protecting?" comes out of it. An unhashed resolver would
    # make the single most consequential file in the mechanical layer the only
    # one nobody verifies — the same argument that puts the reaper on this list.
    "$REPO_ROOT/scripts/lib/resolve-roots.sh"
    # The publication-boundary predicate, in both its halves. Not hooks, and
    # hashed for the reaper's reason: TWO registered guards
    # (guard-publication-writes.sh, guard-publication-commits.sh) delegate
    # their entire decision to these two files. Hashing the guards while
    # leaving the thing that actually decides unverified would check the lock
    # and ignore the key — the same sentence that put remove-agent-worktree.sh
    # on this list.
    "$REPO_ROOT/scripts/lib/publication-boundary.sh"
    "$REPO_ROOT/scripts/lib/publication-boundary.py"
    # The CEO-queue predicate, in both its halves — same argument again:
    # guard-ceo-queue-commits.sh delegates its entire decision to these two
    # files, so hashing the guard and leaving the thing that decides unverified
    # would check the lock and ignore the key.
    "$REPO_ROOT/scripts/lib/ceo-queue.sh"
    "$REPO_ROOT/scripts/lib/ceo-queue.py"
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

# --- Mint the entity-facing engine pointer --------------------------------
# A HOOK is told where the engine is ($CLAUDE_PLUGIN_ROOT). An ENTITY's own
# scripts are not, and under a by-reference engine they have no relative path to
# it either — so an install-fresh pipeline or a CI step that must run the
# integrity probe has nothing to call. scripts/locate-engine.sh is the full
# answer; this symlink is the two-line bootstrap an adopter can use before it
# can source anything.
#
# It is a CACHE of the operator registration, never the source of truth: the
# locator consults the registration FIRST and this only as a fallback, and the
# probe's BR6 layer asserts the two agree, so a pointer left behind by a moved
# engine is a probe failure rather than a silent wrong answer.
#
# Best-effort by design: a machine with no writable ~/.claude is not a broken
# install, and this must never be the reason an installer fails.
#
# CLAUDE_CONFIG_DIR is honoured (the host's own override for where ~/.claude
# lives), and it is what lets a test sandbox its HOME properly: without it, a
# suite that runs this installer against a throwaway engine would repoint the
# REAL operator's pointer at a temp directory that is deleted seconds later.
# Observed, in this repo, before the variable was threaded through.
#
# AND IT IS WITHHELD FROM A LINKED GIT WORKTREE. This is the one step in the
# script whose blast radius is the OPERATOR'S WHOLE MACHINE rather than this
# checkout: every entity on the box, in every repository, follows this one
# symlink. A linked worktree is the exact opposite — per-agent, ephemeral,
# removed by the lander minutes later. Aiming a durable machine-wide pointer at
# an ephemeral directory is never what anyone intended, and it is INVISIBLE at
# the moment it happens: the installer prints a cheerful "✓ engine pointer ->"
# either way, and nothing goes wrong until the worktree is reaped and the next
# probe run reports BR6b DANGLING to whoever happens to be sitting there.
#
# MEASURED, on this machine: an engineer ran this installer inside his worktree
# while testing something unrelated and silently repointed the operator's live
# engine at it. He noticed only because he happened to look afterwards. Nobody
# should have to happen to look.
#
# WHY SKIP RATHER THAN REFUSE THE WHOLE RUN. Everything else install.sh does is
# repo-local and entirely correct inside a worktree — validating the config,
# migrating a stale settings.json, and above all minting the .sha256 sidecars
# the integrity probe needs to pass there. That is the REASON to run it in a
# worktree, and it is a routine part of an engineer's loop. Refusing the whole
# script would break a normal path to close an abnormal one, which trades down.
# So the dangerous half is withheld and the useful half runs untouched.
#
# WHY SKIP RATHER THAN WARN. A warning is what this already effectively was:
# the damage was done, printed among a dozen other lines, and caught only by
# somebody looking for it. A warning that fires after the irreversible act is
# an obituary, not a guard.
#
# --force-engine-pointer is the deliberate escape hatch, because there is a
# legitimate case (exercising pointer behaviour itself) and because an opt-in
# flag leaves a record in shell history that an env var or a silent default
# does not.
#
# Detection is git's own definition of a linked worktree — a private --git-dir
# that differs from the shared --git-common-dir — not a path heuristic. If git
# is absent, or this is not a checkout at all (a vendored engine copy, a test
# sandbox), the answer is "not a worktree" and behaviour is byte-identical to
# before this paragraph existed.
POINTER_IN_WORKTREE=0
POINTER_MAIN_HINT=""
if [ "$FORCE_ENGINE_POINTER" -ne 1 ]; then
    _PTR_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    _PTR_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$_PTR_GIT_DIR" ] && [ -n "$_PTR_GIT_COMMON" ] && [ "$_PTR_GIT_DIR" != "$_PTR_GIT_COMMON" ]; then
        POINTER_IN_WORKTREE=1
        # Name the exact path to run instead, rather than "the main checkout":
        # the parent of the shared .git is the main checkout root, and this
        # engine's offset inside the worktree is its offset inside the twin.
        _PTR_MAIN_TOP="$(dirname "$_PTR_GIT_COMMON")"
        _PTR_WT_TOP="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --show-toplevel 2>/dev/null || true)"
        if [ -n "$_PTR_WT_TOP" ] && [ "${REPO_ROOT#"$_PTR_WT_TOP"}" != "$REPO_ROOT" ]; then
            POINTER_MAIN_HINT="$_PTR_MAIN_TOP${REPO_ROOT#"$_PTR_WT_TOP"}"
        else
            POINTER_MAIN_HINT="$_PTR_MAIN_TOP"
        fi
    fi
fi

ENGINE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENGINE_POINTER="$ENGINE_CONFIG_DIR/richos-engine"
if [ "$POINTER_IN_WORKTREE" -eq 1 ]; then
    echo "NOTE: engine pointer SKIPPED — this checkout is a LINKED GIT WORKTREE:" >&2
    echo "        $REPO_ROOT" >&2
    echo "      $ENGINE_POINTER is unchanged, which is what you want: a worktree is removed at" >&2
    echo "      land time, and a pointer left aimed at a removed directory is a dangling symlink" >&2
    echo "      that probe layer BR6b reports as a hard failure to whoever runs it next." >&2
    echo "      Everything else in this run completed normally — config validation, settings.json" >&2
    echo "      migration and the .sha256 sidecars — which is what install.sh is for in a worktree." >&2
    if [ -n "$POINTER_MAIN_HINT" ]; then
        echo "      To repoint the operator's engine for real, run the installer from the main checkout:" >&2
        echo "        $POINTER_MAIN_HINT/scripts/hooks/install.sh" >&2
    fi
    echo "      To repoint from HERE anyway, deliberately:  install.sh --force-engine-pointer" >&2
elif mkdir -p "$ENGINE_CONFIG_DIR" 2>/dev/null; then
    if [ -L "$ENGINE_POINTER" ] || [ ! -e "$ENGINE_POINTER" ]; then
        if ln -sfn "$REPO_ROOT" "$ENGINE_POINTER" 2>/dev/null; then
            echo "✓ engine pointer -> $ENGINE_POINTER -> $REPO_ROOT"
        else
            echo "NOTE: could not write the engine pointer at $ENGINE_POINTER — entity scripts that locate the engine will fall back to the operator registration. (install.sh)" >&2
        fi
    else
        echo "NOTE: $ENGINE_POINTER exists and is NOT a symlink — leaving it alone rather than replacing an operator's file. Entity scripts will resolve the engine from the operator registration instead. (install.sh)" >&2
    fi
else
    echo "NOTE: could not create $ENGINE_CONFIG_DIR — engine pointer not minted. (install.sh)" >&2
fi
exit 0
