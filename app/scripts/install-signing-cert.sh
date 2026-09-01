#!/usr/bin/env bash
# Turn the .cer Apple hands back into a usable code-signing IDENTITY on this Mac,
# and prove it is usable before saying so.
#
#   app/scripts/install-signing-cert.sh ~/Downloads/developerID_application.cer
#   app/scripts/install-signing-cert.sh --check       # what does this machine have?
#
# WHY A SECOND SCRIPT
# -------------------
# The .cer Apple emails you is a CERTIFICATE — the public half. `codesign` cannot
# use it. What it needs is an IDENTITY: that certificate paired, inside a keychain,
# with the private key the CSR was made against. Double-clicking the .cer in Finder
# is the step everyone takes and it is only two thirds of the job: it imports the
# certificate, and whether an identity results depends on the private key already
# being in the same keychain, which it is NOT when the CSR came from openssl rather
# than from Keychain Access. The symptom is a certificate visible in Keychain Access
# with no disclosure triangle, and `security find-identity -v -p codesigning`
# reporting "0 valid identities found" — which reads like the certificate failed.
#
# So this script pairs them explicitly and then asks `security find-identity`
# whether an identity actually appeared. That question is the only evidence that
# any of this worked.
#
# THE INTERMEDIATE IS THE OTHER HALF-FAILURE. A Developer ID leaf chains to Apple's
# "Developer ID Certification Authority" and then to the Apple Root CA. If the
# intermediate is missing from this machine, the identity appears, signing appears
# to succeed, and `codesign --verify` later fails with "unable to build chain to
# self-signed root". This script checks for it and names the fix rather than
# discovering it during a release.
#
# ================================================================================
# WHAT CHANGED ON 2026-09-01, AND WHY — this script FAILED against the real
# Developer ID certificate the first time one existed. Every line below is measured
# on this machine, macOS 15.6, against that certificate.
# ================================================================================
#
# 1. THE PKCS#12 IS GONE. It was the whole failure surface and it was never needed.
#    The old path wrote a passphrase-less PKCS#12 and fed it to `security import`.
#    Measured, against the real certificate:
#
#      LibreSSL 3.3.6      p12, empty passphrase -> SecKeychainItemImport: MAC
#                                                  verification failed. 0 identities.
#      OpenSSL 3.6.1 -legacy p12, empty passphrase -> the same MAC failure.
#      OpenSSL 3.6.1 (no -legacy), real passphrase -> the same MAC failure; its
#                                                  default PBES2/AES p12 is one
#                                                  macOS will not verify at all.
#      either openssl, -legacy/LibreSSL, RANDOM passphrase -> 1 identity imported.
#
#    So an empty PKCS#12 passphrase cannot work, and the fix everyone reaches for —
#    a random one-shot passphrase — has to travel to `security import` on `-P`,
#    i.e. on a command line, where `ps` shows it to every process this user runs.
#    That is the exact thing the doctrine below forbids.
#
#    MEASURED, so it is not left as a doctrine the code does not keep: `security
#    import` has NO non-argv passphrase channel. Omitting `-P` does not mean "empty
#    password" — it escalates to SecurityAgent and puts a GUI dialog on the
#    operator's screen, and the process then blocks on a human forever. Piping the
#    passphrase to stdin does not feed it. There is no `-P -`, no file, no env var.
#
#    The way out is not to need a passphrase. `security import` takes a PEM private
#    key and a PEM certificate DIRECTLY; import both into one keychain and the
#    keychain pairs them into an identity by public key. Measured on the real
#    certificate: "1 key imported.", "1 certificate imported.", and
#    `security find-identity -v -p codesigning` then reports
#    BF4D68E6…  "Developer ID Application: Alex Booster (TZ33A4QCZJ)".
#    No PKCS#12, no passphrase, nothing on a command line, nothing to delete.
#
# 2. THE OPENSSL IS PINNED to /usr/bin/openssl. It used to be whichever openssl
#    came first on PATH; on this machine that is Homebrew's OpenSSL 3.6.1 and the
#    OS's is LibreSSL 3.3.6. For something this load-bearing, PATH order is not an
#    input. RICHOS_OPENSSL overrides, and the choice is printed.
#
# 3. THE .cer IS DER AND IS CONVERTED EXPLICITLY, and the result is checked before
#    anything consumes it. Apple returns DER. LibreSSL will not read DER where PEM
#    is expected — it prints "unable to load certificates", exits 1, AND LEAVES A
#    0-BYTE OUTPUT FILE, which then fails downstream with a misleading error about
#    something else entirely. OpenSSL 3.x quietly accepts the DER, so the bug is
#    invisible on a machine with Homebrew openssl first — which is precisely why
#    pinning the openssl and converting explicitly are one change, not two.
#
# 4. NOTHING HERE MAY EVER RAISE A PROMPT. A release script that blocks on an
#    invisible dialog hangs in CI and in front of the person running it. So:
#    every `security import` passes `-P ''` explicitly (missing `-P` is a GUI
#    dialog, not an empty password); every openssl read of the private key passes
#    `-passin pass:` (without it, an encrypted key makes openssl block on a
#    terminal prompt); and an encrypted private key is REFUSED before any keychain
#    call rather than discovered inside one.
#
# NO CREDENTIAL IS EVER PUT ON A COMMAND LINE — and as of this revision the code
# keeps that, because there is no credential left to put anywhere. The private key
# is protected by the same file permissions that already protect it (0600 in a 0700
# directory), which is the honest comparison.
#
# ONE THING THIS SCRIPT CANNOT DO FOR YOU. Importing a key from the command line
# gives it a trusted-application ACL (`-T /usr/bin/codesign`) but not a partition
# list, so the FIRST time codesign uses it macOS may ask once, in a dialog, to
# confirm. Fixing that ahead of time needs the keychain's own password on a command
# line (`security set-key-partition-list -k …`), which is the credential this script
# refuses to handle. It is named here rather than left to be met during a release.
#
# Exit codes: 0 installed and verified (or, with --check, a usable identity exists).
# 1 the import reported success and no identity resulted (or, with --check, this
# machine has no usable Developer ID Application identity). 2 refused. 3 a
# prerequisite is missing.
set -euo pipefail

key_dir="${RICHOS_SIGNING_DIR:-$HOME/.richos-signing}"
keychain="${RICHOS_KEYCHAIN:-}"
cer=""
check_only=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      check_only=1; shift ;;
    --dir)        key_dir="${2:-}"; shift 2 ;;
    --dir=*)      key_dir="${1#*=}"; shift ;;
    --keychain)   keychain="${2:-}"; shift 2 ;;
    --keychain=*) keychain="${1#*=}"; shift ;;
    --keep-p12)
      echo "error: --keep-p12 is gone: this script no longer builds a PKCS#12 at all." >&2
      echo "       It imports the PEM key and the PEM certificate directly, because a" >&2
      echo "       passphrase-less PKCS#12 fails macOS's MAC verification and a" >&2
      echo "       passphrase-bearing one can only be handed to 'security import' on a" >&2
      echo "       command line. For a portable backup, make one deliberately with a" >&2
      echo "       passphrase you TYPE rather than pass as an argument:" >&2
      echo "         /usr/bin/openssl pkcs12 -export -inkey $key_dir/developer-id.key \\" >&2
      echo "             -in <cert.pem> -out backup.p12" >&2
      exit 2 ;;
    -h|--help)    sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    *)  cer="$1"; shift ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

[ "$(uname -s)" = "Darwin" ] || { warn "error: keychains are macOS; this runs on macOS only."; exit 3; }

# ---------------------------------------------------------------------------
# The openssl is PINNED. See note 2 in the header: PATH order decided which
# implementation built the credential material, and the two implementations do
# not agree about DER, about PKCS#12 encryption, or about -legacy.
# ---------------------------------------------------------------------------
OPENSSL="${RICHOS_OPENSSL:-/usr/bin/openssl}"
if [ ! -x "$OPENSSL" ]; then
  warn "error: no openssl at $OPENSSL."
  warn "       This script pins /usr/bin/openssl deliberately rather than taking"
  warn "       whichever one PATH offers. Set RICHOS_OPENSSL to override."
  exit 3
fi

INTERMEDIATE_CN="Developer ID Certification Authority"
INTERMEDIATE_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"

# Every `security` call that reads identities must read the keychain this run
# WROTE to. Reading the default search list instead is a false pass: a failed
# import into --keychain X still "finds" the identity that was already in login.
find_identity_out() {
  if [ -n "$keychain" ]; then
    security find-identity -v -p codesigning "$keychain" 2>/dev/null || true
  else
    security find-identity -v -p codesigning 2>/dev/null || true
  fi
}

devid_names() { printf '%s\n' "$1" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'; }

# ---------------------------------------------------------------------------
# --check: state of this machine, nothing written.
#
# This used to print its own heading and then nothing at all — the one question
# the script exists to answer was the one its status output did not show — and it
# exited 0 whatever it found. Both are fixed: the identities are printed, and the
# exit code carries the answer.
# ---------------------------------------------------------------------------
if [ -n "$check_only" ]; then
  ids="$(find_identity_out)"
  say "codesigning identities${keychain:+ in $keychain} on this machine:"
  if [ -n "$ids" ]; then
    printf '%s\n' "$ids" | sed 's/^/    /'
  else
    say "    (none — 'security find-identity -v -p codesigning' returned nothing)"
  fi
  names="$(devid_names "$ids")"
  devid_count="$(printf '%s' "$names" | grep -c . || true)"
  say ""
  say "  Developer ID Application identities: $devid_count"
  [ "$devid_count" -gt 0 ] && printf '%s\n' "$names" | sed 's/^/    /'
  say ""

  intermediate_ok=1
  if security find-certificate -c "$INTERMEDIATE_CN" >/dev/null 2>&1; then
    say "  Apple intermediate '$INTERMEDIATE_CN': PRESENT"
  else
    intermediate_ok=0
    say "  Apple intermediate '$INTERMEDIATE_CN': ABSENT"
    say "    Without it a Developer ID signature cannot build a chain to the Apple root."
    say "    Fix: curl -fLO $INTERMEDIATE_URL && security import DeveloperIDG2CA.cer"
  fi
  say ""
  if [ -f "$key_dir/developer-id.key" ]; then
    say "  private key expected at: $key_dir/developer-id.key (present)"
  else
    say "  private key expected at: $key_dir/developer-id.key (ABSENT — run make-signing-csr.sh)"
  fi
  say ""
  if [ "$devid_count" -eq 0 ]; then
    say "VERDICT: this machine cannot sign for distribution — no Developer ID"
    say "Application identity. Exit code 1, so a caller can act on it."
    exit 1
  fi
  if [ "$intermediate_ok" -eq 0 ]; then
    say "VERDICT: an identity exists but Apple's intermediate does not, so signatures"
    say "made with it will not verify. Exit code 1."
    exit 1
  fi
  say "VERDICT: usable. $devid_count Developer ID Application identit(y/ies) and the"
  say "Apple intermediate are both present."
  exit 0
fi

if [ -z "$cer" ]; then
  warn "error: give me the .cer Apple issued, e.g."
  warn "       $0 ~/Downloads/developerID_application.cer"
  warn "       (or $0 --check to see what this machine already has)"
  exit 2
fi
[ -f "$cer" ] || { warn "error: no such file: $cer"; exit 2; }

key_path="$key_dir/developer-id.key"
if [ ! -f "$key_path" ]; then
  warn ""
  warn "REFUSING — the private key is not at $key_path."
  warn ""
  warn "  The certificate on its own cannot sign anything. It was issued against a"
  warn "  private key that this machine must still hold; without it, importing the"
  warn "  certificate produces no identity and no error, which is the failure this"
  warn "  script exists to make visible."
  warn ""
  warn "  If the CSR was generated elsewhere, bring that key here. If no CSR has been"
  warn "  generated yet, the certificate cannot be the right one:"
  warn "      app/scripts/make-signing-csr.sh"
  warn ""
  exit 2
fi

say "openssl        : $OPENSSL ($("$OPENSSL" version 2>/dev/null | head -1))"

# ---------------------------------------------------------------------------
# DER -> PEM, EXPLICITLY, and the result is checked before anything reads it.
# LibreSSL leaves a 0-byte file behind when this goes wrong; a 0-byte file that
# nothing checks is how a misleading error three steps later gets produced.
# ---------------------------------------------------------------------------
cer_pem="$key_dir/.developer-id.cer.pem"
umask 077
rm -f "$cer_pem"
if ! "$OPENSSL" x509 -inform DER -in "$cer" -outform PEM -out "$cer_pem" 2>/dev/null; then
  # Apple has shipped PEM here before; accept either rather than guessing at the bytes.
  rm -f "$cer_pem"
  if ! "$OPENSSL" x509 -inform PEM -in "$cer" -outform PEM -out "$cer_pem" 2>/dev/null; then
    rm -f "$cer_pem"
    warn "error: $cer is not a certificate $OPENSSL can read as DER or PEM."
    exit 2
  fi
fi
if [ ! -s "$cer_pem" ] || ! grep -q 'BEGIN CERTIFICATE' "$cer_pem"; then
  rm -f "$cer_pem"
  warn "error: converting $cer to PEM produced an empty or unusable file."
  warn "       That is the 0-byte artifact this check exists for: openssl can exit"
  warn "       reporting failure AND leave an output file behind, and every step"
  warn "       after it then fails with an error about the wrong thing."
  exit 2
fi
chmod 600 "$cer_pem"

# ---------------------------------------------------------------------------
# The certificate must actually match the key. Compared by public modulus, which
# is the only comparison that answers it. Getting this wrong produces an identity
# that exists and cannot sign.
#
# `-passin pass:` is not decoration: without it, an ENCRYPTED private key makes
# openssl block on a terminal passphrase prompt. With it, it fails immediately and
# the refusal below is reached instead.
# ---------------------------------------------------------------------------
key_mod="$("$OPENSSL" rsa -in "$key_path" -noout -modulus -passin pass: 2>/dev/null || true)"
if [ -z "$key_mod" ]; then
  rm -f "$cer_pem"
  warn ""
  warn "REFUSING — $key_path cannot be read without a passphrase."
  warn ""
  warn "  Either it is not an RSA private key, or it is encrypted. An encrypted key"
  warn "  is refused HERE, deliberately, rather than handed to 'security import':"
  warn "  that would raise a macOS passphrase dialog and block this script on a human"
  warn "  forever, which in CI is an unattended hang with no output."
  warn ""
  warn "  Decrypt it deliberately, with a passphrase you type:"
  warn "      /usr/bin/openssl rsa -in $key_path -out $key_path.plain"
  warn ""
  exit 2
fi
cer_mod="$("$OPENSSL" x509 -in "$cer_pem" -noout -modulus 2>/dev/null || true)"
if [ "$key_mod" != "$cer_mod" ]; then
  rm -f "$cer_pem"
  warn ""
  warn "REFUSING — this certificate was NOT issued against the key at $key_path."
  warn ""
  warn "  Their public moduli differ, so they are not two halves of one identity."
  warn "  Most likely a CSR was regenerated after this certificate was requested, or"
  warn "  this is a certificate from a different request. Neither is recoverable by"
  warn "  retrying: request a new certificate from the CURRENT key's CSR at"
  warn "      $key_dir/developer-id.certSigningRequest"
  warn ""
  exit 2
fi

cert_cn="$("$OPENSSL" x509 -in "$cer_pem" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')"
cert_end="$("$OPENSSL" x509 -in "$cer_pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

say "certificate    : $cert_cn"
say "expires        : $cert_end"
say "matches key    : yes (public moduli identical)"
say ""

if ! printf '%s' "$cert_cn" | grep -q '^Developer ID Application:'; then
  warn "REFUSING — this is not a Developer ID APPLICATION certificate."
  warn ""
  warn "  Its common name is: $cert_cn"
  warn ""
  warn "  The portal offers several types and they are not interchangeable:"
  warn "    Developer ID Application  <- signs a .app for direct download. THIS one."
  warn "    Developer ID Installer    <- signs .pkg installers only."
  warn "    Apple Development / Distribution <- App Store and test devices; Gatekeeper"
  warn "                                        rejects a downloaded app signed with them."
  warn ""
  warn "  Revoke this one and request the right type; docs/ceo/developer-id-setup-2026-08-31.md"
  warn "  names the exact menu entry."
  rm -f "$cer_pem"
  exit 2
fi

# ---------------------------------------------------------------------------
# Import both halves, then ASK whether an identity resulted.
#
# `-P ''` on EVERY call. A missing -P is not an empty passphrase: it is a
# SecurityAgent dialog and an indefinite block. An item that is already there
# reports "The specified item already exists in the keychain." and exits 1, which
# is what makes a second run of this script a no-op rather than an error.
# ---------------------------------------------------------------------------
import_one() {                       # import_one <file> <what>  -> 0 ok, 1 real failure
  local file="$1" what="$2" out rc
  local args=(import "$file" -P '' -T /usr/bin/codesign -T /usr/bin/security)
  [ -n "$keychain" ] && args+=(-k "$keychain")
  set +e
  out="$(security "${args[@]}" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    say "  $what: $(printf '%s' "$out" | tr '\n' ' ')"
    return 0
  fi
  if printf '%s' "$out" | grep -qi 'already exists'; then
    say "  $what: already present (this run changed nothing, which is what re-running should do)"
    return 0
  fi
  warn "error: importing the $what failed:"
  warn "$out"
  return 1
}

say "importing into the ${keychain:-login} keychain..."
import_failed=0
import_one "$key_path" "private key"  || import_failed=1
import_one "$cer_pem"  "certificate"  || import_failed=1
rm -f "$cer_pem"

if [ "$import_failed" -ne 0 ]; then
  warn ""
  warn "FAILED — at least one half did not import, so no identity can have been"
  warn "created. Exiting non-zero: a failure that exits 0 is how a broken install"
  warn "gets reported as done."
  exit 2
fi

# ---------------------------------------------------------------------------
# The verification. This is the only sentence in this script that is evidence.
# ---------------------------------------------------------------------------
say ""
say "codesigning identities now${keychain:+ in $keychain}:"
ids="$(find_identity_out)"
printf '%s\n' "$ids" | sed 's/^/    /'
say ""

names="$(devid_names "$ids")"
devid_count="$(printf '%s' "$names" | grep -c . || true)"
if [ "$devid_count" -eq 0 ]; then
  warn "FAILED — the import reported success and NO Developer ID Application identity exists."
  warn ""
  warn "  That is the exact state this script was written to stop being reported as done."
  warn "  The usual cause is that the certificate landed in a keychain the key is not in."
  warn "  Try naming one explicitly:  $0 --keychain login.keychain-db $cer"
  exit 1
fi

if ! security find-certificate -c "$INTERMEDIATE_CN" >/dev/null 2>&1; then
  say "WARNING — Apple's intermediate '$INTERMEDIATE_CN' is not on this machine."
  say "  Signing will appear to work and 'codesign --verify' will later fail with"
  say "  'unable to build chain to self-signed root'. Fix it now, it is one command:"
  say "      curl -fLO $INTERMEDIATE_URL && security import DeveloperIDG2CA.cer"
  say ""
fi

identity="$(printf '%s\n' "$names" | head -1)"
team="$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"

say "OK: '$identity' is installed and usable."
say ""
say "  Team ID: ${team:-<not in the identity string>}"
say "  package-app.sh DISCOVERS this identity on its own when exactly one exists, so"
say "  nothing needs to be exported. To pin it anyway:"
say "      export RICHOS_SIGNING_IDENTITY='$identity'"
say ""
say "  ONE-TIME DIALOG, named here rather than met during a release: a key imported"
say "  from the command line carries a trusted-application ACL but no partition list,"
say "  so the first codesign run may ask you once to confirm. Click 'Always Allow'."
say "  Removing even that needs the keychain's own password on a command line, which"
say "  this script will not do."
say ""
say "  Next: app/scripts/package-app.sh --sign developer-id"
