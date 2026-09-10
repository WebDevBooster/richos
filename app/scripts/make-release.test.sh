#!/usr/bin/env bash
#
# make-release.test.sh — the release chain's REFUSALS, exercised without a release build
# and without a GitHub release.
#
# WHAT THIS SUITE CAN AND CANNOT PROVE, first, because the distinction decides what belongs
# here.
#
#   IT PROVES     that the order is enforced rather than documented: that a pin cannot be
#                 built into an app until the published bytes have been read back, that a
#                 stale receipt is caught, and that a digest that does not match what a URL
#                 serves stops the release. It runs in seconds, against a local HTTP server
#                 standing in for the release host.
#
#   IT CANNOT     prove that a release installs. That is a claim about a signed bundle
#                 replacing a running one, and it belongs to `app/scripts/updater-e2e.sh`.
#                 Nor can it prove the checks that only exist once a real bundle has been
#                 built — the digest inside the executable, the stapled ticket inside the
#                 first-install archive. Those run inside `make-release.sh app`, on the
#                 artifact, every time.
#
# Cases:
#   R1  `plan` names the version, the tag and every URL, and creates nothing
#   R2  `verify-engine` with no pin refuses
#   R3  `verify-engine` against a URL that does not serve the asset refuses, and says the
#       failure would otherwise ship inside a signed binary
#   R4  `verify-engine` against bytes that are NOT the pinned bytes refuses
#   R5  `verify-engine` against the pinned bytes writes a receipt naming that digest
#   R5a `app` with no named-person deny-list stops at the names gate, BEFORE the pin check —
#       the gate's precedence, asserted rather than assumed
#   R6  `app` with no pin refuses
#   R7  `app` with a pin and no receipt refuses — the digest would be a claim about a local file
#   R8  `app` with a receipt for a DIFFERENT digest refuses — the asset was rebuilt after it
#       was verified
#   R9  `app` with a good receipt and no signing key refuses
#   R10 `verify-release` with nothing staged refuses
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$SRC_DIR/.." && pwd)"
SCRIPT="$SRC_DIR/make-release.sh"

TMP="$(mktemp -d -t make-release-test.XXXXXX)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

run() { OUT="$("$@" 2>&1)"; CODE=$?; return 0; }
expect() {   # expect <name> <wanted-code> <substring>
  local name="$1" want="$2" needle="$3"
  if [ "$CODE" != "$want" ]; then
    bad "$name" "exit $CODE, wanted $want. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-220)"
  elif ! printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    bad "$name" "exit $want as wanted, but the output never said '$needle'"
  else
    ok "$name"
  fi
}

OUTDIR="$TMP/staging"
TAG="v0.0.0-test"
REL=(bash "$SCRIPT")

# ---------------------------------------------------------------------------------------
# THE NAMES GATE, PUT INTO A KNOWN STATE INSTEAD OF INHERITED FROM THE MACHINE
# ---------------------------------------------------------------------------------------
#
# `make-release.sh app` runs `names_gate` before it looks at anything else, and that gate
# REFUSES when the operator's deny-list is absent — deliberately, because "no list" must
# never be able to look like "no names found". The list lives outside every repository, at
# `$HOME/.richos-privacy/named-persons`, and a machine that is not the owner's does not
# have one.
#
# So R6-R9 below, which are about the PIN/RECEIPT/KEY ordering and have nothing to do with
# names, were passing on exactly one machine in the world and failing everywhere else.
# MEASURED on a GitHub `macos-latest` runner, 2026-09-10, run 34444955517: all four red,
# each one "exit 2 as wanted, but the output never said ..." — the right exit code, from
# the wrong refusal, which is precisely the confusion `expect`'s needle exists to catch.
# It caught it. The suite was the thing that was wrong.
#
# `RICHOS_NAMED_PERSONS_FILE` is the deny-list's own documented override
# (`engine/scripts/lib/named-persons.sh::np_list_path`). A `sha256:` entry is a hashed
# window rather than a name, so this fixture discloses nothing and — being a digest no
# two-token window in any tree will ever produce — matches nothing. The gate therefore runs
# for real and returns CLEAN, and the four cases below reach the refusals they are named
# after.
#
# The absent case is not thrown away by this; it becomes R5a, which asserts the precedence
# on purpose instead of by accident.
NPLIST="$TMP/named-persons"
printf '# fixture: a digest that matches nothing, so the gate runs and finds nothing\n' > "$NPLIST"
printf 'sha256:2:%s\n' "0000000000000000000000000000000000000000000000000000000000000000" >> "$NPLIST"
chmod 600 "$NPLIST"
# Every `app` invocation below goes through this: no signing key, and the names gate in
# whichever state the case is about.
APP_ENV=(env -u TAURI_SIGNING_PRIVATE_KEY -u TAURI_SIGNING_PRIVATE_KEY_PATH)

echo ""
echo "=== R. the release chain refuses out of order ==="

run "${REL[@]}" plan --tag "$TAG" --out "$OUTDIR"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$APP/src-tauri/Cargo.toml" | head -1)"
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Fq "$VERSION" \
   && printf '%s' "$OUT" | grep -Fq "releases/latest/download/latest.json" \
   && [ ! -d "$OUTDIR" ]; then
  ok "R1 plan names the version ($VERSION) and the endpoint, and creates nothing"
else
  bad "R1 plan names the version and the endpoint, and creates nothing" \
      "exit $CODE; staging dir exists: $( [ -d "$OUTDIR" ] && echo yes || echo no )"
fi

run "${REL[@]}" verify-engine --tag "$TAG" --out "$OUTDIR"
expect "R2 verify-engine with no pin refuses" 2 "no pin at"

# A local stand-in for the release host. The asset is a file whose only job is to have a
# digest; nothing here cares that it is not an engine.
SERVE="$TMP/serve"; mkdir -p "$SERVE" "$OUTDIR"
ENGINE_VERSION="$(tr -d '[:space:]' < "$APP/../engine/VERSION")"
ASSET="richos-engine-$ENGINE_VERSION.tar.gz"
printf 'the bytes that were published\n' > "$SERVE/$ASSET"
cp "$SERVE/$ASSET" "$OUTDIR/$ASSET"
GOOD_DIGEST="$(/usr/bin/shasum -a 256 "$SERVE/$ASSET" | awk '{print $1}')"

PORT="${RICHOS_RELEASE_TEST_PORT:-8975}"
( cd "$SERVE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
# Job control's own "Terminated" line would otherwise be the last thing this suite prints,
# after its verdict, which reads like a failure and is not one.
disown $SERVER_PID 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS -o /dev/null "http://127.0.0.1:$PORT/$ASSET" 2>/dev/null && break
  sleep 0.3
done
if ! curl -sS -o /dev/null "http://127.0.0.1:$PORT/$ASSET" 2>/dev/null; then
  echo "make-release.test.sh: could not serve a fixture on port $PORT (set RICHOS_RELEASE_TEST_PORT)." >&2
  exit 3
fi

write_pin() {  # write_pin <url> <digest>
  cat > "$OUTDIR/engine-pin.env" <<PIN
export RICHOS_ENGINE_VERSION=$ENGINE_VERSION
export RICHOS_ENGINE_URL=$1
export RICHOS_ENGINE_SHA256=$2
PIN
}

write_pin "http://127.0.0.1:$PORT/not-published.tar.gz" "$GOOD_DIGEST"
run "${REL[@]}" verify-engine --tag "$TAG" --out "$OUTDIR"
expect "R3 verify-engine against a URL that serves nothing refuses" 1 "inside a signed binary"

write_pin "http://127.0.0.1:$PORT/$ASSET" "0000000000000000000000000000000000000000000000000000000000000000"
run "${REL[@]}" verify-engine --tag "$TAG" --out "$OUTDIR"
expect "R4 verify-engine against bytes that are not the pinned bytes refuses" 1 "THE PUBLISHED BYTES ARE NOT THE PINNED BYTES"

write_pin "http://127.0.0.1:$PORT/$ASSET" "$GOOD_DIGEST"
run "${REL[@]}" verify-engine --tag "$TAG" --out "$OUTDIR"
if [ "$CODE" = 0 ] && grep -q "sha256=$GOOD_DIGEST" "$OUTDIR/engine-published.ok" 2>/dev/null; then
  ok "R5 verify-engine against the pinned bytes writes a receipt naming that digest"
else
  bad "R5 verify-engine against the pinned bytes writes a receipt naming that digest" \
      "exit $CODE; receipt: $(cat "$OUTDIR/engine-published.ok" 2>/dev/null | tr '\n' ' ')"
fi

# `app` never reaches a build in any case below: each refusal happens before it would.
NOPIN="$TMP/nopin"; mkdir -p "$NOPIN"

# R5a — THE GATE COMES FIRST, and this is the case that used to be made by accident, in red,
# on every machine that is not the owner's. With no deny-list the refusal must NOT be the pin
# refusal: `app` has to stop at the names gate before it has an opinion about staging.
run "${APP_ENV[@]}" RICHOS_NAMED_PERSONS_FILE="$TMP/a-list-that-does-not-exist" \
        bash "$SCRIPT" app --tag "$TAG" --out "$NOPIN"
#
# Both halves are asserted. The positive one is the sentence the gate prints on ABSENT —
# outside its once-per-session banner, so it appears on every invocation. The negative one
# is that "no pin at" is NOT in the output, which is what makes this a statement about
# ORDER rather than merely about a refusal happening.
if [ "$CODE" != 2 ]; then
  bad "R5a app with no deny-list refuses at the names gate, before the pin" \
      "exit $CODE, wanted 2. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-220)"
elif ! printf '%s' "$OUT" | grep -Fq "nothing is checking for names"; then
  bad "R5a app with no deny-list refuses at the names gate, before the pin" \
      "exit 2, but not from the names gate: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-220)"
elif printf '%s' "$OUT" | grep -Fq "no pin at"; then
  bad "R5a app with no deny-list refuses at the names gate, before the pin" \
      "it reached the pin check as well — the gate did not stop the run"
else
  ok "R5a app with no deny-list refuses at the names gate, before the pin"
fi

run "${APP_ENV[@]}" RICHOS_NAMED_PERSONS_FILE="$NPLIST" \
        bash "$SCRIPT" app --tag "$TAG" --out "$NOPIN"
expect "R6 app with no pin refuses" 2 "no pin at"

NORECEIPT="$TMP/noreceipt"; mkdir -p "$NORECEIPT"
cp "$OUTDIR/engine-pin.env" "$NORECEIPT/engine-pin.env"
run "${APP_ENV[@]}" RICHOS_NAMED_PERSONS_FILE="$NPLIST" \
        bash "$SCRIPT" app --tag "$TAG" --out "$NORECEIPT"
expect "R7 app with a pin and no receipt refuses" 2 "claim about a local file"

STALE="$TMP/stale"; mkdir -p "$STALE"
cp "$OUTDIR/engine-pin.env" "$STALE/engine-pin.env"
sed 's/^sha256=.*/sha256=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$OUTDIR/engine-published.ok" > "$STALE/engine-published.ok"
run "${APP_ENV[@]}" RICHOS_NAMED_PERSONS_FILE="$NPLIST" \
        bash "$SCRIPT" app --tag "$TAG" --out "$STALE"
expect "R8 app with a receipt for a different digest refuses" 2 "rebuilt after it was verified"

run "${APP_ENV[@]}" RICHOS_NAMED_PERSONS_FILE="$NPLIST" \
        bash "$SCRIPT" app --tag "$TAG" --out "$OUTDIR"
expect "R9 app with a good receipt and no signing key refuses" 2 "no updater signing key"

EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
run "${REL[@]}" verify-release --tag "$TAG" --out "$EMPTY"
expect "R10 verify-release with nothing staged refuses" 2 "no SHA256SUMS"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== make-release.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== make-release.test.sh: all $PASS passed ==="
