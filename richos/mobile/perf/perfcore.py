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

# THE COLD-START STANDARD, the ONLY place its limits live (CEO 2026-10-03, richos-hq/wiki/ceo-decisions.md
# §104, his words): "iPhone: the first 2-5 cold starts must be under 800 ms on the test
# phone. The test instantly fails if that's not the case. No need to wait for 20. If the test doesn't fail
# after cold start 2-5, the average cold start time on the test iPhone must always be under 700 ms (among
# the cold starts 2-20). Android: the first 2-5 cold starts must be under 1000 ms on the Android test phone
# phone ... the average cold start time on the test Android must always be under 900 ms (among the cold
# starts 2-20)." Start 1 is not judged. `earlyMs` judges each of starts 2-5; `avgMs` judges the average of
# starts 2-20. "Under" is strict: a start or average equal to its limit fails.
COLD_STANDARD = {
    "ios": {"earlyMs": 800, "avgMs": 700, "phone": "the iOS test phone"},
    "android": {"earlyMs": 1000, "avgMs": 900, "phone": "the Android test phone"},
}
# THE WARM-START STANDARD (the CEO's final limits, 2026-10-03, richos-hq/wiki/ceo-decisions.md §104).
#   the iOS test phone: 818 ms per start (starts 2-5), 716 ms average. The whole return, the iOS opening
#     animation included, measured the same way as the cold start; best warm median 595 ms times the cold
#     margins (800/582 per start, 700/582 average).
#   the Android test phone: 200 ms per start, 150 ms average, set by the CEO himself:
#     "No need to go crazy. That's plenty good enough."
# A limit set to None would make a warm judgment RAISE LimitNotSet; it never passes or fails silently.
WARM_STANDARD = {
    "ios": {"earlyMs": 818, "avgMs": 716, "phone": "the iOS test phone"},
    "android": {"earlyMs": 200, "avgMs": 150, "phone": "the Android test phone"},
}
STANDARDS = {"cold": COLD_STANDARD, "warm": WARM_STANDARD}
COLD_STARTS = 20          # a start test is 20 normal starts
COLD_EARLY_LAST = 5       # starts 2..5 are each judged against earlyMs, the run stops at the first over
SOURCE_STANDARD = "CEO 2026-10-03, richos-hq/wiki/ceo-decisions.md §104"


class LimitNotSet(Exception):
    """A standard's limit is still a placeholder: the judgment refuses instead of guessing."""


def cold_verdict(platform, starts_ms, total=COLD_STARTS):
    return series_verdict("cold", platform, starts_ms, total)


def warm_verdict(platform, starts_ms, total=COLD_STARTS):
    return series_verdict("warm", platform, starts_ms, total)


def series_verdict(kind, platform, starts_ms, total=COLD_STARTS):
    """Judge a start series, kind "cold" or "warm". `starts_ms` is the start times in order, start 1 first
    (start 1 is never judged; None marks a start with no time). Returns a dict: verdict FAIL (a start 2-5 at
    or over the early limit, `stop` true: the run stops there; or the 2-`total` average at or over the
    average limit), PASS (all `total` starts judged, average under), or INCOMPLETE (not enough starts yet and
    nothing over: keep going when `stop` is false, never a pass). Raises LimitNotSet on a placeholder."""
    lim = STANDARDS[kind][platform]
    if lim["earlyMs"] is None or lim["avgMs"] is None:
        raise LimitNotSet(f"the {kind}-start limits for {platform} are not set in perfcore.py: the CEO fills them in")
    out = {"kind": kind, "platform": platform, "source": SOURCE_STANDARD,
           "method": f"the {kind}-start standard (starts 2-5 each under the early limit, then the 2-{total} average under the average limit), judged from the series' own samples", "earlyLimitMs": lim["earlyMs"],
           "averageLimitMs": lim["avgMs"], "startsMs": list(starts_ms), "stop": False}
    for n, ms in enumerate(starts_ms, 1):
        if n == 1 or n > COLD_EARLY_LAST or ms is None:
            continue
        if ms >= lim["earlyMs"]:
            out.update(verdict="FAIL", stop=True, failedStart=n, failedMs=ms,
                       why=f"{kind} start {n} took {ms} ms, not under {lim['earlyMs']} ms ({lim['phone']}); the run stops here")
            return out
    judged = starts_ms[1:total]
    if len(starts_ms) < total or any(ms is None for ms in judged):
        out.update(verdict="INCOMPLETE", why=f"{len([m for m in judged if m is not None])} of {total - 1} judged starts timed; no verdict")
        return out
    avg = sum(judged) / len(judged)
    out["averageMs"] = round(avg, 1)
    if avg >= lim["avgMs"]:
        out.update(verdict="FAIL", why=f"the average of {kind} starts 2-{total} is {avg:.0f} ms, not under {lim['avgMs']} ms ({lim['phone']})")
    else:
        out.update(verdict="PASS", why=f"the average of {kind} starts 2-{total} is {avg:.0f} ms, under {lim['avgMs']} ms; starts 2-{COLD_EARLY_LAST} each under {lim['earlyMs']} ms")
    return out


def should_stop(kind, platform, starts_ms):
    """True when the series so far already fails the early limit: no further start is made."""
    return bool(series_verdict(kind, platform, starts_ms)["stop"])


def cold_should_stop(platform, starts_ms):
    return should_stop("cold", platform, starts_ms)


def warm_should_stop(platform, starts_ms):
    return should_stop("warm", platform, starts_ms)


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
    if ((record.get("benchmark") or {}).get("verdict") == "SLOWER THAN THE ESTABLISHED BENCHMARK"
            and not str((record.get("acceptance") or {}).get("verdict", "")).startswith("REFUSED")):
        problems.append("the record is slower than the established benchmark but its acceptance is not REFUSED")
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
