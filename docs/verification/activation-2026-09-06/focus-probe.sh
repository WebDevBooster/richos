#!/usr/bin/env bash
#
# focus-probe.sh <binary> <label> <seconds> [RICHOS_ACTIVATION value]
#
# Boot a richos-tauri binary EXACTLY the way a test harness boots one — as a child process
# this script holds, `cd /`, with the environment a Finder launch really has — and measure
# whether it takes the keyboard away from whatever is frontmost right now.
#
# =========================================================================================
# WHY THE VERDICT IS A CONJUNCTION AND NOT A GREP
# =========================================================================================
#
# "The app did not take focus" passes TRIVIALLY if the app never launched, died in `setup`,
# or came up without a webview. The first version of this file computed its verdict from the
# frontmost samples alone, and it would have reported `focus never left Terminal` over a
# binary that did not exist. That is the exact failure class this repository spent 2026-09-04
# and 2026-09-05 removing from eleven checks, reproduced by the person removing it.
#
# So PASS requires FOUR facts, each measured separately and each printed:
#
#   L  the process was still alive when the sampling window ended
#   C  the boot log carries `[richos] boot complete` — `setup` ran to its end
#   W  the boot log carries a line only the WEBVIEW can cause: `voice_readiness` is a
#      `#[tauri::command]` that the page invokes before it renders its greeting, so its
#      output proves WKWebView was created, the frontend loaded, JavaScript ran and an IPC
#      round trip completed into Rust
#   F  no sample of `lsappinfo front` named this app
#
# Any of L, C, W missing is reported as INCONCLUSIVE, never as a pass — the run proved
# nothing about focus because there was nothing on screen to take it.
#
# W's limit, named: on a machine where speech IS installed, `voice_readiness` succeeds and
# prints nothing, so W is absent for a reason that is not a failure. This probe is run with a
# scratch HOME where it is always absent, which is why W is usable here; the real-home run
# (real-launch-proof.sh) does not rely on it and says so.
set -uo pipefail

BIN="$1"; LABEL="$2"; SECS="${3:-6}"; ACT="${4:-}"
OUT="${FOCUS_PROBE_OUT:-/private/tmp/richos-focus-probe}/probe-$LABEL"
mkdir -p "$OUT"
HOMEDIR="$(mktemp -d -t focus-probe.XXXXXX)"
mkdir -p "$HOMEDIR/Library/Application Support"

front() {
  local asn name
  asn="$(/usr/bin/lsappinfo front 2>/dev/null)"
  name="$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/.*"LSDisplayName"="\([^"]*\)".*/\1/p')"
  [ -z "$name" ] && name="(none)"
  printf '%s' "$name"
}

BEFORE="$(front)"
{
  printf 'label            : %s\n' "$LABEL"
  printf 'binary           : %s\n' "$BIN"
  printf 'scratch HOME     : %s\n' "$HOMEDIR"
  printf 'RICHOS_ACTIVATION: %s\n' "${ACT:-<unset>}"
  printf 'frontmost BEFORE : %s\n' "$BEFORE"
} > "$OUT/report.txt"

: > "$OUT/boot.log"
if [ -n "$ACT" ]; then
  ( cd / && exec /usr/bin/env -i HOME="$HOMEDIR" USER="${USER:-unknown}" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin RICHOS_ACTIVATION="$ACT" \
      "$BIN" > "$OUT/boot.log" 2>&1 ) &
else
  ( cd / && exec /usr/bin/env -i HOME="$HOMEDIR" USER="${USER:-unknown}" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$BIN" > "$OUT/boot.log" 2>&1 ) &
fi
PID=$!
{
  printf 'app pid          : %s\n' "$PID"
  printf 'probe pid        : %s (this script IS the parent — condition P cannot hold)\n' "$$"
} >> "$OUT/report.txt"

: > "$OUT/frontmost-samples.txt"
i=0
while [ "$i" -lt $((SECS * 4)) ]; do
  printf '%s\n' "$(front)" >> "$OUT/frontmost-samples.txt"
  sleep 0.25
  i=$((i + 1))
done

/usr/bin/lsappinfo list 2>/dev/null | grep -A 6 '"richos-tauri" ASN' > "$OUT/lsappinfo.txt" 2>&1

# -- the four facts, each measured on its own --------------------------------------------
if kill -0 "$PID" 2>/dev/null; then L=yes; else L=no; fi
if grep -q '^\[richos\] boot complete' "$OUT/boot.log" 2>/dev/null; then C=yes; else C=no; fi
if grep -q '^\[richos\] voice: not offered' "$OUT/boot.log" 2>/dev/null; then W=yes; else W=no; fi
if grep -qi 'richos' "$OUT/frontmost-samples.txt"; then F=no; else F=yes; fi

kill -TERM "$PID" 2>/dev/null
j=0
while [ "$j" -lt 40 ]; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; j=$((j + 1)); done
kill -KILL "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

{
  printf 'frontmost AFTER  : %s\n' "$(front)"
  printf 'distinct frontmost applications while it ran:\n'
  LC_ALL=C sort "$OUT/frontmost-samples.txt" | uniq -c | LC_ALL=C sort -rn | sed 's/^/    /'
  printf 'L still alive at the end of sampling : %s\n' "$L"
  printf 'C [richos] boot complete             : %s\n' "$C"
  printf 'W webview completed an IPC round trip: %s\n' "$W"
  printf 'F no sample named this app frontmost : %s\n' "$F"
} >> "$OUT/report.txt"

RC=0
if [ "$L" != yes ] || [ "$C" != yes ] || [ "$W" != yes ]; then
  printf 'VERDICT          : INCONCLUSIVE — the app did not run far enough for focus to mean anything (L=%s C=%s W=%s)\n' "$L" "$C" "$W" >> "$OUT/report.txt"
  RC=2
elif [ "$F" != yes ]; then
  printf 'VERDICT          : IT TOOK FOCUS — the app booted, drew, and became frontmost\n' >> "$OUT/report.txt"
  RC=1
else
  printf 'VERDICT          : PASS — it booted, drew and answered IPC, and focus never left %s\n' "$BEFORE" >> "$OUT/report.txt"
fi
rm -rf "$HOMEDIR"
cat "$OUT/report.txt"
exit "$RC"
