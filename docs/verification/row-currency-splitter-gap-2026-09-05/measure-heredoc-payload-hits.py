#!/usr/bin/env python3
"""How often is a git commit/merge 'recognized' ONLY because the words appear
inside a heredoc BODY -- a document being written, not a command being run?

Same population as the g8 measurement: calls anchored at a governed main
checkout, where guard-row-currency-commits.sh would actually act.
"""
import datetime
import json
import os
import re
import shlex

ROOT = "/Users/alex/.claude/projects"
SINCE = datetime.datetime(2026, 8, 30).timestamp()
GOVERNED = {"/Users/alex/ab/richos", "/Users/alex/ab/richos-hq",
            "/Users/alex/ab/femcboost"}

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SHELL = re.compile(r"(?:^|[|;&]|\s)(?:env\s+\S+\s+)?(?:\S*/)?(?:sh|bash|zsh|ksh|dash)\b")


def blank_heredocs(src):
    chars = list(src)
    lines = src.split("\n")
    offs, o = [], 0
    for ln in lines:
        offs.append(o)
        o += len(ln) + 1
    i = 0
    shellfed = 0
    while i < len(lines):
        m = HEREDOC.search(lines[i])
        if m:
            tag = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() != tag:
                j += 1
            a = offs[i + 1] if i + 1 < len(lines) else len(src)
            b = offs[j] if j < len(lines) else len(src)
            if b > a:
                if SHELL.search(lines[i][:m.start()]):
                    shellfed += 1
                else:
                    for k in range(a, b):
                        if chars[k] != "\n":
                            chars[k] = " "
            i = j
        i += 1
    return "".join(chars), shellfed


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
    p = dashC or (CD_RE.search(cmd).group(1).strip("\"'") if CD_RE.search(cmd) else (cwd or ""))
    p = os.path.expanduser(p)
    if p and not os.path.isabs(p) and cwd:
        p = os.path.normpath(os.path.join(cwd, p))
    return p.rstrip("/")


hits = []
shell_total = 0
for dirpath, _d, files in os.walk(ROOT):
    for fn in files:
        if not fn.endswith(".jsonl"):
            continue
        fp = os.path.join(dirpath, fn)
        try:
            if os.path.getmtime(fp) < SINCE:
                continue
        except OSError:
            continue
        cwd = ""
        with open(fp, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"Bash"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if isinstance(rec.get("cwd"), str):
                    cwd = rec["cwd"]
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
                    if not cmd or "git" not in cmd or "<<" not in cmd:
                        continue
                    full, _dc = walk(top_level_segments(cmd))
                    _b, sf = blank_heredocs(cmd)
                    shell_total += sf
                    if not full:
                        continue
                    blanked, _ = blank_heredocs(cmd)
                    minus, dashC = walk(top_level_segments(blanked))
                    if minus:
                        continue
                    a = anchor(cmd, cwd, dashC)
                    hits.append((a in GOVERNED, a, rec.get("timestamp", ""), cmd))

gov = [h for h in hits if h[0]]
print("calls recognized as commit/merge ONLY because of a heredoc BODY:", len(hits))
print("  ...of those, anchored at a GOVERNED MAIN CHECKOUT (would act):", len(gov))
print("heredocs fed to a shell anywhere in the scanned set:", shell_total)
print()
for _g, a, ts, cmd in gov[:10]:
    print("---", ts, a)
    print("   ", cmd.replace("\n", "\\n")[:220])
