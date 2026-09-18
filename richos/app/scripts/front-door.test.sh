#!/usr/bin/env bash
#
# front-door.test.sh — drive the SHIPPED window's front door through AppKit, not through an
# automation protocol, and hold the one row `ui/tests` structurally cannot reach.
#
# =========================================================================================
# WHY THIS EXISTS, AND WHY IT IS NOT A CHECK IN `ui/tests`
# =========================================================================================
#
# `ui/tests/escape.js` has ten checks and thirty-nine assertions about the CEO's rule — "the
# user must always be able to close any popup of any kind by simply tapping the escape key"
# (2026-09-17, item 1) — and every one of them is green. Ray then walked the candidate-.9
# bundle and reported the settings menu surviving Escape
# (`docs/verification/2026-09-18-nightly-1.2.0-nightly.20260918.3-onscreen-audit.md` §4).
#
# The two are not in contradiction, because they are not measuring the same thing.
# `page.keyboard.press("Escape")` hands a synthesized event to the page through WebKit's
# automation protocol. The shipped window has no such path: a key travels
#
#     the keyboard (or a CGEvent)  ->  the window server  ->  NSApplication
#       ->  the key window  ->  the WKWebView as first responder  ->  the web content
#       ->  `document`'s keydown listeners
#
# and every arrow in that chain is a place the press can be lost, all of them below the layer
# `escape.js` starts at. Three suites' worth of green says the HANDLER is right; it can never
# say the key arrives. This is the only file in this repository that can.
#
# =========================================================================================
# WHAT READING THE NATIVE TREE WILL AND WILL NOT TELL YOU — measured, 2026-09-18
# =========================================================================================
#
# **System Events reports nodes for subtrees that are `display: none` in the renderer.** This
# is not a suspicion; it was measured both ways on the same build in the same hour.
#
# In the .9 window's own tree, at rest, with nothing open:
#
#     AXGroup | name=Connected repositories
#     AXGroup | name=Allow this action?
#     AXGroup | name=Quit while work is running?
#
# and in the real renderer under WebKit, at the same point in the same page:
#
#     #repositories-sheet  -> { hiddenAttr: true, display: "none" }
#     #permission-sheet    -> { hiddenAttr: true, display: "none" }
#     #quit-question       -> { hiddenAttr: true, display: "none" }
#
# (`[hidden] { display: none !important }`, `style.css:280`, which the app sets precisely
# because several of these declare their own `display`.)
#
# SO A NODE'S PRESENCE IN THAT TREE IS NOT EVIDENCE THAT IT IS ON SCREEN, and a check that
# asserts on presence will report a closed sheet as open. Ray's row 2 rested partly on "the
# tree still returns the sheet's 5 nodes"; that half of it is void, and his screenshots are
# what the row actually stands on. Every assertion below is on the node's SIZE, which is 0x0
# for an unrendered subtree and its real box otherwise.
#
# =========================================================================================
# THE PRECONDITIONS, DECLARED, BECAUSE THIS CHECK IS WORTHLESS WITHOUT THEM
# =========================================================================================
#
# P1  AT LEAST ONE ACTIVE DISPLAY. `gui_display_counts` in `lib/gui-launch.sh` carries the
#     whole diagnosis: macOS ACTIVE means connected, AWAKE and available for drawing, so a
#     Mac whose screens have gone to sleep reports every display ONLINE and NO display
#     ACTIVE, and the app truthfully prints `window: the runtime reported no attached
#     display`. Measured here on 2026-09-18: with the screens asleep this suite's own boot
#     produced exactly that line and `count of windows` 0.
#
# P2  THE SESSION MUST NOT BE LOCKED. This one cost a full measurement before it was found.
#     With `CGSSessionScreenIsLocked = true` the app boots, derives a real geometry on a real
#     monitor — `window: derived 1400x880 pt at (260,102) ... Monitor #30942` — and yet
#     System Events reports `windows: 0` and cannot answer "which process is frontmost" at
#     all. Synthesized keys go nowhere. A run in that state can only produce a false red on
#     every check below.
#
#         $ ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked
#         	<key>CGSSessionScreenIsLocked</key>
#         	<true/>
#
#     CEO ruling 2026-09-18 (§56) is that screen-bound work WAITS for the unlock as a state —
#     it never fails and it never nags. `--wait-for-screen <seconds>` is that wait. Without
#     it, an unmet precondition is a NAMED REFUSAL and exit 2: not a pass, not a failure of
#     the product, and never silence.
#
# P3  `cliclick`. The keys have to come from somewhere outside the app.
#
# P4  THE SCRATCH HOME MUST BE CANONICAL, AND THIS ONE IS NOT ABOUT THE MACHINE — IT IS
#     ABOUT WHAT THIS FILE PUTS ON THE PERSON'S SCREEN. This harness asks for
#     `RICHOS_ACTIVATION=regular`, which `activation.rs:72` grants and which
#     `startup_alert.rs:110-112` uses as the EXACT condition for arming the modal alert. So
#     this is the one harness in the repository that can show "RichOS could not open" to the
#     person at the Mac, and on 2026-09-18 at 16:11:56Z it did, for two minutes, because the
#     scratch HOME was built under `$TMPDIR` and `/var` is a symlink to `private/var`:
#
#         failure: application startup: Could not establish application update exclusion:
#                  home is not a canonical directory
#
#     `richos-user-update::root` (lib.rs:147) refuses a HOME that is not already its own
#     `canonicalize()`. `pwd -P` at creation makes it canonical; P4 then re-asks the same
#     question before the launch, so a future `$TMPDIR` this harness did not anticipate is a
#     named refusal with nothing on screen, rather than a dialog he has to dismiss.
#
#     THE FIRST ACCOUNT OF THIS FAILURE BLAMED THE DOUBLED SLASH IN `${TMPDIR}/...`, AND IT
#     IS WRONG — measured on rustc 1.98.0: `Path::new("/a//b") == Path::new("/a/b")` is
#     TRUE, `/private/var/…/T//x//home` canonicalizes EQUAL, and `/var/…/T/x/home` with no
#     doubled slash anywhere canonicalizes UNEQUAL. Trimming the slash alone would have
#     fixed nothing.
#
# And if a boot fails anyway, for a reason none of the four preconditions can see, the boot
# watch below ends the instance at the stderr line — which `cannot_start` writes BEFORE it
# raises the alert — rather than letting a ten-minute modal stand for the length of the run.
#
# =========================================================================================
# CASES
# =========================================================================================
#
#   P1  a display is awake            -> otherwise a named refusal, exit 2
#   P2  the session is unlocked       -> otherwise a named refusal, exit 2  (or wait for it)
#   P3  cliclick is on this machine   -> otherwise a named refusal, exit 2
#   P4  the scratch HOME is canonical -> otherwise a named refusal, exit 2, NOTHING LAUNCHED
#   P5  the boot reached its window   -> otherwise the instance is ENDED AT ONCE and named,
#                                        exit 2, so no modal alert stands on his screen
#   C0  the bundle boots and puts exactly one window on screen
#   C1  POSITIVE CONTROL — a native keystroke reaches the web content at all
#   C2  POSITIVE CONTROL — the same DOCUMENT-level keydown listener that owns Escape runs on
#       a native key (Cmd-K opens the search overlay; it is three lines above the Escape arm
#       in the same listener in `main.js`)
#   C3  Escape closes the search overlay
#   C4  Escape closes the settings menu — audit-9 row 2, the row this file exists for
#   C5  the tree is read by SIZE and the calibration above is re-proved on this run: a sheet
#       that is `display:none` is present and 0x0
#   Z   this run left nothing running, and the pid is named
#
# The app is QUIT through its own menu and the pid is proved gone (CEO §54 addendum 4): "Test
# app windows must always close/quit when testing is finished. Same hygiene as with any other
# garbage."
#
# Usage:
#   scripts/front-door.test.sh --bundle /path/to/RichOS.app
#   scripts/front-door.test.sh --release ~/.richos-nightly/releases/v1.2.0-nightly.20260918.3
#   scripts/front-door.test.sh --bundle … --wait-for-screen 900
#   scripts/front-door.test.sh --bundle … --evidence docs/verification/<dir>   (keeps the dumps)
#
# macOS only.

set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gui-launch.sh
. "$APP_DIR/scripts/lib/gui-launch.sh"

BUNDLE="" RELEASE="" WAIT_FOR_SCREEN=0 EVIDENCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --wait-for-screen) WAIT_FOR_SCREEN="${2:-0}"; shift 2 ;;
    --evidence) EVIDENCE="${2:-}"; shift 2 ;;
    *) echo "front-door.test.sh: unknown argument $1" >&2; exit 64 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "REFUSED: this drives AppKit and a WKWebView, which exist only on macOS." >&2
  exit 2
fi

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

# ---------------------------------------------------------------------------------------
# P1/P2/P3 — the preconditions, each with its own repair
# ---------------------------------------------------------------------------------------
screen_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | grep -A1 'CGSSessionScreenIsLocked' | grep -q '<true/>'
}

echo "== The front door, through AppKit (audit-9 row 2) =="

read -r ACTIVE ONLINE <<< "$(gui_display_counts)"
VERDICT="$(gui_display_verdict "$ACTIVE")"
DISPLAY_RC=$?
if [ "$DISPLAY_RC" -ne 0 ]; then
  echo "  REFUSED  $VERDICT (online: $ONLINE)"
  echo "           Wake the screen and run this again. Nothing about the product was measured."
  exit 2
fi
note "$VERDICT"

WAITED=0
while screen_locked; do
  if [ "$WAITED" -ge "$WAIT_FOR_SCREEN" ]; then
    echo "  REFUSED  the session is LOCKED (CGSSessionScreenIsLocked = true)."
    echo "           A locked session reports 0 windows for an app that has one, cannot say"
    echo "           which process is frontmost, and delivers no synthesized keys. Every check"
    echo "           below would be a false red. Nothing about the product was measured."
    echo "           Unlock the screen, or pass --wait-for-screen <seconds> and this will wait"
    echo "           for it rather than failing (CEO 2026-09-18, §56)."
    exit 2
  fi
  [ "$WAITED" -eq 0 ] && note "the session is locked; waiting up to ${WAIT_FOR_SCREEN}s for the unlock, as a state"
  sleep 5
  WAITED=$((WAITED + 5))
done
note "the session is unlocked (waited ${WAITED}s)"

CLICLICK="$(command -v cliclick || true)"
if [ -z "$CLICLICK" ]; then
  echo "  REFUSED  cliclick is not on this machine, and the keys have to come from outside the"
  echo "           app. \`brew install cliclick\`. Nothing about the product was measured."
  exit 2
fi
note "keys from $CLICLICK"

# ---------------------------------------------------------------------------------------
# The bundle
# ---------------------------------------------------------------------------------------
# THE SCRATCH TREE IS CANONICALIZED, AND THE REASON IS THE PRODUCT'S OWN RULE.
#
# `richos-user-update`'s `root()` (crates/richos-user-update/src/lib.rs:147-149) refuses a
# HOME that is not already its own `canonicalize()`, and the app stops before its window
# exists when it does. On macOS `/var` is a symlink to `private/var` and `$TMPDIR` lives
# under it, so a scratch HOME built from `$TMPDIR` fails that check EVERY TIME.
#
# MEASURED rather than reasoned, with a five-line Rust probe on the same toolchain the app
# builds with (1.98.0), because the first account of this failure blamed the doubled slash
# `${TMPDIR}/...` produces and that account is WRONG:
#
#   Path::new("/a//b") == Path::new("/a/b")                                      ->  true
#   given /var/folders/…/T/pathprobe/home      canonical /private/var/…/home     ->  false
#   given /private/var/folders/…/T//pathprobe//home                              ->  TRUE
#
# The doubled separator is collapsed by `Path`'s component-wise equality and is harmless;
# the `/var` symlink is the whole of it. `pwd -P` resolves both, so both are gone.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/richos-front-door-XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
GUI_LAUNCHED_PIDS="$TMP/pids"
: > "$GUI_LAUNCHED_PIDS"
export GUI_LAUNCHED_PIDS
cleanup() {
  local survivors
  # THE DUMPS OUTLIVE THE RUN ONLY IF ASKED. The scratch tree is deleted either way (CEO §54:
  # garbage is always cleaned up); `--evidence <dir>` copies out the accessibility dumps and
  # the boot log FIRST, which are a few kB of text, and never the unpacked bundle or the
  # scratch HOME, which are not.
  if [ -n "$EVIDENCE" ]; then
    mkdir -p "$EVIDENCE" \
      && cp "$TMP"/ax-*.txt "$EVIDENCE/" 2>/dev/null
    [ -f "$TMP/app.log" ] && cp "$TMP/app.log" "$EVIDENCE/" 2>/dev/null
    echo "  evidence copied to $EVIDENCE"
  fi
  survivors="$(gui_reap_all)"
  [ "$survivors" -eq 0 ] || echo "  RESIDUE  $survivors process(es) survived both signals" >&2
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -n "$RELEASE" ]; then
  [ -f "$RELEASE/RichOS.app.tar.gz" ] || { echo "REFUSED: no RichOS.app.tar.gz under $RELEASE" >&2; exit 64; }
  tar -xzf "$RELEASE/RichOS.app.tar.gz" -C "$TMP" || { echo "REFUSED: the release archive would not extract" >&2; exit 64; }
  BUNDLE="$TMP/RichOS.app"
fi
if [ -z "$BUNDLE" ] || [ ! -x "$BUNDLE/Contents/MacOS/richos-tauri" ]; then
  echo "REFUSED: --bundle must name a RichOS.app with an executable in it, or --release a" >&2
  echo "         published directory holding RichOS.app.tar.gz." >&2
  exit 64
fi

HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR/Applications"

# P4 — THE SCRATCH HOME MUST PASS THE APP'S OWN RULE BEFORE THE APP IS ASKED.
#
# This harness sets `RICHOS_ACTIVATION=regular` (see the boot below) because a key window and
# a frontmost process are exactly what it is measuring. `activation.rs:72` says that forces
# the front, and `startup_alert.rs:110-112` arms the CEO-FACING MODAL on precisely
# `Presentation::Regular` and on nothing else. So this file is the one harness in the
# repository that can put "RichOS could not open" on the person's screen, and it must
# therefore prove the boot can succeed BEFORE it launches, rather than discover it after.
#
# It happened: the run at 16:11:56Z on 2026-09-18 left that alert up for two minutes and the
# CEO sent a screenshot of it.
#
# `home_rule_violation` MIRRORS `root()` (crates/richos-user-update/src/lib.rs:141-168) rather
# than approximating it — canonical, then every ancestor a directory owned by root or by me
# and not writable by anyone else unless it is root-owned AND sticky, then the home itself
# private to its owner. `stat -L` follows symlinks because Rust's `metadata()` does. It prints
# the violation and returns 0 when there is one; returns 1 when the HOME would be accepted.
home_rule_violation() {
  local home="$1" me p uid mode
  me="$(id -u)"
  case "$home" in
    /*) ;;
    *) printf 'the scratch HOME is not an absolute path: %s\n' "$home"; return 0 ;;
  esac
  if [ "$(cd "$home" && pwd -P)" != "$home" ]; then
    printf 'the scratch HOME is not canonical: %s resolves to %s (lib.rs:147)\n' \
      "$home" "$(cd "$home" && pwd -P)"
    return 0
  fi
  uid="$(stat -L -f '%u' "$home")"
  mode="$(stat -L -f '%p' "$home")"
  if [ "$uid" != "$me" ] || [ $((8#$mode & 8#22)) -ne 0 ]; then
    printf 'the scratch HOME is not private to its owner: %s is uid %s mode %s (lib.rs:130)\n' \
      "$home" "$uid" "$mode"
    return 0
  fi
  p="$(dirname "$home")"
  while :; do
    uid="$(stat -L -f '%u' "$p")"
    mode="$(stat -L -f '%p' "$p")"
    if [ "$uid" != 0 ] && [ "$uid" != "$me" ]; then
      printf 'an ancestor of the scratch HOME belongs to neither root nor me: %s is uid %s (lib.rs:156)\n' "$p" "$uid"
      return 0
    fi
    if [ $((8#$mode & 8#22)) -ne 0 ] && { [ "$uid" != 0 ] || [ $((8#$mode & 8#1000)) -eq 0 ]; }; then
      printf 'an ancestor of the scratch HOME is writable by others and not root-sticky: %s is uid %s mode %s (lib.rs:153-157)\n' "$p" "$uid" "$mode"
      return 0
    fi
    [ "$p" = "/" ] && break
    p="$(dirname "$p")"
  done
  return 1
}

if VIOLATION="$(home_rule_violation "$HOMEDIR")"; then
  echo "  REFUSED  $VIOLATION"
  echo "           richos-user-update::root refuses exactly that and the app would stop before"
  echo "           its window exists — and because this harness asks for a regular activation,"
  echo "           the person at this Mac would get a modal alert about it. Nothing was"
  echo "           launched and nothing about the product was measured."
  echo "           Point \$TMPDIR at a directory of your own that no one else can write to."
  exit 2
fi
note "scratch HOME passes the app's own rule: $HOMEDIR"

cp -a "$BUNDLE" "$HOMEDIR/Applications/RichOS.app"
EXE="$HOMEDIR/Applications/RichOS.app/Contents/MacOS/richos-tauri"
LOG="$TMP/app.log"
: > "$LOG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist" 2>/dev/null || echo unknown)"
SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :RichOSSourceCommit' "$BUNDLE/Contents/Info.plist" 2>/dev/null || echo unknown)"
note "bundle $VERSION, built from $SOURCE"

# ---------------------------------------------------------------------------------------
# The tree, read with position AND size
# ---------------------------------------------------------------------------------------
AXDUMP="$TMP/axdump.applescript"
cat > "$AXDUMP" <<'APPLESCRIPT'
tell application "System Events"
  tell process "richos-tauri"
    set out to ""
    try
      set out to out & "windows:" & (count of windows) & linefeed
    end try
    try
      set d to entire contents of window 1
      repeat with e in d
        try
          set r to (role of e as text)
          set nm to ""
          try
            set nm to (name of e as text)
          end try
          set vl to ""
          try
            set vl to (value of e as text)
          end try
          set pz to "? ?"
          try
            set pz to ((item 1 of (position of e)) as text) & "," & ((item 2 of (position of e)) as text) & " " & ((item 1 of (size of e)) as text) & "x" & ((item 2 of (size of e)) as text)
          end try
          if nm is not "" or vl is not "" then
            set out to out & r & " | " & pz & " | name=" & nm & " | value=" & vl & linefeed
          end if
        end try
      end repeat
    on error errm
      set out to out & "ERR " & errm & linefeed
    end try
    return out
  end tell
end tell
APPLESCRIPT

ax() { osascript "$AXDUMP" > "$TMP/ax-$1.txt" 2>&1; }
windows_in() { head -1 "$TMP/ax-$1.txt" | sed 's/^windows://'; }
# The node named $2 in dump $1, as "WxH". Empty when there is no such node at all.
size_of() {
  awk -F' \\| ' -v want="$2" '$4 == "name=" want { split($2, a, " "); print a[2]; exit }' "$TMP/ax-$1.txt"
}
# Does dump $1 carry a node named $2 with a non-zero box? THIS is "on screen".
on_screen() {
  local s; s="$(size_of "$1" "$2")"
  case "$s" in ""|0x0|0x*|*x0) return 1 ;; *) return 0 ;; esac
}
middle_of() {
  awk -F' \\| ' -v want="$2" '
    $4 == "name=" want {
      split($2, a, " "); split(a[1], p, ","); split(a[2], z, "x");
      if (z[1] + 0 > 0 && z[2] + 0 > 0) { printf "%d,%d\n", p[1] + z[1] / 2, p[2] + z[2] / 2; exit }
    }' "$TMP/ax-$1.txt"
}

# ---------------------------------------------------------------------------------------
# C0 — boot, one window, and the front
# ---------------------------------------------------------------------------------------
( cd / && exec env -i HOME="$HOMEDIR" USER="${USER:-unknown}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    RICHOS_ACTIVATION=regular "$EXE" >> "$LOG" 2>&1 ) &
PID=$!
printf '%s\n' "$PID" >> "$GUI_LAUNCHED_PIDS"

# THE BOOT WATCH ALSO WATCHES FOR THE FAILURE, AND ENDS THE INSTANCE THE MOMENT IT LANDS.
#
# `startup_alert::cannot_start` writes stderr FIRST and raises the modal AFTER
# (startup_alert.rs:222-228), and the modal's timeout is TEN MINUTES
# (`ALERT_TIMEOUT_SECONDS: f64 = 600.0`, startup_alert.rs:161). So a failing boot under this
# harness puts a dialog on the person's screen for as long as the rest of this file takes to
# run — which on 2026-09-18 was two minutes — unless something kills the process, and the
# line that says to is already in the log a tenth of a second earlier.
#
# The old loop's only exit conditions were `boot complete` and the process being GONE. A
# process sitting on a modal is neither, so it ran its full 60s and then measured a window
# that does not exist. This arm is the one that matters for the person at the Mac.
BOOT_FAILURE=""
W=0
while [ "$W" -lt 600 ]; do
  grep -q '^\[richos\] boot complete' "$LOG" 2>/dev/null && break
  BOOT_FAILURE="$(grep -m1 '^\[richos\] application startup:' "$LOG" 2>/dev/null || true)"
  [ -n "$BOOT_FAILURE" ] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
  W=$((W + 1))
done
if [ -n "$BOOT_FAILURE" ]; then
  gui_kill "$PID" >/dev/null 2>&1
  if kill -0 "$PID" 2>/dev/null; then
    echo "  RESIDUE  pid $PID survived both signals and may still be showing a modal alert." >&2
  fi
  echo "  REFUSED  the bundle stopped before its window existed, $((W / 10)).$((W % 10))s after launch:"
  echo "             $BOOT_FAILURE"
  echo "           Its alert was armed (this harness asks for a regular activation), so the"
  echo "           instance was ended at once rather than left on the person's screen. Nothing"
  echo "           about the front door was measured — this is a verdict on the boot, not on"
  echo "           Escape."
  exit 2
fi
sleep 3
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1
sleep 1
ax 0-rest
if [ "$(windows_in 0-rest)" = "1" ]; then
  ok "C0  the bundle boots and puts exactly one window on screen  (pid $PID)"
else
  bad "C0  the bundle did not put one window on screen: $(head -2 "$TMP/ax-0-rest.txt" | tr '\n' ' ')"
  note "the boot's own window line: $(grep -m1 '^\[richos\] window' "$LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------------------
# C5 — the calibration, re-proved on THIS run rather than quoted from the header
# ---------------------------------------------------------------------------------------
PHANTOM="$(size_of 0-rest 'Quit while work is running?')"
if [ -n "$PHANTOM" ] && ! on_screen 0-rest 'Quit while work is running?'; then
  ok "C5  a display:none sheet is in the tree and measures ${PHANTOM} — presence is not evidence"
elif [ -z "$PHANTOM" ]; then
  note "C5  this build's tree does not carry the quit dialog at rest; the calibration could not be"
  note "    re-proved on this run, so every SIZE assertion below is stricter than it needs to be."
else
  bad "C5  the quit dialog measures $PHANTOM at rest, which means it IS on screen"
fi

# ---------------------------------------------------------------------------------------
# Leave the opening screen by CLICKING the door at its own box — no key dependency yet,
# because whether keys arrive is exactly what C1 is about to ask.
# ---------------------------------------------------------------------------------------
DOOR="$(middle_of 0-rest 'Talk to Rich')"
if [ -n "$DOOR" ]; then
  "$CLICLICK" "c:$DOOR" >/dev/null 2>&1
  sleep 2
fi
ax 1-desk

# ---------------------------------------------------------------------------------------
# C1 — a native keystroke reaches the web content AT ALL
# ---------------------------------------------------------------------------------------
PROBE="front door probe $$"
"$CLICLICK" "t:$PROBE" >/dev/null 2>&1
sleep 1
ax 2-typed
if grep -qF "$PROBE" "$TMP/ax-2-typed.txt"; then
  ok "C1  positive control — a native keystroke reaches the web content"
else
  bad "C1  positive control FAILED — nothing typed from outside the app reached the page"
  note "Every check below this line is about a key that never arrived, so they say nothing"
  note "about the product. Fix the control before reading them."
fi

# ---------------------------------------------------------------------------------------
# C2 — the SAME document-level keydown listener that owns Escape, on a native key
# ---------------------------------------------------------------------------------------
"$CLICLICK" kd:cmd t:k ku:cmd >/dev/null 2>&1
sleep 1.5
ax 3-cmdk
if [ "$(wc -l < "$TMP/ax-3-cmdk.txt")" -gt "$(wc -l < "$TMP/ax-2-typed.txt")" ]; then
  ok "C2  positive control — Cmd-K reached main.js's document keydown listener"
else
  bad "C2  positive control FAILED — Cmd-K changed nothing, so that listener is not running on"
  note "native keys. Escape is three lines below Cmd-K in the SAME listener, so C4 cannot"
  note "distinguish a broken handler from a key that never arrived."
fi

# ---------------------------------------------------------------------------------------
# C3 — Escape closes what Cmd-K opened
# ---------------------------------------------------------------------------------------
"$CLICLICK" kp:esc >/dev/null 2>&1
sleep 1.5
ax 4-esc
if [ "$(wc -l < "$TMP/ax-4-esc.txt")" -le "$(wc -l < "$TMP/ax-2-typed.txt")" ]; then
  ok "C3  Escape closed the search overlay"
else
  bad "C3  Escape did not close the search overlay"
  diff "$TMP/ax-3-cmdk.txt" "$TMP/ax-4-esc.txt" | head -8 | while IFS= read -r l; do note "$l"; done
fi

# ---------------------------------------------------------------------------------------
# C4 — THE ROW. The settings menu, opened by its own control, closed by Escape.
# ---------------------------------------------------------------------------------------
SET="$(middle_of 0-rest 'Settings')"
if [ -z "$SET" ]; then
  bad "C4  the settings control has no box in the tree, so the menu could not be opened"
else
  "$CLICLICK" "c:$SET" >/dev/null 2>&1
  sleep 1.5
  ax 5-setmenu
  if ! on_screen 5-setmenu 'Techy Mode'; then
    bad "C4  the settings menu did not open, so Escape was never put to it"
    note "Techy Mode measures '$(size_of 5-setmenu 'Techy Mode')'"
  else
    OPEN_SIZE="$(size_of 5-setmenu 'Techy Mode')"
    "$CLICLICK" kp:esc >/dev/null 2>&1
    sleep 1.5
    ax 6-setmenu-esc
    AFTER="$(size_of 6-setmenu-esc 'Techy Mode')"
    [ -n "$AFTER" ] || AFTER="absent"
    if on_screen 6-setmenu-esc 'Techy Mode'; then
      bad "C4  the settings menu survived Escape — audit-9 row 2 reproduces"
      note "Techy Mode measured $OPEN_SIZE open and $AFTER after Escape"
    else
      ok "C4  Escape closed the settings menu  (Techy Mode $OPEN_SIZE -> $AFTER)"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------
# Z — the instance is closed when the test ends (CEO §54 addendum 4)
# ---------------------------------------------------------------------------------------
osascript -e 'tell application "System Events" to tell process "richos-tauri" to keystroke "q" using command down' >/dev/null 2>&1
sleep 3
if kill -0 "$PID" 2>/dev/null; then
  note "Z   its own Quit did not end it; sending a signal"
  gui_kill "$PID" >/dev/null 2>&1
fi
if kill -0 "$PID" 2>/dev/null; then
  bad "Z   pid $PID SURVIVED both signals — there is a window of this test still on his screen"
else
  ok "Z   pid $PID is gone; nothing this run started is still running"
fi

echo
echo "  evidence: $TMP  (removed on exit; copy it out of here if a check went red)"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
