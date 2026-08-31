#!/usr/bin/env bash
#
# updater-setup.test.sh — the UPDATE PATH's configuration, its refusals, and the two
# artifacts, exercised without a release build.
#
# WHAT THIS SUITE CAN AND CANNOT PROVE, first, because the distinction is the whole reason
# it exists beside `updater-e2e.sh` rather than instead of it.
#
#   IT PROVES     every refusal in `package-app.sh --updater`, by running it; that the
#                 shipped config is wired the way the plugin needs; that the archive builder
#                 produces something installable and REFUSES the four shapes that are not;
#                 and that the signature verifier verifies a good pair and REFUSES a
#                 tampered one and a wrong-key one. It runs in seconds.
#
#   IT CANNOT     prove that an update applies. That is a claim about a signed .app.tar.gz
#                 replacing a RUNNING bundle, and it is proven by `app/scripts/updater-e2e.sh`,
#                 which builds 0.1.0 and 0.1.1 and makes one become the other on this machine.
#                 Nothing here is a substitute for that, and this header exists so nobody
#                 reads a green run as one.
#
# Cases:
#   A1  --updater with no signing key refuses, and says why there is no fallback
#   A2  --updater with a key path that does not exist refuses
#   A3  --updater with the key INSIDE a git worktree refuses (a leaked updater key cannot
#       be revoked — the public half is compiled into every installed copy)
#   A4  --updater with a world-readable key refuses
#   A5  --updater with a real key, outside a repo, mode 600, RESOLVES
#   A6  ...and says NO MANIFEST when RICHOS_UPDATE_BASE_URL is unset
#   A7  ...and names the URL when it is set
#   B1  tauri.conf.json declares createUpdaterArtifacts
#   B2  ...an endpoint, and it is the RFC 2606 placeholder rather than a guessed host
#   B3  ...a pubkey that is a decodable minisign public key
#   B4  the webview is granted NO updater permission, and the capability says why
#   B5  the build always passes --no-sign (the bundler would otherwise sign a tarball of an
#       unsigned app, and a keyless build would fail outright)
#   C1  the archive builder roots every member at one .app
#   C2  ...preserves the executable bit
#   C3  ...preserves symlinks rather than dereferencing them
#   C4  ...and writes no AppleDouble members
#   D1  `verify` refuses an archive rooted at two different names
#   D2  `verify` refuses an archive with no Info.plist
#   D3  `verify` refuses an archive with an AppleDouble member
#   D4  `verify` refuses an archive with nothing executable in it
#   E1  the signature verifier VERIFIES a good pair against the shipped pubkey
#   E2  ...REFUSES a tampered artifact, and says so as a signature refusal
#   E3  ...REFUSES a correctly-formed signature from a different key
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$SRC_DIR/.." && pwd)"
SCRIPT="$SRC_DIR/package-app.sh"
TAR_PY="$SRC_DIR/lib/updater_tar.py"
CONF="$APP/src-tauri/tauri.conf.json"
CAPS="$APP/src-tauri/capabilities/default.json"

TMP="$(mktemp -d -t updater-setup-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  PATH="$HOME/.cargo/bin:$PATH"; export PATH
fi

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

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

# A key OUTSIDE every repository, made fresh for this suite. Never the operator's real one:
# a suite that reads a release key is a suite that can leak one.
KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
KEY="$KEYDIR/suite.key"
cargo tauri signer generate -w "$KEY" -p "" --ci >/dev/null 2>&1
if [ ! -f "$KEY" ]; then
  echo "updater-setup.test.sh: could not generate a test key (is the Tauri CLI installed?)" >&2
  exit 3
fi
chmod 600 "$KEY"

echo ""
echo "=== A. the updater signing key, and the refusals ==="

run env -u TAURI_SIGNING_PRIVATE_KEY -u TAURI_SIGNING_PRIVATE_KEY_PATH bash "$SCRIPT" --updater --dry-run
expect "A1 --updater with no key refuses, and says there is no fallback" 2 "no fallback and there must not be"

run env TAURI_SIGNING_PRIVATE_KEY_PATH="$TMP/nope.key" bash "$SCRIPT" --updater --dry-run
expect "A2 a key path that does not exist refuses" 2 "TAURI_SIGNING_PRIVATE_KEY_PATH does not exist"

# A3: a key inside a git worktree. `app/` itself is one, so this needs no fixture repo.
cp "$KEY" "$TMP/in-repo.key"
INREPO="$APP/.updater-key-under-test.key"
cp "$KEY" "$INREPO"
chmod 600 "$INREPO"
run env TAURI_SIGNING_PRIVATE_KEY_PATH="$INREPO" bash "$SCRIPT" --updater --dry-run
expect "A3 a key inside a git worktree refuses" 2 "inside a git worktree"
rm -f "$INREPO"

cp "$KEY" "$KEYDIR/loose.key"; chmod 644 "$KEYDIR/loose.key"
run env TAURI_SIGNING_PRIVATE_KEY_PATH="$KEYDIR/loose.key" bash "$SCRIPT" --updater --dry-run
expect "A4 a world-readable key refuses" 2 "readable by other users"

run env TAURI_SIGNING_PRIVATE_KEY_PATH="$KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" bash "$SCRIPT" --updater --dry-run
expect "A5 a real key, outside a repo, mode 600, resolves" 0 "update artifacts    : ON"

expect "A6 ...and no manifest is written without RICHOS_UPDATE_BASE_URL" 0 "NOT written"

run env TAURI_SIGNING_PRIVATE_KEY_PATH="$KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" \
        RICHOS_UPDATE_BASE_URL="https://updates.example.com/richos" \
        bash "$SCRIPT" --updater --dry-run
expect "A7 ...and names the base URL when it is set" 0 "https://updates.example.com/richos"

echo ""
echo "=== B. the shipped configuration ==="

conf_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));
p=sys.argv[2].split(".");
for k in p:
    d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
print("" if d is None else (json.dumps(d) if not isinstance(d,str) else d))' "$CONF" "$1"; }

if [ "$(conf_get bundle.createUpdaterArtifacts)" = "true" ]; then
  ok "B1 bundle.createUpdaterArtifacts is on — without it no update artifact is ever made"
else
  bad "B1 bundle.createUpdaterArtifacts is on" "it is: '$(conf_get bundle.createUpdaterArtifacts)'"
fi

ENDPOINT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"]["updater"]["endpoints"][0])' "$CONF" 2>/dev/null)"
if printf '%s' "$ENDPOINT" | grep -q '\.invalid/'; then
  ok "B2 the endpoint is the RFC 2606 .invalid placeholder, not a guessed host"
else
  bad "B2 the endpoint is the RFC 2606 .invalid placeholder, not a guessed host" \
      "it is '$ENDPOINT' — if a real host has been chosen, this case is what tells you to update app/UPDATES.md too"
fi

PUBKEY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"]["updater"]["pubkey"])' "$CONF" 2>/dev/null)"
if printf '%s' "$PUBKEY" | base64 -d 2>/dev/null | grep -q "minisign public key"; then
  ok "B3 the pubkey decodes to a minisign public key"
else
  bad "B3 the pubkey decodes to a minisign public key" "it does not — the app would refuse every update it is offered"
fi

# PARSED, NOT GREPPED, and that is not fussiness: the first version of this case
# grepped the whole file for `updater:` and failed on the capability's own
# DESCRIPTION, which explains at length why `updater:default` is not granted. A
# check that cannot tell a permission from a sentence about a permission is a check
# that punishes documenting the thing it is checking.
PERMS="$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["permissions"]))' "$CAPS")"
if printf '%s' "$PERMS" | grep -q 'core:default' && ! printf '%s' "$PERMS" | grep -q 'updater'; then
  if grep -q 'NOTE ON THE UPDATER' "$CAPS"; then
    ok "B4 the webview holds NO updater permission, and the capability file says why"
  else
    bad "B4 the webview holds NO updater permission, and the capability file says why" \
        "the permission is correctly absent, but nothing in the file explains it — an absent permission reads as an omission"
  fi
else
  bad "B4 the webview holds NO updater permission" "the granted permissions are: $PERMS"
fi

if grep -q 'build_args=(tauri build --no-sign' "$SCRIPT"; then
  ok "B5 the build always passes --no-sign, so the bundler never signs a tarball of an unsigned app"
else
  bad "B5 the build always passes --no-sign" \
      "without it, tauri-cli signs the tarball it made BEFORE package-app.sh signed the bundle — and a keyless build fails outright"
fi

echo ""
echo "=== C. the archive builder, against a real bundle skeleton ==="

FAKE="$TMP/Fake.app"
mkdir -p "$FAKE/Contents/MacOS" "$FAKE/Contents/Resources" "$FAKE/Contents/Frameworks/X.framework/Versions/A"
printf 'binary\n' > "$FAKE/Contents/MacOS/fake"; chmod 755 "$FAKE/Contents/MacOS/fake"
printf '<plist/>\n' > "$FAKE/Contents/Info.plist"
printf 'icon\n' > "$FAKE/Contents/Resources/icon.icns"
ln -s "Versions/A" "$FAKE/Contents/Frameworks/X.framework/Current"

run python3 "$TAR_PY" build "$FAKE" "$TMP/fake.tar.gz"
if [ "$CODE" != 0 ]; then
  bad "C0 the archive was built" "$OUT"
else
  MEMBERS="$(python3 -c 'import tarfile,sys;print("\n".join(tarfile.open(sys.argv[1]).getnames()))' "$TMP/fake.tar.gz")"
  ROOTS="$(printf '%s\n' "$MEMBERS" | cut -d/ -f1 | sort -u | tr '\n' ' ')"
  if [ "$(printf '%s\n' "$MEMBERS" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')" = "1" ] \
     && printf '%s' "$ROOTS" | grep -q "Fake.app"; then
    ok "C1 every member is rooted at the one .app (the updater DROPS the first component)"
  else
    bad "C1 every member is rooted at the one .app" "roots: $ROOTS"
  fi

  EXEC_COUNT="$(python3 -c 'import tarfile,sys
t=tarfile.open(sys.argv[1]);print(sum(1 for m in t.getmembers() if m.isreg() and m.mode & 0o111))' "$TMP/fake.tar.gz")"
  if [ "$EXEC_COUNT" -ge 1 ]; then
    ok "C2 the executable bit survives (without it the installed app cannot launch)"
  else
    bad "C2 the executable bit survives" "no member carries one"
  fi

  SYM_COUNT="$(python3 -c 'import tarfile,sys
t=tarfile.open(sys.argv[1]);print(sum(1 for m in t.getmembers() if m.issym()))' "$TMP/fake.tar.gz")"
  if [ "$SYM_COUNT" -ge 1 ]; then
    ok "C3 symlinks stay symlinks (a framework's Current/ is one, and copying it doubles the bundle)"
  else
    bad "C3 symlinks stay symlinks" "the archive contains none — they were dereferenced"
  fi

  if printf '%s\n' "$MEMBERS" | grep -q '/\._'; then
    bad "C4 no AppleDouble members" "the archive carries ._ sidecars, which the updater would unpack into the app"
  else
    ok "C4 no AppleDouble members — bsdtar's xattr sidecars are not in here"
  fi

  run python3 "$TAR_PY" verify "$TMP/fake.tar.gz"
  expect "C5 verify passes its own output" 0 "OK:"
fi

echo ""
echo "=== D. the archive verifier refuses what it should ==="

mkbad() {  # mkbad <name> <python that fills `t`>
  python3 - "$TMP/$1" <<PY
import tarfile, io, sys, os
path = sys.argv[1]
t = tarfile.open(path, "w:gz")
def add(name, data=b"x", mode=0o644, sym=None):
    info = tarfile.TarInfo(name)
    if sym is not None:
        info.type = tarfile.SYMTYPE
        info.linkname = sym
        t.addfile(info)
        return
    info.size = len(data); info.mode = mode
    t.addfile(info, io.BytesIO(data))
$2
t.close()
PY
}

mkbad two-roots.tar.gz 'add("A.app/Contents/Info.plist"); add("A.app/Contents/MacOS/a", mode=0o755); add("B.app/Contents/Info.plist")'
run python3 "$TAR_PY" verify "$TMP/two-roots.tar.gz"
expect "D1 two roots -> refused (the updater drops only the FIRST component)" 1 "different names"

mkbad no-plist.tar.gz 'add("A.app/Contents/MacOS/a", mode=0o755)'
run python3 "$TAR_PY" verify "$TMP/no-plist.tar.gz"
expect "D2 no Info.plist -> refused (it would extract into an empty bundle)" 1 "Info.plist"

mkbad appledouble.tar.gz 'add("A.app/Contents/Info.plist"); add("A.app/Contents/MacOS/a", mode=0o755); add("A.app/Contents/._Info.plist")'
run python3 "$TAR_PY" verify "$TMP/appledouble.tar.gz"
expect "D3 an AppleDouble member -> refused" 1 "AppleDouble"

mkbad nothing-exec.tar.gz 'add("A.app/Contents/Info.plist"); add("A.app/Contents/MacOS/a", mode=0o644)'
run python3 "$TAR_PY" verify "$TMP/nothing-exec.tar.gz"
expect "D4 nothing executable -> refused (the installed app cannot launch)" 1 "executable bit"

echo ""
echo "=== E. the signature verifier — the check the signer's exit code does not make ==="

# The verifier is checked against a CONFIG whose pubkey is this suite's key, so the cases
# are about the arithmetic and not about the repository's own key. E1-E3 are the same three
# outcomes the CEO's machine can have.
SUITE_CONF="$TMP/suite.conf.json"
python3 - "$SUITE_CONF" "$KEY.pub" <<'PY'
import base64, json, sys
conf, pub = sys.argv[1], sys.argv[2]
json.dump({"plugins": {"updater": {"pubkey": open(pub).read().strip()}}}, open(conf, "w"))
PY

printf 'a released artifact\n' > "$TMP/art.bin"
(cd "$APP/src-tauri" && cargo tauri signer sign -f "$KEY" -p "" "$TMP/art.bin" >/dev/null 2>&1)

VERIFY=(cargo run -q --example verify_update_signature --)
run env -C "$APP/src-tauri" "${VERIFY[@]}" "$TMP/art.bin" "$TMP/art.bin.sig" "$SUITE_CONF"
expect "E1 a good pair VERIFIES against the pubkey in the config" 0 "VERIFIED"

printf 'a released artifact!\n' > "$TMP/tampered.bin"
cp "$TMP/art.bin.sig" "$TMP/tampered.bin.sig"
run env -C "$APP/src-tauri" "${VERIFY[@]}" "$TMP/tampered.bin" "$TMP/tampered.bin.sig" "$SUITE_CONF"
expect "E2 a TAMPERED artifact is REFUSED" 1 "REFUSED"

OTHER="$KEYDIR/other.key"
cargo tauri signer generate -w "$OTHER" -p "" --ci >/dev/null 2>&1
cp "$TMP/art.bin" "$TMP/otherkey.bin"
(cd "$APP/src-tauri" && cargo tauri signer sign -f "$OTHER" -p "" "$TMP/otherkey.bin" >/dev/null 2>&1)
run env -C "$APP/src-tauri" "${VERIFY[@]}" "$TMP/otherkey.bin" "$TMP/otherkey.bin.sig" "$SUITE_CONF"
expect "E3 a well-formed signature from ANOTHER key is REFUSED" 1 "REFUSED"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== updater-setup.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== updater-setup.test.sh: all $PASS passed ==="
