#!/bin/bash
set -euo pipefail
SP="$1"
REF="/Users/alex/ab/richos-hq/docs/reference/local"
ffmpeg -y -v error -i "$REF/01_alex-audio_webinar-recording.mp3" -ac 1 -ar 16000 "$SP/audio/me.wav"
ffmpeg -y -v error -i "$REF/01_andreas_pettersson-audio_webinar-recording.mp3" -ac 1 -ar 16000 "$SP/audio/others.wav"
shasum -a 256 "$SP/audio/me.wav" "$SP/audio/others.wav"
