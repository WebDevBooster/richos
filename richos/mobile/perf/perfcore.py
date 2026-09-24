"""perfcore — the record every RichConnect measurement writes, its statistics and its budgets.

One record per run, one JSON document, the same shape for both platforms (schema
`richos-mobile-perf/1`). A record names the build (commit and installed-bytes hash), the device,
the route and every number with the method that produced it. It never carries a number that was
not measured: a metric the run could not measure is `null` beside a `notMeasured` sentence.

Budgets are the PRD's (richos-hq/docs/prds/2026-09-24-richconnect-perceived-speed-and-no-annoyance.md
§7). They are Codex's PROPOSED engineering targets, not the CEO's words and not measured facts; the
record says so beside every comparison. A comparison is never an acceptance verdict: PRD §8 says
missing physical-device evidence is NOT VERIFIED, never PASS, so `acceptance` is `NOT VERIFIED`
unless the device is physical, the build is a release configuration and the sample is at least the
protocol's 100 trials. Even then this tool reports evidence; people decide acceptance.
"""
import hashlib
import json
import math
import os
import subprocess

SCHEMA = "richos-mobile-perf/1"

PRD = "richos-hq/docs/prds/2026-09-24-richconnect-perceived-speed-and-no-annoyance.md"

# PRD §7, verbatim targets. `metric` names the record key each budget is compared against.
BUDGETS = {
    "coldLaunch": {"p95Ms": 1000, "row": "Cold launch to useful local interaction",
                   "boundary": "OS launch request to correct saved viewport and composer accepting input"},
    "warmResume": {"p95Ms": 200, "row": "Warm resume to usable retained state",
                   "boundary": "Foreground transition begins to correct retained content accepting input"},
    "tapToFeedback": {"p95Ms": 100, "row": "Tap, edit or gesture feedback",
                      "boundary": "Input event to its visible response"},
    "sendToQueued": {"p95Ms": 150, "row": "Small text send to durable local queued state",
                     "boundary": "Send input to safe local persistence and queued UI"},
    "receiveToVisible": {"p95Ms": 100, "row": "Received text to visible text",
                         "boundary": "Complete usable stream data reaching the client to rendered text"},
    "activeFrames": {"onTimePercentMin": 99.0, "stallMsMax": 100, "row": "Scrolling, keyboard and transition smoothness",
                     "boundary": "active frames meeting the OS frame deadline; no app-caused stall >= 100 ms"},
    "backgroundQuiet": {"max": 0, "row": "Background quiet",
                        "boundary": "zero app-originated periodic refresh, retries or keep-alives after cancellation settles"},
    "idleFrames": {"max": 0, "row": "Settled idle UI",
                   "boundary": "zero app-driven recurring redraws and no recurring app timer without work due"},
}

# PRD §8: "at least 100 trials per launch class and primary device configuration".
PROTOCOL_TRIALS = 100


class Refused(Exception):
    """The run cannot answer honestly (wrong build, wrong device, missing tool). Exit 3."""


class Unmeasurable(Exception):
    """One metric could not be measured on this device or build; the record says why."""


def percentile(samples, p):
    """Nearest-rank percentile (the smallest sample with at least p% of samples at or below it)."""
    if not samples:
        return None
    ordered = sorted(samples)
    rank = max(1, math.ceil(p / 100.0 * len(ordered)))
    return ordered[rank - 1]


def stats(samples):
    """p50 always; p95 from 20 samples, p99 from 100 (fewer cannot place them); max and n."""
    n = len(samples)
    out = {"n": n, "min": min(samples) if n else None, "p50": percentile(samples, 50),
           "p95": percentile(samples, 95) if n >= 20 else None,
           "p99": percentile(samples, 99) if n >= 100 else None,
           "max": max(samples) if n else None}
    if n and n < 20:
        out["why"] = f"{n} samples cannot place a p95 (needs 20) or a p99 (needs 100); a pilot sample"
    elif n and n < 100:
        out["why"] = f"{n} samples cannot place a p99 (needs 100); below the PRD §8 protocol of 100 trials"
    return out


def compare(metric, summary, key="p95"):
    """Set a metric's statistic beside its PRD §7 budget. Never a verdict (see module doc)."""
    budget = BUDGETS[metric]
    value = summary.get(key)
    target = budget.get("p95Ms")
    out = {"budget": target, "unit": "ms", "statistic": key, "row": budget["row"],
           "source": f"{PRD} §7 (proposed target, not a CEO number)"}
    if value is None or target is None:
        out["within"] = None
        out["why"] = summary.get("why") or "no statistic to compare"
    else:
        out["within"] = value <= target
    return out


def acceptance(device_kind, release_build, samples):
    reasons = []
    if device_kind != "physical":
        reasons.append("not a physical device (PRD §8: an emulator or simulator cannot certify)")
    if not release_build:
        reasons.append("not a release configuration (debuggable build; PRD §7 budgets are for release builds)")
    if samples < PROTOCOL_TRIALS:
        reasons.append(f"{samples} launch trials, below the PRD §8 protocol of {PROTOCOL_TRIALS}")
    return {"verdict": "NOT VERIFIED" if reasons else "EVIDENCE ONLY (a reviewer decides)", "why": reasons}


def tree_sha256(path):
    """A directory's identity: sha256 over its relative paths and file bytes, in sorted order."""
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, path).encode() + b"\0")
            if os.path.islink(full):
                h.update(b"link:" + os.readlink(full).encode())
            else:
                with open(full, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
            h.update(b"\0")
    return h.hexdigest()


def git(checkout, *args):
    return subprocess.run(["git", "-C", checkout, *args], capture_output=True, text=True)


def source_identity(checkout, paths):
    """The commit a checkout is at, and whether `paths` under it differ from that commit."""
    head = git(checkout, "rev-parse", "HEAD")
    if head.returncode:
        raise Refused(f"{checkout} is not a git checkout: {head.stderr.strip()}")
    status = git(checkout, "status", "--porcelain", "--", *paths)
    if status.returncode:
        raise Refused(f"git status failed in {checkout}: {status.stderr.strip()}")
    return {"commit": head.stdout.strip(), "dirty": bool(status.stdout.strip()), "paths": list(paths)}


def check_record(record):
    """The structural promises of a record. Returns a list of sentences; empty means sound."""
    problems = []
    if record.get("schema") != SCHEMA:
        problems.append(f"schema is {record.get('schema')!r}, not {SCHEMA}")
    for key in ("platform", "build", "device", "route", "metrics", "acceptance", "notMeasured", "startedAt"):
        if key not in record:
            problems.append(f"no {key}")
    build = record.get("build") or {}
    if not build.get("commit"):
        problems.append("the build names no commit")
    if build.get("installedSha256") and build.get("builtSha256") and build["installedSha256"] != build["builtSha256"]:
        problems.append("the installed build is not the stamped build")
    device = record.get("device") or {}
    if device.get("kind") not in ("emulator", "physical", "simulator"):
        problems.append(f"device kind {device.get('kind')!r} is not emulator, simulator or physical")
    if (record.get("acceptance") or {}).get("verdict") == "PASS":
        problems.append("a record never says PASS (PRD §8: evidence, reviewed by people)")
    for name, metric in (record.get("metrics") or {}).items():
        if not isinstance(metric, dict):
            problems.append(f"metric {name} is not an object")
            continue
        if not metric.get("method"):
            problems.append(f"metric {name} states no method")
        samples = metric.get("samplesMs")
        summary = metric.get("stats")
        if samples is not None and summary is not None and summary.get("n") != len(samples):
            problems.append(f"metric {name}: stats.n {summary.get('n')} but {len(samples)} samples")
    for entry in record.get("notMeasured") or []:
        if not entry.get("what") or not entry.get("why"):
            problems.append(f"a notMeasured entry lacks what or why: {entry}")
    return problems


def dump(record):
    return json.dumps(record, indent=2, sort_keys=False) + "\n"
