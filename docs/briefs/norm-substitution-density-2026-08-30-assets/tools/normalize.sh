#!/bin/bash
set -euo pipefail
SP="$1"
# The two source recordings are two speakers from one webinar. They live OUTSIDE this repository,
# in richos-hq, which is private and gitignores them. Their local FILENAMES are not written here
# either: the second speaker is a named third party who did not agree to appear in a public
# repository, and a filename is personal data even when the audio it names never ships.
# Pass the two names in, so re-running is possible without publishing whose voices these are.
REF="${REF:-/Users/alex/ab/richos-hq/docs/reference/local}"
: "${ME_MP3:?set ME_MP3 to the first speaker's recording filename inside $REF}"
: "${OTHERS_MP3:?set OTHERS_MP3 to the second speaker's recording filename inside $REF}"
ffmpeg -y -v error -i "$REF/$ME_MP3" -ac 1 -ar 16000 "$SP/audio/me.wav"
ffmpeg -y -v error -i "$REF/$OTHERS_MP3" -ac 1 -ar 16000 "$SP/audio/others.wav"
shasum -a 256 "$SP/audio/me.wav" "$SP/audio/others.wav"
