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

# 4. THE LEAK OF 2026-09-03. --force-engine-pointer is the POINTER's escape
# hatch, and install.sh computed the ephemeral/worktree facts only when it was
# off — so a forced run from a temp checkout with a faked HOME (exactly
# global-state-witness.test.sh case c4) fell through every withholding branch
# and ran a REAL `launchctl bootstrap gui/<uid>` on a plist inside the fake
# home. The job outlived the temp directory: gui/501/com.richos.worktree-
# reconciler, RunAtLoad, every 300s, program path already deleted, found by
# `launchctl list` on the operator's machine. Two rules follow, each asserted
# below: the force flag governs the pointer and NOTHING else, and a HOME that
# is not this account's passwd home is a test — gui/<uid> is per-account and
# reads nothing from $HOME. launchctl is SHIMMED for these cases, so a
# regression can never re-create the leak they exist to catch; that the shim is
# the launchctl which resolves is asserted too, or an empty log proves nothing.
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
cat >"$SHIM/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_SHIM_LOG:?}"
exit 0
SH
chmod +x "$SHIM/launchctl"
SHIMLOG="$SANDBOX/launchctl.log"
RESOLVED="$(env PATH="$SHIM:$PATH" bash -c 'command -v launchctl')"
FAKEHOME="$SANDBOX/home"; mkdir -p "$FAKEHOME/.claude"
FAKEPLIST="$FAKEHOME/Library/LaunchAgents/com.richos.worktree-reconciler.plist"
OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$FAKEHOME" PATH="$SHIM:$PATH" LAUNCHCTL_SHIM_LOG="$SHIMLOG" \
        bash "$ENG/scripts/hooks/install.sh" --force-engine-pointer 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'reconciler NOT scheduled' && [ ! -e "$FAKEPLIST" ]; then
    ok "S11  --force-engine-pointer from a temp checkout with a faked HOME: exit 0, NOT scheduled, no plist under the fake home"
else
    bad "S11  rc=$RC plist=$([ -e "$FAKEPLIST" ] && echo WRITTEN || echo absent) out=${OUT:0:300}"
fi
if [ "$RESOLVED" = "$SHIM/launchctl" ] && [ ! -s "$SHIMLOG" ]; then
    ok "S12  ...and launchctl was never invoked (the shim at $SHIM/launchctl is the one that resolves, and its log is empty)"
else
    bad "S12  resolved=$RESOLVED log=$(cat "$SHIMLOG" 2>/dev/null | tr '\n' ';')"
fi
printf '%s' "$OUT" | grep -q "not this account's home" && ok "S13  ...and the refusal names the faked HOME as the reason" || bad "S13  out=${OUT:0:300}"
[ -L "$FAKEHOME/.claude/richos-engine" ] && ok "S14  ...while the forced POINTER was still minted — the flag governs the pointer and nothing else" || bad "S14  the escape hatch must still mint the pointer"

# 5. the same force flag, the operator's real HOME, and the engine inside a
# LINKED GIT WORKTREE of a throwaway repository. The worktree fact comes from
# git alone (private --git-dir != shared --git-common-dir), so it is the one
# withholding wall that neither the fake-HOME wall nor the sandboxed-config
# wall can stand in for — which makes this the case that isolates the fix:
# the fact must be computed whether or not the pointer step was forced past it.
# (The ephemeral rule is deliberately narrow — it only fires when the config
# dir IS the real ~/.claude — so with this suite's sandboxed config dir it is
# the sandbox wall that would catch a forced temp checkout, and that proves
# nothing about the flag.)
WTREPO="$SANDBOX/wt-repo"
git init -q -b main "$WTREPO" 2>/dev/null
# The seed commit is made with plumbing (commit-tree + update-ref), which runs
# no hooks: a porcelain `git commit` here is refused on any machine whose
# global pre-commit identity guard rejects a throwaway author, and the case
# must not depend on what that machine's hooks think of a fixture.
WT_TREE="$(git -C "$WTREPO" hash-object -w -t tree /dev/null 2>/dev/null)"
WT_SEED="$(git -C "$WTREPO" -c user.name=t -c user.email=t@t commit-tree "$WT_TREE" -m seed 2>/dev/null)"
git -C "$WTREPO" update-ref refs/heads/main "$WT_SEED" 2>/dev/null
git -C "$WTREPO" worktree add -q -b linked "$SANDBOX/wt-linked" 2>/dev/null
ENG2="$SANDBOX/wt-linked/engine"
mkdir -p "$ENG2/.claude"
cp -R "$ENG/scripts" "$ENG2/scripts"; cp -R "$ENG/hooks" "$ENG2/hooks"
cp "$ENG/orchestration.config" "$ENG2/orchestration.config"; cp "$ENG/.claude/settings.local.json" "$ENG2/.claude/"; cp "$ENG/VERSION" "$ENG2/VERSION"
find "$ENG2" -name '*.sha256' -delete
: >"$SHIMLOG"
OUT="$(env PATH="$SHIM:$PATH" LAUNCHCTL_SHIM_LOG="$SHIMLOG" bash "$ENG2/scripts/hooks/install.sh" --force-engine-pointer 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ephemeral or a linked worktree' && [ ! -s "$SHIMLOG" ]; then
    ok "S15  --force-engine-pointer from a LINKED WORKTREE with the real HOME: the worktree fact is still computed, NOT scheduled, launchctl untouched"
else
    bad "S15  rc=$RC log=$(cat "$SHIMLOG" 2>/dev/null | tr '\n' ';') out=${OUT:0:300}"
fi
[ -L "$CLAUDE_CONFIG_DIR/richos-engine" ] && ok "S16  ...and the forced pointer was minted into the sandboxed config dir (positive control: the force did its own job)" || bad "S16  the escape hatch must still mint the pointer"

# 6. FAIL CLOSED (review 2026-09-03, blocker 7). Until this revision a plist
# that could not be written, a missing launchctl and a failed bootstrap all
# exited 0, the last with "load it by hand". A test label
# (com.richos.worktree-reconciler.test-<id>) with RICHOS_LAUNCH_AGENTS_DIR set
# is the one way through the withholding walls: it loads a LIVE job under a
# name that says what it is. launchctl is SHIMMED for the failure arms.
TL="com.richos.worktree-reconciler.test-$$"
FAILSHIM="$SANDBOX/failshim"; mkdir -p "$FAILSHIM"
LA2="$SANDBOX/LaunchAgents2"
cat >"$FAILSHIM/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_SHIM_LOG:?}"
case "$1" in bootstrap) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;; bootout) exit 0 ;; print) exit 113 ;; esac
exit 0
SH
chmod +x "$FAILSHIM/launchctl"
: >"$SHIMLOG"
OUT="$(env PATH="$FAILSHIM:$PATH" LAUNCHCTL_SHIM_LOG="$SHIMLOG" RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'install.sh: FAILED — the persistent reconciler is NOT scheduled' && printf '%s' "$OUT" | grep -q 'launchctl bootstrap' \
   && grep -q "^bootstrap gui/$(id -u) $LA2/$TL.plist" "$SHIMLOG" && ! printf '%s' "$OUT" | grep -qi 'by hand'; then
    ok "S17  launchctl bootstrap FAILS -> install.sh exits 1, names the failure, and never says 'load it by hand' (INVERTED: it used to exit 0)"
else
    bad "S17  rc=$RC log=$(tr '\n' ';' <"$SHIMLOG") out=${OUT:0:300}"
fi
cat >"$FAILSHIM/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_SHIM_LOG:?}"
case "$1" in print) echo "Could not find service" >&2; exit 113 ;; esac
exit 0
SH
: >"$SHIMLOG"
OUT="$(env PATH="$FAILSHIM:$PATH" LAUNCHCTL_SHIM_LOG="$SHIMLOG" RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'launchctl print .* failed after bootstrap'; then
    ok "S18  bootstrap 'succeeds' but launchctl print cannot find the job -> install.sh exits 1 (a load that cannot be verified is not a load)"
else
    bad "S18  rc=$RC out=${OUT:0:300}"
fi
cat >"$FAILSHIM/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in print) printf '%s\n' "gui/501/x = {" "  program = /usr/bin/python3" "  arguments = {" "    /usr/bin/python3" "    /somewhere/else/reconcile-terminal-worktrees.py" "  }" "}" ;; esac
exit 0
SH
OUT="$(env PATH="$FAILSHIM:$PATH" RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "does not name this checkout's reconciler"; then
    ok "S19  the loaded job names ANOTHER checkout's reconciler -> install.sh exits 1 (the job must point at the checkout that installed it)"
else
    bad "S19  rc=$RC out=${OUT:0:300}"
fi
NOLC="$SANDBOX/nolaunchctl"; mkdir -p "$NOLC"
for t in bash cat grep sed cut tr date mkdir git mktemp basename dirname rm ln awk sort uniq wc head tail env sleep python3 id uname mv cp chmod touch shasum find readlink pwd; do
    p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -sf "$p" "$NOLC/$t"
done
OUT="$(env PATH="$NOLC" RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'launchctl is not on PATH'; then
    ok "S20  launchctl unavailable -> install.sh exits 1 (INVERTED: it used to exit 0 with a note)"
else
    bad "S20  rc=$RC out=${OUT:0:300}"
fi
OUT="$(RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="com.evil.something" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'not a test label' && ok "S21  a custom label that is not a test label is refused outright (exit 1)" || bad "S21  rc=$RC out=${OUT:0:200}"

# 7. LIVE INSTALLATION (macOS only; the real launchctl, a real launchd job,
# under a test label, reconciling a SANDBOXED store; booted out at exit).
# This is the case the review asked for instead of a plist-serialization
# test: the job loads, `launchctl print` names this checkout's reconciler,
# the job RUNS (its heartbeat appears in the sandboxed store), a reinstall
# from a second checkout repoints it, and bootout removes it.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
    live_cleanup() { launchctl bootout "gui/$(id -u)/$TL" >/dev/null 2>&1 || true; }
    trap 'live_cleanup; rm -rf "$SANDBOX"' EXIT
    # hygiene: a test job a killed earlier run left behind is booted out first
    for stale in $(launchctl list 2>/dev/null | awk '{print $3}' | grep '^com\.richos\.worktree-reconciler\.test-' || true); do
        launchctl bootout "gui/$(id -u)/$stale" >/dev/null 2>&1 || true
    done
    LIVE_TX="$SANDBOX/live-tx"; LIVE_CAP="$SANDBOX/live-captures"
    OUT="$(RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" RICHOS_WORKTREE_TX_DIR="$LIVE_TX" RICHOS_WORKTREE_CAPTURE_DIR="$LIVE_CAP" bash "$ENG/scripts/hooks/install.sh" 2>&1)"; RC=$?
    PRINTED="$(launchctl print "gui/$(id -u)/$TL" 2>&1)"; PRC=$?
    if [ "$RC" -eq 0 ] && [ "$PRC" -eq 0 ] && printf '%s' "$PRINTED" | grep -qF "$ENG/scripts/reconcile-terminal-worktrees.py" && printf '%s' "$OUT" | grep -q 'verified with launchctl print'; then
        ok "S22  LIVE: install.sh loads a real launchd job under the test label and launchctl print names THIS checkout's reconciler"
    else
        bad "S22  rc=$RC print_rc=$PRC out=${OUT:0:200} printed=${PRINTED:0:200}"
    fi
    grep -q "<key>RICHOS_WORKTREE_TX_DIR</key><string>$LIVE_TX</string>" "$LA2/$TL.plist" && ok "S23  ...the plist carries the sandboxed store in EnvironmentVariables (the live job never touches ~/.claude/state)" || bad "S23  env block missing from $LA2/$TL.plist"
    ! grep -q '<key>EnvironmentVariables</key>' "$PLIST" && ok "S23b ...while the production-shaped plist from case 1 carries no EnvironmentVariables block" || bad "S23b production plist carries an env block"
    WAITED=0
    while [ ! -f "$LIVE_TX/last-run.json" ] && [ "$WAITED" -lt 30 ]; do sleep 1; WAITED=$((WAITED + 1)); done
    if [ -f "$LIVE_TX/last-run.json" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "--quiet" in d["argv"]' "$LIVE_TX/last-run.json" 2>/dev/null; then
        ok "S24  ...and the job RAN under launchd (RunAtLoad): the reconciler's heartbeat appeared in the sandboxed store after ${WAITED}s"
    else
        bad "S24  no heartbeat at $LIVE_TX/last-run.json after ${WAITED}s (log: $(tail -c 300 "$CLAUDE_CONFIG_DIR/state/worktree-reconciler.log" 2>/dev/null | tr '\n' ' '))"
    fi
    # reinstall from a SECOND checkout repoints the job: no manual command
    ENG3="$SANDBOX/engine-landed"; mkdir -p "$ENG3/.claude"
    cp -R "$ENG/scripts" "$ENG3/scripts"; cp -R "$ENG/hooks" "$ENG3/hooks"
    cp "$ENG/orchestration.config" "$ENG3/orchestration.config"; cp "$ENG/.claude/settings.local.json" "$ENG3/.claude/"; cp "$ENG/VERSION" "$ENG3/VERSION"
    find "$ENG3" -name '*.sha256' -delete
    OUT="$(RICHOS_LAUNCH_AGENTS_DIR="$LA2" RICHOS_LAUNCHD_LABEL="$TL" RICHOS_WORKTREE_TX_DIR="$LIVE_TX" RICHOS_WORKTREE_CAPTURE_DIR="$LIVE_CAP" bash "$ENG3/scripts/hooks/install.sh" 2>&1)"; RC=$?
    PRINTED="$(launchctl print "gui/$(id -u)/$TL" 2>&1)"
    if [ "$RC" -eq 0 ] && printf '%s' "$PRINTED" | grep -qF "$ENG3/scripts/reconcile-terminal-worktrees.py" && ! printf '%s' "$PRINTED" | grep -qF "$ENG/scripts/reconcile-terminal-worktrees.py"; then
        ok "S25  reinstalling from a second checkout REPOINTS the loaded job at it (bootout + bootstrap + verify; no manual command)"
    else
        bad "S25  rc=$RC printed=${PRINTED:0:300}"
    fi
    live_cleanup
    launchctl print "gui/$(id -u)/$TL" >/dev/null 2>&1 && bad "S26  the test job survived bootout" || ok "S26  ...and bootout removes it: launchctl print no longer finds the test job"
else
    printf '  SKIP  S22-S26 live launchd installation: macOS + launchctl required (host: %s)\n' "$(uname -s 2>/dev/null)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== install-reconciler-schedule tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== install-reconciler-schedule tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/install-reconciler-schedule.mutation.sh" ]; then
    bash "$SCRIPT_DIR/install-reconciler-schedule.mutation.sh" || exit 1
fi
exit 0
