#!/usr/bin/env bash
# run.sh — put the RichOS app on a screen that is NOT the CEO's, and tell the
#          caller how to drive it.
#
#   testvm/run.sh --bundle <RichOS.app.zip|RichOS.app> --home <fixture-home-dir>
#                 [--vm <name>] [--keep] [--engine <engine.tar.gz>] [--no-tailnet]
#
# Prints, on success:
#   vm=<name> ip=<guest ip> pid=<app pid IN THE GUEST> ssh=<user@ip> elapsed=<s>
#   tailnet=<dnsname|not-joined>
#
# Each --vm name is an INDEPENDENT guest cloned from the provisioned base, so
# two agents can each run.sh with different names and get a window each, at the
# same time, neither touching the host's screen. That parallelism is the point:
# on-screen proofs used to be a queue of one behind the CEO's working day.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

BUNDLE=""; FIXTURE_HOME=""; VM="richos-test-1"; ENGINE=""; KEEP=0; TAILNET=1
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --home)   FIXTURE_HOME="$2"; shift 2 ;;
    --vm)     VM="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    # The tailnet join is ON by default because the phone path is the reason
    # this VM exists at all (CEO §61: there is one path, and it is Tailscale).
    # It is also the only step that can refuse without failing the run, so
    # --no-tailnet is for a proof that has nothing to do with the phone and
    # would rather not spend twenty seconds and a node on one.
    --no-tailnet) TAILNET=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$BUNDLE" ] || die "--bundle is required"
[ -n "$FIXTURE_HOME" ] || die "--home is required"
[ -e "$BUNDLE" ] || die "no such bundle: $BUNDLE"
[ -d "$FIXTURE_HOME" ] || die "no such fixture home: $FIXTURE_HOME"
[ "$VM" != "$TESTVM_BASE_VM" ] || die "refusing to run in the base VM — it is the template every clone comes from"

START=$(date +%s)
preflight_tart
vm_exists "$TESTVM_BASE_VM" || die "base VM missing — run testvm/setup.sh first"

STATE="$TESTVM_RUN/$VM"
mkdir -p "$STATE"

# --- 1. an ephemeral clone ----------------------------------------------------
# Cloning is copy-on-write on APFS: a new guest costs seconds and almost no
# disk until it diverges. This is what makes a per-run disposable VM practical
# rather than a 25 GB copy each time.
if ! vm_exists "$VM"; then
  log "cloning $TESTVM_BASE_VM -> $VM (copy-on-write)"
  # The base must be stopped to clone a consistent disk.
  if vm_running "$TESTVM_BASE_VM"; then
    log "stopping the base VM so the clone is consistent..."
    tart stop "$TESTVM_BASE_VM" 2>/dev/null || true
    sleep 3
  fi
  tart clone "$TESTVM_BASE_VM" "$VM"
  echo ephemeral > "$STATE/ephemeral"
fi
tart set "$VM" --cpu "$TESTVM_CPU" --memory "$TESTVM_RAM_MB" --display "$TESTVM_DISPLAY"

# --- 2. boot headless ---------------------------------------------------------
if ! vm_running "$VM"; then
  log "booting $VM headless..."
  # --no-graphics: the guest keeps a full virtual display and WindowServer;
  # the host simply never renders a window for it. This one flag is the
  # difference between a proof and an interruption.
  #
  # `caffeinate -is`, and NOT -dimsu: -i holds off idle SYSTEM sleep, which is
  # the only thing that would pause a running VM, and -s does the same while on
  # AC power. -d (keep the DISPLAY awake) and -u (declare the user active) are
  # deliberately omitted: they would hold the CEO's screen lit and unlocked for
  # as long as a test ran, which is the very intrusion this harness removes.
  # A locked or slept host screen does not affect the guest at all — the guest
  # runs its own WindowServer inside the VM.
  nohup caffeinate -is "$TART_BIN" run "$VM" --no-graphics > "$TESTVM_LOG/$VM.log" 2>&1 &
  echo $! > "$STATE/vm.pid"
fi

log "waiting for $VM to report an IP..."
IP="$(vm_ip "$VM")" || die "$VM never reported an IP — see $TESTVM_LOG/$VM.log"
echo "$IP" > "$STATE/ip"
log "$VM is up at $IP"

for i in $(seq 1 30); do
  if guest_ssh "$VM" true 2>/dev/null; then break; fi
  [ "$i" -eq 30 ] && die "ssh into $VM never came up"
  sleep 2
done

# --- 2b. the tailnet ----------------------------------------------------------
# BEFORE the app launches, not after: the app asks Tailscale where it is on
# startup and caches the answer (phone/mod.rs `tailnet_now`), so a guest that
# joins afterwards shows the user "this Mac is not set up yet" until the cache
# ages out. Joining first means the first screen he reads is the true one.
#
# A refusal here is NOT fatal — see tailnet.sh's `refuse_tailnet`. Without the
# CEO's key there is no phone path, and everything else about this VM still
# works, so the run continues and says so in its summary.
TAILNET_NAME="not-joined"
if [ "$TAILNET" -eq 1 ]; then
  JOIN_OUT="$("$HERE/tailnet.sh" join "$VM" 2>&1)" && true
  printf '%s\n' "$JOIN_OUT" >&2
  case "$JOIN_OUT" in
    *tailnet=*) TAILNET_NAME="$(printf '%s\n' "$JOIN_OUT" | tailnet_name_from_join_output)" ;;
  esac
  [ -n "$TAILNET_NAME" ] || TAILNET_NAME="not-joined"
fi

# --- 3. stage the payload -----------------------------------------------------
PAYLOAD="/Users/$TESTVM_GUEST_USER/testvm/$VM"
guest_ssh "$VM" "rm -rf '$PAYLOAD' && mkdir -p '$PAYLOAD'"

log "copying the bundle in..."
if [ "${BUNDLE##*.}" = "zip" ]; then
  scp "${TESTVM_SSH_OPTS[@]}" -O -i "$TESTVM_SSH_KEY" "$BUNDLE" \
    "$TESTVM_GUEST_USER@$IP:$PAYLOAD/bundle.zip" >/dev/null
  guest_ssh "$VM" "cd '$PAYLOAD' && ditto -x -k bundle.zip . && rm -f bundle.zip"
else
  scp "${TESTVM_SSH_OPTS[@]}" -O -r -i "$TESTVM_SSH_KEY" "$BUNDLE" \
    "$TESTVM_GUEST_USER@$IP:$PAYLOAD/" >/dev/null
fi
APP="$(guest_ssh "$VM" "ls -d '$PAYLOAD'/*.app 2>/dev/null | head -1")"
[ -n "$APP" ] || die "no .app found in the copied bundle"

# Strip quarantine BEFORE the first launch. A bundle that arrived over scp is
# flagged "downloaded from the internet", and the first launch would raise a
# Gatekeeper dialog that nothing in a headless guest can click — the app would
# simply never appear, with no error anywhere.
guest_ssh "$VM" "xattr -dr com.apple.quarantine '$APP' 2>/dev/null || true"

log "copying the fixture home in..."
# tar over ssh, not scp -r: the fixture home contains symlinks and a Library
# tree whose structure matters, and scp -r silently follows and flattens
# symlinks. Preserving them is the difference between testing the app and
# testing a copy of somebody's home directory.
tar -C "$FIXTURE_HOME" -cf - . \
  | guest_ssh "$VM" "mkdir -p '$PAYLOAD/home' && tar -C '$PAYLOAD/home' -xf -"

if [ -n "$ENGINE" ] && [ -e "$ENGINE" ]; then
  log "copying the engine payload in..."
  scp "${TESTVM_SSH_OPTS[@]}" -O -i "$TESTVM_SSH_KEY" "$ENGINE" \
    "$TESTVM_GUEST_USER@$IP:$PAYLOAD/engine.tar.gz" >/dev/null
  guest_ssh "$VM" "mkdir -p '$PAYLOAD/engine' && tar -C '$PAYLOAD/engine' -xzf '$PAYLOAD/engine.tar.gz'"
fi

# --- 4. launch --------------------------------------------------------------
# RICHOS_ACTIVATION=regular asks for the front: Dock icon, key window, focus.
# On the host that is an intrusion and needs a CEO ruling (§45). In here it is
# free — the only screen it can take is the guest's.
GUEST_HOME="$PAYLOAD/home"
LOGFILE="$PAYLOAD/app.log"

# `open -a` rather than executing the binary: a GUI app started directly from
# an ssh shell has no Aqua session and either dies or draws nothing. `open`
# routes the launch through launchd into the auto-logged-in user's GUI session,
# which is where a window can actually exist. --env carries the environment the
# host QA recipe uses, so the app under test is configured identically.
log "launching the app in the guest's GUI session..."
guest_ssh "$VM" "rm -f '$LOGFILE'; \
  open -n -a '$APP' \
    --env HOME='$GUEST_HOME' \
    --env RICHOS_ACTIVATION=regular \
    --env CLAUDE_CONFIG_DIR='$GUEST_HOME/.claude' \
    --env RICHOS_CLAUDE_BIN=/Users/$TESTVM_GUEST_USER/.local/bin/claude \
    ${ENGINE:+--env RICHOS_ENGINE_DIR='$PAYLOAD/engine'} \
    --stdout '$LOGFILE' --stderr '$LOGFILE'"

# Wait for the process, then for a WINDOW. A pid is not a proof: the app can be
# running and drawing nothing, which is precisely the state a screenshot would
# photograph and call a pass.
PID=""
for i in $(seq 1 30); do
  PID="$(guest_ssh "$VM" "pgrep -n -f 'richos-tauri' 2>/dev/null || true" | tr -d '[:space:]')"
  [ -n "$PID" ] && break
  sleep 1
done
[ -n "$PID" ] || die "the app never started in the guest — log: ssh $TESTVM_GUEST_USER@$IP cat '$LOGFILE'"
echo "$PID" > "$STATE/app.pid"
echo "$PAYLOAD" > "$STATE/payload"

WINDOWS=0
for i in $(seq 1 45); do
  WINDOWS="$(guest_ssh "$VM" "osascript -e 'tell application \"System Events\" to count windows of (first process whose unix id is $PID)' 2>/dev/null || echo 0" | tr -d '[:space:]')"
  [ "${WINDOWS:-0}" -gt 0 ] 2>/dev/null && break
  sleep 1
done

ELAPSED=$(( $(date +%s) - START ))
if [ "${WINDOWS:-0}" -lt 1 ] 2>/dev/null; then
  log "WARNING: the app is running (pid $PID) but reports 0 windows after 45s."
  log "         Check the log:  ssh $TESTVM_GUEST_USER@$IP cat '$LOGFILE'"
fi

log "ready in ${ELAPSED}s"
echo "vm=$VM ip=$IP pid=$PID ssh=$TESTVM_GUEST_USER@$IP windows=${WINDOWS:-0} elapsed=${ELAPSED}s"
echo "tailnet=$TAILNET_NAME"
if [ "$TAILNET_NAME" != "not-joined" ]; then
  echo "phone: https://$TAILNET_NAME:8443/  (from this Mac: curl -sk https://$TAILNET_NAME:8443/)"
fi
echo "shot:  $HERE/shot.sh $VM <out.png> [--ocr]"
echo "ax:    $HERE/ax.sh $VM '<applescript>'"
echo "stop:  $HERE/stop.sh $VM      # ALWAYS, before you report (CEO §54)"
