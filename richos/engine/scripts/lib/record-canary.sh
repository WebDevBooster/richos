#!/usr/bin/env bash
#
# scripts/lib/record-canary.sh — DID THIS RUN TOUCH THE OPERATOR'S RECORD?
#
# ===========================================================================
# WHERE THIS CAME FROM — three instances of one class in two days
# ===========================================================================
# The leak canary (leak-canary.sh) watches CHECKOUTS. It says so in its own
# header: "It does NOT watch the rest of the filesystem or $HOME." Three suites
# then wrote into $HOME, and every one of them was green:
#
#   2026-09-10  finish-row-completion.test.sh wrote 130 `feedbeef` fixture rows
#               into ~/.claude/worker-events.jsonl, the platform's fallback
#               event log (Sage D4, round three).
#   2026-09-10  detect-nonnative-worktree.test.sh created
#               ~/.claude/teams/session-deadbeef/ with 25 KB of fixture names
#               (round 14, D4's sibling).
#   2026-09-11  session-start-stdin.test.sh case 9b ran the real SessionStart
#               reaper with a sandbox entity and an unredirected HOME. The
#               reaper read the operator's REAL team directories, discovered
#               the operator's REAL richos registry, judged a REAL agent's
#               cross-repository tree with an entity in which its shell could
#               not exist, and appended a `terminated` row (witness
#               platform-terminal-record, 2026-09-11T00:02:34.984941+00:00,
#               agent ae904aac1949e5696, sage-fable-cert3) to
#               ~/.claude/state/worktree-ledger.jsonl — for an agent whose
#               shell was LOCKED by a running pid. Both round-four reviewers
#               found it independently; the suite reported all 11 passed.
#
# Each was fixed in its suite with a both-arms control (F15/F16, L1/L2, 9l/9m).
# This file closes the CLASS: the runner takes a baseline of the operator's
# record before EVERY suite and compares after it, so the next suite that
# reaches $HOME is named on the day it is written, not found by a reviewer.
#
# ===========================================================================
# WHAT IS WATCHED, AND WHAT THE WITNESS IS FOR EACH
# ===========================================================================
# `<config>` is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` AS IT WAS WHEN THIS FILE
# WAS SOURCED — captured, never re-read, for the reason global-state-witness.sh
# gives: a suite that moves HOME halfway through would otherwise be compared
# against its own sandbox and always pass.
#
#   <config>/state/worktree-ledger.jsonl   THE OWNERSHIP LEDGER. Witness: every
#        row EXCEPT `event: finished`, by content hash. The exclusion is
#        deliberate and it is the one thing this canary cannot see: the
#        platform's own worker-ended-handoff.sh appends a `finished` row at
#        every helper turn of every live agent on the machine (68 rows during
#        Sage's round-four pass, 48 during Frank's), so a witness that counted
#        them would be red on nearly every suite of a live-machine run, and a
#        canary that cries wolf gets muted — the escalations suite's own reason
#        for counting fixture rows rather than total rows. A `finished` row is
#        advisory and never decisive (worktree-ledger.judge: "advisory, never
#        decisive"), so a leaked one is residue, not a false witness. Every
#        other event — registered, prepared, terminated, retracted — is
#        witnessed, and those are the rows that decide whether a workspace
#        may be destroyed.
#   <config>/worker-events.jsonl           THE FALLBACK EVENT LOG. Witness:
#        every line, by content hash. Only a session with NO team directory
#        writes here (worker-*-handoff.sh resolve_team_dir), so on a machine
#        where the running session has one it is stable across a run (250
#        lines before and after both round-four passes).
#   <config>/teams/                        THE TEAM DIRECTORIES. Witness: the
#        names of the `session-*` entries and of their immediate children —
#        never contents, which the live session's own logs churn.
#   <config>/state/workspaces/             THE WORKSPACE REGISTRY
#        (scripts/lib/workspaces.py). Witness: the names of its session and
#        agent records and every events.jsonl line, by content hash. A suite
#        that registers, lands or discards against it is writing the record
#        the Stop gate and the lock-out decide from (added 2026-09-11, the day
#        two suites wrote 55 test registrations into it before they were
#        sandboxed).
#
# ITS FALSE-POSITIVE VECTORS, NAMED: a real spawn during the run (a
# `registered`/`prepared` row from detect-nonnative-worktree.sh or
# create-teammate-worktree.sh), a real reap or removal (a `terminated` row), a
# session with no team directory writing to the fallback, or the platform
# creating a team directory or a first log file of a type in one. Each prints
# the row or entry it saw, so a reader recognizes the machine's own activity
# at once — the same trade the leak canary made for an engineer's own save.
# In CI none of the three paths exists, so there the witness is exact.
#
# A PATH IT CANNOT READ IS A FAILURE, NEVER A QUIET PASS. RC_HEALTHY carries
# it, exactly as LC_HEALTHY does for the leak canary.
#
# Safe to source repeatedly. Never writes anything under <config>.

if [ -n "${_RECORD_CANARY_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_RECORD_CANARY_SH_SOURCED=1

RC_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
RC_LEDGER="$RC_CFG/state/worktree-ledger.jsonl"
RC_FALLBACK="$RC_CFG/worker-events.jsonl"
RC_TEAMS="$RC_CFG/teams"
RC_WORKSPACES="$RC_CFG/state/workspaces"
RC_HEALTHY=1

# rc_paths — the watched paths, one per line (for a banner).
rc_paths() { printf '%s\n%s\n%s/\n%s/\n' "$RC_LEDGER" "$RC_FALLBACK" "$RC_TEAMS" "$RC_WORKSPACES"; }

# rc_snapshot — the witnessed state of the record on stdout, one entry per
# line, sorted. Exit 1 (and a line starting with UNREADABLE) when a present
# path could not be read.
rc_snapshot() {
    python3 - "$RC_LEDGER" "$RC_FALLBACK" "$RC_TEAMS" "$RC_WORKSPACES" <<'PY'
import hashlib, json, os, sys
ledger, fallback, teams, workspaces = sys.argv[1:5]
out, unreadable = [], False

def h(raw):
    return hashlib.sha256(raw).hexdigest()[:16]

if os.path.lexists(ledger):
    try:
        with open(ledger, "rb") as f:
            for raw in f:
                if not raw.strip():
                    continue
                try:
                    d = json.loads(raw.decode("utf-8"))
                except Exception:
                    out.append("ledger\tunparsable\t%s" % h(raw))
                    continue
                if not isinstance(d, dict):
                    out.append("ledger\tnot-an-object\t%s" % h(raw))
                    continue
                if d.get("event") == "finished":
                    continue          # the platform's per-turn row; see the header
                out.append("ledger\t%s\tevent=%s witness=%s source=%s teammate=%s agent=%s ts=%s"
                           % (h(raw), d.get("event"), d.get("witness") or "-", d.get("source") or "-",
                              d.get("teammate") or "-", d.get("agent_id") or "-", d.get("ts") or "-"))
    except OSError as e:
        out.append("UNREADABLE\tledger\t%s" % e); unreadable = True
else:
    out.append("ledger\tabsent")

if os.path.lexists(fallback):
    try:
        with open(fallback, "rb") as f:
            for n, raw in enumerate(f, 1):
                if not raw.strip():
                    continue
                label = ""
                try:
                    d = json.loads(raw.decode("utf-8"))
                    if isinstance(d, dict):
                        label = "event=%s agent=%s session=%s ts=%s" % (
                            d.get("event"), d.get("agent_id") or "-", d.get("session_id") or "-", d.get("timestamp") or "-")
                except Exception:
                    label = "unparsable"
                out.append("fallback\t%s\t%s" % (h(raw), label))
    except OSError as e:
        out.append("UNREADABLE\tfallback\t%s" % e); unreadable = True
else:
    out.append("fallback\tabsent")

if os.path.lexists(teams):
    try:
        for name in sorted(os.listdir(teams)):
            p = os.path.join(teams, name)
            out.append("teams\t%s%s" % (name, "/" if os.path.isdir(p) else ""))
            if os.path.isdir(p) and not os.path.islink(p):
                for child in sorted(os.listdir(p)):
                    out.append("teams\t%s/%s" % (name, child))
    except OSError as e:
        out.append("UNREADABLE\tteams\t%s" % e); unreadable = True
else:
    out.append("teams\tabsent")

if os.path.lexists(workspaces):
    try:
        for sub in ("sessions", "agents", "done"):
            d = os.path.join(workspaces, sub)
            if os.path.isdir(d):
                for name in sorted(os.listdir(d)):
                    out.append("workspaces\t%s/%s" % (sub, name))
        ev = os.path.join(workspaces, "events.jsonl")
        if os.path.exists(ev):
            with open(ev, "rb") as f:
                for raw in f:
                    if not raw.strip():
                        continue
                    label = ""
                    try:
                        d = json.loads(raw.decode("utf-8"))
                        if isinstance(d, dict):
                            label = "event=%s key=%s" % (d.get("event"), d.get("key") or d.get("session_id") or "-")
                    except Exception:
                        label = "unparsable"
                    out.append("workspaces\tevents.jsonl %s %s" % (h(raw), label))
    except OSError as e:
        out.append("UNREADABLE\tworkspaces\t%s" % e); unreadable = True
else:
    out.append("workspaces\tabsent")

print("\n".join(sorted(out)))
sys.exit(1 if unreadable else 0)
PY
}

# rc_baseline <file> — snapshot the record into <file>. Sets RC_HEALTHY=0 if
# any present path could not be read, so a later "untouched" can be refused.
rc_baseline() {
    RC_HEALTHY=1
    if ! rc_snapshot > "$1" 2>/dev/null; then
        RC_HEALTHY=0
    fi
    return 0
}

# rc_escaped <baseline-file> — every entry of the record that APPEARED or
# CHANGED since <baseline-file>, one per line, human-readable. Empty output
# means the record is as it was. A path that became unreadable is reported
# as UNREADABLE, never as unchanged.
rc_escaped() {
    local after
    after="$(mktemp)" || return 0
    if ! rc_snapshot > "$after" 2>/dev/null; then
        grep '^UNREADABLE' "$after" || printf 'UNREADABLE\n'
        rm -f "$after"
        return 0
    fi
    python3 - "$1" "$after" <<'PY'
import sys
before = set(l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.strip())
after = [l.rstrip("\n") for l in open(sys.argv[2], encoding="utf-8", errors="replace") if l.strip()]
seen = set()
for line in after:
    if line in before or line in seen:
        continue
    seen.add(line)
    kind, _sep, rest = line.partition("\t")
    if rest in ("absent",):
        continue
    if kind == "ledger":
        print("ledger row APPEARED: %s" % rest.split("\t", 1)[-1])
    elif kind == "fallback":
        print("fallback event log line APPEARED: %s" % rest.split("\t", 1)[-1])
    elif kind == "teams":
        print("team directory entry APPEARED: %s" % rest)
    elif kind == "workspaces":
        print("workspace registry entry APPEARED: %s" % rest)
    else:
        print(line)
# a path that was present and is now absent, or vice versa, is a change too
for kind in ("ledger", "fallback", "teams", "workspaces"):
    was = any(l.startswith(kind + "\t") for l in before)
    now = any(l.startswith(kind + "\t") for l in after)
    was_absent = (kind + "\tabsent") in before
    now_absent = (kind + "\tabsent") in set(after)
    if was_absent and not now_absent:
        print("%s: was ABSENT and now EXISTS" % kind)
    elif now_absent and not was_absent and was:
        print("%s: was present and is now ABSENT" % kind)
PY
    rm -f "$after"
    return 0
}
