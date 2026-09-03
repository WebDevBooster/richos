#!/usr/bin/env bash
#
# install-reconciler-schedule.test.sh — install.sh writes the launchd
# definition for the persistent reconciler, and never from a place that could
# aim a machine-wide schedule at a directory that goes away.
#
# What is proven: with RICHOS_LAUNCH_AGENTS_DIR set (a test), the plist is
# written there, names the reconciler, the interval from orchestration.config
# and --quiet, and launchctl is not invoked; from an EPHEMERAL checkout with no
# redirect, nothing is written and the note says why; the plist parses.
#
# Run directly: scripts/hooks/install-reconciler-schedule.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t install-sched.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A REAL engine copy (the installer derives its hook set from hooks.json and
# refuses on a broken settings source).
ENG="$SANDBOX/engine"
mkdir -p "$ENG/.claude"
cp -R "$ENGINE_ROOT/scripts" "$ENG/scripts"
cp -R "$ENGINE_ROOT/hooks" "$ENG/hooks"
cp "$ENGINE_ROOT/orchestration.config" "$ENG/orchestration.config"
cp "$ENGINE_ROOT/.claude/settings.local.json" "$ENG/.claude/"
cp "$ENGINE_ROOT/VERSION" "$ENG/VERSION" 2>/dev/null || printf '0.0.0-test\n' >"$ENG/VERSION"
find "$ENG" -name '*.sha256' -delete
export CLAUDE_CONFIG_DIR="$SANDBOX/config"   # never the operator's real ~/.claude

echo "=== install.sh schedules the reconciler ==="

# 1. redirected plist directory: written, not loaded
LA="$SANDBOX/LaunchAgents"
OUT="$(RICHOS_LAUNCH_AGENTS_DIR="$LA" "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
PLIST="$LA/com.richos.worktree-reconciler.plist"
[ "$RC" -eq 0 ] && [ -f "$PLIST" ] && ok "S01  install.sh exits 0 and writes the plist into RICHOS_LAUNCH_AGENTS_DIR" || bad "S01  rc=$RC plist=$([ -f "$PLIST" ] && echo yes || echo no): ${OUT:0:200}"
printf '%s' "$OUT" | grep -q 'reconciler plist written (not loaded' && ok "S02  ...and says it was NOT loaded (a redirected directory is a test)" || bad "S02  out=${OUT:0:200}"
grep -q "<string>$ENG/scripts/reconcile-terminal-worktrees.py</string>" "$PLIST" 2>/dev/null && ok "S03  the plist names THIS engine's reconciler" || bad "S03  reconciler path"
grep -q '<string>--quiet</string>' "$PLIST" && grep -q '<string>--max-seconds</string>' "$PLIST" && ok "S04  the plist passes --quiet and a --max-seconds budget" || bad "S04  args"
INTERVAL="$(sed -n 's/^RECONCILE_INTERVAL_SECONDS=\([0-9]*\).*/\1/p' "$ENG/orchestration.config" | head -1)"
grep -q "<integer>$INTERVAL</integer>" "$PLIST" && ok "S05  StartInterval is RECONCILE_INTERVAL_SECONDS from orchestration.config ($INTERVAL)" || bad "S05  interval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST" && ok "S06  RunAtLoad is set (a reboot resumes cleanup without a session)" || bad "S06  RunAtLoad"
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null 2>&1 && ok "S07  the plist parses (plutil -lint)" || bad "S07  plutil rejected the plist"
else
    python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$PLIST" 2>/dev/null && ok "S07  the plist parses (plistlib)" || bad "S07  plist unparseable"
fi
grep -q "<string>com.richos.worktree-reconciler</string>" "$PLIST" && ok "S08  Label is com.richos.worktree-reconciler" || bad "S08  label"

# 2. a changed interval is honored
python3 - "$ENG/orchestration.config" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"^RECONCILE_INTERVAL_SECONDS=\d+", "RECONCILE_INTERVAL_SECONDS=42", s, flags=re.M)
open(p, "w").write(s)
PY
RICHOS_LAUNCH_AGENTS_DIR="$LA" "$ENG/scripts/hooks/install.sh" >/dev/null 2>&1
grep -q '<integer>42</integer>' "$PLIST" && ok "S09  a changed RECONCILE_INTERVAL_SECONDS is written on re-install (idempotent, converges)" || bad "S09  interval not updated"

# 3. an EPHEMERAL checkout with no redirect: nothing written anywhere
rm -rf "$LA"
OUT="$("$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'reconciler NOT scheduled' && [ ! -e "$LA" ]; then
    ok "S10  from an ephemeral checkout with no redirect: exit 0, NOT scheduled, nothing written"
else
    bad "S10  rc=$RC out=${OUT:0:200}"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== install-reconciler-schedule tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== install-reconciler-schedule tests: all $PASS passed ==="
exit 0
