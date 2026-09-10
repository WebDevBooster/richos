#!/bin/sh
# A stand-in for `whisper-cli` that records the REAL argv **and the peak memory of the decode
# process**, then behaves exactly as the binary would.
#
# WHY THIS EXISTS RATHER THAN A NUMBER QUOTED FROM THE TIER TABLE. `config.js`'s `quantized` tier
# claims "1.00 GB peak RSS vs 2.12 GB" for q5_0 against turbo. That figure is from 2026-08-26, on a
# different binary, a different decode configuration (`-mc -1`, no explicit `-fa`) and an 11-minute
# sample. A model-choice decision that quotes it would be deciding on a number nobody re-measured.
# So the peak is taken from the process that actually ran, under the configuration that actually
# ships, on the audio the decision is about.
#
# It is a strict SUPERSET of `../../whisper-settings-2026-09-10/tools/whisper-argv-shim.sh`: the
# same argv record, same one-JSON-object-per-line format, same per-argument quoting, so a run
# through this shim is still self-witnessing in exactly the way that rig requires. The argv log is
# written FIRST, before the decode, so an argv record exists even for a run that is killed.
#
#   RICHOS_WHISPER_BIN=<this>
#   RICHOS_WHISPER_RSS_LOG=<path>.jsonl      peak memory + exit status + argv of every invocation
#   RICHOS_WHISPER_RSS_ARGV_LOG=<path>.jsonl OPTIONAL separate argv-only log, for standalone use
#   RICHOS_WHISPER_REAL=<real bin>
#   RICHOS_WHISPER_RSS_REAL=<real bin>       WINS over RICHOS_WHISPER_REAL when set — see below
#
# IT DELIBERATELY DOES NOT WRITE `RICHOS_WHISPER_ARGV_LOG`. That variable belongs to the settings
# rig's argv shim, which sits UPSTREAM of this one in the chain. An earlier version of this file
# honored it too, and the result was every invocation recorded twice in one log with the same
# timestamp — harmless to the numbers, since both records were the same argv, and actively
# misleading to anyone counting invocations in a self-witnessing log. The argv is carried in this
# shim's own `RICHOS_WHISPER_RSS_LOG` records, so nothing is lost; `RICHOS_WHISPER_RSS_ARGV_LOG`
# exists for running this shim on its own, where no upstream shim is recording anything.
#
# IT CHAINS BEHIND THE SETTINGS RIG RATHER THAN REPLACING IT. `flag-sweep.mjs` and
# `longform-decode.mjs` install `whisper-argv-shim.sh` as `RICHOS_WHISPER_BIN` unconditionally, and
# take `RICHOS_WHISPER_REAL` as "the thing to exec" only if it is not already set. So pointing
# `RICHOS_WHISPER_REAL` at THIS file makes the chain product -> argv shim -> rss shim -> real
# binary, and both records get written from one run of the unmodified upstream tool. That collides
# on one variable name — the argv shim's "real" is this shim, and this shim's "real" would be
# itself — so `RICHOS_WHISPER_RSS_REAL` exists purely to break the cycle. A shim that recursed
# would fork-bomb rather than fail, which is why the cycle is broken by construction and not by
# a comparison of paths.
#
# TWO MEMORY NUMBERS, NOT ONE, AND THE SECOND IS THE HONEST ONE ON THIS PLATFORM:
#   maxrssBytes    getrusage(2) `maximum resident set size` via /usr/bin/time -l, in BYTES on
#                  macOS (verified against a control: /bin/dd reports 2,424,832).
#   footprintBytes macOS `peak memory footprint` — phys_footprint, which counts dirty and
#                  compressed pages an RSS reading can miss. Reported alongside rather than
#                  instead of, because RSS is the number every other platform's tooling gives and
#                  dropping it would make this un-comparable off a Mac.
# Neither is a claim about GPU-side allocation on unified memory; the whisper/ggml buffer sizes the
# binary prints for itself are captured too (`ggmlLines`) so the two views can be read together.
#
# STDERR IS PRESERVED, NOT SWALLOWED. `transcribeChannel` execs with stdio stderr:'inherit', so the
# decode's stderr is a real output path of the product. /usr/bin/time writes its report to that same
# stream, so the combined stream is captured to a temp file, the timing report is parsed out, and
# everything that is NOT the report is re-emitted on stderr. The exit status of the real binary is
# propagated unchanged — a shim that turned a decode failure into success would silently produce an
# empty measurement.
set -u
log="${RICHOS_WHISPER_RSS_ARGV_LOG:-/dev/null}"
rsslog="${RICHOS_WHISPER_RSS_LOG:-/dev/null}"
real="${RICHOS_WHISPER_RSS_REAL:-${RICHOS_WHISPER_REAL:-/opt/homebrew/bin/whisper-cli}}"
tag="${RICHOS_WHISPER_RSS_TAG:-}"

# REFUSE TO EXEC MYSELF. When chained, `RICHOS_WHISPER_REAL` names this file; forgetting
# `RICHOS_WHISPER_RSS_REAL` would make that the exec target and the result is an unbounded fork,
# not an error anybody sees. Cheap check, loud failure, no measurement written.
case "$real" in
  */whisper-rss-shim.sh)
    echo "whisper-rss-shim: refusing to exec itself — set RICHOS_WHISPER_RSS_REAL to the real whisper-cli" >&2
    exit 78
    ;;
esac

argv_json() {
  printf '['
  first=1
  for a in "$@"; do
    esc=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    printf '"%s"' "$esc"
  done
  printf ']'
}

{
  printf '{"ts":"%s","argv":' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  argv_json "$@"
  printf '}\n'
} >>"$log"

err=$(mktemp)
start=$(date +%s)
/usr/bin/time -l "$real" "$@" 2>"$err"
status=$?
end=$(date +%s)

maxrss=$(awk '/maximum resident set size/ {print $1}' "$err" | tail -1)
foot=$(awk '/peak memory footprint/ {print $1}' "$err" | tail -1)
[ -n "${maxrss:-}" ] || maxrss=null
[ -n "${foot:-}" ] || foot=null

# Everything the real binary said, minus /usr/bin/time's own report, back onto stderr where the
# product expects it. The report block is the trailing lines from "N real" onward.
awk '/^ *[0-9.]+ +real +[0-9.]+ +user/ {stop=1} !stop {print}' "$err" >&2

{
  printf '{"ts":"%s","tag":"%s","exit":%d,"wallSec":%d,"maxrssBytes":%s,"footprintBytes":%s,"ggmlLines":' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$status" "$((end - start))" "$maxrss" "$foot"
  # whisper/ggml's own memory accounting, verbatim, so the process-level number can be cross-read
  # against what the decoder believes it allocated.
  grep -E 'model size|buffer size|compute buffer|kv self size|kv cross size' "$err" \
    | sed 's/^[[:space:]]*//' | tr '\n' '\036' | sed 's/\036$//' > "$err.g" 2>/dev/null || true
  if [ -s "$err.g" ]; then
    tr '\036' '\n' < "$err.g" | awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}'
  else
    printf '[]'
  fi
  printf ',"argv":'
  argv_json "$@"
  printf '}\n'
} >>"$rsslog"

rm -f "$err" "$err.g"
exit $status
