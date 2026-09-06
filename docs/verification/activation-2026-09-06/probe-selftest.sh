#!/usr/bin/env bash
#
# Make the probe FAIL on purpose, three distinct ways, before believing any green it prints.
# Each stub is a real executable the probe boots exactly as it boots the app.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$DIR/focus-probe.sh"
export FOCUS_PROBE_OUT="${FOCUS_PROBE_OUT:-/private/tmp/richos-focus-probe-selftest}"
STUBS="$FOCUS_PROBE_OUT/stubs"
mkdir -p "$STUBS"

# N1 — the binary does not exist at all.
printf '\n===== N1 the binary does not exist =====\n'
bash "$P" "$STUBS/no-such-binary" n1-missing-binary 2 2>&1 | tail -8
printf 'probe exit: %s\n' "${PIPESTATUS[0]}"

# N2 — it starts, prints a full healthy-looking boot log, and DIES immediately.
printf '\n===== N2 it prints a perfect boot log and then dies =====\n'
cat > "$STUBS/dies.sh" <<'STUB'
#!/bin/sh
echo "[richos] activation: accessory — no Dock icon, no window on screen, no focus taken, because this is not an installed launch: x"
echo "[richos] boot complete — every line above is what this launch resolved"
echo "[richos] voice: not offered on this machine — My ears aren't installed on this machine yet"
exit 0
STUB
chmod +x "$STUBS/dies.sh"
bash "$P" "$STUBS/dies.sh" n2-dies-immediately 2 2>&1 | tail -8
printf 'probe exit: %s\n' "${PIPESTATUS[0]}"

# N3 — it stays alive forever and never boots: the shape of a hang in `setup`.
printf '\n===== N3 it stays alive and never finishes booting =====\n'
cat > "$STUBS/hangs.sh" <<'STUB'
#!/bin/sh
echo "[richos] activation: accessory — no Dock icon, no window on screen, no focus taken, because this is not an installed launch: x"
sleep 600
STUB
chmod +x "$STUBS/hangs.sh"
bash "$P" "$STUBS/hangs.sh" n3-never-boots 2 2>&1 | tail -8
printf 'probe exit: %s\n' "${PIPESTATUS[0]}"

# N4 — it boots to completion but the WEBVIEW never speaks: alive, complete, no window.
printf '\n===== N4 it boots but no webview ever answers =====\n'
cat > "$STUBS/no-webview.sh" <<'STUB'
#!/bin/sh
echo "[richos] activation: accessory — no Dock icon, no window on screen, no focus taken, because this is not an installed launch: x"
echo "[richos] boot complete — every line above is what this launch resolved"
sleep 600
STUB
chmod +x "$STUBS/no-webview.sh"
bash "$P" "$STUBS/no-webview.sh" n4-no-webview 2 2>&1 | tail -8
printf 'probe exit: %s\n' "${PIPESTATUS[0]}"
