#!/usr/bin/env bash
# THE ENGINE, AS A RELEASE ASSET — deterministic, digested, and pinned into the build.
#
#   app/scripts/make-engine-asset.sh [--out <dir>] [--tag <release-tag>]
#
# WHY THIS EXISTS
#
# `ceo-decisions.md` §19 rules the payload at four files and 8,754,980 B and lists the engine
# directory under "What is NOT bundled". The same day: "Where the download lives: THE PUBLIC
# GITHUB REPO'S RELEASES." The engine is already IN that repository, so it reaches a customer
# as a release asset. This script is the thing that makes that asset, and the digest that makes
# it verifiable.
#
# DETERMINISTIC, AND THAT IS THE WHOLE POINT
#
# The digest is compiled into the app (`RICHOS_ENGINE_SHA256`) and covered by the app's own
# Developer ID signature. That only means anything if building the tarball twice from the same
# tree produces the same bytes. Four things are normalized, each of which otherwise moves:
#
#   * ORDER    — `find | LC_ALL=C sort`, not the filesystem's directory order.
#   * TIME     — every mtime pinned to the engine's own commit time (or 0 outside a checkout).
#   * OWNER    — uid/gid 0, name `root`, via bsdtar's `--uid/--gid/--uname/--gname`.
#   * GZIP     — `gzip -n`, because gzip writes the source filename and an mtime into its own
#                header by default, which makes two identical tarballs differ.
#
# `--check` runs the whole thing twice into scratch directories and requires the two digests to
# match. A non-deterministic build would otherwise be discovered as a DigestMismatch on a
# customer's Mac, which is the one place it must never be discovered.
#
# WHAT IT DOES NOT DO
#
# It does not publish, tag, or upload. `gh release upload` is a human's decision and this
# script's output tells them exactly what to run. Nothing here touches the network.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
ENGINE_DIR="$REPO_ROOT/engine"

OUT_DIR="$REPO_ROOT/app/target/engine-asset"
TAG=""
CHECK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT_DIR="$2"; shift 2 ;;
        --tag)   TAG="$2"; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "REFUSING — $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# The engine, and its version
# ---------------------------------------------------------------------------------------
[ -d "$ENGINE_DIR" ] || die "no engine directory at $ENGINE_DIR"
[ -d "$ENGINE_DIR/scripts/hooks" ] || die "$ENGINE_DIR has no scripts/hooks — it is not an engine"
[ -f "$ENGINE_DIR/VERSION" ] || die "$ENGINE_DIR has no VERSION — it is not an engine"

VERSION="$(tr -d '[:space:]' < "$ENGINE_DIR/VERSION")"
[ -n "$VERSION" ] || die "$ENGINE_DIR/VERSION is empty"

# The engine's own commit time, so the archive's mtimes are a property of the CONTENT and not
# of when somebody happened to run this. Outside a checkout, 0.
SOURCE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct -- engine 2>/dev/null || true)"
[ -n "$SOURCE_EPOCH" ] || SOURCE_EPOCH=0
SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo "not-a-checkout")"

[ -n "$TAG" ] || TAG="engine-v$VERSION"
ASSET="richos-engine-$VERSION.tar.gz"
URL="https://github.com/WebDevBooster/richos/releases/download/$TAG/$ASSET"

# ---------------------------------------------------------------------------------------
# Build one archive, deterministically, into $1
# ---------------------------------------------------------------------------------------
build_into() {
    local out="$1"
    local staging
    staging="$(mktemp -d "${TMPDIR:-/tmp}/richos-engine-asset.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    # A COPY, so nothing here can touch the engine in the checkout. `-R` preserves symlinks
    # rather than following them into a loop.
    mkdir -p "$staging/engine"
    ( cd "$ENGINE_DIR" && /usr/bin/tar -cf - . ) | ( cd "$staging/engine" && /usr/bin/tar -xf - ) || return 1

    # ORDER, fixed. `-print` then sort, rather than trusting readdir.
    local manifest="$staging/manifest"
    ( cd "$staging" && find engine -print ) | LC_ALL=C sort > "$manifest" || return 1

    # TIME, fixed. `touch -h` so a symlink's own timestamp is set rather than its target's.
    local stamp
    stamp="$(date -u -r "$SOURCE_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || echo 197001010000.00)"
    ( cd "$staging" && LC_ALL=C xargs -0 -n 200 touch -h -t "$stamp" < <(tr '\n' '\0' < "$manifest") ) || return 1

    # OWNER + GZIP, fixed. bsdtar writes the members in the order given on stdin.
    ( cd "$staging" \
        && /usr/bin/tar --uid 0 --gid 0 --uname root --gname root \
                        -c -f - -T "$manifest" -n \
        | gzip -n -9 > "$out" ) || return 1

    [ -s "$out" ] || return 1
}

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
TARBALL="$OUT_DIR/$ASSET"

echo "=== the engine ==="
echo "  source   : $ENGINE_DIR"
echo "  version  : $VERSION"
echo "  repo HEAD: $SOURCE_SHA"
echo "  mtimes   : $SOURCE_EPOCH (the engine's own last commit time)"
echo

build_into "$TARBALL" || die "the archive could not be built"
DIGEST="$(sha256_of "$TARBALL")"
BYTES="$(/usr/bin/stat -f %z "$TARBALL")"

echo "=== the asset ==="
echo "  file  : $TARBALL"
echo "  bytes : $BYTES"
echo "  sha256: $DIGEST"
echo

# ---------------------------------------------------------------------------------------
# DETERMINISM, PROVED RATHER THAN CLAIMED
# ---------------------------------------------------------------------------------------
if [ "$CHECK" = "1" ]; then
    echo "=== --check: building a second time and comparing ==="
    SECOND="$(mktemp -d "${TMPDIR:-/tmp}/richos-engine-check.XXXXXX")/second.tar.gz"
    mkdir -p "$(dirname "$SECOND")"
    build_into "$SECOND" || die "the second build failed"
    SECOND_DIGEST="$(sha256_of "$SECOND")"
    echo "  first : $DIGEST"
    echo "  second: $SECOND_DIGEST"
    if [ "$DIGEST" != "$SECOND_DIGEST" ]; then
        rm -rf "$(dirname "$SECOND")"
        die "THE ARCHIVE IS NOT DETERMINISTIC. A pin over these bytes would fail on a customer's Mac."
    fi
    echo "  IDENTICAL."
    rm -rf "$(dirname "$SECOND")"
    echo
fi

# The archive is what the app will check, so check it here too — the same shape check
# `install_engine` performs, run before anybody uploads anything.
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/richos-engine-verify.XXXXXX")"
/usr/bin/tar -x -z --no-same-owner -f "$TARBALL" -C "$VERIFY" || die "the archive does not open"
[ -d "$VERIFY/engine/scripts/hooks" ] || die "the archive has no engine/scripts/hooks"
[ -f "$VERIFY/engine/VERSION" ] || die "the archive has no engine/VERSION"
[ "$(tr -d '[:space:]' < "$VERIFY/engine/VERSION")" = "$VERSION" ] || die "the archive's VERSION is not $VERSION"
FILES="$(find "$VERIFY/engine" -type f | wc -l | tr -d ' ')"
rm -rf "$VERIFY"
echo "=== it opens, and it is an engine ==="
echo "  engine/scripts/hooks  present"
echo "  engine/VERSION        $VERSION"
echo "  files                 $FILES"
echo

# ---------------------------------------------------------------------------------------
# The pin, ready to paste
# ---------------------------------------------------------------------------------------
PIN_FILE="$OUT_DIR/engine-pin.env"
cat > "$PIN_FILE" <<PINEOF
# THE ENGINE PIN — read at COMPILE time by richos-core (\`setup.rs::engine_pin\`), so the digest
# ends up inside the executable that the app's Developer ID signature covers. A runtime
# variable would be a value an attacker on the machine could set, which is the opposite of a
# pin. An unset or malformed pin makes the build refuse to install an engine rather than
# trusting whatever the URL returns.
#
# Built from engine $VERSION at repo $SOURCE_SHA.
export RICHOS_ENGINE_VERSION=$VERSION
export RICHOS_ENGINE_URL=$URL
export RICHOS_ENGINE_SHA256=$DIGEST
PINEOF

echo "=== the pin ==="
cat "$PIN_FILE"
echo
echo "=== what a human does next, and nothing here did it ==="
echo "  gh release create $TAG --repo WebDevBooster/richos --title 'RichOS engine $VERSION' --notes '...'"
echo "  gh release upload $TAG '$TARBALL' --repo WebDevBooster/richos"
echo "  source '$PIN_FILE' && app/scripts/package-app.sh"
echo
echo "  The upload has to happen BEFORE a build carrying this pin ships, or every customer's"
echo "  first run gets a 404 and a named DownloadFailed. The pin is not a promise; it is a"
echo "  claim about bytes that must already be there."
