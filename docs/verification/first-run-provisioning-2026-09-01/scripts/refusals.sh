#!/usr/bin/env bash
# THE TWO REFUSALS, PROVED BY TRYING TO MAKE THEM FAIL.
#
# A refusal nobody has attempted is a comment. Each case below runs the SHIPPED code — the
# real `provision`, and the real `loro-context.mjs` — against the thing it is supposed to
# refuse, and prints what came back.
#
#   1. NO SILENT DEFAULT. Unset, blank and relative targets, each with a clean HOME and an
#      environment holding nothing. A wrong corpus or a cheerful exit 0 would be the failure.
#   2. NOT INSIDE THE PRODUCT REPO. Both markers: loro's own (`loro/lib/store.js` +
#      `loro/bin/loro-context.mjs`, `layout.js:391`) and the richos product repo as it
#      actually is (`app/crates/richos-core/Cargo.toml`) — which loro's detector CANNOT see,
#      because richos ships no `loro/`.
#   3. AND THE COMPILER'S OWN REFUSAL, for the placement question this design turns on:
#      tools inside the corpus, tools as a sibling `loro/`, tools as a sibling `loro-tools/`.
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")/../../../../app" && pwd)"
WORK="${1:?usage: refusals.sh <work-dir> [loro-source]}"
SOURCE="${2:-/Users/alex/ab/richos-hq/loro}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
NODE="${NODE:-/opt/homebrew/bin/node}"

rm -rf "$WORK"; mkdir -p "$WORK"
( cd "$APP_DIR" && "$CARGO" build -q -p richos-core --example provision_refusals ) || exit 1
/usr/bin/env -i HOME="$WORK/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$APP_DIR/target/debug/examples/provision_refusals" "$WORK"

echo
echo "=== 3. the compiler's own refusal, by placement — the real loro-context.mjs ==="
for case in inside sibling-loro sibling-loro-tools; do
    root="$WORK/place-$case"
    mkdir -p "$root/corpus/ceo/records" "$root/corpus/companies"
    case "$case" in
        inside)             /usr/bin/ditto "$SOURCE" "$root/corpus/loro" ;;
        sibling-loro)       /usr/bin/ditto "$SOURCE" "$root/loro" ;;
        sibling-loro-tools) /usr/bin/ditto "$SOURCE" "$root/loro-tools" ;;
    esac
    bin="$(find "$root" -name loro-context.mjs -path '*/bin/*' | head -1)"
    echo "--- tools at ${bin%/bin/loro-context.mjs} ---"
    "$NODE" "$bin" corpus --corpus "$root/corpus" --format json 2>&1 | head -3
done
