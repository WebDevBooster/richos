#!/usr/bin/env bash
# provision-guest.sh — RUNS INSIDE THE GUEST, over ssh. Idempotent.
#
# Turns a stock cirruslabs macOS image into a host that can prove things about
# the RichOS app: capture its real screen, read its accessibility tree, OCR the
# result, and stay awake while doing it.
#
# Everything here is a thing that DOES NOT WORK by default over ssh, with the
# reason it does not. Nothing is cargo-culted; each block names its failure.
set -uo pipefail   # NOT -e: a partial provision must report every problem it
                   # found, not die on the first one and hide the rest.

log()  { printf '[provision] %s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
FAILED=()
fail() { FAILED+=("$1"); printf '[provision] FAIL %s\n' "$1"; }

WANT_RES="${TART_DISPLAY_SIZE:-1680x1050}"
SUDO="sudo"

# ---------------------------------------------------------------------------
# 1. PATH for NON-INTERACTIVE ssh.
#    `ssh host 'cmd'` sources ONLY ~/.zshenv — not ~/.zprofile, not ~/.zshrc.
#    Without this every brew-installed tool (tesseract, displayplacer) is
#    "command not found" the moment the harness drives the guest remotely,
#    while working perfectly in an interactive test session. That asymmetry is
#    exactly the kind of thing that wastes an afternoon.
# ---------------------------------------------------------------------------
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  grep -q 'brew shellenv' "$HOME/.zshenv" 2>/dev/null \
    || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zshenv"
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null \
    || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
else
  fail "Homebrew missing in guest (expected on a cirruslabs base image)"
fi

# ---------------------------------------------------------------------------
# 2. NEVER LET THE SCREEN GO DARK.
#    A sleeping display or an engaged screensaver captures as a BLACK FRAME,
#    and a black frame is indistinguishable from a missing TCC grant. Both
#    failures look identical in a screenshot, so remove one of them for good.
#    Also: a locked screen would swallow every synthetic keystroke.
# ---------------------------------------------------------------------------
log "disabling sleep, screensaver and screen lock..."
$SUDO pmset -a displaysleep 0 sleep 0 disksleep 0 powernap 0 >/dev/null 2>&1 \
  || fail "pmset could not disable sleep"
defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null || true
$SUDO defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0 2>/dev/null || true
defaults write com.apple.screensaver askForPassword -int 0 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. TCC — THE GRANT THAT MAKES SCREENSHOTS REAL.
#    Without it `screencapture` over ssh returns a black frame, silently. The
#    consent dialog that would normally fix this CANNOT appear: there is no
#    interactive GUI session to show it in, and no one is there to click it.
#
#    Writing TCC.db directly is only possible because the cirruslabs base image
#    ships with SIP DISABLED (their disable-sip packer template). On a stock
#    Mac SIP protects these files from root itself. This is the single reason
#    this whole harness is feasible, and the reason it must stay a VM-only
#    trick — never do this on the host.
#
#    Two client shapes are granted because Apple changed how the ssh session
#    process identifies itself across releases: modern macOS reports the bundle
#    id `com.apple.sshd-session` (client_type 0), older ones the executable
#    path `/usr/libexec/sshd-keygen-wrapper` (client_type 1). Granting both is
#    cheap; guessing wrong costs a black frame with no error.
#
#    Columns are named rather than positional: the `access` table has gained
#    columns in several macOS releases (pid, pid_version, boot_uuid,
#    last_reminded), so a positional INSERT that works on one version silently
#    breaks on the next.
# ---------------------------------------------------------------------------
TCC_USER="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TCC_SYS="/Library/Application Support/com.apple.TCC/TCC.db"

grant() {  # grant <db> <sudo|nosudo> <service> <client> <client_type> <indirect>
  local db="$1" mode="$2" service="$3" client="$4" ctype="$5" indirect="${6:-UNUSED}"
  local itype=0
  [ "$indirect" = "UNUSED" ] || itype=0
  local sql="INSERT OR REPLACE INTO access
      (service, client, client_type, auth_value, auth_reason, auth_version,
       indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
    VALUES ('$service', '$client', $ctype, 2, 2, 1, $itype, '$indirect', 0, strftime('%s','now'));"
  if [ "$mode" = "sudo" ]; then
    $SUDO sqlite3 "$db" "$sql" 2>/dev/null
  else
    sqlite3 "$db" "$sql" 2>/dev/null
  fi
}

log "granting TCC: ScreenCapture, Accessibility, AppleEvents..."
for svc in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent; do
  grant "$TCC_SYS"  sudo   "$svc" com.apple.sshd-session               0 || true
  grant "$TCC_SYS"  sudo   "$svc" /usr/libexec/sshd-keygen-wrapper     1 || true
  grant "$TCC_USER" nosudo "$svc" com.apple.sshd-session               0 || true
  grant "$TCC_USER" nosudo "$svc" /usr/libexec/sshd-keygen-wrapper     1 || true
done

# System Events is the process that actually posts keystrokes and reads the
# accessibility tree on our behalf, so it needs Accessibility in its own right.
grant "$TCC_SYS" sudo kTCCServiceAccessibility com.apple.systemevents 0 || true

# AppleEvents: permission for the ssh session to DRIVE System Events at all.
# The indirect object is the target being driven — this one is a real pairing,
# not a placeholder, which is why it is passed explicitly.
grant "$TCC_USER" nosudo kTCCServiceAppleEvents /usr/libexec/sshd-keygen-wrapper 1 com.apple.systemevents || true
grant "$TCC_USER" nosudo kTCCServiceAppleEvents com.apple.sshd-session           0 com.apple.systemevents || true
grant "$TCC_SYS"  sudo   kTCCServiceAppleEvents /usr/libexec/sshd-keygen-wrapper 1 com.apple.systemevents || true

GRANTED=$(sqlite3 "$TCC_USER" "SELECT count(*) FROM access WHERE service LIKE 'kTCCService%';" 2>/dev/null || echo 0)
SYSGRANTED=$($SUDO sqlite3 "$TCC_SYS" "SELECT count(*) FROM access WHERE service LIKE 'kTCCService%';" 2>/dev/null || echo 0)
log "TCC rows: user=$GRANTED system=$SYSGRANTED"
[ "${SYSGRANTED:-0}" -gt 0 ] || fail "system TCC.db has no grants — is SIP really off in this image? (csrutil status: $(csrutil status 2>&1 | tr -d '\n'))"

# ---------------------------------------------------------------------------
# 4. Tooling. tesseract is the OCR gate; displayplacer pins the resolution.
#    Installed from Homebrew, which the base image ships preconfigured.
# ---------------------------------------------------------------------------
log "installing tesseract + displayplacer..."
brew install tesseract displayplacer >/tmp/brew-tools.log 2>&1 \
  || log "brew install returned nonzero (may be already installed) — verifying below"
command -v tesseract    >/dev/null 2>&1 || fail "tesseract missing after install"
command -v displayplacer >/dev/null 2>&1 || fail "displayplacer missing after install"

# ---------------------------------------------------------------------------
# 5. Pin the logical resolution.
#    tart sizes the VIRTUAL display, but the guest's GUI can still come up at a
#    scaled mode, which changes screenshot dimensions and every click
#    coordinate between runs. Pinning makes a screenshot comparable to the one
#    taken yesterday — which is the whole basis of a visual proof.
# ---------------------------------------------------------------------------
if command -v displayplacer >/dev/null 2>&1; then
  SCREEN_ID="$(displayplacer list 2>/dev/null | awk '/^Persistent screen id:/ {print $4; exit}')"
  CUR="$(displayplacer list 2>/dev/null | awk '/^Resolution:/ {print $2; exit}')"
  if [ -n "${SCREEN_ID:-}" ] && [ "${CUR:-}" != "$WANT_RES" ]; then
    displayplacer "id:$SCREEN_ID res:$WANT_RES hz:60 color_depth:7 scaling:on" >/dev/null 2>&1 \
      || displayplacer "id:$SCREEN_ID res:$WANT_RES scaling:on" >/dev/null 2>&1 \
      || displayplacer "id:$SCREEN_ID res:$WANT_RES" >/dev/null 2>&1 \
      || log "WARN: could not pin display to $WANT_RES (still ${CUR:-unknown})"
  fi
  log "display: $(displayplacer list 2>/dev/null | awk '/^Resolution:/ {print $2; exit}')"
fi

# ---------------------------------------------------------------------------
# 6. Tailscale, left SIGNED OUT on purpose.
#    The guest should be reachable as its own tailnet node so the phone can
#    open the app's paired page. Signing in needs the CEO's account, and no
#    agent may hold or borrow those credentials — so provisioning stops one
#    step short and the handoff names the single URL he opens, once.
# ---------------------------------------------------------------------------
log "installing tailscale (left signed out)..."
brew install tailscale >/tmp/brew-tailscale.log 2>&1 || log "tailscale install returned nonzero"
if command -v tailscale >/dev/null 2>&1; then
  $SUDO brew services start tailscale >/dev/null 2>&1 || log "could not start tailscaled service"
else
  fail "tailscale missing after install"
fi

# ---------------------------------------------------------------------------
# 7. Quarantine. A bundle copied in from the host carries com.apple.quarantine,
#    and the FIRST launch then raises a Gatekeeper "are you sure?" dialog that
#    blocks the app until something clicks it. Nothing can click it here.
#    (run.sh strips it per-copy too; this covers anything staged by hand.)
# ---------------------------------------------------------------------------
for app in "$HOME"/testvm/*/RichOS.app; do
  [ -e "$app" ] && xattr -dr com.apple.quarantine "$app" 2>/dev/null
done
true

mkdir -p "$HOME/testvm"
if [ ${#FAILED[@]} -eq 0 ]; then
  date -u +%FT%TZ > "$HOME/.richos-testvm-provisioned"
  log "PROVISIONED OK"
  exit 0
fi
log "provisioning finished with ${#FAILED[@]} problem(s):"
for f in "${FAILED[@]}"; do log "  - $f"; done
exit 1
