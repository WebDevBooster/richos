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
#        not converging; never one filed as a follow-up (blocks false); one
#        work in two repositories is compared repository by repository
#   W09  a repository not in SECOND_REVIEW_REPOS is never reviewed; with the
#        key absent it says so once and starts nothing; a value bash sets that
#        is not names (review_repos in scripts/lib/operator_fences.py, the one
#        reader install and the land use too, sources the config in bash) is
#        said once and starts nothing
#   W10  monitors.json starts review-watch.sh --monitor always
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
    repos_error = ""
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

# Review rv-20261009T104053Z-8662354d-47b2: two passed rechecks of a finding
# already filed as a follow-up (blocks false) were told as not converging. And
# one work in two repositories: each repository's rechecks are compared only
# with that repository's, so a finding still open in richos through two richos
# rechecks is told though a richos-hq review came between them.
resetstate
reg echo-sonnet-w1 600 30
tickrw
python3 - "$SB" "$REPO" "$SB/w08-rows.jsonl" <<'PY'
import json, os, sys
sb, repo, out = sys.argv[1:4]
st = os.path.join(sb, "sr")
richos, hq = os.path.realpath(repo), os.path.realpath(repo) + "-hq"
rows = []
def add(rid, work, where, verdict, findings=(), earlier=(), blocks=None):
    rec = os.path.join(st, "reviews", rid)
    os.makedirs(rec, exist_ok=True)
    ans = {"findings": [dict(f, blocks=True) for f in findings], "earlier_findings": []}
    ein = []
    for fid, title in earlier:
        ans["earlier_findings"].append({"id": fid, "status": "still-open", "blocks": blocks, "note": ""})
        ein.append({"id": fid, "title": title})
    json.dump({"answer": ans, "earlier_findings_in": ein}, open(os.path.join(rec, "verdict.json"), "w"))
    rows.append({"id": rid, "at": "2026-10-09T0%d:00:00Z" % len(rows), "repo": where, "tip": "e" * 38 + "%02d" % len(rows),
                 "work": work, "trigger": "long-job", "verdict": verdict, "findings": len(findings), "p1": 0,
                 "reviewer": "codex", "reviewer_model": "m", "record": rec})
fu = [{"priority": 3, "title": "Filed follow-up", "files": [], "evidence": "", "fixture": ""}]
add("rv-fu-0", "teammate:fu", richos, "passed", fu)
add("rv-fu-1", "teammate:fu", richos, "passed", earlier=[("rv-fu-0#1", "Filed follow-up")], blocks=False)
xr = [{"priority": 2, "title": "Blocker in richos", "files": [], "evidence": "", "fixture": ""}]
add("rv-xr-0", "teammate:xr", richos, "changes-requested", xr)
add("rv-xr-1", "teammate:xr", hq, "passed")
add("rv-xr-2", "teammate:xr", richos, "changes-requested", earlier=[("rv-xr-0#1", "Blocker in richos")], blocks=True)
add("rv-xr-3", "teammate:xr", hq, "passed")
# The two rows that decide come last, in a look of their own: one look's block
# is capped at BLOCK_CHARS.
add("rv-fu-2", "teammate:fu", richos, "passed", earlier=[("rv-fu-0#1", "Filed follow-up")], blocks=False)
add("rv-xr-4", "teammate:xr", richos, "changes-requested", earlier=[("rv-xr-0#1", "Blocker in richos")], blocks=True)
with open(out, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
head -n 6 "$SB/w08-rows.jsonl" >>"$SB/sr/reviews.jsonl"
tickrw
tail -n 2 "$SB/w08-rows.jsonl" >>"$SB/sr/reviews.jsonl"
tickrw
NC="$(printf '%s' "$OUT" | grep 'NOT CONVERGING')"
has "$OUT" "reviews/rv-xr-4/verdict.json" && ! has "$OUT" "... more in the next look" && ! has "$NC" "rv-fu-0#1"
check "W08 a finding filed as a follow-up (blocks false) is never told as not converging" $? "$NC"
[ "$(printf '%s\n' "$NC" | grep -c 'rv-xr-0#1')" = "1" ]
check "W08 one work in two repositories: a finding still open through two rechecks of its own repository is told" $? "$NC"

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
resetstate
cfg 'SECOND_REVIEW_REPOS="/abs/richos"'
reg echo-sonnet-w1 600 30
tickrw
O1="$OUT"
tickrw
[ "$(ncalls)" = "0" ] && has "$O1" "orchestration.config cannot be read: bash reads it as '/abs/richos'" && [ -z "$OUT" ]
check "W09 a SECOND_REVIEW_REPOS value that is not names is said once and starts nothing" $? "calls=$(ncalls) first=$O1 second=$OUT"
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
