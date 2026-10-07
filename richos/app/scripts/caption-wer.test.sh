#!/usr/bin/env bash
# caption-wer.py: rolling WebVTT read once, WER counts, capitalization and spelling pairs, loops.
# run-tests: no-host-screen: synthetic captions and transcripts only; no capture or input
# run-tests: inputs richos/app/scripts/caption-wer.test.sh richos/app/scripts/qa/caption-wer.py richos/app/scripts/qa/caption-wer.test.py
# run-tests: covers richos/app/scripts/qa/caption-wer.py richos/app/scripts/qa/caption-wer.test.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/qa/caption-wer.test.py"
