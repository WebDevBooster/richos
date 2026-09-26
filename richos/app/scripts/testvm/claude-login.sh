#!/usr/bin/env bash
# claude-login.sh — the guest is signed in to `claude` as the host is, at every
#                   run, and the value never appears anywhere but a pipe.
#
#   testvm/claude-login.sh host-check                 is THIS Mac signed in?
#   testvm/claude-login.sh push  <vm> <guest-home>    copy the login in, verify
#   testvm/claude-login.sh check <vm> <guest-home>    verify only, copy nothing
#
# Prints ONE line on stdout:
#
#   claude login: guest logged in
#   claude login: guest NOT logged in
#
# ===========================================================================
# THE QUESTION THIS EXISTS FOR
# ===========================================================================
# The CEO, 2026-09-20: *"What happens when the Claude login expires in the
# VM?"*
#
# The honest old answer was "it never had one". `docs/testvm.md` said signing
# in was a human action — `ssh admin@<ip> 'claude /login'`, once per guest, on
# a guest that is DELETED at the end of every run. That is a human errand per
# proof, which is the same shape as the Tailscale URL sign-in this harness
# already replaced with a key.
#
# The new answer is that the guest never holds a login longer than one run: it
# is projected from the host at the start of every run and destroyed with the
# clone. ONLY the access token and its metadata cross this boundary. A copied
# refresh token lets the guest rotate the host login without sharing its lock
# or writing the replacement back. A fresh clone does not prevent that race.
# The access snapshot can expire during a run; it cannot renew the host login.
#
# ===========================================================================
# WHY THE VALUE IS NEVER ON A COMMAND LINE — AND HOW CLAUDE CODE ITSELF DOES IT
# ===========================================================================
# A secret in argv is in the process table of the machine that runs it and in
# every log that records a command line. This harness already refuses that for
# the Tailscale key (`--auth-key file:<path>`, never inline), and the same rule
# binds here.
#
# `security` has a mode for it, and Claude Code uses that mode itself. Read out
# of the 2.1.277 binary:
#
#   i = `add-generic-password -U -a "${account}" -s "${service}" -X "${hex}"\n`
#   if (i.length <= 4032) security -i   <- the command arrives on STDIN
#   else … argv …                          (their fallback; NOT taken here)
#
# So this file does the same: the payload is hex-encoded and handed to
# `security -i` on stdin, in the guest, over ssh. Measured here on 2026-09-20:
# the host's credential is 524 bytes, so the line is ~1.1 kB — comfortably
# inside the 4032 the same code treats as the limit. If it ever exceeds that,
# this REFUSES rather than taking the argv fallback.
#
# ===========================================================================
# THE NAME THE GUEST WILL LOOK UP, AND WHY TWO ARE WRITTEN
# ===========================================================================
# From the same binary, the service name is built as:
#
#   `Claude Code` + OAUTH_FILE_SUFFIX + "-credentials" + scope
#   scope = ""  when CLAUDE_CONFIG_DIR is unset
#         = "-" + sha256(configDir).hex.slice(0,8)   when it is set
#
# and the account is `process.env.USER || os.userInfo().username`.
#
# OAUTH_FILE_SUFFIX is "" in the shipped build (the non-empty variants are the
# `-local-oauth` / `-custom-oauth` development configurations). `run.sh`
# launches the app WITH `CLAUDE_CONFIG_DIR=<fixture home>/.claude`, so the name
# the app resolves is the scoped one — and a `claude` a tester starts by hand
# over ssh, with no such variable, resolves the bare one.
#
# Both are written, with the same value, into the same disposable keychain.
# Writing two rows of a throwaway keychain costs nothing; predicting which one
# the process under test will ask for, and being wrong, costs a whole walk.
#
# The ACCOUNT is the GUEST's user, never the host's: the app runs as `admin` in
# there, so an item filed under `alex` would never be found.
# ===========================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e

# The service and account on THIS Mac, where the CEO signed in once.
TESTVM_CLAUDE_KC_SERVICE="${TESTVM_CLAUDE_KC_SERVICE:-Claude Code-credentials}"
TESTVM_HOST_CLAUDE_ACCOUNT="${TESTVM_HOST_CLAUDE_ACCOUNT:-${USER:-alex}}"
# Same default, same override name as keychain.sh — a throwaway phrase for a
# throwaway keychain in a guest that is deleted at the end of the run.
TESTVM_KEYCHAIN_PHRASE="${TESTVM_KEYCHAIN_PHRASE:-testvm-throwaway}"
# Every `security` call is bounded. Against a locked or missing keychain the
# real one raises a dialog and waits for a click — on the HOST that would be a
# window on the CEO's screen, which is the one thing this harness never does.
TESTVM_CLAUDE_LOGIN_SECONDS="${TESTVM_CLAUDE_LOGIN_SECONDS:-15}"
# `security -i`'s own stdin limit, as Claude Code's code treats it.
TESTVM_SECURITY_STDIN_MAX="${TESTVM_SECURITY_STDIN_MAX:-4032}"

VM=""; GUEST_HOME=""
CMD="${1:-}"; shift 2>/dev/null

cg() {  # one command in the guest, the harness's single indirection
  if [ -n "${TESTVM_GUEST_EXEC:-}" ]; then
    "$TESTVM_GUEST_EXEC" "$VM" "$@"
  else
    guest_ssh "$VM" "$@"
  fi
}

# The same, with something on stdin. `guest_ssh` already passes stdin through,
# so this exists to name what is happening at the call site: THE SECRET GOES
# HERE, and nowhere else.
cg_stdin() { cg "$@"; }

guest_service_scoped() {  # the name the app resolves, given its config dir
  local dir="$1" h
  h="$(printf '%s' "$dir" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,8)}')"
  [ -n "$h" ] || return 1
  printf '%s-%s\n' "$TESTVM_CLAUDE_KC_SERVICE" "$h"
}

# The host's `security`, behind ONE override — the same seam `host_ts_cli` has,
# and for the same reason: so the tests can drive every decision in this file
# without reading, or risking, the CEO's real keychain.
TESTVM_HOST_SECURITY="${TESTVM_HOST_SECURITY:-/usr/bin/security}"

# Is THIS Mac signed in? Attributes only — `-w` is deliberately absent, so this
# question can be asked without the answer ever being in a variable.
host_logged_in() {
  perl -e 'alarm shift; exec @ARGV' "$TESTVM_CLAUDE_LOGIN_SECONDS" \
    "$TESTVM_HOST_SECURITY" find-generic-password \
      -s "$TESTVM_CLAUDE_KC_SERVICE" -a "$TESTVM_HOST_CLAUDE_ACCOUNT" \
    >/dev/null 2>&1
}

guest_logged_in() {  # <service>
  local out
  out="$(cg "env HOME='$GUEST_HOME' perl -e 'alarm shift; exec @ARGV' $TESTVM_CLAUDE_LOGIN_SECONDS \
             security find-generic-password -a '$TESTVM_GUEST_USER' -s '$1' \
               '$GUEST_HOME/Library/Keychains/login.keychain-db' 2>&1")"
  case "$out" in
    *"\"svce\""*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$CMD" in
  host-check)
    if host_logged_in; then
      log "host claude is logged in (keychain item '$TESTVM_CLAUDE_KC_SERVICE', account $TESTVM_HOST_CLAUDE_ACCOUNT)"
      exit 0
    fi
    printf '[testvm] host claude is not logged in — /login on the host first\n' >&2
    exit 1
    ;;
  push|check) ;;
  *) die "usage: claude-login.sh host-check | push <vm> <guest-home> | check <vm> <guest-home>" ;;
esac

VM="${1:-}"; GUEST_HOME="${2:-}"
[ -n "$VM" ] || die "usage: claude-login.sh $CMD <vm> <guest-home>"
[ -n "$GUEST_HOME" ] || die "usage: claude-login.sh $CMD <vm> <guest-home>"
# A guest path, always — the same refusal keychain.sh makes, for the same
# reason: nothing in this harness may address the CEO's own home.
case "$GUEST_HOME" in
  "/Users/$TESTVM_GUEST_USER/"*) ;;
  *) die "refusing: '$GUEST_HOME' is not under the guest user's home (/Users/$TESTVM_GUEST_USER/)" ;;
esac

SVC_SCOPED="$(guest_service_scoped "$GUEST_HOME/.claude")"
[ -n "$SVC_SCOPED" ] || die "could not derive the scoped keychain service name"

report() {  # report <logged in|NOT logged in>
  printf 'claude login: guest %s\n' "$1"
}

# The credential file's size in the guest, and nothing about its contents. A
# size is a fact that can be compared with the host's without the value ever
# being read back out of the guest — and it is precisely the check that catches
# Ray's failure mode, where a store reports success and holds nothing.
guest_credential_bytes() {
  cg "wc -c < '$GUEST_HOME/.claude/.credentials.json' 2>/dev/null || echo 0" 2>/dev/null \
    | tr -d '[:space:]'
}

if [ "$CMD" = "check" ]; then
  FB="$(guest_credential_bytes)"
  if [ "${FB:-0}" -gt 1 ] 2>/dev/null; then
    report "logged in"; exit 0
  fi
  if guest_logged_in "$SVC_SCOPED" || guest_logged_in "$TESTVM_CLAUDE_KC_SERVICE"; then
    report "logged in"; exit 0
  fi
  report "NOT logged in"; exit 1
fi

# --- push ---------------------------------------------------------------------
if ! host_logged_in; then
  report "NOT logged in"
  printf '[testvm] host claude is not logged in — /login on the host first\n' >&2
  exit 2
fi

# THE ONLY PLACE THE VALUE EXISTS: read from the host keychain straight into
# this process's memory, written to no file on this Mac, printed nowhere, and
# handed to the guest on stdin below. `-w` prints the value, so this pipeline is
# the one place in the harness that must never gain a `tee`, a log, or a debug
# echo.
SECRET="$(perl -e 'alarm shift; exec @ARGV' "$TESTVM_CLAUDE_LOGIN_SECONDS" \
        "$TESTVM_HOST_SECURITY" find-generic-password \
          -s "$TESTVM_CLAUDE_KC_SERVICE" -a "$TESTVM_HOST_CLAUDE_ACCOUNT" -w 2>/dev/null \
       | perl -0777 -pe 's/\n\z//')"
if [ -z "$SECRET" ]; then
  report "NOT logged in"
  printf '[testvm] the host credential could not be read (locked keychain, or a dialog was waiting)\n' >&2
  exit 3
fi
# Drop refresh capability BEFORE either guest store is written. Use an explicit
# field allowlist so future host credentials cannot accidentally cross as well.
# Invalid/expired snapshots refuse provisioning; no token or parser input is logged.
SECRET="$(printf '%s' "$SECRET" | python3 -c '
import json, math, sys, time
try:
    data = json.load(sys.stdin)["claudeAiOauth"]
    token = data["accessToken"]
    expiry = data["expiresAt"]
    if not isinstance(token, str) or not token:
        raise ValueError()
    if isinstance(expiry, bool) or not isinstance(expiry, (int, float)):
        raise ValueError()
    if not math.isfinite(expiry) or expiry <= time.time() * 1000:
        raise ValueError()
    fields = ("accessToken", "expiresAt", "scopes", "subscriptionType", "rateLimitTier")
    snapshot = {k: data[k] for k in fields if k in data}
    sys.stdout.write(json.dumps({"claudeAiOauth": snapshot}, separators=(",", ":")))
except (KeyError, TypeError, ValueError, OverflowError):
    sys.exit(1)
' 2>/dev/null)" || {
  SECRET=""
  report "NOT logged in"
  printf '[testvm] REFUSED: no unexpired Claude access credential; refresh the host login before retrying. No host refresh token was sent to the guest.\n' >&2
  exit 3
}
SECRET_BYTES="${#SECRET}"
HEX="$(printf '%s' "$SECRET" | xxd -p | tr -d '\n')"

# --- THE FILE STORE, which is the route that is known to work in a guest ------
# Ray's vm9 audit, 2026-09-20: `security add-generic-password -w` reading from a
# pipe with no tty stores an EMPTY password AND EXITS 0 — a sign-in that reports
# success and is not one. That is the route this file never took (it uses
# `security -i` with `-X <hex>`, which round-trips a real value; proved on this
# host against a throwaway keychain), but his finding names the right primary:
# `claude` keeps a FILE store as well, and a file has no tty, no securityd and no
# session to be on the wrong side of.
#
# Where: `.credentials.json` inside the config dir — CLAUDE_CONFIG_DIR when set,
# `~/.claude` otherwise. `run.sh` sets it to the fixture home's `.claude`, and a
# `claude` started by hand over ssh uses the guest user's own. Both are written,
# for the same reason both keychain service names are.
#
# The value goes in on STDIN once and is copied inside the guest, so it is never
# an argument and never crosses the wire twice. `umask 077` before the write,
# because the file IS the credential.
log "writing the access snapshot into the guest's credential file (no refresh token; may expire during the run)"
FILE_BYTES="$(printf '%s' "$SECRET" | cg_stdin "umask 077; \
  mkdir -p '$GUEST_HOME/.claude' ~/.claude && \
  cat > '$GUEST_HOME/.claude/.credentials.json' && \
  cp '$GUEST_HOME/.claude/.credentials.json' ~/.claude/.credentials.json && \
  chmod 600 '$GUEST_HOME/.claude/.credentials.json' ~/.claude/.credentials.json && \
  wc -c < '$GUEST_HOME/.claude/.credentials.json'" 2>/dev/null | tr -d '[:space:]')"

PAYLOAD="$(printf 'add-generic-password -U -a "%s" -s "%s" -X "%s" "%s"\nadd-generic-password -U -a "%s" -s "%s" -X "%s" "%s"\n' \
  "$TESTVM_GUEST_USER" "$SVC_SCOPED"               "$HEX" "$GUEST_HOME/Library/Keychains/login.keychain-db" \
  "$TESTVM_GUEST_USER" "$TESTVM_CLAUDE_KC_SERVICE" "$HEX" "$GUEST_HOME/Library/Keychains/login.keychain-db")"

# Each line is one `security -i` command; the limit is per line, as the code
# quoted in the header treats it.
LONGEST=0
while IFS= read -r line; do
  [ "${#line}" -gt "$LONGEST" ] && LONGEST="${#line}"
done <<EOF
$PAYLOAD
EOF
if [ "$LONGEST" -gt "$TESTVM_SECURITY_STDIN_MAX" ]; then
  HEX=""
  report "NOT logged in"
  printf '[testvm] REFUSED: the credential is %s characters of hex, past security -i'"'"'s %s-character stdin limit.\n' \
    "$LONGEST" "$TESTVM_SECURITY_STDIN_MAX" >&2
  printf '         The argv fallback Claude Code takes here is not taken here: a secret on a\n' >&2
  printf '         command line is in the guest process table and in every log of it.\n' >&2
  exit 4
fi

log "copying a Claude access snapshot into $VM (no refresh token; stdin only)"
# The unlock is repeated here rather than trusted. `keychain.sh prepare` unlocked
# this keychain, but in ITS ssh session; lock state is securityd's and an
# already-unlocked keychain makes this a no-op that costs nothing. The
# alternative is a write that fails for a reason the read-back below can only
# call "not logged in".
printf '%s\n' "$PAYLOAD" | cg_stdin "env HOME='$GUEST_HOME' perl -e 'alarm shift; exec @ARGV' \
  $TESTVM_CLAUDE_LOGIN_SECONDS sh -c \"security unlock-keychain -p '$TESTVM_KEYCHAIN_PHRASE' \
  '$GUEST_HOME/Library/Keychains/login.keychain-db' >/dev/null 2>&1; security -i\"" >/dev/null 2>&1
PUSH_RC=$?
# Gone from this process the moment it is no longer needed.
HEX=""; PAYLOAD=""; SECRET=""

# Read BACK, because "the write returned 0" and "the store holds what the app
# will ask for" are two different claims — the whole lesson of this harness's
# freshness rules, and exactly the gap Ray found in the `-w` route, which
# reports success while storing nothing.
#
# The file's SIZE is compared with the host credential's, so a store that took
# the write and kept an empty value fails here instead of at the first model
# turn. The contents are never read back out of the guest.
FILE_OK=0
if [ "${FILE_BYTES:-0}" = "$SECRET_BYTES" ]; then
  FILE_OK=1
else
  GB="$(guest_credential_bytes)"
  [ "${GB:-0}" = "$SECRET_BYTES" ] && FILE_OK=1
fi
KC_OK=0
guest_logged_in "$SVC_SCOPED" && KC_OK=1

if [ "$FILE_OK" -eq 1 ] || [ "$KC_OK" -eq 1 ]; then
  log "login stored: credential file $([ "$FILE_OK" -eq 1 ] && echo "yes ($SECRET_BYTES bytes, matching the access snapshot)" || echo no), keychain item $([ "$KC_OK" -eq 1 ] && echo yes || echo no)"
  report "logged in"
  exit 0
fi

report "NOT logged in"
cat >&2 <<EOF
[testvm] WARNING: $VM is NOT signed in to claude (write rc=$PUSH_RC).
         Neither store took it: the credential file is ${FILE_BYTES:-0} bytes where
         the access snapshot is $SECRET_BYTES, and no keychain item came back.
         Everything that needs no model turn still renders and still
         screenshots. A model turn in the guest will answer
         "Not logged in - Please run /login".
         Most likely cause: this run's login keychain is locked or absent —
         ask it:  $HERE/keychain.sh check $VM $GUEST_HOME
EOF
exit 1
