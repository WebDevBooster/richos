#!/usr/bin/env bash
#
# rebuild-survival.test.sh — the acceptance harness, including its refusal to
# report a pass it has not earned.
#
# THE POINT OF THIS SUITE IS THE VERDICTS, NOT THE PLUMBING. A harness for a test
# that cannot run yet is exactly the kind of artefact that quietly reports green
# and gets believed, so most of what follows drives it to a state and asserts which
# of the four verdicts comes out: PASS, FAIL, INCOMPLETE (exit 4) or refusal
# (exit 2). Getting INCOMPLETE where a pass is not available is the behaviour under
# test, not a shortcoming of it.
#
# Every bundle here is real and ad-hoc signed by the real codesign; the Developer
# ID cases are driven by hand-written records, because no Developer ID signature
# exists anywhere in this project to record. Those cases prove the COMPARISON, and
# say nothing about a signature nobody has made.
#
# Cases:
#   G1  an unknown command is refused
#   G2  record without a label is refused
#   G3  a record directory inside a git worktree is refused
#   G4  a real ad-hoc bundle records its cdhash, signature kind and requirement
#   G5  compare against a record that does not exist is refused
#   G6  two ad-hoc builds -> CANNOT PASS, and says the certificate is the fix
#   G7  the SAME bundle twice -> INCONCLUSIVE on identical cdhashes, not a pass
#   G8  two Developer-ID-shaped records with the SAME requirement -> layer 1 passes
#   G9  ...and says so is the MECHANISM, not the acceptance test
#   G10 two Developer-ID-shaped records with DIFFERENT requirements -> FAIL
#   G11 a grant held by N and not by N+1 -> FAIL
#   G12 an unreadable TCC database -> INCOMPLETE, never a guessed pass
#   G13 layer 3 is always printed as not machine-checkable
#   G14 status on a machine with no Developer ID identity -> exit 4, naming what it needs
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$SRC_DIR/rebuild-survival.sh"
TMP="$(mktemp -d -t rebuild-survival-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
run() { OUT="$("$@" 2>&1)"; CODE=$?; return 0; }
expect() {
  local name="$1" want="$2" needle="$3"
  if [ "$CODE" != "$want" ]; then
    bad "$name" "exit $CODE, wanted $want. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-220)"
  elif ! printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    bad "$name" "exit $want as wanted, but the output never said '$needle'"
  else ok "$name"; fi
}

make_bundle() {   # make_bundle <dir> <marker-bytes>
  local b="$1" marker="$2"
  rm -rf "$b"; mkdir -p "$b/Contents/MacOS"
  cp /bin/echo "$b/Contents/MacOS/RichOS"
  printf '%s' "$marker" >> "$b/Contents/MacOS/RichOS" 2>/dev/null || true
  cat > "$b/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RichOS</string>
<key>CFBundleIdentifier</key><string>com.richos.app</string>
</dict></plist>
PLIST
  codesign --force --sign - --timestamp=none "$b" >/dev/null 2>&1
}

# A record as the harness writes them, for the states no signature here can reach.
write_record() {  # write_record <dir> <label> <cdhash> <sig> <dr> <mic> <ax>
  mkdir -p "$1"
  cat > "$1/$2.record" <<EOF
label: $2
app: /nowhere/RichOS.app
bundle_id: com.richos.app
cdhash: $3
signature: $4
authority: Developer ID Application: Test Person (TEAM00001)
designated_requirement: $5
tcc_microphone: $6
tcc_accessibility: $7
recorded: 2026-08-31T00:00:00Z
EOF
}

DR_STABLE='identifier "com.richos.app" and anchor apple generic and certificate leaf[subject.OU] = "TEAM00001"'
DR_OTHER='identifier "com.richos.app" and anchor apple generic and certificate leaf[subject.OU] = "TEAM99999"'

echo ""
echo "=== G. the harness ==="
run bash "$H" wibble
expect "G1 an unknown command is refused" 2 "unknown command"

B1="$TMP/N.app";  make_bundle "$B1" ""
B2="$TMP/N1.app"; make_bundle "$B2" "one changed byte"
S="$TMP/state"

run bash "$H" record "$B1" --dir "$S"
expect "G2 record without a label is refused" 2 "needs --label"

REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q 2>/dev/null
run bash "$H" record "$B1" --label N --dir "$REPO/state"
expect "G3 a record directory inside a git worktree is refused" 2 "inside a git worktree"

run bash "$H" record "$B1" --label N --dir "$S"
if [ "$CODE" = 0 ] && grep -q '^signature: adhoc' "$S/N.record" \
   && grep -q '^cdhash: [0-9a-f]\{40\}' "$S/N.record" \
   && grep -q '^designated_requirement: cdhash' "$S/N.record"; then
  ok "G4 a real ad-hoc bundle records its cdhash, signature kind and requirement"
else
  bad "G4 the record is not what codesign reports" "exit $CODE; $(cat "$S/N.record" 2>/dev/null | tr '\n' ' ')"
fi

run bash "$H" compare --a N --b MISSING --dir "$S"
expect "G5 comparing against a record that does not exist is refused" 2 "no record at"

bash "$H" record "$B2" --label N1 --dir "$S" >/dev/null 2>&1
run bash "$H" compare --a N --b N1 --dir "$S"
expect "G6 two ad-hoc builds -> cannot pass, and the certificate is named as the fix" 4 "The certificate is the fix"

bash "$H" record "$B1" --label SAME --dir "$S" >/dev/null 2>&1
run bash "$H" compare --a N --b SAME --dir "$S"
expect "G7 the same bytes twice is INCONCLUSIVE, and says it is not a pass" 4 "This is not a pass"

DS="$TMP/devid"
write_record "$DS" A aaaa1111 "Developer ID Application: Test Person (TEAM00001)" "$DR_STABLE" granted granted
write_record "$DS" B bbbb2222 "Developer ID Application: Test Person (TEAM00001)" "$DR_STABLE" granted granted
run bash "$H" compare --a A --b B --dir "$DS"
expect "G8 identical identifier-and-team requirements -> layer 1 passes" 0 "PASS: identical, identifier-and-team shaped"
if printf '%s' "$OUT" | grep -Fq "THIS IS THE MECHANISM, NOT THE ACCEPTANCE TEST"; then
  ok "G9 ...and refuses to let layer 1 be read as the acceptance test"
else
  bad "G9 layer 1 passed without saying what it is not" ""
fi

write_record "$DS" C cccc3333 "Developer ID Application: Test Person (TEAM00001)" "$DR_OTHER" granted granted
run bash "$H" compare --a A --b C --dir "$DS"
expect "G10 requirements that differ -> FAIL" 1 "designated requirements DIFFER"

write_record "$DS" D dddd4444 "Developer ID Application: Test Person (TEAM00001)" "$DR_STABLE" denied granted
run bash "$H" compare --a A --b D --dir "$DS"
expect "G11 a grant held by N and not by N+1 -> FAIL" 1 "is not held by"

write_record "$DS" E eeee5555 "Developer ID Application: Test Person (TEAM00001)" "$DR_STABLE" unreadable unreadable
run bash "$H" compare --a A --b E --dir "$DS"
expect "G12 an unreadable TCC database -> INCOMPLETE, never a guessed pass" 4 "UNREADABLE — and that is reported rather than guessed at"

run bash "$H" compare --a A --b B --dir "$DS"
expect "G13 layer 3 is always named as not machine-checkable" 0 "NOT MACHINE-CHECKABLE"

run bash "$H" status --dir "$TMP/empty"
if [ "$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application:' || true)" -eq 0 ]; then
  expect "G14 status with no certificate -> exit 4, naming what the test needs" 4 "THIS TEST CANNOT PASS YET"
else
  ok "G14 SKIPPED-BY-FACT: this machine now HAS a Developer ID identity, so the no-certificate verdict is not reachable here"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== rebuild-survival tests: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== rebuild-survival tests: all $PASS passed ==="
