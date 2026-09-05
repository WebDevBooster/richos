#!/usr/bin/env bash
#
# make-release.sh — one RichOS release, in the order the chain forces, with every claim
# checked against the artifact rather than against an exit code.
#
#   app/scripts/make-release.sh plan             # what this release will be. Touches nothing.
#   app/scripts/make-release.sh engine           # build the deterministic engine asset + the pin
#   app/scripts/make-release.sh verify-engine    # download the PUBLISHED asset, require the pin
#   app/scripts/make-release.sh app              # build the app against the verified pin
#   app/scripts/make-release.sh verify-release   # download everything published, require SHA256SUMS
#
# THE ORDER IS NOT A PREFERENCE
#
# The app carries the engine's URL and SHA-256 as COMPILE-TIME constants
# (`richos-core/src/setup.rs::engine_pin`), inside the executable the Developer ID
# signature covers. So the engine asset has to exist at its URL before the app that pins it
# is compiled, and the digest that goes into the binary has to be computed from the bytes
# that will actually be served — not from a local file that is merely believed to be the
# same. `verify-engine` downloads the published asset and refuses if it differs; `app`
# refuses to build until `verify-engine` has written its receipt for the current pin.
#
# A pin is not a promise. It is a claim about bytes that are already there, and the only
# way to know is to fetch them.
#
# WHAT UPLOADS, AND IN WHICH ORDER
#
# Nothing here touches the network except `verify-engine` and `verify-release`, both of
# which only READ. Creating the release and uploading the assets is a human's decision;
# this script prints the exact commands and the order they have to run in.
#
#   1. create the release for the tag
#   2. upload the engine asset            <- before the app is compiled
#   3. verify-engine                      <- the digest, off the wire
#   4. app                                <- compiles the verified pin in
#   5. upload the app archive, its .sig, the first-install zip and SHA256SUMS
#   6. upload latest.json LAST
#   7. verify-release
#
# latest.json is last because the updater endpoint is
# `.../releases/latest/download/latest.json` and GitHub resolves `latest` to whatever the
# newest release is. From the moment this release becomes the newest, that manifest is what
# every installed copy fetches — so it must not exist before the archive it names does. A
# manifest naming a file that is not there yet is an update that fails for everybody, at the
# one moment nobody is watching.
#
# And an engine-only release must be marked pre-release, or it becomes "latest" and takes
# `latest.json` away from every installed copy. Measured 2026-09-04: two live public Tauri
# projects are in exactly that state, their endpoints answering 404.
#
# Exit codes: 0 done. 1 an artifact failed a check. 2 refused before doing anything.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
repo_root="$(cd "$app_dir/.." && pwd)"
src_tauri="$app_dir/src-tauri"

REPO="WebDevBooster/richos"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn ""; warn "REFUSING — $1"; exit "${2:-2}"; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------------
cmd="${1:-}"
[ -n "$cmd" ] && shift || { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

TAG=""
NOTES="${RICHOS_UPDATE_NOTES:-}"
OUT=""
SIGN_MODE="developer-id"
NOTARIZE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          TAG="${2:-}"; shift 2 ;;
    --tag=*)        TAG="${1#*=}"; shift ;;
    --notes)        NOTES="${2:-}"; shift 2 ;;
    --notes=*)      NOTES="${1#*=}"; shift ;;
    --out)          OUT="${2:-}"; shift 2 ;;
    --out=*)        OUT="${1#*=}"; shift ;;
    --sign)         SIGN_MODE="${2:-}"; shift 2 ;;
    --sign=*)       SIGN_MODE="${1#*=}"; shift ;;
    --no-notarize)  NOTARIZE=0; shift ;;
    -h|--help)      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  PATH="$HOME/.cargo/bin:$PATH"; export PATH
fi

# ---------------------------------------------------------------------------------------
# THE VERSION IS READ, NEVER TYPED, AND IT IS READ FROM ONE PLACE
#
# `app/src-tauri/Cargo.toml` is the only file that carries the application version:
# `tauri.conf.json` deliberately has no `version` key, and tauri-utils 2.9.3
# (`config.rs:3612`) then takes it from the Cargo manifest. The tag, the update base URL,
# the first-install archive's name and the manifest all derive from it here, and the
# manifest's own `version` is read back off the PRODUCED bundle's Info.plist by
# `package-app.sh` — so a build that somehow disagreed would be caught rather than
# announced.
# ---------------------------------------------------------------------------------------
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$src_tauri/Cargo.toml" | head -1)"
[ -n "$VERSION" ] || die "no version in $src_tauri/Cargo.toml"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' || die "'$VERSION' is not a semver version"

python3 -c 'import json,sys;sys.exit(1 if "version" in json.load(open(sys.argv[1])) else 0)' \
  "$src_tauri/tauri.conf.json" \
  || die "tauri.conf.json carries a \`version\` key. It OVERRIDES Cargo.toml, so the
  version would be written in two places and the wrong one could win silently. Remove it."

ENGINE_VERSION="$(tr -d '[:space:]' < "$repo_root/engine/VERSION")"
[ -n "$ENGINE_VERSION" ] || die "engine/VERSION is empty"

[ -n "$TAG" ] || TAG="v$VERSION"
[ -n "$OUT" ] || OUT="$app_dir/target/release-staging/$TAG"

case "$(uname -m)" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64)        ARCH="x86_64" ;;
  *)             ARCH="$(uname -m)" ;;
esac
PLATFORM_KEY="darwin-$ARCH"

ENGINE_ASSET="richos-engine-$ENGINE_VERSION.tar.gz"
UPDATE_ASSET="RichOS.app.tar.gz"
INSTALL_ASSET="RichOS-$VERSION-macos-$ARCH.zip"
# THE SAME BYTES UNDER A NAME THAT NEVER CHANGES, so a link can outlive a release.
#
# `/releases/latest/download/<name>` only resolves if <name> is identical in every release,
# and the versioned name above is by construction never identical twice. So the home-page
# README had to spell out a version, and on 2026-09-04 it still said 1.0.0 while 1.0.1 was
# the current release: the link worked, then told the reader to download a file that was not
# there. A copy under a stable name removes the class, and it removes the second half of the
# problem too -- a stranger landing on the releases page had six files and no way to tell
# which was the app.
#
# It is a COPY, not a rename: the versioned name is what SHA256SUMS, the audit trail and
# every past link refer to, and provenance is worth more than ten megabytes. Both names are
# checksummed, because `write_sums` covers everything staged -- so the duplication is stated
# in the release's own manifest rather than being a thing you have to know.
STABLE_ASSET="RichOS-macos-$ARCH.zip"
MANIFEST_ASSET="latest.json"
SUMS_ASSET="SHA256SUMS"

DOWNLOAD_BASE="https://github.com/$REPO/releases/download/$TAG"
ENGINE_URL="$DOWNLOAD_BASE/$ENGINE_ASSET"
UPDATE_URL="$DOWNLOAD_BASE/$UPDATE_ASSET"
ENDPOINT="https://github.com/$REPO/releases/latest/download/$MANIFEST_ASSET"

PIN_FILE="$OUT/engine-pin.env"
RECEIPT="$OUT/engine-published.ok"

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# The endpoint compiled into the app has to be the one this release publishes to. If those
# two ever drift, every claim below is about a file nobody fetches.
CONFIGURED_ENDPOINT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"]["updater"]["endpoints"][0])' "$src_tauri/tauri.conf.json")"
[ "$CONFIGURED_ENDPOINT" = "$ENDPOINT" ] || die "tauri.conf.json's updater endpoint is
    $CONFIGURED_ENDPOINT
  and this release publishes its manifest to
    $ENDPOINT
  One of the two is wrong, and an installed copy would fetch the first."

# ---------------------------------------------------------------------------------------
plan() {
  rule
  say "RichOS $VERSION — release $TAG"
  rule
  say "  application version : $VERSION            (app/src-tauri/Cargo.toml, the only copy)"
  say "  engine version      : $ENGINE_VERSION            (engine/VERSION)"
  say "  platform key        : $PLATFORM_KEY   (tauri_plugin_updater::target())"
  say "  repository          : $REPO"
  say "  staging directory   : $OUT"
  say ""
  say "  assets, and the URL each will live at:"
  say "    $ENGINE_ASSET"
  say "        $ENGINE_URL"
  say "    $UPDATE_ASSET + $UPDATE_ASSET.sig"
  say "        $UPDATE_URL"
  say "    $INSTALL_ASSET      (the first install — a stapled .app, archived with ditto)"
  say "    $STABLE_ASSET            (the same bytes under a name that never changes)"
  say "        https://github.com/$REPO/releases/latest/download/$STABLE_ASSET"
  say "        $DOWNLOAD_BASE/$INSTALL_ASSET"
  say "    $MANIFEST_ASSET                      (uploaded LAST)"
  say "        $DOWNLOAD_BASE/$MANIFEST_ASSET"
  say "    $SUMS_ASSET"
  say "        $DOWNLOAD_BASE/$SUMS_ASSET"
  say ""
  say "  the endpoint every installed copy fetches, unchanging across releases:"
  say "    $ENDPOINT"
  rule
}

# ---------------------------------------------------------------------------------------
# names_gate — NOBODY'S NAME LEAVES THIS MACHINE INSIDE AN ARTIFACT.
#
# A third party found his own name in this repository hours after it went public, and told
# the owner. Nothing in the toolchain had looked for it: the secret scanner looks for
# CREDENTIALS, and a name is not a secret. The engine's write-time and command-time guards
# close that for anything authored or committed HERE — but they cannot see a file that
# arrived by cp, a generator's output, a title typed into github.com, or anything committed
# before those guards existed.
#
# So the tree is checked again at the one point where the cost stops being recoverable. A
# name in a commit can be scrubbed at HEAD; a name in a signed, notarized, downloaded binary
# is on a stranger's disk and stays there.
#
# It runs before ANY artifact is built, and it refuses on a MISSING list as loudly as on a
# hit. That asymmetry with the write-time guards is deliberate and it is the whole design:
# a stranger who clones this repository has no roster of the owner's clients and friends and
# must not be blocked by its absence, but a release happens on the owner's machine, where
# "there is no list" and "there are no names" are two entirely different facts.
names_gate() {
  local checker="$repo_root/engine/scripts/named-persons.sh"
  if [ ! -x "$checker" ]; then
    die "the named-person check is missing at $checker.
  It is the last thing standing between a private individual's name and a published
  binary, and a release that cannot run it is a release that does not know what it
  is shipping. Refusing." 2
  fi
  say "checking the tree for names on the deny-list..."
  bash "$checker" --tree --repo "$repo_root" || exit $?
  say ""
}

# ---------------------------------------------------------------------------------------
cmd_engine() {
  names_gate
  mkdir -p "$OUT" || die "cannot create $OUT"
  say "building the engine asset for $TAG, and proving it is reproducible..."
  say ""
  bash "$here/make-engine-asset.sh" --check --tag "$TAG" --out "$OUT" || exit 1

  [ -f "$OUT/$ENGINE_ASSET" ] || die "$OUT/$ENGINE_ASSET was not produced" 1
  [ -f "$PIN_FILE" ] || die "$PIN_FILE was not produced" 1

  # The pin the app will compile in, read back off the file rather than off the log.
  # shellcheck disable=SC1090
  . "$PIN_FILE"
  local local_digest; local_digest="$(sha256_of "$OUT/$ENGINE_ASSET")"
  [ "$RICHOS_ENGINE_SHA256" = "$local_digest" ] \
    || die "the pin says $RICHOS_ENGINE_SHA256 and the file on disk is $local_digest" 1
  [ "$RICHOS_ENGINE_URL" = "$ENGINE_URL" ] \
    || die "the pin's URL is
    $RICHOS_ENGINE_URL
  and this release publishes the asset to
    $ENGINE_URL" 1

  # Any receipt from an earlier run is stale by definition now.
  rm -f "$RECEIPT"

  rule
  say "NEXT, and nothing here did it:"
  say ""
  say "  gh release create $TAG --repo $REPO --title 'RichOS $VERSION' --notes '...'"
  say "  gh release upload $TAG '$OUT/$ENGINE_ASSET' --repo $REPO"
  say "  app/scripts/make-release.sh verify-engine --tag $TAG"
  say ""
  say "  The upload happens BEFORE the app is compiled. The digest above goes inside the"
  say "  executable, and a customer's first run checks it against whatever that URL returns."
  rule
}

# ---------------------------------------------------------------------------------------
cmd_verify_engine() {
  [ -f "$PIN_FILE" ] || die "no pin at $PIN_FILE — run \`make-release.sh engine --tag $TAG\` first"
  # shellcheck disable=SC1090
  . "$PIN_FILE"
  [ -n "${RICHOS_ENGINE_SHA256:-}" ] || die "$PIN_FILE has no RICHOS_ENGINE_SHA256"

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/richos-verify-engine.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  say "fetching the PUBLISHED asset — the bytes a customer's first run will get:"
  say "  $RICHOS_ENGINE_URL"
  local code
  code="$(curl -sS -L -o "$tmp/asset" -w '%{http_code}' --max-time 300 "$RICHOS_ENGINE_URL" 2>"$tmp/curl.err")"
  if [ "$code" != "200" ]; then
    warn ""
    warn "  HTTP $code. $(cat "$tmp/curl.err")"
    die "the engine asset is not published at that URL yet. Upload it before building the
  app that pins it — otherwise every customer's first run gets a 404 and a named
  DownloadFailed, and the failure ships inside a signed binary." 1
  fi

  local got; got="$(sha256_of "$tmp/asset")"
  local bytes; bytes="$(/usr/bin/stat -f %z "$tmp/asset")"
  say "  bytes    : $bytes"
  say "  sha256   : $got"
  say "  pinned   : $RICHOS_ENGINE_SHA256"
  if [ "$got" != "$RICHOS_ENGINE_SHA256" ]; then
    die "THE PUBLISHED BYTES ARE NOT THE PINNED BYTES. Whatever is at that URL is not what
  this build would trust, so every installation would refuse the engine with a
  DigestMismatch. Re-upload the asset this run produced, or rebuild the pin." 1
  fi

  # A local copy is not evidence about the wire, so the local file is compared too — a
  # mismatch here means the staging directory drifted from what was uploaded.
  if [ -f "$OUT/$ENGINE_ASSET" ]; then
    local local_digest; local_digest="$(sha256_of "$OUT/$ENGINE_ASSET")"
    [ "$local_digest" = "$got" ] \
      || die "the published asset matches the pin and the local staging copy does NOT
  ($local_digest). Something rebuilt the staging directory after the upload." 1
  fi

  mkdir -p "$OUT"
  {
    printf '# Written by make-release.sh verify-engine. `app` refuses to build without it.\n'
    printf '# It records that these exact bytes were READ BACK from the published URL.\n'
    printf 'tag=%s\n' "$TAG"
    printf 'url=%s\n' "$RICHOS_ENGINE_URL"
    printf 'sha256=%s\n' "$got"
    printf 'bytes=%s\n' "$bytes"
    printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RECEIPT"

  say ""
  say "VERIFIED: the published engine asset is the pinned engine asset."
  say "  receipt: $RECEIPT"
}

# ---------------------------------------------------------------------------------------
cmd_app() {
  # Run again, and not out of belt-and-braces: `engine` and `app` are separate invocations
  # with an upload and a network verification between them, and the tree can move in that
  # window. A gate that runs once, at the start of a chain that spans hours, is a gate that
  # attests to a tree nobody is still building.
  names_gate
  [ -f "$PIN_FILE" ] || die "no pin at $PIN_FILE — run \`make-release.sh engine --tag $TAG\` first"
  [ -f "$RECEIPT" ] || die "no receipt at $RECEIPT.
  The engine asset has not been read back from its published URL, so the digest about to
  be compiled into this build is a claim about a local file. Upload the asset, then run
    app/scripts/make-release.sh verify-engine --tag $TAG"

  # shellcheck disable=SC1090
  . "$PIN_FILE"
  local receipt_sha; receipt_sha="$(sed -n 's/^sha256=//p' "$RECEIPT")"
  [ "$receipt_sha" = "$RICHOS_ENGINE_SHA256" ] \
    || die "the receipt is for $receipt_sha and the pin is now $RICHOS_ENGINE_SHA256.
  The engine asset was rebuilt after it was verified. Re-upload and re-verify."

  [ -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}${TAURI_SIGNING_PRIVATE_KEY:-}" ] \
    || die "no updater signing key. Export TAURI_SIGNING_PRIVATE_KEY_PATH — app/RELEASING.md
  says which key ships and why. Without a signature there is no publishable release."

  # ---- THE SOURCE CORRESPONDING TO THE BINARY -----------------------------------------
  #
  # RichOS is AGPL-3.0-only and the release page is where a stranger goes looking for the
  # source that made the binary. GitHub attaches the tag's tree to every release as
  # `Source code (zip/tar.gz)` automatically, so the corresponding source is published for
  # free — and it is only CORRESPONDING if this build came from that exact tree.
  #
  # A dirty tree is therefore refused rather than warned about: an uncommitted line is a
  # difference between what was shipped and what was published, and nobody can see it later.
  local head_sha tag_sha dirty
  head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$head_sha" ]; then
    dirty="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
    [ -z "$dirty" ] || die "the working tree has uncommitted changes, so the binary would not
  correspond to the source published beside it. AGPL aside, nobody can reconstruct what
  shipped from a tree that was never committed.

$(printf '%s' "$dirty" | sed 's/^/    /')" 1
    tag_sha="$(git -C "$repo_root" rev-parse "$TAG^{commit}" 2>/dev/null || true)"
    if [ -n "$tag_sha" ] && [ "$tag_sha" != "$head_sha" ]; then
      die "HEAD is $head_sha and $TAG is $tag_sha. GitHub publishes the TAG's tree as the
  source beside this release, so it would not be the source this binary was built from." 1
    fi
    say ""
    if [ -n "$tag_sha" ]; then
      say "  source     : $head_sha, which is $TAG. The release page publishes this tree."
    else
      say "  source     : $head_sha. $TAG does not exist locally yet — create it on THIS"
      say "               commit, or the source published beside the release is a different tree."
    fi
  else
    say ""
    say "  source     : not a git checkout, so nothing here can say which tree this is."
  fi

  mkdir -p "$OUT"

  rule
  say "building RichOS $VERSION for $TAG"
  say "  engine pin : $RICHOS_ENGINE_VERSION  $RICHOS_ENGINE_SHA256"
  say "             : $RICHOS_ENGINE_URL  (verified published)"
  say "  signing    : $SIGN_MODE$( [ "$NOTARIZE" = 1 ] && printf ', notarized and stapled')"
  say "  manifest   : $UPDATE_URL"
  rule
  say ""

  local notarize_env=()
  [ "$NOTARIZE" = "1" ] && notarize_env+=(RICHOS_NOTARIZE=1)

  env "${notarize_env[@]+"${notarize_env[@]}"}" \
      RICHOS_ENGINE_VERSION="$RICHOS_ENGINE_VERSION" \
      RICHOS_ENGINE_URL="$RICHOS_ENGINE_URL" \
      RICHOS_ENGINE_SHA256="$RICHOS_ENGINE_SHA256" \
      RICHOS_UPDATE_BASE_URL="$DOWNLOAD_BASE" \
      RICHOS_UPDATE_NOTES="$NOTES" \
      bash "$here/package-app.sh" --sign "$SIGN_MODE" --updater || exit 1

  local bundle="$src_tauri/target/release/bundle/macos/RichOS.app"
  local tarball="$bundle.tar.gz"
  local sig="$tarball.sig"
  local manifest; manifest="$(dirname "$tarball")/latest.json"
  local f
  for f in "$bundle" "$tarball" "$sig" "$manifest"; do
    [ -e "$f" ] || die "the build did not produce $f" 1
  done

  # ---- the pin is INSIDE the executable, read off the executable -----------------------
  #
  # `engine_pin()` reads three `option_env!` values, so they are compiled in and covered by
  # the code signature. That is the whole reason for a compile-time pin rather than a
  # runtime variable — and it is worth nothing if the environment did not actually reach
  # the compiler. An `option_env!` string survives an optimized build as plain bytes
  # (checked with rustc -O on 2026-09-04), so the executable is the place to ask.
  local exe="$bundle/Contents/MacOS/richos-tauri"
  [ -f "$exe" ] || die "no executable at $exe" 1
  if grep -a -q "$RICHOS_ENGINE_SHA256" "$exe"; then
    say ""
    say "  the engine digest IS inside the executable, so the signature covers it."
  else
    die "the engine digest is NOT in $exe. The pin did not reach the compiler, so this
  build would install whatever the URL returns without checking it. Nothing publishable
  was produced." 1
  fi

  # ---- the bundle version is the version this release claims --------------------------
  local plist_version
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist" 2>/dev/null)"
  [ "$plist_version" = "$VERSION" ] \
    || die "the built bundle says it is $plist_version and this release is $VERSION.
  The tag, the manifest and the binary would disagree." 1

  # ---- the first-install artifact -----------------------------------------------------
  #
  # NOT THE DMG. `cargo tauri build --bundles app,dmg` makes the disk image DURING the
  # build, which is BEFORE package-app.sh signs, notarizes and staples the .app — so the
  # image would carry a bundle from before all three, and the image itself would be
  # neither signed nor notarized. A ditto archive made HERE carries the stapled bundle,
  # and the ticket rides inside it, so a first launch works with no network.
  say ""
  say "making the first-install archive from the finished bundle..."
  rm -f "$OUT/$INSTALL_ASSET"
  /usr/bin/ditto -c -k --keepParent "$bundle" "$OUT/$INSTALL_ASSET" \
    || die "ditto could not archive the bundle" 1

  # Read back out of the archive, because the archive is the artifact and `ditto` exiting 0
  # is a claim about a command. Gatekeeper's verdict on the EXTRACTED copy is the verdict a
  # person who downloads it gets.
  local unz; unz="$(mktemp -d "${TMPDIR:-/tmp}/richos-install-check.XXXXXX")"
  /usr/bin/ditto -x -k "$OUT/$INSTALL_ASSET" "$unz" || die "the first-install archive does not open" 1
  local extracted="$unz/RichOS.app"
  [ -d "$extracted" ] || die "the first-install archive does not contain RichOS.app" 1
  if ! codesign --verify --deep --strict "$extracted" 2>/dev/null; then
    rm -rf "$unz"; die "the extracted bundle fails codesign --verify" 1
  fi
  local spctl_verdict; spctl_verdict="$(spctl -a -vv "$extracted" 2>&1 | tr '\n' ' ')"
  local staple_verdict="not requested"
  if [ "$NOTARIZE" = "1" ]; then
    if xcrun stapler validate "$extracted" >/dev/null 2>&1; then
      staple_verdict="valid — the ticket survived the archive"
    else
      rm -rf "$unz"
      die "the extracted bundle has NO valid stapled ticket. A machine that is offline or
  behind a captive portal treats it as un-notarized, which is the same as not being
  notarized at all for the person it matters to." 1
    fi
  fi
  rm -rf "$unz"
  say "  extracted and checked: codesign OK; stapled ticket: $staple_verdict"
  say "  Gatekeeper on the extracted copy: $spctl_verdict"

  # ---- stage everything that will be published ----------------------------------------
  cp "$tarball"  "$OUT/$UPDATE_ASSET"
  cp "$sig"      "$OUT/$UPDATE_ASSET.sig"
  cp "$manifest" "$OUT/$MANIFEST_ASSET"
  [ -f "$OUT/$ENGINE_ASSET" ] || die "the engine asset is missing from $OUT" 1

  # ---- the manifest, judged by the type that judges it on a customer's Mac -------------
  say ""
  say "checking the manifest with the updater's own RemoteRelease type..."
  (cd "$src_tauri" && cargo run -q --example verify_update_manifest -- \
      "$OUT/$MANIFEST_ASSET" "$OUT/$UPDATE_ASSET" "$OUT/$UPDATE_ASSET.sig" "$UPDATE_URL") \
    || die "the manifest is not publishable — the reasons are above." 1

  # The stable-name copy is made from the archive that just PASSED the checks above, never
  # from the bundle again -- two archives of one bundle are not guaranteed byte-identical, and
  # a second archive would be one nothing verified.
  rm -f "$OUT/$STABLE_ASSET"
  cp "$OUT/$INSTALL_ASSET" "$OUT/$STABLE_ASSET" || die "could not write the stable-name copy" 1
  [ "$(sha256_of "$OUT/$INSTALL_ASSET")" = "$(sha256_of "$OUT/$STABLE_ASSET")" ] \
    || die "the stable-name copy does not match the archive it was copied from" 1
  say "stable-name copy: $STABLE_ASSET (byte-identical to $INSTALL_ASSET)"

  write_sums
  say ""
  rule
  say "STAGED: $OUT"
  ls -l "$OUT" | sed 's/^/  /'
  rule
  say "NEXT, and nothing here did it. latest.json goes LAST:"
  say ""
  say "  gh release upload $TAG --repo $REPO \\"
  say "      '$OUT/$UPDATE_ASSET' '$OUT/$UPDATE_ASSET.sig' \\"
  say "      '$OUT/$INSTALL_ASSET' '$OUT/$STABLE_ASSET' '$OUT/$SUMS_ASSET'"
  say "  gh release upload $TAG --repo $REPO '$OUT/$MANIFEST_ASSET'"
  say "  app/scripts/make-release.sh verify-release --tag $TAG"
  rule
}

# ---------------------------------------------------------------------------------------
# THE CHECKSUMS. One file, in the format `shasum -c` reads, so a person who downloads the
# release can check it with a command that already ships on their Mac.
write_sums() {
  say ""
  say "writing $SUMS_ASSET over everything that will be published..."
  ( cd "$OUT" && rm -f "$SUMS_ASSET" \
      && find . -maxdepth 1 -type f ! -name "$SUMS_ASSET" ! -name 'engine-pin.env' \
                ! -name 'engine-published.ok' -print \
      | sed 's|^\./||' | LC_ALL=C sort \
      | tr '\n' '\0' | xargs -0 /usr/bin/shasum -a 256 > "$SUMS_ASSET" ) \
      || die "could not write $SUMS_ASSET" 1

  # VERIFIED BY READING IT BACK. `shasum -a 256 > file` exiting 0 says a file was written.
  ( cd "$OUT" && /usr/bin/shasum -a 256 -c "$SUMS_ASSET" ) \
    || die "$SUMS_ASSET does not verify against the files it names" 1
  say ""
  sed 's/^/  /' "$OUT/$SUMS_ASSET"
}

# ---------------------------------------------------------------------------------------
cmd_verify_release() {
  [ -f "$OUT/$SUMS_ASSET" ] || die "no $SUMS_ASSET in $OUT — run \`make-release.sh app\` first"

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/richos-verify-release.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local fail=0
  rule
  say "downloading every published asset and comparing it with $SUMS_ASSET"
  rule
  local want name url code got
  while read -r want name; do
    [ -n "$name" ] || continue
    url="$DOWNLOAD_BASE/$name"
    code="$(curl -sS -L -o "$tmp/$name" -w '%{http_code}' --max-time 600 "$url" 2>/dev/null)"
    if [ "$code" != "200" ]; then
      warn "  MISSING  $name — HTTP $code at $url"
      fail=1
      continue
    fi
    got="$(sha256_of "$tmp/$name")"
    if [ "$got" = "$want" ]; then
      say "  OK       $name"
    else
      warn "  DIFFERS  $name"
      warn "           published $got"
      warn "           staged    $want"
      fail=1
    fi
  done < <(sed 's/^\([0-9a-f]*\)  */\1 /' "$OUT/$SUMS_ASSET")

  # ---- and the endpoint an installed copy actually fetches ----------------------------
  say ""
  say "fetching the updater endpoint itself:"
  say "  $ENDPOINT"
  code="$(curl -sS -L -o "$tmp/endpoint.json" -w '%{http_code}' \
          -H 'Accept: application/json' --max-time 120 "$ENDPOINT" 2>/dev/null)"
  if [ "$code" != "200" ]; then
    warn "  HTTP $code — every installed copy would report a manifest failure."
    warn "  If this release is not the newest one GitHub knows about, \`latest\` points"
    warn "  elsewhere. An engine-only or draft release ahead of this one does exactly that."
    fail=1
  else
    say "  HTTP 200, $(/usr/bin/stat -f %z "$tmp/endpoint.json") bytes"
    if [ -f "$tmp/$UPDATE_ASSET" ] && [ -f "$tmp/$UPDATE_ASSET.sig" ]; then
      (cd "$src_tauri" && cargo run -q --example verify_update_manifest -- \
          "$tmp/endpoint.json" "$tmp/$UPDATE_ASSET" "$tmp/$UPDATE_ASSET.sig" "$UPDATE_URL") \
        || fail=1
    fi
  fi

  rule
  if [ "$fail" != "0" ]; then
    warn "verify-release: the published release does NOT match what was staged."
    exit 1
  fi
  say "verify-release: every published byte matches, and the endpoint serves the manifest"
  say "that names them. This release is what it says it is."
  rule
}

case "$cmd" in
  plan)           plan ;;
  engine)         plan; say ""; cmd_engine ;;
  verify-engine)  cmd_verify_engine ;;
  app)            cmd_app ;;
  verify-release) cmd_verify_release ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
