#!/usr/bin/env bash
# Generate the Certificate Signing Request the Apple portal asks for, and the
# private key that request is made against. Neither ever enters a repository.
#
#   app/scripts/make-signing-csr.sh                 # generate, using this machine's defaults
#   app/scripts/make-signing-csr.sh --name "Alex Booster" --email a@b.com --country GB
#   app/scripts/make-signing-csr.sh --show          # describe what already exists
#
# WHY THIS FILE EXISTS
# --------------------
# A Developer ID Application certificate is not downloaded. It is REQUESTED: you
# create a keypair, hand Apple the public half inside a CSR, and Apple hands back a
# certificate that is worthless without the private half you kept. Apple's own
# documented route to that keypair is Keychain Access -> Certificate Assistant ->
# "Request a Certificate From a Certificate Authority", which is six GUI steps with
# three fields whose wrong values are not detectable until a build fails weeks
# later. This script is those six steps, run once, with the values written down.
#
# THE PRIVATE KEY IS THE WHOLE ASSET. Lose it and the issued certificate is
# scrap — Apple cannot re-issue against a key it never had; you revoke and start
# again. Leak it and someone else can sign software as the CEO. So:
#
#   * it is written OUTSIDE any git worktree, and this script REFUSES to write it
#     inside one (checked with `git rev-parse`, not by looking at the path);
#   * its directory is 0700 and the key itself 0600, set before the key is written
#     rather than after;
#   * an existing key is never silently overwritten. Overwriting it orphans any
#     certificate already issued against it, which is a footgun that looks like a
#     successful run.
#
# WHAT APPLE ACTUALLY REQUIRES OF THE CSR, and where each number comes from:
#
#   RSA 2048-bit, SHA-256   Apple's Certificate Assistant defaults, and what its
#                           "Key Size / Algorithm" sheet offers for a code-signing
#                           request. Apple has never published a CSR spec page; this
#                           mirrors what its own tool emits.
#   PEM, .certSigningRequest   the extension the portal's upload field filters on.
#                           The bytes are an ordinary PEM CSR.
#
# THE SUBJECT FIELDS BARELY MATTER, and it is worth saying so rather than letting
# someone agonise over them. Apple issues the certificate against the ENROLLED
# ACCOUNT's legal name and team, not against what you type here — the Common Name on
# the issued certificate will read "Developer ID Application: <legal name> (<TEAMID>)"
# whatever this CSR says. They are filled in honestly anyway, because a CSR with a
# stranger's details in it is a confusing artifact to find on disk in a year.
#
# Exit codes: 0 generated (or described). 2 refused. 3 a prerequisite is missing.
set -euo pipefail

key_dir="${RICHOS_SIGNING_DIR:-$HOME/.richos-signing}"
name=""
email=""
country=""
force=""
show=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)      name="${2:-}"; shift 2 ;;
    --name=*)    name="${1#*=}"; shift ;;
    --email)     email="${2:-}"; shift 2 ;;
    --email=*)   email="${1#*=}"; shift ;;
    --country)   country="${2:-}"; shift 2 ;;
    --country=*) country="${1#*=}"; shift ;;
    --dir)       key_dir="${2:-}"; shift 2 ;;
    --dir=*)     key_dir="${1#*=}"; shift ;;
    --force)     force=1; shift ;;
    --show)      show=1; shift ;;
    -h|--help)   sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

command -v openssl >/dev/null 2>&1 || { warn "error: openssl not found on PATH."; exit 3; }

key_path="$key_dir/developer-id.key"
csr_path="$key_dir/developer-id.certSigningRequest"

# ---------------------------------------------------------------------------
# --show: describe what is on disk. No arguments needed, nothing written.
# ---------------------------------------------------------------------------
if [ -n "$show" ]; then
  say "signing material directory: $key_dir"
  if [ ! -d "$key_dir" ]; then
    say "  (does not exist — nothing has been generated)"
    exit 0
  fi
  say "  directory mode: $(stat -f '%Lp' "$key_dir")"
  if [ -f "$key_path" ]; then
    bits="$(openssl rsa -in "$key_path" -noout -text 2>/dev/null | sed -n 's/^.*Private-Key: (\([0-9]*\) bit.*/\1/p' | head -1)"
    say "  private key : $key_path  (mode $(stat -f '%Lp' "$key_path"), RSA ${bits:-unknown}-bit)"
  else
    say "  private key : ABSENT"
  fi
  if [ -f "$csr_path" ]; then
    say "  CSR         : $csr_path  (mode $(stat -f '%Lp' "$csr_path"))"
    say "  CSR subject : $(openssl req -in "$csr_path" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    say "  CSR digest  : $(openssl req -in "$csr_path" -noout -text 2>/dev/null | sed -n 's/^ *Signature Algorithm: *//p' | head -1)"
  else
    say "  CSR         : ABSENT"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# The key must not land in a repository. Asked of git, not of the string.
# ---------------------------------------------------------------------------
probe_dir="$key_dir"
while [ ! -d "$probe_dir" ] && [ "$probe_dir" != "/" ]; do probe_dir="$(dirname "$probe_dir")"; done
if inside="$(cd "$probe_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$inside" ]; then
  warn ""
  warn "REFUSING — $key_dir is inside a git worktree:"
  warn ""
  warn "    $inside"
  warn ""
  warn "  A code-signing private key does not go in a repository, not even ignored,"
  warn "  not even briefly: an ignore rule is one 'git add -f' from being wrong, and"
  warn "  a key that has been committed once is compromised for the life of the"
  warn "  history. Pick a directory outside every checkout — the default,"
  warn "  \$HOME/.richos-signing, is one."
  warn ""
  exit 2
fi

# ---------------------------------------------------------------------------
# Subject fields. Defaulted from this machine where a default is honest.
# ---------------------------------------------------------------------------
if [ -z "$name" ]; then
  name="$(id -F 2>/dev/null || true)"
  [ -n "$name" ] || name="$(id -un)"
fi
if [ -z "$email" ]; then
  email="$(git config --get user.email 2>/dev/null || true)"
fi
if [ -z "$email" ]; then
  warn "error: no email address. Pass --email <the Apple Account's address>."
  warn "       git config user.email is unset, so there is nothing honest to default to."
  exit 2
fi
if [ -z "$country" ]; then
  # AppleLocale is not one shape. This machine reports `en_US@rg=gbzzzz`, measured
  # 2026-08-31: language en_US, REGION GB. Reading only the two letters after the
  # underscore gets US out of a machine whose region is GB, so the `@rg=` override
  # is read FIRST and the language region is the fallback. Neither -> ask, never guess.
  locale="$(defaults read -g AppleLocale 2>/dev/null || true)"
  country="$(printf '%s' "$locale" | sed -n 's/.*@rg=\([a-z][a-z]\).*/\1/p' | tr '[:lower:]' '[:upper:]' | head -1)"
  [ -n "$country" ] || country="$(printf '%s' "$locale" | sed -n 's/^[a-z][a-z]*[_-]\([A-Z][A-Z]\).*$/\1/p' | head -1)"
fi
if ! printf '%s' "$country" | grep -qE '^[A-Z]{2}$'; then
  warn "error: could not determine a two-letter country code (got '${country:-<empty>}')."
  warn "       Pass --country GB (or US, DE, ...). openssl rejects anything else."
  exit 2
fi

# ---------------------------------------------------------------------------
# Never overwrite an existing key by accident.
# ---------------------------------------------------------------------------
if [ -f "$key_path" ] && [ -z "$force" ]; then
  warn ""
  warn "REFUSING — a private key already exists at:"
  warn ""
  warn "    $key_path"
  warn ""
  warn "  Overwriting it would ORPHAN any certificate already issued against it:"
  warn "  the .cer from Apple would still download, still install, and still be"
  warn "  useless, because the private half it was issued to no longer exists. That"
  warn "  failure surfaces at the first signing attempt, not here."
  warn ""
  warn "  If you are certain there is no certificate for this key, re-run with"
  warn "  --force. To see what is there: $0 --show"
  warn ""
  exit 2
fi

# ---------------------------------------------------------------------------
# Generate. Permissions first, so the key is never briefly world-readable.
# ---------------------------------------------------------------------------
mkdir -p "$key_dir"
chmod 700 "$key_dir"

umask 077
openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -keyout "$key_path" \
  -out "$csr_path" \
  -subj "/emailAddress=$email/CN=$name/C=$country" >/dev/null 2>&1 \
  || { warn "error: openssl refused to generate the request. Re-run without the redirect to see why."; exit 2; }

chmod 600 "$key_path"
chmod 644 "$csr_path"

subject="$(openssl req -in "$csr_path" -noout -subject | sed 's/^subject=//')"
digest="$(openssl req -in "$csr_path" -noout -text | sed -n 's/^ *Signature Algorithm: *//p' | head -1)"
bits="$(openssl rsa -in "$key_path" -noout -text 2>/dev/null | sed -n 's/^.*Private-Key: (\([0-9]*\) bit.*/\1/p' | head -1)"

say ""
say "Certificate Signing Request generated."
say ""
say "  upload THIS to Apple    : $csr_path"
say "  keep THIS, never share  : $key_path   (mode $(stat -f '%Lp' "$key_path"), RSA ${bits}-bit)"
say "  subject                 : $subject"
say "  signature               : $digest"
say ""
say "  Neither file is in a repository, and this script refuses to put them in one."
say ""
say "NEXT, and only the account holder can do it — docs/ceo/developer-id-setup-2026-08-31.md"
say "walks it in plain language. In one line: developer.apple.com/account -> Certificates ->"
say "+ -> Developer ID Application -> upload the .certSigningRequest above -> download the"
say ".cer. Then, back here:"
say ""
say "  app/scripts/install-signing-cert.sh ~/Downloads/developerID_application.cer"
say ""
