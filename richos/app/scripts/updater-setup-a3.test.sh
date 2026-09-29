#!/usr/bin/env bash
#
# updater-setup-a3.test.sh — updater-setup.test.sh's case A3 ("a key inside a git worktree
# refuses") never puts its key into the checkout the suite is verified in.
#
# WHY (2026-09-30). A3 used to copy a signing key to `$APP/.updater-key-under-test.key`, the
# real checkout, because the checkout is a git worktree and the refusal needs one. A proof run
# fingerprinting that checkout listed the file, A3's cleanup removed it, and the land of
# zach-opus-stable1 crashed opening it (proof-run.py source_identity(); lead log
# /Volumes/E1TB/tmp/claude/rich/merge-stable1.log). A throwaway `git init` repository proves the
# same refusal without writing into anything that is being verified.
#
# HOW, in seconds and without cargo: a COPY of the suite runs in a throwaway checkout (itself a
# git repository, as the real one is), beside a stub `package-app.sh` that records every key
# path it is handed and refuses a key inside a repository the way the real one does, and a stub
# `cargo` that writes a dummy key for `cargo tauri signer generate` and fails everything else.
# Every other case of the copy fails for want of the real tools; only A3 and the paths are read.
#
# Checks:
#   1  the copy reached A3 and A3 saw the refusal (its key was inside a repository)
#   2  no key the copy handed to package-app.sh lies inside the checkout it was run from
#   3  the checkout is exactly as it was: nothing left behind in it either
#
# run-tests: inputs richos/app/scripts/updater-setup-a3.test.sh richos/app/scripts/updater-setup.test.sh
# run-tests: covers -
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$SRC_DIR/updater-setup.test.sh"

TMP="$(mktemp -d -t updater-setup-a3.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# The throwaway checkout: app/scripts holds the suite under test and the stub packager.
CHECKOUT="$TMP/checkout"
mkdir -p "$CHECKOUT/app/scripts/lib" "$CHECKOUT/app/src-tauri/capabilities"
git -C "$CHECKOUT" init -q
cp "$SUITE" "$CHECKOUT/app/scripts/updater-setup.test.sh"
cat > "$CHECKOUT/app/scripts/package-app.sh" <<'SH'
#!/usr/bin/env bash
# Stub: record the key path, then refuse a key inside a repository as package-app.sh does.
key="${TAURI_SIGNING_PRIVATE_KEY_PATH:-}"
[ -n "$key" ] && [ -e "$key" ] && printf '%s/%s\n' "$(cd "$(dirname "$key")" && pwd -P)" "$(basename "$key")" >> "$A3_KEYS_HANDED"
if [ -n "$key" ] && [ -e "$key" ] && (cd "$(dirname "$key")" && git rev-parse --show-toplevel >/dev/null 2>&1); then
  echo "REFUSING — the key is inside a git worktree"
  exit 2
fi
exit 0
SH
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'SH'
#!/usr/bin/env bash
# Stub: `cargo tauri signer generate -w <path> ...` writes a dummy key pair; nothing else works.
if [ "${1:-} ${2:-} ${3:-}" = "tauri signer generate" ]; then
  shift 3
  while [ $# -gt 0 ]; do
    if [ "$1" = "-w" ]; then printf 'dummy key\n' > "$2"; printf 'dummy pub\n' > "$2.pub"; fi
    shift
  done
  exit 0
fi
exit 1
SH
chmod 755 "$CHECKOUT/app/scripts/package-app.sh" "$TMP/bin/cargo"
git -C "$CHECKOUT" add -A
BEFORE="$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)"

export A3_KEYS_HANDED="$TMP/keys-handed.txt"
: > "$A3_KEYS_HANDED"
PATH="$TMP/bin:$PATH" bash "$CHECKOUT/app/scripts/updater-setup.test.sh" > "$TMP/suite.out" 2>&1

echo ""
echo "=== updater-setup.test.sh A3 keeps its key out of the checkout ==="

if grep -q "PASS  A3 " "$TMP/suite.out"; then
  ok "1 the suite reached A3 and saw the refusal"
else
  bad "1 the suite reached A3 and saw the refusal" \
      "$(grep -E "A3|could not" "$TMP/suite.out" | head -3 | tr '\n' ' ')"
fi

REAL_CHECKOUT="$(cd "$CHECKOUT" && pwd -P)"
INSIDE="$(grep -F "$REAL_CHECKOUT/" "$A3_KEYS_HANDED" || true)"
if [ ! -s "$A3_KEYS_HANDED" ]; then
  bad "2 no key handed to package-app.sh lies inside the checkout" "no key was handed to package-app.sh at all"
elif [ -n "$INSIDE" ]; then
  bad "2 no key handed to package-app.sh lies inside the checkout" \
      "the suite wrote a key into the checkout it is verified in: $INSIDE"
else
  ok "2 no key handed to package-app.sh lies inside the checkout ($(wc -l < "$A3_KEYS_HANDED" | tr -d ' ') handed)"
fi

AFTER="$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "3 the checkout is exactly as the suite found it"
else
  bad "3 the checkout is exactly as the suite found it" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | tr '\n' ' ')"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== updater-setup-a3.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== updater-setup-a3.test.sh: all $PASS passed ==="
