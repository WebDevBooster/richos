#!/usr/bin/env python3
"""unguarded_rm.py: refuse, BEFORE Claude Code asks the CEO, the rm shapes that Claude Code's own
critical-path circuit breaker turns into a Yes/No prompt even in bypassPermissions mode.

The CEO, 2026-10-02, bypass permissions on, was stopped by: "Dangerous rm operation on possibly-empty
variable path: $D/*.jsonl in `rm -f $D/*.jsonl` (rewrite it as "${D:?}"/*.jsonl or use a literal path)".
That prompt is Claude Code's, not ours (docs: code.claude.com/docs/en/permission-modes, "Critical
paths"): "rm and rmdir removals targeting a critical path ... no allow rule or PreToolUse hook "allow"
approves", and in bypassPermissions mode it "Asks you to approve it, with a time limit". A PreToolUse
hook that DENIES runs before that prompt, so the agent gets the reason and rewrites; he never sees it.

What this refuses (rm and rmdir, anywhere in the command: after && ; | & newline, in ( ), { }, $( ),
backticks, sh -c / bash -c scripts, xargs, find -exec):
  1. a path argument that STARTS with an unguarded variable: $D/x, ${D}/x, "$D"/x, "$D/x", $1, $@
     (the docs' trigger is a glob or trailing slash directly under a variable, or a variable followed
     by a top-level directory name; refusing every variable-first path is the stricter, simpler
     superset). Guarded `${D:?}` and `${D:?message}` pass; so do literal paths.
  2. a variable the SAME command assigns from `$(pwd)`, `` `pwd` `` or `$(git rev-parse
     --show-toplevel)`, even guarded (a ${D:?} guard does not clear it: use a literal path)
  3. a recursive rm whose target is only a command substitution: rm -rf "$(pwd)"
  4. a trailing command substitution after a critical path: rm -rf ~/$(cmd)
  5. a literal critical path: the filesystem root, a top-level directory (/usr, /tmp), the home folder,
     the working directory or one of its parents, and /* or ~/*
and `find <variable root> ... -delete` / `-exec rm` with an unguarded variable root.

IT IS A TEXT MATCH AND LEAKS (a script that runs rm, eval, a variable holding a command). Its job is to
stop the habitual command, not an adversary. Any error in the check is a pass.
"""
import json
import os
import re
import sys

_WS = " \t"
_REDIR = re.compile(r"^(\d*[<>]|&>|>&|<&|>\|)")
_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_KEYWORDS = {"if", "then", "do", "else", "elif", "while", "until", "!", "{", "time", "exec",
             "command", "builtin", "nohup", "sudo", "env", "nice", "xargs", "stdbuf"}
_OPTS_WITH_ARG = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T"},
    "nice": {"-n"},
    "xargs": {"-n", "-I", "-P", "-L", "-d", "-s", "-E", "-a"},
    "env": {"-u", "-C", "-S"},
}
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
_DIR_ASSIGN = re.compile(
    r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=[\"']?"
    r"(\$\(\s*pwd\s*\)|`\s*pwd\s*`|\$\(\s*git\s+rev-parse\s+--show-toplevel\s*\))")
_VAR = re.compile(r"^\$(?:\{(?P<br>[^}]*)\}|(?P<name>[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]))")


def _match_paren(s, i):
    """s[i:i+2] == '$(' (or '<(' / '>('): index just past the matching ')'."""
    depth = 0
    j = i + 1
    n = len(s)
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = s.find("'", j + 1)
            j = n if k < 0 else k + 1
            continue
        if c == '"':
            j += 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            j += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def tokenize(text):
    """-> (commands, nested). commands: list of lists of RAW words (quotes kept). nested: bodies of
    $(...), backticks and <(...) found anywhere, to be analyzed as commands of their own."""
    cmds, nested = [], []
    words, cur = [], []
    heredocs = []
    i, n = 0, len(text)

    def flush():
        if cur:
            words.append("".join(cur))
            del cur[:]

    def end_cmd():
        flush()
        if words:
            cmds.append(list(words))
            del words[:]

    while i < n:
        c = text[i]
        if c in _WS:
            flush()
            i += 1
        elif c == "\n":
            end_cmd()
            i += 1
            for delim, dash in heredocs:
                while i < n:
                    j = text.find("\n", i)
                    line = text[i:] if j < 0 else text[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if dash else line) == delim:
                        break
            heredocs = []
        elif c == "#" and not cur:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "\\":
            if i + 1 < n and text[i + 1] == "\n":
                i += 2
            else:
                cur.append(text[i:i + 2])
                i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            j = n if j < 0 else j + 1
            cur.append(text[i:j])
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 2
                elif text.startswith("$(", j):
                    k = _match_paren(text, j)
                    nested.append(text[j + 2:k - 1])
                    j = k
                elif text[j] == "`":
                    k = text.find("`", j + 1)
                    k = n - 1 if k < 0 else k
                    nested.append(text[j + 1:k])
                    j = k + 1
                else:
                    j += 1
            j = min(j + 1, n)
            cur.append(text[i:j])
            i = j
        elif text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            k = _match_paren(text, i)
            nested.append(text[i + 2:k - 1])
            cur.append(text[i:k])
            i = k
        elif c == "`":
            k = text.find("`", i + 1)
            k = n - 1 if k < 0 else k
            nested.append(text[i + 1:k])
            cur.append(text[i:k + 1])
            i = k + 1
        elif text.startswith("<<<", i):
            cur.append("<<<")
            i += 3
        elif text.startswith("<<", i):
            flush()
            words.append("<<")
            i += 2
            dash = False
            if i < n and text[i] == "-":
                dash = True
                i += 1
            while i < n and text[i] in _WS:
                i += 1
            j = i
            while j < n and text[j] not in " \t\n;|&()<>":
                j += 1
            delim = text[i:j].strip("'\"\\")
            heredocs.append((delim, dash))
            i = j
        elif c in ";|":
            end_cmd()
            i += 1
            while i < n and text[i] in ";|&":
                i += 1
        elif c == "&":
            if cur and cur[-1][-1:] in "<>":
                cur.append("&")
            elif i + 1 < n and text[i + 1] == ">":
                cur.append("&")
            else:
                end_cmd()
                while i + 1 < n and text[i + 1] == "&":
                    i += 1
            i += 1
        elif c in "()":
            end_cmd()
            i += 1
        else:
            cur.append(c)
            i += 1
    end_cmd()
    return cmds, nested


def _unquote_word(w):
    out = re.sub(r"\\(.)", r"\1", w)
    return out.replace('"', "").replace("'", "")


def _var_info(raw):
    """If the word starts with a variable expansion, -> (name, guarded, rest, quoted) else None.
    `rest` is what follows the variable token, quotes untouched."""
    quoted = raw.startswith('"')
    body = raw[1:] if quoted else raw
    m = _VAR.match(body)
    if not m:
        return None
    rest = body[m.end():]
    if m.group("br") is not None:
        inner = m.group("br")
        nm = re.match(r"[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]", inner)
        name = nm.group(0) if nm else inner
        guarded = bool(nm) and inner[nm.end():].startswith(":?")
    else:
        name = m.group("name")
        guarded = False
    return name, guarded, rest, quoted


def _rewrite(name, rest, quoted):
    if quoted:
        return '"${%s:?}%s' % (name, rest)
    return '"${%s:?}"%s' % (name, rest)


def _critical_set(cwd, home):
    crit = {"/"}
    try:
        for entry in os.listdir("/"):
            crit.add("/" + entry)
    except OSError:
        pass
    if home:
        crit.add(os.path.normpath(home))
    if cwd:
        p = os.path.normpath(cwd)
        while True:
            crit.add(p)
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent
    return crit


def _literal_critical(raw, crit, cwd, home):
    """The raw word names a critical path literally (no variable) -> the path, else None."""
    if raw.startswith("'"):
        w = raw[1:-1] if raw.endswith("'") else raw[1:]
    else:
        w = _unquote_word(raw)
    if "$" in w or "`" in w:
        return None
    if w in ("/*", "~/*"):
        return w
    glob = False
    if w.endswith("/*"):
        glob = True
        w = w[:-2] or "/"
    if w == "~" or w.startswith("~/"):
        if home:
            w = os.path.normpath(home + w[1:])
    if not w.startswith("/"):
        if not cwd:
            return None
        w = os.path.normpath(os.path.join(cwd, w))
    else:
        w = os.path.normpath(w)
    if glob:
        # docs: only a glob under the root or the home folder is named; other critical dirs are
        # critical as themselves
        return (w + "/*") if w in ("/", os.path.normpath(home or "/nonexistent")) else None
    return w if w in crit else None


class _Ctx:
    def __init__(self, cwd, home, dir_vars):
        self.cwd, self.home, self.dir_vars = cwd, home, dir_vars
        self.crit = _critical_set(cwd, home)
        self.findings = []


def _strip_prefix(words):
    """Drop env assignments, keywords and wrappers; -> (cmdname, args, wrapper_seen_xargs)."""
    i = 0
    xargs = False
    while i < len(words):
        w = words[i]
        if _ENV_ASSIGN.match(w):
            i += 1
            continue
        base = _unquote_word(w)
        if base in _KEYWORDS:
            if base == "xargs":
                xargs = True
            i += 1
            while i < len(words) and words[i].startswith("-") and base in _OPTS_WITH_ARG:
                skip = words[i] in _OPTS_WITH_ARG[base]
                i += 2 if skip else 1
            while base == "env" and i < len(words) and _ENV_ASSIGN.match(words[i]):
                i += 1
            continue
        break
    if i >= len(words):
        return None, [], xargs
    return os.path.basename(_unquote_word(words[i])), words[i + 1:], xargs


def _positional_bound(vname, words):
    """True when `sh -c` was handed `words` words after its script and they supply $vname.

    The first word is $0, so $n needs n + 1 words; $@ and $* need at least one real argument."""
    if vname.isdigit():
        return int(vname) < words
    if vname in ("@", "*"):
        return words >= 2
    return False


def _scan_rm(name, args, ctx, bound_positional):
    recursive = False
    targets = []
    end_opts = False
    skip_next = False
    for w in args:
        if skip_next:
            skip_next = False
            continue
        if _REDIR.match(w):
            if re.fullmatch(r"\d*[<>]+&?|&>|>\||\d*>&|\d*<&", w):
                skip_next = True
            continue
        if not end_opts and w == "--":
            end_opts = True
            continue
        if not end_opts and w.startswith("-") and len(w) > 1:
            if w == "--recursive" or re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", w):
                recursive = True
            continue
        targets.append(w)
    for raw in targets:
        info = _var_info(raw)
        if info:
            vname, guarded, rest, quoted = info
            if _positional_bound(vname, bound_positional):
                continue
            if not guarded:
                ctx.findings.append(
                    "`%s ... %s`: the path starts with the variable $%s, which can be empty. "
                    "Rewrite it as %s (the shell then stops with an error when %s is empty), or use a literal path."
                    % (name, raw, vname, _rewrite(vname, rest, quoted), vname))
                continue
            if vname in ctx.dir_vars:
                ctx.findings.append(
                    "`%s ... %s`: %s is assigned from a directory-printing substitution ($(pwd) or "
                    "$(git rev-parse --show-toplevel)) in the same command, so it can name the working "
                    "directory or repository root; a ${%s:?} guard does not clear that. Use a literal path."
                    % (name, raw, vname, vname))
            continue
        stripped = raw[1:-1] if raw.startswith('"') and raw.endswith('"') and len(raw) > 1 else raw
        if re.fullmatch(r"\$\(.*\)|`[^`]*`", stripped, re.S) and recursive:
            ctx.findings.append(
                "`%s -r ... %s`: the target is only a command substitution, which Claude Code cannot check. "
                "Run the substitution on its own first, then remove the literal paths it prints." % (name, raw))
            continue
        if re.match(r"^\"?(~|/[^/$\"]*)/?\$\(", raw) or re.match(r"^\"?(~|/[^/$\"]*)/?`", raw):
            ctx.findings.append(
                "`%s ... %s`: a command substitution trails a critical path (if it expands empty the "
                "target is that path). Resolve the substitution first and use a literal path." % (name, raw))
            continue
        crit = _literal_critical(raw, ctx.crit, ctx.cwd, ctx.home)
        if crit:
            ctx.findings.append(
                "`%s ... %s` targets the critical path %s (the filesystem root, a top-level directory, the "
                "home folder, the working directory or one of its parents). Claude Code always asks the "
                "operator before removing one. Name the specific child you mean, by a literal path." % (name, raw, crit))


def _scan_find(args, ctx, bound_positional):
    roots = []
    for w in args:
        if w.startswith("-") or w in ("(", "\\(", "!", "\\!"):
            break
        roots.append(w)
    deletes = "-delete" in args
    execs = False
    for idx, w in enumerate(args):
        if w in ("-exec", "-execdir", "-ok", "-okdir"):
            sub = []
            for x in args[idx + 1:]:
                if x in ("\\;", ";", "+", "'+'", '"+"'):
                    break
                sub.append(x)
            if sub and os.path.basename(_unquote_word(sub[0])) in ("rm", "rmdir"):
                execs = True
            _scan_words(sub, ctx, bound_positional)
    if deletes or execs:
        for raw in roots:
            info = _var_info(raw)
            if info and not info[1] and not _positional_bound(info[0], bound_positional):
                vname, _g, rest, quoted = info
                ctx.findings.append(
                    "`find %s ... %s`: the search root starts with the variable $%s, which can be empty "
                    "(find would then run from the current directory). Rewrite it as %s, or use a literal path."
                    % (raw, "-delete" if deletes else "-exec rm", vname, _rewrite(vname, rest, quoted)))


def _scan_words(words, ctx, bound_positional=0):
    name, args, _x = _strip_prefix(words)
    if not name:
        return
    if name in _SHELLS:
        for idx, a in enumerate(args):
            if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", a) and idx + 1 < len(args):
                script = args[idx + 1]
                # Hunt P5-82 (v3): the first word after the script is $0, so `sh -c '...' sh`
                # supplies no $1; this counts the words, $0 included.
                bound = len(args) - (idx + 2)
                if script.startswith("'"):
                    body, sub_bound = script[1:-1], bound
                elif script.startswith('"'):
                    body = script[1:-1].replace('\\"', '"').replace("\\\\", "\\")
                    sub_bound = 0
                else:
                    body, sub_bound = script, 0
                _scan_text(body, ctx, sub_bound)
                break
        return
    if name in ("rm", "rmdir"):
        _scan_rm(name, args, ctx, bound_positional)
    elif name == "find":
        _scan_find(args, ctx, bound_positional)


def _scan_text(text, ctx, bound_positional=0, depth=0):
    if depth > 6:
        return
    cmds, nested = tokenize(text)
    for words in cmds:
        _scan_words(words, ctx, bound_positional)
    for body in nested:
        _scan_text(body, ctx, bound_positional, depth + 1)


def verdict(command, cwd=None, home=None):
    """-> list of refusal reasons (empty when the command passes)."""
    dir_vars = {m.group(1) for m in _DIR_ASSIGN.finditer(command)}
    ctx = _Ctx(cwd, home or os.environ.get("HOME"), dir_vars)
    _scan_text(command, ctx)
    seen, out = set(), []
    for f in ctx.findings:
        if f not in seen:
            seen.add(f)
            out.append(f)
    return out


def check(payload_text):
    """PreToolUse[Bash]: 2 with the refusal on stderr, else 0. Unreadable input passes."""
    try:
        payload = json.loads(payload_text)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in (None, "Bash"):
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not isinstance(command, str) or not re.search(r"\brm(dir)?\b|\bfind\b", command):
        return 0
    try:
        reasons = verdict(command, cwd=payload.get("cwd"))
    except Exception:  # any error in the check is a pass
        return 0
    if not reasons:
        return 0
    sys.stderr.write(
        "REFUSED (guard-unguarded-rm): Claude Code would stop the operator with a Yes/No prompt for this "
        "removal, even with bypass permissions on. Nothing ran. Fix the command and run it again:\n  - %s\n"
        % "\n  - ".join(reasons))
    return 2


def main(argv):
    if argv and argv[0] == "check":
        return check(sys.stdin.read())
    sys.stderr.write("usage: unguarded_rm.py check < payload.json\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
