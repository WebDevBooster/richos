#!/usr/bin/env bash
#
# Fetch BOTH dictation models into one shared directory — and prove they are the right bytes.
#
# RichOS ships one dictation app carrying two whisper models:
#   Accurate (default) : ggml-large-v3-turbo-q5_0.bin   574,041,195 bytes
#   Fast     (opt-in)  : ggml-small.en.bin              487,614,201 bytes
#                                              total  1,061,655,396 bytes (1.06 GB)
#
# Full ggml-large-v3-turbo.bin (1,624,555,275 bytes) is NOT fetched — it is retired from the
# dictation path. It stays the default for POST-CALL batch transcription (tools/richos-service),
# which resolves models from the same directory, so that path is unaffected.
# Measurements: the dictation-daemon + q5 brief, 2026-08-26
#
# ---------------------------------------------------------------------------------------------
# WHAT CHANGED, 2026-08-31: THIS SCRIPT NOW VERIFIES A CRYPTOGRAPHIC HASH.
#
# It used to verify a byte count and the four-byte GGML magic. Both are trivially satisfiable by
# anyone who can serve bytes, so a hotel captive portal's login page padded to 574,041,195 bytes
# would have installed as a speech model. The sizes and hashes are no longer written here at all:
# they are read from tools/richos-service/lib/model-pins.json, which is the ONE place they live,
# so this script and the service can never disagree about what a model is. The test suite asserts
# that this parser and the service's reader produce identical tables.
#
# Resumability: YES. A download that dies at 90% of 574 MB does not start over — the partial file
# is kept and `curl -C -` resumes from its length. A file that fails its HASH is DELETED, not
# resumed and not quarantined, because those bytes are not a prefix of anything.
# ---------------------------------------------------------------------------------------------
#
# Destination resolution, in order:
#   $1                    (explicit argument)
#   $OPENWISPR_MODEL_DIR  (first entry of the `:`-separated list)
#   ~/Models/Whisper      (the shared RichOS model dir the patched app searches)
#
# Usage:
#   tools/richos-hud/fetch-dictation-models.sh [dest-dir]
#   tools/richos-hud/fetch-dictation-models.sh --print-pins    # id file bytes sha256, one per line
#   tools/richos-hud/fetch-dictation-models.sh --verify [dest-dir]   # check what is there, fetch nothing
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${HERE}/../richos-service/lib/model-pins.json"

if [ ! -f "${PIN_FILE}" ]; then
  echo "!! pin table not found at ${PIN_FILE} — refusing to download a model this script cannot verify" >&2
  exit 1
fi

# Read the pin table. Deliberately awk and not jq: this script must run on a stock macOS with
# nothing installed, which is the machine a first run happens on. The table is our own file with a
# fixed shape, so a field-driven state machine is sufficient and, unlike a regex over the whole
# file, cannot silently pair one model's size with another's hash.
read_pins() {
  awk '
    function val(line,   v) {
      v = line
      sub(/^[^:]*:[[:space:]]*/, "", v)
      gsub(/^"|",?$|,$/, "", v)
      return v
    }
    /"id"[[:space:]]*:/     { id = val($0);    have_id = 1; next }
    /"file"[[:space:]]*:/   { file = val($0);  have_file = 1; next }
    /"bytes"[[:space:]]*:/  { bytes = val($0); have_bytes = 1; next }
    /"sha256"[[:space:]]*:/ {
      sha = val($0)
      if (have_id && have_file && have_bytes) print id "\t" file "\t" bytes "\t" sha
      have_id = have_file = have_bytes = 0
      next
    }
  ' "${PIN_FILE}"
}

read_scalar() {
  awk -v key="$1" '
    $0 ~ "\"" key "\"[[:space:]]*:" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      gsub(/^"|",?$|,$/, "", v)
      print v
      exit
    }
  ' "${PIN_FILE}"
}

BASE_URL="$(read_scalar baseUrl)"
GGML_MAGIC="$(read_scalar ggmlMagicHex)"

if [ "${1:-}" = "--print-pins" ]; then
  read_pins
  exit 0
fi

VERIFY_ONLY=0
if [ "${1:-}" = "--verify" ]; then
  VERIFY_ONLY=1
  shift
fi

pin_field() {
  # pin_field <model-id> <1=id|2=file|3=bytes|4=sha256>
  read_pins | awk -F'\t' -v want="$1" -v col="$2" '$1 == want { print $col; found = 1 } END { if (!found) exit 1 }'
}

file_size() {
  stat -f %z "$1" 2>/dev/null || stat -c %s "$1"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "!! no shasum or sha256sum on this machine — cannot verify a model, refusing to install one" >&2
    return 1
  fi
}

free_bytes() {
  # POSIX df in 512-byte blocks; portable across macOS and Linux.
  df -P "$1" 2>/dev/null | awk 'NR == 2 { print $4 * 512 }'
}

# Is this file the model we pinned? Prints a sentence naming what is wrong; returns non-zero.
# $1 path  $2 want_bytes  $3 want_sha  $4 label
verify_file() {
  local path="$1" want_bytes="$2" want_sha="$3" label="$4"
  local have magic got

  if [ ! -f "${path}" ]; then
    echo "!! ${label}: ${path} is not on disk." >&2
    return 1
  fi
  have=$(file_size "${path}")
  if [ "${have}" = "0" ]; then
    echo "!! ${label}: the file is empty — the download produced no bytes at all." >&2
    return 1
  fi
  magic=$(head -c 4 "${path}" | xxd -p)
  if [ "${magic}" != "${GGML_MAGIC}" ]; then
    if head -c 1024 "${path}" | LC_ALL=C tr 'A-Z' 'a-z' | grep -qE '<!doctype html|<html[ >]|<head[ >]|<meta '; then
      echo "!! ${label}: this came back as a WEB PAGE, not a model — the file starts with HTML." >&2
      echo "   That is what hotel, airport or conference wifi looks like when it intercepts the" >&2
      echo "   download to show a login page. Sign in to the network and run this again." >&2
    else
      echo "!! ${label}: not a whisper model — its first four bytes are ${magic}, and every GGML" >&2
      echo "   model starts with ${GGML_MAGIC}." >&2
    fi
    return 1
  fi
  if [ "${have}" != "${want_bytes}" ]; then
    if [ "${have}" -lt "${want_bytes}" ]; then
      echo "!! ${label}: incomplete — ${have} of ${want_bytes} bytes." >&2
    else
      echo "!! ${label}: larger than the model we pinned — ${have} bytes where ${want_bytes} were expected." >&2
    fi
    return 1
  fi
  echo "    verifying sha256 over ${have} bytes…"
  got=$(sha256_of "${path}") || return 1
  if [ "${got}" != "${want_sha}" ]; then
    echo "!! ${label}: EXACTLY the right size and it starts like a real model, but the contents are" >&2
    echo "   not the bytes RichOS pinned." >&2
    echo "   expected sha256 ${want_sha}" >&2
    echo "        got sha256 ${got}" >&2
    echo "   Something between ${BASE_URL} and this machine changed the file." >&2
    return 1
  fi
  return 0
}

if [ "${1:-}" != "" ]; then
  DEST="$1"
elif [ "${OPENWISPR_MODEL_DIR:-}" != "" ]; then
  DEST="${OPENWISPR_MODEL_DIR%%:*}"
else
  DEST="${HOME}/Models/Whisper"
fi

mkdir -p "${DEST}"
echo "==> Model directory: ${DEST}"
echo "==> Pin table:       ${PIN_FILE}  (verified $(read_scalar verifiedOn))"

fetch() {
  local id="$1" label="$2"
  local file want_bytes want_sha path need have_free
  file=$(pin_field "${id}" 2) || { echo "!! no pin for model \"${id}\" — refusing to download something unverifiable" >&2; return 1; }
  want_bytes=$(pin_field "${id}" 3)
  want_sha=$(pin_field "${id}" 4)
  path="${DEST}/${file}"

  if [ -f "${path}" ]; then
    if verify_file "${path}" "${want_bytes}" "${want_sha}" "${label}" 2>/dev/null; then
      echo "==> ${label}: already present and verified — OK"
      return 0
    fi
    if [ "${VERIFY_ONLY}" = "1" ]; then
      verify_file "${path}" "${want_bytes}" "${want_sha}" "${label}" || true
      return 1
    fi
    echo "==> ${label}: present but does not verify —"
    verify_file "${path}" "${want_bytes}" "${want_sha}" "${label}" || true
    echo "==> ${label}: deleting it and fetching again. Nothing unverified is ever left in place."
    rm -f "${path}"
  elif [ "${VERIFY_ONLY}" = "1" ]; then
    echo "==> ${label}: not installed (${want_bytes} bytes to download)"
    return 1
  fi

  # Disk preflight, BEFORE a byte moves. Finding out at 95% of 574 MB is the worst possible time.
  need=$(( want_bytes + want_bytes / 10 ))
  have_free=$(free_bytes "${DEST}")
  if [ -n "${have_free}" ] && [ "${have_free}" -lt "${need}" ]; then
    echo "!! ${label}: not enough free disk — needs ${need} bytes (the model plus 10% headroom)," >&2
    echo "   this disk has ${have_free}. Nothing was started." >&2
    return 1
  fi

  # `-C -` resumes from the length of the .part file, so a dropped 574 MB download does not start
  # over. A .part that is already >= the pinned size, or that does not begin like a model, is not a
  # prefix worth resuming — drop it and start clean.
  if [ -f "${path}.part" ]; then
    local part_bytes part_magic
    part_bytes=$(file_size "${path}.part")
    part_magic=$(head -c 4 "${path}.part" | xxd -p)
    if [ "${part_bytes}" -ge "${want_bytes}" ] || [ "${part_magic}" != "${GGML_MAGIC}" ]; then
      echo "==> ${label}: the partial file is not a usable prefix — starting over"
      rm -f "${path}.part"
    else
      echo "==> ${label}: resuming from ${part_bytes} of ${want_bytes} bytes"
    fi
  fi

  echo "==> ${label}: downloading ${file}"
  local curl_rc=0
  curl -fL -C - --progress-bar -o "${path}.part" "${BASE_URL}/${file}" || curl_rc=$?
  # curl exit 33 is "this server does not do byte ranges". Resuming is then impossible, not merely
  # slow, so the partial is dropped and the whole file is fetched from zero. Without this the
  # script would report a resumable failure for ever against a server that can never resume.
  if [ "${curl_rc}" = "33" ]; then
    echo "==> ${label}: this server does not support resuming — starting the download over"
    rm -f "${path}.part"
    curl_rc=0
    curl -fL --progress-bar -o "${path}.part" "${BASE_URL}/${file}" || curl_rc=$?
  fi
  if [ "${curl_rc}" != "0" ]; then
    echo "!! ${label}: the download did not finish (curl exit ${curl_rc}). The partial file was" >&2
    echo "   kept, so running this again resumes from where it stopped rather than starting over." >&2
    return 1
  fi

  if ! verify_file "${path}.part" "${want_bytes}" "${want_sha}" "${label}"; then
    # A short file is a kept prefix and can be resumed. Anything else is not a model at all, and
    # keeping it would mean the next run resumes onto garbage.
    local got
    got=$(file_size "${path}.part")
    if [ "${got}" -lt "${want_bytes}" ] && [ "$(head -c 4 "${path}.part" | xxd -p)" = "${GGML_MAGIC}" ]; then
      echo "   The partial file was kept for a resume." >&2
    else
      rm -f "${path}.part"
      echo "   The file was deleted. Nothing was installed." >&2
    fi
    return 1
  fi

  mv "${path}.part" "${path}"
  echo "==> ${label}: installed and verified, ${want_bytes} bytes"
}

rc=0
fetch "large-v3-turbo-q5_0" "Accurate (large-v3-turbo-q5_0)" || rc=1
fetch "small.en"            "Fast (small.en)"                || rc=1

echo
if [ "${rc}" = "0" ]; then
  echo "==> Both dictation models present in ${DEST}, each verified against its pinned sha256"
  echo "    The patched app searches: \$OPENWISPR_MODEL_DIR, config.modelDir,"
  echo "    ~/.config/open-wispr/models, ~/Models/Whisper, the whisper.cpp install dirs."
else
  echo "!! One or more models are not installed. Nothing unverified was left in ${DEST}." >&2
fi
exit "${rc}"
