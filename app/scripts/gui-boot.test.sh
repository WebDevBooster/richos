#!/usr/bin/env bash
#
# gui-boot.test.sh — boot the shipped binary the way LaunchServices boots it, and hold
# every line it prints to account.
#
# =========================================================================================
# THE DEFECT THIS EXISTS TO MAKE UNSHIPPABLE
# =========================================================================================
#
# One premise failure — a component reading its configuration out of an environment a Finder
# double-click does not have — was found and fixed THREE TIMES on 2026-09-01:
#
#   970ac5e  the engine directory:  current_dir()/../engine  ->  "/../engine" under cwd=/
#   c179cc1  the loro READ path:    LORO_CORPUS / LORO_ROOT / RICHOS_LORO_DIR, all unset
#   49e2cd4  the loro WRITE path:   CliLoroWriter::from_env(), the same three, still unset
#
# Every one was found by RUNNING the app, never by reading it. Every one shipped working for
# developers and dead for the CEO, because a developer's shell has the variables and his
# launch has `HOME`, `USER`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else.
#
# The job is not to make the fourth instance easier to find. It is to make it impossible to
# ship.
#
# =========================================================================================
# WHY THIS IS NOT A LIST OF THINGS THAT CAN GO WRONG
# =========================================================================================
#
# The obvious check is an inventory: every environment variable a component reads, listed,
# with an assertion that each has a non-environment fallback. `run-tests.sh` twelve lines up
# from here warns about exactly that shape in its own words — this repository has shipped the
# drift defect five times, and it shipped it again on 2026-09-01 when a sandbox file list was
# found five guards behind. A hand-maintained list that stops matching produces a SHORTER
# list, silently, and everything looks greener than it did.
#
# So nothing here is keyed by a variable name, and nothing here enumerates failures. The
# check boots a real process and accounts for its real output, under one rule:
#
#     EVERY LINE OF THE BOOT LOG IS EITHER PROOF THAT SOMETHING RESOLVED, A ROUTINE FACT,
#     OR A DECLARED GAP. ANYTHING ELSE IS A FAILURE.
#
# The asymmetry is the whole point. When a fourth resolver is added and it cannot find its
# configuration on a Finder launch, it prints a sentence saying so — and that sentence
# matches no rule below, so this check goes RED without anyone having remembered to extend
# it. Drift makes the UNACCOUNTED list LONGER, never shorter. There is no way for this to
# fail open.
#
# =========================================================================================
# THE LIMIT, NAMED RATHER THAN LEFT TO BE DISCOVERED
# =========================================================================================
#
# A seam that fails SILENTLY — resolves nothing and prints nothing at all — is invisible
# here, exactly as it is invisible to a human reading the same log. This check raises the
# floor from "somebody has to notice" to "the machine notices anything that speaks"; it does
# not conjure a signal that was never emitted. `S1` below is the half of that gap that CAN
# be closed mechanically: every operator line in the shell carries the `[richos]` prefix, so
# scoping the accounting to that prefix loses nothing.
#
# =========================================================================================
# CASES
# =========================================================================================
#
#   S1  every eprintln! in src-tauri outside its tests carries the [richos] prefix
#   A1  a line no rule accounts for FAILS, and the line is printed
#   A2  a RESOLVED rule with no matching line FAILS — silence is not success
#   A3  a declared gap passes AND its reason is printed where a reviewer sees it
#   A4  a gap declared with no reason is REFUSED — a bare marker declares nothing
#   A5  an empty log FAILS, never "all 0 lines accounted for"
#   B1  the healthy machine boots to completion under launchd's environment
#   B2  ...and every line of that boot is accounted for  <- THE POSITIVE HALF
#   B3  engine pointer removed          -> RED           <- and five negative halves,
#   B4  corpus pointer removed          -> RED              each proving that the detector
#   B5  loro tools removed              -> RED              for one seam is alive on this
#   B6  the claude stand-in removed     -> RED              run and not a corpse
#   B7  the saved company removed       -> RED
#
# B3-B7 break the MACHINE, not the source, so they run on every invocation in seconds. The
# proof that this check catches the three HISTORICAL defects — the source premises put back
# one at a time — is a one-off and its red output is committed under
# `docs/verification/gui-boot-check-2026-09-01/`.
#
# macOS only, for the reason run-tests.sh gives: launchd's environment is the thing under
# test and it does not exist elsewhere.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "gui-boot.test.sh: the condition under test is launchd's environment on macOS." >&2
  echo "                  (uname -s reports $(uname -s).) Refusing to report a result." >&2
  exit 3
fi

# =========================================================================================
# THE RULES
# =========================================================================================
#
# Three classes, and the class is the claim being made about the line.

DECL_ERRORS=0

RESOLVED_ID=(); RESOLVED_RE=(); RESOLVED_WHY=()
ROUTINE_RE=();  ROUTINE_WHY=()
GAP_ID=();      GAP_RE=();      GAP_WHY=()

# resolved <id> <extended-regex> <what it proves>
#
# A line that PROVES a configuration was found, naming what was found. It must match at
# least once in a healthy boot; its absence is a failure on its own, because the way all
# three historical defects presented was a success line that stopped appearing.
resolved() { RESOLVED_ID+=("$1"); RESOLVED_RE+=("$2"); RESOLVED_WHY+=("$3"); }

# routine <extended-regex> <why it proves nothing>
#
# A line that is fine and carries no claim about configuration.
routine() { ROUTINE_RE+=("$1"); ROUTINE_WHY+=("$2"); }

# gap <id> <extended-regex> <reason>
#
# A KNOWN OPEN GAP: a line that says a configuration is missing, on a machine where it
# genuinely cannot be supplied, because nothing installs the thing yet. Declaring one is a
# claim that the gap is real and unfixable today, so the reason is MANDATORY and is printed
# in the run's output where a reviewer sees it — the discipline `dialect-exempt:` uses. A
# bare marker declares nothing.
gap() {
  if [ -z "${3:-}" ] || [ -z "$(printf '%s' "${3:-}" | tr -d '[:space:]')" ]; then
    printf 'gui-boot.test.sh: gap "%s" was declared with NO REASON — refusing it. A gap is a\n' "$1" >&2
    printf '                  claim that a missing configuration is unfixable today; state why\n' >&2
    printf '                  or fix it.\n' >&2
    DECL_ERRORS=$((DECL_ERRORS + 1))
    return 1
  fi
  GAP_ID+=("$1"); GAP_RE+=("$2"); GAP_WHY+=("$3")
  return 0
}

declare_rules() {
  RESOLVED_ID=(); RESOLVED_RE=(); RESOLVED_WHY=()
  ROUTINE_RE=();  ROUTINE_WHY=()
  GAP_ID=();      GAP_RE=();      GAP_WHY=()

  # -- the five things a launch has to find ----------------------------------------------
  # Each regex demands the RESOLVED shape and not merely the topic word: `engine directory:`
  # is printed on both paths, and the failing one reads `NOT FOUND - N place(s) tried`
  # (engine.rs::describe), which this does not match and which nothing else matches either.
  resolved 'engine directory' \
    '^\[richos\] engine directory: /.+ \(via .+\)$' \
    'the working directory claude is started in (engine.rs, 970ac5e)'

  resolved 'compute lease' \
    '^\[richos\] compute lease attached over .+$' \
    'a claude binary was found AND answered the initialize handshake (native.rs)'

  resolved 'loro read half' \
    '^\[richos\] loro Tier C: compiling from .+ \(via .+\), node .+$' \
    'the corpus and the compiler that reads it (loro.rs, c179cc1)'

  resolved 'loro write half' \
    '^\[richos\] loro correction desk: writing to .+ via .+$' \
    'the corpus a confirmed correction is written to (correction.rs, 49e2cd4)'

  resolved 'company' \
    '^\[richos\] company: .+ \(via .+\)$' \
    'the entity this launch files work under (main.rs::boot_entity)'

  # -- lines that are facts about the launch, not about configuration ---------------------
  routine '^\[richos\] launch: [a-z-]+ \([0-9]+ window\(s\)\)$' \
    'which kind of start this is; carries no claim about anything being found'
  routine '^\[richos\] boot complete' \
    'the terminator, printed by setup as its last act'
  routine '^\[richos\] loro lane: no lane narrowing in force' \
    'an unpartitioned corpus, which is a shape rather than a missing setting'
  routine '^\[richos\] loro corpus: in-repo layout at .+ - this is .+ own' \
    'whose record an in-repo corpus is; a statement about ownership, not resolution'

  # -- the declared gaps ------------------------------------------------------------------
  gap 'RICHOS_SERVICE_BIN' \
    '^\[richos\] no RICHOS_SERVICE_BIN' \
    'CliVocabulary::from_env (staging.rs:187) is the same environment-only premise as the
       three defects above, and it is left open ON PURPOSE: nothing installs a vocabulary
       service, so there is no second candidate to fall back TO. Inventing a path here
       would be a fabricated fix. Confirming a spoken correction reports that it has
       nowhere to write, which is the honest behavior. CLOSE THIS by deciding where the
       vocabulary service ships from, then delete this declaration and the check turns
       red until the boot line goes away.'
}

# =========================================================================================
# THE ACCOUNTING
# =========================================================================================
#
# gui_account <log-file>
#
# Exit 0 when every `[richos]` line is accounted for AND every RESOLVED rule matched.
# Exit 1 otherwise. Prints a full report either way, because a check whose failure output
# does not name the line is a check somebody has to reproduce by hand.
gui_account() {
  local log="$1"
  local problems=0

  if [ ! -s "$log" ]; then
    echo "    NOTHING TO ACCOUNT FOR: $log is empty. A boot that printed nothing did not"
    echo "    boot; this is a failure, not a clean sheet."
    return 1
  fi

  local richos_lines
  richos_lines="$(grep -c '^\[richos\]' "$log" 2>/dev/null || true)"
  if [ "${richos_lines:-0}" -eq 0 ]; then
    echo "    NOTHING TO ACCOUNT FOR: $log has no [richos] lines at all."
    return 1
  fi

  # -- every line is classified, and unknown is a failure ---------------------------------
  local line i matched
  while IFS= read -r line; do
    matched=""
    for i in "${!RESOLVED_RE[@]}"; do
      if printf '%s\n' "$line" | grep -Eq -- "${RESOLVED_RE[$i]}"; then matched="resolved:${RESOLVED_ID[$i]}"; break; fi
    done
    if [ -z "$matched" ]; then
      for i in "${!ROUTINE_RE[@]}"; do
        if printf '%s\n' "$line" | grep -Eq -- "${ROUTINE_RE[$i]}"; then matched="routine"; break; fi
      done
    fi
    if [ -z "$matched" ]; then
      for i in "${!GAP_RE[@]}"; do
        if printf '%s\n' "$line" | grep -Eq -- "${GAP_RE[$i]}"; then matched="gap:${GAP_ID[$i]}"; break; fi
      done
    fi
    if [ -z "$matched" ]; then
      echo "    UNACCOUNTED  $line"
      problems=$((problems + 1))
    fi
  done < <(grep '^\[richos\]' "$log")

  # -- and every RESOLVED rule has to have been satisfied ---------------------------------
  # The three historical defects all presented as an ABSENT success line. A check that only
  # looked for bad sentences would have passed c6cf4ea, where the write half printed nothing
  # at all.
  for i in "${!RESOLVED_RE[@]}"; do
    if ! grep -Eq -- "${RESOLVED_RE[$i]}" "$log"; then
      echo "    NOT RESOLVED  ${RESOLVED_ID[$i]} — nothing in this boot proved it was found."
      echo "                  It should have said: ${RESOLVED_WHY[$i]}"
      problems=$((problems + 1))
    fi
  done

  # -- the gaps, printed WHERE A REVIEWER SEES THEM ---------------------------------------
  for i in "${!GAP_ID[@]}"; do
    if grep -Eq -- "${GAP_RE[$i]}" "$log"; then
      echo "    DECLARED GAP  ${GAP_ID[$i]}"
      # Reflowed, because a declaration a reviewer has to squint at is a declaration a
      # reviewer skips, and skipping it is the whole failure mode a gap declaration exists
      # to prevent.
      printf '%s\n' "${GAP_WHY[$i]}" | tr -s '[:space:]' ' ' | fold -s -w 84 \
        | sed 's/^ *//; s/^/                  /'
    fi
  done

  # -- anything that is not ours is shown, never silently dropped -------------------------
  local foreign
  foreign="$(grep -v '^\[richos\]' "$log" | grep -v '^$' || true)"
  if [ -n "$foreign" ]; then
    echo "    OUT OF SCOPE (not [richos] lines; S1 proves the shell prints none of these):"
    printf '%s\n' "$foreign" | sed 's/^/      /'
  fi

  [ "$problems" -eq 0 ] && return 0
  return 1
}

# =========================================================================================
# S1 — the prefix, so scoping the accounting to it loses nothing
# =========================================================================================

SCAN_AWK="$(mktemp -t gui-boot-scan.XXXXXX)"
cat > "$SCAN_AWK" <<'AWK'
# Stop at the test module: a test's own output never reaches a boot log.
/^#\[cfg\(test\)\]/ { exit }
/eprintln!\(/ { want = 1 }
{
  if (want) {
    i = index($0, "eprintln!(")
    rest = (i > 0) ? substr($0, i + 10) : $0
    q = index(rest, "\"")
    if (q > 0) {
      lit = substr(rest, q + 1)
      if (substr(lit, 1, 8) != "[richos]") printf "%s:%d: %s\n", FILENAME, FNR, substr(lit, 1, 70)
      want = 0
    }
  }
}
AWK

STRAY="$(cd "$APP_DIR/src-tauri/src" && awk -f "$SCAN_AWK" ./*.rs 2>/dev/null)"
if [ -z "$STRAY" ]; then
  ok "S1 every operator line in src-tauri carries the [richos] prefix"
else
  bad "S1 every operator line in src-tauri carries the [richos] prefix" \
      "these would be invisible to the accounting below: $(printf '%s' "$STRAY" | tr '\n' ' ')"
fi
rm -f "$SCAN_AWK"

# =========================================================================================
# A1-A5 — the accounting itself, driven against logs built by hand
# =========================================================================================
#
# These are instant and they are the reason the boot cases below can be trusted: they prove
# the detector reacts, and reacts for the stated reason, rather than being a function that
# returns 0.

TMP="$(mktemp -d -t gui-boot-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A healthy log, written out here so A1/A2 differ from it by exactly one line.
healthy_log() {
  cat <<'LOG'
[richos] launch: fresh (1 window(s))
[richos] company: femcboost (via the saved choice)
[richos] loro Tier C: compiling from /m/corpus (via the corpus pointer in Application Support), node /opt/homebrew/bin/node
[richos] loro correction desk: writing to /m/corpus via /m/loro-tools/bin/loro-write.mjs (the same install the compiler above resolved)
[richos] engine directory: /m/.claude/richos-engine (via engine install pointer)
[richos] compute lease attached over /m/.local/bin/claude
[richos] no RICHOS_SERVICE_BIN — spoken corrections will be recorded and asked
[richos] boot complete — every line above is what this launch resolved
LOG
}

declare_rules
healthy_log > "$TMP/healthy.log"
if OUT="$(gui_account "$TMP/healthy.log" 2>&1)"; then
  ok "A0 the hand-written healthy log is accepted (the fixture the next four vary)"
else
  bad "A0 the hand-written healthy log is accepted" "$(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# A1 — the fourth instance, simulated. A new seam that cannot find its configuration prints
# a sentence nobody wrote a rule for.
{ healthy_log; echo "[richos] voice profile: no RICHOS_VOICE_DIR — dictation will not start"; } > "$TMP/a1.log"
OUT="$(gui_account "$TMP/a1.log" 2>&1)"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'UNACCOUNTED.*RICHOS_VOICE_DIR'; then
  ok "A1 a line no rule accounts for fails, and the line is printed verbatim"
else
  bad "A1 a line no rule accounts for fails" "exit $CODE; output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
fi

# A2 — the shape all three historical defects actually had: not a bad sentence, an ABSENT
# good one. `c6cf4ea` printed no write-half line at all.
healthy_log | grep -v 'correction desk: writing to' > "$TMP/a2.log"
OUT="$(gui_account "$TMP/a2.log" 2>&1)"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'NOT RESOLVED  loro write half'; then
  ok "A2 a missing success line fails — silence is not success"
else
  bad "A2 a missing success line fails" "exit $CODE; output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
fi

# A3 — the declaration is visible, not merely tolerated.
OUT="$(gui_account "$TMP/healthy.log" 2>&1)"; CODE=$?
# Whitespace-normalized on both sides: the reason is REFLOWED for a reader, so asserting on
# a raw line would be asserting on the wrapping rather than on the words.
FLAT="$(printf '%s' "$OUT" | tr -s '[:space:]' ' ')"
if [ "$CODE" -eq 0 ] \
  && printf '%s' "$FLAT" | grep -q 'DECLARED GAP RICHOS_SERVICE_BIN' \
  && printf '%s' "$FLAT" | grep -q 'nothing installs a vocabulary service'; then
  ok "A3 a declared gap passes and its reason is printed where a reviewer sees it"
else
  bad "A3 a declared gap prints its reason" "exit $CODE; output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
fi

# A4 — a bare marker declares nothing.
DECL_ERRORS=0
if gap 'BARE' '^\[richos\] whatever' '   ' 2>/dev/null; then
  bad "A4 a gap with no reason is refused" "it was accepted"
elif [ "$DECL_ERRORS" -eq 1 ]; then
  ok "A4 a gap declared with no reason is refused"
else
  bad "A4 a gap with no reason is refused" "refused but did not record the refusal"
fi
declare_rules   # the refused declaration must not linger in the rule set

# A5 — an empty log is a failure.
: > "$TMP/a5.log"
if gui_account "$TMP/a5.log" >/dev/null 2>&1; then
  bad "A5 an empty log fails" "it passed"
else
  ok "A5 an empty log fails, never 'all 0 lines accounted for'"
fi

# =========================================================================================
# B1-B7 — the real thing
# =========================================================================================

if ! command -v cargo >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    PATH="$HOME/.cargo/bin:$PATH"; export PATH
  else
    echo "gui-boot.test.sh: no cargo on PATH — the binary under test cannot be built." >&2
    echo "                  Refusing to report a result over an artifact this run did not make." >&2
    exit 2
  fi
fi

echo "  ... building richos-tauri (the artifact under test is built here, never assumed)"
if ! ( cd "$APP_DIR/src-tauri" && cargo build --quiet --bin richos-tauri ); then
  echo "gui-boot.test.sh: richos-tauri did not build. Refusing to report a boot result." >&2
  exit 2
fi

GUI_APP_DIR="$APP_DIR"
GUI_ENGINE_DIR="$REPO_DIR/engine"
GUI_BINARY="$APP_DIR/src-tauri/target/debug/richos-tauri"
export GUI_APP_DIR GUI_ENGINE_DIR GUI_BINARY
# shellcheck source=lib/gui-launch.sh
. "$DIR/lib/gui-launch.sh"

MACHINE="$TMP/machine"
if MOUT="$(gui_machine "$MACHINE" 2>&1)"; then
  ok "B0 a complete machine was built (corpus, tools, engine pointer, claude, saved company)"
  printf '%s\n' "$MOUT" | sed 's/^/         /'
else
  echo "gui-boot.test.sh: could not build the machine to boot on:" >&2
  printf '%s\n' "$MOUT" | sed 's/^/  /' >&2
  echo "                  That is a fact about THIS MACHINE, not a verdict about the code." >&2
  exit 2
fi

# B1/B2 — the positive half.
if gui_boot "$MACHINE" "$TMP/healthy-boot.log" 60; then
  ok "B1 the healthy machine boots to completion under launchd's environment"
else
  bad "B1 the healthy machine boots to completion" "$(tail -3 "$TMP/healthy-boot.log" | tr '\n' ' ')"
fi
echo "  --- the boot log, as captured ---"
sed 's/^/      /' "$TMP/healthy-boot.log"
echo "  --- accounting ---"
if OUT="$(gui_account "$TMP/healthy-boot.log" 2>&1)"; then
  printf '%s\n' "$OUT"
  ok "B2 every line of a healthy Finder-condition boot is accounted for"
else
  printf '%s\n' "$OUT"
  bad "B2 every line of a healthy Finder-condition boot is accounted for" "see the report above"
fi

# B3-B7 — the negative halves. One configuration removed from the machine at a time. Each
# proves that the detector for THAT seam is alive on this run: a check that only ever sees a
# healthy boot is a check that would keep passing after it stopped working.
break_and_boot() {   # break_and_boot <name> <case-id> <what-to-remove-cmd...>
  local name="$1" id="$2"; shift 2
  local broken="$TMP/broken-$id"
  rm -rf "$broken"
  cp -a "$MACHINE" "$broken" || { bad "$id $name" "could not copy the machine"; return; }
  ( cd "$broken" && "$@" ) || { bad "$id $name" "could not break the machine"; return; }
  gui_boot "$broken" "$TMP/broken-$id.log" 60
  if gui_account "$TMP/broken-$id.log" >"$TMP/broken-$id.report" 2>&1; then
    bad "$id $name" "the check PASSED a machine with this missing. Report: $(tr '\n' ' ' < "$TMP/broken-$id.report" | cut -c1-200)"
  else
    ok "$id $name"
    grep -E 'UNACCOUNTED|NOT RESOLVED' "$TMP/broken-$id.report" | head -4 | sed 's/^/       /'
  fi
}

break_and_boot "the engine pointer is removed -> caught"      B3 rm -f  .claude/richos-engine
break_and_boot "the corpus pointer is removed -> caught"      B4 rm -rf "Library/Application Support/RichOS/corpus" RichOS
break_and_boot "the loro tools are removed -> caught"         B5 rm -rf "Library/Application Support/RichOS/loro-tools"
break_and_boot "the claude stand-in is removed -> caught"     B6 rm -f  .local/bin/claude
break_and_boot "the saved company is removed -> caught"       B7 rm -f  "Library/Application Support/com.richos.app/config.json"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== gui-boot.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== gui-boot.test.sh: all $PASS passed ==="
