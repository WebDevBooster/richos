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
#   * MODE     — 755 for directories, 755 for anything the source marks user-executable, 644
#                for everything else. See below; this one was found by running the script,
#                not by reading it.
#   * GZIP     — `gzip -n`, because gzip writes the source filename and an mtime into its own
#                header by default, which makes two identical tarballs differ.
#
# MODE, AND WHY IT IS NOT PARANOIA. Measured 2026-09-04, same tree, same machine, same second:
#
#     umask 022  ->  2,021,839 B  sha256 cbee8763588469de4f01f04a8f3aeaec1dc7bb1225327119c51dbdd7ebd7afb2
#     umask 077  ->  2,021,655 B  sha256 fdae7195cf0083426ead2749fb4e3f87678e29c45cf5ac77d7cce3088e073e33
#
# All 531 members differed, and they differed ONLY in mode — 0755 became 0700, 0644 became
# 0600 — because macOS's bsdtar applies the caller's umask when it extracts as a non-root
# user, so the staging copy inherited the umask of whoever happened to run this. The digest
# that gets compiled into the app and checked on a customer's Mac was a function of an
# operator's shell setting. Normalizing here makes the archive a function of CONTENT plus the
# one permission bit git actually tracks, which is the only determinism boundary that can
# hold across two machines.
#
# `--check` runs the whole thing twice and requires the two digests to match — and the second
# run is deliberately made in a DIFFERENT ENVIRONMENT (another umask, another TMPDIR, the C
# locale, UTC), because a second build under identical conditions cannot fail for any reason
# the first one would not have failed for. That is exactly how the umask defect above survived
# a green `--check`. A non-deterministic build would otherwise be discovered as a
# DigestMismatch on a customer's Mac, which is the one place it must never be discovered.
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

# ---------------------------------------------------------------------------------------
# THE LICENSE, WHICH LIVES OUTSIDE THE DIRECTORY BEING PACKAGED
# ---------------------------------------------------------------------------------------
#
# The canonical AGPL text is at the REPOSITORY root, and this script archives `engine/`.
# So until 2026-09-04 the standalone engine tarball shipped with no license text at all:
# an AGPL work distributed without its terms, to a customer who has no repository to look
# in. The fix is a copy made HERE, at packaging time, rather than a second copy committed
# inside engine/ - because a committed duplicate of a license text is a file that can drift
# from the canonical one with nothing to catch it. This copy cannot drift; it is made from
# the canonical file every time and read back out of the finished archive below.
LICENSE_SRC="$REPO_ROOT/LICENSE"
NOTICES_SRC="$REPO_ROOT/docs/legal/THIRD-PARTY-NOTICES.md"
[ -f "$LICENSE_SRC" ] || die "no LICENSE at $LICENSE_SRC - refusing to build an unlicensed asset"
[ -f "$NOTICES_SRC" ] || die "no third-party notices at $NOTICES_SRC - refusing to build an asset that cannot name what it bundles"

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

    # THE TERMS, COPIED IN. Before the manifest is built, so these files are ordered,
    # timestamped and owned exactly like every other member and the archive stays
    # reproducible. `cp` without `-p`: the mtime is pinned below for all members alike.
    cp "$LICENSE_SRC" "$staging/engine/LICENSE" || return 1
    cp "$NOTICES_SRC" "$staging/engine/THIRD-PARTY-NOTICES.md" || return 1

    # MODE, fixed. Read the executable bit off the COPY (which preserves the source's u+x
    # under any sane umask) and then flatten everything to two permissions. `-perm -u+x` is
    # the discriminant rather than any group/other bit precisely because those are the bits
    # a umask moves; u+x is also the only permission git records.
    find "$staging/engine" -type d -exec chmod 755 {} + || return 1
    find "$staging/engine" -type f -perm -u+x -exec chmod 755 {} + || return 1
    find "$staging/engine" -type f ! -perm -u+x -exec chmod 644 {} + || return 1

    # ORDER, fixed. `-print` then sort, rather than trusting readdir.
    local manifest="$staging/manifest"
    ( cd "$staging" && find engine -print ) | LC_ALL=C sort > "$manifest" || return 1

    # TIME, fixed. `touch -h` so a symlink's own timestamp is set rather than its target's.
    #
    # TZ IS ON BOTH HALVES AND THAT IS THE WHOLE POINT. `date -u` prints the stamp in UTC,
    # but `touch -t` READS ITS ARGUMENT IN THE LOCAL ZONE — so on a Mac set to anything but
    # UTC the two disagreed by the offset and the archive's mtimes, and therefore its digest,
    # were a function of the operator's timezone. Measured 2026-09-04, same tree, same
    # machine, one variable:
    #
    #     TZ unset (Europe/Berlin)  ->  sha256 cbee8763588469de4f01f04a8f3aeaec1dc7bb12...
    #     TZ=UTC                    ->  sha256 bdb82559bce916dc8945142a1f85d02a2d831609...
    #
    # Pinning both ends to UTC makes the mtime a property of the engine's commit and of
    # nothing else.
    local stamp
    stamp="$(TZ=UTC date -u -r "$SOURCE_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || echo 197001010000.00)"
    ( cd "$staging" && LC_ALL=C TZ=UTC xargs -0 -n 200 touch -h -t "$stamp" < <(tr '\n' '\0' < "$manifest") ) || return 1

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
    echo "=== --check: building a second time, in a DIFFERENT environment, and comparing ==="
    CHECK_TMP="$(mktemp -d /tmp/richos-engine-check.XXXXXX)"
    SECOND="$CHECK_TMP/second.tar.gz"
    echo "  second build runs under: umask 077, TMPDIR=$CHECK_TMP, LC_ALL=C, TZ=UTC"
    ( umask 077; TMPDIR="$CHECK_TMP" LC_ALL=C TZ=UTC build_into "$SECOND" ) || die "the second build failed"
    SECOND_DIGEST="$(sha256_of "$SECOND")"
    echo "  first : $DIGEST"
    echo "  second: $SECOND_DIGEST"
    if [ "$DIGEST" != "$SECOND_DIGEST" ]; then
        rm -rf "$CHECK_TMP"
        die "THE ARCHIVE IS NOT DETERMINISTIC. A pin over these bytes would fail on a customer's Mac."
    fi
    echo "  IDENTICAL, across two environments."
    rm -rf "$CHECK_TMP"
    echo
fi

# The archive is what the app will check, so check it here too — the same shape check
# `install_engine` performs, run before anybody uploads anything.
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/richos-engine-verify.XXXXXX")"
/usr/bin/tar -x -z --no-same-owner -f "$TARBALL" -C "$VERIFY" || die "the archive does not open"
[ -d "$VERIFY/engine/scripts/hooks" ] || die "the archive has no engine/scripts/hooks"
[ -f "$VERIFY/engine/VERSION" ] || die "the archive has no engine/VERSION"
[ "$(tr -d '[:space:]' < "$VERIFY/engine/VERSION")" = "$VERSION" ] || die "the archive's VERSION is not $VERSION"

# THE LICENSE CHECK IS READ OUT OF THE ARCHIVE, not off the staging directory. `cp` having
# exited 0 is a claim about a command; the bytes inside the tarball are the artifact, and
# the artifact is the only thing a customer ever sees.
[ -f "$VERIFY/engine/LICENSE" ] || die "the archive has no engine/LICENSE - it would ship an AGPL work with no terms"
[ -f "$VERIFY/engine/THIRD-PARTY-NOTICES.md" ] || die "the archive has no engine/THIRD-PARTY-NOTICES.md"
LICENSE_CANON="$(sha256_of "$LICENSE_SRC")"
LICENSE_SHIPPED="$(sha256_of "$VERIFY/engine/LICENSE")"
[ "$LICENSE_CANON" = "$LICENSE_SHIPPED" ] \
    || die "the archive's LICENSE is NOT the canonical text ($LICENSE_SHIPPED vs $LICENSE_CANON)"

# EVERY BUNDLED THIRD-PARTY DIRECTORY KEEPS ITS OWN TERMS, and neither half of that rule
# is a typed list. A hand-written inventory of directories to check is the defect this
# repository has already paid for five times, so both halves are derived from disk:
#
#   (a) NOTHING IS LOST IN PACKAGING. Every license file present under the source engine/
#       must be present at the same relative path inside the archive. This is the check
#       that actually catches a packaging change, and it covers all seven bundled items
#       without naming one of them.
#   (b) NOTHING ARRIVES WITHOUT ITS TERMS. A skill whose own frontmatter declares a
#       `license:` must have a license file beside it. This is the check that catches a
#       NEW vendored skill added with a claim and no text - the exact defect the
#       2026-09-04 audit found in three directories at once.
license_files_under() {
    ( cd "$1" && find . -type f \( -name 'LICENSE' -o -name 'LICENSE.txt' -o -name 'LICENSE.md' \) \
        ! -path './LICENSE' | LC_ALL=C sort )
}

MISSING_TERMS=""
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$VERIFY/engine/$rel" ] || MISSING_TERMS="$MISSING_TERMS engine/${rel#./}"
done <<EOF
$(license_files_under "$ENGINE_DIR")
EOF
[ -z "$MISSING_TERMS" ] \
    || die "packaging DROPPED bundled license file(s) that exist in the source engine:$MISSING_TERMS"

CLAIMED_NO_TEXT=""
while IFS= read -r sk; do
    [ -n "$sk" ] || continue
    d="$(dirname "$sk")"
    sed -n '1,25p' "$sk" | grep -qi '^license:' || continue
    if [ ! -f "$d/LICENSE" ] && [ ! -f "$d/LICENSE.txt" ] && [ ! -f "$d/LICENSE.md" ]; then
        CLAIMED_NO_TEXT="$CLAIMED_NO_TEXT ${d#"$VERIFY"/}"
    fi
done <<EOF
$(find "$VERIFY/engine/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | LC_ALL=C sort)
EOF
[ -z "$CLAIMED_NO_TEXT" ] \
    || die "skill(s) in the archive declare a license with no license file beside it:$CLAIMED_NO_TEXT"

TP_COUNT="$(license_files_under "$VERIFY/engine" | wc -l | tr -d ' ')"
FILES="$(find "$VERIFY/engine" -type f | wc -l | tr -d ' ')"
rm -rf "$VERIFY"
echo "=== it opens, and it is an engine ==="
echo "  engine/scripts/hooks  present"
echo "  engine/VERSION        $VERSION"
echo "  engine/LICENSE        canonical ($LICENSE_CANON)"
echo "  third-party notices   present, $TP_COUNT bundled license file(s) intact"
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
