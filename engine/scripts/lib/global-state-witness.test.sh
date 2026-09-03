#!/usr/bin/env bash
#
# global-state-witness.test.sh — the pointer nobody may leave moved.
#
# ===========================================================================
# WHAT THIS IS ABOUT
# ===========================================================================
# On 2026-09-01 `~/.claude/richos-engine` was found dangling at
# `.../scratchpad/g4/red/layerR` — a Layer R red-run fixture, deleted after the
# run that made it. Measured consequence: a double-clicked RichOS reported NO
# COMPUTE LEASE, having attached its lease through that pointer an hour before.
#
# The defect is not the dangling link. It is that a test could move a global
# pointer install.sh owns and leave it moved, and that the run reported success
# while it was wrong. Two halves, both tested here:
#
#   NEVER BORROW THE REAL ONE  — install.sh REFUSES to aim the operator's real
#                                pointer at an ephemeral checkout. Cases (c).
#   RESTORE WHAT YOU BORROW    — scripts/lib/global-state-witness.sh says so out
#                                loud when something moved. Cases (a)/(b).
#
# ===========================================================================
# THE POSITIVE CONTROL IS THE POINT, AND IT IS CASE (b2)
# ===========================================================================
# A witness reports a problem by printing nothing when all is well — which is
# the same output as a witness that looked at the wrong path, or at nothing. So
# this suite BREAKS THE RESTORE ON PURPOSE, in a fake config directory, and
# requires the witness to fail. Without that case, every green run here is a
# clean bill of health signed by nobody.
#
# NOTHING HERE TOUCHES THE OPERATOR'S REAL CONFIG DIRECTORY. Every case runs
# with HOME and CLAUDE_CONFIG_DIR redirected into a scratch tree — which is the
# discipline the suite exists to enforce, applied to itself.
#
# Covers:
#   (a) the witness sees a moved pointer, a deleted pointer, and a rewritten
#       settings.json, and names the path in each case
#   (b) it passes when nothing moved (b1) — and FAILS when the restore is
#       broken (b2), which is what makes b1 mean anything
#   (c) install.sh refuses to aim the REAL pointer at an ephemeral checkout,
#       names the scratch alternative, still does everything else, and is
#       overridable with --force-engine-pointer; a SANDBOXED config dir is
#       untouched by the rule
#   (d) THE ENUMERATION — every script in this engine that runs install.sh
#       either sandboxes the config dir or carries a witness. Hand-maintained,
#       plus a derived cross-check that can only ever ADD to the list.
#
# Run directly: scripts/lib/global-state-witness.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$SCRIPT_DIR/global-state-witness.sh"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t gswtest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 1; }
# shellcheck source=./global-state-witness.sh
. "$LIB"

echo "=== global-state-witness.test.sh ==="

# ---------------------------------------------------------------------------
echo "--- (a) the witness sees what moved"
# ---------------------------------------------------------------------------
CFG="$SCRATCH/cfg"
mkdir -p "$CFG" "$SCRATCH/engine-a" "$SCRATCH/engine-b"
ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
printf '{"hooks":{}}\n' > "$CFG/settings.json"

SNAP="$(CLAUDE_CONFIG_DIR="$CFG" richos_global_snapshot)"

ln -sfn "$SCRATCH/engine-b" "$CFG/richos-engine"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" richos_global_verify "$SNAP" 2>&1)" && RC=0 || RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "richos-engine"; then
    ok "a REPOINTED pointer is caught, and the path is named"
else
    bad "a repointed pointer must be caught" "rc=$RC $OUT"
fi

ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
rm -f "$CFG/richos-engine"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" richos_global_verify "$SNAP" 2>&1)" && RC=0 || RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "after  : absent"; then
    ok "a DELETED pointer is caught — absent and unchanged are not the same word"
else
    bad "a deleted pointer must be caught" "rc=$RC $OUT"
fi

ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
printf '{"hooks":{"PreToolUse":[]}}\n' > "$CFG/settings.json"
OUT="$(CLAUDE_CONFIG_DIR="$CFG" richos_global_verify "$SNAP" 2>&1)" && RC=0 || RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF "settings.json"; then
    ok "a REWRITTEN settings.json is caught — the user-scope registration nothing here may write"
else
    bad "a rewritten settings.json must be caught" "rc=$RC $OUT"
fi

# ---------------------------------------------------------------------------
echo "--- (b) unchanged passes, and a BROKEN restore does not"
# ---------------------------------------------------------------------------
printf '{"hooks":{}}\n' > "$CFG/settings.json"
ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
if CLAUDE_CONFIG_DIR="$CFG" richos_global_verify "$SNAP" 2>/dev/null; then
    ok "b1. everything put back exactly = silence, and rc 0"
else
    bad "b1. an unchanged config dir must verify"
fi

# b2 — THE RED PROOF THE ROW ASKED FOR. A run that borrows the pointer and
# RESTORES it verifies; the same run with the restore removed does not. Both
# arms are executed here, so b1 above cannot be passing because the witness is
# looking at nothing.
borrow_run() { # <restore: yes|no>
    local snap
    snap="$(CLAUDE_CONFIG_DIR="$CFG" richos_global_snapshot)"
    ln -sfn "$SCRATCH/engine-b" "$CFG/richos-engine"     # the red run borrows it
    rm -rf "$SCRATCH/engine-b"                            # ...and deletes its fixture
    mkdir -p "$SCRATCH/engine-b"
    [ "$1" = "yes" ] && ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
    CLAUDE_CONFIG_DIR="$CFG" richos_global_verify "$snap" 2>/dev/null
}
if borrow_run yes; then RESTORED=0; else RESTORED=1; fi
if borrow_run no;  then LEFT=0;     else LEFT=1;     fi
ln -sfn "$SCRATCH/engine-a" "$CFG/richos-engine"
if [ "$RESTORED" = 0 ] && [ "$LEFT" = 1 ]; then
    ok "b2. POSITIVE CONTROL: a borrow that restores passes, the SAME borrow without the restore FAILS"
else
    bad "b2. breaking the restore must fail the check" "restored-arm=$RESTORED left-moved-arm=$LEFT"
fi

# ---------------------------------------------------------------------------
echo "--- (c) install.sh will not aim the REAL pointer at an ephemeral checkout"
# ---------------------------------------------------------------------------
# A whole engine, in a temp directory — which is exactly the shape of the
# red-run fixture that caused the incident.
EPH="$SCRATCH/eph-engine"
mkdir -p "$EPH/.claude" "$EPH/hooks"
cp -R "$ENGINE_ROOT/scripts" "$EPH/scripts"
cp "$ENGINE_ROOT/VERSION" "$EPH/VERSION"
cp "$ENGINE_ROOT/.claude/settings.local.json" "$EPH/.claude/settings.local.json"
cp "$ENGINE_ROOT/hooks/hooks.json" "$EPH/hooks/hooks.json"

# A FAKE HOME whose .claude is therefore "the operator's real config dir" as far
# as install.sh can tell. The true one is never in play.
FAKEHOME="$SCRATCH/home"
mkdir -p "$FAKEHOME/.claude"
IOUT="$(env -u CLAUDE_CONFIG_DIR HOME="$FAKEHOME" bash "$EPH/scripts/hooks/install.sh" 2>&1)"
IRC=$?
if [ ! -e "$FAKEHOME/.claude/richos-engine" ]; then
    ok "c1. the pointer is NOT minted from a temp-directory checkout onto the real config dir"
else
    bad "c1. an ephemeral checkout repointed the real pointer" "$(ls -l "$FAKEHOME/.claude/richos-engine" 2>&1 | head -1)"
fi
if printf '%s' "$IOUT" | grep -qF 'EPHEMERAL' && printf '%s' "$IOUT" | grep -qF 'CLAUDE_CONFIG_DIR=$(mktemp -d)'; then
    ok "c2. and it SAYS so, naming the scratch config dir as the thing to borrow instead"
else
    bad "c2. the refusal must name the alternative" "$IOUT"
fi
if [ "$IRC" -eq 0 ] && [ -f "$EPH/scripts/hooks/scan-secrets.sh.sha256" ]; then
    ok "c3. everything else install.sh was run for still happened — one step withheld, not the script"
else
    bad "c3. only the pointer step is withheld" "rc=$IRC sidecars=$([ -f "$EPH/scripts/hooks/scan-secrets.sh.sha256" ] && echo minted || echo absent)"
fi

# launchctl is SHIMMED for this call. On 2026-09-03 this exact line — forced,
# temp checkout, fake HOME — ran a REAL `launchctl bootstrap gui/501` on a
# plist under $FAKEHOME, and the job outlived $SCRATCH. install.sh now
# withholds the schedule from a redirected HOME whatever the flag says
# (install-reconciler-schedule.test.sh S11–S16 prove it), and this suite
# stops borrowing the real launchctl regardless, for the reason it borrows
# nothing else real: a red run must not be able to leave anything moved.
GSW_SHIM="$SCRATCH/shim"; mkdir -p "$GSW_SHIM"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${LAUNCHCTL_SHIM_LOG:?}"\nexit 0\n' >"$GSW_SHIM/launchctl"
chmod +x "$GSW_SHIM/launchctl"
GSW_SHIMLOG="$SCRATCH/launchctl.log"
env -u CLAUDE_CONFIG_DIR HOME="$FAKEHOME" PATH="$GSW_SHIM:$PATH" LAUNCHCTL_SHIM_LOG="$GSW_SHIMLOG" \
    bash "$EPH/scripts/hooks/install.sh" --force-engine-pointer >/dev/null 2>&1
if [ -L "$FAKEHOME/.claude/richos-engine" ]; then
    ok "c4. --force-engine-pointer is the deliberate way through, and it still works"
else
    bad "c4. the escape hatch must still mint the pointer"
fi
if [ "$(env PATH="$GSW_SHIM:$PATH" bash -c 'command -v launchctl')" = "$GSW_SHIM/launchctl" ] && [ ! -s "$GSW_SHIMLOG" ] \
   && [ ! -e "$FAKEHOME/Library/LaunchAgents/com.richos.worktree-reconciler.plist" ]; then
    ok "c4b. ...and the forced run touched NO launchd job and wrote NO plist under the fake home (the shim resolves; its log is empty)"
else
    bad "c4b. the forced run reached launchd" "log=$(tr '\n' ';' <"$GSW_SHIMLOG" 2>/dev/null) plist=$([ -e "$FAKEHOME/Library/LaunchAgents/com.richos.worktree-reconciler.plist" ] && echo written || echo absent)"
fi

# THE PRECISION FLOOR. The rule must not fire when the config dir is sandboxed —
# which is what every suite in this engine does, and is the correct discipline.
# Get this wrong and the rule breaks ~20 sandbox installs in the meta-suite.
SBCFG="$SCRATCH/sandbox-cfg"; mkdir -p "$SBCFG"
env CLAUDE_CONFIG_DIR="$SBCFG" HOME="$FAKEHOME" bash "$EPH/scripts/hooks/install.sh" >/dev/null 2>&1
if [ -L "$SBCFG/richos-engine" ]; then
    ok "c5. a SANDBOXED config dir still gets its pointer — the rule fires only on the real one"
else
    bad "c5. the rule must not fire on a sandboxed config dir" "$(ls -l "$SBCFG/richos-engine" 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
echo "--- (d) THE ENUMERATION: who else borrows global state this way"
# ---------------------------------------------------------------------------
# install.sh is the ONLY writer of the pointer, so "who could move it" is
# exactly "who runs install.sh". Each of these is named with what protects it.
RUNNERS=(
    scripts/demo.sh                          # sandboxes CLAUDE_CONFIG_DIR at the call
    scripts/demo.test.sh                     # snapshots and asserts the real pointer intact
    scripts/locate-engine.test.sh            # per-call sandbox + asserts the real pointer intact
    scripts/hooks/contract-integrity.test.sh # exports a sandbox for the whole suite
    scripts/hooks/by-reference.test.sh       # sandboxes CLAUDE_CONFIG_DIR at the call
    scripts/lib/global-state-witness.test.sh # this file: fake HOME and a sandbox
    scripts/hooks/install-reconciler-schedule.test.sh # exports a sandbox config dir + redirects RICHOS_LAUNCH_AGENTS_DIR
)
UNPROTECTED=""
for f in "${RUNNERS[@]}"; do
    p="$ENGINE_ROOT/$f"
    [ -f "$p" ] || { UNPROTECTED="$UNPROTECTED $f(missing)"; continue; }
    grep -q 'CLAUDE_CONFIG_DIR' "$p" || grep -q 'global-state-witness' "$p" \
        || UNPROTECTED="$UNPROTECTED $f"
done
if [ -z "$UNPROTECTED" ]; then
    ok "d1. every script that runs install.sh sandboxes the config dir or witnesses it"
else
    bad "d1. these run install.sh against whatever config dir they are handed:$UNPROTECTED"
fi

# The cross-check, and note which direction it runs in. A derived scan that
# stopped matching would produce a SHORTER list and a greener suite, so it is
# never allowed to REPLACE the list above — it is only allowed to ADD to it. A
# new script that runs install.sh and is not named above fails here.
#
# "Runs it" is a COMMAND POSITION, not a mention: the path token followed by a
# redirect, a flag, an argument list or the end of the line. A line that greps
# install.sh, copies it, or names it inside an `ok`/`bad` message is a mention
# and is filtered out by name — the filter is listed rather than clever, so a
# reader can see exactly what it forgives.
STRAY=""
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit%%:*}"
    rel="${rel#"$ENGINE_ROOT/"}"
    case " ${RUNNERS[*]} " in
        *" $rel "*) continue ;;
    esac
    case "$rel" in
        scripts/hooks/install.sh) continue ;;
    esac
    case " $STRAY " in
        *" $rel "*) continue ;;
    esac
    STRAY="$STRAY $rel"
done <<EOF
$(grep -rnE 'hooks/install\.sh"[[:space:]]*(>|2>|--|"\$@"|$)' "$ENGINE_ROOT/scripts" --include=*.sh 2>/dev/null \
   | grep -vE '\b(ok|bad|grep|cp|sed|awk|echo|printf|emit_warn|emit_fail)\b' || true)
EOF
if [ -z "$STRAY" ]; then
    ok "d2. and nothing else in the engine invokes it"
else
    bad "d2. these invoke install.sh and are not on the list above:$STRAY"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
