"""blankstart.py — the cold-start blank check on a phone: tap the app's icon on the home screen the
way a person does, record the screen from before the tap, and judge the recordings with blank.py.

    android_cold_blank(measure, starts, evidence_dir, log)   perf.py android's "cold-blank" phase
    iphone_cold_blank(recording, started_at, launches)       the iPhone half (see below)
    iphone_run(run_dir)                                      the same, from a phone-ios.py run directory
    python3 blankstart.py iphone RUN_DIR [RUN_DIR ...]       the command line: one series over the runs' taps,
                                                             exit 0 PASS, 1 FAIL, 2 cannot answer
    metric(series, starts, method)                           the record's `coldBlank` metric

Android. For each start: force-stop the app (a cold start), press Home twice (the launcher's first
page), find the RichConnect icon in the launcher's own accessibility tree, start `screenrecord
--time-limit` on the phone as a process this module owns (it ends by itself), wait
`STILL_BEFORE_TAP_S` so the recording opens on a still home screen, `input tap` the icon's center,
let the recording end, pull it and delete it from the phone. The icon must be on the launcher's
first page: the check refuses, with that sentence, rather than open the app any other way. The
recordings are kept beside the record (`<out>.evidence/cold-blank/`, on the external SSD with the
rest of a physical run's evidence; never in a repository) or, with no `--out`, deleted after they
are judged.

iPhone. The phone has no shell, so the taps and the recording come from the UI-test runner: the
tap launches of `perf.py ios --device` (cc/isaac-opus-launch1) and `phone-ios.py run
--screen-recording` (cc/isaac-opus-white1 ab96039a8), which keeps XCTest's own recording of the
whole session. `iphone_cold_blank` takes that one recording, the moment it began on the phone's
clock (its attachment's manifest `timestamp`) and, per launch, the tap and the step that sends the
app away on the same clock (the runner's step log: the tap step's `tapAt`), and judges each start in
its own window, which opens on the still Home Screen a second before the tap.

Battery: nothing here runs in the app or on the phone after the check; screenrecord ends by its
own time limit.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import blank
import perfcore
from perfcore import Unmeasurable

LABEL = "RichConnect"           # the launcher label (AndroidManifest android:label)
RECORD_S = 7                    # screenrecord --time-limit: 1 s of home screen, then 6 s of start
STILL_BEFORE_TAP_S = 1.0        # the still home screen the recording opens on (blank.STILL_BEFORE_TAP_MS)
IPHONE_LEAD_S = 1.0             # each iPhone window opens this long before its tap (the runner sleeps 1 s on the
                                # still Home Screen before tapping; the window must open on it)


def _icon(measure):
    nodes = measure.dump_ui()
    import android
    node = android.find_node(nodes, text=LABEL) or android.find_node(nodes, desc=LABEL)
    if node is None or not node.get("bounds"):
        raise Unmeasurable(f"the {LABEL} icon is not on the launcher's first page: put it there (this check opens the "
                           "app only by tapping its icon, the way a person does)")
    return android.center(node)


def android_cold_blank(measure, starts, evidence_dir=None, log=lambda s: None, popen=subprocess.Popen,
                       analyze=blank.analyze_video, record_s=RECORD_S):
    """`starts` cold starts from a tap on the home-screen icon, each recorded and judged."""
    import android
    dev = measure.d
    keep = evidence_dir is not None
    out_dir = os.path.join(evidence_dir, "cold-blank") if keep else tempfile.mkdtemp(prefix="richos-cold-blank-")
    os.makedirs(out_dir, exist_ok=True)
    results = []
    try:
        for n in range(1, starts + 1):
            dev.sh(f"am force-stop {android.PACKAGE}")
            dev.sh("input keyevent KEYCODE_HOME")
            dev.sleep(0.5)
            dev.sh("input keyevent KEYCODE_HOME")
            dev.sleep(1.5)
            x, y = _icon(measure)
            remote = f"/data/local/tmp/richos-cold-blank-{n}.mp4"
            local = os.path.join(out_dir, f"start-{n:03d}.mp4")
            rec = popen([dev.adb, "-s", dev.serial, "shell", "screenrecord", "--time-limit", str(record_s), remote],
                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                dev.sleep(STILL_BEFORE_TAP_S)
                dev.sh(f"input tap {x} {y}")
            finally:
                try:
                    _, err = rec.communicate(timeout=record_s + 20)
                except subprocess.TimeoutExpired:
                    rec.kill()
                    rec.communicate()
                    raise Unmeasurable(f"screenrecord did not end {record_s + 20} s after it started")
            if rec.returncode:
                raise Unmeasurable(f"screenrecord exited {rec.returncode}: {(err or b'').decode(errors='replace').strip()[:200]}")
            dev.run("pull", remote, local)
            dev.sh(f"rm -f {remote}", check=False)
            try:
                result = analyze(local)
                results.append({"recording": local if keep else os.path.basename(local), "result": result})
                log(f"cold-blank {n}/{starts}: {result['verdict']}, longest blank {result['longestBlankMs']:.0f} ms")
            except blank.CannotAnswer as e:
                results.append({"recording": local if keep else os.path.basename(local), "error": str(e)})
                log(f"cold-blank {n}/{starts}: cannot answer: {e}")
    finally:
        if not keep:
            shutil.rmtree(out_dir, ignore_errors=True)
    series = blank.judge_series(results)
    return metric(series, results, method=(
        "force-stop; Home twice; tap the RichConnect icon on the launcher's first page with `input tap` while "
        f"`screenrecord --time-limit {record_s}` records from {STILL_BEFORE_TAP_S:.0f} s before the tap; each recording "
        "judged by richos/mobile/perf/blank.py (blank frames, the opening animation of a blank window, jumps), times "
        "from the home screen's first visible reaction to the tap"), kept=keep)


def iphone_cold_blank(recording, started_at, launches, decode=blank.decode):
    """The iPhone half: one XCTest screen recording of a tap-launch session; `started_at`, when it
    began on the phone's clock (its attachment's manifest `timestamp`, which phone-ios.py's summary
    keeps under screenRecordings); and per launch its (tap, leave) moments on the same clock, in
    order: the tap step's `tapAt` and the start of the runner's next step that sends the app away
    (Home or terminate; None: the next tap). Each window opens `IPHONE_LEAD_S` before its tap, and
    the analyzer finds the home screen's first reaction inside it, so the join need not be exact.
    Returns the `coldBlank` metric."""
    results = iphone_starts(recording, started_at, launches, decode)
    return metric(blank.judge_series(results), results, method=IPHONE_METHOD, kept=True)


IPHONE_METHOD = (
    "the UI-test runner taps the RichConnect icon on the Home Screen; XCTest's own screen recording of the session "
    "(phone-ios.py --screen-recording) judged by richos/mobile/perf/blank.py, one window per tap from "
    f"{IPHONE_LEAD_S} s before it to the step that sends the app away, placed by the recording's manifest timestamp "
    "on the phone's clock; times from the home screen's first visible reaction to the tap inside the window")


def iphone_starts(recording, started_at, launches, decode=blank.decode):
    """Each launch of `iphone_cold_blank`, judged: [{"recording", "result"} or {"recording", "error"}]."""
    if not launches:
        raise Unmeasurable("no tap moments: the session's step log names none")
    frames, meta = decode(recording)
    offset = -started_at
    results = []
    for k, (tap, leave) in enumerate(launches):
        start = tap + offset - IPHONE_LEAD_S
        if leave is not None:
            stop = leave + offset
        elif k + 1 < len(launches):
            stop = launches[k + 1][0] + offset - IPHONE_LEAD_S
        else:
            stop = meta["durationS"]
        try:
            result = blank.analyze(blank.window(frames, start, stop), duration=stop)
            result["recording"] = {"file": os.path.abspath(recording), "fromS": round(start, 3), "toS": round(stop, 3), **meta}
            results.append({"recording": f"{os.path.abspath(recording)}#{start:.3f}-{stop:.3f}", "result": result})
        except blank.CannotAnswer as e:
            results.append({"recording": f"{os.path.abspath(recording)}#{start:.3f}-{stop:.3f}", "error": str(e)})
    return results


LEAVE_STEPS = ("home", "terminate")


def launches_from_steps(lines):
    """(tap, leave) per tap on the RichConnect icon in a phone-ios.py step log (steps.jsonl): the tap
    step's `tapAt`, and the start of the next Home or terminate step (None when there is none)."""
    steps = [json.loads(line) for line in lines if line.strip()]
    launches = []
    for k, s in enumerate(steps):
        detail = s.get("detail") or {}
        if s.get("do") == "tap" and detail.get("label") == LABEL and s.get("ok") and detail.get("tapAt"):
            leave = next((n["start"] for n in steps[k + 1:] if n.get("do") in LEAVE_STEPS), None)
            launches.append((float(detail["tapAt"]), leave))
    return launches


def recording_from_run(run_dir):
    """The one screen recording a `phone-ios.py run --screen-recording` kept, and its manifest timestamp."""
    try:
        with open(os.path.join(run_dir, "attachments", "manifest.json")) as f:
            manifest = json.load(f)
    except (OSError, ValueError) as e:
        raise Unmeasurable(f"no readable attachments/manifest.json in {run_dir}: {e}")
    videos = [a for t in manifest for a in t.get("attachments", [])
              if str(a.get("exportedFileName", "")).lower().endswith((".mp4", ".mov", ".m4v"))]
    if len(videos) != 1 or not videos[0].get("timestamp"):
        raise Unmeasurable(f"{run_dir}: expected one screen recording with a timestamp, found {len(videos)}")
    return os.path.join(run_dir, "attachments", videos[0]["exportedFileName"]), float(videos[0]["timestamp"])


def iphone_run(run_dir, decode=blank.decode):
    """`iphone_starts` for a phone-ios.py run directory: its recording and its step log."""
    try:
        with open(os.path.join(run_dir, "steps.jsonl")) as f:
            launches = launches_from_steps(f)
    except (OSError, ValueError) as e:
        raise Unmeasurable(f"no readable steps.jsonl in {run_dir}: {e}")
    recording, started_at = recording_from_run(run_dir)
    return iphone_starts(recording, started_at, launches, decode=decode)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(prog="blankstart.py", description="the cold-start blank check on a phone (see the module doc)")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("iphone", help="judge a phone-ios.py --screen-recording run of RichConnect tap launches")
    i.add_argument("run_dirs", nargs="+", help="phone-ios.py run --out directories (steps.jsonl, attachments/)")
    args = p.parse_args(argv)
    try:
        results = []
        for d in args.run_dirs:
            results += iphone_run(d)
        m = metric(blank.judge_series(results), results, method=IPHONE_METHOD, kept=True)
        print(json.dumps({**m, "runs": [os.path.abspath(d) for d in args.run_dirs]}, indent=2))
        return 0 if m["verdict"] == "PASS" else 1
    except (Unmeasurable, blank.CannotAnswer) as e:
        print(f"blankstart.py: cannot answer: {e}", file=sys.stderr)
        return 2


def metric(series, results, method, kept):
    """The record's `coldBlank` metric: one sample per start (its worst stretch), the series verdict
    and every start over the limit."""
    samples = series["samplesMs"]
    return {"method": method, "samplesMs": samples, "stats": perfcore.stats(samples),
            "limitMs": blank.BLANK_LIMIT_MS, "statistic": series["statistic"], "valueMs": series["valueMs"],
            "verdict": series["verdict"], "why": series["why"], "rule": series["rule"],
            "overLimit": series["overLimit"], "unanswered": series["unanswered"],
            "recordingsKept": kept,
            "starts": [{"recording": r["recording"], **({"error": r["error"]} if r.get("error") else {
                "verdict": r["result"]["verdict"], "blankMs": r["result"]["blankMs"],
                "longestBlankMs": r["result"]["longestBlankMs"], "blankStretches": r["result"]["blankStretches"],
                "jumps": r["result"]["jumps"], "settledMs": r["result"]["settledMs"]})} for r in results],
            "measuredAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


if __name__ == "__main__":
    sys.exit(main())
