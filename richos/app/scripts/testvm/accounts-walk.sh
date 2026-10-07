#!/bin/bash
# accounts-walk.sh — feedback item 9 (round 18) on the real app, in one guest run: a person who
# is not technical finds "Claude accounts" in Settings, is offered a second account by Rich at
# 86% of the week, adds it in two steps (signing in with the same account first, then the right
# one), and sees why Rich switched, in the conversation, in the sheet's banner and in Recent
# changes.
#
#   run-walk.py --bundle <RichOS.app.zip> --home <empty dir> --engine <engine.tar.gz> \
#     --report <json> -- accounts-walk.sh <out-dir>
#
# His words (richos-hq docs/ceo-input/2026-10-06_01/feedback.md, item 9): "Non-technical users
# should also be able to take advantage of the multi-account setup". The design is round 18
# (richos-hq design/mockups/rounds/round-18/multi-account.html and NOTES.md).
#
# run-walk.py passes the VM name first, and quits the app, stops the guest and deletes the clone
# when this returns (CEO §54). FIXTURE-DRIVEN, as use-first-walk.sh: fake-claude-fill-first.pl
# answers every `claude` call from per-account usage files, and says who each folder is signed in
# as (login-as), so no real Claude account is read, signed in or switched. In <out-dir>:
#   0-menu-one          Settings, Technical view off: "Claude accounts", "86% of this week used"
#   1-nudge             Rich's suggestion in the conversation, with Add a second account / Not now
#   2-add-step1         Adding, step 1 of 2: the two names
#   3-add-step2         Step 2 of 2: Open sign-in
#   4-same-account      Signed in with the account already in use: its own screen, Try again
#   5-two-{dark,light}  The right account: Work is ready, two cards, Recent changes
#   6-switched-chat     Home's week at 99%: Rich's line, with See your accounts
#   7-switched-{dark,light}  The sheet: the banner (when and why) and Recent changes
#   8-menu-two          Settings: "Using Work, switched <time>"
#   9-chose-home        Item 8 (his test): Home at 97% of its week, chosen with "Use this one now";
#                       9-home-in-use the record says Home and Recent changes "You chose Home";
#                       then Home reaches 99% and 9-switched-again: Rich switched to Work by himself
#   10-menu-technical   2026-10-06_02: Technical view on, the quick settings quota row reads the
#                       in-use account's WEEKLY figure ("Work 12% weekly"; its five-hour is 0%)
#   11-menu-1024-{light,dark}  The window at 1024x700: the "Using Work, switched <time>" row,
#                       with its box in 11-row-{light,dark}.json, for qa/frame.py and contrast.py
# Steps 9 to 11 were added by the nightly 41 walk (ray-opus-walk41): no walk pressed Use this one
# now, read the quota row with Technical view on, or looked at the row in the smallest window.
# EXIT STATUS: 1 when the setup fails or any capture or check below fails (named at the end);
# 0 only when every capture was saved and every check read what it should.
set -u
VM="$1"
S="${2:?usage: accounts-walk.sh <vm> <out-dir>}"
T="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$S"
# 40 s per accessibility call instead of ax.sh's 20: the 2026-10-06 runs shared the host with a
# second guest and suites at 92 to 99% CPU, and a read past 20 s was the harness, not the app.
export TESTVM_AX_TIMEOUT="${TESTVM_AX_TIMEOUT:-40}"
note() { echo "[walk] $(date -u +%H:%M:%SZ) $*" | tee -a "$S/walk.log"; }
FAILS=()
fail() { note "FAILED: $1"; FAILS+=("$1"); }
setup_failed() { note "FAILED: $1; nothing to walk"; exit 1; }
ax() { "$T/ax.sh" "$VM" "$@"; }
shot() { "$T/shot.sh" "$VM" "$S/$1.png" || fail "capture $1"; }
wait_for() {
  for _ in $(seq 1 30); do
    ax find --title "$1" --contains --first >/dev/null 2>&1 && return 0
    ax find --value "$1" --contains --first >/dev/null 2>&1 && return 0
    sleep 2
  done
  note "never appeared: $1"
  return 1
}
has() {  # has <words> <check name>: the words are on screen, read rather than assumed
  for _ in $(seq 1 10); do
    ax find --value "$1" --contains --first >/dev/null 2>&1 && { note "read: $1"; return 0; }
    ax find --title "$1" --contains --first >/dev/null 2>&1 && { note "read: $1"; return 0; }
    sleep 2
  done
  fail "$2 (not on screen: $1)"
}
# press <title> <check name>: one control, by its words, retried: a loaded host can push one
# accessibility read past its 20 s deadline (the 2026-10-06 run, "exit 124"), and that is the
# harness, not the app.
press() {
  for _ in 1 2 3; do
    ax click --title "$1" --contains --first >/dev/null 2>&1 && return 0
    sleep 3
  done
  fail "$2 (could not press: $1)"
  return 1
}
menu_open() { ax find --title 'Light theme' --first >/dev/null 2>&1; }
# menu open|closed: pressed until the menu READS as that state, at most three times. On a loaded
# host a press can report its deadline after it took effect (the 2026-10-06 runs logged "no
# Settings button" while the menu had opened), so what is on screen decides, never the press's
# exit code: a second blind press only closed what the first had opened.
menu() {
  for _ in 1 2 3; do
    if [ "$1" = open ]; then menu_open && return 0; else menu_open || return 0; fi
    ax click --title 'Settings' --role AXPopUpButton >/dev/null 2>&1 || true
    sleep 3
  done
  if [ "$1" = closed ]; then ax --key 53 >/dev/null 2>&1 || true; sleep 2; menu_open || return 0; fi
  note "the menu would not be $1"
}
theme() {  # theme Light|Dark; the press is retried only while the menu is still open to take it
  menu open
  for _ in 1 2 3; do
    ax click --title "$1 theme" >/dev/null 2>&1 && break
    sleep 2
  done
  sleep 1
  menu closed
}
sheet_open() { ax find --title 'Close Claude accounts' --first >/dev/null 2>&1; }
# The Settings row is an AXMenuItem whose title runs on into its line ("Claude accounts Using Work,
# switched 2:35 PM"). Pressed by role: the first node titled Claude accounts is an empty AXGroup
# named after the closed sheet, and pressing it did nothing (the 2026-10-06 14:38Z find).
open_sheet() {
  for try in 1 2; do
    menu open
    ax click --title 'Claude accounts' --role AXMenuItem --contains --first >/dev/null 2>&1 || note "no Claude accounts row"
    sleep 3
    sheet_open && return 0
    note "accounts sheet not open after try $try"
  done
  return 1
}
close_sheet() {
  sheet_open || return 0
  ax click --title 'Close Claude accounts' >/dev/null 2>&1 || true
  sleep 2
  sheet_open && { ax --key 53 || true; sleep 2; }
  return 0
}
relaunch_app() {
  python3 - "$VM" "$T" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from relaunch import relaunch
print(relaunch(sys.argv[1], environment={'RICHOS_CLAUDE_BIN': '/Users/admin/fill-first/claude'}))
PY
}
# usage <file> <five %> <weekly %>
usage() { "$T/guest.sh" "$VM" "printf '{\"five\":$2,\"weekly\":$3}' > \"$1\""; }
login_as() { "$T/guest.sh" "$VM" "printf '%s' '$1' > /Users/admin/fill-first/login-as"; }
send_turn() {  # one plain turn; the turn has ended once Send is back
  ax type "$1" --role AXTextArea --first --replace || note "no composer"
  ax click --title 'Send' --first || note "no Send"
  sleep 4
  for _ in $(seq 1 30); do
    ax find --title 'Send' --first >/dev/null 2>&1 && break
    sleep 2
  done
  sleep 3
}
field() {  # field <label> <text>: type into the input a label names
  ax type "$2" --title "$1" --contains --replace >/dev/null 2>&1 && return 0
  note "no field labeled $1"
  return 1
}

"$T/guest.sh" "$VM" 'mkdir -p /Users/admin/fill-first' || setup_failed "the fixture folder"
"$T/guest.sh" "$VM" --push "$T/fake-claude-fill-first.pl" /Users/admin/fill-first/claude || setup_failed "pushing the fake claude"
"$T/guest.sh" "$VM" 'chmod 755 /Users/admin/fill-first/claude' || setup_failed "the fake claude's mode"
usage /Users/admin/fill-first/usage-1.json 20 86 || setup_failed "the one account's usage fixture"
relaunch_app || setup_failed "relaunching the app with the fake claude"

wait_for 'Not now' || true
ax click --title 'Not now' --first || true
wait_for 'Add this company' || true
sleep 2
for attempt in 1 2 3; do
  ax type 'Northwind Traders' --role AXTextField --first --replace || true
  sleep 1
  ax click --title 'Add this company' || true
  sleep 6
  ax find --title 'Add this company' --first >/dev/null 2>&1 || break
  note "company not added yet (attempt $attempt)"
done

# The guest starts on the system theme (light); the shots named -dark are taken in Dark.
theme Dark
note "0 Settings with Technical view off: the row is there, with its plain line"
menu open
# Technical view off: the detailed quota row is hidden. Not asked of the accessibility tree: on the
# 2026-10-06 run a find of "Claude Code quota" succeeded while the guest's screen showed no such
# row. The shot 0-menu-one shows the menu, and tests/accounts.js asserts the row hidden.
has 'Claude accounts' "0 the Claude accounts row"
has '86% of this week used' "0 the row's line"
shot 0-menu-one
menu closed

note "1 Rich suggests a second account, in the conversation"
send_turn 'What is on my plate today?'
wait_for 'Add a second account' || true
has 'If you have a second Claude account' "1 Rich's suggestion"
has 'Not now' "1 Not now beside it"
shot 1-nudge

note "2 adding, step 1 of 2: the two names (from Rich's button)"
press 'Add a second account' "2 Add a second account"
sleep 3
has 'Step 1 of 2' "2 step 1"
shot 2-add-step1
field 'The account you use now' 'Home' || fail "2 the first name"
field 'The new account' 'Work' || fail "2 the new name"
press 'Continue' "2 Continue"
sleep 2
has 'Sign in to Work' "3 step 2"
shot 3-add-step2

note "4 the same account signed in again"
login_as 'account-1@fixture.invalid' || fail "4 the login-as fixture"
: > "$S/.empty"; "$T/guest.sh" "$VM" --push "$S/.empty" /Users/admin/fill-first/calls.log || true; rm -f "$S/.empty"
press 'Open sign-in' "4 Open sign-in"
wait_for 'That is the account you already use' || true
has 'You signed in as' "4 the same-account screen"
has 'Try again' "4 Try again"
shot 4-same-account
"$T/guest.sh" "$VM" 'cat /Users/admin/fill-first/calls.log' > "$S/4-calls.log" 2>&1 || fail "4 calls.log"
grep -q 'claude-accounts/2 auth logout' "$S/4-calls.log" || fail "4 the same account was not signed out of the new folder"

note "5 the right account: Work is ready"
login_as 'work@fixture.invalid' || fail "5 the login-as fixture"
# shellcheck disable=SC2016  # the $(...) is meant to expand in the guest's shell, not here
DATA=$("$T/guest.sh" "$VM" 'dirname "$(find /Users/admin/testvm -type d -name claude-accounts 2>/dev/null | head -1)"')
note "app data: $DATA"
usage "$DATA/claude-accounts/2/usage.json" 0 12 || fail "Work's usage fixture"
press 'Try again' "5 Try again"
wait_for 'is ready' || true
has 'is ready. Rich switches to it when Home is nearly full' "5 Work is ready"
has 'You added' "5 Recent changes"
shot 5-two-dark
"$T/guest.sh" "$VM" "cat \"$DATA/claude-accounts.json\"" > "$S/5-accounts.txt" 2>&1 || fail "5 the accounts record"
grep -q '"label": *"Home"' "$S/5-accounts.txt" || fail "5 the first account is not named Home"
grep -q '"label": *"Work"' "$S/5-accounts.txt" || fail "5 Work is not on the record"
grep -q '"kind": *"added"' "$S/5-accounts.txt" || fail "5 Recent changes has no added row"
close_sheet; theme Light; open_sheet || fail "5 the sheet in light"; shot 5-two-light
close_sheet; theme Dark

note "6 Home's week reaches 99%: Rich switches, and says why"
usage /Users/admin/fill-first/usage-1.json 20 99 || fail "Home's 99% usage fixture"
send_turn 'How is the client report going?'
send_turn 'And the pairing screens?'
"$T/guest.sh" "$VM" "cat \"$DATA/claude-accounts.json\"" > "$S/6-accounts.txt" 2>&1 || fail "6 the accounts record"
grep -q '"inUse": *"2"' "$S/6-accounts.txt" || fail "6 claude-accounts.json does not record Work in use"
has 'I switched the team to your' "6 Rich's line"
has 'See your accounts' "6 See your accounts under it"
shot 6-switched-chat

note "7 the sheet: the banner says when and why; Recent changes"
press 'See your accounts' "7 See your accounts"
sleep 3
has 'Rich switched to Work at' "7 the banner"
has 'Why: Home had used 99% of its weekly limit' "7 the banner's why"
has 'Rich switched to' "7 Recent changes"
shot 7-switched-dark
close_sheet; theme Light; open_sheet || fail "7 the sheet in light"; shot 7-switched-light
close_sheet; theme Dark

note "8 Settings: which account, and when it switched"
menu open
has 'Using Work, switched' "8 the row's line after a switch"
shot 8-menu-two
menu closed

note "9 item 8: he chooses the account at 97% of its week, and Rich switches again at 99%"
usage /Users/admin/fill-first/usage-1.json 20 97 || fail "Home's 97% usage fixture"
# Home was resting at 99%; a fresh reading at 97% gives it room again. A turn reads the quota, so
# the sheet is opened after one, and again after up to two more, until Home's card offers the choice.
chosen=0
for try in 1 2 3; do
  send_turn "Quick check $try on the weekly figures, please."
  open_sheet || { note "no sheet on try $try"; continue; }
  if ax find --title 'Use Home now' --first >/dev/null 2>&1; then chosen=1; break; fi
  note "Home's card offers no Use this one now yet (try $try)"
  close_sheet
done
if [ "$chosen" = 1 ]; then
  shot 9-chose-home
  press 'Use Home now' "9 Use this one now on Home"
  sleep 4
  "$T/guest.sh" "$VM" "cat \"$DATA/claude-accounts.json\"" > "$S/9-accounts-chosen.txt" 2>&1 || fail "9 the accounts record"
  grep -q '"inUse": *"1"' "$S/9-accounts-chosen.txt" || fail "9 the record does not say Home is in use after Use this one now"
  grep -q '"kind": *"chose"' "$S/9-accounts-chosen.txt" || fail "9 Recent changes has no chose row"
  # "You chose <b>Home</b>." is two text nodes, so the words are read up to the bold name
  # (walk-434edf5caf3d: the frame showed the row and a find of the whole sentence missed it).
  has 'You chose' "9 Recent changes says You chose Home"
  shot 9-home-in-use
  close_sheet
  usage /Users/admin/fill-first/usage-1.json 20 99 || fail "Home's second 99% usage fixture"
  switched=0
  for try in 1 2 3; do
    send_turn "Status update $try on the client report?"
    "$T/guest.sh" "$VM" "cat \"$DATA/claude-accounts.json\"" > "$S/9-accounts-after.txt" 2>&1 || true
    if grep -q '"inUse": *"2"' "$S/9-accounts-after.txt"; then switched=1; break; fi
  done
  [ "$switched" = 1 ] || fail "9 Home reached 99% of its week and Rich did not switch to Work"
  shot 9-switched-again
else
  fail "9 Home at 97% never offered Use this one now"
fi
theme Dark

note "10 _02: with Technical view on, the quick settings quota row is the WEEKLY figure"
menu open
ax click --title 'Technical view' --first >/dev/null 2>&1 || note "no Technical view switch"
sleep 3
# Turning it on asks where ("Turn on the technical view": all conversations, this company, this
# one); its own default and "Turn it on" (walk-434edf5caf3d: left open, it blocked every later read).
if ax find --title 'Turn it on' --first >/dev/null 2>&1; then
  press 'Turn it on' "10 Turn it on"
  sleep 3
fi
menu open
has 'Claude Code quota' "10 the quota row with Technical view on"
has 'Work 12% weekly' "10 the row reads Work's weekly 12%, not its five-hour 0%"
ax find --title 'Claude Code quota' --contains --json > "$S/10-row.json" 2>&1 || true
shot 10-menu-technical
menu open
ax click --title 'Technical view' --first >/dev/null 2>&1 || note "Technical view not switched back off"
sleep 3
if ax find --title 'Turn it off' --first >/dev/null 2>&1; then
  press 'Turn it off' "10 Turn it off"
  sleep 3
fi
menu closed

note "11 the smallest window, 1024x700: the row's lines fit and can be read"
APP_PID=$(cat "${TESTVM_ROOT:-$HOME/.richos-testvm}/run/$VM/app.pid" 2>/dev/null || true)
ax --windows > "$S/11-windows-before.txt" 2>&1 || true
ax "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to set size of window 1 to {1024, 700}" >/dev/null 2>&1 || fail "11 resizing the window"
sleep 2
ax --windows > "$S/11-windows-1024.txt" 2>&1 || true
grep -q '1024' "$S/11-windows-1024.txt" || fail "11 the window is not 1024 wide"
for t in Light Dark; do
  if [ "$t" = Light ]; then lower=light; else lower=dark; fi
  theme "$t"
  menu open
  has 'Using Work, switched' "11 the row's line at 1024x700 ($lower)"
  ax find --title 'Claude accounts' --role AXMenuItem --contains --json > "$S/11-row-$lower.json" 2>&1 || true
  shot "11-menu-1024-$lower"
  menu closed
done

if [ "${#FAILS[@]}" -gt 0 ]; then
  note "done, with ${#FAILS[@]} failed step(s): $(printf '%s; ' "${FAILS[@]}")"
  exit 1
fi
note "done"
exit 0
