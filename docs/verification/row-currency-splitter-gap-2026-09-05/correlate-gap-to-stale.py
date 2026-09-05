#!/usr/bin/env python3
"""Did the stale rows reach main THROUGH the g8 gap, or past a guard that saw
the call and let it by?

For each richos-hq commit that landed with a stale richos-hq-internal row, find
the Bash tool call that produced it (a git commit/merge anchored at richos-hq
whose timestamp is within 180s before the commit's committer date) and record
whether the SHIPPED splitter recognized that call at all.
"""
import datetime
import json
import os
import re
import shlex
import subprocess

ROOT = "/Users/alex/.claude/projects"
REPO = "/Users/alex/ab/richos-hq"
SINCE = datetime.datetime(2026, 8, 30).timestamp()


def top_level_segments(text):
    segs, cur, quote, esc = [], [], None, False
    i = 0
    while i < len(text):
        ch = text[i]
        if esc:
            cur.append(ch); esc = False; i += 1; continue
        if quote:
            if ch == "\\" and quote == '"':
                cur.append(ch); esc = True; i += 1; continue
            if ch == quote:
                quote = None
            cur.append(ch); i += 1; continue
        if ch == "\\":
            cur.append(ch); esc = True; i += 1; continue
        if ch in ("'", '"'):
            quote = ch; cur.append(ch); i += 1; continue
        if text[i:i + 2] in ("&&", "||"):
            segs.append("".join(cur)); cur = []; i += 2; continue
        if ch in ";\n|":
            segs.append("".join(cur)); cur = []; i += 1; continue
        cur.append(ch); i += 1
    segs.append("".join(cur))
    return segs


def naive_segments(text):
    return re.split(r"(?:\|\||&&|[;\n|])", text)


def walk(segments):
    for seg in segments:
        try:
            argv = shlex.split(seg, comments=False)
        except ValueError:
            continue
        while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
            argv.pop(0)
        if not argv or os.path.basename(argv[0]) != "git":
            continue
        k, sub = 1, ""
        while k < len(argv):
            a = argv[k]
            if a == "-C" and k + 1 < len(argv):
                k += 2; continue
            if a.startswith("--git-dir") or a.startswith("--work-tree"):
                k += 2 if "=" not in a else 1
                continue
            if a.startswith("-c") and a != "-c":
                k += 1; continue
            if a == "-c" and k + 1 < len(argv):
                k += 2; continue
            if a.startswith("-"):
                k += 1; continue
            sub = a
            k += 1
            break
        if sub in ("commit", "merge"):
            return sub
    return None


calls = []
for dirpath, _d, files in os.walk(ROOT):
    for fn in files:
        if not fn.endswith(".jsonl"):
            continue
        p = os.path.join(dirpath, fn)
        try:
            if os.path.getmtime(p) < SINCE:
                continue
        except OSError:
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"Bash"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                msg = rec.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for blk in content:
                    if not isinstance(blk, dict):
                        continue
                    if blk.get("type") != "tool_use" or blk.get("name") != "Bash":
                        continue
                    cmd = (blk.get("input") or {}).get("command") or ""
                    ts = rec.get("timestamp") or ""
                    if not cmd or not ts or "git" not in cmd:
                        continue
                    if "richos-hq" not in cmd and "richos-hq" not in (rec.get("cwd") or ""):
                        continue
                    if not walk(top_level_segments(cmd)):
                        continue
                    try:
                        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except Exception:
                        continue
                    calls.append((t, cmd))
calls.sort(key=lambda r: r[0])
print("candidate richos-hq commit/merge calls found in transcripts:", len(calls))

HERE = os.path.dirname(os.path.abspath(__file__))
STALE = subprocess.run(
    ["python3", os.path.join(HERE, "replay-stale-rows.py")],
    capture_output=True, text=True).stdout
shas = [l.split()[0] for l in STALE.split("\n")
        if re.match(r"^[0-9a-f]{12}\s", l)]
print("stale-carrying commits to correlate:", len(shas))
print()

seen_by_old = 0
missed_by_old = 0
unmatched = 0
for sha in shas:
    when = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%cI", sha],
                          capture_output=True, text=True).stdout.strip()
    subj = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%s", sha],
                          capture_output=True, text=True).stdout.strip()
    t = datetime.datetime.fromisoformat(when)
    best = None
    for ct, cmd in calls:
        d = (t - ct).total_seconds()
        if 0 <= d <= 180:
            if best is None or d < best[0]:
                best = (d, cmd)
    if best is None:
        unmatched += 1
        print("%s  %-60s  NO MATCHING CALL FOUND" % (sha, subj[:60]))
        continue
    old = walk(naive_segments(best[1]))
    if old:
        seen_by_old += 1
        verdict = "the shipped splitter SAW this call"
    else:
        missed_by_old += 1
        verdict = "the shipped splitter NEVER SAW this call  <-- through the gap"
    print("%s  %-60s  %s" % (sha, subj[:60], verdict))

print()
print("stale-carrying commits whose producing call the shipped splitter MISSED:",
      missed_by_old)
print("stale-carrying commits whose producing call it recognized             :",
      seen_by_old)
print("stale-carrying commits with no call found in any transcript           :",
      unmatched)
