#!/usr/bin/env python3
"""
guard-idle-land.py — the analysis half of the Stop-time idle-land gate.

Called by guard-idle-land.sh, which has already resolved the two roots and
decided that this repository adopted the engine. This file does the reading,
the resolving and the verdict; it never decides whether to run.

WHAT THIS IS FOR
  The orchestrator's working record opens by stating its own rule: a land ends
  by STARTING the top unblocked item, then reports -- not the other way round;
  the only permitted stop is an item whose next action needs a decision only
  the CEO can make. The rule was written down. Then four branches landed across
  two repositories, a long report was written, and the turn ended with an empty
  dispatch queue and seven unblocked rows sitting in the file. The operator had
  to type "why has everything stopped again" for the seventh time in two days.

  Every previous answer to that question was a document. This is the same
  defect the whole engine keeps finding in itself -- A RULE ENFORCED BY
  ATTENTION LASTS EXACTLY AS LONG AS THE ATTENTION -- and the answer to it here
  is the answer everywhere else: put it at a chokepoint that fires whether or
  not anybody remembers it. Stop is the chokepoint. The turn is the thing.

THE PREDICATE, AND WHY EVERY TERM IS READ FROM GROUND TRUTH
  Four terms, all four required, none of them read from prose the orchestrator
  wrote:

    1. THIS TURN LANDED SOMETHING. Not "the message says landed" -- a `git
       merge` or `git push` in THIS TURN'S OWN TOOL TRAFFIC, whose EFFECT is
       then confirmed against the repository by identity:
         merge <ref>  ->  `merge-base --is-ancestor <ref> HEAD`
         push         ->  HEAD == the branch's remote-tracking ref
       A merge that conflicted and was aborted fails both. This is the
       freshness contract's own rule -- identity or refuse -- pointed at an
       action instead of at an artifact.

    2. NO WORK WAS STARTED. No `Agent` tool call in this same turn, SCOPED TO
       promptId. The scoping is not an optimization: its sibling guard
       collected tool names session-wide, so "did this turn call Agent?" was
       permanently yes after the first spawn and its reporting layer was
       silently dead for weeks while its suite stayed green. That bug is
       replayed as a test case here (cases p2/p3 in the suite) so it cannot
       come back.

    3. THERE IS SOMETHING TO START. At least one row of the record's `## Next`
       table that is neither struck through nor blocked -- DERIVED FROM THE
       FILE, never a typed count, never a number in a report. If the file is
       missing, unreadable, has no parsable table, or is ambiguous (two
       candidate records on this machine), THE GATE GOES INERT AND SAYS SO. It
       never blocks on a guess about what is left to do.

    4. NOTHING IS STILL RUNNING. `background_tasks` from the payload. Landing
       while four agents work is not idling, and a gate that could not tell the
       difference would fire on the most productive turns in the session.

  Everything unrecognized is treated as BLOCKED, not as free. Every ambiguity
  resolves towards silence. A gate that cries wolf is removed within a day, and
  then the operator is worse off than before it existed.

THE ESCAPE, AND WHY THERE IS NO TOKEN FOR IT
  There is no live override line. The escape is legitimate and already exists:
  move the row into the CEO's record, which is a committed, diffable act. An
  in-the-moment token would be reached for at exactly the moment this gate is
  doing its job -- the argument guard-row-currency-commits.sh makes about "I
  will update the row after the deploy", unchanged.

  That is also why the gate is INERT unless the repository declares `.ceo-todos`:
  the deferral target must exist before a refusal can honestly point at it. A
  gate that refuses and offers nowhere to go is a gate people unwire.

WHAT IT CANNOT SEE
  * work started any way other than an `Agent` call -- a task written into a
    store, a message to a running teammate. Those are not dispatches of the top
    row and the record's rule is about dispatching.
  * a land that reaches a repository some way other than `git merge`/`git push`
    (a cherry-pick, an `am`, a rebase-and-fast-forward). Stated gap, not an
    oversight: none of them is how work lands here.
  * whether the row that WAS dispatched is the TOP one. This gate checks that
    something started, never that the right thing started. Ordering is
    judgment and this is not a judge.
  * a merge whose branch ref was deleted immediately afterwards: the identity
    confirmation cannot resolve it, so the turn passes. Quiet direction.

Exit codes:
  0  did not land, dispatched something, nothing to start, not evaluable, or
     anything went wrong
  2  BLOCKED -- landed, started nothing, and the record has an unblocked row
"""

import json
import os
import re
import shlex
import subprocess
import sys

# --------------------------------------------------------------------------
# this turn's tool traffic
# --------------------------------------------------------------------------

# A prompt the HOST wrote, not the operator: a task notification carrying an
# agent's whole handoff, a system reminder, a queued-command echo.
MACHINE_PROMPT_RE = re.compile(
    r"<(task-notification|system-reminder|command-message|command-name|"
    r"local-command-stdout)>")


def read_turn(path, prompt_id, limit_bytes=48 * 1024 * 1024):
    """Tool names, Bash command strings and the operator's own words, THIS TURN.

    The turn is scoped by promptId, using the binary's own semantic: a UUID
    correlating a user prompt with all subsequent events until the next prompt.
    Assistant records carry no promptId, so the turn is the file-order span from
    the first record bearing this prompt_id to the end of the file -- at Stop
    time there is no next prompt yet.

    ABSENT A prompt_id THE TURN CANNOT BE SCOPED, and here that means the gate
    is not evaluable at all: an unscoped read would attribute the whole
    session's merges to this turn AND the whole session's Agent calls to it,
    and the two errors do not cancel. So it returns None and the caller stands
    down. The sibling gate could afford to widen; this one cannot.

    At Stop time the transcript already holds every tool_use and tool_result of
    the turn; it does NOT yet hold the final assistant text. Nothing here needs
    that text -- this gate reads actions, not claims.
    """
    if not prompt_id:
        return None
    if not path or not os.path.isfile(path):
        return None
    try:
        if os.path.getsize(path) > limit_bytes:
            return None
    except OSError:
        return None

    tools, bash, said, cwd = [], [], [], ""
    started = False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("promptId") == prompt_id:
                    if not started:
                        started = True
                    if rec.get("cwd"):
                        cwd = rec["cwd"]
                if not started:
                    continue
                msg = rec.get("message") or {}
                content = msg.get("content")
                # The operator's own words, used ONLY to stand the gate down
                # (see hold_signal). Real user prompts carry an origin or a
                # promptSource; a tool_result user record carries neither.
                #
                # MACHINE-GENERATED PROMPTS ARE NOT THE OPERATOR. A
                # <task-notification> arrives on the same channel, carries a
                # whole agent handoff inside it, and is where this filter was
                # earned: replaying the failing turn, the gate stood itself
                # down on the word "Freeze" — inside `Freeze margin 1.5`,
                # quoted by an agent reporting a measurement. The operator had
                # said nothing at all that turn.
                if rec.get("type") == "user" and (rec.get("origin") or rec.get("promptSource")):
                    parts = []
                    if isinstance(content, str):
                        parts.append(content)
                    elif isinstance(content, list):
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "text":
                                parts.append(b.get("text", ""))
                    for t in parts:
                        if MACHINE_PROMPT_RE.search(t):
                            continue
                        said.append(t)
                if rec.get("type") == "assistant" and isinstance(content, list):
                    for b in content:
                        if not isinstance(b, dict) or b.get("type") != "tool_use":
                            continue
                        name = b.get("name", "")
                        tools.append(name)
                        if name == "Bash":
                            inp = b.get("input") or {}
                            if isinstance(inp, dict):
                                bash.append(str(inp.get("command", "") or ""))
    except OSError:
        return None
    if not started:
        return None
    return {"tools": tools, "bash": bash, "said": "\n".join(said), "cwd": cwd}


# --------------------------------------------------------------------------
# PREDICATE 1 -- did this turn land anything?
# --------------------------------------------------------------------------

HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# Flags of `git merge` that TAKE A VALUE. Without this list the value is read
# as the merged ref: `git merge -m "…" branch` would confirm against a commit
# message. Nothing downstream would notice, because an unresolvable ref simply
# makes the gate quiet — which is how a check goes dead without failing.
MERGE_VALUE_FLAGS = {"-m", "--message", "-F", "--file", "-s", "--strategy",
                     "-X", "--strategy-option", "-S", "--gpg-sign",
                     "--into-name", "--cleanup"}


def strip_heredocs(cmd):
    """Drop heredoc BODIES, keeping the line that opens them.

    A heredoc body is data, not commands. These commands routinely carry whole
    python programs inside `<<'PY' … PY`, and such a body will contain quotes
    that do not balance as shell — which breaks any quote-aware scan of the
    rest of the line, and can also contain the literal text of a git command
    that was never run.
    """
    lines = (cmd or "").split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = HEREDOC_RE.search(line)
        if m:
            tag = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() != tag:
                j += 1
            i = j + 1
            continue
        i += 1
    return "\n".join(out)


def segments(cmd):
    """Split a shell command into segments, RESPECTING QUOTES.

    A regex split on `[;\\n|&]` is wrong here and the failure is silent rather
    than loud: every real landing in this repository is written

        git merge --no-ff <branch> -m "<subject>
        <a body with blank lines and newlines in it>"

    and a naive newline split cuts that quoted message in half, leaves shlex
    with an unbalanced quote, and drops the merge on the floor. Replayed
    against the turn this gate was written for, that bug found 3 pushes and
    ZERO of the 4 merges.
    """
    text = strip_heredocs(cmd)
    segs, buf, q, i = [], [], None, 0
    n = len(text)
    while i < n:
        c = text[i]
        if q:
            buf.append(c)
            if c == "\\" and q == '"' and i + 1 < n:
                buf.append(text[i + 1])
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in ("'", '"'):
            q = c
            buf.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            buf.append(c)
            buf.append(text[i + 1])
            i += 2
            continue
        if c in "\n;|&":
            segs.append("".join(buf))
            buf = []
            while i < n and text[i] in "\n;|&":
                i += 1
            continue
        buf.append(c)
        i += 1
    segs.append("".join(buf))
    return [s for s in segs if s.strip()]


def _argv(seg):
    try:
        argv = shlex.split(seg, comments=False)
    except ValueError:
        return None
    while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
        argv.pop(0)
    return argv or None


def landing_ops(commands, base_cwd):
    """[(repo_path, 'merge'|'push', ref)] for every merge/push in the traffic.

    Parsed as COMMAND LINES, never matched as substrings: `echo "git push"` is
    not a push, and a gate that thinks it is teaches people it cries wolf. `cd`
    is tracked across segments because that is how these commands are actually
    written -- `cd <repo> && git merge <branch>`.
    """
    ops = []
    for cmd in commands:
        cwd = base_cwd
        for seg in segments(cmd):
            argv = _argv(seg)
            if not argv:
                continue
            head = os.path.basename(argv[0])
            if head == "cd" and len(argv) > 1:
                target = argv[1]
                if not target.startswith("-"):
                    target = os.path.expanduser(target)
                    cwd = target if os.path.isabs(target) else os.path.normpath(
                        os.path.join(cwd or ".", target))
                continue
            if head != "git":
                continue
            repo, k, sub = "", 1, ""
            while k < len(argv):
                a = argv[k]
                if a == "-C" and k + 1 < len(argv):
                    repo = argv[k + 1]
                    k += 2
                    continue
                if a in ("-c", "--git-dir", "--work-tree") and k + 1 < len(argv):
                    k += 2
                    continue
                if a.startswith("-"):
                    k += 1
                    continue
                sub = a
                k += 1
                break
            if sub not in ("merge", "push"):
                continue
            rest = argv[k:]
            # --abort / --continue / --quit / --dry-run are not landings.
            if any(a in ("--abort", "--continue", "--quit", "--dry-run", "-n",
                         "--no-commit") for a in rest):
                continue
            # The merged ref. Value-taking flags are consumed with their value
            # (see MERGE_VALUE_FLAGS), and a redirection token is never a ref.
            # For a push nothing here is used at all -- the confirmation is
            # HEAD against the remote-tracking ref.
            ref = ""
            j = 0
            while j < len(rest):
                a = rest[j]
                if a in MERGE_VALUE_FLAGS:
                    j += 2
                    continue
                if a.startswith("-"):
                    j += 1
                    continue
                if ">" in a or "<" in a:
                    j += 1
                    continue
                ref = a
                break
            path = repo or cwd or ""
            path = os.path.expanduser(path)
            if path and not os.path.isabs(path):
                path = os.path.normpath(os.path.join(cwd or ".", path))
            ops.append((path, sub, ref))
    return ops


def _git(repo, *args, **kw):
    try:
        p = subprocess.run(["git", "-C", repo] + list(args),
                           capture_output=True, text=True, timeout=kw.get("timeout", 10))
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.strip()


def confirm_landing(repo, kind, ref):
    """Did the operation actually change this repository? Identity, not prose.

    merge <ref>  the merged tip is now an ancestor of HEAD. A merge that
                 conflicted, was aborted, or was never committed fails this.
    push         HEAD equals the branch's remote-tracking ref. A push that was
                 rejected, or that never ran, fails this.

    Both are content identities: no clock, no reflog window, no parsing of
    command output that a pipe may have swallowed.
    """
    if not repo or not os.path.isdir(repo):
        return False
    top = _git(repo, "rev-parse", "--show-toplevel")
    if not top:
        return False
    head = _git(repo, "rev-parse", "HEAD")
    if not head:
        return False
    if kind == "merge":
        if not ref:
            return False
        if _git(repo, "rev-parse", "--verify", "-q", ref + "^{commit}") is None:
            return False
        try:
            p = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", ref, "HEAD"],
                               capture_output=True, text=True, timeout=10)
        except Exception:
            return False
        return p.returncode == 0
    branch = _git(repo, "symbolic-ref", "--short", "-q", "HEAD")
    if not branch:
        return False
    up = _git(repo, "rev-parse", "--verify", "-q", branch + "@{upstream}")
    return bool(up) and up == head


# --------------------------------------------------------------------------
# PREDICATE 4 -- is anything still running?
# --------------------------------------------------------------------------

TERMINAL = {"completed", "complete", "done", "failed", "failure", "error",
            "cancelled", "canceled", "terminated", "killed", "stopped", "finished"}


def still_running(payload):
    bt = payload.get("background_tasks")
    if not isinstance(bt, list) or not bt:
        return 0
    n = 0
    for t in bt:
        if isinstance(t, dict):
            st = str(t.get("status") or t.get("state") or "").strip().lower()
            if st in TERMINAL:
                continue
        # A non-dict entry, or one with no status we recognize, counts as
        # RUNNING. Unrecognized means quiet.
        n += 1
    return n


# --------------------------------------------------------------------------
# the operator's own hold
# --------------------------------------------------------------------------

HOLD_RE = re.compile(
    r"\b(hold(?:\s+(?:on|off|everything|all|it|fire|the\s+line))?|"
    r"stand\s+down|stand\s+by|standby|"
    r"pause(?:\s+(?:everything|all|the|it|here))?|"
    r"freeze(?:\s+(?:everything|all))?|"
    r"do\s+not\s+(?:dispatch|spawn|start|proceed|continue|land)|"
    r"don'?t\s+(?:dispatch|spawn|start|proceed|continue|land)|"
    r"no\s+more\s+(?:work|dispatches|dispatching|agents))\b", re.I)

CODE_SPAN_RE = re.compile(r"```.*?```|`[^`\n]*`", re.S)


def hold_signal(said):
    """The operator told this turn to stop. Prose, deliberately, and safe.

    Every other prose predicate in this engine was measured and demoted, and
    this one would be too if it could accuse anybody. It cannot: it only ever
    STANDS THE GATE DOWN. A false positive costs one un-fired gate; a false
    negative costs nothing, because the gate then evaluates its four real
    terms. ONE-DIRECTIONAL ERROR is what makes a heuristic acceptable here and
    is the only reason there is prose in this file at all.

    Two narrowings, both earned on the replay rather than guessed, and NOT a
    third one that was tried and rejected:
      * the text is the OPERATOR'S OWN PROMPTS only, never a host-written one
        (read_turn does that filtering). A task notification carrying an
        agent's handoff is not the operator speaking, and that is where the
        real false positive came from;
      * code spans are removed. `Freeze margin 1.5`, quoted inside an agent's
        measurement, stood the gate down on the very turn it exists to catch.
      * REJECTED: requiring the phrase to open a sentence. It is the obvious
        third narrowing and it is wrong -- "Land what is finished and then
        hold" is exactly how a hold is actually said, and the anchor threw it
        away. Measured over the corpus, the unanchored form suppressed nothing
        it should not have; the operator's own words are short and directive,
        which is what makes the loose form safe HERE and nowhere else.
    """
    if not said:
        return None
    text = CODE_SPAN_RE.sub(" ", said)
    m = HOLD_RE.search(text)
    return m.group(1) if m else None


# --------------------------------------------------------------------------
# PREDICATE 3 -- the record, and what is left in it
# --------------------------------------------------------------------------

DEFAULT_RECORD = "RICH-TODOs.md"
DEFAULT_SECTION = "Next"


def _repo_top(path):
    if not path or not os.path.isdir(path):
        return ""
    return _git(path, "rev-parse", "--show-toplevel") or ""


def backlog_candidates(landed_repos, entity_root, record_name):
    """Every place on this machine that could hold the orchestrator's backlog.

    A repository qualifies only if it declares `.ceo-todos` AND carries the
    record. The declaration requirement is not decoration: it is what
    guarantees the refusal has somewhere legitimate to send the row (see the
    module docstring, "THE ESCAPE"). Search order is the landed repositories,
    then their siblings, then the entity and its siblings -- deterministic, and
    the chosen path is printed in every refusal so it is never a mystery.
    """
    seen, out = set(), []

    def consider(p):
        top = _repo_top(p)
        if not top or top in seen:
            return
        seen.add(top)
        if not os.path.isfile(os.path.join(top, ".ceo-todos")):
            return
        rec = os.path.join(top, record_name)
        if os.path.isfile(rec):
            out.append(rec)

    def with_siblings(p):
        consider(p)
        parent = os.path.dirname(os.path.abspath(p)) if p else ""
        if not parent or not os.path.isdir(parent):
            return
        try:
            for d in sorted(os.listdir(parent))[:60]:
                consider(os.path.join(parent, d))
        except OSError:
            pass

    for r in landed_repos:
        with_siblings(r)
    if entity_root:
        with_siblings(entity_root)
    return out


STRIP_RE = re.compile(r"(\*\*|~~|`|\*|_)")
REF_RANGE_RE = re.compile(r"(\d+)\s*[-‐-―]\s*(\d+)")

# A cell that says the work is finished. The record strikes such rows through
# as well, so this is a second, independent reading of the same fact.
DONE_WORDS = {"done", "landed", "closed", "shipped", "merged", "complete", "completed"}

# A cell that states nothing is in the way. Everything NOT in this set, and not
# matching the "<something> free" shape below, is treated as BLOCKED -- the
# quiet direction, because the cost of a wrong "blocked" is one missed nudge
# and the cost of a wrong "free" is the gate crying wolf.
FREE_WORDS = {"", "-", "--", "–", "—", "n/a", "na", "none", "nothing",
              "nobody", "unblocked", "ready", "now", "free", "no", "nil"}

FREE_SHAPE_RE = re.compile(r"^(?:.{0,40}?\s)?free(?:\s+after\s+(?P<refs>.+))?$")


def _norm(cell):
    s = STRIP_RE.sub("", cell or "")
    return re.sub(r"\s+", " ", s).strip().lower()


def parse_record(text, section):
    """The `## <section>` table, as rows with a derived state.

    Returns (rows, reason). rows is None when the record cannot be read as a
    table at all -- and the caller then goes INERT rather than guessing.

    Each row is {num, item, blocked, state} where state is one of
    'done' / 'free' / 'blocked'. Nothing here is a count; the count is
    len([r for r in rows if r.state == 'free']) and it is computed, never read.
    """
    lines = text.split("\n")
    start = None
    pat = re.compile(r"^#{1,6}\s+" + re.escape(section) + r"\s*$", re.I)
    for i, ln in enumerate(lines):
        if pat.match(ln.strip()):
            start = i + 1
            break
    if start is None:
        return None, "no '%s' section heading" % section

    body = []
    for ln in lines[start:]:
        if re.match(r"^#{1,6}\s+\S", ln.strip()):
            break
        body.append(ln)

    table = [ln.strip() for ln in body if ln.strip().startswith("|")]
    if len(table) < 3:
        return None, "the '%s' section holds no table" % section

    def cells(ln):
        parts = ln.split("|")
        if parts and not parts[0].strip():
            parts = parts[1:]
        if parts and not parts[-1].strip():
            parts = parts[:-1]
        return [p.strip() for p in parts]

    header = cells(table[0])
    if len(header) < 2:
        return None, "the table header has fewer than two columns"
    sep = cells(table[1])
    if not sep or not all(re.match(r"^:?-{2,}:?$", s) for s in sep if s):
        return None, "the table has no header separator"

    # Column roles are DERIVED from the header, never assumed by position.
    blocked_col = None
    for i, h in enumerate(header):
        if re.search(r"block", h, re.I):
            blocked_col = i
    if blocked_col is None:
        blocked_col = len(header) - 1
    item_col = 1 if len(header) > 1 else 0
    if item_col == blocked_col:
        item_col = 0

    rows, by_num = [], {}
    for ln in table[2:]:
        c = cells(ln)
        if len(c) < 2:
            continue
        num_raw = c[0] if len(c) > 0 else ""
        item_raw = c[item_col] if item_col < len(c) else ""
        blk_raw = c[blocked_col] if blocked_col < len(c) else ""
        struck = "~~" in num_raw or "~~" in item_raw
        blk = _norm(blk_raw)
        state = "blocked"
        if struck or blk in DONE_WORDS:
            state = "done"
        else:
            m = FREE_SHAPE_RE.match(blk)
            if blk in FREE_WORDS:
                state = "free"
            elif m:
                state = "free" if m.group("refs") is None else "deferred"
                if state == "deferred":
                    state = ("deferred", m.group("refs"))
        row = {"num": _norm(num_raw), "num_raw": num_raw.strip(),
               "item": item_raw.strip(), "blocked": blk_raw.strip(),
               "state": state}
        rows.append(row)
        if row["num"]:
            by_num[row["num"]] = row

    # "<something> free after 1-2" -- resolve the references. Every referenced
    # row must exist AND be done; anything else stays blocked. This is derived
    # from the same table, so it can never disagree with a count somebody typed.
    for row in rows:
        st = row["state"]
        if not isinstance(st, tuple):
            continue
        refs = st[1]
        nums = set()
        for a, b in REF_RANGE_RE.findall(refs):
            try:
                lo, hi = int(a), int(b)
            except ValueError:
                nums = None
                break
            if hi - lo > 50:
                nums = None
                break
            nums.update(str(n) for n in range(lo, hi + 1))
        if nums is None:
            row["state"] = "blocked"
            continue
        rest = REF_RANGE_RE.sub(" ", refs)
        nums.update(re.findall(r"\d+", rest))
        if not nums:
            row["state"] = "blocked"
            continue
        ok = True
        for n in nums:
            target = by_num.get(n)
            if target is None or target["state"] != "done":
                ok = False
                break
        row["state"] = "free" if ok else "blocked"

    if not rows:
        return None, "the '%s' table has no rows" % section
    return rows, ""


def summarise(item, limit=160):
    """One line of the row, for the refusal. Never the whole cell.

    Kept short on purpose: the refusal names the row so it can be found, it
    does not reproduce the record. The record is the record.
    """
    s = re.sub(r"\s+", " ", item or "").strip()
    return s[:limit] + ("..." if len(s) > limit else "")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # unparseable payload never wedges turn-end

    if payload.get("stop_hook_active"):
        # Already blocked once this turn. A gate that re-blocks its own retry is
        # a gate that can strand a session.
        return 0

    entity_root = (os.environ.get("RICHOS_IDLE_ENTITY_ROOT")
                   or payload.get("cwd") or os.getcwd())
    record_name = os.environ.get("RICHOS_IDLE_RECORD") or DEFAULT_RECORD
    section = os.environ.get("RICHOS_IDLE_SECTION") or DEFAULT_SECTION
    enforce = os.environ.get("RICHOS_IDLE_ENFORCE", "1") != "0"

    turn = read_turn(payload.get("transcript_path"), payload.get("prompt_id"))
    if turn is None:
        # No scoped turn, no gate. Silent: this is the ordinary state of every
        # session that is not the orchestrator's, and a line here would be
        # printed thousands of times to say nothing.
        return 0

    base_cwd = turn.get("cwd") or entity_root
    ops = landing_ops(turn["bash"], base_cwd)
    if not ops:
        return 0

    landed, unconfirmed = [], []
    for repo, kind, ref in ops:
        top = _repo_top(repo)
        if confirm_landing(repo, kind, ref):
            if top and top not in landed:
                landed.append(top)
        else:
            unconfirmed.append((repo, kind, ref))

    record = {
        "prompt_id": payload.get("prompt_id"),
        "session": payload.get("session_id") or "",
        "ops": len(ops),
        "landed": landed,
        "unconfirmed": len(unconfirmed),
        "dispatched": turn["tools"].count("Agent"),
        "verdict": "pass",
    }

    def log():
        try:
            state = os.path.join(entity_root, ".claude", "state")
            os.makedirs(state, exist_ok=True)
            with open(os.path.join(state, "idle-land-checks.jsonl"), "a",
                      encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
        except Exception:
            pass  # the log is a convenience; losing it never changes a verdict

    if not landed:
        record["verdict"] = "no-confirmed-landing"
        log()
        return 0

    if "Agent" in turn["tools"]:
        record["verdict"] = "dispatched"
        log()
        return 0

    running = still_running(payload)
    if running:
        record["verdict"] = "background-running"
        record["running"] = running
        log()
        return 0

    held = hold_signal(turn["said"])
    if held:
        record["verdict"] = "held"
        record["hold"] = held
        log()
        return 0

    # From here the turn HAS landed and started nothing, so every remaining
    # outcome is worth a line on stderr. Above this point silence is correct;
    # below it, silence would be a defense that reports "on" while looking at
    # nothing.
    cands = backlog_candidates(landed, entity_root, record_name)
    tag = "(hook: scripts/hooks/guard-idle-land.sh)"

    if not cands:
        record["verdict"] = "inert-no-record"
        log()
        sys.stderr.write(
            "idle-land gate INERT: this turn landed and started nothing, but no\n"
            "  %s beside a `.ceo-todos` declaration was found near %s.\n"
            "  Nothing was checked -- said out loud so that 'the gate is on' never\n"
            "  means 'the gate looked'. %s\n" % (record_name, ", ".join(landed), tag))
        return 0

    if len({os.path.realpath(c) for c in cands}) > 1:
        record["verdict"] = "inert-ambiguous"
        record["candidates"] = cands
        log()
        sys.stderr.write(
            "idle-land gate INERT: %d candidate records found and a gate that guesses\n"
            "  is not a gate:\n%s\n  Declare one, or remove the others. %s\n"
            % (len(cands), "\n".join("      " + c for c in cands), tag))
        return 0

    path = cands[0]
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        record["verdict"] = "inert-unreadable"
        log()
        sys.stderr.write("idle-land gate INERT: %s is unreadable (%s). Nothing was\n"
                         "  checked. %s\n" % (path, e, tag))
        return 0

    rows, reason = parse_record(text, section)
    if rows is None:
        record["verdict"] = "inert-unparsable"
        record["reason"] = reason
        log()
        sys.stderr.write("idle-land gate INERT: %s -- %s. The gate will not guess at\n"
                         "  what is left to do, so nothing was checked. %s\n"
                         % (path, reason, tag))
        return 0

    free = [r for r in rows if r["state"] == "free"]
    record["rows"] = len(rows)
    record["free"] = len(free)
    record["record"] = path
    if not free:
        record["verdict"] = "backlog-empty"
        log()
        return 0

    top = free[0]
    record["verdict"] = "block" if enforce else "report"
    record["top"] = top["num_raw"] or summarise(top["item"], 60)
    log()

    head = ("=== LANDED, AND STARTED NOTHING — TURN BLOCKED ==="
            if enforce else
            "=== idle-land gate: LANDED, AND STARTED NOTHING (report only) ===")
    out = [head, ""]
    out.append("  This turn landed work in: %s" % ", ".join(landed))
    out.append("  Agent calls this turn: 0")
    out.append("  Unblocked rows left in %s (%s): %d"
               % (os.path.basename(path), section, len(free)))
    out.append("")
    out.append("  The top one:")
    out.append("      %s  %s" % (top["num_raw"] or "-", summarise(top["item"])))
    if top["blocked"]:
        out.append("      blocked by: %s" % summarise(top["blocked"], 80))
    out.append("")
    out.append("  Two ways through, and only two:")
    out.append("    1. START IT. Dispatch it now, in this turn, then report.")
    out.append("    2. MOVE IT. If its next action needs a decision only the CEO")
    out.append("       can make, move the row into the CEO's record — a committed,")
    out.append("       diffable act, which is why there is no override token here.")
    out.append("")
    out.append("  Record: %s" % path)
    if not enforce:
        out.append("  (report-only: IDLE_LAND_ENFORCE=0 — this turn was NOT blocked)")
    else:
        out.append("  Do not weaken or unwire this hook.")
    out.append(tag)
    sys.stderr.write("\n".join(out) + "\n")
    return 2 if enforce else 0


if __name__ == "__main__":
    sys.exit(main())
