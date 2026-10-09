#!/usr/bin/env bash
#
# review-watch.test.sh: THE SECOND REVIEW STARTS BY ITSELF (scripts/review-watch.sh
# running scripts/lib/review_watch.py), against fixture state and a fake
# second-review only. Never the operator's registry, ~/.claude/state, a real
# model or a real teammate.
#
# 2026-10-08: the CEO fetched a Codex review of an agent's work by hand four
# times. His words (ruling §113): "A regular RichOS user can never be expected
# anything even remotely close to that. So, this all must be completely
# automated." Every case below fails on a checkout without scripts/review-watch.sh.
#
#   W01  THE REPLAY of the 2026-10-08 dictation record (timestamps only:
#        registry rows and commit times, scripts/fixtures/review-watch-
#        dictation-2026-10-08.json), one look per minute from 02:52Z to 19:05Z:
#        a handover review starts within two looks of every handover of
#        dictation slices 1-4 (dict1, dict1b, dict1c, dict2, dict3, dict3b,
#        dict4, dict4c) and of slice 5 (dict5, dict5b, dict5c); at least one
#        mid-job review of echo-fable-dict5 starts before 15:03Z and none in a
#        teammate's first 60 minutes; the stopped and discarded dict4b gets
#        none; one tip is never reviewed twice at once; each handover tip is
#        reviewed once
#   W02  a lost review (it ends with no verdict) is started once more, and a
#        second loss is told once; nothing more starts for that commit
#   W03  a handover, end to end through the script: one review starts at the
#        first look, by registry key, on the agent's own commits only (the
#        merge base with main, which has moved on since), with the handover
#        trigger and the work's key; a second look starts nothing more (the
#        lock); the verdict is told once, with what the lead can do; told
#        again 30 minutes later while nobody continues the work, and not once
#        a continuation names it
#   W04  the long-job clock starts at the registry's start, never at git's
#        dates: a base committed a day before the start gets no review at a
#        commit five minutes in, and one 61 minutes in
#   W05  a running teammate gone quiet (no commit, no transcript write for 20
#        minutes) with unreviewed commits gets a review
#   W06  a handover replaces a mid-job review of the same tip: the mid-job
#        review is stopped by its recorded pid and the handover one starts
#   W07  Codex's READY entry starts a review of its codex/ branch, with the
#        to-codex.md entry that named the branch as the original words
#   W08  a finding still open through two rechecks in a row is told once as
#        not converging
#   W09  a repository not in SECOND_REVIEW_REPOS is never reviewed; with the
#        key absent it says so once and starts nothing
#   W10  monitors.json starts review-watch.sh --monitor always
#   W11  --host-json (the operator install's host child, slice 4): a look's notices
#        are one JSON line per lead session, for the host to send to that lead
#   W12  a verdict reaches its lead session even when the worker committed while
#        its review ran: by the review's own record (lock, then attempt row), and
#        by the work's stable identity when no record names it
#   W13  the host's quit (SIGTERM, five-second bound): the watcher stops every
#        review it started at once, escalating to SIGKILL itself, and exits on
#        its own inside the bound with none left running
#   W14  the app's watcher picks only receipts with request.role worker for a
#        mid-job review, never a quiet handover reviewer's cc/ workspace
#   W15  the host's quit records a review stopped only once its reviewer, which
#        leads its own session, is gone too (a responsive and a deaf launcher)
#   W16  a SIGTERM during spawn, before the review's pid reaches its lock, still
#        stops that review and settles it as stopped
#   W17  a verdict goes to the review's recorded owner first; a registry fallback
#        needs the same work, never another work holding the reviewed commit
#   W18  a SIGTERM while second-review starts its reviewer (fork done, Popen not
#        returned): the reviewer's group is registered first, then stopped; a
#        launcher wedged there past the grace is reached by a second read
#   W19  the repeated handover notice goes to the recorded owner of the same
#        work, on that work's own clock, never to another work at the tip
#   W20  the plain monitor prints a verdict only in its owner's session, unless
#        no live monitor of the owner will print it
#
# Every case loads scripts/lib/app_review.py too: review_watch.py imports its app_paths.
# The app mode (--app-state) and app_review.py's mid-job notice are driven over the real
# app fixture in mega-lander/tests/app.test.py.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
RW="$SCRIPT_DIR/review-watch.sh"
LIB="$SCRIPT_DIR/lib"
FIXTURE="$SCRIPT_DIR/fixtures/review-watch-dictation-2026-10-08.json"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
SB="$(scratch_new review-watch-test)" || { echo "FATAL: no scratch" >&2; exit 1; }
cleanup() {
    # A fake review still sleeping is stopped by the pid it recorded at its start.
    for f in "$SB"/calls/*/pid; do
        [ -f "$f" ] || continue
        p="$(cat "$f")"
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
    scratch_release "$SB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 -- $3"; fi; }
has()   { printf '%s' "$1" | grep -qF -- "$2"; }

echo "review-watch.test.sh"
[ -f "$RW" ] || echo "  (scripts/review-watch.sh is missing: every case below fails)"

# --- isolation -------------------------------------------------------------
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT RICHOS_ENGINE_ROOT CODEX_HOME REVIEW_WATCH_NOW
mkdir -p "$SB/bin" "$SB/calls" "$SB/claude" "$SB/workspaces/agents" "$SB/workspaces/done" "$SB/projects" "$SB/codex"
export CLAUDE_CONFIG_DIR="$SB/claude"
export RICHOS_WORKSPACES_DIR="$SB/workspaces"
export RICHOS_PROJECTS_DIR="$SB/projects"
export RICHOS_SESSIONS_DIR="$SB/sessions"
export REVIEW_WATCH_STATE_DIR="$SB/rw"
export SECOND_REVIEW_STATE_DIR="$SB/sr"
export REVIEW_WATCH_SECOND_REVIEW="$SB/bin/fake-second-review"
export REVIEW_WATCH_TO_RICH="$SB/codex/to-rich.md"
export REVIEW_WATCH_TO_CODEX="$SB/codex/to-codex.md"
export FAKE_CALLS="$SB/calls"

# =============================================================================
# W01, W02: the replay, driving the real watcher with a fixture world
# =============================================================================
python3 - "$LIB" "$FIXTURE" "$SB/replay" <<'PY' >"$SB/replay.out" 2>&1
import datetime, json, os, sys
lib, fixture, root = sys.argv[1:4]
os.makedirs(root)
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
results = {}
def say(case, ok, why=""):
    print("%s %s %s" % ("PASS" if ok else "FAIL", case, why))
try:
    import review_watch as rw
except Exception as exc:  # the watcher is missing: every case fails
    for c in ("W01", "W02"):
        say(c, False, "review_watch cannot be imported: %s" % exc)
    sys.exit(0)

def ep(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
def hm(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%H:%M:%SZ")

REPO = "/fixture/richos"
REVIEW_SECONDS = 30 * 60      # the first by-hand review's measured length (Sage's check §1.2)
data = json.load(open(fixture))
team = data["teammates"]
for t in team:
    t["start"] = ep(t["started_at"] or t["registered_at"])
    t["end"] = ep(t["end_at"])
    t["gone"] = ep(t["disposition"]["at"]) if t.get("disposition") else None
    for c in t["commits"]:
        c["t"] = ep(c["at"])
by_name = dict((t["name"], t) for t in team)

def root_of(t):
    while t["continues"]:
        t = by_name[t["continues"][0]]
    return t["name"]

class ReplayWorld(object):
    repos = ["richos"]
    def __init__(self):
        self.now = 0
    def registry_items(self, now, seen):
        items = []
        live = [t for t in team if t["start"] <= now and not (t["gone"] is not None and t["gone"] <= now)]
        continued = set(c for t in live for c in t["continues"])
        for t in live:
            commits = [c for c in t["commits"] if c["t"] <= now]
            if not commits:
                continue
            seen.setdefault("teammate:" + root_of(t), now)
            items.append(rw.Item("teammate:" + root_of(t), t["name"], REPO, commits[-1]["sha"], "base-" + t["name"],
                                 "ended" if t["end"] <= now else "running", started=t["start"], ref=t["name"],
                                 continued=t["name"] in continued))
        return items, []
    def codex_items(self, now, codex_state):
        return [], []

class ReplayWatcher(rw.Watcher):
    """The real watcher; only its processes are simulated."""
    def __init__(self, world, mode="pass"):
        rw.Watcher.__init__(self, "/fixture/engine", "/fixture/orchestration.config", world)
        self.mode = mode
        self.fake = {}            # pid -> review
        self.starts = []
        self.next_pid = 1000
        self.now = 0
    def spawn(self, item, trigger, log_path):
        self.next_pid += 1
        pid = self.next_pid
        self.fake[pid] = {"item": item, "trigger": trigger, "at": self.now, "end": self.now + REVIEW_SECONDS,
                          "stopped": False, "done": False}
        self.starts.append((self.now, item.name, item.tip, trigger, pid))
        return pid, "fake-%d" % pid
    def alive(self, info):
        f = self.fake.get(info.get("pid"))
        if f is None:
            return False
        if self.mode == "die":
            return False
        return not f["stopped"] and self.now < f["end"]
    def stop(self, info):
        f = self.fake.get(info.get("pid"))
        if f:
            f["stopped"] = True
    def finish_due(self, now):
        """A fake review that reached its end writes its ledger row, as second-review does."""
        for pid, f in sorted(self.fake.items()):
            if f["done"] or f["stopped"] or now < f["end"] or self.mode == "die":
                continue
            f["done"] = True
            it = f["item"]
            rid = "rv-fake-%d" % pid
            rec = os.path.join(os.environ["SECOND_REVIEW_STATE_DIR"], "reviews", rid)
            os.makedirs(rec)
            verdict = "changes-requested" if (it.name == "echo-fable-dict5" and f["trigger"] == "handover") else "passed"
            findings = [{"priority": 2, "title": "a fake finding", "files": ["x.rs:1"], "evidence": "e", "fixture": ""}] \
                if verdict != "passed" else []
            json.dump({"answer": {"findings": findings, "earlier_findings": []}, "earlier_findings_in": []},
                      open(os.path.join(rec, "verdict.json"), "w"))
            rw.append_jsonl(rw.review_ledger(), {
                "id": rid, "at": rw.iso(f["at"]), "repo": REPO, "tip": it.tip, "work": it.work, "trigger": f["trigger"],
                "verdict": verdict, "findings": len(findings), "p1": 0, "reviewer": "codex",
                "reviewer_model": "gpt-6.1-sol", "author": it.name, "record": rec})

def run(watcher, t0, t1, step=60):
    out = []
    sd = rw.session_dir("replay-session")
    t = t0
    while t <= t1:
        watcher.now = t
        watcher.finish_due(t)
        # concurrency check: no two live fake reviews of one tip at once
        live = [(f["item"].repo, f["item"].tip) for f in watcher.fake.values()
                if not f["stopped"] and not f["done"] and f["at"] <= t < f["end"] and watcher.mode != "die"]
        if len(live) != len(set(live)):
            out.append(("DOUBLE", t, live))
        import io
        buf = io.StringIO()
        rw.tick(watcher, sd, now=t, out=buf)
        if buf.getvalue():
            out.append(("TOLD", t, buf.getvalue()))
        t += step
    return out

# -- W01 ----------------------------------------------------------------------
w = ReplayWatcher(ReplayWorld())
t0 = min(t["start"] for t in team) - 60
t1 = max(t["end"] for t in team) + 30 * 60
log = run(w, t0, t1)
problems = []
for t in team:
    if not t["commits"]:
        mine = [s for s in w.starts if s[1] == t["name"]]
        if mine:
            problems.append("%s has no commits but got %d review(s)" % (t["name"], len(mine)))
        continue
    final = [c for c in t["commits"] if c["t"] <= t["end"]][-1]["sha"]
    ho = [s for s in w.starts if s[1] == t["name"] and s[2] == final and s[3] == "handover"]
    if len(ho) != 1:
        problems.append("%s: %d handover reviews of its final tip %s" % (t["name"], len(ho), final))
    elif not (t["end"] <= ho[0][0] <= t["end"] + 120):
        problems.append("%s: its handover review started at %s, not within two looks of its end %s" % (
            t["name"], hm(ho[0][0]), hm(t["end"])))
    early = [s for s in w.starts if s[1] == t["name"] and s[3] == "long-job" and s[0] < t["start"] + 3600]
    if early:
        problems.append("%s: a long-job review at %s, inside its first 60 minutes" % (t["name"], hm(early[0][0])))
    print("  replay: %-20s start %s end %s | %s" % (t["name"], hm(t["start"]), hm(t["end"]), ", ".join(
        "%s %s@%s" % (s[3], hm(s[0]), s[2]) for s in w.starts if s[1] == t["name"])))
d5 = by_name["echo-fable-dict5"]
mid = [s for s in w.starts if s[1] == "echo-fable-dict5" and s[3] in ("long-job", "quiet")]
before = [s for s in mid if s[0] < ep("2026-10-08T15:03:00Z")]
if not before:
    problems.append("no mid-job review of echo-fable-dict5 started before 15:03Z (mid-job starts: %s)" % [hm(s[0]) for s in mid])
doubles = [x for x in log if x[0] == "DOUBLE"]
if doubles:
    problems.append("one tip reviewed twice at once at %s: %s" % (hm(doubles[0][1]), doubles[0][2]))
slices = ["echo-opus-dict1", "echo-opus-dict1b", "echo-opus-dict1c", "echo-opus-dict2", "echo-opus-dict3",
          "echo-sonnet-dict3b", "echo-opus-dict4", "echo-opus-dict4c"]
missing = [n for n in slices if n not in by_name]
if missing:
    problems.append("the fixture lacks %s" % missing)
told = "".join(x[2] for x in log if x[0] == "TOLD")
if told.count("[CHANGES-REQUESTED] echo-fable-dict5, handover review") != 1:
    problems.append("dict5's changes-requested handover verdict was told %d times, not once (dict5b continues it)"
                    % told.count("[CHANGES-REQUESTED] echo-fable-dict5, handover review"))
say("W01", not problems, "; ".join(problems) or "%d reviews started; dict5 mid-job at %s" % (
    len(w.starts), ", ".join(hm(s[0]) for s in mid)))

# -- W02 ----------------------------------------------------------------------
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw-lost")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr-lost")
one = dict(by_name["echo-opus-dict1c"])
team[:] = [one]
w2 = ReplayWatcher(ReplayWorld(), mode="die")
log2 = run(w2, one["end"], one["end"] + 10 * 60)
told2 = "".join(x[2] for x in log2 if x[0] == "TOLD")
starts = [s for s in w2.starts]
ok2 = len(starts) == 2 and told2.count("[NO VERDICT TWICE] echo-opus-dict1c") == 1
say("W02", ok2, "starts=%s told=%r" % ([(hm(s[0]), s[3]) for s in starts], told2[:600]))
PY
REPLAY="$(cat "$SB/replay.out")"
grep '^  replay:' "$SB/replay.out" | sed 's/^/    /'
for c in W01 W02; do
    line="$(grep "^[A-Z]* $c " "$SB/replay.out" | head -1)"
    case "$line" in
        "PASS $c "*) ok "$c ${line#PASS $c }" ;;
        "FAIL $c "*) bad "$c ${line#FAIL $c }" ;;
        *) bad "$c did not run: $(tail -5 "$SB/replay.out" | tr '\n' ' ')" ;;
    esac
done

# =============================================================================
# W03-W10: the real script, a fixture registry and repository, a fake review
# =============================================================================
cat >"$SB/bin/fake-second-review" <<'SH'
#!/usr/bin/env bash
exec python3 "$(dirname "$0")/fake-sr.py" "$@"
SH
cat >"$SB/bin/fake-sr.py" <<'PY'
#!/usr/bin/env python3
"""Records its arguments; FAKE_SR_MODE: sleep (runs until stopped), else writes
one ledger row with that verdict, as second-review does, and ends."""
import json, os, sys, time
argv = sys.argv[1:]
log = os.environ["FAKE_CALLS"]
d = os.path.join(log, "%02d" % len(os.listdir(log)))
os.makedirs(d)
json.dump(argv, open(os.path.join(d, "argv.json"), "w"))
open(os.path.join(d, "pid"), "w").write(str(os.getpid()))
words = []
for i, a in enumerate(argv):
    if a == "--words-file":
        words.append(open(argv[i + 1]).read())
open(os.path.join(d, "words.txt"), "w").write("".join(words))
mode = os.environ.get("FAKE_SR_MODE", "passed")
if mode == "sleep":
    time.sleep(600)
    sys.exit(0)
val = lambda k: argv[argv.index(k) + 1] if k in argv else ""
repo = os.path.realpath(val("--repo"))
state = os.environ["SECOND_REVIEW_STATE_DIR"]
rid = "rv-fake-%s" % os.path.basename(d)
rec = os.path.join(state, "reviews", rid)
os.makedirs(rec)
findings = [] if mode == "passed" else [{"priority": 2, "title": "Shutdown leaves audio on disk", "files": ["a.txt:1"],
                                         "evidence": "e", "fixture": ""}]
json.dump({"answer": {"findings": findings, "earlier_findings": []}, "earlier_findings_in": []},
          open(os.path.join(rec, "verdict.json"), "w"))
at = float(os.environ.get("REVIEW_WATCH_NOW") or time.time())
row = {"id": rid, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)), "repo": repo, "tip": val("--tip"),
       "work": val("--work"), "trigger": val("--trigger"), "verdict": mode, "findings": len(findings), "p1": 0,
       "reviewer": "codex", "reviewer_model": "gpt-6.1-sol", "author": "x", "record": rec}
with open(os.path.join(state, "reviews.jsonl"), "a") as f:
    f.write(json.dumps(row) + "\n")
PY
chmod +x "$SB/bin/fake-second-review" "$SB/bin/fake-sr.py"
mkdir -p "$SB/sr"

REPO="$SB/richos"
G() { git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=Author -c user.email=author@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$REPO"
G init -q -b main
printf 'base\n' >"$REPO/a.txt"
GIT_COMMITTER_DATE="2026-10-07T09:00:00Z" GIT_AUTHOR_DATE="2026-10-07T09:00:00Z" G add -A
GIT_COMMITTER_DATE="2026-10-07T09:00:00Z" GIT_AUTHOR_DATE="2026-10-07T09:00:00Z" G commit -qm "base, a day old"
BASE="$(G rev-parse HEAD)"
G checkout -qb cc/echo-sonnet-w1
printf 'base\nmine\n' >"$REPO/a.txt"
G commit -qam "the agent's own commit"
TIP="$(G rev-parse HEAD)"
G checkout -q main
printf 'unrelated\n' >"$REPO/b.txt"
G add -A; G commit -qm "an unrelated main commit, after the branch point"
G checkout -q cc/echo-sonnet-w1
printf 'SECOND_REVIEW_REPOS="richos"\n' >"$SB/orchestration.config"
cfg() { printf '%s\n' "$1" >"$SB/orchestration.config"; }

# reg <name> <started-ago-seconds> <ended-ago-seconds or -> [continues-key] : one registry record
reg() {
    python3 - "$SB" "$REPO" "$@" <<'PY'
import json, os, sys, time
sb, repo, name, started_ago, ended_ago = sys.argv[1:6]
cont = sys.argv[6:]
now = time.time()
key = "sess-w--" + name
rec = {"key": key, "name": name, "agent_id": "", "registered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - float(started_ago))),
       "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - float(started_ago))),
       "end": None if ended_ago == "-" else {"at": now - float(ended_ago), "signal": "SubagentStop"},
       "handed_in": None, "pause": None, "disposition": None, "continues": cont, "orphan": False,
       "workspaces": [{"kind": "cc", "repo": repo, "path": repo, "branch": "cc/" + name, "deleted_at": None},
                      {"kind": "native", "repo": os.path.join(sb, "femcboost"), "path": os.path.join(sb, "femcboost"),
                       "branch": "worktree-agent-x", "deleted_at": None}]}
json.dump(rec, open(os.path.join(sb, "workspaces", "agents", key + ".json"), "w"))
json.dump({"repos": [os.path.realpath(repo)]}, open(os.path.join(sb, "workspaces", "repos.json"), "w"))
PY
}
tickrw() { OUT="$(RICHOS_ENTITY_ROOT="$SB" bash "$RW" --tick 2>&1)"; RC=$?; }
ncalls() { ls "$SB/calls" | wc -l | tr -d ' '; }
lastargv() { cat "$(ls -d "$SB"/calls/* | tail -1)/argv.json" 2>/dev/null; }
resetstate() { rm -rf "$SB/rw" "$SB/sr" "$SB/calls" "$SB/workspaces/agents"; mkdir -p "$SB/sr" "$SB/calls" "$SB/workspaces/agents"; }
waitcalls() { for _ in $(seq 1 100); do [ "$(ncalls)" -ge "$1" ] && break; sleep 0.1; done; }
waitrows() {
    for _ in $(seq 1 100); do
        if [ -f "$SB/sr/reviews.jsonl" ] && [ "$(wc -l <"$SB/sr/reviews.jsonl" | tr -d ' ')" -ge "$1" ]; then break; fi
        sleep 0.1
    done
}

# --- W03 ---------------------------------------------------------------------
resetstate
reg echo-sonnet-w1 600 30
FAKE_SR_MODE=changes-requested tickrw
waitcalls 1; waitrows 1
A="$(lastargv)"
[ "$RC" -eq 0 ] && [ "$(ncalls)" = "1" ] && has "$A" '"--name", "sess-w--echo-sonnet-w1"' && has "$A" "\"--tip\", \"$TIP\"" \
  && has "$A" "\"--base\", \"$BASE\"" && has "$A" '"--trigger", "handover"' && has "$A" '"--work", "teammate:sess-w--echo-sonnet-w1"'
check "W03 a handover starts one review at the first look: by key, the agent's own commits only, the handover trigger" $? "rc=$RC calls=$(ncalls) argv=$A out=$OUT"
FAKE_SR_MODE=changes-requested tickrw
[ "$(ncalls)" = "1" ] && has "$OUT" "[CHANGES-REQUESTED] echo-sonnet-w1, handover review" && has "$OUT" "continues: echo-sonnet-w1" \
  && has "$OUT" "Shutdown leaves audio on disk"
check "W03 the verdict is told once with its findings and what the lead can do; no second review of the tip" $? "calls=$(ncalls) out=$OUT"
tickrw
[ -z "$OUT" ]; check "W03 the next look tells nothing again" $? "out=$OUT"
REVIEW_WATCH_NOW="$(python3 -c 'import time; print(time.time() + 31 * 60)')" tickrw
has "$OUT" "told again, notice 2"; check "W03 unhandled after 30 minutes: told again" $? "out=$OUT"
reg echo-sonnet-w1b 60 - sess-w--echo-sonnet-w1
REVIEW_WATCH_NOW="$(python3 -c 'import time; print(time.time() + 65 * 60)')" tickrw
[ "$RC" -eq 0 ] && ! has "$OUT" "[CHANGES-REQUESTED] echo-sonnet-w1,"; check "W03 once a continuation names the work, it is not told again" $? "out=$OUT"

# --- W11 ---------------------------------------------------------------------
# The operator install's host child (slice 4, Sage's check §1.3): --host-json prints each
# look's notices as one JSON line per lead session, so the host can send each to the lead
# whose session registered the work, as a message of its own.
resetstate
reg echo-sonnet-w1 600 30
python3 - "$SB" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "workspaces", "agents", "sess-w--echo-sonnet-w1.json")
r = json.load(open(p)); r["session_id"] = "lead-session-1"
json.dump(r, open(p, "w"))
PY
OUT="$(RICHOS_ENTITY_ROOT="$SB" FAKE_SR_MODE=changes-requested bash "$RW" --tick --host-json 2>&1)"; RC=$?
waitcalls 1; waitrows 1
OUT="$(RICHOS_ENTITY_ROOT="$SB" bash "$RW" --tick --host-json 2>&1)"; RC=$?
printf '%s\n' "$OUT" | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
rows = [json.loads(l) for l in lines]
assert len(rows) == 1, rows
assert rows[0]["session"] == "lead-session-1", rows
assert "[CHANGES-REQUESTED] echo-sonnet-w1, handover review" in rows[0]["text"], rows
assert rows[0]["text"].startswith("REVIEW-WATCH "), rows
'
check "W11 --host-json: the verdict is one JSON line for the lead session that registered the work" $? "rc=$RC out=$OUT"

# --- W12 ---------------------------------------------------------------------
# Second review of cc/echo-opus-review4 at cac403f77, finding 1 (fixtures/operator_notice.py):
# the lead session was found only through an item at the reviewed tip, so a worker that committed
# while its review ran got its verdict sent to session "", which the host refuses, while the
# consumed-row cursor moved on: the verdict was lost.
resetstate
reg echo-sonnet-w1 3660 -
python3 - "$SB" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "workspaces", "agents", "sess-w--echo-sonnet-w1.json")
r = json.load(open(p)); r["session_id"] = "lead-session-1"
json.dump(r, open(p, "w"))
PY
OUT="$(RICHOS_ENTITY_ROOT="$SB" FAKE_SR_MODE=changes-requested bash "$RW" --tick --host-json 2>&1)"; RC=$?
waitcalls 1; waitrows 1
printf 'base\nmine\nmore\n' >"$REPO/a.txt"
G commit -qam "the worker commits again while its review runs"
OUT="$(RICHOS_ENTITY_ROOT="$SB" bash "$RW" --tick --host-json 2>&1)"; RC=$?
G reset -q --hard "$TIP"
printf '%s\n' "$OUT" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
assert len(rows) == 1, rows
assert rows[0]["session"] == "lead-session-1", rows
assert "[CHANGES-REQUESTED] " in rows[0]["text"] and "mid-job (long-job)" in rows[0]["text"], rows
'
check "W12 the worker committed while its review ran: the verdict still goes to its lead session (the review's record)" $? \
    "rc=$RC out=$OUT"
python3 - "$LIB" "$SB/w12" <<'PY'
import json, os, sys
lib, root = sys.argv[1:3]
os.makedirs(root)
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
import review_watch as rw
rw.HOST_JSON["on"] = True
repo = os.path.realpath(os.path.join(root, "fictional-repo"))
old, new = "a" * 40, "b" * 40
row = {"id": "review-1", "repo": repo, "tip": old, "work": "teammate:worker", "trigger": "long-job",
       "verdict": "changes-requested", "findings": 1, "p1": 1, "author": "worker", "reviewer": "claude",
       "reviewer_model": "opus"}
got = {}
for label, tip in (("unchanged tip", old), ("worker committed during review", new)):
    item = rw.Item("teammate:worker", "worker", repo, tip, "c" * 40, "running")
    item.session = "lead-session-1"
    state = {"rows": 0}
    notice = json.loads(rw.tell(10000, state, [row], rw.Book([row], {}, []), [item], [], [])[0])
    got[label] = (notice["session"], state["rows"])
print(got)
sys.exit(0 if all(v == ("lead-session-1", 1) for v in got.values()) else 1)
PY
check "W12 with no record of the review, the work's stable identity names the lead session (the reviewer's fixture)" $? "see above"

# --- W13 ---------------------------------------------------------------------
# Finding 2 (fixtures/shutdown.py): the host gives the watcher five seconds after SIGTERM
# (review_watch.rs STOP_BOUND), and stop_own stopped reviews one after another with ten seconds
# each before SIGKILL; reviews lead their own sessions, so the host's group SIGKILL left them
# running. Two reviews that ignore SIGTERM, the real run_host_loop and its SIGTERM path.
cat >"$SB/w13.py" <<'PY'
import json, os, signal, subprocess, sys, time
lib, root = sys.argv[1], sys.argv[2]
STAND_IN = ("import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "print('ready',flush=True); time.sleep(60)")
if len(sys.argv) > 3:
    # The watcher: the host's child, owning two review stand-ins, each in its own session.
    os.environ["REVIEW_WATCH_STATE_DIR"] = root
    os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "reviews")
    os.environ["REVIEW_WATCH_POLL_SECONDS"] = "0.2"
    sys.path.insert(0, lib)
    import review_watch as rw

    class Quiet(rw.Watcher):
        told = False
        def look(self, now, session_state):
            if not self.told:                       # the SIGTERM handlers are in place by now
                self.told = True
                print("ready", flush=True)
            return []
    watcher = Quiet("/fixture/engine", "", world=object())
    owned = []
    for n in range(2):
        p = subprocess.Popen([sys.executable, "-c", STAND_IN], stdout=subprocess.PIPE, text=True,
                             start_new_session=True)
        assert p.stdout.readline().strip() == "ready"
        watcher.children[p.pid] = p
        owned.append(p.pid)
        lock = os.path.join(root, "locks", "%d.lock" % n)
        os.makedirs(os.path.dirname(lock), exist_ok=True)
        json.dump({"pid": p.pid, "repo": "fictional", "tip": str(n), "started_at": time.time()}, open(lock, "w"))
    json.dump(owned, open(os.path.join(root, "pids.json"), "w"))
    sys.exit(rw.run_host_loop(watcher, "app"))

def exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
os.makedirs(root)
p = subprocess.Popen([sys.executable, os.path.abspath(__file__), lib, root, "watcher"], stdout=subprocess.PIPE,
                     text=True, start_new_session=True)
pids, ok = [], False
try:
    assert p.stdout.readline().strip() == "ready"
    pids = json.load(open(os.path.join(root, "pids.json")))
    t0 = time.monotonic()
    os.kill(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=5)                           # the host's STOP_BOUND
        killed = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)            # what the host does at the bound
        p.wait(timeout=3)
        killed = True
    took = time.monotonic() - t0
    time.sleep(0.2)
    alive = [x for x in pids if exists(x)]
    try:
        outcomes = [json.loads(l)["outcome"] for l in open(os.path.join(root, "attempts.jsonl"))]
    except OSError:
        outcomes = []
    print("host bound=5s, watcher exit=%s after %.2fs (killed by the host: %s), reviews still alive=%d of %d, "
          "attempts=%s" % (p.returncode, took, killed, len(alive), len(pids), outcomes))
    ok = not killed and not alive and outcomes == ["stopped", "stopped"]
finally:
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    for x in pids:
        try:
            os.killpg(x, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
sys.exit(0 if ok else 1)
PY
W13OUT="$(python3 "$SB/w13.py" "$LIB" "$SB/w13" 2>&1)"; W13RC=$?
printf '    %s\n' "$W13OUT"
check "W13 the host's quit: every review is stopped at once, inside the five-second bound, none left running" $W13RC \
    "$W13OUT"

# --- W14 ---------------------------------------------------------------------
# Finding 3 (fixtures/reviewer_as_worker.py): AppWorld took every cc/ workspace as implementation
# work, and a handover reviewer gets one at the worker's commit, so a quiet or long reviewer was
# itself picked for a mid-job review whose verdict could never reach the worker.
python3 - "$LIB" "$SB/w14" <<'PY'
import json, os, sys
from types import SimpleNamespace
from unittest.mock import patch
lib, root = sys.argv[1:3]
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
import review_watch as rw
app = os.path.join(root, "app")
part = os.path.join(app, "workspaces", "p" * 64)
receipts = os.path.join(app, "work-receipts", "p" * 64)
os.makedirs(part)
os.makedirs(receipts)
repo = os.path.join(root, "fictional-project")
recs = []
for n, (name, role) in enumerate((("mark-sonnet-w", "worker"), ("frank-opus-review", "reviewer"))):
    json.dump({"id": "r%d" % n, "name": name, "request": {"role": role}},
              open(os.path.join(receipts, "r%d.json" % n), "w"))
    recs.append({"key": "lead--" + name, "name": name, "session_id": "lead",
                 "registered_at": "2026-10-09T00:00:00Z", "started_at": "2026-10-09T00:00:00Z",
                 "workspaces": [{"kind": "cc", "repo": repo, "path": os.path.join(repo, name), "branch": "cc/" + name}]})
world = rw.AppWorld.__new__(rw.AppWorld)
world.app_state, world.claude, world.repos, world._merge_bases = app, "fictional-claude", ["(every)"], {}
world.ws = SimpleNamespace(all_agents=lambda: recs, finished_state=lambda r, c: (False, False, ""), _chain=lambda r: [r])
world.src = SimpleNamespace()
now = rw.parse_iso("2026-10-09T01:01:00Z")
with patch.object(world, "integration_tip", return_value=("b" * 40, "")), \
     patch.object(world, "merge_base", return_value="b" * 40), \
     patch.object(rw, "git", return_value="a" * 40), \
     patch.object(rw.stall_watch, "_git_last_commit", return_value=None), \
     patch.object(rw.stall_watch, "_transcript", return_value=""):
    seen = {}
    items, _problems = world.registry_items(now, seen)
    due = rw.due(items, rw.Book([], {}, []), now, seen, 3600, handover=False)
picked = [(i.name, t) for i, t, _ in due]
print("picked for a mid-job review:", picked)
sys.exit(0 if picked == [("mark-sonnet-w", "long-job")] else 1)
PY
check "W14 the app's watcher reviews mid-job only receipts with request.role worker, never a handover reviewer" $? "see above"

# --- W15 ---------------------------------------------------------------------
# Second review of cc/echo-opus-review4b at f14155545, finding 1 (fixtures/shutdown_descendant.py):
# second-review's reviewer leads its own session, so the watcher's SIGTERM to the launcher's group
# never reaches it; _on_stop sent it one SIGTERM and exited at once, and stop_all, seeing the
# launcher gone, recorded "stopped" over a reviewer that ignores SIGTERM and runs on. Two
# launchers: the real second_review._on_stop and run_bounded ("responsive"), and one that ignores
# SIGTERM itself ("deaf"), whose reviewer only the watcher can stop.
cat >"$SB/w15.py" <<'PY'
import json, os, signal, subprocess, sys, time
lib, root, mode = sys.argv[1], sys.argv[2], sys.argv[3]
role = sys.argv[4] if len(sys.argv) > 4 else ""
sys.path.insert(0, lib)
REVIEWER = ("import os,signal,sys,time\n"
            "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            "open(os.path.join(sys.argv[1],'reviewer.pid'),'w').write(str(os.getpid()))\n"
            "while True:\n"
            "    open(os.path.join(sys.argv[1],'heartbeat'),'w').write(str(time.monotonic()))\n"
            "    time.sleep(0.05)\n")
if role == "launcher":
    if mode == "responsive":
        import second_review as sr
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, sr._on_stop)
        sr.run_bounded([sys.executable, "-B", "-c", REVIEWER, root], root, "", os.devnull, os.devnull, 60)
    else:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        subprocess.Popen([sys.executable, "-B", "-c", REVIEWER, root], start_new_session=True).wait()
    sys.exit(0)
if role == "watcher":
    os.environ["REVIEW_WATCH_STATE_DIR"] = root
    os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "reviews")
    os.environ["REVIEW_WATCH_POLL_SECONDS"] = "0.1"
    import review_watch as rw

    class Quiet(rw.Watcher):
        told = False
        def look(self, now, session_state):
            if not self.told:                       # the SIGTERM handlers are in place by now
                self.told = True
                print("ready", flush=True)
            return []
    w = Quiet("/fixture/engine", "", world=object())
    p = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), lib, root, mode, "launcher"],
                         start_new_session=True)
    w.children[p.pid] = p
    open(os.path.join(root, "launcher.pid"), "w").write(str(p.pid))
    os.makedirs(os.path.join(root, "locks"))
    json.dump({"pid": p.pid, "repo": "fictional", "tip": "a" * 40, "started_at": time.time()},
              open(os.path.join(root, "locks", "one.lock"), "w"))
    deadline = time.monotonic() + 5
    while not os.path.exists(os.path.join(root, "reviewer.pid")):
        if time.monotonic() > deadline:
            raise SystemExit("the reviewer did not start")
        time.sleep(0.01)
    sys.exit(rw.run_host_loop(w, "app"))

def exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
os.makedirs(root)
watcher = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), lib, root, mode, "watcher"],
                           stdout=subprocess.PIPE, text=True, start_new_session=True)
reviewer = launcher = None
ok = False
try:
    assert watcher.stdout.readline().strip() == "ready"
    launcher = int(open(os.path.join(root, "launcher.pid")).read())
    reviewer = int(open(os.path.join(root, "reviewer.pid")).read())
    t0 = time.monotonic()
    os.kill(watcher.pid, signal.SIGTERM)
    try:
        watcher.wait(timeout=5)                     # the host's STOP_BOUND
        killed = False
    except subprocess.TimeoutExpired:
        os.killpg(watcher.pid, signal.SIGKILL)
        watcher.wait(timeout=3)
        killed = True
    took = time.monotonic() - t0
    for _ in range(20):                             # an exited reviewer is reaped by launchd, not by us
        if not exists(reviewer):
            break
        time.sleep(0.05)
    beat = open(os.path.join(root, "heartbeat")).read()
    time.sleep(0.3)
    advanced = beat != open(os.path.join(root, "heartbeat")).read()
    try:
        outcomes = [json.loads(l)["outcome"] for l in open(os.path.join(root, "attempts.jsonl"))]
    except OSError:
        outcomes = []
    print("%s launcher: watcher exit=%s after %.2fs (killed by the host: %s), launcher alive=%s, reviewer alive=%s, "
          "heartbeat advanced=%s, attempts=%s" % (mode, watcher.returncode, took, killed, exists(launcher),
                                                  exists(reviewer), advanced, outcomes))
    ok = not killed and not exists(launcher) and not exists(reviewer) and not advanced and outcomes == ["stopped"]
finally:
    for pid in (reviewer, launcher):
        if pid:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    if watcher.poll() is None:
        os.killpg(watcher.pid, signal.SIGKILL)
        watcher.wait()
sys.exit(0 if ok else 1)
PY
for mode in responsive deaf; do
    W15OUT="$(python3 "$SB/w15.py" "$LIB" "$SB/w15-$mode" "$mode" 2>&1)"; W15RC=$?
    printf '    %s\n' "$W15OUT"
    check "W15 the host's quit ($mode launcher): stopped is recorded only once the reviewer's own group is gone" \
        $W15RC "$W15OUT"
done

# --- W16 ---------------------------------------------------------------------
# Finding 2 (fixtures/shutdown_during_spawn.py): stop_own stopped only reviews whose pid was in
# their lock, and the pid reaches the lock after spawn returns; a SIGTERM in between (here inside
# the process-start lookup, and inside Popen itself after the fork) left a review that leads its
# own session running. The real spawn, start, run_host_loop and stop_own.
cat >"$SB/w16.py" <<'PY'
import json, os, shlex, signal, subprocess, sys, time
lib, root, window = sys.argv[1], sys.argv[2], sys.argv[3]
role = sys.argv[4] if len(sys.argv) > 4 else ""
sys.path.insert(0, lib)
if role == "review":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(os.path.join(root, "review.pid"), "w").write(str(os.getpid()))
    while True:
        open(os.path.join(root, "heartbeat"), "w").write(str(time.monotonic()))
        time.sleep(0.05)

def started():
    deadline = time.monotonic() + 5
    while not os.path.exists(os.path.join(root, "heartbeat")):
        if time.monotonic() > deadline:
            raise RuntimeError("the fixture review did not start")
        time.sleep(0.01)

if role == "watcher":
    os.environ["REVIEW_WATCH_STATE_DIR"] = root
    os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "reviews")
    os.environ["REVIEW_WATCH_SECOND_REVIEW"] = os.path.join(root, "fake-review.sh")
    import review_watch as rw
    if window == "in-popen":
        real = subprocess.Popen

        class Interrupted(real):
            fired = False
            def __init__(self, *a, **k):
                real.__init__(self, *a, **k)
                if k.get("start_new_session") and not Interrupted.fired:
                    Interrupted.fired = True        # the fork is done; Popen has not returned yet
                    started()
                    os.kill(os.getpid(), signal.SIGTERM)
                    time.sleep(0.5)
        rw.subprocess.Popen = Interrupted

    class Interrupting(rw.Watcher):
        def process_start(self, pid):
            if window == "process-start":         # the real spawn's first call after the Popen
                started()
                os.kill(os.getpid(), signal.SIGTERM)
                time.sleep(0.5)
            return rw.Watcher.process_start(pid)
        def look(self, now, state):
            item = rw.Item("teammate:fixture", "fixture", root, "a" * 40, "b" * 40, "running")
            self.start(item, "long-job", now, 1)
            return []
    sys.exit(rw.run_host_loop(Interrupting("/fixture/engine", "", world=object()), "app"))

def exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
os.makedirs(root)
runner = "exec " + " ".join(shlex.quote(s) for s in [sys.executable, "-B", os.path.abspath(__file__), lib, root,
                                                      window, "review"])
open(os.path.join(root, "fake-review.sh"), "w").write("#!/bin/bash\n" + runner + "\n")
watcher = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), lib, root, window, "watcher"],
                           start_new_session=True)
review, ok = None, False
try:
    try:
        watcher.wait(timeout=5)
        killed = False
    except subprocess.TimeoutExpired:
        os.killpg(watcher.pid, signal.SIGKILL)
        watcher.wait(timeout=3)
        killed = True
    review = int(open(os.path.join(root, "review.pid")).read())
    for _ in range(20):
        if not exists(review):
            break
        time.sleep(0.05)
    beat = open(os.path.join(root, "heartbeat")).read()
    time.sleep(0.3)
    advanced = beat != open(os.path.join(root, "heartbeat")).read()
    locks = [json.load(open(os.path.join(root, "locks", f))) for f in os.listdir(os.path.join(root, "locks"))
             if f.endswith(".lock")]
    try:
        outcomes = [json.loads(l)["outcome"] for l in open(os.path.join(root, "attempts.jsonl"))]
    except OSError:
        outcomes = []
    print("SIGTERM %s: watcher exit=%s (killed: %s), locks left=%s, review alive=%s, heartbeat advanced=%s, "
          "attempts=%s" % (window, watcher.returncode, killed, [l.get("pid") for l in locks], exists(review),
                           advanced, outcomes))
    ok = not killed and not locks and not exists(review) and not advanced and outcomes == ["stopped"]
finally:
    if review:
        try:
            os.killpg(review, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    if watcher.poll() is None:
        os.killpg(watcher.pid, signal.SIGKILL)
        watcher.wait()
sys.exit(0 if ok else 1)
PY
for window in process-start in-popen; do
    W16OUT="$(python3 "$SB/w16.py" "$LIB" "$SB/w16-$window" "$window" 2>&1)"; W16RC=$?
    printf '    %s\n' "$W16OUT"
    check "W16 a SIGTERM during spawn ($window): the partly registered review is stopped and settled as stopped" \
        $W16RC "$W16OUT"
done

# --- W17 ---------------------------------------------------------------------
# Finding 3 (fixtures/verdict_owner_collision.py): owner_session took the first item at the
# reviewed repository and tip, whatever its work, before the review's own record; once the worker
# moved on and another work held that commit, the verdict went to that other lead.
python3 - "$LIB" "$SB/w17" <<'PY'
import os, sys
lib, root = sys.argv[1:3]
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
import review_watch as rw
repo = os.path.realpath(os.path.join(root, "fictional-repository"))
old, new = "a" * 40, "b" * 40
row = {"repo": repo, "tip": old, "work": "teammate:lead-A--worker"}
owner = rw.Item(row["work"], "worker", repo, new, "c" * 40, "running")
owner.session = "lead-A"
other = rw.Item("teammate:lead-B--reviewer", "reviewer", repo, old, "c" * 40, "running")
other.session = "lead-B"
record = {"repo": repo, "tip": old, "work": row["work"], "session": "lead-A"}
got = {}
for label, running, attempts in (("running lock", {(repo, old): record}, []), ("settled attempt", {}, [record])):
    got[label] = rw.owner_session(row, [owner, other], rw.Book([], running, attempts), attempts)
got["no record, same work moved on"] = rw.owner_session(row, [other, owner], rw.Book([], {}, []), [])
got["no record, only another work at the tip"] = rw.owner_session(row, [other], rw.Book([], {}, []), [])
got["unique-tip control"] = rw.owner_session(row, [owner], rw.Book([], {}, [record]), [record])
print(got)
want = {"running lock": "lead-A", "settled attempt": "lead-A", "no record, same work moved on": "lead-A",
        "no record, only another work at the tip": "", "unique-tip control": "lead-A"}
sys.exit(0 if got == want else 1)
PY
check "W17 the recorded owner comes first, and a registry fallback needs the same work, never another work at the tip" \
    $? "see above"

# --- W18 ---------------------------------------------------------------------
# Second review of 783a8dba1, finding 1 (fixtures/reviewer_spawn_at_quit.py): run_bounded forked
# the reviewer, which leads its own session, before saving its group in _REVIEWER; a SIGTERM in
# between made _on_stop exit with no group to end, and the watcher, whose one read of the process
# table came before the fork, returned no review left running over a reviewer that ran on. The
# real second_review.run_bounded and _on_stop under the real Watcher.stop_all; the process table is
# read for real, before the reviewer exists, and the SIGTERM lands while Popen has not returned.
# Two windows: "brief" (0.3 s, as a real Popen: second-review registers its reviewer, then ends it
# itself) and "wedged" (10 s, longer than the watcher's 2 s SIGTERM grace, the reviewer's fixture
# as written: only the watcher's second read of the process table, before SIGKILL, can reach it).
cat >"$SB/w18.py" <<'PY'
import os, select, signal, subprocess, sys, time
lib, window = sys.argv[1], sys.argv[2]
role = sys.argv[3] if len(sys.argv) > 3 else ""
sys.path.insert(0, lib)
WINDOW = {"brief": 0.3, "wedged": 10.0}[window]    # the fork and exec are done; Popen returns after this

def line(stream):
    if not select.select([stream], [], [], 5)[0]:
        raise RuntimeError("fixture synchronization timed out")
    return stream.readline().strip()

if role == "launcher":
    import second_review as sr
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, sr._on_stop)
    original = subprocess.Popen
    ready_read, ready_write = os.pipe()
    heartbeat_write = int(sys.argv[4])
    reviewer_code = ("import os,signal,sys,time\n"
                     "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                     "os.write(int(sys.argv[1]),b'R')\n"
                     "while True:\n"
                     " os.write(int(sys.argv[2]),b'H'); time.sleep(0.05)\n")

    def spawning(*args, **kwargs):
        print("before reviewer fork", flush=True)
        assert sys.stdin.readline().strip() == "spawn"
        kwargs["pass_fds"] = (ready_write, heartbeat_write)
        child = original(*args, **kwargs)
        assert os.read(ready_read, 1) == b"R"
        print(child.pid, flush=True)
        time.sleep(WINDOW)                          # the SIGTERM lands here, before run_bounded saves the group
        return child
    sr.subprocess.Popen = spawning
    sr.run_bounded([sys.executable, "-B", "-c", reviewer_code, str(ready_write), str(heartbeat_write)],
                   os.getcwd(), "", os.devnull, os.devnull, 60)
    sys.exit(0)

import review_watch as rw
heartbeat_read, heartbeat_write = os.pipe()
launcher = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), lib, window, "launcher",
                             str(heartbeat_write)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                            start_new_session=True, pass_fds=(heartbeat_write,))
os.close(heartbeat_write)
reviewer, ok = None, False
try:
    assert line(launcher.stdout) == "before reviewer fork"
    watcher = rw.Watcher("/fixture/engine", "", world=object())
    watcher.children[launcher.pid] = launcher
    real_below = rw.Watcher.groups_below

    def read_then_spawn(pids):
        global reviewer
        snapshot = real_below(pids)                 # the first read of the process table, before the fork
        if reviewer is not None:
            return snapshot                         # a later read: the reviewer exists by now
        launcher.stdin.write("spawn\n")
        launcher.stdin.flush()
        reviewer = int(line(launcher.stdout))
        return snapshot
    watcher.groups_below = read_then_spawn
    remaining = watcher.stop_all([{"pid": launcher.pid}], rw.QUIT_TERM_SECONDS, rw.QUIT_KILL_SECONDS)
    launcher.wait(timeout=5)
    os.set_blocking(heartbeat_read, False)
    try:
        os.read(heartbeat_read, 4096)               # beats written before the launcher exited
    except BlockingIOError:
        pass
    time.sleep(0.2)
    try:
        advanced = bool(os.read(heartbeat_read, 4096))   # b"" (end of file): every writer is gone
    except BlockingIOError:
        advanced = False
    gone = rw.group_gone(reviewer)
    print("SIGTERM while run_bounded's Popen has not returned (%s, %.1f s): launcher exit=%s, stop_all remaining=%s, "
          "reviewer heartbeat advanced=%s, reviewer group gone=%s" % (window, WINDOW, launcher.returncode, remaining,
                                                                      advanced, gone))
    # brief: second-review ends its own reviewer and exits 143; wedged: the watcher's SIGKILL (-9) ends both.
    ok = launcher.returncode == {"brief": 143, "wedged": -9}[window] and remaining == [] and not advanced and gone
finally:
    for pid in (reviewer, launcher.pid):
        if pid:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    launcher.wait(timeout=5)
    os.close(heartbeat_read)
sys.exit(0 if ok else 1)
PY
for window in brief wedged; do
    W18OUT="$(python3 "$SB/w18.py" "$LIB" "$window" 2>&1)"; W18RC=$?
    printf '    %s\n' "$W18OUT"
    check "W18 a SIGTERM while second-review starts its reviewer ($window): no reviewer is left running" \
        $W18RC "$W18OUT"
done

# --- W19 ---------------------------------------------------------------------
# Second review of 783a8dba1, finding 2 (fixtures/repeated_verdict_owner_collision.py): the first
# notice went through owner_session, but the 30-minute reminder looked the verdict up by repository
# and tip and sent it through whichever ended item held that tip, on a clock shared by every work
# there: another work at the tip got the owner's reminder and suppressed the owner's own. The full
# tell(), with its state in memory.
python3 - "$LIB" "$SB/w19" <<'PY'
import json, os, sys
from unittest.mock import patch
lib, root = sys.argv[1:3]
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
import review_watch as rw
repo = os.path.realpath(os.path.join(root, "fictional-repository"))
tip = "a" * 40

def row(work, author):
    return {"repo": repo, "tip": tip, "work": work, "author": author, "verdict": "changes-requested",
            "trigger": "handover", "record": "", "findings": 1, "at": "2026-10-09T00:00:00Z"}

def item(work, name, session):
    it = rw.Item(work, name, repo, tip, "b" * 40, "ended", ref=name)
    it.session = session
    return it
A, B = "teammate:work-A", "teammate:work-B"
rw.HOST_JSON["on"] = True

def run(rows, items, attempts, fresh=True):
    """[[sessions told at the first look], [sessions told 30 minutes later]]."""
    state = {"rows": 0 if fresh else len(rows), "told": {}}
    book = rw.Book(rows, {}, attempts)
    out = []
    with patch.object(rw.stall_watch, "_read_json", return_value={}), patch.object(rw.stall_watch, "_write_json"):
        for t in (100, 100 + rw.REPEAT_MINUTES * 60):
            out.append([json.loads(s)["session"] for s in rw.tell(t, state, rows, book, items, [], attempts)])
    return out
got, want = {}, {}
owner_attempt = [{"repo": repo, "tip": tip, "work": A, "session": "lead-A", "outcome": "verdict"}]
# The reviewer's fixture: another ended work at the same tip comes first in the registry.
got["another work first at the tip"] = run([row(A, "worker-A")],
                                           [item(B, "reviewer-B", "lead-B"), item(A, "worker-A", "lead-A")],
                                           owner_attempt)
want["another work first at the tip"] = [["lead-A"], ["lead-A"]]
# A session whose first look comes after the verdict was told: the reminder loop tells it first.
got["first told by the reminder loop"] = run([row(A, "worker-A")],
                                             [item(B, "reviewer-B", "lead-B"), item(A, "worker-A", "lead-A")],
                                             owner_attempt, fresh=False)
want["first told by the reminder loop"] = [["lead-A"], ["lead-A"]]
# Only another work holds the tip now: nothing goes to its lead.
got["only another work at the tip"] = run([row(A, "worker-A")], [item(B, "reviewer-B", "lead-B")], owner_attempt,
                                          fresh=False)
want["only another work at the tip"] = [[], []]
# Two works at one tip, each with its own changes-requested verdict: each reminder reaches its own
# lead, and neither clock suppresses the other.
both = [row(A, "worker-A"), row(B, "reviewer-B")]
got["two works, two verdicts"] = run(both, [item(B, "reviewer-B", "lead-B"), item(A, "worker-A", "lead-A")],
                                     owner_attempt + [dict(owner_attempt[0], work=B, session="lead-B")])
want["two works, two verdicts"] = [["lead-A", "lead-B"], ["lead-B", "lead-A"]]
for k in want:
    print("%s: %s" % (k, got[k]))
sys.exit(0 if got == want else 1)
PY
check "W19 the repeated handover notice goes to the recorded owner of the same work, on that work's own clock" \
    $? "see above"

# --- W20 ---------------------------------------------------------------------
# The same class in the plain monitor (review-watch.sh --monitor inside each lead session): there a
# notice is delivered by printing it in the session whose monitor runs, so another lead's monitor
# printed every lead's verdicts. Now a monitor prints a block it owns, one with no owner, and one
# whose owner has no monitor that has looked (that session ended), never one another live lead's
# monitor will print.
python3 - "$LIB" "$SB/w20" <<'PY'
import fcntl, json, os, sys
lib, root = sys.argv[1:3]
os.environ["REVIEW_WATCH_STATE_DIR"] = os.path.join(root, "rw")
os.environ["SECOND_REVIEW_STATE_DIR"] = os.path.join(root, "sr")
sys.path.insert(0, lib)
import review_watch as rw
repo = os.path.realpath(os.path.join(root, "fictional-repository"))

def row(tip, work):
    return {"repo": repo, "tip": tip, "work": work, "author": work, "verdict": "passed", "trigger": "handover",
            "record": "", "findings": 0, "at": "2026-10-09T00:00:00Z"}
rows = [row("a" * 40, "teammate:of-A"), row("b" * 40, "teammate:of-B"), row("c" * 40, "teammate:of-gone"),
        row("d" * 40, "branch:by-hand")]
attempts = [{"repo": repo, "tip": r["tip"], "work": r["work"], "session": s, "outcome": "verdict"}
            for r, s in zip(rows, ("lead-A", "lead-B", "lead-gone", ""))]

def monitor(sid, looked):
    d = rw.session_dir(sid)
    fd = os.open(os.path.join(d, "monitor.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if looked:
        json.dump({"last_look": 1}, open(os.path.join(d, "told.json"), "w"))
    return fd
held = [monitor("lead-A", True), monitor("lead-B", True), monitor("lead-new", False)]
attempts.append({"repo": repo, "tip": "e" * 40, "work": "teammate:of-new", "session": "lead-new", "outcome": "verdict"})
rows.append(row("e" * 40, "teammate:of-new"))

def told(me):
    vars(rw).setdefault("MONITOR", {})["session"] = me    # what run_loop sets; a watcher without it prints all
    lines = rw.tell(100, {"rows": 0, "told": {}}, rows, rw.Book(rows, {}, attempts), [], [], attempts)
    return sorted(t for t in ("a", "b", "c", "d", "e") if any("@" + t * 12 in ln for ln in lines))
got = {"lead-A's monitor": told("lead-A"), "lead-B's monitor": told("lead-B"), "no session known": told("")}
want = {"lead-A's monitor": ["a", "c", "d", "e"], "lead-B's monitor": ["b", "c", "d", "e"],
        "no session known": ["a", "b", "c", "d", "e"]}
print(got)
sys.exit(0 if got == want else 1)
PY
check "W20 the plain monitor prints a verdict only in its owner's session, unless no live monitor of the owner will" \
    $? "see above"

# --- W04 ---------------------------------------------------------------------
resetstate
reg echo-sonnet-w1 300 -
tickrw
[ "$RC" -eq 0 ] && [ "$(ncalls)" = "0" ]; check "W04 a commit five minutes in, on a base a day old: no long-job review" $? "calls=$(ncalls) out=$OUT"
reg echo-sonnet-w1 3660 -
FAKE_SR_MODE=passed tickrw
waitcalls 1
A="$(lastargv)"
[ "$(ncalls)" = "1" ] && has "$A" '"--trigger", "long-job"'; check "W04 61 minutes after the registry's start: a long-job review" $? "calls=$(ncalls) argv=$A"

# --- W05 ---------------------------------------------------------------------
resetstate
python3 - "$SB" <<'PY'
import json, os, sys, time
sb = sys.argv[1]
d = os.path.join(sb, "projects", "-fixture", "sess-w", "subagents")
os.makedirs(d, exist_ok=True)
p = os.path.join(d, "agent-abcdef0123456789.jsonl")
open(p, "w").write("{}\n")
old = time.time() - 25 * 60
os.utime(p, (old, old))
PY
reg echo-sonnet-w1 1800 -
python3 - "$SB" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "workspaces", "agents", "sess-w--echo-sonnet-w1.json")
r = json.load(open(p)); r["agent_id"] = "abcdef0123456789"; r["session_id"] = ""
json.dump(r, open(p, "w"))
PY
OLD="@$(python3 -c 'import time; print(int(time.time() - 25 * 60))')"
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" G commit -q --amend --no-edit
TIP="$(G rev-parse HEAD)"
FAKE_SR_MODE=passed tickrw
waitcalls 1
A="$(lastargv)"
[ "$(ncalls)" = "1" ] && has "$A" '"--trigger", "quiet"' && has "$A" "\"--tip\", \"$TIP\""
check "W05 gone quiet 25 minutes with an unreviewed commit: a review starts" $? "calls=$(ncalls) argv=$A out=$OUT"

# --- W06 ---------------------------------------------------------------------
resetstate
reg echo-sonnet-w1 3660 -
FAKE_SR_MODE=sleep tickrw
waitcalls 1
MIDPID="$(cat "$SB/calls/00/pid" 2>/dev/null)"
reg echo-sonnet-w1 3660 5
FAKE_SR_MODE=passed tickrw
waitcalls 2
A="$(lastargv)"
GONE=1
for _ in $(seq 1 50); do if [ -n "$MIDPID" ] && ! kill -0 "$MIDPID" 2>/dev/null; then GONE=0; break; fi; sleep 0.1; done
[ "$(ncalls)" = "2" ] && [ "$GONE" -eq 0 ] && has "$A" '"--trigger", "handover"' && has "$(cat "$SB/calls/00/argv.json")" '"long-job"' \
  && grep -q '"outcome": "superseded"' "$SB/rw/attempts.jsonl"
check "W06 a handover stops the mid-job review of the same tip by its recorded pid and starts its own" $? \
    "calls=$(ncalls) mid pid=$MIDPID gone=$GONE argv=$A"

# --- W07 ---------------------------------------------------------------------
resetstate
G checkout -qb codex/fix-w7 "$BASE"
printf 'base\ncodex\n' >"$REPO/a.txt"
G commit -qam "codex: a fix"
CTIP="$(G rev-parse HEAD)"
G checkout -q cc/echo-sonnet-w1
printf '## 2026-10-09T01:00:00Z Rich: please build codex/fix-w7\n\nCODEX-ASK-LINE: make the fix for codex/fix-w7.\n\n## 2026-10-09T01:10:00Z Rich: something else\n\nOTHER-ASK\n' >"$SB/codex/to-codex.md"
printf '## 2026-10-09T00:00:00Z STATUS: old\n\nold entry\n' >"$SB/codex/to-rich.md"
tickrw                                    # the first look starts at the end of the file
printf '\n## 2026-10-09T02:00:00Z READY TO LAND: codex/fix-w7\n\nCommit: `%s`\nRepository: richos only.\nCLAIM-LINE\n' "$CTIP" >>"$SB/codex/to-rich.md"
FAKE_SR_MODE=passed tickrw                # it grew: told after it settles one look
FAKE_SR_MODE=passed tickrw
waitcalls 1
A="$(lastargv)"
W="$(cat "$(ls -d "$SB"/calls/* | tail -1)/words.txt" 2>/dev/null)"
[ "$(ncalls)" = "1" ] && has "$A" '"--branch", "codex/fix-w7"' && has "$A" "\"--tip\", \"$CTIP\"" && has "$A" '"--author", "codex"' \
  && has "$A" "\"--base\", \"$BASE\"" && has "$W" "CODEX-ASK-LINE" && ! has "$W" "OTHER-ASK"
check "W07 Codex's READY entry starts a review of its branch, with the entry that asked for it as the words" $? "calls=$(ncalls) argv=$A words=$W out=$OUT"

# --- W08 ---------------------------------------------------------------------
resetstate
reg echo-sonnet-w1 600 30
tickrw                                    # the first look: the ledger's end is where telling starts
python3 - "$SB" "$REPO" "$TIP" <<'PY'
import json, os, sys
sb, repo, tip = sys.argv[1:4]
st = os.path.join(sb, "sr")
rows = []
for i, (status, f) in enumerate([(None, True), ("still-open", True), ("still-open", True)]):
    rid = "rv-nc-%d" % i
    rec = os.path.join(st, "reviews", rid)
    os.makedirs(rec, exist_ok=True)
    ans = {"findings": [], "earlier_findings": []}
    ein = []
    if i == 0:
        ans["findings"] = [{"priority": 2, "title": "Audio left on disk", "files": [], "evidence": "", "fixture": ""}]
    else:
        ans["earlier_findings"] = [{"id": "rv-nc-0#1", "status": "still-open", "note": ""}]
        ein = [{"id": "rv-nc-0#1", "title": "Audio left on disk"}]
    json.dump({"answer": ans, "earlier_findings_in": ein}, open(os.path.join(rec, "verdict.json"), "w"))
    rows.append({"id": rid, "at": "2026-10-09T0%d:00:00Z" % i, "repo": os.path.realpath(repo), "tip": "f" * 39 + str(i),
                 "work": "teammate:sess-w--echo-sonnet-w1", "trigger": "long-job", "verdict": "changes-requested",
                 "findings": 1, "p1": 0, "reviewer": "codex", "reviewer_model": "m", "record": rec})
with open(os.path.join(st, "reviews.jsonl"), "a") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
tickrw
N1="$(printf '%s' "$OUT" | grep -c 'NOT CONVERGING')"
tickrw
N2="$(printf '%s' "$OUT" | grep -c 'NOT CONVERGING')"
[ "$N1" = "1" ] && [ "$N2" = "0" ]
check "W08 a finding still open through two rechecks in a row is told once as not converging" $? "first=$N1 again=$N2"

# --- W09 ---------------------------------------------------------------------
resetstate
cfg 'SECOND_REVIEW_REPOS="some-other-repo"'
reg echo-sonnet-w1 600 30
tickrw
[ "$RC" -eq 0 ] && [ "$(ncalls)" = "0" ]; check "W09 a repository not in SECOND_REVIEW_REPOS (and the femcboost workspace) is never reviewed" $? "calls=$(ncalls) out=$OUT"
resetstate
cfg '# no SECOND_REVIEW_REPOS here'
reg echo-sonnet-w1 600 30
tickrw
O1="$OUT"
tickrw
[ "$(ncalls)" = "0" ] && has "$O1" "no repository is listed in SECOND_REVIEW_REPOS" && [ -z "$OUT" ]
check "W09 with SECOND_REVIEW_REPOS absent it says so once and starts nothing" $? "calls=$(ncalls) first=$O1 second=$OUT"
cfg 'SECOND_REVIEW_REPOS="richos"'

# --- W10 ---------------------------------------------------------------------
python3 - "$ENGINE/monitors/monitors.json" <<'PY'
import json, sys
mons = json.load(open(sys.argv[1]))
m = [x for x in mons if x.get("name") == "review-watch"]
sys.exit(0 if len(m) == 1 and m[0].get("when") == "always"
         and m[0].get("command", "").endswith("/scripts/review-watch.sh --monitor") else 1)
PY
check "W10 monitors.json starts review-watch.sh --monitor always" $? "monitors.json wiring"

echo
echo "review-watch.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
