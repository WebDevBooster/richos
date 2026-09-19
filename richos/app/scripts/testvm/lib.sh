#!/usr/bin/env bash
# lib.sh — shared ground for the testvm harness. Sourced, never run.
#
# ===========================================================================
# WHAT THE HARNESS IS FOR
# ===========================================================================
# 2026-09-19. The CEO, twice within the hour:
#
#   "So, every engineer will keep opening the app making me unable to do
#    anything here or WHAT???"
#   "WHEN THE FUCK WILL THERE BE A PROPER FUCKING SETUP THAT WILL ENABLE
#    SUPER FAST DEVELOPMENT AND NOT PATHETICALLY SLOW SNAIL PACE DEVELOPMENT?"
#
# Until today an on-screen proof of the RichOS app meant a window on HIS Mac,
# taking HIS focus, one agent at a time, serialized behind his working day.
# This harness moves every such proof into a macOS virtual machine on the same
# Mac: the app opens on the guest's virtual display, nothing appears on his
# screen, and two proofs can run at once because they run in two guests.
#
# ===========================================================================
# EVERY DECISION HERE IS DELIBERATE — NO THIRD-PARTY DEFAULT IS TRUSTED
# ===========================================================================
# Each constant below that differs from the tool's own default says why.
# ===========================================================================

set -euo pipefail

# --- Where everything lives. ONE declared place (CEO §54). --------------------
# The engine's scratch-reaper only deletes inside DECLARED scratch roots, and
# this is not one of them — deliberately. The base image costs a 25 GB download
# and must survive every sweep. Ephemeral per-run clones are cleaned by stop.sh
# and swept by this harness's OWN reap.sh, which is where §54 is honored.
TESTVM_ROOT="${TESTVM_ROOT:-$HOME/.richos-testvm}"
TESTVM_BIN="$TESTVM_ROOT/bin"
TESTVM_LOG="$TESTVM_ROOT/log"
TESTVM_RUN="$TESTVM_ROOT/run"
TART_BIN="$TESTVM_BIN/tart.app/Contents/MacOS/tart"

# TART_HOME keeps images and VM disks inside our one declared directory instead
# of tart's default ~/.tart, so "where is the disk space" has one answer and
# "delete it all" is one rm.
export TART_HOME="${TART_HOME:-$TESTVM_ROOT/tart}"

# --- Pins. --------------------------------------------------------------------
# tart 2.33.1, NOT "latest". 2.36.0 and 2.37.0 hard-link
# @rpath/libswiftCompatibilitySpan.dylib — a Swift 6.2 runtime shipping only on
# macOS 26 / Xcode 26. On this macOS 15.6 host they abort in dyld before main
# and macOS puts a crash dialog on the CEO's screen. 2.33.1 weak-links it.
# Re-check this pin when the host is upgraded past macOS 15.
TESTVM_TART_VERSION="${TESTVM_TART_VERSION:-2.33.1}"

# The guest. Sequoia = macOS 15, matching the host's major version, so what the
# app does in the guest is what it does on his Mac. `base` (not `vanilla`)
# because it ships Homebrew and, critically, has SIP DISABLED — which is the
# only reason the TCC grants in provision-guest.sh can be written at all.
# ghcr publishes only a `latest` tag for this image, so the pin that actually
# means something is the digest, recorded at pull time in IMAGE_DIGEST.
TESTVM_IMAGE="${TESTVM_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
TESTVM_BASE_VM="${TESTVM_BASE_VM:-richos-base}"

# Guest display. The app derives a 1400x880 window and refuses below 1024x700,
# so the screen must clear 1400x950 with room for the menu bar. tart's default
# is 1024x768 — too small, the window would be clipped and every screenshot
# would be a lie. 1680x1050 leaves margin without wasting guest memory.
TESTVM_DISPLAY="${TESTVM_DISPLAY:-1680x1050}"

# Per-VM resources. Host has 10 cores / 24 GB. TWO guests must run at once
# (that is the point), so a guest gets 4 cores and 7 GB: 2x7=14 GB leaves 10 GB
# for the host, its own apps and the CEO's work. macOS guests below ~6 GB swap
# hard and boot slowly, so 7 GB is the floor that keeps boots honest, not a
# luxury. tart's defaults (whatever the image baked) are not trusted.
TESTVM_CPU="${TESTVM_CPU:-4}"
TESTVM_RAM_MB="${TESTVM_RAM_MB:-7168}"

# The guest account the app runs as. It must be the console (auto-login) user:
# a window only exists inside the GUI session, and screencapture over ssh can
# only see the session its user owns.
TESTVM_GUEST_USER="${TESTVM_GUEST_USER:-admin}"
TESTVM_GUEST_PASS="${TESTVM_GUEST_PASS:-admin}"

TESTVM_SSH_KEY="${TESTVM_SSH_KEY:-$TESTVM_ROOT/id_testvm}"

# ssh options: no host-key prompt or pollution — a guest is disposable and its
# key changes every clone, so StrictHostKeyChecking=no plus a THROWAWAY known
# hosts file keeps the CEO's ~/.ssh/known_hosts untouched.
TESTVM_SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
)

log()  { printf '[testvm] %s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die()  { printf '[testvm] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Never execute an unproven binary. ----------------------------------------
# See preflight-binary.py's header: a bare `tart --version` put a crash dialog
# on the CEO's screen on 2026-09-19. Every entry point calls this BEFORE tart.
preflight_tart() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -x "$TART_BIN" ] || die "tart is not installed at $TART_BIN — run testvm/setup.sh"
  python3 "$script_dir/preflight-binary.py" "$TART_BIN" --quiet \
    || die "tart failed its launch preflight (above). Refusing to execute it: running it anyway is what puts a crash dialog on the CEO's screen."
}

tart() { "$TART_BIN" "$@"; }

# Parsed, never grepped. tart pretty-prints its JSON as `"Name" : "value"`, so
# a grep for "Name":"value" silently finds nothing and every caller concludes
# the VM does not exist — which is exactly what happened the first time this
# ran. Source is checked too: an OCI row is the downloaded IMAGE, not a local
# VM, and the two share a name space.
vm_exists() {
  tart list --format json 2>/dev/null | python3 -c "
import json,sys
want=sys.argv[1]
try: rows=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(r.get('Name')==want and r.get('Source')=='local' for r in rows) else 1)
" "$1"
}

vm_running() {
  tart list --format json 2>/dev/null \
    | python3 -c "
import json,sys
want=sys.argv[1]
try: rows=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(r.get('Name')==want and r.get('Source')=='local' and r.get('Running') for r in rows) else 1)
" "$1"
}

# The guest's IP. tart reports it only once the guest agent is up, which is the
# real signal that the guest has finished booting.
vm_ip() { tart ip "$1" --wait 180 2>/dev/null; }

guest_ssh() {
  local vm="$1"; shift
  local ip
  ip="$(cat "$TESTVM_RUN/$vm/ip" 2>/dev/null || vm_ip "$vm")" || die "no IP for VM $vm"
  ssh "${TESTVM_SSH_OPTS[@]}" -i "$TESTVM_SSH_KEY" "$TESTVM_GUEST_USER@$ip" "$@"
}

guest_scp() {
  local vm="$1"; shift
  local ip
  ip="$(cat "$TESTVM_RUN/$vm/ip" 2>/dev/null || vm_ip "$vm")" || die "no IP for VM $vm"
  # -O forces the legacy SCP protocol: macOS guests ship an sftp-server that
  # some images leave disabled, and the modern default silently fails there.
  scp "${TESTVM_SSH_OPTS[@]}" -O -i "$TESTVM_SSH_KEY" -r "$@" "$TESTVM_GUEST_USER@$ip:"
}

require_vm_running() {
  vm_exists "$1" || die "no such VM: $1"
  vm_running "$1" || die "VM $1 is not running — start it with testvm/run.sh"
}
