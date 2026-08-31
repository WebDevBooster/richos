#!/usr/bin/env bash
# THE ACCEPTANCE TEST THAT MATTERS — do microphone and accessibility survive the
# NEXT build? A build that has only ever been installed once has never tested the
# thing that breaks.
#
#   app/scripts/rebuild-survival.sh status
#   app/scripts/rebuild-survival.sh record <path/to/RichOS.app> --label N
#   app/scripts/rebuild-survival.sh compare --a N --b N+1
#
# WHAT IS BEING TESTED, and why installing once cannot test it
# ------------------------------------------------------------
# macOS's privacy database (TCC) does not store "RichOS may use the microphone".
# It stores a DESIGNATED REQUIREMENT — a code-signing expression — and grants the
# permission to whatever satisfies it. Under ad-hoc signing that expression is a
# hash of the build, so the next build satisfies nothing and starts at zero. Under
# a Developer ID signature it is
#
#     identifier "com.richos.app" and anchor apple generic
#       and certificate leaf[subject.OU] = "<TEAMID>"
#
# which every future build satisfies. Measured on the CEO's Mac 2026-08-24:
# rebuild cdhash a343d887… reported Accessibility "not granted" in the same minute
# a differently-hashed build reported "granted", and toggling the switch in System
# Settings provably did not migrate it. richos-hq/wiki/packaging-and-signing.md.
#
# So the test is: install N, grant both, install N+1, and confirm both still hold
# WITH ZERO USER INTERACTION.
#
# THREE LAYERS, AND THEY ARE NOT EQUALLY AUTOMATABLE. Saying so is the point of
# this file; a harness that reported one layer's result as the whole answer would
# be the same defect as a build reporting an exit code as an artefact.
#
#   Layer 1  THE MECHANISM, fully automatic, and decisive when it FAILS.
#            The designated requirement of N and of N+1, read off the bundles.
#            If they differ, or either is a cdhash expression, the grants CANNOT
#            survive and no amount of clicking will change it. This layer needs no
#            privileges and no human, and it is the layer that catches the mistake
#            people actually make.
#
#   Layer 2  THE DATABASE, automatic ONLY with Full Disk Access. The microphone
#            row lives in the user TCC.db and the accessibility row in the
#            SIP-protected system one. Both are readable — by a process the
#            operator has granted Full Disk Access. The terminal running this
#            usually has not, so this layer reports UNREADABLE rather than
#            guessing, and says exactly what would make it readable.
#
#   Layer 3  ZERO USER INTERACTION, irreducibly human. "No dialog appeared" is not
#            a fact any database holds; it is a thing a person saw not happen.
#            This harness prints the two things to try and takes the answer.
#
# Layer 1 passing is NOT the acceptance test passing. It is the mechanism being in
# place. The file says so in its own verdicts rather than leaving it to be inferred.
#
# Exit codes: 0 the comparison passed (all layers that could run, ran, and agreed).
# 1 it FAILED — the grants did not or cannot survive. 2 refused. 4 INCOMPLETE: not
# enough evidence exists yet to say either way, and what is missing is named.
set -uo pipefail

state_dir="${RICHOS_SURVIVAL_DIR:-$HOME/.richos-signing/rebuild-survival}"
cmd="${1:-}"
[ $# -gt 0 ] && shift

label=""
label_a=""
label_b=""
app=""

while [ $# -gt 0 ]; do
  case "$1" in
    --label)   label="${2:-}"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    --a)       label_a="${2:-}"; shift 2 ;;
    --a=*)     label_a="${1#*=}"; shift ;;
    --b)       label_b="${2:-}"; shift 2 ;;
    --b=*)     label_b="${1#*=}"; shift ;;
    --dir)     state_dir="${2:-}"; shift 2 ;;
    --dir=*)   state_dir="${1#*=}"; shift ;;
    -*) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    *)  app="$1"; shift ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

# ---------------------------------------------------------------------------
# Layer 2's honest answer to "can I read this at all".
# ---------------------------------------------------------------------------
tcc_read() {          # tcc_read <db> <service> <client>
  local db="$1" service="$2" client="$3" out
  if [ ! -r "$db" ]; then printf 'unreadable'; return; fi
  command -v sqlite3 >/dev/null 2>&1 || { printf 'no-sqlite3'; return; }
  if ! out="$(sqlite3 "file:$db?immutable=1" \
        "SELECT auth_value FROM access WHERE service='$service' AND client='$client';" 2>&1)"; then
    # "authorization denied" is what a process without Full Disk Access gets, and
    # it is a DIFFERENT fact from "there is no grant". Never collapse the two.
    printf 'unreadable'
    return
  fi
  case "$out" in
    "")  printf 'no-row' ;;
    0)   printf 'denied' ;;
    2|3) printf 'granted' ;;
    *)   printf 'auth_value=%s' "$out" ;;
  esac
}

record_file() { printf '%s/%s.record' "$state_dir" "$1"; }

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
if [ "$cmd" = "status" ] || [ -z "$cmd" ] || [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; then
  if [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; then
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  devid="$(printf '%s\n' "$ids" | grep -c 'Developer ID Application:' || true)"
  say "rebuild-survival — can this machine run the test today?"
  say ""
  say "  Developer ID Application identities : $devid"
  say "  recorded builds                     : $(ls -1 "$state_dir"/*.record 2>/dev/null | wc -l | tr -d ' ') (in $state_dir)"
  mic_state="$(tcc_read "$USER_TCC" kTCCServiceMicrophone com.richos.app)"
  ax_state="$(tcc_read "$SYS_TCC" kTCCServiceAccessibility com.richos.app)"
  say "  TCC microphone row                  : $mic_state"
  say "  TCC accessibility row               : $ax_state"
  say ""
  if [ "$devid" -eq 0 ]; then
    say "VERDICT: THIS TEST CANNOT PASS YET, and not because anything is broken."
    say ""
    say "  The property under test does not exist under ad-hoc signing. An ad-hoc"
    say "  bundle's designated requirement IS its code hash, so build N+1 fails it by"
    say "  construction — there is no arrangement of installs that makes the grants"
    say "  survive, and a 'FAIL' here would be measuring the absence of a certificate."
    say ""
    say "  WHAT IT NEEDS, in order:"
    say "    1. a Developer ID Application certificate on this machine"
    say "         app/scripts/make-signing-csr.sh"
    say "         docs/ceo/developer-id-setup-2026-08-31.md   (the CEO's two steps)"
    say "         app/scripts/install-signing-cert.sh <the .cer>"
    say "    2. TWO Developer ID signed builds that differ by at least one shipped"
    say "       byte — 'rebuild' with identical bytes is not a test: three runs over"
    say "       an unchanged tree produced one cdhash on 2026-08-30."
    say "    3. app icons, so a bundle can be produced at all. package-app.sh refuses"
    say "       on the placeholder set now in the tree (CEO item 2.6, the artwork)."
    say "    4. for layer 2, Full Disk Access for this terminal; otherwise a human"
    say "       answers layer 3 and layer 2 reports UNREADABLE rather than guessing."
    exit 4
  fi
  say "VERDICT: a Developer ID identity exists. Record build N, install it, grant both"
  say "permissions, then record and install N+1 and compare."
  exit 0
fi

# ---------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------
if [ "$cmd" = "record" ]; then
  [ -n "$app" ] || { warn "error: record needs a path to a .app"; exit 2; }
  [ -d "$app" ] || { warn "error: not a bundle directory: $app"; exit 2; }
  [ -n "$label" ] || { warn "error: record needs --label (e.g. --label N)"; exit 2; }

  probe="$state_dir"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
  if inside="$(cd "$probe" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$inside" ]; then
    warn "REFUSING — the record directory is inside a git worktree ($inside)."
    warn "  These records name paths on this machine and are evidence for one run;"
    warn "  they are not repository content. Use --dir, or the default outside every"
    warn "  checkout."
    exit 2
  fi

  mkdir -p "$state_dir" || { warn "error: cannot create $state_dir"; exit 2; }

  desc="$(codesign -dvvv "$app" 2>&1 || true)"
  dr="$(codesign -d -r- "$app" 2>/dev/null | sed -n 's/^# *designated => //p' | head -1)"
  cdhash="$(printf '%s\n' "$desc" | sed -n 's/^CDHash=//p' | head -1)"
  authority="$(printf '%s\n' "$desc" | sed -n 's/^Authority=//p' | head -1)"
  sigkind="$(printf '%s\n' "$desc" | sed -n 's/^Signature=//p' | head -1)"
  ident="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"

  {
    printf 'label: %s\n'      "$label"
    printf 'app: %s\n'        "$app"
    printf 'bundle_id: %s\n'  "$ident"
    printf 'cdhash: %s\n'     "$cdhash"
    printf 'signature: %s\n'  "${sigkind:-none}"
    printf 'authority: %s\n'  "${authority:-none}"
    printf 'designated_requirement: %s\n' "${dr:-none}"
    printf 'tcc_microphone: %s\n'    "$(tcc_read "$USER_TCC" kTCCServiceMicrophone "${ident:-com.richos.app}")"
    printf 'tcc_accessibility: %s\n' "$(tcc_read "$SYS_TCC" kTCCServiceAccessibility "${ident:-com.richos.app}")"
    printf 'recorded: %s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$(record_file "$label")"

  say "recorded build '$label' -> $(record_file "$label")"
  sed 's/^/    /' "$(record_file "$label")"
  say ""
  say "Now INSTALL it, grant microphone and accessibility, and use the app once."
  say "Then build N+1 with at least one shipped byte changed, record it, and:"
  say "    app/scripts/rebuild-survival.sh compare --a $label --b <the next label>"
  exit 0
fi

# ---------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------
if [ "$cmd" = "compare" ]; then
  [ -n "$label_a" ] && [ -n "$label_b" ] || { warn "error: compare needs --a <label> --b <label>"; exit 2; }
  fa="$(record_file "$label_a")"; fb="$(record_file "$label_b")"
  for f in "$fa" "$fb"; do
    [ -f "$f" ] || { warn "error: no record at $f — run 'record' for that build first."; exit 2; }
  done

  get() { sed -n "s/^$2: //p" "$1"; }

  dr_a="$(get "$fa" designated_requirement)"; dr_b="$(get "$fb" designated_requirement)"
  ch_a="$(get "$fa" cdhash)";                 ch_b="$(get "$fb" cdhash)"
  sg_a="$(get "$fa" signature)";              sg_b="$(get "$fb" signature)"
  mic_a="$(get "$fa" tcc_microphone)";        mic_b="$(get "$fb" tcc_microphone)"
  ax_a="$(get "$fa" tcc_accessibility)";      ax_b="$(get "$fb" tcc_accessibility)"

  say "rebuild survival: '$label_a' -> '$label_b'"
  say ""
  say "  LAYER 1 — the mechanism"
  say "    cdhash        $ch_a"
  say "               -> $ch_b"
  say "    requirement   $dr_a"
  say "               -> $dr_b"
  say ""

  fail=0; incomplete=0

  if [ "$ch_a" = "$ch_b" ]; then
    say "    INCONCLUSIVE: both builds have the same cdhash, so they are the SAME"
    say "    application to macOS and no grant was ever at risk. This is not a pass."
    say "    Change a shipped byte and rebuild — measured 2026-08-30, three runs over"
    say "    an unchanged tree all produced cdhash fc5051ac…"
    incomplete=1
  fi

  # AD-HOC IS INCOMPLETE, NOT FAILED, and the distinction is the whole reason this
  # branch is separate. Two ad-hoc builds will always show a cdhash requirement and
  # always lose the grants — but that measures the ABSENCE OF A CERTIFICATE, not a
  # defect in the app or the build. Reporting FAIL there would put a red result
  # against work that is correct, which is how a harness stops being believed.
  adhoc=0
  case "$sg_a$sg_b" in *adhoc*) adhoc=1 ;; esac

  if [ "$adhoc" = 1 ]; then
    say "    CANNOT PASS: at least one build is ad-hoc signed ('$sg_a' / '$sg_b')."
    say "    An ad-hoc designated requirement IS the code hash, so N+1 fails it by"
    say "    construction. The certificate is the fix, not a different install order,"
    say "    and this is reported as INCOMPLETE rather than FAILED because it measures"
    say "    the absence of a certificate and nothing about this build."
    incomplete=1
  elif printf '%s' "$dr_a$dr_b" | grep -q 'cdhash'; then
    say "    FAIL: a designated requirement is a cdhash expression on a build that is"
    say "    NOT ad-hoc signed. macOS binds the grant to that hash and nothing else, so"
    say "    the certificate is present and buying nothing. This one is a real defect."
    fail=1
  elif [ "$dr_a" != "$dr_b" ]; then
    say "    FAIL: the designated requirements DIFFER. Whatever macOS granted to the"
    say "    first expression, the second one does not satisfy. Grants cannot survive."
    fail=1
  elif [ "$dr_a" != "none" ] && [ -n "$dr_a" ]; then
    say "    PASS: identical, identifier-and-team shaped. Every future build satisfies"
    say "    it. THIS IS THE MECHANISM, NOT THE ACCEPTANCE TEST."
  fi

  say ""
  say "  LAYER 2 — the database"
  say "    microphone     $mic_a -> $mic_b"
  say "    accessibility  $ax_a  -> $ax_b"
  if printf '%s' "$mic_a$mic_b$ax_a$ax_b" | grep -q 'unreadable\|no-sqlite3'; then
    say "    UNREADABLE — and that is reported rather than guessed at. The microphone"
    say "    row is in the user TCC database and the accessibility row in the"
    say "    SIP-protected system one; both need Full Disk Access for the process"
    say "    reading them. Grant it to this terminal in System Settings -> Privacy &"
    say "    Security -> Full Disk Access, or answer layer 3 by hand."
    incomplete=1
  elif [ "$mic_b" = "granted" ] && [ "$ax_b" = "granted" ]; then
    say "    PASS: both rows still authorize the new build."
  elif [ "$mic_a" != "granted" ] || [ "$ax_a" != "granted" ]; then
    say "    INCOMPLETE: build '$label_a' did not hold both grants, so there was"
    say "    nothing for '$label_b' to keep. Grant both on the FIRST install."
    incomplete=1
  else
    say "    FAIL: a grant that was held by '$label_a' is not held by '$label_b'."
    fail=1
  fi

  say ""
  say "  LAYER 3 — zero user interaction"
  say "    NOT MACHINE-CHECKABLE, and pretending otherwise is how this test gets"
  say "    reported as passing when it did not. 'No permission dialog appeared' is a"
  say "    thing a person saw not happen. Do these two, in the new build:"
  say "      1. press the talk button and say something — Rich hears it, no prompt;"
  say "      2. use paste-at-cursor / the global hotkey — it works, no prompt."
  say ""

  if [ "$fail" -ne 0 ]; then
    say "VERDICT: FAILED. The permission grants did not survive."
    exit 1
  fi
  if [ "$incomplete" -ne 0 ]; then
    say "VERDICT: INCOMPLETE — no honest pass is available from this evidence. What is"
    say "missing is named above; nothing here is a failure of the app."
    exit 4
  fi
  say "VERDICT: layers 1 and 2 PASSED. The acceptance test is complete only once a"
  say "human has answered layer 3; this harness will not answer it for you."
  exit 0
fi

warn "error: unknown command '$cmd'. Try: status | record | compare  (--help for the argument)"
exit 2
