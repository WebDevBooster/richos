#!/usr/bin/env bash
# two-logins-check.sh — after run.sh's one push, are BOTH sign-ins in the guest?
# Prints ITEM NAMES only (keychain service names and credential file paths), never a value.
#
#   run-walk.py --no-app --home <empty dir> --engine <engine.tar.gz> --report <json> -- two-logins-check.sh
#
# run-walk.py passes the VM name first. Exit 0 when Home's scoped item AND Work's item
# are both there, 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e
VM="${1:?usage: two-logins-check.sh <vm>}"
GUEST_HOME="$(cat "$TESTVM_RUN/$VM/payload" 2>/dev/null)/home"
case "$GUEST_HOME" in "/Users/$TESTVM_GUEST_USER/"*) ;; *) die "no guest home recorded for $VM" ;; esac
KC="$GUEST_HOME/Library/Keychains/login.keychain-db"
sha8() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
HOME_ITEM="Claude Code-credentials-$(sha8 "$GUEST_HOME/.claude")"
WORK_DIR="$GUEST_HOME/claude-accounts/2"
WORK_ITEM="Claude Code-credentials-$(sha8 "$WORK_DIR")"
bad=0
for item in "$HOME_ITEM" "$WORK_ITEM"; do
  if guest_ssh "$VM" "env HOME='$GUEST_HOME' security find-generic-password -a '$TESTVM_GUEST_USER' -s '$item' '$KC' >/dev/null 2>&1"; then
    echo "guest keychain item present: $item"
  else
    echo "guest keychain item MISSING: $item"; bad=1
  fi
done
for f in "$GUEST_HOME/.claude/.credentials.json" "$WORK_DIR/.credentials.json"; do
  if guest_ssh "$VM" "test -s '$f'"; then echo "guest credential file present: $f"; else echo "guest credential file MISSING: $f"; bad=1; fi
done
exit "$bad"
