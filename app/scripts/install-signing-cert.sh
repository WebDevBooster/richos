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
# So this script pairs them explicitly, through a PKCS#12, and then asks
# `security find-identity` whether an identity actually appeared. That question is
# the only evidence that any of this worked.
#
# THE INTERMEDIATE IS THE OTHER HALF-FAILURE. A Developer ID leaf chains to Apple's
# "Developer ID Certification Authority" and then to the Apple Root CA. If the
# intermediate is missing from this machine, the identity appears, signing appears
# to succeed, and `codesign --verify` later fails with "unable to build chain to
# self-signed root". This script checks for it and names the fix rather than
# discovering it during a release.
#
# NO CREDENTIAL IS EVER PUT ON A COMMAND LINE. The PKCS#12 this builds carries no
# passphrase — it lives for the length of one import inside a 0700 directory and is
# then removed — because the alternative is a passphrase visible in `ps` to every
# process on the machine. Its protection is the same file permission already
# protecting the private key beside it, which is the honest comparison.
#
# Exit codes: 0 installed and verified. 1 imported but no identity resulted.
# 2 refused. 3 a prerequisite is missing.
set -euo pipefail

key_dir="${RICHOS_SIGNING_DIR:-$HOME/.richos-signing}"
keychain="${RICHOS_KEYCHAIN:-}"
cer=""
check_only=""
keep_p12=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      check_only=1; shift ;;
    --dir)        key_dir="${2:-}"; shift 2 ;;
    --dir=*)      key_dir="${1#*=}"; shift ;;
    --keychain)   keychain="${2:-}"; shift 2 ;;
    --keychain=*) keychain="${1#*=}"; shift ;;
    --keep-p12)   keep_p12=1; shift ;;
    -h|--help)    sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    *)  cer="$1"; shift ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

[ "$(uname -s)" = "Darwin" ] || { warn "error: keychains are macOS; this runs on macOS only."; exit 3; }
command -v openssl >/dev/null 2>&1 || { warn "error: openssl not found on PATH."; exit 3; }

INTERMEDIATE_CN="Developer ID Certification Authority"
INTERMEDIATE_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"

report_identities() {
  local out
  out="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  say "$out" | sed 's/^/    /'
  printf '%s\n' "$out" | grep -c 'Developer ID Application:' || true
}

# ---------------------------------------------------------------------------
# --check: state of this machine, nothing written.
# ---------------------------------------------------------------------------
if [ -n "$check_only" ]; then
  say "codesigning identities on this machine:"
  report_identities >/dev/null
  say ""
  if security find-certificate -c "$INTERMEDIATE_CN" >/dev/null 2>&1; then
    say "  Apple intermediate '$INTERMEDIATE_CN': PRESENT"
  else
    say "  Apple intermediate '$INTERMEDIATE_CN': ABSENT"
    say "    Without it a Developer ID signature cannot build a chain to the Apple root."
    say "    Fix: curl -fLO $INTERMEDIATE_URL && security import DeveloperIDG2CA.cer"
  fi
  say ""
  say "  private key expected at: $key_dir/developer-id.key $( [ -f "$key_dir/developer-id.key" ] && echo '(present)' || echo '(ABSENT — run make-signing-csr.sh)')"
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

# ---------------------------------------------------------------------------
# The certificate must actually match the key. Compared by public modulus, which
# is the only comparison that answers it. Getting this wrong produces an identity
# that exists and cannot sign.
# ---------------------------------------------------------------------------
cer_pem="$key_dir/.developer-id.cer.pem"
if ! openssl x509 -inform DER -in "$cer" -out "$cer_pem" 2>/dev/null; then
  # Apple has shipped PEM here before; accept either rather than guessing at the bytes.
  if ! openssl x509 -inform PEM -in "$cer" -out "$cer_pem" 2>/dev/null; then
    warn "error: $cer is not a certificate openssl can read as DER or PEM."
    exit 2
  fi
fi
chmod 600 "$cer_pem"

key_mod="$(openssl rsa  -in "$key_path" -noout -modulus 2>/dev/null || true)"
cer_mod="$(openssl x509 -in "$cer_pem"  -noout -modulus 2>/dev/null || true)"
if [ -z "$key_mod" ] || [ "$key_mod" != "$cer_mod" ]; then
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

cert_cn="$(openssl x509 -in "$cer_pem" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')"
cert_end="$(openssl x509 -in "$cer_pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

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
# Pair them, import, and then ASK whether an identity resulted.
# ---------------------------------------------------------------------------
p12="$key_dir/developer-id.p12"
umask 077
if ! openssl pkcs12 -export -legacy -inkey "$key_path" -in "$cer_pem" \
        -name "$cert_cn" -out "$p12" -passout pass: 2>/dev/null; then
  # -legacy is absent on openssl 1.x and required on 3.x for a keychain-readable
  # PKCS#12; try both rather than pinning a version this machine may not have.
  openssl pkcs12 -export -inkey "$key_path" -in "$cer_pem" \
        -name "$cert_cn" -out "$p12" -passout pass: 2>/dev/null \
    || { warn "error: openssl could not build a PKCS#12 from the key and certificate."; rm -f "$cer_pem"; exit 2; }
fi
chmod 600 "$p12"
rm -f "$cer_pem"

import_args=(import "$p12" -P "" -T /usr/bin/codesign -T /usr/bin/security)
[ -n "$keychain" ] && import_args+=(-k "$keychain")

say "importing into the $( [ -n "$keychain" ] && echo "$keychain" || echo "login" ) keychain..."
if ! out="$(security "${import_args[@]}" 2>&1)"; then
  # An already-present item is not a failure; anything else is.
  if printf '%s' "$out" | grep -qi 'already exists'; then
    say "  (already present — continuing to the verification, which is the part that counts)"
  else
    warn "error: security import failed:"
    warn "$out"
    [ -n "$keep_p12" ] || rm -f "$p12"
    exit 2
  fi
fi

if [ -n "$keep_p12" ]; then
  say ""
  say "  KEPT: $p12 — an UNENCRYPTED copy of the private key, protected by nothing but"
  say "  file permissions (0600, in a 0700 directory). It is a fine local artifact and a"
  say "  bad backup. For a backup that leaves this machine, make one with a passphrase you"
  say "  type rather than pass as an argument:"
  say "      openssl pkcs12 -export -inkey $key_path -in <cert.pem> -out backup.p12"
else
  rm -f "$p12"
fi

# ---------------------------------------------------------------------------
# The verification. This is the only sentence in this script that is evidence.
# ---------------------------------------------------------------------------
say ""
say "codesigning identities now on this machine:"
ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
printf '%s\n' "$ids" | sed 's/^/    /'
say ""

devid_count="$(printf '%s\n' "$ids" | grep -c 'Developer ID Application:' || true)"
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

identity="$(printf '%s\n' "$ids" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
team="$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"

say "OK: '$identity' is installed and usable."
say ""
say "  Team ID: ${team:-<not in the identity string>}"
say "  package-app.sh DISCOVERS this identity on its own when exactly one exists, so"
say "  nothing needs to be exported. To pin it anyway:"
say "      export RICHOS_SIGNING_IDENTITY='$identity'"
say ""
say "  Next: app/scripts/package-app.sh --sign developer-id"
