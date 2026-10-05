#!/usr/bin/env bash
#
# scripts/lib/by-reference-fixture.sh — the shared setup of the by-reference suites: the
# negative controls for contract-integrity-probe.sh's BY-REFERENCE layer set (BR1..BR10,
# including BR6b). Sourced by scripts/hooks/by-reference.test.sh and by-reference-2/-3/-4.test.sh.
#
# WHY FOUR SUITES (2026-10-05). The undivided suite ran 457 s (median of 12 merge-gate runs,
# max 599 s) against the gate's 600 s cap per check, so under load it timed out (4 timeouts in
# 2 trees) and set the floor of every hook-touching merge (richos-hq
# docs/operations/2026-10-04-merge-check-speed.md, sections 3 and 4). Its cases are independent
# (each makes its own sandbox and removes it), so they are divided by line range into four
# suites of about a quarter each; nothing in a case changed. Each suite takes the operator's
# global-state snapshot at its start and verifies it at its end (case 10), as the whole did.
#
# What the setup does, and why, is unchanged; read on.

# Drain predicate input before returning. grep -q can close its pipe early and
# turn a successful match into SIGPIPE from printf under pipefail. The
# redirected grep predicates below keep the same patterns without that race.

SRC_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
FAIL_NAMES=()

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# The launching session's own environment must not leak in as a candidate root.
unset CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT

# This suite runs the real install.sh against ~10 throwaway sandboxes. Each call
# threads CLAUDE_CONFIG_DIR into the sandbox — but INTENDING to sandbox is not
# evidence of having sandboxed, and the one time that intention slipped, the
# operator's pointer spent an hour aimed at a deleted fixture and a double-
# clicked RichOS reported NO COMPUTE LEASE. Snapshot now, verify at the end.
STATE_BEFORE=""
if [ -f "$SRC_ENGINE/scripts/lib/global-state-witness.sh" ]; then
    # shellcheck source=../lib/global-state-witness.sh
    . "$SRC_ENGINE/scripts/lib/global-state-witness.sh"
    STATE_BEFORE="$(richos_global_snapshot)"
fi

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
# <sb>/                      marketplace root (git repo)
#   .claude-plugin/marketplace.json
#   engine/                  ENGINE_ROOT — a real engine, by reference
#   home/.claude/...         the operator-scope registration BR6 reads
# <sb>/entity/               ENTITY_ROOT — a different, adopted repository
#
# entity/ lives INSIDE the marketplace repo purely for convenience; it carries
# its own orchestration.config, which is what makes it an adopted root, and the
# probe is always told about it explicitly via RICHOS_ENTITY_ROOT.
make_sandbox() {
    local sb
    sb="$(cd "$(mktemp -d -t byref.XXXXXX)" && pwd -P)"

    mkdir -p "$sb/engine" "$sb/entity/.claude/agents" "$sb/home/.claude/plugins" "$sb/.claude-plugin"

    cp -R "$SRC_ENGINE/scripts"        "$sb/engine/scripts"
    cp -R "$SRC_ENGINE/mega-lander" "$sb/engine/mega-lander"
    cp -R "$SRC_ENGINE/ass-kicker" "$sb/engine/ass-kicker"
    cp -R "$SRC_ENGINE/.claude"        "$sb/engine/.claude"
    cp -R "$SRC_ENGINE/.claude-plugin" "$sb/engine/.claude-plugin"
    cp -R "$SRC_ENGINE/hooks"          "$sb/engine/hooks"
    cp "$SRC_ENGINE/orchestration.config" "$sb/engine/orchestration.config"
    cp "$SRC_ENGINE/VERSION" "$sb/engine/VERSION" 2>/dev/null || printf '0.0.0-test\n' >"$sb/engine/VERSION"

    # The entity's config is deliberately DIFFERENT from the engine's, so a
    # layer that read the wrong one would be visible rather than plausible.
    cat >"$sb/entity/orchestration.config" <<'CFG'
PROTECTED_PATHS="src"
READONLY_ALLOWLIST="Explore Plan"
ALLOWED_MODELS="opus sonnet haiku"
# Declared, and DIFFERENT from the engine's (no fable), for the same reason
# ALLOWED_MODELS is: Layer MT reads the ENTITY's declaration, and a layer that
# read the engine's would be visible here rather than plausible.
MODEL_TIERS="opus > sonnet > haiku"
CREATOR_TEAMMATE="dean"
CFG
    printf -- '---\nname: mark\nmodel: opus\n---\nentity roster body\n' \
        >"$sb/entity/.claude/agents/mark.md"

    # The entity's OWN settings file. Under a by-reference engine it carries no
    # guard registrations — the plugin supplies those — but it still carries the
    # two critical project-scope config keys BR10 audits, and any project-scope
    # hooks the entity keeps. A sandbox without it would make BR10's baseline red.
    cat >"$sb/entity/.claude/settings.local.json" <<'ENTCFG'
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "worktree": { "baseRef": "head" }
}
ENTCFG

    cat >"$sb/.claude-plugin/marketplace.json" <<'MKT'
{
  "name": "sandbox-local",
  "owner": { "name": "test" },
  "plugins": [
    { "name": "richos-engine", "source": "./engine" }
  ]
}
MKT

    # The operator-scope registration, exactly as the host writes it.
    cat >"$sb/home/.claude/settings.json" <<JSON
{
  "enabledPlugins": { "richos-engine@sandbox-local": true },
  "extraKnownMarketplaces": {
    "sandbox-local": { "source": { "source": "directory", "path": "$sb" } }
  }
}
JSON
    cat >"$sb/home/.claude/plugins/known_marketplaces.json" <<JSON
{
  "sandbox-local": {
    "source": { "source": "directory", "path": "$sb" },
    "installLocation": "$sb"
  }
}
JSON

    # Mint the engine's sidecars, so BR4's tamper check has a baseline to
    # compare against (and so its "did not run" warning is not the default) —
    # and the entity-facing engine pointer BR6b audits, which the same installer
    # mints. CLAUDE_CONFIG_DIR keeps it inside the sandbox: without it the
    # installer would repoint the REAL operator's pointer at a temp directory
    # this function deletes moments later. That leak was observed, once, and it
    # is why the variable is threaded through the installer and the locator.
    RICHOS_ENTITY_ROOT="$sb/engine" CLAUDE_CONFIG_DIR="$sb/home/.claude" \
        "$sb/engine/scripts/hooks/install.sh" >/dev/null 2>&1

    # BR7's subject is "does this reach the next clone?", so the sandbox has to
    # be a real repository with a real commit.
    git -C "$sb" init -q -b main >/dev/null 2>&1
    git -C "$sb" add -A >/dev/null 2>&1
    git -C "$sb" commit -q -m "sandbox" >/dev/null 2>&1

    printf '%s\n' "$sb"
}

# run_probe <sandbox> -> stdout+stderr in OUT, exit code in RC
OUT=""
RC=0
run_probe() {
    local sb="$1"
    set +e
    OUT="$(HOME="$sb/home" CLAUDE_CONFIG_DIR="$sb/home/.claude" RICHOS_ENTITY_ROOT="$sb/entity" \
        "$sb/engine/scripts/hooks/contract-integrity-probe.sh" 2>&1)"
    RC=$?
    set -e
}

# Assertion helpers. `layer_failed BR2` is true when a ✗ line names that layer.
# The layer token is anchored on the whitespace that precedes it, so asking
# about layer "A" cannot be satisfied by an "A." buried in another layer's
# prose. A loose pattern here would quietly make these assertions unfalsifiable.
layer_failed() { printf '%s\n' "$OUT" | grep >/dev/null "✗.*[[:space:]]$1\." ; }
layer_passed() { printf '%s\n' "$OUT" | grep >/dev/null "✓.*[[:space:]]$1\." ; }
layer_warned() { printf '%s\n' "$OUT" | grep >/dev/null "⚠.*[[:space:]]$1\." ; }
out_has()      { printf '%s\n' "$OUT" | grep -F >/dev/null "$1" ; }

# expect_only_layer_failed <case> <layer> [substring]
#
# The three-part assertion: verdict flipped, the NAMED layer is the one that
# caught it, and (when given) it caught it for the stated REASON rather than
# incidentally.
expect_only_layer_failed() {
    local name="$1" layer="$2" substr="${3:-}"
    if [ "$RC" -ne 2 ]; then
        bad "$name" "probe exit was $RC, expected 2"
        return
    fi
    if ! layer_failed "$layer"; then
        bad "$name" "$layer did not report ✗ (some other layer may have absorbed the mutation)"
        return
    fi
    if [ -n "$substr" ] && ! out_has "$substr"; then
        bad "$name" "$layer failed, but not for the stated reason (missing: $substr)"
        return
    fi
    ok "$name"
}


# by_reference_finish <suite name> — case 10 and the verdict, for one suite.
by_reference_finish() {
    # ---------------------------------------------------------------------------
    # The suite gives back what it borrowed — asserted, not intended.
    if [ -z "$STATE_BEFORE" ]; then
        bad "10.global-state-witness-present" "scripts/lib/global-state-witness.sh is missing, so nothing checked what this suite left behind"
    elif richos_global_verify "$STATE_BEFORE" 2>/dev/null; then
        ok "10.the-operator-global-state-is-unchanged-by-this-suite"
    else
        bad "10.the-operator-global-state-is-unchanged-by-this-suite" "$(richos_global_verify "$STATE_BEFORE" 2>&1 | tr '\n' ' ')"
    fi

    # ---------------------------------------------------------------------------
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        echo "=== $1: all $PASS passed ==="
        exit 0
    fi
    echo "=== $1: $PASS passed, $FAIL FAILED ==="
    for n in "${FAIL_NAMES[@]}"; do echo "    - $n"; done
    exit 1
}
