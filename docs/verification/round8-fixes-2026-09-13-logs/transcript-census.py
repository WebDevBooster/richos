#!/usr/bin/env python3
"""transcript-census.py — READ-ONLY census of every persisted transcript row of
type "user" under ~/.claude/projects, grouped by the fields the platform STAMPS
(never by the text). Prints counts per shape, and, for every shape, whether an
ASSISTANT row follows it (i.e. whether it starts a turn at all).

Usage: transcript-census.py [projects-dir]
"""
import collections, json, os, sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/projects")
files = []
for d, _dirs, fs in os.walk(root):
    for f in fs:
        if f.endswith(".jsonl"):
            files.append(os.path.join(d, f))
files.sort()

def first_token(text):
    t = (text or "").lstrip()
    if not t:
        return "(empty)"
    if t.startswith("<"):
        return "<" + t[1:].split(">", 1)[0].split(" ", 1)[0] + ">"
    if t.startswith("["):
        return "[" + t[1:].split("]", 1)[0] + "]"
    if t.startswith("Another Claude session sent a message"):
        return "Another-Claude-session…"
    if t.startswith("Stop hook feedback"):
        return "Stop-hook-feedback"
    return "words"

shapes = collections.Counter()
followed = collections.Counter()
examples = {}
rows_total = 0
tool_result_rows = 0
for path in files:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        continue
    parsed = []
    for line in lines:
        try:
            parsed.append(json.loads(line))
        except ValueError:
            parsed.append(None)
    for i, d in enumerate(parsed):
        if not isinstance(d, dict) or d.get("type") != "user":
            continue
        rows_total += 1
        msg = d.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            tool_result_rows += 1
            continue
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
        else:
            text = ""
        origin = d.get("origin")
        okind = origin.get("kind") if isinstance(origin, dict) else ("absent" if origin is None else "?")
        key = (
            "entry=%s" % d.get("entrypoint"),
            "origin=%s" % okind,
            "promptSource=%s" % d.get("promptSource"),
            "isMeta=%s" % d.get("isMeta"),
            "isCompactSummary=%s" % d.get("isCompactSummary"),
            "queueSkip=%s" % d.get("queueSkipAttachments"),
            "text=%s" % first_token(text),
        )
        shapes[key] += 1
        nxt = None
        for j in range(i + 1, min(i + 6, len(parsed))):
            n = parsed[j]
            if isinstance(n, dict) and n.get("type") in ("assistant", "user"):
                nxt = n.get("type")
                break
        if nxt == "assistant":
            followed[key] += 1
        if key not in examples:
            examples[key] = (os.path.basename(path), d.get("uuid"), (text or "")[:60].replace("\n", " "))

print("files: %d   user rows: %d   of which tool_result rows: %d   text rows: %d" % (
    len(files), rows_total, tool_result_rows, sum(shapes.values())))
print()
print("%6s %6s  shape" % ("rows", "->asst"))
for key, n in sorted(shapes.items(), key=lambda kv: -kv[1]):
    print("%6d %6d  %s" % (n, followed[key], "  ".join(key)))
print()
print("one example per shape (file, uuid, first 60 chars):")
for key, n in sorted(shapes.items(), key=lambda kv: -kv[1]):
    f, u, t = examples[key]
    print("  %s | %s | %s | %r" % ("  ".join(key), f, u, t))
