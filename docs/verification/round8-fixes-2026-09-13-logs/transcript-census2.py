#!/usr/bin/env python3
"""transcript-census2.py — READ-ONLY. The Stop gate reads the LEAD's transcript,
so this census keeps MAIN-session rows apart from sidechain/agent rows, and
groups every user TEXT row by the fields the platform stamps, with the platform
version range each shape was seen at. It then scores candidate rules against
the corpus: which rows each rule accepts as "a person's turn" and which it
rejects, by shape.

Usage: transcript-census2.py [projects-dir]
"""
import collections, json, os, sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/projects")
files = sorted(os.path.join(d, f) for d, _s, fs in os.walk(root) for f in fs if f.endswith(".jsonl"))


def vkey(v):
    try:
        return tuple(int(x) for x in (v or "0").split("."))
    except ValueError:
        return (0,)


def first_token(text):
    t = (text or "").lstrip()
    if not t:
        return "(empty)"
    if t.startswith("<"):
        return "<" + t[1:].split(">", 1)[0].split(" ", 1)[0] + ">"
    if t.startswith("["):
        return "[" + t[1:].split("]", 1)[0].split(":")[0].split(" ")[0] + "…]"
    if t.startswith("Another Claude session sent a message"):
        return "Another-Claude-session…"
    if t.startswith("Stop hook feedback"):
        return "Stop-hook-feedback"
    return "words"


rows = []          # (main?, shape-key, version, text, file, uuid)
for path in files:
    base = os.path.basename(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(d, dict) or d.get("type") != "user":
                    continue
                msg = d.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
                    continue
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
                else:
                    text = ""
                origin = d.get("origin")
                okind = origin.get("kind") if isinstance(origin, dict) else ("absent" if origin is None else "?")
                main = not d.get("isSidechain") and not base.startswith("agent-")
                key = (d.get("entrypoint"), okind, d.get("promptSource"), bool(d.get("isMeta")),
                       bool(d.get("isCompactSummary")), bool(d.get("queueSkipAttachments")), first_token(text))
                rows.append((main, key, d.get("version") or "", text, base, d.get("uuid")))
    except OSError:
        continue

by = collections.defaultdict(list)
for main, key, ver, text, f, u in rows:
    by[(main, key)].append((ver, text, f, u))

print("files: %d   user text rows: %d   main-session: %d   sidechain/agent: %d" % (
    len(files), len(rows), sum(1 for r in rows if r[0]), sum(1 for r in rows if not r[0])))
print()
print("MAIN-SESSION rows by stamped shape (entrypoint, origin.kind, promptSource, isMeta, isCompactSummary, queueSkipAttachments | first token) — version range")
for (main, key), lst in sorted(by.items(), key=lambda kv: (-kv[0][0], -len(kv[1]))):
    if not main:
        continue
    vs = sorted(set(v for v, _t, _f, _u in lst), key=vkey)
    print("%6d  %-8s origin=%-18s promptSource=%-20s meta=%-5s compact=%-5s queueSkip=%-5s | %-32s  v%s..v%s" % (
        len(lst), key[0], key[1], key[2], key[3], key[4], key[5], key[6], vs[0], vs[-1]))
print()
print("SIDECHAIN/AGENT rows by shape (for the record; the Stop gate never reads these)")
for (main, key), lst in sorted(by.items(), key=lambda kv: (-kv[0][0], -len(kv[1]))):
    if main:
        continue
    vs = sorted(set(v for v, _t, _f, _u in lst), key=vkey)
    print("%6d  %-8s origin=%-18s promptSource=%-20s meta=%-5s compact=%-5s queueSkip=%-5s | %-32s  v%s..v%s" % (
        len(lst), key[0], key[1], key[2], key[3], key[4], key[5], key[6], vs[0], vs[-1]))

# --- candidate rules, scored on MAIN rows -----------------------------------
def r_stamped(key):
    entry, okind, ps, meta, compact, qs, tok = key
    if meta or compact or qs:
        return False
    if ps == "system":
        return False
    if okind == "human":
        return True
    if okind == "absent" and ps in ("typed", "queued", "sdk", "suggestion_accepted"):
        return True
    return False

def r_origin_only(key):
    entry, okind, ps, meta, compact, qs, tok = key
    return (not meta) and okind == "human"

def r_deny_list_today(key):
    # what workspaces.py:2975 does: not isMeta, then a tag deny-list over the text
    entry, okind, ps, meta, compact, qs, tok = key
    if meta:
        return False
    if tok in ("<task-notification>", "<teammate-message>", "<system-reminder>", "<local-command>", "<command-name>"):
        return False
    return True

print()
for name, rule in (("STAMPED (origin human, or origin absent with promptSource typed/queued/sdk/suggestion_accepted; never meta/compact/queueSkip/system)", r_stamped),
                   ("ORIGIN-ONLY (origin.kind == human)", r_origin_only),
                   ("DENY-LIST TODAY (workspaces.py:2975)", r_deny_list_today)):
    acc = collections.Counter(); rej = collections.Counter()
    for (main, key), lst in by.items():
        if not main:
            continue
        (acc if rule(key) else rej)[key] += len(lst)
    print("=== rule: %s" % name)
    print("  accepts %d main rows:" % sum(acc.values()))
    for key, n in sorted(acc.items(), key=lambda kv: -kv[1]):
        print("    %6d  origin=%-18s promptSource=%-20s entry=%-8s | %s" % (n, key[1], key[2], key[0], key[6]))
    print("  rejects %d main rows:" % sum(rej.values()))
    for key, n in sorted(rej.items(), key=lambda kv: -kv[1]):
        print("    %6d  origin=%-18s promptSource=%-20s entry=%-8s meta=%s compact=%s queueSkip=%s | %s" % (n, key[1], key[2], key[0], key[3], key[4], key[5], key[6]))
    print()

# --- the rows with NO stamp at all (no origin, no promptSource, not meta) on MAIN transcripts, by version
print("=== MAIN rows with NO origin and NO promptSource and not meta/compact/queueSkip, by version and first token")
c = collections.Counter()
for (main, key), lst in by.items():
    if not main:
        continue
    entry, okind, ps, meta, compact, qs, tok = key
    if okind == "absent" and ps is None and not (meta or compact or qs):
        for v, _t, _f, _u in lst:
            c[(v, tok)] += 1
for (v, tok), n in sorted(c.items(), key=lambda kv: (vkey(kv[0][0]), kv[0][1])):
    print("   v%-10s %6d  %s" % (v, n, tok))

# --- the [Image …] person turn Frank named: main rows whose text starts with "[Image #" and are not meta
print()
print("=== MAIN rows whose text starts with '[Image #' (a pasted screenshot then his words)")
for (main, key), lst in by.items():
    if not main:
        continue
    for v, text, f, u in lst:
        if text.lstrip().startswith("[Image #"):
            print("   v%s origin=%s promptSource=%s meta=%s | %s | %s | %r" % (v, key[1], key[2], key[3], f, u, text[:50]))
