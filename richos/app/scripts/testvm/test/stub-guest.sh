#!/usr/bin/env bash
# stub-guest.sh — a guest that is a text file.
#
#   $TESTVM_GUEST_EXEC <vm> <shell command string>
#
# `tailnet.sh` reaches its guest through ONE indirection (`tsg`), so pointing
# that at this script exercises every decision in the join — the flags, the
# order, the key handling, the refusal classification, the name read-back —
# against a machine that boots in no seconds and costs no memory.
#
# It records every command it was handed to $STUB_LOG, which is how the tests
# assert the things that matter most and are hardest to see: that the auth key
# never appears in a command line, and that it is deleted from the guest.
#
# Behavior is steered by $STUB_MODE:
#   ok             a tailnet that works
#   invalid-key    `tailscale up` refuses the key the way 1.102.4 really does
#   certs-off      joined, but the tailnet will not certify the node
#   never-running  `up` returns 0 and the daemon never reaches Running
#   no-cert        Running and certified, but `cert` hands back nothing
set -uo pipefail
VM="$1"; shift
CMD="$*"
STUB_LOG="${STUB_LOG:-/dev/null}"
STUB_MODE="${STUB_MODE:-ok}"
STUB_DNSNAME="${STUB_DNSNAME:-richos-test-a.tail770f6e.ts.net}"
printf '%s\t%s\n' "$VM" "$CMD" >> "$STUB_LOG"

# stdin is consumed for the commands that take it, exactly as ssh would, so a
# test can assert what was written rather than what was intended.
case "$CMD" in
  *"cat > "*)
    target="$(printf '%s' "$CMD" | sed -n "s/.*cat > '\([^']*\)'.*/\1/p")"
    mkdir -p "${STUB_GUEST_FS:-/tmp}$(dirname "$target")"
    cat > "${STUB_GUEST_FS:-/tmp}$target"
    # A copy that survives the deletion, so a test can prove the key ARRIVED
    # as well as proving it left. Without it, "the file is gone" is equally
    # true of a key that was never written.
    [ -n "${STUB_KEEP_STAGED:-}" ] && cp "${STUB_GUEST_FS:-/tmp}$target" "$STUB_KEEP_STAGED"
    exit 0 ;;
  *"rm -f "*)
    target="$(printf '%s' "$CMD" | sed -n "s/.*rm -f '\([^']*\)'.*/\1/p")"
    rm -f "${STUB_GUEST_FS:-/tmp}$target"
    exit 0 ;;
  *"tee "*)
    cat > /dev/null
    exit 0 ;;
esac

case "$CMD" in
  *"tailscale up"*)
    case "$STUB_MODE" in
      invalid-key) echo "backend error: invalid key: unable to validate API key"; exit 1 ;;
      *) echo "Success."; exit 0 ;;
    esac ;;
  *"tailscale status --json"*)
    # A guest that has logged out answers as a signed-out guest, whatever mode
    # it was in before — which is the whole thing `logout` has to verify.
    if [ -n "${STUB_LOGOUT_MARKER:-}" ] && [ -f "$STUB_LOGOUT_MARKER" ]; then
      printf '{"BackendState":"NeedsLogin","Self":{"DNSName":""},"CertDomains":null}\n'
      exit 0
    fi
    case "$STUB_MODE" in
      never-running) printf '{"BackendState":"NeedsLogin","Self":{"DNSName":""},"CertDomains":null}\n'; exit 0 ;;
      certs-off)     printf '{"BackendState":"Running","Self":{"DNSName":"%s.","Online":true,"TailscaleIPs":["100.64.0.9"]},"CertDomains":null}\n' "$STUB_DNSNAME"; exit 0 ;;
      signed-out)    printf '{"BackendState":"NeedsLogin","Self":{"DNSName":""},"CertDomains":null}\n'; exit 0 ;;
      *)             printf '{"BackendState":"Running","Self":{"DNSName":"%s.","Online":true,"TailscaleIPs":["100.64.0.9","fd7a:115c:a1e0::9"]},"CertDomains":["%s"]}\n' "$STUB_DNSNAME" "$STUB_DNSNAME"; exit 0 ;;
    esac ;;
  *"tailscale cert"*)
    case "$STUB_MODE" in
      no-cert) exit 1 ;;
      *) [ -f "${STUB_CERT_PEM:-}" ] && cat "$STUB_CERT_PEM"; exit 0 ;;
    esac ;;
  *"tailscale logout"*|*"tailscale down"*)
    # The tests point STUB_MODE at signed-out for the second status read.
    [ -n "${STUB_LOGOUT_MARKER:-}" ] && : > "$STUB_LOGOUT_MARKER"
    exit 0 ;;
  *"ls -l"*) echo "-rwxr-xr-x 1 root wheel 0 tailscale"; exit 0 ;;
  *) exit 0 ;;
esac
