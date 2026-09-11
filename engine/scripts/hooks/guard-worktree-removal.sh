#!/usr/bin/env bash
#
# guard-worktree-removal.sh — BLOCKING PreToolUse guard on the Bash tool.
# Keeps the workspace spec's two events the only ones:
#
#   "1) spawned/workspace registered 2) landed/workspace to be deleted. What
#    the hell else is there needed to be?"   — docs/plans/worktree-spec-2026-09-11.md
#
# A workspace is CREATED by scripts/create-teammate-worktree.sh, which registers
# it first, and DELETED by scripts/workspaces.sh land|discard (and that
# command's own automatic retry), which stops every process the agent started
# and deletes every workspace and branch it has, together. Nothing else creates
# or deletes one, and codex/ is never touched.
#
# THE CONTRACT (precision over recall — a guard that blocks normal work gets
# disabled, so this fires ONLY on genuine workspace-creating or -destroying ops):
#   REFUSED, with no override (SPEC):
#     - git worktree add               (points 1, 3: a raw workspace is registered
#                                       by nothing, and one not named cc/ is refused)
#     - git worktree prune             (all forms; use worktree list to inspect)
#     - git worktree remove / rm -r of an agent's workspace (cc/, worktree-*,
#       .claude/worktrees/) or of a codex/ one
#     - git branch -d / -D of a cc/, worktree-* or codex/ branch
#     - claude --worktree / -w         (point 3: nobody starts a session in its
#                                       own workspace)
#   BLOCKED unless it carries `worktree-remove-ack:<reason>` (logged to the
#   ENTITY's .claude/state/worktree-remove-acks.log):
#     - git worktree remove / rm -r of a linked worktree that is NOT an agent's
#       (point 1: "only cc/ ones are the system's concern")
#   workspaces.sh passes when the payload carries no separate destructive
#   command. Everything else Bash-related (git worktree list, rm of
#   non-worktree paths, ordinary git/rm) passes untouched.
#
# THREE FALSE POSITIVES THIS VERSION REMOVES, every one of them measured:
#
#   1. `git rm` IS NOT `rm`. The old rule matched `\brm\b`, which fires inside
#      `git rm -r <dir>` — a removal of TRACKED FILES from the index, not a
#      filesystem removal and never a worktree removal. This blocked a
#      legitimate `git rm -r scripts/hooks` during the previous migration step.
#      The verb must now be a bare `rm`, never one preceded by `git`.
#
#   2. `*-wt` IS NOT "a worktree". The old rule treated any path token whose
#      last component ended in `-wt` as a worktree. That is a naming convention
#      of ONE adopter, it fires on every unrelated directory that happens to end
#      that way, and it misses every hand-rolled worktree that does not. The
#      test is now STRUCTURAL: the token must be the TOP LEVEL of a real LINKED
#      git worktree on disk — `git -C <tok> rev-parse --show-toplevel` equals the
#      token AND its `--git-common-dir` lives elsewhere (a main checkout is not a
#      linked worktree and is not what this guard is about). That covers native
#      `.claude/worktrees/agent-*` worktrees AND hand-rolled external-repo ones —
#      including the one from the 2026-08-24 incident, which the naming
#      convention only caught by luck.
#
#   3. PROSE ABOUT A COMMAND IS NOT THE COMMAND. Confirmed live on 2026-09-03
#      and again on 2026-09-04: a `git commit` was refused because its MESSAGE
#      explained why the reconciler stalls on a locked quarantine, quoting the
#      command this guard watches for. Both times it was routed around by
#      rewording, and the guard was left alone -- so as it stood, THE RECORD
#      COULD NOT DESCRIBE THE DEFECT THE ENGINE WAS BEING FIXED FOR.
#
#      A `-m`/`--message` quoted operand and a heredoc payload are now blanked
#      before any rule looks, because nothing in either of them executes. Two
#      exceptions keep the recall exactly where it was: a heredoc fed to a
#      SHELL is still read in full, and `$( ... )` / backtick substitutions
#      survive the blanking wherever the shell would still run them. See
#      "WHAT WILL EXECUTE" in the classifier for the measurement -- 16 hits in
#      83,348 real Bash calls sat in text that was never going to run, and
#      NONE of the 14 heredoc hits were fed to a shell.
#
#      That work also closed a hole it did not create: a substitution NESTED
#      inside another git command's argument run -- `-m "$(git ... )"` -- was
#      swallowed by the outer match and never classified at all. It is now
#      classified, and only inside substitutions, so `git log --grep=...` is
#      still a search rather than a refusal.
#
#   `.claude/worktrees/agent-*` is KEPT as an unconditional structural match
#   alongside the linked-worktree test: that path shape is self-describing, and
#   a residue directory whose registration is already gone is exactly the shape
#   the zombie-residue doctrine says not to reach for casually.
#
# WHY THE SANCTIONED COMMANDS PASS CLEANLY: PreToolUse[Bash] fires on the
# AGENT's top-level Bash tool call only, never on subprocesses a script spawns.
# workspaces.sh and create-teammate-worktree.sh run git internally as
# subprocesses, so their git calls are invisible to this hook; the guard sees
# only the invocation (not destructive-shaped) and allows it.
#
# FAIL-CLOSED on missing python3, matching the sibling PreToolUse[Bash] guard
# (guard-bash-main-writes.sh): an unparsed payload must never wave a worktree
# removal through. (That sibling already blocks all Bash without python3, so
# this adds no new collateral.) A JSON parse error of a PRESENT payload fails
# OPEN to PASS (precision — never block unrelated Bash on a parse glitch),
# again matching the sibling.
#
# NOTE: hooks are snapshotted per session; a change here takes effect from the
# NEXT session.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-worktree-removal.sh: python3 required — refusing (fail-closed)" >&2; exit 2; }

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-worktree-removal.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, three different behaviors —
# see the contract for why "block everything unresolvable" is NOT the rule.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # This repository never adopted the engine, so there is no enforcement to
    # lose here. Stand down. NOT a silent skip: engine-status.sh announces the
    # stand-down into the orchestrator's own context at every session start.
    exit 0
else
    # BROKEN: this guard believes it is governing something and cannot. Block.
    root_failure_banner "scripts/hooks/guard-worktree-removal.sh" >&2
    exit 2
fi
# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# On a payload it cannot read, this guard takes the SAME silent exit 0 that a
# well-formed payload for a DIFFERENT tool takes: the tool-name extraction ends
# in `|| true`, so "this call is not mine" and "I could not tell whose call this
# is" are one exit. That is why 17 of 25 PreToolUse guards were measured passing
# a call in complete silence on 2026-09-05. This separates the two. NO VERDICT
# CHANGES — the exit is the one already taken — only the silence does. The
# measurement, the channel and the argument: scripts/lib/unevaluated-notice.sh.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    unevaluated_or_continue "guard-worktree-removal.sh" "$INPUT" \
        "${ENTITY_ROOT:-${SEAT_ROOT:-${RICHOS_ENTITY_ROOT_RESOLVED:-}}}" \
        "whether this command creates or deletes a workspace outside the workspace spec's own land and discard"
fi

HOOK_TAG="(hook: scripts/hooks/guard-worktree-removal.sh)"

# Detection + classification in one python pass. Prints one of:
#   PASS                     not a Bash tool / not a worktree-creating or -destroying op
#   HELPER                   invokes workspaces.sh and nothing destructive besides
#   SPEC\t<reasons>          creates or deletes what only the spec's events may:
#                            refused, no override
#   ACK\t<reason>            removes a worktree that is not an agent's, and
#                            carries worktree-remove-ack:<reason>
#   BLOCK\t<reasons>         removes a worktree that is not an agent's, no ack
#
# The classifier is assigned to a VARIABLE via a quoted heredoc first, and only
# then handed to `python3 -c "$VAR"`. Embedding it directly inside a `$(...)`
# command substitution is what the sibling guards do, and it breaks HERE: this
# program's regexes contain a `)` inside a character class (`[^;&|)]`), and
# bash 3.2 — the /bin/bash every macOS operator runs — mis-scans that as the
# close of the command substitution even though it sits inside single quotes.
# Measured: `bash -n` reported "syntax error near unexpected token `('" 150
# lines further down, pointing at innocent code. A heredoc assignment is
# scanned once, as text, so the class is impossible.
read -r -d '' _WTR_CLASSIFIER <<'PYEOF' || true
import json, os, re, shlex, subprocess, sys

try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("PASS"); raise SystemExit
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    print("PASS"); raise SystemExit
ti = d.get("tool_input") or {}
cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""

# ===========================================================================
# WHAT WILL EXECUTE, AND WHAT IS ONLY BEING WRITTEN DOWN
# ===========================================================================
# THE FALSE POSITIVE THIS REMOVES, confirmed live twice and measured once.
# On 2026-09-03 and again on 2026-09-04 this guard refused a `git commit` whose
# MESSAGE explained why the reconciler stalls on a locked quarantine -- prose
# that quoted the very command the guard watches for. Both times it was routed
# around by rewording, which costs seconds, and the guard was not touched, which
# costs an engineer. As it stood, THE RECORD COULD NOT DESCRIBE THE DEFECT THE
# ENGINE WAS BEING FIXED FOR.
#
# A COMMAND THAT PERFORMS AN ACT, A COMMIT MESSAGE DESCRIBING ONE, AND A
# DOCUMENT QUOTING ONE ARE THREE DIFFERENT THINGS. The classifier used to scan
# the whole Bash call as one string and could not tell them apart.
#
# So two regions are blanked before anything is matched -- blanked with SPACES,
# never deleted, so every character offset the rules below rely on still points
# where it did:
#
#   1. A `-m` / `--message` QUOTED OPERAND. Nothing inside one ever executes.
#   2. A HEREDOC BODY. It is data on stdin; what the consumer does with it is
#      the consumer's business.
#
# AND TWO EXCEPTIONS KEEP THE RECALL, so this is a narrowing and not a hole:
#
#   * A heredoc fed to a SHELL is still scanned in full. `bash <<EOF` really
#     does execute its body, so the body really is a command.
#   * COMMAND SUBSTITUTIONS SURVIVE THE BLANKING wherever the shell would still
#     run them: `$( ... )` and backticks inside a DOUBLE-quoted message operand,
#     and inside an UNQUOTED-tag heredoc. `git commit -m "$(rm -rf <wt>)"` is a
#     removal wearing a message's clothes, and it is still caught. A
#     single-quoted operand and a `<<'EOF'` heredoc expand nothing, so those are
#     blanked whole.
#
# MEASURED over 83,348 real Bash calls from every transcript on this machine
# (docs/verification/worktree-removal-prose-2026-09-05/): the shipped classifier
# fires on 1,013 of them, and 16 of those hits sit in text that was never going
# to run -- 2 inside a commit message, 14 inside a heredoc payload. ZERO of the
# 14 were fed to a shell. So the recall cost of this change, against the whole
# corpus, is nothing at all, and the two message hits are the two live refusals
# that produced this row.
#
# WHAT THIS DELIBERATELY DOES NOT CLAIM. A python or perl heredoc that builds a
# removal command as a STRING and hands it to a shell is a subprocess, and this
# guard has never been able to see a subprocess -- its own header says so, about
# the sanctioned helper. Blanking that body changes nothing that was ever true.
_SHELL_CONSUMER = re.compile(
    r"(?:^|[|;&]|\s)(?:env\s+\S+\s+)?(?:\S*/)?(?:sh|bash|zsh|ksh|dash)\b")
_HEREDOC_START = re.compile(r"<<-?\s*(?P<q>['\"]?)(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?P=q)")
_SUBST = re.compile(r"\$\([^)]*\)|`[^`]*`")
_MSG_FLAG = re.compile(r"(?:^|\s)(?:-m|--message)(?:=|\s+)(?P<q>['\"])")


def _blank(chars, start, end, keep_substitutions):
    """Space out [start, end), optionally leaving `$( )` / backticks readable."""
    text = "".join(chars[start:end])
    keep = []
    if keep_substitutions:
        keep = [(m.start(), m.end()) for m in _SUBST.finditer(text)]
    for i in range(start, end):
        if chars[i] == "\n":
            continue          # line structure is what the heredoc walk reads
        rel = i - start
        if any(a <= rel < b for a, b in keep):
            continue
        chars[i] = " "


def executable_text(src):
    """The parts of a Bash call the shell will actually run, as a same-length
    string with everything else spaced out."""
    chars = list(src)

    # --- heredoc bodies ----------------------------------------------------
    lines = src.split("\n")
    offs, o = [], 0
    for ln in lines:
        offs.append(o)
        o += len(ln) + 1
    i = 0
    while i < len(lines):
        m = _HEREDOC_START.search(lines[i])
        if m:
            tag = m.group("tag")
            quoted_tag = bool(m.group("q"))
            j = i + 1
            while j < len(lines) and lines[j].strip() != tag:
                j += 1
            body_start = offs[i + 1] if i + 1 < len(lines) else len(src)
            body_end = offs[j] if j < len(lines) else len(src)
            if body_end > body_start and not _SHELL_CONSUMER.search(lines[i][:m.start()]):
                _blank(chars, body_start, body_end,
                       keep_substitutions=not quoted_tag)
            i = j
        i += 1

    # --- -m / --message operands -------------------------------------------
    # Read off the ORIGINAL text, so a message inside a blanked heredoc cannot
    # confuse the scan, and applied to the same character list.
    for m in _MSG_FLAG.finditer(src):
        q = m.group("q")
        start = m.end()
        k = start
        while k < len(src):
            if src[k] == "\\" and q == '"':
                k += 2
                continue
            if src[k] == q:
                break
            k += 1
        _blank(chars, start, min(k, len(src)), keep_substitutions=(q == '"'))

    return "".join(chars)


# EVERY RULE BELOW READS THIS, NEVER `cmd`. Same length, same offsets, so the
# `rm` rule's backward look for a preceding `git` still lands on the right token.
scan = executable_text(cmd)

reasons = []
candidates = []

# --- 1-3) The GIT worktree/branch-destroying ops, decided PER GIT INVOCATION.
#
# THE FALSE POSITIVE THIS REPLACES, measured 2026-09-02 on a pure READ:
#
#     ls -d <path> 2>&1; git branch --list 'worktree-agent-a58289*'
#
# BLOCKED. The three conjuncts of the old branch rule were three INDEPENDENT
# searches over the WHOLE command string: `git ... branch` matched the listing,
# `worktree-\S+` matched its glob, and `-[dD]` matched the `ls -d` -- a
# different verb, in a different clause, that deletes nothing. `git merge-base
# --is-ancestor <branch> main` went the same way whenever anything else on the
# line carried a -d.
#
# Both of those are the VERIFICATION step of a removal. A guard that fires when
# you look at what you just removed is a guard you learn to waive, and a waived
# guard is not a defense, it is a formality. So:
#
#   * the flags of a rule are read from the arguments of the git invocation that
#     OWNS them, never from the rest of the line, and
#   * a git invocation whose subcommand is READ-ONLY can never contribute a
#     reason at all -- `list`, `for-each-ref`, `merge-base`, `rev-list`, `show`,
#     `log`, `status`, `diff` and their kin are enumerated below.
#
# What deliberately did NOT change: a destructive invocation is still caught
# wherever it sits on the line, so a read-only verb in an earlier clause cannot
# launder a `git worktree remove` in a later one. Both halves are pinned by the
# suite (RO*/RD*) and by mutants M5/M6.

# git's own options that CONSUME the next token; skipping them is what lets
# `git -C <repo> worktree remove` find `worktree` as the subcommand.
GIT_GLOBAL_OPTS_WITH_VALUE = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
    "--super-prefix", "--config-env",
}

# Subcommands that CANNOT destroy a worktree or a branch. Enumerated rather than
# inferred: an unknown subcommand is treated as potentially destructive and
# falls through to the specific rules below, which then find nothing. Adding a
# read verb here is safe; adding a write verb is not, and M6 proves it.
GIT_READ_ONLY_SUBCOMMANDS = {
    "annotate", "blame", "cat-file", "cherry", "config", "count-objects",
    "describe", "diff", "for-each-ref", "grep", "help", "log", "ls-files",
    "ls-remote", "ls-tree", "merge-base", "name-rev", "range-diff", "reflog",
    "rev-list", "rev-parse", "shortlog", "show", "show-ref", "status",
    "symbolic-ref", "var", "verify-commit", "verify-tag", "version",
    "whatchanged",
}

# A git invocation and ITS OWN arguments. The leading class admits a statement
# separator, whitespace or a quote (so `bash -c "git worktree remove x"` is
# still seen, exactly as before); the argument run stops at the next separator
# so a later, unrelated command cannot lend this one its flags.
GIT_INVOCATION = re.compile(r"(?:^|[;&|(\n\"'`]|\s)(?:[^\s;|&()\"'`]+/)?git\b[\"']?(?P<args>[^\n;|&)]*)")


def _git_subcommand(tokens):
    """(subcommand, remaining-args) for one git invocation, or (None, [])."""
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


def collect_git(text):
  for m in GIT_INVOCATION.finditer(text):
    try:
        tokens = shlex.split(m.group("args"))
    except ValueError:
        # The clause may be inside an enclosing shell quote. Preserve the
        # conservative executable scan instead of treating parse failure as safe.
        tokens = [word.strip("\"'") for word in m.group("args").split()]
    # A shell comment ends the invocation's arguments. Without this, the
    # trailing `# worktree-remove-ack: ...` token read as a `worktree-*` branch
    # name and turned an ordinary acknowledged branch delete into a refusal.
    for i, t in enumerate(tokens):
        if t.startswith("#"):
            tokens = tokens[:i]
            break
    sub, rest = _git_subcommand(tokens)
    if sub is None or sub in GIT_READ_ONLY_SUBCOMMANDS:
        continue

    if sub == "worktree":
        sub2 = next((t for t in rest if not t.startswith("-")), None)
        if sub2 == "remove":
            reasons.append("git worktree remove")
            after = rest[rest.index("remove") + 1:] if "remove" in rest else []
            paths.extend(t for t in after if not t.startswith("-"))
        elif sub2 == "prune":
            # Even default pruning deletes Git metadata for absent worktrees,
            # including registered ones. Block dry-run forms too: later options
            # can override them. The supported inspection command is list.
            spec.append("git worktree prune (it deletes git's record of every "
                        "absent workspace at once; only a land or a discard deletes one)")
        elif sub2 == "add":
            # docs/plans/worktree-spec-2026-09-11.md, points 1 and 3: every
            # non-native workspace is a cc/ workspace registered when it is
            # created, and creating one that is not is refused. A raw add is
            # registered by nothing.
            spec.append("git worktree add (a workspace is created by "
                        "create-teammate-worktree.sh, which registers it first; a raw one "
                        "has no registration, and one not named cc/ is refused — points 1, 3)")

    elif sub == "branch":
        # -d, -D, a short bundle containing either, or --delete. A bare delete
        # of a branch that is not the system's (points 1, 2) is still NOT
        # blocked -- precision.
        deletes = any(
            t == "--delete" or re.fullmatch(r"-[A-Za-z]*[dD][A-Za-z]*", t)
            for t in rest)
        if deletes and any(re.search(r"(?:^|refs/heads/)codex/\S+", t) for t in rest):
            spec.append("git branch -D of a codex/ branch (codex/ is never touched — point 2)")
        elif deletes and any(re.search(r"(?:^|refs/heads/)(?:worktree-\S+|cc/\S+)", t) for t in rest):
            spec.append("git branch -D of an agent's branch (a land or a discard deletes it, "
                        "with every workspace it has — points 4, 7, 10)")

# 4) A FILESYSTEM recursive rm whose OWN argument list names a worktree.
#
#    FIX 1 — `git rm` is not `rm`. The token immediately preceding the verb is
#    inspected, so `git rm -r <dir>` (an index removal of tracked files) never
#    reaches this rule no matter how much whitespace separates the two words.
#    `sudo rm` / `xargs rm` are NOT excluded — those really do remove files.
#
#    FIX 2 — the target must BE a workspace to make the command destructive:
#    decided structurally, below, from git.
RM_CLAUSE = re.compile(r"(?:^|[;&|(]\s*|\s)rm\b(?P<args>[^;&|)]*)")


def collect_rm(text):
  for m in RM_CLAUSE.finditer(text):
    before = text[:m.start()].rstrip()
    if before.split()[-1:] == ["git"]:
        continue  # `git rm` — an index removal, not a filesystem removal
    args = m.group("args")
    if not (re.search(r"(?:^|\s)-[A-Za-z]*[rR][A-Za-z]*\b", args) or re.search(r"--recursive\b", args)):
        continue
    for raw in re.findall(r"\S+", args):
        tok = raw.strip("\"'")
        if not tok or tok.startswith("-"):
            continue
        if re.search(r"\.claude/worktrees/agent-\S*", tok):
            # Structural, self-describing, and decided without touching disk.
            spec.append("rm -r of a .claude/worktrees/agent-* workspace (point 6: native "
                        "workspaces are deleted by a land or a discard)")
        else:
            rm_paths.append(tok)


# 5) Nobody starts a session in its own workspace (point 3).
CLAUDE_WT = re.compile(r"(?:^|[;&|(\n]\s*|\s)(?:\S*/)?claude\b[^;&|\n]*\s(?:--worktree|-w)(?:\s|=|$)")

# THE WHOLE COMMAND, AND THEN EVERY COMMAND SUBSTITUTION INSIDE IT.
#
# WHY THE SECOND PASS EXISTS, and it is a hole this repair FOUND rather than one
# it created. `GIT_INVOCATION.finditer` cannot overlap, and its argument run
# stops only at a statement separator -- so in
#
#     git commit -m "subject $(git worktree remove <wt>)"
#
# the OUTER `git commit` match swallows the inner one, the inner `git` is never
# classified, and a real removal rides into the object store inside a message.
# So the second pass is confined to text the shell will actually execute: a
# `$( ... )` or backtick substitution, which is a command by construction.
spec = []
paths = []
rm_paths = []
collect_git(scan)
collect_rm(scan)
for _sub in _SUBST.finditer(scan):
    collect_git(_sub.group(0))
    collect_rm(_sub.group(0))
if CLAUDE_WT.search(scan):
    spec.append("claude --worktree / -w (nobody starts a session in its own workspace in "
                "RichOS; it is not allowed — point 3)")


# --- STRUCTURAL workspace test ---------------------------------------------
# A path is a workspace iff, on disk, it is the TOP LEVEL of a LINKED git
# worktree: `rev-parse --show-toplevel` is the path, and `--git-dir` differs
# from `--git-common-dir`. Its branch then says whose concern it is.
def _git(p, *a):
    try:
        r = subprocess.run(["git", "-C", p] + list(a), capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def workspace_kind(p):
    p = os.path.expanduser(p)
    if not os.path.isdir(p):
        return ""
    top = _git(p, "rev-parse", "--show-toplevel")
    if not top or os.path.realpath(top) != os.path.realpath(p):
        return ""
    gd = _git(p, "rev-parse", "--absolute-git-dir")
    cd = _git(p, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not gd or not cd or os.path.realpath(gd) == os.path.realpath(cd):
        return ""
    br = _git(p, "symbolic-ref", "--quiet", "--short", "HEAD")
    if br.startswith("codex/"):
        return "codex"
    if br.startswith("cc/") or br.startswith("worktree-") or "/.claude/worktrees/" in os.path.realpath(p) + "/":
        return "system"
    return "other"


for tok in paths + rm_paths:
    k = workspace_kind(tok)
    if k == "codex":
        spec.append("a codex/ workspace (%s) — codex/ is never touched (point 2)" % tok)
    elif k == "system":
        spec.append("an agent's workspace (%s) — deleted by a land or a discard, with every "
                    "workspace and branch it has (points 4, 7, 10)" % tok)
    elif k == "other" and tok in rm_paths:
        reasons.append("rm -r of a linked git worktree (%s)" % tok)


# The sanctioned command: scripts/workspaces.sh (land / discard) is the only
# thing that deletes a workspace. It cannot authorize a separate raw
# destructive command in the same shell payload.
helper = bool(re.search(r"(?:^|[\s;&|(])(?:\S*/)?workspaces\.sh\b", scan))
ack = re.search(r"worktree-remove-ack:[ \t]*(.+)", scan)

if spec:
    print("SPEC\t" + "; ".join(sorted(set(spec)))); raise SystemExit
if helper and not reasons:
    print("HELPER"); raise SystemExit
if not reasons:
    print("PASS"); raise SystemExit
if ack:
    print("ACK\t" + ack.group(1).strip()); raise SystemExit
print("BLOCK\t" + "; ".join(sorted(set(reasons))))
PYEOF

# Payload bytes use stdin: environment strings have a much smaller per-value
# limit on Linux. A failed classifier must never become an unevaluated pass.
if ! RESULT="$(python3 -c "$_WTR_CLASSIFIER" <<<"$INPUT")"; then
    echo "ERROR: guard-worktree-removal.sh: payload classifier failed; refusing unevaluated operation" >&2
    exit 2
fi

RESULT_KIND="$(printf '%s' "$RESULT" | cut -f1)"

case "$RESULT_KIND" in
    PASS|HELPER)
        exit 0 ;;
    ACK)
        ACK_REASON="$(printf '%s' "$RESULT" | cut -f2-)"
        # Best-effort audit log, written into the ENTITY's state dir — never the
        # engine's. Consecutive-duplicate dedup keyed on the ack text ONLY.
        LOG_DIR="$ENTITY_ROOT/.claude/state"
        LOG_FILE="$LOG_DIR/worktree-remove-acks.log"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        LAST_KEY=""
        [ -f "$LOG_FILE" ] && LAST_KEY="$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -f2- || true)"
        if [ "$ACK_REASON" != "$LAST_KEY" ]; then
            printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACK_REASON" \
                >>"$LOG_FILE" 2>/dev/null || true
        fi
        exit 0 ;;
    SPEC)
        REASONS="$(printf '%s' "$RESULT" | cut -f2-)"
        {
            echo "=== Worktree guard: REFUSED ==="
            echo "  This Bash command does what only the workspace spec's own events do:"
            echo "    $REASONS"
            echo ""
            echo "  docs/plans/worktree-spec-2026-09-11.md: a workspace is registered when it"
            echo "  is created, and deleted when its work is landed or discarded — every"
            echo "  workspace and branch the agent has, together, after its processes are"
            echo "  stopped. Those are the only deleters, and codex/ is never touched:"
            echo "    create:  $ENGINE_ROOT/scripts/create-teammate-worktree.sh <repo> <name>"
            echo "    land:    $ENGINE_ROOT/scripts/workspaces.sh land <agent>"
            echo "    discard: $ENGINE_ROOT/scripts/workspaces.sh discard <agent> --reason '...'"
            echo "  There is no override for this refusal."
            echo "$HOOK_TAG"
        } >&2
        exit 2 ;;
    BLOCK)
        REASONS="$(printf '%s' "$RESULT" | cut -f2-)"
        {
            echo "=== Worktree-removal guard: BLOCKED ==="
            echo "  This Bash command removes a git worktree ($REASONS) that is not an"
            echo "  agent's workspace. If it is an agent's, land or discard it instead:"
            echo "    $ENGINE_ROOT/scripts/workspaces.sh land|discard <agent>"
            echo ""
            echo "  Deliberate removal of a worktree that is not the system's (logged): add a"
            echo "    worktree-remove-ack: <why this removal is safe>"
            echo "  token to the command."
            echo "$HOOK_TAG"
        } >&2
        exit 2 ;;
    *)
        # Unknown classifier output -> fail OPEN (precision; never block unrelated
        # Bash on an unexpected result).
        exit 0 ;;
esac
