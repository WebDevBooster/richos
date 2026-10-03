#!/usr/bin/env bash
#
# secret-alerts.test.sh — secret-alerts.py with a fake gh.
#   S1  one open alert is reported (number, type, link), exit 1
#   S2  no open alert is silent, exit 0
#   S3  gh failing is exit 2, never 0
# CHECKER_DIR names the owned-state-checks directory to test.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${CHECKER_DIR:-$SCRIPT_DIR}/secret-alerts.py"
PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/secret-alerts-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

R="$SANDBOX/repo"
mkdir -p "$R/.github/workflows"
git -C "$R" init -q -b main
git -C "$R" remote add origin git@github.com:Example/thing.git

fake() { printf '#!/usr/bin/env bash\ncase "$*" in *secret-scanning*) ;; *) echo "{\\"private\\": ${PRIVATE:-false}}"; exit 0 ;; esac\n%s\n' "$1" > "$SANDBOX/gh"; chmod +x "$SANDBOX/gh"; }
run() { OUT="$(GH_BIN="$SANDBOX/gh" python3 "$CHECKER" --repo "$R" 2>&1)"; RC=$?; }

fake "echo '[{\"number\":3,\"secret_type_display_name\":\"Tailscale API Key\",\"html_url\":\"https://github.com/Example/thing/security/secret-scanning/3\"}]'"
run
if [ "$RC" = 1 ] && grep -q '#3' <<<"$OUT" && grep -q 'Tailscale API Key' <<<"$OUT" && grep -q 'secret-scanning/3' <<<"$OUT"; then ok "S1  an open alert is reported"; else bad "S1 (rc=$RC): $OUT"; fi

fake "echo '[]'"
run
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "S2  none open is silent"; else bad "S2 (rc=$RC): $OUT"; fi

fake "exit 1"
run
if [ "$RC" = 2 ]; then ok "S3  gh failing is unknown, not healthy"; else bad "S3 (rc=$RC): $OUT"; fi

fake "exit 1"
PRIVATE=true run
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "S4  a private repository is skipped"; else bad "S4 (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
