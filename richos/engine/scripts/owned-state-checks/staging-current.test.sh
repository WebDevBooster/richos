#!/usr/bin/env bash
#
# staging-current.test.sh — staging-current.sh must judge what staging CARRIES,
# not only whether main has commits staging lacks.
#
#   C1  staging at main's tip is current (the control).
#   C2  staging a few commits behind main, with product changes since, is STALE.
#   C3  staging at a DESCENDANT of main that reverts the product to its old
#       content is STALE: no main commit is missing from it, yet it runs a
#       different product than main. (Hunt P5-11: this used to print "current".)
#   C4  staging at a descendant of main that only adds a file OUTSIDE the product
#       tree is still current: a difference elsewhere is not a stale product.
#
# CHECKER_DIR names the owned-state-checks directory to test (used to show the
# new case fails on the version before the fix). It must have ../lib beside it.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${CHECKER_DIR:-$SCRIPT_DIR}/staging-current.sh"
RECORDER="$SCRIPT_DIR/../staging-record.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/staging-current-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

R="$SANDBOX/repo"
mkdir -p "$R/product"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name t
printf 'STAGING_TREES="product"\nSTAGING_DEPLOY_RECORD=".claude/state/staging-deployed"\n' > "$R/orchestration.config"
printf 'old\n' > "$R/product/f.txt"
git -C "$R" add -A
git -C "$R" commit -q --no-verify -m old
OLD="$(git -C "$R" rev-parse HEAD)"
printf 'new\n' > "$R/product/f.txt"
git -C "$R" commit -q --no-verify -am new
NEW="$(git -C "$R" rev-parse HEAD)"

# A deploy that shipped a descendant of main which reverted the product.
git -C "$R" checkout -q -b deploy-revert
printf 'old\n' > "$R/product/f.txt"
git -C "$R" commit -q --no-verify -am "revert product"
REVERT="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
# A deploy that shipped a descendant of main touching only a non-product file.
git -C "$R" checkout -q -b deploy-docs
printf 'note\n' > "$R/NOTES.txt"
git -C "$R" add -A
git -C "$R" commit -q --no-verify -m "docs only"
DOCS="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main

record() { bash "$RECORDER" --root "$R" --sha "$1" --tree product --outcome success >/dev/null; }
check() { OUT="$(bash "$CHECKER" --root "$R" 2>&1)"; RC=$?; }

record "$NEW"; check
if [ "$RC" = 0 ] && grep -q '^current' <<<"$OUT"; then ok "C1  staging at main's tip is current"; else bad "C1  (rc=$RC): $OUT"; fi

record "$OLD"; check
if [ "$RC" = 1 ] && grep -q '^STALE' <<<"$OUT"; then ok "C2  staging behind main with product changes since is STALE"; else bad "C2  (rc=$RC): $OUT"; fi

record "$REVERT"; check
if [ "$RC" = 1 ] && grep -q '^STALE' <<<"$OUT"; then ok "C3  a descendant that reverts the product is STALE"; else bad "C3  (rc=$RC): $OUT"; fi

record "$DOCS"; check
if [ "$RC" = 0 ] && grep -q '^current' <<<"$OUT"; then ok "C4  a descendant that changes only files outside the tree is current"; else bad "C4  (rc=$RC): $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
