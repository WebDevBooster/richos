#!/usr/bin/env bash
#
# gui-proof-in-vm.sh — watch a candidate's own bundle start, in a guest, and write down
#                      what was seen, so `nightly-local.py publish` has something to check.
#
#   gui-proof-in-vm.sh --run <run-id> [--vm <name>] [--out <path>] [--keep]
#   gui-proof-in-vm.sh --bundle <RichOS.app.zip> --commit <sha> [--vm <name>] [--out <path>]
#
# =========================================================================================
# WHY THIS EXISTS
# =========================================================================================
#
# The CEO, 2026-09-19: *"So, every engineer will keep opening the app making me unable to do
# anything here or WHAT???"*
#
# `nightly-local.py build --no-host-screen` answers that by holding back every suite that
# boots the app, so a candidate is built, signed, notarized and walkable without one pixel
# reaching his Mac. The price is that nobody has watched the thing start. `publish` refuses
# such a candidate until `--gui-proof` names evidence that somebody did, and THIS is what
# produces that evidence — inside a `testvm` guest, on the guest's own virtual display,
# with nothing on the host's screen.
#
# =========================================================================================
# WHAT THIS PROVES, AND WHAT IT DOES NOT — the distinction is the whole value of the file
# =========================================================================================
#
# It boots THE ARTIFACT THE RELEASE WILL PUBLISH: the signed, notarized, stapled bundle out
# of the candidate's own staging directory, on a clean macOS 15 guest with no developer
# environment, no cargo, no repository and no `~/.claude` of the operator's. That is closer
# to a customer's first run than anything on a developer's Mac can be, and it is the
# question `publish` actually needs answered: does the thing about to become installable
# start, and does it draw a window.
#
# IT IS NOT `gui-boot.test.sh`, AND IT DOES NOT CLAIM TO BE. That suite builds a debug
# binary from the checkout and asserts B0-B8 and C1-C5 over a synthetic machine — engine
# resolution through candidate 6, the Info.plist's shape, the company registry, the corpus
# pointer. This file asserts one thing about a different artifact. So the proof it writes
# says `suite=shipped-bundle-boot`, never `suite=gui-boot.test.sh`, and `publish` accepts
# either while recording which it got. A proof that borrowed the other's name would be the
# most useful lie in the release chain.
#
# =========================================================================================
# THE GARBAGE (CEO ruling §54) AND THE HOST'S SCREEN
# =========================================================================================
#
# The guest clone, the app inside it and the fixture home are all garbage the moment the
# verdict is read, and every one of them is cleaned up however this script ends — including
# on INT and TERM. Where cleanup fails it SAYS SO LOUDLY and names what to delete by hand,
# rather than exiting 0 over a 25 GB surprise.
#
# Nothing here touches the host's display, power, session or input state: no `pmset`, no
# `caffeinate`, no keystroke, no `open` on this machine. The app is launched, watched and
# killed inside the guest, by pid (`testvm/stop.sh`'s own rule, written after a Command-Q
# through System Events landed on the CEO's Terminal).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTVM="$HERE/testvm"
STATE_DIR="${RICHOS_NIGHTLY_STATE:-$HOME/.richos-nightly}"

RUN_ID=""; BUNDLE=""; COMMIT=""; VM=""; OUT=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run)    RUN_ID="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --vm)     VM="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "gui-proof-in-vm.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "gui-proof-in-vm.sh: $*" >&2; exit 2; }

[ "$(uname -s)" = "Darwin" ] || die "the guest harness is macOS virtualization; this is $(uname -s)."
[ -x "$TESTVM/run.sh" ]  || die "no $TESTVM/run.sh — run testvm/setup.sh first (see docs/testvm.md)."
[ -x "$TESTVM/stop.sh" ] || die "no $TESTVM/stop.sh; refusing to start a guest I cannot clean up."

# ---------------------------------------------------------------------------------------
# Which candidate, and which commit it was built from
# ---------------------------------------------------------------------------------------
if [ -n "$RUN_ID" ]; then
  [ -z "$BUNDLE" ] || die "--run and --bundle name the same thing two ways; give one."
  POINTER="$STATE_DIR/runs/$RUN_ID.json"
  [ -f "$POINTER" ] || die "no recorded build for run $RUN_ID at $POINTER; run \`nightly-local.py build\` first."
  CAND_DIR="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["out"])' "$POINTER")" \
    || die "$POINTER is not readable as a run pointer"
  CANDIDATE="$CAND_DIR/candidate.json"
  [ -f "$CANDIDATE" ] || die "$CAND_DIR has no candidate.json; the build for run $RUN_ID did not finish."
  # THE COMMIT IS READ OUT OF THE CANDIDATE, never passed in beside it. A sha a caller
  # types is a sha a caller can mistype, and the one thing `publish` checks is that this
  # proof is about THAT tree.
  eval "$(/usr/bin/python3 - "$CANDIDATE" <<'PY'
import json, shlex, sys
info = json.load(open(sys.argv[1]))["info"]
commit = info.get("build_commit") or info["source_commit"]
print(f"COMMIT={shlex.quote(commit)}")
print(f"VERSION={shlex.quote(info['version'])}")
print(f"TAG={shlex.quote(info['tag'])}")
PY
)" || die "could not read $CANDIDATE"
  # make-release.sh's own ARCH mapping; this Mac is Apple Silicon only.
  BUNDLE="$CAND_DIR/RichOS-$VERSION-macos-aarch64.zip"
  [ -f "$BUNDLE" ] || die "the candidate has no first-install archive at $BUNDLE"
else
  [ -n "$BUNDLE" ] || die "one of --run <run-id> or --bundle <zip> is required."
  [ -e "$BUNDLE" ] || die "no such bundle: $BUNDLE"
  [ -n "$COMMIT" ] || die "--bundle needs --commit <sha>: a proof that does not name the tree it was taken against proves nothing about any particular one."
  TAG="${TAG:-unversioned}"
fi

[ -n "$VM" ] || VM="richos-gui-proof-$$"
[ -n "$OUT" ] || OUT="$STATE_DIR/gui-proofs/${RUN_ID:-$COMMIT}.proof"
mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"

# ---------------------------------------------------------------------------------------
# Scratch, and the promise that none of it outlives this script (CEO ruling §54)
# ---------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/richos-gui-proof.XXXXXX")" || die "cannot create a scratch directory"
STOPPED=0
cleanup() {
  local rc=$?
  if [ "$STOPPED" = 0 ] && [ "$KEEP" = 0 ]; then
    STOPPED=1
    echo "gui-proof-in-vm.sh: stopping the guest and deleting the clone..."
    if ! "$TESTVM/stop.sh" "$VM" >"$WORK/stop.log" 2>&1; then
      # LOUD, never a footnote. A failed cleanup that exits quietly is how 105 GB sat in
      # $TMPDIR overnight, which is the incident §54 was written for.
      echo "" >&2
      echo "  ############################################################" >&2
      echo "  ##  CLEANUP FAILED — THERE IS A GUEST LEFT ON THIS MAC    ##" >&2
      echo "  ############################################################" >&2
      echo "  The clone '$VM' and/or the app inside it did not stop. Delete it by hand:" >&2
      echo "      $TESTVM/stop.sh $VM" >&2
      echo "      $TESTVM/reap.sh" >&2
      sed 's/^/      /' "$WORK/stop.log" >&2 2>/dev/null
      echo "" >&2
    fi
  elif [ "$KEEP" = 1 ]; then
    echo "gui-proof-in-vm.sh: --keep, so the guest '$VM' is still running. Stop it with:"
    echo "    $TESTVM/stop.sh $VM"
  fi
  rm -rf "$WORK"
  return $rc
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# A fixture HOME: empty, and OUTSIDE the operator's own. The app under test must not read
# or write anything of his (README.md's activation invariant D), and a first run on an
# empty home is the shape a customer's first run has.
FIXTURE="$WORK/home"
mkdir -p "$FIXTURE"

echo "gui-proof-in-vm.sh: booting ${TAG:-the bundle} in guest '$VM'"
echo "  bundle : $BUNDLE"
echo "  commit : $COMMIT"
echo "  nothing here opens a window on this Mac; the display is the guest's."
echo ""

RESULT="fail:no-window"
WINDOWS=0
if "$TESTVM/run.sh" --bundle "$BUNDLE" --home "$FIXTURE" --vm "$VM" > "$WORK/run.out" 2>&1; then
  # `run.sh` prints `windows=N`, and N is the point: a pid is not a proof, because the app
  # can be running and drawing nothing — which is precisely the state a screenshot would
  # photograph and call a pass (run.sh's own words).
  WINDOWS="$(sed -n 's/.*windows=\([0-9][0-9]*\).*/\1/p' "$WORK/run.out" | tail -1)"
  [ -n "$WINDOWS" ] || WINDOWS=0
  if [ "$WINDOWS" -ge 1 ]; then
    RESULT="pass"
  fi
else
  RESULT="fail:run.sh"
fi
cat "$WORK/run.out"

{
  echo "richos-gui-proof 1"
  echo "suite=shipped-bundle-boot"
  echo "commit=$COMMIT"
  echo "where=vm:$VM"
  echo "result=$RESULT"
  echo "windows=$WINDOWS"
  echo "bundle=$(basename "$BUNDLE")"
  echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "--- output ---"
  cat "$WORK/run.out" 2>/dev/null
} > "$OUT"

echo ""
if [ "$RESULT" = "pass" ]; then
  echo "  PASS  the candidate's own signed bundle started in a clean guest and drew $WINDOWS window(s)"
  echo "  proof: $OUT"
  echo ""
  echo "  nightly-local.py publish --run ${RUN_ID:-<run-id>} --gui-proof $OUT"
  exit 0
fi
echo "  FAIL  the candidate's bundle did not reach a window in the guest ($RESULT)"
echo "        The proof records the failure rather than deleting it: $OUT"
echo "        publish will refuse it, which is the correct outcome for a bundle that"
echo "        does not start. Read the run output above and the guest's own app.log."
exit 1
