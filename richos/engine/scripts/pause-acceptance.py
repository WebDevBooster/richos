#!/usr/bin/env python3
"""The CEO's pause acceptance test: ONE test agent, paused ONCE, held 5 minutes, resumed.

His words (2026-09-27, §94): "before ever trying to do any pause when it comes to
regular teammates next time, you must first prove (via a test) that you can actually
do what I call a PAUSE and then resume after 5 minutes". Amended 2026-09-28: "forget
the fucking 3-agent test. if you can't get that done with one agent once, there's no
point for a 3-agent test." What he calls a PAUSE (§87): the same agent is held, its
running work frozen in place; nothing is ended, lost or restarted; on resume it
continues from the same point. What the agent is told is WAIT ("aha, so the keyword
is WAIT, not pause."). Whether its run stayed open is measured here, never asked of it.

The lead runs it in steps, because only the lead can send a message. Each step is
one foreground command under the Bash tool's 10-minute limit:

  start   --agent NAME --work-dir DIR   shows the agent doing measurable real work, then
                                        prints the generated pause to send, unchanged
  (the lead sends it with SendMessage)
  paused                                within seconds: its processes frozen (state T, CPU
                                        near 0), its counter stopped, the pause recorded
  hold                                  blocks until 5 minutes after the pause, sampling
                                        that nothing moved and its run did not end; then
                                        prints the generated RESUME to send
  (the lead sends it with SendMessage)
  resumed                               the SAME agent (id, registry record, transcript)
                                        continues from the frozen value: same process, no
                                        restart, nothing lost, no command of it ran while
                                        held, no SubagentStop during the hold

`next` runs whichever step is due; `status` says where the run is. The first
failure ends the run and is written down; nothing is retried. The receipt (JSON and
a readable page) goes to --receipt-dir, by default richos-hq docs/verification.

The test agent's task is pause-acceptance-agent-task.txt beside this file; its work
is pause-acceptance-worker.py. The harness signals nothing: it only reads the
registry, the hold record, the process table, the agent's files and its transcript.
"""
import argparse
import calendar
import glob
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))
import agent_hold  # noqa: E402
import pause_protocol  # noqa: E402

HOLD_SECONDS = 300          # "then resume after 5 minutes"
FROZEN_WITHIN = 10.0        # seconds from the recorded pause to every process confirmed stopped
SAMPLE_SECONDS = 3.0
HOLD_SAMPLE_EVERY = 15.0
CPU_NEAR_ZERO = 0.05        # CPU seconds the frozen processes may show over a sample (ps rounding)
RESUME_WAIT = 180.0         # for the agent's first action after RESUME
STATE_NAME = ".pause-acceptance.json"


def load_registry():
    spec = importlib.util.spec_from_file_location("pause_acceptance_ws", os.path.join(ENGINE, "mega-lander", "workspaces.py"))
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)
    return ws


def utc(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else "-"


def epoch(iso_text):
    try:
        return float(calendar.timegm(time.strptime(iso_text[:19], "%Y-%m-%dT%H:%M:%S")))
    except (TypeError, ValueError):
        return None


class Failed(Exception):
    pass


# ---------------------------------------------------------------------------
# what is read
# ---------------------------------------------------------------------------

def progress(work_dir):
    """[(t, pid, n, hash)] from the worker's log; a malformed line is itself a failure."""
    rows = []
    try:
        with open(os.path.join(work_dir, "progress.log")) as f:
            for line in f:
                t, pid, n, h = line.split()
                rows.append((float(t), int(pid), int(n), h))
    except FileNotFoundError:
        return []
    except ValueError:
        raise Failed("progress.log has a line the worker never writes")
    return rows


def chain_problem(rows):
    """None when one process counted 1, 2, 3 ... with an unbroken hash chain."""
    h = hashlib.sha256(b"richos-pause-acceptance").hexdigest()
    pids = sorted({r[1] for r in rows})
    if len(pids) > 1:
        return "the counter was written by %d processes (%s): it was restarted" % (len(pids), pids)
    for i, (_t, _pid, n, got) in enumerate(rows, 1):
        if n != i:
            return "the counter went to %d where %d was next: %s" % (n, i, "restarted" if n < i else "a step was lost")
        h = hashlib.sha256((h + str(n)).encode()).hexdigest()
        if got != h:
            return "the hash chain breaks at %d: the work did not continue from the same point" % n
    return None


def commands(work_dir):
    try:
        with open(os.path.join(work_dir, "commands.log")) as f:
            return [float(line.split()[0]) for line in f if line.strip()]
    except (OSError, ValueError, IndexError):
        return []


def cpu_of(pids):
    """{pid: (stat, cpu seconds, birth)} for the pids still alive."""
    table = agent_hold.snapshot()
    return {p: (table[p]["stat"], table[p]["cpu"], table[p]["birth"]) for p in pids if p in table}


def transcript_path(ws, rec):
    base = ws._platform_projects_dir()
    hits = sorted(glob.glob(os.path.join(base, "*", rec["session_id"], "subagents", "agent-%s.jsonl" % rec["agent_id"])))
    return hits[0] if hits else ""


def transcript_last(path):
    """(lines, time of the newest line) of the agent's own transcript."""
    try:
        with open(path, "rb") as f:
            lines = f.read().splitlines()
    except OSError:
        return 0, None
    newest = None
    for raw in reversed(lines[-50:]):
        try:
            newest = epoch(json.loads(raw).get("timestamp") or "")
        except ValueError:
            continue
        if newest:
            break
    return len(lines), newest or os.path.getmtime(path)


# ---------------------------------------------------------------------------
# the run's record
# ---------------------------------------------------------------------------

class Run:
    def __init__(self, work_dir):
        self.work_dir = os.path.abspath(work_dir)
        self.path = os.path.join(self.work_dir, STATE_NAME)
        self.s = {}
        if os.path.exists(self.path):
            with open(self.path) as f:
                self.s = json.load(f)

    def save(self):
        tmp = self.path + ".new"
        with open(tmp, "w") as f:
            json.dump(self.s, f, indent=2, sort_keys=True)
        os.replace(tmp, self.path)

    def note(self, step, **facts):
        facts["at"] = utc(time.time())
        self.s.setdefault("steps", {})[step] = facts
        self.save()

    def fail(self, step, why):
        self.s["phase"], self.s["verdict"] = "failed", "FAIL"
        self.s["failure"] = {"step": step, "why": why, "at": utc(time.time())}
        self.save()
        write_receipt(self)
        print("FAIL at %s: %s" % (step, why))
        print("Receipt: %s" % self.s.get("receipt"))
        return 1


def write_receipt(run):
    s = run.s
    d = s["receipt_dir"]
    os.makedirs(d, exist_ok=True)
    stem = os.path.join(d, "%s-pause-acceptance-%s" % (s["started_at"][:10], s["agent"]))
    with open(stem + ".json", "w") as f:
        json.dump(s, f, indent=2, sort_keys=True)
    steps = s.get("steps", {})
    lines = ["# Pause acceptance: %s, %s" % (s["agent"], s.get("verdict", "unfinished")), "",
             "His words (§94, amended 2026-09-28): one test agent, paused once, resumed after 5 minutes; the "
             "same agent continues from the same point, nothing ended, lost or restarted.", "",
             "- agent: `%s`, id `%s`, session `%s`" % (s["agent"], s["agent_id"], s["session_id"]),
             "- transcript: `%s`" % (s.get("transcript") or "not found"),
             "- work directory: `%s`" % s["work_dir"],
             "- harness: `%s` at engine `%s`" % (os.path.basename(__file__), s.get("engine_head", "?")), "",
             "| step | when (UTC) | measured |", "|---|---|---|"]
    for name in ("start", "paused", "hold", "resumed"):
        if name in steps:
            facts = {k: v for k, v in steps[name].items() if k != "at"}
            lines.append("| %s | %s | %s |" % (name, steps[name]["at"],
                                               "; ".join("%s: %s" % (k, json.dumps(v)) for k, v in sorted(facts.items()))))
    if s.get("failure"):
        lines += ["", "**FAILED at %s:** %s" % (s["failure"]["step"], s["failure"]["why"])]
    elif s.get("verdict") == "PASS":
        lines += ["", "**PASS:** every check above held."]
    with open(stem + ".md", "w") as f:
        f.write("\n".join(lines) + "\n")
    s["receipt"] = stem + ".md"
    run.save()


# ---------------------------------------------------------------------------
# the steps
# ---------------------------------------------------------------------------

def agent_record(ws, run):
    rec = ws.load_agent(ws.named_key(run.s["session_id"], run.s["agent"]))
    if not rec:
        raise Failed("the registry has no agent %r in session %s" % (run.s["agent"], run.s["session_id"]))
    if rec.get("agent_id") != run.s["agent_id"]:
        raise Failed("the name now belongs to agent id %s, not %s: a different agent" % (rec.get("agent_id"), run.s["agent_id"]))
    return rec


def sample(work_dir, pids, seconds):
    before_rows, before_cpu = progress(work_dir), cpu_of(pids)
    time.sleep(seconds)
    after_rows, after_cpu = progress(work_dir), cpu_of(pids)
    cpu = round(sum(max(0.0, after_cpu[p][1] - before_cpu[p][1]) for p in before_cpu if p in after_cpu), 2)
    return {"counter_before": before_rows[-1][2] if before_rows else 0,
            "counter_after": after_rows[-1][2] if after_rows else 0,
            "cpu_seconds": cpu, "sample_seconds": seconds,
            "states": {str(p): after_cpu[p][0] for p in sorted(after_cpu)}}


def step_start(ws, run, a):
    sid = a.session or ws.current_session()
    if not sid:
        raise Failed("no session: run it from the lead's session, or pass --session")
    rec = ws.load_agent(ws.named_key(sid, a.agent))
    if not rec or not rec.get("agent_id"):
        raise Failed("the registry has no agent %r with an id in session %s" % (a.agent, sid))
    state, why = ws.recipient_state(sid, a.agent)
    if state != "active":
        raise Failed("the agent is %s (%s); the test starts with a working agent" % (state, why))
    head = subprocess.run(["git", "-C", ENGINE, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    run.s = {"agent": a.agent, "agent_id": rec["agent_id"], "session_id": sid, "key": rec["key"],
             "work_dir": run.work_dir, "hold_seconds": a.hold_seconds, "receipt_dir": os.path.abspath(a.receipt_dir),
             "started_at": utc(time.time()), "engine_head": head, "phase": "start"}
    run.s["transcript"] = transcript_path(ws, rec)
    if not run.s["transcript"]:
        raise Failed("no transcript agent-%s.jsonl for session %s" % (rec["agent_id"], sid))
    rows = progress(run.work_dir)
    if not rows:
        raise Failed("no progress.log in %s: the agent's counter is not running" % run.work_dir)
    problem = chain_problem(rows)
    if problem:
        raise Failed(problem)
    worker = rows[-1][1]
    table = agent_hold.snapshot()
    owned, _excluded, _p, _n, _parents = agent_hold.owned_tree(sid, rec["agent_id"], table)
    if worker not in owned:
        raise Failed("the counter (pid %d) is not among the agent's recorded processes %s: the hold could not "
                     "reach it (was it started before the hooks were installed?)" % (worker, sorted(owned)))
    s = sample(run.work_dir, sorted(owned), 5.0)
    if s["counter_after"] <= s["counter_before"] or s["cpu_seconds"] <= 0:
        raise Failed("the agent is not doing measurable work: counter %d -> %d, CPU %.2f s over 5 s"
                     % (s["counter_before"], s["counter_after"], s["cpu_seconds"]))
    run.s["worker"] = {"pid": worker, "birth": table[worker]["birth"]}
    run.s["phase"] = "await-pause"
    run.note("start", agent_id=rec["agent_id"], worker_pid=worker, owned=len(owned), working=s,
             transcript_lines=transcript_last(run.s["transcript"])[0])
    print("START %s (id %s): counter %d -> %d and %.2f CPU s over 5 s, across %d owned processes."
          % (a.agent, rec["agent_id"], s["counter_before"], s["counter_after"], s["cpu_seconds"], len(owned)))
    print("Now send this with SendMessage, unchanged, then run: %s next --work-dir %s" % (__file__, run.work_dir))
    print(json.dumps(pause_protocol.message_input(a.agent, "manual")))
    return 0


def step_paused(ws, run):
    rec = agent_record(ws, run)
    pause = rec.get("pause") or {}
    if not pause:
        raise Failed("the registry records no pause for %s: was the generated pause sent?" % run.s["agent"])
    if not pause.get("control"):
        raise Failed("the registry's pause was not the unchanged generated message")
    hold = agent_hold._read_json(agent_hold._held_path(run.s["session_id"], run.s["agent_id"]))
    if not hold:
        raise Failed("no hold record: the pause froze nothing")
    held = {int(p): b for p, b in (hold.get("held") or {}).items()}
    w = run.s["worker"]
    if held.get(w["pid"]) != w["birth"]:
        raise Failed("the counter (pid %d) is not among the frozen processes %s" % (w["pid"], sorted(held)))
    frozen_at = float(hold.get("at") or 0) + float(hold.get("stopped_seconds") or 0)
    latency = round(frozen_at - float(pause["at"]), 2)
    if latency > FROZEN_WITHIN:
        raise Failed("frozen %.1f s after the pause, not within seconds" % latency)
    s = sample(run.work_dir, sorted(held), SAMPLE_SECONDS)
    running = [p for p, st in s["states"].items() if not st.startswith("T")]
    if running:
        raise Failed("processes still running after the pause: %s" % running)
    if s["cpu_seconds"] > CPU_NEAR_ZERO:
        raise Failed("the frozen processes used %.2f CPU s over %.0f s" % (s["cpu_seconds"], SAMPLE_SECONDS))
    if s["counter_after"] != s["counter_before"]:
        raise Failed("the counter moved while frozen: %d -> %d" % (s["counter_before"], s["counter_after"]))
    rows = progress(run.work_dir)
    run.s["pause_at"] = float(pause["at"])
    run.s["frozen_counter"] = rows[-1][2]
    run.s["held"] = {str(p): b for p, b in held.items()}
    run.s["commands_before_pause"] = len([t for t in commands(run.work_dir) if t < run.s["pause_at"]])
    run.s["phase"] = "holding"
    run.note("paused", pause_at=utc(pause["at"]), frozen_within_seconds=latency, held=len(held),
             hold_reported_cpu=hold.get("cpu_during_sample"), frozen=s, frozen_counter=rows[-1][2],
             counter_last_written=round(rows[-1][0] - run.s["pause_at"], 2), hold_notes=hold.get("notes") or [],
             locks=hold.get("locks") or [])
    print("PAUSED %s: %d process(es) frozen %.2f s after the pause; CPU %.2f s over %.0f s; counter held at %d."
          % (run.s["agent"], len(held), latency, s["cpu_seconds"], SAMPLE_SECONDS, rows[-1][2]))
    print("Next: %s next --work-dir %s   (it holds until %s, 5 minutes after the pause)"
          % (__file__, run.work_dir, utc(run.s["pause_at"] + run.s["hold_seconds"])))
    return 0


def run_ended_since(rec, since):
    end = rec.get("end") or {}
    return end if end and float(end.get("at") or 0) >= since else None


def step_hold(ws, run):
    until = run.s["pause_at"] + run.s["hold_seconds"]
    held = [int(p) for p in run.s["held"]]
    samples = []
    while True:
        rec = agent_record(ws, run)
        ended = run_ended_since(rec, run.s["pause_at"])
        if ended:
            raise Failed("the agent's run ended during the hold (%s at %s): it did not wait inside its run"
                         % (ended.get("signal"), utc(ended.get("at"))))
        if not rec.get("pause"):
            raise Failed("the pause ended before the 5 minutes: %s" % json.dumps(rec.get("history", [])[-1:]))
        left = until - time.time()
        s = sample(run.work_dir, held, max(0.5, min(HOLD_SAMPLE_EVERY, left)) if left > 0 else 0.5)
        s["seconds_since_pause"] = round(time.time() - run.s["pause_at"], 1)
        samples.append(s)
        if [p for p, st in s["states"].items() if not st.startswith("T")]:
            raise Failed("a frozen process ran during the hold: %s" % s["states"])
        if s["counter_after"] != run.s["frozen_counter"] or s["cpu_seconds"] > CPU_NEAR_ZERO:
            raise Failed("work moved during the hold: counter %d (frozen at %d), CPU %.2f s"
                         % (s["counter_after"], run.s["frozen_counter"], s["cpu_seconds"]))
        ran = [t for t in commands(run.work_dir) if t >= run.s["pause_at"]]
        if ran:
            raise Failed("a command of the agent ran during the hold, at %s" % utc(ran[0]))
        if time.time() >= until:
            break
    run.s["phase"] = "await-resume"
    lines, newest = transcript_last(run.s["transcript"])
    run.note("hold", held_seconds=round(time.time() - run.s["pause_at"], 1), samples=len(samples),
             max_cpu_seconds=max(x["cpu_seconds"] for x in samples),
             counters=sorted({x["counter_after"] for x in samples}), transcript_lines=lines,
             transcript_newest=utc(newest))
    print("HELD %s for %.0f s: %d samples, counter stayed at %d, CPU at most %.2f s per sample, no command ran, "
          "its run did not end." % (run.s["agent"], time.time() - run.s["pause_at"], len(samples),
                                     run.s["frozen_counter"], max(x["cpu_seconds"] for x in samples)))
    print("Now send this with SendMessage, unchanged, then run: %s next --work-dir %s" % (__file__, run.work_dir))
    print(json.dumps(pause_protocol.message_input(run.s["agent"], "manual", resume=True)))
    return 0


def resume_record(rec, since):
    for h in reversed(rec.get("history") or []):
        if h.get("fact") == "resumed" and (epoch(h.get("at") or "") or 0) >= since - 1:
            return h
    return None


def step_resumed(ws, run):
    rec = agent_record(ws, run)
    if rec.get("pause"):
        raise Failed("the registry still records the pause: was the generated RESUME sent?")
    h = resume_record(rec, run.s["pause_at"])
    if not h:
        raise Failed("the registry records no resume after the pause")
    resumed_at = epoch(h["at"])
    ended = h.get("end") or {}
    if ended and float(ended.get("at") or 0) >= run.s["pause_at"]:
        raise Failed("the agent's run ended during the hold (%s at %s), so the resume started a new run"
                     % (ended.get("signal"), utc(ended.get("at"))))
    if agent_hold._read_json(agent_hold._held_path(run.s["session_id"], run.s["agent_id"])):
        raise Failed("the hold record is still there after the resume")
    held = [int(p) for p in run.s["held"]]
    deadline = time.time() + RESUME_WAIT
    while True:
        rows = progress(run.work_dir)
        problem = chain_problem(rows)
        if problem:
            raise Failed(problem)
        after = [r for r in rows if r[2] > run.s["frozen_counter"]]
        lines, newest = transcript_last(run.s["transcript"])
        acted = newest is not None and newest >= resumed_at
        if len(after) >= 4 and acted:
            break
        if time.time() >= deadline:
            raise Failed("within %.0f s of the resume: %d new counter steps, agent acted in its transcript: %s"
                         % (RESUME_WAIT, len(after), acted))
        time.sleep(2.0)
    problem = chain_problem(rows)
    if problem:
        raise Failed(problem)
    if rows[0][1] != run.s["worker"]["pid"]:
        raise Failed("the counter's process is %d, not the frozen %d" % (rows[0][1], run.s["worker"]["pid"]))
    early = [r for r in after if r[0] < resumed_at - 1]
    if early:
        raise Failed("counter step %d was written at %s, before the resume" % (early[0][2], utc(early[0][0])))
    s = sample(run.work_dir, held, SAMPLE_SECONDS)
    # Read again AFTER the sample: a counter ended and started afresh just after the
    # resume shows only here (the fake-agent suite's N4 passed before this).
    rows = progress(run.work_dir)
    problem = chain_problem(rows)
    if problem:
        raise Failed(problem)
    if s["counter_after"] <= s["counter_before"]:
        raise Failed("the counter did not move in the %.0f s after the resume (%d)" % (SAMPLE_SECONDS, s["counter_after"]))
    alive = cpu_of(held)
    reborn = [p for p in alive if alive[p][2] != run.s["held"][str(p)]]
    if reborn:
        raise Failed("pid(s) %s now name different processes" % reborn)
    if [p for p, st in s["states"].items() if st.startswith("T")]:
        raise Failed("processes still frozen after the resume: %s" % s["states"])
    during = [t for t in commands(run.work_dir) if run.s["pause_at"] <= t < resumed_at]
    if during:
        raise Failed("a command of the agent started during the hold, at %s" % utc(during[0]))
    if ws.load_agent(ws.named_key(run.s["session_id"], run.s["agent"])).get("agent_id") != run.s["agent_id"]:
        raise Failed("a different agent now holds the name")
    run.s["phase"], run.s["verdict"] = "done", "PASS"
    run.note("resumed", resumed_at=utc(resumed_at), held_seconds=round(resumed_at - run.s["pause_at"], 1),
             first_counter_after=after[0][2], first_counter_after_at=utc(after[0][0]),
             counter_continued_from=run.s["frozen_counter"], same_process=run.s["worker"]["pid"],
             running=s, transcript=run.s["transcript"], transcript_lines=lines, transcript_newest=utc(newest),
             run_ended_during_hold=False,
             commands_after_resume=len([t for t in commands(run.work_dir) if t >= resumed_at]))
    write_receipt(run)
    print("PASS %s: resumed at %s after %.0f s; the same process (pid %d) continued from %d to %d with an unbroken "
          "chain; no command ran while held; its run never ended; its transcript %s shows it acting after RESUME."
          % (run.s["agent"], utc(resumed_at), resumed_at - run.s["pause_at"], run.s["worker"]["pid"],
             run.s["frozen_counter"], rows[-1][2], run.s["transcript"]))
    print("Receipt: %s" % run.s["receipt"])
    return 0


STEPS = {"await-pause": ("paused", step_paused), "holding": ("hold", step_hold),
         "await-resume": ("resumed", step_resumed)}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("start")
    st.add_argument("--agent", required=True, help="the test agent's name")
    st.add_argument("--work-dir", required=True, help="the directory its counter writes")
    st.add_argument("--session", default="", help="the lead's session id (default: this command's session)")
    st.add_argument("--hold-seconds", type=float, default=HOLD_SECONDS)
    st.add_argument("--receipt-dir", default=os.path.join(os.path.expanduser("~"), "ab", "richos-hq", "docs",
                                                          "verification", "pause-acceptance"))
    for name in ("paused", "hold", "resumed", "next", "status"):
        s = sub.add_parser(name)
        s.add_argument("--work-dir", required=True)
    a = p.parse_args(argv)
    run = Run(a.work_dir)
    if a.cmd == "status":
        print("phase: %s%s" % (run.s.get("phase", "not started"),
                               "; verdict %s" % run.s["verdict"] if run.s.get("verdict") else ""))
        return 0
    if a.cmd != "start" and run.s.get("phase") in (None, "failed", "done"):
        print("REFUSED: this run is %s; start a new one with `start`." % run.s.get("phase", "not started"))
        return 2
    ws = load_registry()
    name = a.cmd
    try:
        if a.cmd == "start":
            if run.s.get("phase") not in (None, "failed", "done"):
                print("REFUSED: a run is in progress here (%s); finish it or use a new --work-dir." % run.s["phase"])
                return 2
            return step_start(ws, run, a)
        if a.cmd == "next":
            name, fn = STEPS[run.s["phase"]]
        else:
            fn = {"paused": step_paused, "hold": step_hold, "resumed": step_resumed}[a.cmd]
            if STEPS[run.s["phase"]][0] != a.cmd:
                print("REFUSED: the step due is %s, not %s." % (STEPS[run.s["phase"]][0], a.cmd))
                return 2
        return fn(ws, run)
    except Failed as e:
        if not run.s.get("receipt_dir"):
            print("FAIL at %s: %s" % (name, e))
            return 1
        return run.fail(name, str(e))


if __name__ == "__main__":
    sys.exit(main())
