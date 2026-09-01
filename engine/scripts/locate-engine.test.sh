#!/usr/bin/env bash
#
# locate-engine.test.sh — the engine locator, positive and negative.
#
# Every case runs against a SANDBOXED CLAUDE_CONFIG_DIR, never the operator's
# real one. That is not tidiness: an earlier draft of install.sh wrote its
# pointer to the real $HOME/.claude while a suite exercised a throwaway engine,
# and repointed this machine's live pointer at a temp directory that was deleted
# seconds later. The variable exists because that happened.
#
# Cases:
#   1a  RICHOS_ENGINE_ROOT wins, and reports its source
#   1b  RICHOS_ENGINE_ROOT set to a NON-engine FAILS — it must never fall
#       through to an engine nobody named (the EXCLUSIVE rule)
#   1c  ...and specifically does not fall through even when a perfectly good
#       registration is present (the negative arm 1b needs to mean anything)
#   2a  CLAUDE_PLUGIN_ROOT is used when it looks like an engine
#   2b  CLAUDE_PLUGIN_ROOT pointing at a NON-engine is skipped, not fatal
#       (another plugin's root can legitimately be there)
#   3a  the operator registration resolves, and OUTRANKS the pointer
#   3b  a registration whose plugin is DISABLED does not resolve
#   3c  a registration naming a DIFFERENT marketplace does not resolve
#   4a  the pointer resolves when nothing else does
#   4b  a STALE pointer (target is no longer an engine) is rejected
#   5a  nothing available at all -> exit 1 with a NAMED diagnosis, never a
#       silent empty string a caller could mistake for a path
#   5b  ...and the diagnosis says what to run
#   6a  install.sh mints the pointer into CLAUDE_CONFIG_DIR
#   6b  install.sh does NOT clobber a non-symlink file an operator put there
#   6d  install.sh run from a LINKED GIT WORKTREE leaves an existing pointer
#       ALONE — and still does everything else it was run for
#   6e  ...and --force-engine-pointer is the deliberate way through
#   6f  an unrecognized argument is REFUSED (exit 2), never ignored

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT_REAL="$(cd "$SRC_DIR/.." && pwd)"
LOCATOR="$SRC_DIR/locate-engine.sh"

TMP="$(mktemp -d -t locate-engine.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Snapshot the REAL operator global state BEFORE anything runs, so case 6c can
# prove the suite left it alone rather than assert that it meant to. Taken
# through scripts/lib/global-state-witness.sh — one definition of "what a run
# may not leave moved", shared with demo.test.sh and by-reference.test.sh.
REAL_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REAL_STATE_BEFORE=""
if [ -f "$ENGINE_ROOT_REAL/scripts/lib/global-state-witness.sh" ]; then
    # shellcheck source=./lib/global-state-witness.sh
    . "$ENGINE_ROOT_REAL/scripts/lib/global-state-witness.sh"
    REAL_STATE_BEFORE="$(richos_global_snapshot)"
fi

PASS=0
FAIL=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

# A directory that LOOKS like an engine (the locator's validity test is
# scripts/hooks/ + VERSION).
make_fake_engine() { # <dir>
    mkdir -p "$1/scripts/hooks"
    printf '9.9.9\n' > "$1/VERSION"
}

FAKE_A="$TMP/engineA"; make_fake_engine "$FAKE_A"
FAKE_B="$TMP/engineB"; make_fake_engine "$FAKE_B"
NOTENGINE="$TMP/not-an-engine"; mkdir -p "$NOTENGINE"

# A sandboxed config dir carrying a complete, working registration for engineA.
CFG="$TMP/cfg"
mkdir -p "$CFG/plugins" "$TMP/marketplace/.claude-plugin"
cat > "$TMP/marketplace/.claude-plugin/marketplace.json" <<JSON
{"name":"richos-local","plugins":[{"name":"richos-engine","source":"./engineA"}]}
JSON
# The manifest's source is relative to the marketplace root, so the engine has
# to live there. Move engineA under it.
rm -rf "$TMP/marketplace/engineA"
cp -R "$FAKE_A" "$TMP/marketplace/engineA"
REG_ENGINE="$TMP/marketplace/engineA"
cat > "$CFG/settings.json" <<JSON
{"extraKnownMarketplaces":{"richos-local":{"source":{"source":"directory","path":"$TMP/marketplace"}}},
 "enabledPlugins":{"richos-engine@richos-local":true}}
JSON

# run <expected-exit> <expected-stdout-or-empty> -- <env assignments...>
locate() { env "$@" bash "$LOCATOR" 2>/dev/null; }

echo "=== locate-engine ==="

# 1a
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG" RICHOS_ENGINE_ROOT="$FAKE_B")"
[ "$OUT" = "$(cd "$FAKE_B" && pwd -P)" ] && ok "1a RICHOS_ENGINE_ROOT wins" || bad "1a RICHOS_ENGINE_ROOT wins" "got '$OUT'"

# 1b / 1c — EXCLUSIVE: a bad explicit root fails, even with a good registration
# sitting right there. 1c is what makes 1b evidence rather than a coincidence.
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG" RICHOS_ENGINE_ROOT="$NOTENGINE")"; RC=$?
[ "$RC" -ne 0 ] && ok "1b a bad RICHOS_ENGINE_ROOT FAILS" || bad "1b a bad RICHOS_ENGINE_ROOT FAILS" "rc=$RC"
[ -z "$OUT" ] && ok "1c ...and prints nothing (no fall-through to the registration)" || bad "1c ...and prints nothing" "got '$OUT'"

# 2a / 2b
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$FAKE_B")"
[ "$OUT" = "$(cd "$FAKE_B" && pwd -P)" ] && ok "2a CLAUDE_PLUGIN_ROOT is used" || bad "2a CLAUDE_PLUGIN_ROOT is used" "got '$OUT'"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$NOTENGINE")"
[ "$OUT" = "$(cd "$REG_ENGINE" && pwd -P)" ] && ok "2b a non-engine CLAUDE_PLUGIN_ROOT is SKIPPED, not fatal" || bad "2b a non-engine CLAUDE_PLUGIN_ROOT is skipped" "got '$OUT'"

# 3a — registration resolves, and OUTRANKS a pointer aimed elsewhere.
ln -sfn "$FAKE_B" "$CFG/richos-engine"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG")"
[ "$OUT" = "$(cd "$REG_ENGINE" && pwd -P)" ] && ok "3a the registration resolves AND outranks the pointer" || bad "3a registration outranks pointer" "got '$OUT'"

# 3b — plugin present but disabled.
CFG2="$TMP/cfg-disabled"; mkdir -p "$CFG2"
sed 's/"richos-engine@richos-local":true/"richos-engine@richos-local":false/' "$CFG/settings.json" > "$CFG2/settings.json"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG2")"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "3b a DISABLED plugin does not resolve" || bad "3b disabled plugin resolves anyway" "rc=$RC out='$OUT'"

# 3c — enabled, but under a marketplace this operator does not know.
CFG3="$TMP/cfg-othermkt"; mkdir -p "$CFG3"
sed 's/richos-engine@richos-local/richos-engine@somewhere-else/' "$CFG/settings.json" > "$CFG3/settings.json"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG3")"; RC=$?
[ "$RC" -ne 0 ] && ok "3c an unknown marketplace does not resolve" || bad "3c unknown marketplace resolved" "out='$OUT'"

# 4a — pointer only.
CFG4="$TMP/cfg-pointeronly"; mkdir -p "$CFG4"
ln -sfn "$FAKE_B" "$CFG4/richos-engine"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG4")"
[ "$OUT" = "$(cd "$FAKE_B" && pwd -P)" ] && ok "4a the pointer resolves when nothing else does" || bad "4a pointer resolves" "got '$OUT'"

# 4b — STALE pointer: the target exists but is no longer an engine.
CFG5="$TMP/cfg-stale"; mkdir -p "$CFG5"
ln -sfn "$NOTENGINE" "$CFG5/richos-engine"
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG5")"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok "4b a STALE pointer is REJECTED, not returned" || bad "4b stale pointer returned" "rc=$RC out='$OUT'"

# 5a / 5b — nothing at all.
CFG6="$TMP/cfg-empty"; mkdir -p "$CFG6"
ERR="$(env CLAUDE_CONFIG_DIR="$CFG6" bash "$LOCATOR" 2>&1 >/dev/null)"; RC=$?
OUT="$(locate CLAUDE_CONFIG_DIR="$CFG6")"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then
    ok "5a nothing resolvable -> exit 1 and EMPTY stdout"
else
    bad "5a nothing resolvable" "rc=$RC out='$OUT'"
fi
printf '%s' "$ERR" | grep -qF 'install.sh' && ok "5b ...and the diagnosis names the command to run" || bad "5b diagnosis names install.sh"

echo ""
echo "=== install.sh: the pointer ==="

# 6a — a real installer run against a throwaway engine COPY, with a sandboxed
# config dir. A copy, not a stub: a stubbed installer could pass while the
# shipped one fails.
INST_ENGINE="$TMP/inst-engine"
mkdir -p "$INST_ENGINE"
cp -R "$ENGINE_ROOT_REAL/scripts" "$INST_ENGINE/scripts"
cp "$ENGINE_ROOT_REAL/VERSION" "$INST_ENGINE/VERSION"
mkdir -p "$INST_ENGINE/.claude"
cp "$ENGINE_ROOT_REAL/.claude/settings.local.json" "$INST_ENGINE/.claude/settings.local.json"
# THE REGISTRATION SURFACE IS PART OF THE FIXTURE, and this line is why 6a was
# red. install.sh no longer takes its sidecar-minting scope from a typed list;
# it DERIVES it from hooks/hooks.json through scripts/lib/registered-hooks.sh,
# and exits 2 rather than minting a guessed subset. This fixture copied
# scripts/ and VERSION only, so the installer correctly refused it and no
# pointer was ever minted — a fixture defect wearing the costume of a locator
# defect. (scripts/demo.sh built its sample repo the same way and broke the
# same day, in front of buyers.)
mkdir -p "$INST_ENGINE/hooks"
cp "$ENGINE_ROOT_REAL/hooks/hooks.json" "$INST_ENGINE/hooks/hooks.json"
CFG7="$TMP/cfg-install"; mkdir -p "$CFG7"
env CLAUDE_CONFIG_DIR="$CFG7" bash "$INST_ENGINE/scripts/hooks/install.sh" >/dev/null 2>&1
if [ -L "$CFG7/richos-engine" ] && [ "$(cd "$CFG7/richos-engine" && pwd -P)" = "$(cd "$INST_ENGINE" && pwd -P)" ]; then
    ok "6a install.sh mints the pointer into CLAUDE_CONFIG_DIR"
else
    bad "6a install.sh mints the pointer" "$(ls -l "$CFG7/richos-engine" 2>&1 | head -1)"
fi

# 6b — an operator's own regular file at that path is NOT replaced.
CFG8="$TMP/cfg-occupied"; mkdir -p "$CFG8"
printf 'operator data\n' > "$CFG8/richos-engine"
env CLAUDE_CONFIG_DIR="$CFG8" bash "$INST_ENGINE/scripts/hooks/install.sh" >/dev/null 2>&1
if [ -f "$CFG8/richos-engine" ] && [ ! -L "$CFG8/richos-engine" ] \
   && grep -qF 'operator data' "$CFG8/richos-engine"; then
    ok "6b install.sh does NOT clobber a non-symlink file at that path"
else
    bad "6b install.sh clobbered an operator file"
fi

# ---------------------------------------------------------------------------
# 6d/6e/6f — THE LINKED-WORKTREE POINTER FOOTGUN.
#
# install.sh repoints ~/.claude/richos-engine at whatever checkout it runs from.
# That is right from a real checkout and wrong from a linked worktree: the
# worktree is removed at land time, and the operator's machine-wide pointer is
# left dangling — a state BR6b reports as a hard failure to whoever probes next,
# long after the person who caused it has gone.
#
# It happened here. An engineer ran the installer inside his worktree while
# testing something unrelated and silently repointed this machine's live engine
# at it; he restored it only because he happened to check afterwards. These
# cases exist so nobody has to happen to check.
#
# The topology is built for real — git clone, then git worktree add — because
# the detection is git's own (private --git-dir != shared --git-common-dir) and
# a faked directory layout would not exercise it.
# ---------------------------------------------------------------------------
WT_MAIN="$TMP/wt-main"
git init -q -b main "$WT_MAIN" >/dev/null 2>&1
mkdir -p "$WT_MAIN/scripts"
cp -R "$ENGINE_ROOT_REAL/scripts/hooks" "$WT_MAIN/scripts/hooks"
cp -R "$ENGINE_ROOT_REAL/scripts/lib" "$WT_MAIN/scripts/lib"
cp "$ENGINE_ROOT_REAL/scripts/reap-stale-worktrees.sh" "$WT_MAIN/scripts/"
cp "$ENGINE_ROOT_REAL/scripts/remove-agent-worktree.sh" "$WT_MAIN/scripts/"
cp "$ENGINE_ROOT_REAL/VERSION" "$WT_MAIN/VERSION"
mkdir -p "$WT_MAIN/hooks" "$WT_MAIN/.claude"
cp "$ENGINE_ROOT_REAL/hooks/hooks.json" "$WT_MAIN/hooks/hooks.json"
cp "$ENGINE_ROOT_REAL/.claude/settings.local.json" "$WT_MAIN/.claude/settings.local.json"
git -C "$WT_MAIN" config user.name "engine tests" >/dev/null 2>&1
if [ -z "$(git -C "$WT_MAIN" config user.email 2>/dev/null)" ]; then
    git -C "$WT_MAIN" config user.email "tests@example.com" >/dev/null 2>&1
fi
git -C "$WT_MAIN" add -A >/dev/null 2>&1
git -C "$WT_MAIN" add -f .claude/settings.local.json >/dev/null 2>&1
git -C "$WT_MAIN" commit -q -m "engine" >/dev/null 2>&1
git -C "$WT_MAIN" worktree add -q "$TMP/wt-linked" -b linked HEAD >/dev/null 2>&1
WT_LINKED="$TMP/wt-linked"

if [ ! -d "$WT_LINKED/scripts/hooks" ]; then
    bad "6d linked-worktree fixture" "git worktree add did not produce $WT_LINKED"
else
    CFG9="$TMP/cfg-worktree"; mkdir -p "$CFG9"
    # Pre-seed a pointer at the MAIN checkout. The assertion is that an existing,
    # correct pointer SURVIVES — strictly stronger than "no pointer was created",
    # which an installer that simply crashed would also satisfy.
    ln -sfn "$WT_MAIN" "$CFG9/richos-engine"
    WT_OUT="$(env CLAUDE_CONFIG_DIR="$CFG9" bash "$WT_LINKED/scripts/hooks/install.sh" 2>&1)"
    WT_RC=$?
    WT_PTR="$(readlink "$CFG9/richos-engine" 2>/dev/null || true)"
    WT_SIDECARS="$(ls "$WT_LINKED"/scripts/hooks/*.sha256 2>/dev/null | wc -l | tr -d ' ')"

    # Three assertions in one case, because any one alone would pass for the
    # wrong reason: the pointer survived, the run still SUCCEEDED, and the work
    # the operator actually ran it for still happened. An installer that refused
    # outright would satisfy the first and fail the other two — and breaking the
    # normal path is a worse outcome than the footgun.
    if [ "$WT_PTR" = "$WT_MAIN" ] && [ "$WT_RC" -eq 0 ] && [ "$WT_SIDECARS" -gt 0 ]; then
        ok "6d install.sh from a LINKED WORKTREE leaves the pointer alone, exits 0, and still mints $WT_SIDECARS sidecars"
    else
        bad "6d install.sh from a linked worktree" "ptr='$WT_PTR' want='$WT_MAIN' rc=$WT_RC sidecars=$WT_SIDECARS"
    fi

    # The skip must be ANNOUNCED. A silent skip is its own defect: an operator
    # who meant to repoint would walk away believing they had.
    if printf '%s' "$WT_OUT" | grep -qF 'LINKED GIT WORKTREE' \
       && printf '%s' "$WT_OUT" | grep -qF -- '--force-engine-pointer'; then
        ok "6d' ...and says so, naming the escape hatch"
    else
        bad "6d' the worktree skip was silent or unexplained" "$(printf '%s' "$WT_OUT" | tail -3 | tr '\n' ' ')"
    fi

    # 6e — the deliberate opt-in still works, from the same worktree.
    env CLAUDE_CONFIG_DIR="$CFG9" bash "$WT_LINKED/scripts/hooks/install.sh" --force-engine-pointer >/dev/null 2>&1
    FORCED_PTR="$(readlink "$CFG9/richos-engine" 2>/dev/null || true)"
    if [ "$FORCED_PTR" = "$WT_LINKED" ]; then
        ok "6e --force-engine-pointer repoints from a worktree anyway (deliberate, auditable)"
    else
        bad "6e --force-engine-pointer did not repoint" "ptr='$FORCED_PTR' want='$WT_LINKED'"
    fi

    # 6f — a typo must not be silently ignored. An installer that swallowed
    # '--force-enginepointer' would hand back a green run and none of the effect.
    env CLAUDE_CONFIG_DIR="$CFG9" bash "$WT_LINKED/scripts/hooks/install.sh" --force-enginepointer >/dev/null 2>&1
    BADARG_RC=$?
    if [ "$BADARG_RC" -eq 2 ]; then
        ok "6f an unrecognized argument is refused with exit 2, not ignored"
    else
        bad "6f unrecognized argument was not refused" "rc=$BADARG_RC (expected 2)"
    fi

    # 6g — the POSITIVE control for 6d. Without it, 6d passes on any installer
    # that stopped minting pointers at all, and the suite would be green over a
    # feature that no longer exists. The SAME installer, same sandboxed config
    # dir, run from the MAIN checkout, must still repoint.
    CFG10="$TMP/cfg-mainckt"; mkdir -p "$CFG10"
    env CLAUDE_CONFIG_DIR="$CFG10" bash "$WT_MAIN/scripts/hooks/install.sh" >/dev/null 2>&1
    MAIN_PTR="$(readlink "$CFG10/richos-engine" 2>/dev/null || true)"
    if [ "$MAIN_PTR" = "$WT_MAIN" ]; then
        ok "6g POSITIVE CONTROL: the same installer from the MAIN checkout still repoints normally"
    else
        bad "6g the normal repoint path is BROKEN" "ptr='$MAIN_PTR' want='$WT_MAIN'"
    fi
fi

# 6c — the REAL operator config dir was not touched by any case above. This is
# the assertion the suite exists to be able to make: the leak it guards against
# actually happened once, and a suite that merely intends to sandbox is not
# evidence that it did.
#
# Asked through scripts/lib/global-state-witness.sh rather than by hand. This
# file and demo.test.sh had two hand-rolled copies of the same check, and two
# copies of a check is how one of them ends up watching the wrong thing —
# neither of them, for instance, would have noticed the pointer being DELETED
# rather than repointed, because `readlink` prints nothing for both.
if [ -f "$ENGINE_ROOT_REAL/scripts/lib/global-state-witness.sh" ]; then
    # shellcheck source=./lib/global-state-witness.sh
    . "$ENGINE_ROOT_REAL/scripts/lib/global-state-witness.sh"
    if richos_global_verify "$REAL_STATE_BEFORE" 2>/dev/null; then
        ok "6c the REAL $REAL_CFG_DIR global state is byte-identical before and after"
    else
        bad "6c THE SUITE MUTATED THE OPERATOR'S GLOBAL STATE" "$(richos_global_verify "$REAL_STATE_BEFORE" 2>&1 | tr '\n' ' ')"
    fi
else
    bad "6c the global-state witness is missing" "scripts/lib/global-state-witness.sh"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== locate-engine tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== locate-engine tests: all $PASS passed ==="
