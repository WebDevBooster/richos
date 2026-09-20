#!/usr/bin/env bash
# guest.sh — one word to run something inside a test guest, and to move a file
#            either way.
#
#   testvm/guest.sh <vm> '<shell command>'          # one string: the guest's shell runs it
#   testvm/guest.sh <vm> <cmd> <arg> <arg>...       # several: each is quoted, none is re-parsed
#   testvm/guest.sh <vm> --pull <guest-path> <host-path>
#   testvm/guest.sh <vm> --push <host-path> <guest-path>
#
#   printf '%s' "$SECRET" | testvm/guest.sh <vm> 'cat > /tmp/x'   # stdin goes through
#
# The exit code is the GUEST COMMAND'S. stdout is the guest's stdout, stderr is
# the guest's stderr, and nothing of this script's own is mixed into either.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# The CEO, 2026-09-20: *"How many times does Ray build the same scripts or
# checks from scratch (for the same type of job)? And how much time does that
# waste in every one of his runs?"*
#
# `lib.sh` has had `guest_ssh` since the harness was written, and it is a SHELL
# FUNCTION in a file that is sourced, never run — so nothing on a command line
# could call it. Every walk therefore wrote its own wrapper around the same four
# ssh options: `guest.sh`, `gssh.sh`, `pull.sh`, `pullstates.sh`, `publish.sh`,
# `guest-probe1.sh`, `guest-probe2.sh`, `guest-probe3.sh`, `guest-authcheck.sh`,
# `guest-fixengine.sh`, `guest-relaunch.sh` — eleven of them across three walks,
# each one pasting the same `-o StrictHostKeyChecking=no -o UserKnownHostsFile=
# /dev/null -i ~/.richos-testvm/id_testvm` and each one free to get a flag
# subtly wrong. One of them reached the guest by wrapping the WHOLE command in
# an AppleScript `do shell script` through ax.sh, quoting it with a python
# one-liner, because there was no CLI entry point to `guest_ssh`.
#
# This is that entry point. It is deliberately thin: the options live in lib.sh
# and nothing here copies them.
#
# ===========================================================================
# ONE STRING IS A SHELL COMMAND; SEVERAL ARE ARGUMENTS
# ===========================================================================
# ssh joins its arguments with spaces and hands the result to the guest's shell,
# so `ssh host ls '/a b'` runs `ls /a b` — two arguments, silently, and the
# error blames the guest. The rule here is stated rather than inherited:
#
#   ONE argument  -> passed through verbatim. Pipes, redirections and $VARs are
#                    the GUEST's, which is what `'cat > /tmp/x'` needs.
#   SEVERAL       -> each is quoted for the guest's shell and joined, so a path
#                    with a space stays one path. Force this for a single
#                    argument with `--`: `guest.sh vm -- 'my file.txt'`.
#
# ===========================================================================
# A SECRET GOES ON STDIN, NEVER IN THE COMMAND
# ===========================================================================
# stdin is passed straight through, because that is the only place a credential
# may travel: a command line is visible in the guest's process table and in
# every log that echoes what it ran. `claude-login.sh` writes the CEO's
# credential this way and so must anything else.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e

VM="${1:-}"; shift 2>/dev/null
[ -n "$VM" ] || die "usage: guest.sh <vm> <command...> | --pull <guest> <host> | --push <host> <guest>"
[ $# -gt 0 ] || die "guest.sh $VM: nothing to run. Give a command, or --pull/--push."

[ -f "$TESTVM_SSH_KEY" ] || die "no ssh key at $TESTVM_SSH_KEY — run testvm/setup.sh"

# The address, without waking tart when we already know it. `run.sh` writes the
# IP the moment the guest reports one, so the ordinary case costs a `cat`; only
# a guest nothing has recorded pays for a `tart ip`, and THAT path preflights
# the binary first (lib.sh: a bare `tart --version` once put a crash dialog on
# the CEO's screen).
guest_addr() {
  local ip
  ip="$(cat "$TESTVM_RUN/$VM/ip" 2>/dev/null)"
  if [ -z "$ip" ]; then
    # The ask runs in a SUBSHELL because `preflight_tart` exits rather than
    # returning, and "tart is not installed" is the wrong sentence to end a
    # `guest.sh <vm> uname -a` with: the question was which guest, not which
    # hypervisor. Whatever went wrong there, the refusal below names the VM.
    ip="$( (preflight_tart >/dev/null 2>&1 && vm_ip "$VM" 2>/dev/null) || true )"
  fi
  [ -n "$ip" ] || die "no address for $VM — nothing has recorded one at $TESTVM_RUN/$VM/ip and tart could not be asked for it. Start it with testvm/run.sh --vm $VM ..., or list the guests with tart list."
  printf '%s' "$ip"
}

case "$1" in
  --pull|--push)
    DIRECTION="$1"; shift
    SRC="${1:-}"; DST="${2:-}"
    [ -n "$SRC" ] && [ -n "$DST" ] || die "$DIRECTION needs two paths: $DIRECTION <from> <to>"
    IP="$(guest_addr)" || exit 1
    # -O forces the legacy SCP protocol, for the same reason every other copy in
    # this harness does: some macOS images ship an sftp-server that is disabled,
    # and the modern default fails there without saying why.
    if [ "$DIRECTION" = "--pull" ]; then
      scp "${TESTVM_SSH_OPTS[@]}" -O -r -i "$TESTVM_SSH_KEY" \
          "$TESTVM_GUEST_USER@$IP:$SRC" "$DST"
    else
      [ -e "$SRC" ] || die "no such file on this Mac: $SRC"
      scp "${TESTVM_SSH_OPTS[@]}" -O -r -i "$TESTVM_SSH_KEY" \
          "$SRC" "$TESTVM_GUEST_USER@$IP:$DST"
    fi
    exit $?
    ;;
  --)
    shift
    [ $# -gt 0 ] || die "guest.sh $VM: -- with nothing after it"
    LITERAL=1
    ;;
  *)
    LITERAL=0
    ;;
esac

if [ "$LITERAL" -eq 0 ] && [ $# -eq 1 ]; then
  CMD="$1"
else
  CMD=""
  for a in "$@"; do
    # printf %q quotes for a POSIX shell; bash 3.2 (this Mac's /bin/bash) has it.
    CMD="$CMD${CMD:+ }$(printf '%q' "$a")"
  done
fi

# ONE string to ssh, so its own argument-joining never gets a say. The options
# and the key come from lib.sh — nothing here keeps a second copy of them, which
# is the whole reason eleven hand-rolled wrappers were a problem.
IP="$(guest_addr)" || exit 1
ssh "${TESTVM_SSH_OPTS[@]}" -i "$TESTVM_SSH_KEY" "$TESTVM_GUEST_USER@$IP" "$CMD"
RC=$?

# 255 is ssh's OWN failure code — it could not connect, authenticate or allocate
# a session. A guest command is free to exit 255 too, so the code is passed
# through untouched either way and only the EXPLANATION is added. Diagnosing
# costs a `tart list` and is worth it exactly once, when the connection failed.
if [ "$RC" -eq 255 ]; then
  {
    echo "[testvm] ssh to $VM exited 255 — that is ssh's own failure code (it could not"
    echo "         connect, authenticate, or open a session), not necessarily the command's."
  } >&2
  # The diagnosis runs in a SUBSHELL so that nothing it calls can change this
  # script's exit code: `preflight_tart` exits 1 when tart is not installed, and
  # a diagnosis that replaced the guest's 255 with its own 1 would be a wrapper
  # lying about what it wrapped.
  (
    preflight_tart >/dev/null 2>&1 || exit 0
    if vm_exists "$VM" 2>/dev/null; then
      if vm_running "$VM" 2>/dev/null; then
        echo "         $VM IS running. The guest may still be booting — run.sh waits up to"
        echo "         60s for ssh — or the recorded address is stale: $TESTVM_RUN/$VM/ip"
      else
        echo "         $VM exists but is NOT running. Start it: testvm/run.sh --vm $VM ..."
      fi
    else
      echo "         There is no VM called $VM. List them with tart list."
    fi
  ) >&2
fi

exit $RC
