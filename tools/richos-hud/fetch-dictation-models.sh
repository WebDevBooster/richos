#!/usr/bin/env bash
#
# Fetch BOTH dictation models into one shared directory.
#
# RichOS ships one dictation app carrying two whisper models:
#   Accurate (default) : ggml-large-v3-turbo-q5_0.bin   574,041,195 bytes
#   Fast     (opt-in)  : ggml-small.en.bin              487,614,201 bytes
#                                              total  1,061,655,396 bytes (1.06 GB)
#
# Full ggml-large-v3-turbo.bin (1,624,555,275 bytes) is NOT fetched — it is
# retired from the dictation path. It stays the default for POST-CALL batch
# transcription (tools/richos-service), which resolves models from the same
# directory, so that path is unaffected.
# Measurements: the dictation-daemon + q5 brief, 2026-08-26
#
# Destination resolution, in order:
#   $1                    (explicit argument)
#   $OPENWISPR_MODEL_DIR  (first entry of the `:`-separated list)
#   ~/Models/Whisper      (the shared RichOS model dir the patched app searches)
#
# Usage:
#   tools/richos-hud/fetch-dictation-models.sh [dest-dir]
#
set -euo pipefail

BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

ACCURATE_FILE="ggml-large-v3-turbo-q5_0.bin"
ACCURATE_BYTES=574041195
FAST_FILE="ggml-small.en.bin"
FAST_BYTES=487614201

if [ "${1:-}" != "" ]; then
  DEST="$1"
elif [ "${OPENWISPR_MODEL_DIR:-}" != "" ]; then
  DEST="${OPENWISPR_MODEL_DIR%%:*}"
else
  DEST="${HOME}/Models/Whisper"
fi

mkdir -p "${DEST}"
echo "==> Model directory: ${DEST}"

fetch() {
  local file="$1" want_bytes="$2" label="$3"
  local path="${DEST}/${file}"

  if [ -f "${path}" ]; then
    local have
    have=$(stat -f %z "${path}" 2>/dev/null || stat -c %s "${path}")
    if [ "${have}" = "${want_bytes}" ]; then
      echo "==> ${label}: already present, ${have} bytes — OK"
      return 0
    fi
    echo "==> ${label}: present but ${have} bytes (expected ${want_bytes}) — refetching"
    rm -f "${path}"
  fi

  echo "==> ${label}: downloading ${file}"
  curl -fL --progress-bar -o "${path}.part" "${BASE_URL}/${file}"
  local got
  got=$(stat -f %z "${path}.part" 2>/dev/null || stat -c %s "${path}.part")
  if [ "${got}" != "${want_bytes}" ]; then
    rm -f "${path}.part"
    echo "!! ${label}: got ${got} bytes, expected ${want_bytes} — refusing to install" >&2
    return 1
  fi
  # whisper.cpp GGML magic: the uint32 0x67676d6c ("ggml") stored little-endian,
  # so the first four bytes on disk are 6c 6d 67 67. Verified against the two
  # real model files, not assumed from the spelling.
  local magic
  magic=$(head -c 4 "${path}.part" | xxd -p)
  if [ "${magic}" != "6c6d6767" ]; then
    rm -f "${path}.part"
    echo "!! ${label}: not a GGML file (magic ${magic}) — refusing to install" >&2
    return 1
  fi
  mv "${path}.part" "${path}"
  echo "==> ${label}: installed, ${got} bytes"
}

fetch "${ACCURATE_FILE}" "${ACCURATE_BYTES}" "Accurate (large-v3-turbo-q5_0)"
fetch "${FAST_FILE}"     "${FAST_BYTES}"     "Fast (small.en)"

echo
echo "==> Both dictation models present in ${DEST}"
echo "    The patched app searches: \$OPENWISPR_MODEL_DIR, config.modelDir,"
echo "    ~/.config/open-wispr/models, ~/Models/Whisper, the whisper.cpp install dirs."
