"""hook_command.py -- which guard scripts does a registered hook command EXECUTE?

P5-45: a registered command that only PRINTS a guard's path
(`echo "scripts/hooks/guard-ghost.sh"`) was credited as enforcing that guard,
because every reader searched the whole command string for the path. A guard is
run by a command when the path is the program of a shell segment (after
variable assignments and runner words such as bash, sh, env, python3), never
when it is an argument of echo, printf, cat, grep and the like.

P5-45 (v3): nor when it is the file operand of a redirection (`cat < g.sh`,
`echo x > g.sh`), the inline code of `python3 -c` / `node -e`, or the argument
of a runner option that takes one (`env -u NAME` no longer hides the program).
`bash -c '<command>'` is read as that command.

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
    operand = False
    for tok in lex:
        if operand:
            # Hunt P5-45 (v3): the word after a redirection is the file it reads or
            # writes (`cat < g.sh`, `echo x > g.sh`), never a command that runs.
            operand = False
            continue
        if tok and all(c in "();&|<>" for c in tok):
            if any(c in "<>" for c in tok):
                if any(c in "();|" for c in tok) and seg:
                    out.append(seg)
                    seg = []
                operand = True
                continue
            if seg:
                out.append(seg)
            seg = []
        else:
            seg.append(tok)
    if seg:
        out.append(seg)
    return out


# Options whose next word is their argument, not the program (`env -u NAME`).
_OPT_ARG = {"env": {"-u", "--unset", "-C", "--chdir"}, "exec": {"-a"},
            "python": {"-W", "-X"}, "python3": {"-W", "-X"}}
# Options after which the runner executes inline code or a module, not a script path.
_CODE_OPT = {"python": {"-c", "-m"}, "python3": {"-c", "-m"}, "node": {"-e", "-p", "--eval", "--print"},
             "command": {"-v", "-V"}}
_SHELLS = {"bash", "sh", "zsh", "dash"}


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
        code = False
        while i < len(seg) and not code:
            t = seg[i]
            if _ASSIGN.match(t):
                i += 1
            elif os.path.basename(t) in _RUNNERS:
                runner = os.path.basename(t)
                i += 1
                while i < len(seg) and (seg[i].startswith("-") or _ASSIGN.match(seg[i])):
                    opt = seg[i]
                    i += 1
                    if opt in _CODE_OPT.get(runner, ()):
                        code = True
                        break
                    if runner in _SHELLS and re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", opt):
                        # `bash -c '<command>'`: what runs is that command's own program.
                        if i < len(seg):
                            found.extend(executed(seg[i]))
                        code = True
                        break
                    if opt in _OPT_ARG.get(runner, ()):
                        i += 1
            else:
                break
        if code:
            continue
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
