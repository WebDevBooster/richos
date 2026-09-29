# shellcheck shell=bash
# cargo-target.sh — the ONE place that says where Cargo wrote a build.
#
#   . "$here/lib/cargo-target.sh"
#   target_dir="$(cargo_target_dir "$src_tauri")"
#
# Cargo writes to $CARGO_TARGET_DIR when it is set (the shared target
# /Volumes/E1TB/caches/cargo-target/ is one) and to <crate>/target otherwise. A script that
# builds and then looks under <crate>/target finds nothing, or a stale build left there, when
# the variable is set. A relative CARGO_TARGET_DIR is relative to the directory Cargo ran in,
# which every caller makes the crate directory, so it is resolved against that.
cargo_target_dir() {
  local crate_dir="$1" dir="${CARGO_TARGET_DIR:-}"
  if [ -z "$dir" ]; then
    printf '%s\n' "$crate_dir/target"
  elif [ "${dir#/}" != "$dir" ]; then
    printf '%s\n' "$dir"
  else
    printf '%s\n' "$crate_dir/$dir"
  fi
}
