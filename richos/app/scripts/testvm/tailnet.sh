#!/usr/bin/env bash
# tailnet.sh — put a test guest ON THE TAILNET, so the phone path is walkable
#              in a VM instead of on the CEO's Mac.
#
#   testvm/tailnet.sh join   <vm>    join, and print tailnet=<dnsname>
#   testvm/tailnet.sh name   <vm>    what the guest currently calls itself
#   testvm/tailnet.sh logout <vm>    leave, before the guest is destroyed
#   testvm/tailnet.sh nodes          richos-test-* nodes the HOST still sees
#   testvm/tailnet.sh doctor <vm>    why the phone path is or is not available
#
# ===========================================================================
# WHY A GUEST HAS TO BE A TAILNET NODE AT ALL
# ===========================================================================
# The app refuses to hand out a pairing code unless it can serve one:
# `PhoneChannel::begin_pairing` returns `PhoneError::TailnetNotReady` when
# `serving_plan` is `None` (src-tauri/src/phone/mod.rs:858), and `serving_plan`
# (:563) needs three things — a tailnet name, an origin derived from it, and a
# certificate `tailscale cert` will actually issue. CEO §61 deleted the
# localhost/LAN fallback on purpose: *"any mobile app or PWA is utterly useless
# within the home network"*. There is one path, and a signed-out guest is not
# on it.
#
# So provision-guest.sh installs Tailscale and stops (its §6 says why: signing
# in needs the CEO's account and no agent may hold his credentials). This
# script is the other half: it uses a key HE created, once, that lives outside
# every repository, and it never prints it.
#
# ===========================================================================
# WHAT THE APP LOOKS FOR, AND WHERE — because "put the cert there" has no there
# ===========================================================================
# There is no certificate FILE the app reads. `tailnet::fetch_cert`
# (phone/tailnet.rs:722) runs
#
#     tailscale cert --cert-file - --key-file - --min-validity 720h <name>
#
# and parses the PEM blocks off STDOUT — deliberately, so the private key never
# touches a disk and so the Mac App Store sandbox variant works. The two things
# that must therefore be true INSIDE the guest are:
#
#   1. a `tailscale` binary at one of the four paths the app looks at
#      (phone/tailnet.rs:82). MEASURED in a guest, 2026-09-19:
#      /opt/homebrew/bin/tailscale -> ../Cellar/tailscale/1.102.4/bin/tailscale,
#      which is candidate 3 and is a symlink `is_file()` follows; and
#   2. a daemon that answers THE APP'S user, not just root. The app runs as the
#      guest's console user, so `--operator=<that user>` is part of the join.
#
# Everything this script writes for the certificate is a CACHE (see
# `cert_cache_*`), never the thing the app reads.
# ===========================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e

# Where the guest's tailscaled keeps state, and therefore its certificate cache.
# MEASURED 2026-09-19: the Homebrew launch daemon runs `tailscaled` with NO
# arguments, and its state file is /Library/Tailscale/tailscaled.state (root,
# 0700). Upstream derives the certificate directory from the state file's
# directory, so `certs/` beside it is where a cached certificate would live.
# `unverified:` — no certificate has been issued on this machine yet, so the
# filename convention below is upstream's documented one rather than one seen.
# Getting it wrong costs nothing: the daemon ignores files it does not read.
GUEST_STATE_DIR="${TESTVM_GUEST_STATE_DIR:-/Library/Tailscale}"

# Run a command in the guest. Indirected so the tests can drive every decision
# in this file against a stub instead of a 7 GB virtual machine.
tsg() {
  local vm="$1"; shift
  if [ -n "${TESTVM_GUEST_EXEC:-}" ]; then
    "$TESTVM_GUEST_EXEC" "$vm" "$@"
  else
    guest_ssh "$vm" "$@"
  fi
}

# ---------------------------------------------------------------------------
# the refusal, written once
# ---------------------------------------------------------------------------
# A missing key refuses ONE STEP. The VM still boots, still takes a bundle,
# still renders, still screenshots — everything that is not the phone path
# still works, because a harness that dies on a missing optional credential is
# a harness nobody can use for anything else.
refuse_tailnet() {
  local why="$1"
  cat >&2 <<EOF
[testvm] tailnet: NOT JOINED — $why

  THE ONE ACTION (the CEO's, once — no agent can do it):
    1. https://login.tailscale.com/admin/settings/keys  ->  Generate auth key
       Reusable: ON   Ephemeral: ON   Pre-approved: ON   Expiry: 90 days
    2. Save it, and nothing else, into the file below, readable by him alone:
         install -m 600 /dev/null $TESTVM_AUTHKEY
         printf '%s' 'tskey-auth-...' > $TESTVM_AUTHKEY

  Everything else in this VM still works. Only the phone path needs the key:
  without it the app answers "This Mac is not set up yet" rather than a code.
EOF
  return 1
}

# ---------------------------------------------------------------------------
# the certificate cache — `cert_cache_dir`/`_usable`/`_store` live in lib.sh,
# because reap.sh prunes the same cache and a second copy of the validity rule
# is a second answer to "is this certificate still good".
# ---------------------------------------------------------------------------
# Push a cached certificate into the guest's daemon store, as root, before the
# app asks for one. Best-effort by construction: if the layout guess is wrong
# the daemon simply issues a fresh certificate, which is what would have
# happened anyway.
cert_cache_push() {
  local vm="$1" name="$2" dir
  dir="$(cert_cache_dir "$name")"
  cert_cache_usable "$name" || return 1
  cat "$dir/cert.pem" | tsg "$vm" "sudo mkdir -p '$GUEST_STATE_DIR/certs' && sudo tee '$GUEST_STATE_DIR/certs/$name.crt' >/dev/null" || return 1
  cat "$dir/key.pem"  | tsg "$vm" "sudo tee '$GUEST_STATE_DIR/certs/$name.key' >/dev/null" || return 1
  tsg "$vm" "sudo chmod 600 '$GUEST_STATE_DIR/certs/$name.crt' '$GUEST_STATE_DIR/certs/$name.key'" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# reading the guest's tailnet state
# ---------------------------------------------------------------------------
# Parsed with python3, never grepped: `tailscale status --json` is a large
# document whose shape changes between releases, and a grep for a field name
# finds it inside a peer as happily as inside Self.
guest_status_field() {
  local vm="$1" what="$2"
  tsg "$vm" "$TESTVM_GUEST_TS status --json 2>/dev/null" | python3 -c '
import json,sys
want=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
self_=d.get("Self") or {}
name=(self_.get("DNSName") or "").strip().rstrip(".").lower()
if want=="state": print(d.get("BackendState") or "")
elif want=="name": print(name)
elif want=="online": print("yes" if self_.get("Online") else "no")
elif want=="certified":
    domains=[ (x or "").strip().rstrip(".").lower() for x in (d.get("CertDomains") or []) ]
    print("yes" if name and name in domains else "no")
elif want=="ips": print(" ".join(self_.get("TailscaleIPs") or []))
' "$what"
}

# ---------------------------------------------------------------------------
# join
# ---------------------------------------------------------------------------
cmd_join() {
  local vm="${1:-}"
  [ -n "$vm" ] || die "usage: tailnet.sh join <vm>"

  local node
  node="$(tailnet_node_name "$vm")" || {
    refuse_tailnet "'$vm' does not make a legal tailnet node name (a–z, 0–9 and hyphens, 63 max)"
    return 1
  }

  local problem
  problem="$(authkey_problem "$TESTVM_AUTHKEY")" || { refuse_tailnet "$problem"; return 1; }

  # The key goes into the guest as a FILE, and `tailscale up --auth-key file:…`
  # reads it there. Never as a command argument: an argument is visible in the
  # guest's own process table to every process in it, and in every log that
  # records a command line. The flag's own help says "if it begins with
  # file:, then it's a path to a file containing the authkey" — read off
  # `tailscale up --help` in the guest, version 1.102.4, rather than assumed.
  local keypath="/Users/$TESTVM_GUEST_USER/.richos-testvm-authkey"
  tsg "$vm" "umask 077; cat > '$keypath'" < "$TESTVM_AUTHKEY" || {
    refuse_tailnet "could not stage the key inside $vm"
    return 1
  }

  log "tailnet: joining as $node ..."
  # EVERY FLAG IS SPECIFIED, AND EVERY ONE IS A DECISION:
  #
  #   --auth-key file:…     the key never appears in argv (above).
  #   --hostname            without it the node is "Manageds-Virtual-Machine"
  #                         for EVERY clone — measured — so two guests would
  #                         collide into …-1 names nothing can predict.
  #   --operator            the app runs as the console user, not root, and
  #                         `tailscale cert` is a mutating call. Without this
  #                         the app's own certificate fetch is a permission
  #                         error it reports as "not set up yet".
  #   --reset               `up` with flags refuses if an UNSPECIFIED setting
  #                         would change; a clone must start from a known
  #                         state, not from whatever the base image last had.
  #   --accept-dns=true     the vendor default, and REQUIRED here rather than
  #                         inherited: the pairing URL is opened in Safari
  #                         inside this guest, and only MagicDNS resolves
  #                         <node>.<tailnet>.ts.net in there.
  #   --accept-routes=false a test node has no business pulling somebody's
  #                         subnet routes into its table.
  #   --shields-up=false    shields-up blocks INCOMING connections, which is
  #                         precisely what the phone makes. Stated, not
  #                         assumed, because the whole guest is disposable and
  #                         a stale pref would be invisible.
  #   --ssh=false           we already reach this guest over the LAN; a tailnet
  #                         SSH server is surface with no purpose here.
  #   --advertise-*         nothing. A throwaway node advertises nothing.
  #   --timeout             `up`'s own default is 0s, documented as "blocks
  #                         forever". An agent has no terminal to notice that.
  local out rc
  out="$(tsg "$vm" "sudo $TESTVM_GUEST_TS up \
      --auth-key 'file:$keypath' \
      --hostname '$node' \
      --operator '$TESTVM_GUEST_USER' \
      --reset \
      --accept-dns=true \
      --accept-routes=false \
      --shields-up=false \
      --ssh=false \
      --advertise-exit-node=false \
      --advertise-routes= \
      --timeout $TESTVM_TAILNET_TIMEOUT 2>&1")"
  # The exit status is read BEFORE anything is piped: `$?` after a pipeline is
  # the LAST command's, so redacting inline would have reported sed's success
  # as tailscale's and every failed join would have looked fine.
  rc=$?
  out="$(printf '%s' "$out" | redact_keys)"
  # The key file goes the moment it has been used, whether or not it worked.
  tsg "$vm" "rm -f '$keypath'" >/dev/null 2>&1

  if [ $rc -ne 0 ]; then
    case "$out" in
      *"invalid key"*|*"unable to validate API key"*)
        refuse_tailnet "the tailnet refused the key — it is expired, revoked, or single-use and already spent" ;;
      *"already in use"*|*"Ephemeral"*)
        refuse_tailnet "the tailnet refused the key: $out" ;;
      *) refuse_tailnet "tailscale up failed: $out" ;;
    esac
    return 1
  fi

  # What it CALLS itself, read back — never the name we asked for. A hostname
  # already taken by a node that has not aged out yet silently becomes
  # "<name>-1", and every URL built from the requested name would then point at
  # somebody else's machine.
  # Up to a minute, asked twice a... no: thirty asks, two seconds apart. The
  # two knobs are overridable ONLY so the tests can drive the never-Running
  # path without sleeping for a minute to prove a refusal.
  local dnsname state
  for _ in $(seq 1 "${TESTVM_JOIN_POLLS:-30}"); do
    state="$(guest_status_field "$vm" state | tr -d '[:space:]')"
    dnsname="$(guest_status_field "$vm" name | tr -d '[:space:]')"
    [ "$state" = "Running" ] && [ -n "$dnsname" ] && break
    sleep "${TESTVM_JOIN_POLL_SECONDS:-2}"
  done
  if [ "$state" != "Running" ] || [ -z "$dnsname" ]; then
    refuse_tailnet "the daemon never reached Running with a name (last state: ${state:-unknown})"
    return 1
  fi
  if [ "$dnsname" != "$node.${dnsname#*.}" ]; then
    log "tailnet: NOTE — asked for '$node', the tailnet named this node '${dnsname%%.*}'"
    log "         a node by that name is probably still registered; reap.sh nodes will show it"
  fi

  # HTTPS certificates are a TAILNET-WIDE switch in his admin console, and the
  # app reads exactly this field to decide whether to offer the phone path at
  # all (phone/tailnet.rs: CertDomains -> Ready vs CertificatesOff). Answer it
  # here, where there is a person to tell, instead of letting the app render
  # "not set up yet" with no reason.
  if [ "$(guest_status_field "$vm" certified | tr -d '[:space:]')" != "yes" ]; then
    cat >&2 <<EOF
[testvm] tailnet: joined as $dnsname, but this tailnet will not issue it a certificate.
         The app will show "not set up yet" and no pairing code.
         THE ONE ACTION: https://login.tailscale.com/admin/dns  ->  HTTPS Certificates: Enable
EOF
    echo "tailnet=$dnsname certificates=off"
    return 1
  fi

  # A certificate already issued for THIS NAME, offered back to the daemon
  # before anything asks it to issue a new one.
  #
  # THE ORDER HERE IS THE WHOLE FIX. This used to run before `tailscale up`,
  # keyed on the name we ASKED for — while the cache is keyed, and can only be
  # keyed, on the fully-qualified name the daemon reports afterwards. The two
  # keys never matched, so the cache stored a certificate on every run and read
  # one on none, and the only visible symptom would have been a rate-limit
  # refusal weeks later on somebody else's run. Caught by the test named
  # "the second run offers the cached certificate back to the guest".
  #
  # Between `up` and the first `cert` call is also the only correct window:
  # before it the name is unknown, after it the issuance has already happened.
  if cert_cache_usable "$dnsname"; then
    if cert_cache_push "$vm" "$dnsname"; then
      log "tailnet: re-using the certificate already issued for $dnsname"
    else
      log "tailnet: could not place the cached certificate (harmless — one will be issued)"
    fi
  fi

  # Warm the certificate, AS THE USER THE APP RUNS AS and with the same
  # arguments the app uses, so a refusal shows up here rather than inside a
  # pairing sheet. The output is a private key: it is captured, never printed,
  # and the only thing said about it out loud is whether it parsed.
  local pem
  pem="$(tsg "$vm" "$TESTVM_GUEST_TS cert --cert-file - --key-file - --min-validity $TESTVM_MIN_VALIDITY '$dnsname' 2>/dev/null")"
  if [ -n "$pem" ] && printf '%s' "$pem" | grep -q 'BEGIN CERTIFICATE'; then
    if cert_cache_store "$dnsname" "$pem"; then
      log "tailnet: certificate in hand and cached for the next run"
    else
      log "tailnet: certificate in hand (not cacheable — the next run will ask for a new one)"
    fi
  else
    log "tailnet: WARNING — the daemon would not hand over a certificate; the app will refuse to pair"
  fi
  unset pem

  echo "tailnet=$dnsname"
  return 0
}

# ---------------------------------------------------------------------------
# logout — §54, at the tailnet
# ---------------------------------------------------------------------------
# An EPHEMERAL node removes itself once the control plane stops hearing from
# it, so a guest that dies without this still disappears — eventually, on
# Tailscale's clock. `logout` makes it immediate and, more importantly, makes
# the node's disappearance something we DID rather than something we hope for.
cmd_logout() {
  local vm="${1:-}"
  [ -n "$vm" ] || die "usage: tailnet.sh logout <vm>"
  # Reachability, asked of whatever is actually reaching the guest: when a
  # caller has supplied its own `TESTVM_GUEST_EXEC`, tart's opinion about a VM
  # of that name is not the authority on whether there is a guest to talk to.
  if [ -z "${TESTVM_GUEST_EXEC:-}" ]; then
    vm_running "$vm" 2>/dev/null || return 0
  fi
  local before
  before="$(guest_status_field "$vm" state | tr -d '[:space:]')"
  [ "$before" = "Running" ] || return 0
  log "tailnet: signing $vm out ..."
  tsg "$vm" "sudo $TESTVM_GUEST_TS logout 2>&1" >/dev/null 2>&1
  tsg "$vm" "sudo $TESTVM_GUEST_TS down 2>&1"   >/dev/null 2>&1
  local after
  after="$(guest_status_field "$vm" state | tr -d '[:space:]')"
  case "$after" in
    Running) log "tailnet: WARNING — $vm is STILL signed in after logout"; return 1 ;;
    *) log "tailnet: $vm is signed out (state: ${after:-gone})"; return 0 ;;
  esac
}

cmd_name() {
  local vm="${1:-}"
  [ -n "$vm" ] || die "usage: tailnet.sh name <vm>"
  local n
  n="$(guest_status_field "$vm" name | tr -d '[:space:]')"
  [ -n "$n" ] || { echo "(not on the tailnet)"; return 1; }
  echo "$n"
}

# ---------------------------------------------------------------------------
# nodes — the HOST's view, which is the only one that outlives a dead guest
# ---------------------------------------------------------------------------
cmd_nodes() {
  local cli
  cli="$(host_ts_cli)" || { echo "(no tailscale command line on this Mac)"; return 0; }
  "$cli" status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
rows=[]
for p in (d.get("Peer") or {}).values():
    host=(p.get("HostName") or "").strip()
    if host.lower().startswith("richos-test-"):
        rows.append((host, (p.get("DNSName") or "").strip().rstrip("."), bool(p.get("Online"))))
for host, dns, online in sorted(rows):
    # Double quotes inside: this program is carried in a single-quoted shell
    # string, so an apostrophe here ENDS it — which is how the first version
    # shipped a NameError instead of a node list.
    print(host + "\t" + dns + "\t" + ("online" if online else "offline"))
'
}

# ---------------------------------------------------------------------------
# doctor — every reason the phone path might not be available, in one answer
# ---------------------------------------------------------------------------
cmd_doctor() {
  local vm="${1:-}"
  [ -n "$vm" ] || die "usage: tailnet.sh doctor <vm>"
  local problem
  if problem="$(authkey_problem "$TESTVM_AUTHKEY")"; then
    echo "auth key:      present at $TESTVM_AUTHKEY"
  else
    echo "auth key:      MISSING — $problem"
  fi
  echo "guest cli:     $(tsg "$vm" "ls -l $TESTVM_GUEST_TS 2>&1 | head -1" 2>/dev/null)"
  echo "backend state: $(guest_status_field "$vm" state)"
  echo "node name:     $(guest_status_field "$vm" name)"
  echo "certificates:  $(guest_status_field "$vm" certified)"
  echo "addresses:     $(guest_status_field "$vm" ips)"
  echo "host sees:     $(cmd_nodes | tr '\n' ' ')"
}

case "${1:-}" in
  join)   shift; cmd_join   "$@" ;;
  logout) shift; cmd_logout "$@" ;;
  name)   shift; cmd_name   "$@" ;;
  nodes)  shift; cmd_nodes  "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  *) die "usage: tailnet.sh join|name|logout|nodes|doctor [vm]" ;;
esac
