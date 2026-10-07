#!/usr/bin/env python3
"""Tokens used per percentage point of the Claude quota, per account.

  token-track.py sample   [--account LABEL=DIR ...] [--accounts-file F]
  token-track.py report   [--account LABEL=DIR ...] [--accounts-file F]

`sample` reads each account's five-hour and weekly percentages (the same
get_usage read quota_watch.py uses, with CLAUDE_CONFIG_DIR set to the account's
folder) and appends one row per account to <state>/readings.jsonl. Run it every
few minutes (the weekly-switch test rounds run it before and after a job).

`report` joins those rows with the token counts in each account's Claude Code
transcripts (<folder>/projects/**/*.jsonl: input, output, cache write, cache
read, by model) and prints, per account, how many tokens by kind raised the
weekly and the five-hour percentage by one point, and how many rises that is
based on. Between two consecutive readings of the same window the tokens used
are summed; the answer is total tokens / total points over those pairs, so
percentage rounding averages out. A window that reset between two readings is
skipped.

The default account is ~/.claude. State: ~/.claude/state/token-track/
(override with TOKEN_TRACK_STATE). Nothing is written into a repository.
"""
import argparse
import datetime
import glob
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KINDS = ("input", "output", "cache_write", "cache_read")
FIELDS = {"input": "input_tokens", "output": "output_tokens",
          "cache_write": "cache_creation_input_tokens", "cache_read": "cache_read_input_tokens"}


def state_dir():
    return os.environ.get("TOKEN_TRACK_STATE") or os.path.join(os.path.expanduser("~"), ".claude", "state", "token-track")


def accounts(args):
    result = {}
    if not args.account and not args.accounts_file:
        result["default"] = os.path.join(os.path.expanduser("~"), ".claude")
    for spec in args.account or []:
        label, _, folder = spec.partition("=")
        result[label] = os.path.expanduser(folder)
    if args.accounts_file:
        with open(args.accounts_file) as fh:
            for a in json.load(fh).get("accounts", []):
                result[str(a.get("label") or a.get("id"))] = os.path.expanduser(a.get("folder") or "~/.claude")
    return result


def parse_ts(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def read_tokens(folder):
    """[(epoch, model, {kind: n})] from every transcript under folder/projects.
    A streamed message appears several times with the same id; the last (largest) copy wins."""
    last = {}
    for path in glob.glob(os.path.join(folder, "projects", "**", "*.jsonl"), recursive=True):
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    row = json.loads(line)
                    msg = row["message"]
                    usage = msg["usage"]
                    at = parse_ts(row["timestamp"])
                except (ValueError, KeyError, TypeError):
                    continue
                if not isinstance(usage, dict):
                    continue
                counts = {k: int(usage.get(f) or 0) for k, f in FIELDS.items()}
                key = msg.get("id") or row.get("uuid") or (path, at)
                old = last.get(key)
                if old is None or counts["output"] >= old[2]["output"]:
                    last[key] = (at, msg.get("model") or "unknown", counts)
    return sorted(last.values(), key=lambda t: t[0])


def window(reading, which):
    """(percent, resets_at) of 'five_hour' or 'seven_day' from a row."""
    w = reading.get(which)
    return (w["used"], w["resets_at"]) if w else (None, None)


def per_point(readings, tokens, which):
    rows = [r for r in readings if r.get(which)]
    rows.sort(key=lambda r: r["at"])
    total = {k: 0 for k in KINDS}
    by_model = {}
    points = 0.0
    rises = 0
    for a, b in zip(rows, rows[1:]):
        ua, ra = window(a, which)
        ub, rb = window(b, which)
        if ra is None or rb is None or abs(ra - rb) > 120 or ub < ua:
            continue
        for at, model, counts in tokens:
            if a["at"] < at <= b["at"]:
                for k in KINDS:
                    total[k] += counts[k]
                    by_model.setdefault(model, {x: 0 for x in KINDS})[k] += counts[k]
        if ub > ua:
            rises += 1
            points += ub - ua
    return {"points": points, "rises": rises, "tokens": total, "by_model": by_model,
            "per_point": {k: round(total[k] / points) for k in KINDS} if points else None}


def load_readings(path):
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return rows


def cmd_report(args):
    readings = load_readings(os.path.join(state_dir(), "readings.jsonl"))
    for label, folder in accounts(args).items():
        mine = [r for r in readings if r.get("account") == label]
        tokens = read_tokens(folder)
        print("account %s (%s): %d readings, %d token rows" % (label, folder, len(mine), len(tokens)))
        for which, name in (("seven_day", "weekly"), ("five_hour", "five-hour")):
            r = per_point(mine, tokens, which)
            if not r["per_point"]:
                print("  %s: no rise measured yet (%d readings of it)" % (name, sum(1 for x in mine if x.get(which))))
                continue
            p = r["per_point"]
            print("  %s: 1 point = %s tokens (input %d, output %d, cache write %d, cache read %d); "
                  "%g points over %d rises" % (name, format(sum(p.values()), ","), p["input"], p["output"],
                                               p["cache_write"], p["cache_read"], r["points"], r["rises"]))
            for model, c in sorted(r["by_model"].items()):
                print("    %s: %s" % (model, ", ".join("%s %s" % (k, format(c[k], ",")) for k in KINDS)))
    return 0


def cmd_sample(args):
    sys.path.insert(0, os.path.join(HERE, "lib"))
    import quota_watch
    os.makedirs(state_dir(), exist_ok=True)
    status = 0
    for label, folder in accounts(args).items():
        old = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = folder
        try:
            now = int(time.time())
            r = quota_watch.read_get_usage(now)
        finally:
            if old is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = old
        if r["state"] != "ok":
            print("account %s: no reading (%s)" % (label, r["why"]), file=sys.stderr)
            status = 1
            continue
        row = {"at": now, "account": label, "five_hour": {"used": r["used"], "resets_at": r["resets_at"]}}
        for w in r.get("windows", []):
            if w["id"] == "seven_day" and w["resets_at"]:
                row["seven_day"] = {"used": w["used"], "resets_at": w["resets_at"]}
        with open(os.path.join(state_dir(), "readings.jsonl"), "a") as fh:
            fh.write(json.dumps(row) + "\n")
        print("account %s: five-hour %g%%, weekly %s" % (label, r["used"], ("%g%%" % row["seven_day"]["used"]) if "seven_day" in row else "unknown"))
    return status


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("command", choices=("sample", "report"))
    p.add_argument("--account", action="append", metavar="LABEL=DIR", help="a Claude config folder; default ~/.claude")
    p.add_argument("--accounts-file", help="the app's claude-accounts.json")
    args = p.parse_args(argv)
    return {"sample": cmd_sample, "report": cmd_report}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
