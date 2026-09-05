#!/usr/bin/env python3
"""g4: how often does guard-worktree-removal.sh's classifier fire on text that
DESCRIBES a removal rather than performing one?

Replays the SHIPPED classifier (extracted verbatim from the guard) over every
Bash call in every transcript on this machine, and sorts the hits by WHERE the
matched text sits: in the executable part of the command, inside a `-m` message
body, or inside a heredoc payload.
"""
import json
import os
import re
import sys

ROOT = "/Users/alex/.claude/projects"

GIT_GLOBAL_OPTS_WITH_VALUE = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
    "--super-prefix", "--config-env",
}
GIT_READ_ONLY_SUBCOMMANDS = {
    "annotate", "blame", "cat-file", "cherry", "config", "count-objects",
    "describe", "diff", "for-each-ref", "grep", "help", "log", "ls-files",
    "ls-remote", "ls-tree", "merge-base", "name-rev", "range-diff", "reflog",
    "rev-list", "rev-parse", "shortlog", "show", "show-ref", "status",
    "symbolic-ref", "var", "verify-commit", "verify-tag", "version",
    "whatchanged",
}
GIT_INVOCATION = re.compile(r"(?:^|[;&|(\n\"'`]|\s)git\b(?P<args>[^\n;|&)]*)")
RM_CLAUSE = re.compile(r"(?:^|[;&|(]\s*|\s)rm\b(?P<args>[^;&|)]*)")


def _git_subcommand(tokens):
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in GIT_GLOBAL_OPTS_WITH_VALUE:
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t, tokens[i + 1:]
    return None, []


def classify(cmd):
    """-> list of (reason, match-start) exactly as the shipped guard decides."""
    hits = []
    for m in GIT_INVOCATION.finditer(cmd):
        sub, rest = _git_subcommand(m.group("args").split())
        if sub is None or sub in GIT_READ_ONLY_SUBCOMMANDS:
            continue
        if sub == "worktree":
            sub2 = next((t for t in rest if not t.startswith("-")), None)
            if sub2 == "remove":
                hits.append(("git worktree remove", m.start()))
            elif sub2 == "prune" and any(
                    t == "--expire" or t.startswith("--expire=") for t in rest):
                hits.append(("git worktree prune --expire", m.start()))
        elif sub == "branch":
            deletes = any(t == "--delete" or re.fullmatch(r"-[A-Za-z]*[dD][A-Za-z]*", t)
                          for t in rest)
            if deletes and any(re.search(r"\bworktree-\S+", t) for t in rest):
                hits.append(("git branch -D of a worktree-* branch", m.start()))
    for m in RM_CLAUSE.finditer(cmd):
        before = cmd[:m.start()].rstrip()
        if before.split()[-1:] == ["git"]:
            continue
        args = m.group("args")
        if not (re.search(r"(?:^|\s)-[A-Za-z]*[rR][A-Za-z]*\b", args)
                or re.search(r"--recursive\b", args)):
            continue
        for raw in re.findall(r"\S+", args):
            tok = raw.strip("\"'")
            if not tok or tok.startswith("-"):
                continue
            if re.search(r"\.claude/worktrees/agent-\S*", tok):
                hits.append(("rm -r of a .claude/worktrees/agent-* path", m.start()))
    return hits


HEREDOC_START = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def heredoc_spans(cmd):
    """[(start, end, consumer-line)] character spans of every heredoc BODY."""
    spans = []
    lines = cmd.split("\n")
    offs, o = [], 0
    for ln in lines:
        offs.append(o)
        o += len(ln) + 1
    i = 0
    while i < len(lines):
        m = HEREDOC_START.search(lines[i])
        if m:
            tag = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() != tag:
                j += 1
            if j > i + 1:
                spans.append((offs[i + 1], offs[j] if j < len(lines) else len(cmd),
                              lines[i]))
            i = j
        i += 1
    return spans


MSG_FLAG = re.compile(r"(?:^|\s)(?:-m|--message)(?:=|\s+)(?P<q>['\"])")


def message_spans(cmd):
    """[(start, end)] character spans of every -m/--message quoted operand."""
    spans = []
    for m in MSG_FLAG.finditer(cmd):
        q = m.group("q")
        start = m.end()
        i = start
        while i < len(cmd):
            if cmd[i] == "\\" and q == '"':
                i += 2
                continue
            if cmd[i] == q:
                break
            i += 1
        spans.append((start, i))
    return spans


def inside(pos, spans):
    return any(a <= pos < b for a, b, *_ in spans)


def commands():
    for dirpath, _d, files in os.walk(ROOT):
        for fn in files:
            if not fn.endswith(".jsonl"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                fh = open(p, encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh:
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
                        if cmd:
                            yield rec.get("timestamp", ""), cmd


total = 0
fired = 0
in_msg = 0
in_hd = 0
in_exec = 0
hd_shell = 0
examples = {"msg": [], "hd": [], "exec": []}
for ts, cmd in commands():
    total += 1
    hits = classify(cmd)
    if not hits:
        continue
    fired += 1
    hd = heredoc_spans(cmd)
    ms = message_spans(cmd)
    for reason, pos in hits:
        if inside(pos, ms):
            in_msg += 1
            if len(examples["msg"]) < 6:
                examples["msg"].append((ts, reason, cmd[max(0, pos - 60):pos + 90]))
        elif inside(pos, hd):
            in_hd += 1
            consumer = next(c for a, b, c in hd if a <= pos < b)
            if re.search(r"(?:^|[|;&]\s*)(?:\S*/)?(?:ba|z|k|da)?sh\b", consumer):
                hd_shell += 1
            if len(examples["hd"]) < 8:
                examples["hd"].append((ts, reason, consumer.strip()[:90],
                                       cmd[max(0, pos - 40):pos + 80]))
        else:
            in_exec += 1
            if len(examples["exec"]) < 10:
                examples["exec"].append((ts, reason, cmd[max(0, pos - 60):pos + 120]))

print("Bash calls examined                         :", total)
print("calls the SHIPPED classifier finds destructive:", fired)
print()
print("  hits in the EXECUTABLE part of the command :", in_exec)
print("  hits inside a -m/--message BODY            :", in_msg, " <- prose about a command")
print("  hits inside a HEREDOC PAYLOAD              :", in_hd, " <- document being written")
print("      of those, fed to a SHELL (would still execute):", hd_shell)
print()
for k, label in (("msg", "MESSAGE-BODY HITS"), ("hd", "HEREDOC-PAYLOAD HITS"),
                 ("exec", "EXECUTABLE HITS")):
    print("=== %s ===" % label)
    for row in examples[k]:
        print("  ", row[0], "|", row[1])
        for extra in row[2:]:
            print("     ", extra.replace("\n", "\\n")[:180])
    print()
