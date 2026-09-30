# shellcheck shell=bash
# cargo-target.sh — the ONE place that says where Cargo wrote a build.
#
#   . "$here/lib/cargo-target.sh"
#   target_dir="$(cargo_target_dir "$src_tauri")"
#
# CARGO_TARGET_DIR selects the cache root. The dispatcher isolates mutable output
# below it by physical Cargo workspace. Readers use that same resolver; a fixed
# <crate>/target path could select another checkout's binary or no binary at all.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo-cache-env.sh"
cargo_target_dir() {
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../bin/cargo" --richos-target-dir "$1"
}
