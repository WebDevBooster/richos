#!/usr/bin/env bash
#
# locate-engine.sh — answer "where is the engine?" for a caller that is NOT a hook.
#
# THE PROBLEM THIS SOLVES, and why it did not exist before now.
#
#   A HOOK always knows where the engine is: the host sets $CLAUDE_PLUGIN_ROOT
#   for it, and the two-root contract (scripts/lib/resolve-roots.sh) takes it
#   from there. Nothing else does. An ENTITY's own scripts — an install-fresh
#   pipeline, a freshness verifier, a CI step — run as plain shell, get no
#   $CLAUDE_PLUGIN_ROOT, and under a by-reference engine have no relative path
#   to it either, because the engine is not in their repository any more.
#
#   The first two adopters never hit this: neither had an entity script that
#   called an engine asset. The third does, and its calls are load-bearing —
#   its device-install pipeline runs the integrity probe and ABORTS if the hooks
#   are not wired. Delete the entity's local copy of the probe with no way to
#   find the engine's, and that abort silently becomes a no-op: the exact
#   "a defense reports on while protecting nothing" failure this migration
#   exists to remove, introduced BY the migration.
#
# RESOLUTION ORDER. Each candidate is accepted only if it actually looks like
# this engine (carries scripts/hooks/ AND VERSION), so a stale pointer at a
# directory that is no longer an engine is rejected rather than returned.
#
#   1. $RICHOS_ENGINE_ROOT     — explicit, and EXCLUSIVE: if it is set and does
#                                not resolve, this FAILS rather than falling
#                                through. Falling through would silently use an
#                                engine nobody named.
#   2. $CLAUDE_PLUGIN_ROOT     — set when a hook happens to call this.
#   3. the operator registration — ~/.claude/settings.json enabledPlugins ->
#                                extraKnownMarketplaces -> marketplace manifest
#                                -> plugin source. AUTHORITATIVE: this is the
#                                chain the HOST itself walks, so it names the
#                                bytes actually being run. Same chain the probe's
#                                BR6 layer audits.
#   4. ~/.claude/richos-engine — a symlink minted by scripts/hooks/install.sh.
#                                Last, deliberately: it is a cache of (3), and a
#                                cache that outranked its source could point at
#                                a moved engine forever. BR6 asserts it agrees
#                                with (3), so a stale one is a probe failure.
#
# USAGE
#   As a command (prints the engine root, exit 0; prints nothing, exit 1 if it
#   cannot resolve — the diagnosis goes to stderr):
#       ENGINE="$(<engine>/scripts/locate-engine.sh)" || exit 1
#
#   Sourced (sets RICHOS_ENGINE_ROOT_LOCATED, returns 0/1):
#       . <engine>/scripts/locate-engine.sh && richos_locate_engine
#
#   THE BOOTSTRAP PROBLEM, stated plainly: an entity cannot source this file
#   without already knowing where the engine is. That is unavoidable, and it is
#   why candidate 4 exists — an adopter's own bootstrap is two lines
#   ($RICHOS_ENGINE_ROOT, then ~/.claude/richos-engine) with NO chain logic of
#   its own to drift, and everything richer lives here, in one place, tested.
#   An adopter bootstrap MUST fail loud when both are absent. Skipping the
#   engine call is never the right answer.

# CLAUDE_CONFIG_DIR is the host's own override for where ~/.claude lives.
# Candidates 3 and 4 BOTH read from it, so an operator who moved their config —
# or a test that sandboxed it — gets a consistent answer rather than one
# candidate reading the sandbox and the other reading the real machine.
richos_engine_config_dir() {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

richos_engine_looks_valid() { # <path>
    [ -n "${1:-}" ] || return 1
    [ -d "$1/scripts/hooks" ] || return 1
    [ -f "$1/VERSION" ] || return 1
    return 0
}

# richos_locate_engine — sets RICHOS_ENGINE_ROOT_LOCATED and RICHOS_ENGINE_SOURCE.
# Returns 0 on success, 1 on failure (with a named reason on stderr).
richos_locate_engine() {
    RICHOS_ENGINE_ROOT_LOCATED=""
    RICHOS_ENGINE_SOURCE=""
    local cand=""

    # 1. explicit, and EXCLUSIVE
    if [ -n "${RICHOS_ENGINE_ROOT:-}" ]; then
        if richos_engine_looks_valid "$RICHOS_ENGINE_ROOT"; then
            RICHOS_ENGINE_ROOT_LOCATED="$(cd "$RICHOS_ENGINE_ROOT" && pwd -P)"
            RICHOS_ENGINE_SOURCE="RICHOS_ENGINE_ROOT"
            return 0
        fi
        echo "locate-engine: RICHOS_ENGINE_ROOT is set to '$RICHOS_ENGINE_ROOT' but that is not an engine (needs scripts/hooks/ and VERSION). Refusing to fall through to another engine nobody named." >&2
        return 1
    fi

    # 2. a hook's own plugin root
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && richos_engine_looks_valid "$CLAUDE_PLUGIN_ROOT"; then
        RICHOS_ENGINE_ROOT_LOCATED="$(cd "$CLAUDE_PLUGIN_ROOT" && pwd -P)"
        RICHOS_ENGINE_SOURCE="CLAUDE_PLUGIN_ROOT"
        return 0
    fi

    # 3. the operator registration — what the HOST actually loads
    if command -v python3 >/dev/null 2>&1; then
        cand="$(RICHOS_CFG_DIR="$(richos_engine_config_dir)" python3 - <<'PY' 2>/dev/null
import json, os, sys

cfgdir = os.environ.get("RICHOS_CFG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
cfg = os.path.join(cfgdir, "settings.json")


def load(p):
    try:
        with open(p, encoding="utf-8") as h:
            return json.load(h)
    except Exception:
        return None


settings = load(cfg) or {}
enabled = settings.get("enabledPlugins") or {}
# Keys are "<plugin>@<marketplace>"; we want ours, enabled.
market = None
for key, on in enabled.items():
    if not on or "@" not in key:
        continue
    plugin, mkt = key.rsplit("@", 1)
    if plugin == "richos-engine":
        market = mkt
        break
if not market:
    sys.exit(0)

src = ((settings.get("extraKnownMarketplaces") or {}).get(market) or {}).get("source") or {}
mroot = src.get("path")
if not mroot:
    known = load(os.path.join(cfgdir, "plugins", "known_marketplaces.json")) or {}
    entry = known.get(market) or {}
    mroot = entry.get("path") or ((entry.get("source") or {}).get("path"))
if not mroot:
    sys.exit(0)

manifest = load(os.path.join(mroot, ".claude-plugin", "marketplace.json")) or {}
for p in manifest.get("plugins") or []:
    if p.get("name") == "richos-engine":
        s = p.get("source")
        s = s if isinstance(s, str) else (s or {}).get("path", "")
        if s:
            print(os.path.normpath(os.path.join(mroot, s)))
        break
PY
)"
        if richos_engine_looks_valid "$cand"; then
            RICHOS_ENGINE_ROOT_LOCATED="$(cd "$cand" && pwd -P)"
            RICHOS_ENGINE_SOURCE="operator-registration"
            return 0
        fi
    fi

    # 4. the pointer minted by install.sh
    cand="$(richos_engine_config_dir)/richos-engine"
    if richos_engine_looks_valid "$cand"; then
        RICHOS_ENGINE_ROOT_LOCATED="$(cd "$cand" && pwd -P)"
        RICHOS_ENGINE_SOURCE="install-pointer"
        return 0
    fi

    {
        echo "locate-engine: COULD NOT FIND THE RICHOS ENGINE."
        echo "  Tried, in order:"
        echo "    RICHOS_ENGINE_ROOT      (unset)"
        echo "    CLAUDE_PLUGIN_ROOT      (unset or not an engine)"
        echo "    operator registration   ($(richos_engine_config_dir)/settings.json enabledPlugins -> marketplace -> plugin source)"
        echo "    $(richos_engine_config_dir)/richos-engine (absent or not an engine)"
        echo ""
        echo "  This is not a warning to work around. An entity script that cannot"
        echo "  find the engine cannot run the engine's checks, and skipping them"
        echo "  silently is the failure this contract exists to prevent."
        echo ""
        echo "  Fix: enable the plugin for this operator, then run the engine's"
        echo "  installer once so the pointer exists:"
        echo "    <engine>/scripts/hooks/install.sh"
        echo "  or export RICHOS_ENGINE_ROOT=<engine> for this invocation."
    } >&2
    return 1
}

# Executed directly rather than sourced -> print the answer.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if richos_locate_engine; then
        printf '%s\n' "$RICHOS_ENGINE_ROOT_LOCATED"
        exit 0
    fi
    exit 1
fi
