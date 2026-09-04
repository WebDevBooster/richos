#!/usr/bin/env bash
# Reproducibility proof: a fresh clone of zach-opus-p2 builds from the tracked
# lockfiles with --locked, resolving nothing dynamically.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

SRC=/Users/alex/ab/richos-wt/zach-opus-p2
SC=/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad
CLONE=$SC/proofclone
TARGET=$SC/proof-target

rm -rf "$CLONE" "$TARGET"

banner() { printf '\n=== %s ===\n' "$1"; }

banner "toolchain"
cargo --version
rustc --version

banner "fresh clone of branch zach-opus-p2"
git clone -q --branch zach-opus-p2 "$SRC" "$CLONE"
cd "$CLONE" || exit 1
echo "HEAD: $(git rev-parse HEAD)"
echo "branch: $(git rev-parse --abbrev-ref HEAD)"

banner "1. git ls-files lists both application lockfiles"
git ls-files '*Cargo.lock'

banner "2. no ignore rule hides them (git check-ignore, exit 1 = nothing ignored)"
git check-ignore -v app/Cargo.lock app/src-tauri/Cargo.lock
echo "check-ignore exit: $?  (1 means neither path is ignored)"

banner "3. lockfile digests"
shasum -a 256 app/Cargo.lock app/src-tauri/Cargo.lock tools/native-claude-stdio/Cargo.lock

banner "4. app workspace: cargo metadata --locked --offline"
( cd app && cargo metadata --locked --offline --format-version 1 > /dev/null && echo "OK - graph fully determined by the lockfile, no index access" )

banner "5. tauri workspace: cargo metadata --locked --offline"
( cd app/src-tauri && cargo metadata --locked --offline --format-version 1 > /dev/null && echo "OK - graph fully determined by the lockfile, no index access" )

banner "6. package counts resolved from the lockfiles"
( cd app && cargo metadata --locked --offline --format-version 1 | python3 -c "import json,sys; m=json.load(sys.stdin); print('app workspace:', len([p for p in m['packages'] if p.get('source')]), 'third-party packages')" )
( cd app/src-tauri && cargo metadata --locked --offline --format-version 1 | python3 -c "import json,sys; m=json.load(sys.stdin); print('tauri workspace:', len([p for p in m['packages'] if p.get('source')]), 'third-party packages')" )

banner "7. cargo test --locked -p richos-core (fresh target dir)"
( cd app && CARGO_TARGET_DIR="$TARGET/app" cargo test --locked -p richos-core 2>&1 | grep -E 'Updating|Locking|Adding|Downloaded|^test result:|^error' )
echo "-- no Updating/Locking/Adding line above means nothing was resolved dynamically --"

banner "8. cargo build --locked --release -p richos-core"
( cd app && CARGO_TARGET_DIR="$TARGET/app" cargo build --locked --release -p richos-core 2>&1 | tail -3 )

banner "9. cargo check --locked --all-targets in the detached tauri workspace"
( cd app/src-tauri && CARGO_TARGET_DIR="$TARGET/tauri" cargo check --locked --all-targets 2>&1 | tail -3 )

banner "10. the generated dependency inventory still matches the lockfiles"
bash app/scripts/dependency-license-inventory.sh --check

banner "11. publication completeness"
bash engine/scripts/publication-completeness.sh --root . 2>&1 | tail -6

banner "done"
