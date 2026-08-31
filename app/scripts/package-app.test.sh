#!/usr/bin/env bash
#
# package-app.test.sh — the signing configuration and the bundle verification,
# exercised as far as they can be without a Developer ID certificate.
#
# WHAT THIS SUITE CAN AND CANNOT PROVE, stated first because the distinction is
# the whole reason it exists.
#
#   IT PROVES     every refusal, by running it; the identity DISCOVERY rule on 0,
#                 1 and 2 identities; that discovery never self-selects the
#                 developer-id path; the notary credential rules including the
#                 in-repo and world-readable refusals; and every branch of
#                 verify_bundle's developer-id arm, fired against a REAL signed
#                 bundle.
#
#   IT CANNOT     prove that a Developer ID signature works. No certificate exists
#                 on any machine here (`security find-identity -v -p codesigning`
#                 reports 0), so nothing has ever been signed with one, notarized
#                 or stapled. Sections B and C therefore run against a `security`
#                 SHIM that reports synthetic identities. That shim proves what the
#                 SCRIPT does with an inventory; it proves nothing about codesign.
#                 Where the shim is used, the case name says so.
#
# THE FIXTURE BUNDLE IS REAL, and this is the part that surprised the author.
# package-app.sh cannot build anything on this tree at all: the icon gate refuses
# on the placeholder icon set (CEO item 2.6, the artwork, still open), so there was
# no bundle to verify against. But verify_bundle takes a PATH — it does not care
# who produced it. So section D builds a minimal .app by hand, ad-hoc signs it with
# the real codesign, and points the real --verify-only at it. Every developer-id
# check then fires against a genuine signature that is genuinely not a Developer ID
# one, which is exactly the negative half, and the mutations in D3-D7 turn the
# positive half red one reason at a time.
#
# Cases:
#   A1  an unknown argument is refused, never ignored
#   A2  --sign with a value that is neither mode is refused
#   A3  --help prints the usage, including the notarize and dry-run forms
#   B1  developer-id with NO Developer ID identity refuses, and names the two scripts
#   B2  developer-id with RICHOS_SIGNING_IDENTITY the machine does not report refuses
#   B3  developer-id with exactly ONE identity DISCOVERS it   [shim]
#   B4  developer-id with TWO refuses and lists both rather than sorting  [shim]
#   B5  a plain (ad-hoc) run with an identity present does NOT use it     [shim]
#   C1  RICHOS_NOTARIZE=1 with no credentials refuses                     [shim]
#   C2  a half-supplied API key refuses and names the missing parts       [shim]
#   C3  a key path that does not exist refuses                            [shim]
#   C4  a key INSIDE a git worktree refuses                               [shim]
#   C5  a world-readable key refuses                                      [shim]
#   C6  a complete key, outside a repo, mode 600, resolves                 [shim]
#   C7  RICHOS_NOTARY_PROFILE alone resolves                              [shim]
#   C8  APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID are NOT accepted        [shim]
#   D1  a real ad-hoc bundle passes --verify-only in adhoc mode
#   D2  ...and FAILS in developer-id mode on all EIGHT developer-id grounds —
#       authority, hardened runtime, timestamp, entitlement, and the four separate
#       clauses of the designated requirement
#   D3  a missing shipped icon fails
#   D4  a shipped icon that is not this repository's fails
#   D5  a missing NSMicrophoneUsageDescription fails
#   D6  a bundle whose signature was removed fails
#   D7  --expect-notarized fires the stapled-ticket check
#   Z   the operator's real keychain inventory is unchanged by this suite
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SRC_DIR/package-app.sh"
APP_DIR="$(cd "$SRC_DIR/.." && pwd)"

TMP="$(mktemp -d -t package-app-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REAL_IDS_BEFORE="$(security find-identity -v -p codesigning 2>/dev/null || true)"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# --- run the script, capture output and code ------------------------------
run() { OUT="$("$@" 2>&1)"; CODE=$?; return 0; }

expect() {   # expect <name> <wanted-code> <substring>
  local name="$1" want="$2" needle="$3"
  if [ "$CODE" != "$want" ]; then
    bad "$name" "exit $CODE, wanted $want. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
  elif ! printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    bad "$name" "exit $want as wanted, but the output never said '$needle'"
  else
    ok "$name"
  fi
}

# --------------------------------------------------------------------------
# The shim. `security` and `cargo` only, on a PATH prefix, for the cases whose
# names say [shim]. Nothing else is faked: python3, codesign, PlistBuddy and the
# script itself are the real ones.
# --------------------------------------------------------------------------
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/security" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "find-identity" ]; then
  n="${SHIM_IDENTITIES:-0}"
  i=1
  while [ "$i" -le "$n" ]; do
    printf '  %d) DEADBEEF%04d "Developer ID Application: Test Person (TEAM%05d)"\n' "$i" "$i" "$i"
    i=$((i + 1))
  done
  printf '     %s valid identities found\n' "$n"
  exit 0
fi
exit 1
EOF
cat > "$SHIM/cargo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "tauri" ] && [ "${2:-}" = "--version" ] && { echo "tauri-cli 2.11.4"; exit 0; }
echo "shimmed cargo refuses to do anything else" >&2
exit 1
EOF
chmod +x "$SHIM/security" "$SHIM/cargo"
shimmed() { env PATH="$SHIM:$PATH" "$@"; }

echo ""
echo "=== A. arguments ==="
run bash "$SCRIPT" --wat
expect "A1 an unknown argument is refused" 2 "unknown argument"
run bash "$SCRIPT" --sign sortof
expect "A2 --sign takes only the two modes" 2 "must be 'adhoc' or 'developer-id'"
run bash "$SCRIPT" --help
expect "A3 --help shows the notarize form" 0 "RICHOS_NOTARIZE=1 app/scripts/package-app.sh --sign developer-id"

echo ""
echo "=== B. identity discovery ==="
run bash "$SCRIPT" --sign developer-id --dry-run
expect "B1 no Developer ID identity -> refuse, and name the setup scripts" 2 "install-signing-cert.sh"
run env RICHOS_SIGNING_IDENTITY="Developer ID Application: Ghost (NOPE)" bash "$SCRIPT" --sign developer-id --dry-run
expect "B2 a pinned identity the machine does not report -> refuse" 2 "does not report it on this"

run shimmed env SHIM_IDENTITIES=1 bash "$SCRIPT" --sign developer-id --dry-run
expect "B3 [shim] exactly one identity is DISCOVERED" 0 "discovered the one Developer ID Application identity"
if printf '%s' "$OUT" | grep -q "identity came from  : discovery"; then
  ok "B3b [shim] ...and the dry run says WHERE the identity came from"
else
  bad "B3b the dry run did not attribute the identity to discovery" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
fi

run shimmed env SHIM_IDENTITIES=2 bash "$SCRIPT" --sign developer-id --dry-run
expect "B4 [shim] two identities -> refuse rather than sort" 2 "2 Developer ID Application identities are on this machine"

run shimmed env SHIM_IDENTITIES=1 bash "$SCRIPT" --dry-run
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q "signing mode        : adhoc" \
   && printf '%s' "$OUT" | grep -q "LOUD NOTE"; then
  ok "B5 [shim] an identity on the machine does not make a plain run use it"
else
  bad "B5 a plain run either used the identity or stopped saying one was available" "exit $CODE"
fi

echo ""
echo "=== C. notary credentials ==="
notarize() { shimmed env SHIM_IDENTITIES=1 RICHOS_NOTARIZE=1 "$@" bash "$SCRIPT" --sign developer-id --dry-run; }

run notarize
expect "C1 [shim] notarize with no credentials -> refuse" 2 "no APPLE_PASSWORD path"
run notarize RICHOS_NOTARY_KEY_ID=ABCDE12345
expect "C2 [shim] half an API key -> refuse, naming the missing halves" 2 "RICHOS_NOTARY_KEY RICHOS_NOTARY_ISSUER"

KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"
KEY="$KEYDIR/AuthKey_ABCDE12345.p8"
printf 'not a real key\n' > "$KEY"; chmod 600 "$KEY"

run notarize RICHOS_NOTARY_KEY="$KEYDIR/gone.p8" RICHOS_NOTARY_KEY_ID=ABCDE12345 RICHOS_NOTARY_ISSUER=uuid
expect "C3 [shim] a key path that does not exist -> refuse" 2 "downloaded exactly once"

# C4 needs a real git worktree, because the check asks git rather than the string.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
printf 'not a real key\n' > "$REPO/AuthKey_ABCDE12345.p8"; chmod 600 "$REPO/AuthKey_ABCDE12345.p8"
run notarize RICHOS_NOTARY_KEY="$REPO/AuthKey_ABCDE12345.p8" RICHOS_NOTARY_KEY_ID=ABCDE12345 RICHOS_NOTARY_ISSUER=uuid
expect "C4 [shim] a notary key inside a git worktree -> refuse" 2 "is inside a git worktree"

chmod 644 "$KEY"
run notarize RICHOS_NOTARY_KEY="$KEY" RICHOS_NOTARY_KEY_ID=ABCDE12345 RICHOS_NOTARY_ISSUER=uuid
expect "C5 [shim] a world-readable notary key -> refuse" 2 "readable by other users of this Mac"
chmod 600 "$KEY"

run notarize RICHOS_NOTARY_KEY="$KEY" RICHOS_NOTARY_KEY_ID=ABCDE12345 RICHOS_NOTARY_ISSUER=uuid
expect "C6 [shim] a complete API key resolves" 0 "notarization        : ON via App Store Connect API key ABCDE12345"
run notarize RICHOS_NOTARY_PROFILE=richos
expect "C7 [shim] a keychain profile resolves" 0 "keychain profile 'richos'"
run notarize APPLE_ID=a@b.com APPLE_PASSWORD=abcd-efgh-ijkl-mnop APPLE_TEAM_ID=TEAM00001
expect "C8 [shim] APPLE_ID/PASSWORD/TEAM_ID are NOT a credential path here" 2 "no APPLE_PASSWORD path"

echo ""
echo "=== D. verify_bundle, against a real signed bundle ==="
# A sandbox whose layout package-app.sh derives from its own location: the real
# script, symlinked, beside a synthetic src-tauri holding the icon it compares
# against. The bundle below is signed by the real codesign.
SB="$TMP/sandbox"; mkdir -p "$SB/scripts" "$SB/src-tauri/icons"
ln -s "$SCRIPT" "$SB/scripts/package-app.sh"
head -c 4096 /dev/urandom > "$SB/src-tauri/icons/icon.icns"
SBS="$SB/scripts/package-app.sh"

make_bundle() {   # make_bundle <dir>
  local b="$1"
  rm -rf "$b"; mkdir -p "$b/Contents/MacOS" "$b/Contents/Resources"
  cp /bin/echo "$b/Contents/MacOS/RichOS"
  cp "$SB/src-tauri/icons/icon.icns" "$b/Contents/Resources/icon.icns"
  cat > "$b/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RichOS</string>
<key>CFBundleIdentifier</key><string>com.richos.app</string>
<key>CFBundleName</key><string>RichOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSMicrophoneUsageDescription</key><string>Rich listens when you tap the talk button.</string>
</dict></plist>
PLIST
  codesign --force --sign - --timestamp=none "$b" >/dev/null 2>&1
}

BUNDLE="$TMP/RichOS.app"
make_bundle "$BUNDLE"

run bash "$SBS" --verify-only "$BUNDLE"
expect "D1 a real ad-hoc bundle verifies in adhoc mode" 0 "OK: RichOS.app verifies"

run bash "$SBS" --verify-only "$BUNDLE" --sign developer-id
missing=""
for needle in \
  "expected a Developer ID Application signature" \
  "hardened runtime is NOT enabled" \
  "no secure timestamp on the signature" \
  "com.apple.security.device.audio-input is not in the signed entitlements" \
  "designated requirement is a cdhash expression" \
  "does not pin the bundle identifier 'com.richos.app'" \
  "has no 'anchor apple generic' clause" \
  "does not pin the team (certificate leaf[subject.OU])"
do
  printf '%s' "$OUT" | grep -Fq -- "$needle" || missing="$missing | $needle"
done
if [ "$CODE" = 1 ] && [ -z "$missing" ]; then
  ok "D2 ...and fails in developer-id mode on all EIGHT grounds, four of them on the requirement"
else
  bad "D2 the developer-id arm did not fire completely" "exit $CODE; not reported:$missing"
fi

make_bundle "$BUNDLE"; rm -f "$BUNDLE/Contents/Resources/icon.icns"
run bash "$SBS" --verify-only "$BUNDLE"
expect "D3 a bundle with no shipped icon fails" 1 "Contents/Resources/icon.icns is missing"

make_bundle "$BUNDLE"; head -c 4096 /dev/urandom > "$BUNDLE/Contents/Resources/icon.icns"
run bash "$SBS" --verify-only "$BUNDLE"
expect "D4 a shipped icon this repository did not generate fails" 1 "carrying an icon this repository did not generate"

make_bundle "$BUNDLE"
/usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1
run bash "$SBS" --verify-only "$BUNDLE"
expect "D5 no NSMicrophoneUsageDescription fails" 1 "voice mode cannot even ask for the microphone"

make_bundle "$BUNDLE"; codesign --remove-signature "$BUNDLE" >/dev/null 2>&1
run bash "$SBS" --verify-only "$BUNDLE"
expect "D6 a bundle whose signature was removed fails" 1 "codesign --verify --deep --strict FAILED"

make_bundle "$BUNDLE"
run bash "$SBS" --verify-only "$BUNDLE" --sign developer-id --expect-notarized
expect "D7 --expect-notarized runs the stapled-ticket check" 1 "no valid stapled notarization ticket"

echo ""
echo "=== Z. this suite touched nothing of the operator's ==="
REAL_IDS_AFTER="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ "$REAL_IDS_AFTER" = "$REAL_IDS_BEFORE" ]; then
  ok "Z the real keychain's codesigning inventory is identical before and after"
else
  bad "Z THE SUITE CHANGED THE REAL KEYCHAIN" "before='$REAL_IDS_BEFORE' after='$REAL_IDS_AFTER'"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== package-app tests: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== package-app tests: all $PASS passed ==="
