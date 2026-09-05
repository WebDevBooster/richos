#!/usr/bin/env python3
"""g8, narrowed to the population the guard would actually have JUDGED.

The guard only acts at a LANDING: the MAIN checkout of a repository that
declares a row-currency contract, on an attached HEAD. So the raw 488 from
measure_g8.py is an upper bound, not the answer. Here we resolve the anchor
repository of each recognized commit/merge the way scripts/lib/git-jurisdiction.sh
does (`git -C <path>`, a leading `cd <path> &&`, else the payload cwd) and keep
only the ones anchored at a governed MAIN checkout.
"""
import json
import os
import re
import shlex
import datetime

ROOT = "/Users/alex/.claude/projects"
SINCE = datetime.datetime(2026, 8, 30).timestamp()

# main checkout -> date its row-currency declaration first existed
GOVERNED = {
    "/Users/alex/ab/richos": "2026-08-30",
    "/Users/alex/ab/richos-hq": "2026-08-30",
    "/Users/alex/ab/femcboost": "2026-09-02",
}


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
    """(subcommand, -C value) for the first git commit/merge seen."""
    for seg in segments:
        try:
            argv = shlex.split(seg, comments=False)
        except ValueError:
            continue
        while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
            argv.pop(0)
        if not argv or os.path.basename(argv[0]) != "git":
            continue
        k, sub, dashC = 1, "", ""
        while k < len(argv):
            a = argv[k]
            if a == "-C" and k + 1 < len(argv):
                dashC = argv[k + 1]; k += 2; continue
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
            return sub, dashC
    return None, ""


CD_RE = re.compile(r"(?:^|[;&|\n]|&&)\s*cd\s+([^\s;&|]+)")


def anchor(cmd, cwd, dashC):
    if dashC:
        p = dashC
    else:
        m = CD_RE.search(cmd)
        p = m.group(1).strip("\"'") if m else (cwd or "")
    p = os.path.expanduser(p)
    if p and not os.path.isabs(p) and cwd:
        p = os.path.normpath(os.path.join(cwd, p))
    return p


def commands():
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
            try:
                fh = open(p, encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh:
                cwd_hint = ""
                for line in fh:
                    if '"cwd"' in line and '"Bash"' not in line:
                        try:
                            r = json.loads(line)
                            if isinstance(r.get("cwd"), str):
                                cwd_hint = r["cwd"]
                        except Exception:
                            pass
                    if '"Bash"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if isinstance(rec.get("cwd"), str):
                        cwd_hint = rec["cwd"]
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
                        if cmd:
                            yield rec.get("timestamp", ""), cwd_hint, cmd


def main():
    skipped_landing = []
    both_landing = 0
    inverse = []
    for ts, cwd, cmd in commands():
        if "git" not in cmd:
            continue
        o_sub, o_C = walk(naive_segments(cmd))
        n_sub, n_C = walk(top_level_segments(cmd))
        if o_sub and not n_sub:
            inverse.append((ts, cmd))
            continue
        if not n_sub:
            continue
        a = anchor(cmd, cwd, n_C or o_C)
        a = a.rstrip("/")
        if a not in GOVERNED:
            continue
        if o_sub:
            both_landing += 1
        else:
            skipped_landing.append((ts, a, n_sub, cmd))

    print("=== the population the guard would actually have judged ===")
    print("git commit/merge anchored at a GOVERNED MAIN CHECKOUT:",
          both_landing + len(skipped_landing))
    print("  seen by the shipped splitter (checked)   :", both_landing)
    print("  MISSED by the shipped splitter (skipped) :", len(skipped_landing))
    print()
    byrepo = {}
    for ts, a, sub, cmd in skipped_landing:
        byrepo.setdefault(a, []).append((ts, sub, cmd))
    for a, rows in sorted(byrepo.items()):
        print("%-32s %d skipped   first=%s  last=%s" %
              (a, len(rows), min(r[0] for r in rows), max(r[0] for r in rows)))
    print()
    print("=== INVERSE: recognized by the OLD splitter and not by the new (%d) ===" % len(inverse))
    for ts, cmd in inverse[:40]:
        print("---", ts)
        print("   ", cmd.replace("\n", "\\n")[:260])


main()
