#!/usr/bin/env python3
#
# scripts/lib/interactive-prompt.py — CAN THIS COMMAND STOP AND WAIT FOR A HUMAN?
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-01 at 02:01 a macOS password window appeared on the CEO's screen.
# An agent had run, in the course of a signing repro:
#
#     security import D.p12 -k <scratch>/t3.keychain-db -T /usr/bin/codesign
#
# with no -P. A MISSING passphrase is not an empty passphrase: macOS escalates
# to SecurityAgent, which draws a window on the logged-in user's screen, and the
# calling process blocks on it forever. PID 70803, killed by hand.
#
# The engine had, at that moment, forty-one registered guards. Every one of them
# inspects TEXT AND STATE — files, commit contents, agent names, spawn prompts,
# worktree locks, dialect, secrets. NOT ONE ASKED WHETHER A COMMAND CAN WAIT ON
# A HUMAN. With shell commands executing without per-call approval, nothing at
# all sat between that command and his screen.
#
# This file is the missing question. It is a pure text analyzer: given a shell
# command, it returns the ways that command can stop and wait for a person, and
# for each one it NAMES THE FLAG that makes the command fail instead of wait.
#
# ===========================================================================
# THE REFUSAL MUST NAME THE FIX, OR IT WILL BE WORKED AROUND
# ===========================================================================
# Every finding carries a `fix`. This is not politeness. A guard that says "no"
# without saying "say it this way instead" is a guard whose only available
# response on a bad day is to be waived, and habitual waiving is how a defense
# decays into a formality. `-P ''`, `-n`, `-o BatchMode=yes`, `--no-edit`: in
# every blocking shape here the fix is one token, it keeps the command working,
# and it is what the author wanted in the first place.
#
# There is deliberately NO waiver line, no ack marker and no escape hatch on the
# blocking tier. An escape hatch is only needed where a guard can be WRONG in a
# way the author cannot route around, and that case does not arise here: adding
# the named flag is always available and always correct for an agent.
#
# ===========================================================================
# TWO TIERS, AND THE LINE BETWEEN THEM IS NOT "HOW SURE AM I"
# ===========================================================================
#   block   — the shape has NO legitimate non-interactive use. Nothing an agent
#             could have meant by it is better expressed this way. `sudo` with
#             no -n, `ssh` with no BatchMode, an osascript dialog, `crontab -e`,
#             `vim`: each is a command whose entire purpose is to involve a
#             person, or which asks for a secret it was never given.
#
#   report  — the hazard is real but depends on STATE THIS FILE CANNOT SEE.
#             Is the PEM encrypted? Is the keychain unlocked and partitioned? Is
#             stdin a pipe carrying the keystrokes? Is $EDITOR a terminal editor
#             that fails in a second or a window that waits all night? A shape
#             whose answer lives outside the command string is reported with its
#             fix named, and the command runs.
#
# The tier is a property of the SHAPE, not of the author's confidence. Moving a
# shape from report to block is a claim that it can never be right, and that
# claim is measurable — see the corpus record below.
#
# ===========================================================================
# MEASURED, ON REAL TRANSCRIPTS, BEFORE ANY RATE WAS CLAIMED
# ===========================================================================
# Corpus: every distinct Bash command in every Claude Code transcript on this
# machine — 1,762 session files, 65,781 unique commands, spanning femcboost,
# richos, prospects, the LinkedIn extension and the scratchpad sessions.
# Regenerate it and re-measure with scripts/hooks/interactive-prompt.corpus.md.
#
#   blocking tier   4 / 65,781   (0.006%) — all `security import` with no -P
#   report tier     5 / 65,781   (0.008%) — all `git add -p` fed from a pipe
#
# The four blocking hits are the honest cost of this guard and they are stated
# rather than rounded away: all four import material that is almost certainly
# unencrypted (a .cer, a -nocrypt .p8, an -f openssl PEM), so all four would
# probably not have prompted. The exemption that would clear them — trust
# `-f openssl` / `-f pkcs8` — was REJECTED, because a PEM can be encrypted and
# the false negative it buys is the incident itself. None of the four is broken
# by complying: `-P ''` is correct and harmless for unencrypted material.
#
# Four shapes were tried and CUT because measuring them showed they were wrong:
# `git merge` / `git cherry-pick` / `git revert` / `git pull` without --no-edit
# produced 14 findings and every one was false. Git only opens the merge editor
# when stdin is a terminal, which it never is here — measured directly, not
# assumed: `git merge --no-ff side </dev/null` with GIT_EDITOR set to a tripwire
# completed the merge and never invoked it. `git commit` with no message flag,
# under the identical experiment, DID invoke the editor, which is why that shape
# survived (at report tier, because what happens next depends on $EDITOR).
#
# ===========================================================================
# WHAT THIS CANNOT SEE — say it here, not in a postmortem
# ===========================================================================
# This is shell-TEXT analysis, the same acknowledged limit guard-bash-main-
# writes.sh carries, and the boundary matters more here because the hazard is
# worse:
#
#   * IT DOES NOT LOOK INSIDE SCRIPTS. `bash app/scripts/install-signing-cert.sh`
#     is one token to this file. That script contains `security import`. So a
#     prompting command reached through a script file is NOT covered, and saying
#     so plainly is the point of this paragraph.
#   * It does not see through command substitution that builds a command name,
#     or through a flag supplied in a variable: `security import "$F" $FLAGS`
#     has no visible -P and is refused, correctly but bluntly.
#   * It cannot know what an interpreter will do. `python3 tool.py` may shell out
#     to anything.
#
# The scope is what an agent types. That is where the 02:01 command came from.
#
# Safe to import (analyze / worst are the API) and safe to run:
#     interactive-prompt.py                  read a hook payload on stdin
#     interactive-prompt.py --command "..."  judge one command
#     interactive-prompt.py --corpus f.jsonl measure against a corpus

import json
import re
import sys

MASK = "\x00"

_HEREDOC_OPEN = re.compile(r"<<(-?)\s*(?![<])(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
_FUNCDEF = re.compile(r"(?:\bfunction\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*\(\s*\)")


def strip_heredocs(cmd):
    """Drop heredoc BODIES. They are data, not commands.

    This is the single most important false-positive control in the file. The
    dominant shape in real agent transcripts is `cat > file <<'EOF' ... EOF`
    carrying a shell script, a document or a commit message. Before this,
    matching `sudo` as plain text found six hits in the corpus and every one was
    prose inside a heredoc — including the very row in RICH-TODOs.md that
    describes this defect. `<<<` is a here-STRING, not a heredoc, and is
    excluded by the negative lookahead.
    """
    lines = cmd.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = [(m.group(3), m.group(1) == "-") for m in _HEREDOC_OPEN.finditer(line)]
        i += 1
        for delim, dash in delims:
            while i < len(lines):
                body = lines[i]
                i += 1
                if (body.strip() if dash else body.rstrip()) == delim or body.strip() == delim:
                    break
    return "\n".join(out)


def _scan(cmd):
    """One pass producing TWO VIEWS at identical offsets.

    masked    — quoted content replaced byte-for-byte with a filler. Nothing a
                human typed inside quotes can TRIGGER a match, so `grep "sudo"`
                and `echo "security import x"` are not commands.
    unquoted  — quote characters removed, content kept. So an EXEMPTION written
                as `-o "BatchMode=yes"` still counts.

    The asymmetry is deliberate and it is conservative in both directions:
    positive triggers are read from `masked` (quoted text cannot accuse), and
    exemptions are read from `unquoted` (quoted text can still excuse).
    """
    masked, unquoted = [], []
    i, n, state = 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if state is None:
            if c == "\\" and i + 1 < n:
                masked.append(" ")
                unquoted.append(" " if cmd[i + 1] == "\n" else cmd[i + 1])
                masked.append(" ")
                unquoted.append(" ")
                i += 2
                continue
            if c in "'\"":
                state = c
                masked.append(c)
                unquoted.append(" ")
                i += 1
                continue
            if c == "#" and (not masked or masked[-1] in " \t\n;&|(){}"):
                while i < n and cmd[i] != "\n":
                    masked.append(" ")
                    unquoted.append(" ")
                    i += 1
                continue
            masked.append(c)
            unquoted.append(c)
            i += 1
            continue
        if c == "\\" and state == '"' and i + 1 < n:
            masked.append(MASK)
            unquoted.append(" ")
            masked.append(MASK)
            unquoted.append(cmd[i + 1])
            i += 2
            continue
        if c == state:
            state = None
            masked.append(c)
            unquoted.append(" ")
            i += 1
            continue
        masked.append(MASK)
        unquoted.append(c)
        i += 1
    return "".join(masked), "".join(unquoted)


# Control operators AND subshell/command-substitution openers: `$(sudo x)` and
# `(sudo x)` start a command just as surely as `; sudo x` does.
_SEP = re.compile(r"(?:\|\||&&|[;&|\n(){}`]|\$\()")


def clauses(cmd):
    """Split into command clauses, returning (masked, unquoted) at equal spans."""
    masked, unquoted = _scan(cmd)
    # Blank out function-definition headers BEFORE splitting. Splitting on `(`
    # otherwise ends a clause with the bare word `ed`, and `ed` is an editor:
    # `ed() { python3 -c ...; }` produced 40 false positives in the corpus, all
    # of them one engineer's helper function.
    for m in _FUNCDEF.finditer(masked):
        a, b = m.span()
        masked = masked[:a] + " " * (b - a) + masked[b:]
        unquoted = unquoted[:a] + " " * (b - a) + unquoted[b:]
    cuts = [0]
    for m in _SEP.finditer(masked):
        cuts.append(m.start())
        cuts.append(m.end())
    cuts.append(len(masked))
    out = []
    for a, b in zip(cuts[::2], cuts[1::2]):
        if masked[a:b].strip(" \t\n" + MASK):
            out.append((masked[a:b], unquoted[a:b]))
    return out


_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Transparent wrappers: what follows them is still the command.
WRAPPERS = {"time", "command", "builtin", "exec", "nohup", "nice", "ionice", "stdbuf",
            "caffeinate", "script", "eval", "then", "do", "else", "elif", "if", "while",
            "until", "!"}
WRAPPERS_WITH_ARG = {"timeout", "xargs", "env"}


def head_of(tokens):
    """(index, basename) of the real command word, past assignments and wrappers.

    A token containing masked bytes is a quoted or generated command name: this
    file will not guess at it, and returns nothing rather than matching on the
    filler.
    """
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if not t or MASK in t:
            return None, None
        if _ASSIGN.match(t):
            i += 1
            continue
        base = t.rsplit("/", 1)[-1]
        if base in WRAPPERS:
            i += 1
            continue
        if base in WRAPPERS_WITH_ARG:
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or _ASSIGN.match(tokens[i])
                                       or re.match(r"^[0-9]+(\.[0-9]+)?[smhd]?$", tokens[i])):
                i += 1
            continue
        return i, base
    return None, None


def _tok(s):
    return [t for t in s.split() if t]


def _sub(tokens, idx, depth=1):
    """The depth-th non-flag word after tokens[idx] — the subcommand."""
    seen = 0
    for t in tokens[idx + 1:]:
        if t.startswith("-"):
            continue
        seen += 1
        if seen == depth:
            return t
    return ""


def _short(tokens, letters):
    """True when a token is a short-flag bundle containing one of `letters`.

    Bundle-aware on purpose: `-qm` carries m, and `git commit -qm 'x'` is a
    commit WITH a message. Reading only `-m` would have called it messageless.
    """
    for t in tokens:
        if len(t) > 1 and t[0] == "-" and t[1] != "-":
            head = re.match(r"^[A-Za-z]*", t.split("=", 1)[0][1:]).group(0)
            if any(l in head for l in letters):
                return True
    return False


def _long(tokens, *names):
    for t in tokens:
        if t.split("=", 1)[0] in names:
            return True
    return False


_GIT_GLOBAL_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                        "--exec-path", "--super-prefix", "--config-env"}


def git_sub(tokens, i):
    """git's subcommand and its index, past the global options.

    `-C <path>` swallows its path, so `git -C /repo commit --amend` is a commit
    and not a repository named /repo. Reading the first bare word instead made
    every `git -C ... commit` and every `git -c commit.gpgsign=false commit`
    invisible to this file — which is most of them, in this repository.
    """
    j = i + 1
    while j < len(tokens):
        t = tokens[j]
        if t.startswith("-"):
            j += 2 if (t.split("=", 1)[0] in _GIT_GLOBAL_WITH_ARG and "=" not in t) else 1
            continue
        return t, j
    return "", len(tokens)


def analyze(cmd):
    """Every way this command can stop and wait for a human. Order is stable."""
    findings = []
    for masked, unq in clauses(strip_heredocs(cmd)):
        mt, ut = _tok(masked), _tok(unq)
        if not mt:
            continue
        idx = 0
        while True:
            i, base = head_of(mt[idx:])
            if i is None:
                break
            i += idx
            if base != "sudo":
                findings.extend(check(base, mt, ut, i))
                break
            # sudo is BOTH a shape and a wrapper: judge it, then keep walking so
            # `sudo -n security import x` is still read as a security import.
            own = []
            j = i + 1
            while j < len(mt) and mt[j].startswith("-"):
                own.append(mt[j])
                j += 1
            if not (_short(own, "n") or _long(own, "--non-interactive")):
                findings.append(dict(
                    shape="sudo", severity="block", token="sudo",
                    fix="add -n (--non-interactive)",
                    why="without -n, sudo asks a human for a password; with no terminal "
                        "macOS can escalate that to a window and this process waits forever"))
            idx = j
            if idx >= len(mt):
                break
    return findings


def check(base, mt, ut, i):
    """One clause, one command. mt = masked tokens, ut = unquoted tokens."""
    out = []
    sub = _sub(mt, i)
    sub2 = _sub(mt, i, 2)
    unq_joined = " ".join(ut)

    def add(shape, fix, why, severity="block"):
        out.append(dict(shape=shape, severity=severity, token=base, fix=fix, why=why))

    # --- THE MEASURED ONE --------------------------------------------------
    if base == "security":
        if sub == "import" and not _short(ut, "P"):
            add("security-import",
                "add -P '<passphrase>' — use -P '' when the material has none",
                "a MISSING passphrase is not an empty one. macOS escalates to "
                "SecurityAgent, which draws a window on the logged-in user's screen and "
                "blocks this process forever. Measured 2026-09-01 02:01, PID 70803.")
        elif sub in ("unlock-keychain", "create-keychain") and not _short(ut, "p"):
            add("security-keychain-password", "add -p '<password>'",
                "without -p the keychain password is read from a human")
        elif sub == "set-key-partition-list" and not _short(ut, "k"):
            add("security-partition-list", "add -k '<keychain-password>'",
                "without -k this draws the keychain-unlock window")
        elif sub in ("add-generic-password", "add-internet-password") and not _short(ut, "w"):
            add("security-add-password", "add -w '<secret>'",
                "without -w the secret is read from a human")

    elif base in ("ssh", "scp", "sftp"):
        if not re.search(r"(?i)batchmode\s*=\s*yes", unq_joined):
            add("ssh-batchmode", "add -o BatchMode=yes",
                "without BatchMode, host-key confirmation and password or passphrase "
                "prompts wait on a human; on macOS an askpass helper can draw a window")

    elif base == "ssh-add":
        if not (_short(mt[i:], "lLDdek") or _long(mt[i:], "--delete-all")):
            add("ssh-add",
                "export SSH_ASKPASS_REQUIRE=never SSH_ASKPASS=/usr/bin/false, or use a "
                "key already loaded in the agent",
                "adding a passphrase-protected key prompts, and on macOS that prompt is "
                "a window")

    elif base == "osascript":
        # The script text is nearly always quoted, so this one shape reads the
        # UNQUOTED view for its trigger. Stated here because it is the single
        # exception to the masked-triggers rule, and an unstated exception is
        # how a rule stops being one.
        if re.search(r"(?i)(display\s+dialog|display\s+alert|choose\s+(file|folder|from\s+list"
                     r"|application|URL|color)|with\s+administrator\s+privileges)", unq_joined):
            add("osascript-dialog",
                "use `display notification` (which does not wait), or `do shell script` "
                "WITHOUT `with administrator privileges`",
                "this AppleScript draws a window on the logged-in user's screen and blocks "
                "until somebody clicks it")

    elif base == "git":
        sub, gj = git_sub(mt, i)
        sub2 = _sub(mt, gj)
        rest_m, rest_u = mt[gj:], ut[gj:]
        if sub == "commit":
            if not (_short(rest_u, "mFC")
                    or _long(rest_u, "--message", "--file", "--no-edit", "--reuse-message",
                             "--reedit-message", "--fixup", "--squash", "--template")):
                add("editor-wait", "add -m '<message>' or -F - (or --no-edit on an amend)",
                    "git opens $EDITOR and waits — measured, and NOT suppressed by the "
                    "absence of a terminal the way `git merge` is. Reported rather than "
                    "blocked because what happens next depends on $EDITOR: a terminal "
                    "editor fails in a second, a windowed one waits all night.",
                    severity="report")
        elif sub == "rebase" and (_short(rest_m, "i") or _long(rest_m, "--interactive")):
            add("editor-wait", "drop -i, or set GIT_SEQUENCE_EDITOR=true",
                "an interactive rebase opens $EDITOR and waits for a human")
        elif sub == "add" and (_short(rest_m, "ip") or _long(rest_m, "--interactive", "--patch")):
            add("editor-wait", "stage explicit pathspecs instead of -i / -p",
                "interactive staging reads keystrokes; reported rather than blocked "
                "because the keystrokes are sometimes piped in, which is every one of "
                "the five corpus hits", severity="report")
        elif sub in ("citool", "gui", "mergetool", "difftool"):
            add("gui-wait", "use the non-interactive plumbing instead",
                "this opens a window and waits for a human to close it")
        elif sub == "tag" and _short(rest_m, "as") and not (
                _short(rest_u, "mF") or _long(rest_u, "--message", "--file")):
            add("editor-wait", "add -m '<message>'",
                "an annotated tag with no message opens $EDITOR", severity="report")
        elif sub == "config" and _long(rest_m, "--edit", "-e"):
            add("editor-wait", "use `git config <key> <value>`",
                "git config --edit opens $EDITOR and waits")

    elif base == "crontab":
        if _short(mt[i:], "e"):
            add("editor-wait", "pipe a file in: `crontab <file>`",
                "crontab -e opens $EDITOR and waits")

    elif base in ("vi", "vim", "nvim", "nano", "pico", "emacs", "vipw", "visudo", "htop"):
        add("interactive-program",
            "use a non-interactive tool: sed or python for edits, `ps` for processes",
            "this program takes over the terminal and never returns on its own")

    elif base == "top":
        if not _short(mt[i:], "l"):
            add("interactive-program", "add -l 1 (one sample, then exit)",
                "bare `top` never returns on its own")

    elif base == "open":
        if _short(mt[i:], "W") or _long(mt[i:], "--wait-apps"):
            add("open-wait", "drop -W / --wait-apps",
                "`open -W` blocks until a human quits the launched application")

    # --- INTERACTIVE AUTH FLOWS -------------------------------------------
    elif base == "gh" and sub == "auth" and sub2 == "login":
        if not _long(ut[i:], "--with-token"):
            add("auth-flow", "use --with-token and pipe the token in",
                "gh auth login runs a browser or terminal flow that waits on a human")

    elif base == "npm" and sub in ("login", "adduser"):
        add("auth-flow", "set //<registry>/:_authToken in .npmrc instead",
            "npm login prompts for a username, a password and a one-time code")

    elif base in ("docker", "podman") and sub == "login":
        if not _long(ut[i:], "--password-stdin"):
            add("auth-flow", "add --password-stdin and pipe the secret in",
                "docker login prompts for a password")

    elif base in ("heroku", "railway", "vercel", "netlify", "fly", "flyctl", "supabase",
                  "wrangler", "expo", "eas", "firebase", "convex", "turso", "doctl") \
            and sub == "login":
        add("auth-flow", "use this tool's token environment variable instead",
            "an interactive login flow waits on a human, usually in a browser")

    elif base == "aws" and sub == "configure" and sub2 not in ("set", "get", "list", "import"):
        add("auth-flow", "use `aws configure set <key> <value>`, or environment variables",
            "bare `aws configure` prompts for four values in turn")

    elif base == "gcloud" and sub == "auth" and sub2 == "login":
        add("auth-flow", "use `gcloud auth activate-service-account --key-file`",
            "gcloud auth login opens a browser and waits")

    elif base == "az" and sub == "login":
        if not _long(ut[i:], "--service-principal", "--identity"):
            add("auth-flow", "use --service-principal with --password, or --identity",
                "az login opens a browser and waits")

    elif base in ("apt", "apt-get", "yum", "dnf", "zypper") and sub in (
            "install", "remove", "upgrade", "dist-upgrade", "purge", "autoremove"):
        if not (_short(ut[i:], "y") or _long(ut[i:], "--yes", "--assumeyes")):
            add("confirm-prompt", "add -y",
                "the package manager asks a human for confirmation")

    elif base == "ssh-keygen":
        if _short(mt[i:], "tb") and not _short(ut[i:], "N"):
            add("passphrase-prompt", "add -N '' for no passphrase, or -N '<passphrase>'",
                "ssh-keygen prompts twice for a passphrase")
        elif _short(mt[i:], "p") and not _short(ut[i:], "N"):
            add("passphrase-prompt", "add -P '<old>' -N '<new>'",
                "changing a passphrase prompts for the old one and the new one")

    elif base == "xcrun" and sub == "notarytool" and sub2 == "store-credentials":
        if not _long(ut[i:], "--password"):
            add("passphrase-prompt", "add --password '<app-specific-password>'",
                "store-credentials prompts for the Apple ID password")

    # --- REPORT TIER: the answer lives outside the command string ----------
    elif base == "codesign":
        rest = mt[i:]
        signing = any(t in ("-s", "--sign") for t in rest)
        adhoc = any(t in ("-s", "--sign") and k + 1 < len(rest) and rest[k + 1] == "-"
                    for k, t in enumerate(rest))
        if signing and not adhoc:
            add("keychain-acl",
                "unlock the keychain and run `security set-key-partition-list -S "
                "apple-tool:,apple: -s -k '<pw>' <keychain>` first, or sign ad-hoc with "
                "`--sign -`",
                "signing with a real identity draws the 'wants to sign using key' window "
                "unless the keychain is already unlocked and partitioned — which this "
                "file cannot see", severity="report")

    elif base == "openssl":
        r, ru = mt[i:], ut[i:]
        nopass = any(t.split("=", 1)[0] in ("-nodes", "-noenc", "-nocrypt") for t in ru) \
            or any(t.startswith("-pass") for t in ru)
        if sub == "req" and _long(r, "-newkey", "-keyout") and not nopass:
            add("passphrase-prompt", "add -nodes (or -passout pass:'<x>')",
                "openssl req generating a key prompts for a PEM pass phrase",
                severity="report")
        elif sub == "pkcs12" and _long(r, "-export") and not nopass:
            add("passphrase-prompt", "add -passout pass:'<x>'",
                "openssl pkcs12 -export prompts for an export password", severity="report")
        elif sub in ("genrsa", "genpkey") and any(
                t.startswith(("-aes", "-des", "-camellia")) for t in r) and not nopass:
            add("passphrase-prompt", "add -pass pass:'<x>'",
                "encrypting the generated key prompts for a pass phrase", severity="report")

    return out


def worst(findings):
    if any(f["severity"] == "block" for f in findings):
        return "block"
    return "report" if findings else "clean"


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--corpus":
        import collections
        counts, examples, total = collections.Counter(), collections.defaultdict(list), 0
        with open(argv[1]) as fh:
            for line in fh:
                cmd = json.loads(line)
                total += 1
                for fnd in analyze(cmd):
                    key = (fnd["severity"], fnd["shape"])
                    counts[key] += 1
                    if len(examples[key]) < 30:
                        examples[key].append(cmd)
        print("corpus: %d unique commands" % total)
        for (sev, shape), n in sorted(counts.items(), key=lambda kv: -kv[1]):
            print("\n=== [%s] %s: %d  (%.4f%%)" % (sev, shape, n, 100.0 * n / max(total, 1)))
            for e in examples[(sev, shape)]:
                print("   |", e.replace("\n", " \\n ")[:220])
        return 0
    if argv and argv[0] == "--command":
        f = analyze(argv[1])
        print(json.dumps({"verdict": worst(f), "findings": f}, indent=2))
        return 0
    try:
        d = json.loads(sys.stdin.read() or "{}")
    except Exception:
        # An unparsed payload is not permission to guess. The hook's own
        # fail-closed contract decides; this file only ever reports what it saw.
        print(json.dumps({"verdict": "clean", "findings": [], "parse": "failed"}))
        return 0
    if d.get("tool_name") != "Bash":
        print(json.dumps({"verdict": "clean", "findings": []}))
        return 0
    f = analyze((d.get("tool_input") or {}).get("command", "") or "")
    print(json.dumps({"verdict": worst(f), "findings": f}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
