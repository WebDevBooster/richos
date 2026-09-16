#!/usr/bin/env bash
# Shared by packaging-ci and nightly; the upstream archive is digest-pinned.
set -euo pipefail
case "$(uname -m)" in
  arm64|aarch64)
    asset=cargo-tauri-aarch64-apple-darwin.zip
    want=82bdcb9ae7f407882321680ae50750f11623fae22445f8b00b096e10f815d604 ;;
  x86_64)
    asset=cargo-tauri-x86_64-apple-darwin.zip
    want=f10dfcc103ccb79248ca27cb9aff7b8a65499d1b0df79fe0465e8aa0a8e7cbef ;;
  *) echo 'Unsupported Tauri CLI architecture' >&2; exit 1 ;;
esac
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 --retry-connrefused -o "$scratch/$asset" \
  "https://github.com/tauri-apps/tauri/releases/download/tauri-cli-v2.11.4/$asset"
got="$(shasum -a 256 "$scratch/$asset" | awk '{print $1}')"
[ "$got" = "$want" ] || { echo 'Tauri CLI digest mismatch' >&2; exit 1; }
unzip -q "$scratch/$asset" -d "$scratch/cli"
mkdir -p "$HOME/.cargo/bin"
install -m 0755 "$scratch/cli/cargo-tauri" "$HOME/.cargo/bin/cargo-tauri"
if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$HOME/.cargo/bin" >> "$GITHUB_PATH"; fi
PATH="$HOME/.cargo/bin:$PATH" cargo tauri --version
