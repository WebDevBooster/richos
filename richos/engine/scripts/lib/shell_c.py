#!/usr/bin/env python3
"""shell_c.py: refuse, BEFORE Claude Code asks the user, a Bash command that wraps an inline script
in `bash -c`, `sh -c` or `zsh -c`.

The CEO, 2026-10-09, saw "This shell -c script runs rm and could not be checked. Do you want to
proceed?" for a teammate's command, hit yes, and wrote: "I hope RichOS app users won't be bothered by
this." (The same prompt reached him on 2026-10-07 from the lead's own commands.) Claude Code cannot
check an inline shell script, so it asks the person. A PreToolUse refusal runs first, so the agent
gets the rewrite and the person never sees a prompt.

What is refused: a shell (bash, sh, zsh, dash, ksh, with or without a path) at a command position
whose options include `-c` (`-c`, `-lc`, `-ec`, `-xc`, `-o pipefail -c` ...). A command position is the
start of the command or the word after ; & | ( { newline ` $( , after sudo/env/nohup/time/exec/
command/xargs/NAME=value prefixes, and after `find -exec`.
What passes: `bash file.sh`, `bash -x file.sh`, `bash < file`, and any ordinary command. A MENTION is
not a call: text inside quotes (a commit message, an echo) and heredoc bodies is masked first.

IT IS A TEXT MATCH AND LEAKS (eval, a variable holding a command, a script file that itself runs
bash -c). Its job is to stop the habitual command, not an adversary. Any error in the check is a pass.
Shared by the operator-install rule (scripts/hooks/guard-no-shell-c.sh) and by the RichOS app's hook
(mega-lander/app.py validate_shell_target).
"""
import json
import re
import sys

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
PREFIXES = {"sudo", "env", "nohup", "time", "exec", "command", "builtin", "nice", "xargs", "stdbuf",
            "if", "then", "do", "else", "while", "until", "!"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SEPARATORS = re.compile(r"(?:&&|\|\||;;|[;&|\n(){}`])")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

MESSAGE = (
    "=== guard-no-shell-c: BLOCKED ===\n"
    "  This command wraps an inline script in `{shell} -c`. Claude Code cannot check an inline shell\n"
    "  script, so it stops and ASKS THE USER ('This shell -c script ... could not be checked. Do you\n"
    "  want to proceed?'). The user is never the fallback check.\n"
    "  FIX: run the steps as separate commands (one step per Bash call), or write the script to a file\n"
    "  in your scratch folder and run `bash <file>`. Running a script file stays allowed."
)


def _mask(command):
    """Blank out heredoc bodies and the inside of quoted strings; keep the quotes."""
    out = []
    pending = []
    for line in command.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
                out.append(line)
            else:
                out.append("")
            continue
        out.append(line)
        pending.extend(m.group(2) for m in HEREDOC.finditer(line))
    text = "\n".join(out)
    res = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            res.append(text[i:i + 2])
            i += 2
        elif c in "'\"":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if (c == '"' and text[j] == "\\") else 1
            res.append(c + "x" + c)  # a quoted word stays one word
            i = j + 1
        else:
            res.append(c)
            i += 1
    return "".join(res)


def _is_shell(word):
    return word.rsplit("/", 1)[-1] in SHELLS


def _has_c_option(args):
    """args: the words after the shell. True when an option before the first non-option word is -c."""
    k = 0
    while k < len(args):
        a = args[k]
        if a == "--":
            return False
        if a in ("-o", "+o", "-O", "+O"):
            k += 2
            continue
        if re.match(r"^-[A-Za-z]+$", a):
            if "c" in a[1:]:
                return True
            k += 1
            continue
        return False
    return False


def verdict(command):
    """Return the shell name when `command` runs an inline `shell -c` script, else None."""
    masked = _mask(command)
    for clause in SEPARATORS.split(masked):
        words = clause.replace("$", " ").split()
        k = 0
        while k < len(words):
            w = words[k]
            if w in PREFIXES or ASSIGN.match(w):
                k += 1
                # an option of the prefix (sudo -E, nice -n): skipped; an option that takes a value leaks
                while k < len(words) and words[k].startswith("-") and not _is_shell(words[k]):
                    k += 1
                continue
            if _is_shell(w) and _has_c_option(words[k + 1:]):
                return w.rsplit("/", 1)[-1]
            break
        # `find ... -exec bash -c`: the shell follows -exec anywhere in the clause
        for pos, w in enumerate(words):
            if w in ("-exec", "-execdir", "-ok") and pos + 1 < len(words) and _is_shell(words[pos + 1]) \
                    and _has_c_option(words[pos + 2:]):
                return words[pos + 1].rsplit("/", 1)[-1]
    return None


def refusal(command):
    """The refusal text for `command`, or None to let it through. Never raises."""
    try:
        shell = verdict(command)
    except Exception:
        return None
    return MESSAGE.format(shell=shell) if shell else None


def main(argv):
    try:
        payload = json.loads(sys.stdin.read())
        command = payload.get("tool_input", {}).get("command", "")
        if payload.get("tool_name") != "Bash" or not isinstance(command, str):
            return 0
    except Exception:
        return 0
    text = refusal(command)
    if text:
        sys.stderr.write(text + "\n(hook: scripts/hooks/guard-no-shell-c.sh)\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
