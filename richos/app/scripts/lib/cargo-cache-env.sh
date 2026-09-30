# shellcheck shell=bash
# Source before launching Cargo or a script that can launch it. Registry downloads
# remain shared. An existing sccache setup can share compiled dependencies safely.
richos_cargo_enable() {
  local richos_cargo_bin
  richos_cargo_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../bin" || return 1
  richos_cargo_bin="$(cd "$richos_cargo_bin" && pwd -P)" || return 1
  if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    return 0
  fi
  case "$PATH" in
    "$richos_cargo_bin":*) ;;
    *) export PATH="$richos_cargo_bin:$PATH" ;;
  esac
  if [ -z "${RUSTC_WRAPPER:-}" ] && [ -z "${CARGO_BUILD_RUSTC_WRAPPER:-}" ]; then
    if command -v sccache >/dev/null 2>&1; then
      RUSTC_WRAPPER="$(command -v sccache)"
      export RUSTC_WRAPPER
    elif [ -x /Volumes/E1TB/tools/sccache/v0.18.0/sccache ]; then
      export RUSTC_WRAPPER=/Volumes/E1TB/tools/sccache/v0.18.0/sccache
    fi
    if [ -n "${RUSTC_WRAPPER:-}" ]; then
      export SCCACHE_DIR="${SCCACHE_DIR:-/Volumes/E1TB/caches/sccache/richos}"
    fi
  fi
  richos_sccache_server_start
}

# The sccache server outlives the agent that starts it and creates its temp files under the TMPDIR
# and working directory it inherited. Started from an agent's workspace, it fails every
# metadata-only compile (Clippy, check) once that workspace is closed. So start it here, from
# "/" with a fixed TMPDIR that no agent owns. An already running server is left alone.
richos_sccache_server_start() {
  local wrapper="${RUSTC_WRAPPER:-${CARGO_BUILD_RUSTC_WRAPPER:-}}" fixed_tmp
  case "$(basename "${wrapper:-none}")" in sccache) ;; *) return 0 ;; esac
  fixed_tmp="${RICHOS_SCCACHE_TMPDIR:-/Volumes/E1TB/tmp/sccache-server}"
  mkdir -p "$fixed_tmp" 2>/dev/null || return 0
  ( cd / && TMPDIR="$fixed_tmp" "$wrapper" --start-server </dev/null >/dev/null 2>&1 ) || true
}
richos_cargo_enable
