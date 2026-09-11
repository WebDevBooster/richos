#!/usr/bin/env bash
#
# install-retire-reconciler.test.sh — install.sh takes the retired nightly
# reconciler (com.richos.worktree-reconciler) OFF launchd and never leaves it
# running quietly.
#
# Until 2026-09-11 install.sh SCHEDULED that job; it deleted worktrees every
# night. The CEO's workspace spec (docs/plans/worktree-spec-2026-09-11.md) has
# two deleters, land and discard, and the reconciler is not on the page, so the
# installer now removes it. What this suite proves, in a sandbox only:
#
#   R1  a plist present in the (redirected) LaunchAgents directory is deleted
#   R2  no plist: nothing to do, the install still succeeds, and says nothing
#   R3  a plist that cannot be deleted FAILS the install, naming the job
#   R4  a redirected HOME never reaches launchctl (a shim proves no call was made)
#   R5  the plist directory redirect is honored: a plist beside the real one's
#       name under the FAKE home is untouched when RICHOS_LAUNCH_AGENTS_DIR
#       points elsewhere
#
# Every run uses a copied engine, a fake HOME and a sandboxed CLAUDE_CONFIG_DIR;
# the operator's launchd and config directory are never in play.
#
# Run directly: scripts/hooks/install-retire-reconciler.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SCRATCH="$(cd "$(mktemp -d -t install-retire.XXXXXX)" && pwd -P)"
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

echo "=== install.sh retires the nightly reconciler ==="

# A whole engine in a temp directory, as global-state-witness.test.sh builds it.
EPH="$SCRATCH/eph-engine"
mkdir -p "$EPH/.claude" "$EPH/hooks"
cp -R "$ENGINE_ROOT/scripts" "$EPH/scripts"
cp "$ENGINE_ROOT/VERSION" "$EPH/VERSION"
cp "$ENGINE_ROOT/.claude/settings.local.json" "$EPH/.claude/settings.local.json"
cp "$ENGINE_ROOT/hooks/hooks.json" "$EPH/hooks/hooks.json"

FAKEHOME="$SCRATCH/home"
mkdir -p "$FAKEHOME/.claude"
CFG="$SCRATCH/cfg"
mkdir -p "$CFG"
AGENTS="$SCRATCH/LaunchAgents"
mkdir -p "$AGENTS"
PLIST="$AGENTS/com.richos.worktree-reconciler.plist"

# launchctl is SHIMMED for every run: a red run must not be able to reach the
# operator's launchd.
SHIM="$SCRATCH/shim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${LAUNCHCTL_SHIM_LOG:?}"\nexit 0\n' >"$SHIM/launchctl"
chmod +x "$SHIM/launchctl"
SHIMLOG="$SCRATCH/launchctl.log"

install_run() { # [env...] -> OUT, RC
    OUT="$(env HOME="$FAKEHOME" CLAUDE_CONFIG_DIR="$CFG" PATH="$SHIM:$PATH" LAUNCHCTL_SHIM_LOG="$SHIMLOG" \
               "$@" bash "$EPH/scripts/hooks/install.sh" 2>&1)"
    RC=$?
}

# R1 — present, redirected directory: deleted, and said so.
printf '<plist/>\n' >"$PLIST"
install_run RICHOS_LAUNCH_AGENTS_DIR="$AGENTS"
if [ "$RC" -eq 0 ] && [ ! -e "$PLIST" ] && printf '%s' "$OUT" | grep -qF 'retired reconciler plist removed'; then
    ok "R1 a present plist is deleted, and the install says so"
else
    bad "R1 present plist" "rc=$RC plist=$([ -e "$PLIST" ] && echo present || echo gone) out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# R2 — absent: nothing to do, success, no claim of a removal.
install_run RICHOS_LAUNCH_AGENTS_DIR="$AGENTS"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qF 'retired reconciler plist removed'; then
    ok "R2 no plist: the install succeeds and claims no removal"
else
    bad "R2 absent plist" "rc=$RC"
fi

# R3 — cannot be deleted: the install FAILS and names the job. A read-only
# directory makes the unlink fail for an ordinary user (root is exempt).
if [ "$(id -u)" -ne 0 ]; then
    printf '<plist/>\n' >"$PLIST"
    chmod 555 "$AGENTS"
    install_run RICHOS_LAUNCH_AGENTS_DIR="$AGENTS"
    chmod 755 "$AGENTS"
    if [ "$RC" -ne 0 ] && [ -e "$PLIST" ] && printf '%s' "$OUT" | grep -qF 'the retired nightly reconciler is still installed'; then
        ok "R3 a plist that cannot be deleted FAILS the install, naming the job"
    else
        bad "R3 undeletable plist" "rc=$RC plist=$([ -e "$PLIST" ] && echo present || echo gone)"
    fi
    rm -f "$PLIST"
else
    ok "R3 skipped under root, where a read-only directory does not stop an unlink (stated, not assumed)"
fi

# R4 — a redirected HOME without the directory redirect: launchctl is never called.
: >"$SHIMLOG"
install_run
if [ "$RC" -eq 0 ] && [ ! -s "$SHIMLOG" ]; then
    ok "R4 a redirected HOME never reaches launchctl (the shim's log is empty)"
else
    bad "R4 redirected HOME" "rc=$RC launchctl calls: $(tr '\n' ';' <"$SHIMLOG" 2>/dev/null)"
fi

# R5 — the directory redirect is honored: the fake home's own LaunchAgents is untouched.
mkdir -p "$FAKEHOME/Library/LaunchAgents"
printf '<plist/>\n' >"$FAKEHOME/Library/LaunchAgents/com.richos.worktree-reconciler.plist"
install_run RICHOS_LAUNCH_AGENTS_DIR="$AGENTS"
if [ "$RC" -eq 0 ] && [ -e "$FAKEHOME/Library/LaunchAgents/com.richos.worktree-reconciler.plist" ]; then
    ok "R5 with RICHOS_LAUNCH_AGENTS_DIR set, only that directory is touched"
else
    bad "R5 redirect honored" "rc=$RC"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== install-retire-reconciler: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== install-retire-reconciler: all $PASS passed ==="
exit 0
