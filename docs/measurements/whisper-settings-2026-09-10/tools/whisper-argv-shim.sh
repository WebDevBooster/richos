#!/bin/sh
# A transparent stand-in for `whisper-cli` that RECORDS the argv it was called with and then execs
# the real binary unchanged.
#
# WHY THIS EXISTS RATHER THAN A grep OF config.js. The settings table this ships with is a claim
# about what the pipeline HANDS TO the decoder, and source is not evidence of that: four separate
# places contribute flags to one invocation (`whisperArgs()`, a tier's `decodeArgs`, a caller's
# `extraArgs`, and the output flags that live in `transcribe.js`), the env overrides can change any
# of them at runtime, and whisper-cli takes the LAST value of a repeated flag. The only artifact
# that settles what actually ran is the argv of the process that actually ran. Point
# `RICHOS_WHISPER_BIN` at this file and the pipeline records it for you — including the invocations
# no test calls directly, such as the deletion detector's isolated clip probes.
#
#   RICHOS_WHISPER_BIN=<this>  RICHOS_WHISPER_ARGV_LOG=<path>.jsonl  RICHOS_WHISPER_REAL=<real bin>
#
# One JSON object per line: {"ts": <utc>, "argv": [...]}. Quoting is done per ARGUMENT, so an
# argument containing a space or a quote survives into the record intact — a log written from "$*"
# would silently merge `--prompt "Halden Fitzroy"` into one token and so misreport the very thing
# this file exists to prove.
set -eu
log="${RICHOS_WHISPER_ARGV_LOG:-/dev/null}"
real="${RICHOS_WHISPER_REAL:-/opt/homebrew/bin/whisper-cli}"
{
  printf '{"ts":"%s","argv":[' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=1
  for a in "$@"; do
    esc=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    printf '"%s"' "$esc"
  done
  printf ']}\n'
} >>"$log"
exec "$real" "$@"
