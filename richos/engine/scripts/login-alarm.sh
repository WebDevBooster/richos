#!/usr/bin/env bash
#
# login-alarm.sh — WHEN THE CLAUDE LOGIN DIES, THE CEO IS TOLD, WITHOUT A SESSION.
#
# CEO, 2026-09-26, verbatim: "Fucking "login expired" fuckshit!" and "what must
# be done about that "login expired" shitfuck?" His rule (ruling §90 point 6):
# "He never has to ask; every step and failure reaches him unprompted."
#
# At 09:26:11Z the lead's own turn failed with "Login expired · Please run
# /login", a teammate died the same way at 09:30:44Z, and he found out himself
# about 97 minutes later. Nothing in a Claude session can raise this alarm,
# because when the login is dead every session's model calls fail. So this is a
# plain program, scheduled by launchd every LOGIN_ALARM_SECONDS (30), that needs
# no model, no session and no network.
#
# What it reads (the reasoning is in scripts/lib/login_alarm.py):
#   * the transcripts under ~/.claude/projects, where every session and every
#     teammate records a failed turn as `"error":"authentication_failed"`;
#   * reports handed to it with --report (the quota watcher's get_usage);
#   * the "Claude Code-credentials" keychain item's MODIFICATION TIME, as an
#     attribute: never its value, never -w or -g.
# It never reads, prints, copies or stores a credential or a token.
#
# What it does, ONCE per expiry: a macOS notification with a sound to the CEO,
# and one escalation row (state stopped, for ceo) in the engine ledger, which
# the lead's session reads at every session start and every turn end. When the
# credential is rewritten after the failure (his /login), the escalation is
# acknowledged by this program and the episode closes.
#
# USAGE
#   login-alarm.sh                  one scan (what launchd runs)
#   login-alarm.sh --report --source <name> --detail "<text>"
#                                   one scan plus a failure a caller observed
#   login-alarm.sh --status         the current episode and the last three
#   login-alarm.sh --install        schedule it (launchd, every 30 s, at load too)
#   login-alarm.sh --print-plist    the same service definition, not scheduled
#   login-alarm.sh --uninstall      unschedule it
#   login-alarm.sh --installed      exit 0 if scheduled, 1 if not
#
# TEST SEAMS (the suite uses every one; nothing here has a default that could
# reach the CEO from a test): LOGIN_ALARM_PROJECTS_DIR, LOGIN_ALARM_STATE,
# LOGIN_ALARM_SECURITY, LOGIN_ALARM_NOTIFY_CMD, LOGIN_ALARM_NOW,
# RICHOS_ESCALATION_LEDGER, RICHOS_LAUNCH_AGENTS_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/login_alarm.py"
LABEL="com.richos.login-alarm"
LAUNCHD_DIR="${RICHOS_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCHD_DIR/$LABEL.plist"
# 30 s: the bound is "told within a minute" of the failure, and launchd's
# interval is the worst case of the wait. The scan itself took 0.05 s over 3,028
# transcripts on 2026-09-26.
SECONDS_BETWEEN="${LOGIN_ALARM_SECONDS:-30}"

command -v python3 >/dev/null 2>&1 || { echo "login-alarm.sh: python3 is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "login-alarm.sh: $LIB is missing" >&2; exit 2; }

MODE="run"
case "${1:-}" in
    --install) MODE="install" ;;
    --print-plist) MODE="print-plist" ;;
    --uninstall) MODE="uninstall" ;;
    --installed) MODE="installed" ;;
    --help|-h) sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# This job's own launchd service, and nothing else in the user's domain.
_domain="gui/$(id -u)"

if [ "$MODE" = "uninstall" ]; then
    if command -v launchctl >/dev/null 2>&1 && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ]; then
        launchctl bootout "$_domain/$LABEL" >/dev/null 2>&1 || true
    fi
    rm -f "$PLIST"
    echo "unscheduled $LABEL"
    exit 0
fi

if [ "$MODE" = "installed" ]; then
    [ -f "$PLIST" ] || exit 1
    # A plist on disk is not a scheduled job: on a real host it must be loaded
    # (hunt P5-32 v3, the same check disk-watchdog.sh makes).
    if command -v launchctl >/dev/null 2>&1 && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ]; then
        launchctl print "$_domain/$LABEL" >/dev/null 2>&1 || exit 1
    fi
    exit 0
fi

if [ "$MODE" = "install" ] || [ "$MODE" = "print-plist" ]; then
    # NEVER SCHEDULE FROM A LINKED WORKTREE OR A TEMPORARY DIRECTORY: the plist
    # bakes in this path, a worktree is deleted at land time, and an alarm that
    # silently stopped running looks exactly like a login that never failed.
    # The same refusal disk-watchdog.sh and scratch-reaper.sh make.
    _WT_TMP="${TMPDIR:-/tmp}"; _WT_TMP="${_WT_TMP%/}"
    _WT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    _WT_MARKER="${_WT_ROOT:-$ENGINE_ROOT/..}/.g""it"
    if [ "$MODE" = install ] && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ] && { [ -f "$_WT_MARKER" ] || case "$ENGINE_ROOT" in
            /tmp/*|/private/tmp/*|/private/var/folders/*|*/.claude/worktrees/*|"$_WT_TMP"/*) true ;;
            *) false ;; esac; }; then
        {
            echo "REFUSING TO SCHEDULE FROM HERE."
            echo "  engine: $ENGINE_ROOT"
            echo "  This is a linked worktree or a temporary directory. The plist would bake"
            echo "  in a path that stops existing at land time. Install from the MAIN checkout"
            echo "  (or the installed engine: ~/.claude/richos-engine/scripts/login-alarm.sh --install)."
        } >&2
        exit 2
    fi
    if [ "$MODE" = print-plist ]; then PLIST=/dev/stdout; else mkdir -p "$LAUNCHD_DIR" "$HOME/.claude/state"; fi
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "    <key>Label</key><string>$LABEL</string>"
        echo '    <key>ProgramArguments</key>'
        echo '    <array>'
        echo '        <string>/bin/bash</string>'
        echo "        <string>$SCRIPT_DIR/login-alarm.sh</string>"
        echo '    </array>'
        echo '    <key>EnvironmentVariables</key><dict>'
        echo '        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>'
        echo '    </dict>'
        echo "    <key>StartInterval</key><integer>$SECONDS_BETWEEN</integer>"
        echo '    <key>RunAtLoad</key><true/>'
        echo '    <key>ProcessType</key><string>Background</string>'
        echo "    <key>StandardOutPath</key><string>$HOME/.claude/state/login-alarm.launchd.log</string>"
        echo "    <key>StandardErrorPath</key><string>$HOME/.claude/state/login-alarm.launchd.log</string>"
        echo '</dict>'
        echo '</plist>'
    } >"$PLIST"
    [ "$MODE" != print-plist ] || exit 0
    if command -v launchctl >/dev/null 2>&1 && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ]; then
        launchctl bootout "$_domain/$LABEL" >/dev/null 2>&1 || true
        launchctl bootstrap "$_domain" "$PLIST" >/dev/null 2>&1 || \
            launchctl load "$PLIST" >/dev/null 2>&1 || true
        if ! launchctl print "$_domain/$LABEL" >/dev/null 2>&1; then
            echo "login-alarm: $LABEL was written to $PLIST but launchd did not load it; NOT scheduled" >&2
            exit 1
        fi
    fi
    echo "scheduled $LABEL every $SECONDS_BETWEEN seconds"
    echo "  plist: $PLIST"
    exit 0
fi

exec python3 "$LIB" "$@"
