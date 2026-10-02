"""hook_command.py -- which guard scripts does a registered hook command EXECUTE?

P5-45: a registered command that only PRINTS a guard's path
(`echo "scripts/hooks/guard-ghost.sh"`) was credited as enforcing that guard,
because every reader searched the whole command string for the path. A guard is
run by a command when the path is the program of a shell segment (after
variable assignments and runner words such as bash, sh, env, python3), never
when it is an argument of echo, printf, cat, grep and the like.

Used by registered-hooks.sh at every site that reads a hook command.
"""
import os
import re
import shlex

_RUNNERS = {"bash", "sh", "zsh", "dash", "env", "exec", "nohup", "command",
            "time", "python", "python3", "node"}
_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_HOOK = re.compile(r"(?:^|/)scripts/hooks/([A-Za-z0-9._+-]+\.sh)$")


def _segments(cmd):
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    seg, out = [], []
    for tok in lex:
        if tok and all(c in "();&|<>" for c in tok):
            if seg:
                out.append(seg)
            seg = []
        else:
            seg.append(tok)
    if seg:
        out.append(seg)
    return out


def executed(cmd):
    """Return [(script basename, [following args])] for each guard the command runs."""
    if not isinstance(cmd, str):
        return []
    try:
        segs = _segments(cmd)
    except ValueError:
        return []
    found = []
    for seg in segs:
        i = 0
        while i < len(seg):
            t = seg[i]
            if _ASSIGN.match(t):
                i += 1
            elif os.path.basename(t) in _RUNNERS:
                i += 1
                while i < len(seg) and (seg[i].startswith("-") or _ASSIGN.match(seg[i])):
                    i += 1
            else:
                break
        if i < len(seg):
            m = _HOOK.search(seg[i])
            if m:
                found.append((m.group(1), seg[i + 1:]))
    return found


def executed_hooks(cmd):
    return [name for name, _ in executed(cmd)]


def dispatch_keys(cmd):
    """The event key of each `dispatch-pretooluse.sh <key>` the command runs."""
    return [args[0] for name, args in executed(cmd)
            if name == "dispatch-pretooluse.sh" and args]
