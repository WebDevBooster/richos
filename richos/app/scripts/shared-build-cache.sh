#!/usr/bin/env bash
#
# shared-build-cache.sh — ONE cargo build cache for every checkout of this repository.
#
# =========================================================================================
# THE PROBLEM, MEASURED
# =========================================================================================
#
# This Mac runs many checkouts of this repository at once: the main checkout, one worktree
# per engineer, and `~/.richos-nightly/source` for the release build. Cargo puts its output
# in `target/` beside the workspace, so each one of those compiles the SAME dependency graph
# from scratch the first time anybody runs a test in it. Measured on 2026-09-20, in a fresh
# worktree, machine load ~17:
#
#     cargo test -q -p richos-core   cold worktree, own target/     77s
#     cargo test -q -p richos-core   same worktree, warm            31s
#
# — so 46 of those 77 seconds were recompiling dependency crates that were already compiled,
# byte for byte, three directories away. The Tauri shell is the expensive half and is not in
# that number: its cache is 13 GB, and a worktree that builds it pays minutes, not seconds.
#
# The same reasoning as `scripts/lib/worktree-resource.sh`, pointed the other way. That file
# derives a PRIVATE name per worktree for everything two checkouts would collide over. This
# one is its complement: what must NOT differ between checkouts is shared, once, here.
# ADOPTED AS-IS in shape from T3 Code (MIT, `pingdotgg/t3code` @ `d6f29130`), which shares
# one build cache across its linked worktrees by construction.
#
# =========================================================================================
# WHY A SYMLINK, AND NOT `.cargo/config.toml`, AND NOT AN ENVIRONMENT VARIABLE
# =========================================================================================
#
# All three were considered. The two that lose, lose on facts rather than taste:
#
#  * A CHECKED-IN `.cargo/config.toml` REACHES THE NIGHTLY RELEASE BUILD. `~/.richos-nightly/
#    source` is a git WORKTREE of this repository (`scripts/nightly-local.py`, `checkout()`),
#    so tracked content appears there. `nightly-local.py` deliberately pops CARGO_TARGET_DIR
#    out of the build environment so a developer's exported variable can never redirect a
#    release build — and it cannot pop a committed config file. A tracked config would hand
#    the release build a developer cache, silently, which is the exact thing that code exists
#    to prevent. It also cannot name a shared path: cargo does no environment expansion in
#    config files, and the checkouts sit at different depths (`~/ab/richos`,
#    `~/ab/richos-wt/<name>`, `~/.richos-nightly/source`), so no single relative
#    `build.target-dir` resolves to one directory from all of them.
#
#  * AN ENVIRONMENT VARIABLE CANNOT BE SET BY THE SPAWNER. `scripts/spawn.sh` assembles an
#    Agent payload and exits; nothing it exports survives into the shell an agent later runs
#    its own commands in. Verified from inside an agent on 2026-09-20: CARGO_TARGET_DIR,
#    RICHOS_PLAYWRIGHT and NODE_PATH were all unset. A variable also has to be re-set by
#    every human who opens a terminal, which is the definition of a thing that will be
#    forgotten.
#
#  * THE SYMLINK IS ALREADY THIS REPOSITORY'S ANSWER. `app/.gitignore` has carried
#    `src-tauri/target` in both its directory form and its bare symlink form since
#    2026-09-17, when that cache was relocated to the external volume. A symlink is
#    gitignored, so it never reaches the nightly worktree; and every consumer that computes
#    the path itself — `package-app.sh` (`${CARGO_TARGET_DIR:-$src_tauri/target}`),
#    `voice-component.test.sh`, `native-responsiveness.test.py` — follows it without being
#    changed or even knowing.
#
# CARGO'S OWN LOCK MAKES CONCURRENT BUILDS SAFE. Two checkouts building at once take turns on
# the shared directory ("Blocking waiting for file lock on build directory") and both finish
# green; they do not corrupt each other. Dependency crates are keyed by package id and
# features, not by source path, so they are shared; the workspace's own crates carry the
# manifest path in their fingerprint, so each checkout keeps its own and they never clobber.
#
# =========================================================================================
# THE THINGS THIS REFUSES TO DO
# =========================================================================================
#
#  * It will not touch `~/.richos-nightly/source`. A release build shares nothing.
#  * It will not create a directory under an UNMOUNTED volume. `mkdir -p /Volumes/E1TB/...`
#    on a Mac with that drive unplugged succeeds — on the boot disk — and then the real
#    volume shadows it at the next plug-in. That is a silent 13 GB written to the wrong disk
#    and a cache that empties itself, so an absent volume is a refusal, never a fallback
#    into the same path.
#  * It will not replace a real directory that has anything in it. Say `--adopt` to move an
#    existing cache into the shared location, and only when the shared one is not there yet.
#
# USAGE
#   shared-build-cache.sh [<checkout>]           link this checkout to the shared cache
#   shared-build-cache.sh --check [<checkout>]   report, change nothing; exit 1 if not linked
#   shared-build-cache.sh --adopt [<checkout>]   as above, but move an existing target/ in
#
#   $RICHOS_BUILD_CACHE overrides where the shared cache lives. An explicit path always
#   wins: a human who names a directory has a reason and this file is not it.
#
# EXIT  0 linked (or already linked) / 1 --check found it not linked / 2 refused

set -uo pipefail

MODE=link
CHECKOUT=""
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --adopt) MODE=adopt ;;
        -h|--help) sed -n '/^# USAGE/,/^# EXIT/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "shared-build-cache.sh: unknown option $arg" >&2; exit 2 ;;
        *) CHECKOUT="$arg" ;;
    esac
done

_refuse() { echo "shared-build-cache.sh: $1" >&2; exit 2; }

# --- which checkout ---------------------------------------------------------------------
if [ -z "$CHECKOUT" ]; then
    CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
fi
[ -d "$CHECKOUT" ] || _refuse "no such checkout: $CHECKOUT"
CHECKOUT="$(cd "$CHECKOUT" && pwd -P)"
[ -d "$CHECKOUT/richos/app" ] || _refuse "$CHECKOUT does not look like a RichOS checkout (no richos/app)"

# The release build shares nothing. Resolved through pwd -P on both sides so a symlinked
# home directory cannot sneak past a string comparison.
NIGHTLY="$HOME/.richos-nightly/source"
if [ -d "$NIGHTLY" ] && [ "$(cd "$NIGHTLY" && pwd -P)" = "$CHECKOUT" ]; then
    _refuse "$CHECKOUT is the nightly release worktree — it builds everything itself, on purpose (scripts/nightly-local.py strips CARGO_TARGET_DIR for the same reason)"
fi

# --- where the shared cache lives ---------------------------------------------------------
# Order: an explicit override, then the external volume this machine already uses for the
# Tauri cache, then a directory under $HOME. Never a silent fallback INTO an absent volume's
# path — see the refusals above.
mounted() {  # mounted <path> — is <path> a mount point right now?
    /sbin/mount | grep -q " on $1 ("
}

if [ -n "${RICHOS_BUILD_CACHE:-}" ]; then
    CACHE_ROOT="$RICHOS_BUILD_CACHE"
    case "$CACHE_ROOT" in
        /Volumes/*)
            VOL="/Volumes/$(printf '%s' "${CACHE_ROOT#/Volumes/}" | cut -d/ -f1)"
            mounted "$VOL" || _refuse "RICHOS_BUILD_CACHE is on $VOL, which is not mounted. Plug it in, or point RICHOS_BUILD_CACHE somewhere else — this will not create that path on the boot disk."
            ;;
    esac
elif mounted /Volumes/E1TB; then
    CACHE_ROOT=/Volumes/E1TB/caches/cargo-target
else
    CACHE_ROOT="$HOME/.cache/richos/cargo-target"
    echo "shared-build-cache.sh: /Volumes/E1TB is not mounted; using $CACHE_ROOT" >&2
fi

# --- the map ------------------------------------------------------------------------------
# One line per cargo workspace in this repository: <path under the checkout> <cache name>.
#
# `richos-app` is the Tauri shell's cache and keeps that name because it already holds 13 GB
# under it from the 2026-09-17 relocation; renaming it would throw that away to make a name
# tidier. The app workspace (richos-core, richos-voice) is the one this file adds.
LINKS="
richos/app/target                richos-app-workspace
richos/app/src-tauri/target      richos-app
"

# --- act ------------------------------------------------------------------------------------
RC=0
while read -r REL NAME; do
    [ -n "$REL" ] || continue
    LINK="$CHECKOUT/$REL"
    DEST="$CACHE_ROOT/$NAME"

    if [ -L "$LINK" ]; then
        CUR="$(readlink "$LINK")"
        if [ "$CUR" = "$DEST" ]; then
            if [ -d "$DEST" ]; then
                echo "ok       $REL -> $DEST"
            else
                echo "DANGLING $REL -> $DEST (the cache directory is gone)" >&2
                [ "$MODE" = check ] && { RC=1; continue; }
                mkdir -p "$DEST" || _refuse "cannot create $DEST"
                echo "repaired $REL -> $DEST"
            fi
            continue
        fi
        echo "OTHER    $REL -> $CUR (not the shared cache)" >&2
        [ "$MODE" = check ] && RC=1
        continue
    fi

    if [ -d "$LINK" ]; then
        if [ -z "$(ls -A "$LINK" 2>/dev/null)" ]; then
            [ "$MODE" = check ] && { echo "unlinked $REL (empty directory)" >&2; RC=1; continue; }
            rmdir "$LINK" || _refuse "cannot remove the empty $LINK"
        elif [ "$MODE" = adopt ] && [ ! -e "$DEST" ]; then
            mkdir -p "$(dirname "$DEST")" || _refuse "cannot create $(dirname "$DEST")"
            echo "moving   $LINK -> $DEST (this copies across volumes and is not quick)" >&2
            mv "$LINK" "$DEST" || _refuse "could not move $LINK to $DEST"
        else
            echo "IN USE   $REL is a real directory with build output in it." >&2
            [ "$MODE" = check ] && { RC=1; continue; }
            if [ -e "$DEST" ]; then
                echo "         The shared cache already exists at $DEST, so there is nothing safe to do automatically: delete $LINK and run this again, or keep it and stay unshared." >&2
            else
                echo "         Run with --adopt to MOVE it to $DEST and share it, or delete it and run this again." >&2
            fi
            RC=1
            continue
        fi
    fi

    [ "$MODE" = check ] && { echo "unlinked $REL" >&2; RC=1; continue; }

    mkdir -p "$DEST" || _refuse "cannot create $DEST"
    mkdir -p "$(dirname "$LINK")" || _refuse "cannot create $(dirname "$LINK")"
    ln -s "$DEST" "$LINK" || _refuse "cannot link $LINK -> $DEST"
    echo "linked   $REL -> $DEST"
done <<EOF
$LINKS
EOF

exit $RC
