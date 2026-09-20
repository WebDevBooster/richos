#!/usr/bin/env bash
# claude-sync.sh — the `claude` in the guest IS the `claude` on the host, at
#                  every run, or the run stops.
#
#   testvm/claude-sync.sh <vm>            compare, copy if they differ, verify
#   testvm/claude-sync.sh --check <vm>    compare and report, copy nothing
#
# Prints ONE line on stdout, always in the same shape:
#
#   claude: host 2.1.277 guest 2.1.277
#
# and exits non-zero when the two are not the same binary. Everything else it
# has to say goes to stderr, so a caller can put that line straight into its
# own summary.
#
# ===========================================================================
# THE DEFECT THIS EXISTS FOR
# ===========================================================================
# The CEO, 2026-09-20: *"What happens with the Claude binary in the VM? Will it
# always stay on the same version regardless of any updates?"*
#
# It did. `setup.sh` copied the host's binary into the BASE IMAGE once, when
# the image was built, and `run.sh` never looked at it again — while the host's
# Claude Code kept auto-updating underneath it (2.1.274 and 2.1.275 on the
# 17th, 2.1.276 and 2.1.277 on the 18th, by the mtimes of
# ~/.local/share/claude/versions/*). Every day after a setup, the VM tested
# the app against a `claude` the CEO no longer ran, the gap grew, and no line
# of output ever said so. A harness whose whole purpose is "what he will see"
# cannot hold a different version of the one binary the app shells out to.
#
# So: compared at EVERY run, by sha256 of the RESOLVED host binary; copied when
# it differs; verified after the copy; and the two versions printed whether
# they matched or not, because a number nobody prints is a number nobody
# checks.
# ===========================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e

MODE="sync"
VM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    -*) die "unknown argument: $1" ;;
    *) VM="$1"; shift ;;
  esac
done
[ -n "$VM" ] || die "usage: claude-sync.sh [--check] <vm>"

# ONE indirection to the guest, the same shape `tailnet.sh` and `keychain.sh`
# use, so every decision in here is testable against a guest that is a text
# file rather than a 25 GB image.
cg() {  # cg <shell command string>
  if [ -n "${TESTVM_GUEST_EXEC:-}" ]; then
    "$TESTVM_GUEST_EXEC" "$VM" "$@"
  else
    guest_ssh "$VM" "$@"
  fi
}

# The copy has its own indirection for the same reason. -O (legacy scp) for the
# same reason every other copy in this harness uses it: some macOS guests ship
# an sftp-server that is disabled, and the modern default fails silently there.
cg_put() {  # cg_put <local-file> <remote-absolute-path>
  if [ -n "${TESTVM_GUEST_PUT:-}" ]; then
    "$TESTVM_GUEST_PUT" "$VM" "$1" "$2"
    return $?
  fi
  local ip
  ip="$(cat "$TESTVM_RUN/$VM/ip" 2>/dev/null || vm_ip "$VM")" || return 1
  scp "${TESTVM_SSH_OPTS[@]}" -O -i "$TESTVM_SSH_KEY" "$1" \
      "$TESTVM_GUEST_USER@$ip:$2" >/dev/null 2>&1
}

guest_sha() {
  cg "shasum -a 256 '$TESTVM_GUEST_CLAUDE' 2>/dev/null | awk '{print \$1}'" 2>/dev/null \
    | tr -d '[:space:]'
}

# The guest's own answer to `--version`, with the auto-updater pinned off for
# the probe itself — a version check that could trigger an update would be the
# very drift this script exists to prevent. `perl -e alarm` is the deadline;
# macOS ships no `timeout(1)`.
guest_version() {
  cg "$TESTVM_CLAUDE_PIN_VAR=$TESTVM_CLAUDE_PIN_VALUE perl -e 'alarm shift; exec @ARGV' ${TESTVM_CLAUDE_TIMEOUT:-90} '$TESTVM_GUEST_CLAUDE' --version 2>/dev/null" 2>/dev/null \
    | awk 'NF{print $1; exit}'
}

# --- 1. the host side ---------------------------------------------------------
HOSTBIN="$(host_claude_path)"
if [ -z "$HOSTBIN" ] || [ ! -x "$HOSTBIN" ]; then
  claude_version_line "" ""
  cat >&2 <<EOF
[testvm] REFUSED: there is no claude binary on this host to test against.
         looked at: $TESTVM_HOST_CLAUDE
         The app shells out to \`claude\`; a guest given a stale copy, or no
         copy, is not the Mac the CEO runs. Install Claude Code on the host,
         or point TESTVM_HOST_CLAUDE at the binary to use.
EOF
  exit 2
fi
HSHA="$(sha256_file "$HOSTBIN")"
HVER="$(claude_version_of "$HOSTBIN")"
log "host claude: ${HVER:-unreadable}  ($HOSTBIN)"

# --- 2. the guest side, before anything is changed ----------------------------
GSHA="$(guest_sha)"
GVER=""
[ -n "$GSHA" ] && GVER="$(guest_version)"

VERDICT="$(claude_sync_verdict "$HSHA" "$GSHA" "$HVER" "$GVER")"

if [ "$MODE" = "check" ]; then
  claude_version_line "$HVER" "$GVER"
  [ "$VERDICT" = "in-sync" ] && exit 0
  log "check: $VERDICT (host sha ${HSHA:0:12}, guest sha ${GSHA:0:12})"
  exit 1
fi

# --- 3. copy, only when the bytes differ --------------------------------------
if [ "$VERDICT" = "copy" ]; then
  if [ -z "$GSHA" ]; then
    log "the guest has no claude at $TESTVM_GUEST_CLAUDE — copying the host's in"
  else
    log "the guest's claude is not the host's (${GVER:-unknown} vs ${HVER:-unknown}) — copying the host's in"
  fi
  T0=$(date +%s)
  cg "mkdir -p \"\$(dirname '$TESTVM_GUEST_CLAUDE')\"" >/dev/null 2>&1
  # Copied to a side path and moved into place: a half-written 217 MB binary at
  # the path the app launches is a worse state than an old one.
  if ! cg_put "$HOSTBIN" "$TESTVM_GUEST_CLAUDE.new"; then
    claude_version_line "$HVER" "$GVER"
    log "REFUSED: the copy of the claude binary into $VM failed (scp)."
    exit 3
  fi
  cg "chmod 755 '$TESTVM_GUEST_CLAUDE.new' && mv -f '$TESTVM_GUEST_CLAUDE.new' '$TESTVM_GUEST_CLAUDE'" >/dev/null 2>&1
  log "copied in $(( $(date +%s) - T0 ))s"

  # Re-measured, never assumed. `scp` reporting success and the file on the
  # other side being right are two different claims.
  GSHA="$(guest_sha)"
  GVER="$(guest_version)"
  VERDICT="$(claude_sync_verdict "$HSHA" "$GSHA" "$HVER" "$GVER")"
fi

# --- 4. pin the guest's auto-updater off --------------------------------------
# Belt and braces with the env var `run.sh` puts on the launch: a `claude`
# started by hand over ssh in a long walk would otherwise be free to update
# itself out from under the version this line just printed. Idempotent, and it
# writes to the GUEST user's shell env, never to the fixture home.
if [ "$VERDICT" = "in-sync" ]; then
  cg "grep -q '$TESTVM_CLAUDE_PIN_VAR' ~/.zshenv 2>/dev/null || \
      printf 'export %s=%s\n' '$TESTVM_CLAUDE_PIN_VAR' '$TESTVM_CLAUDE_PIN_VALUE' >> ~/.zshenv" \
    >/dev/null 2>&1
fi

# --- 5. the line, and the verdict ---------------------------------------------
claude_version_line "$HVER" "$GVER"
if [ "$VERDICT" = "in-sync" ]; then
  exit 0
fi

cat >&2 <<EOF
[testvm] REFUSED: the claude in $VM is not the claude on this host.
         host : ${HVER:-unreadable}  sha ${HSHA:0:12}  ($HOSTBIN)
         guest: ${GVER:-unreadable}  sha ${GSHA:0:12}  ($TESTVM_GUEST_CLAUDE)
         A copy was attempted and the two still do not match, so what the guest
         would test is not what the CEO runs. Diagnose:
           $HERE/claude-sync.sh --check $VM
EOF
exit 4
