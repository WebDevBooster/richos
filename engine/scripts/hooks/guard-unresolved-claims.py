#!/usr/bin/env python3
"""
guard-unresolved-claims.py — the analysis half of the Stop-time claim gate.

Called by guard-unresolved-claims.sh, which has already resolved the two roots
and decided that this repository adopted the engine. This file does the
reading, the resolving and the verdict; it never decides whether to run.

WHAT THIS IS FOR
  Every other guard in this engine watches the REPOSITORY. This one watches the
  TURN -- specifically the last thing the orchestrator says before it stops
  talking, which is the one surface on which an untrue statement is free.

THE PREDICATE, AND WHY IT IS THIS ONE
  The first design read prose: it looked for "dispatching" and asked whether an
  Agent call had been made. That is a heuristic over natural language and it was
  measured at 17% precision (1 true positive against 5 false ones across 418
  real turns) -- every false one was the orchestrator correctly describing a
  PAST action, a NEGATED action ("I'm not spawning anything further"), or a past
  incident. A gate at 17% precision is worse than no gate: it teaches the thing
  it governs to route around it, and then it protects nothing.

  So this gate does not detect INTENT. It resolves IDENTIFIERS. An identifier
  either resolves against ground truth or it does not; there is no threshold to
  tune and nothing to interpret.

WHY SOME IDENTIFIERS BLOCK AND OTHERS ONLY REPORT
  The property that makes a check safe to block on is not exactness. It is
  MONOTONICITY OF THE GROUND TRUTH.

    * agent names -- ground truth is the spawned-names ledger, the roster and
      the idle/task event logs. detect-nonnative-worktree.sh only ever APPENDS
      to the ledger, and only for an Agent call that actually executed. Nothing
      removes an entry. So within a session the set only grows, and an
      unresolved name can mean exactly one thing: never spawned. BLOCKS.

    * commit SHAs -- ground truth is the object database, which SHRINKS: a
      history rewrite plus gc drops commits that were real when cited. Measured
      cold against today's object DB, 8 of 262 SHA citations failed and all 8
      were casualties of one rewrite the orchestrator itself announced. Adding
      session-wide grounding (below) took that to 0/262. BLOCKS, with grounding.

    * file paths -- ground truth is the filesystem, which shrinks harder: files
      are deleted, renamed, and moved, and reporting a deletion correctly means
      naming a path that no longer resolves. Worse, a relative path is only
      meaningful against a base this process cannot know. Even with grounding,
      15 of 572 path citations failed and they were legitimate: hypothetical
      adopter paths (`~/ab/myrichos`), paths inside a landed-and-removed
      worktree, mockup-round directories relative to an unknown base. 2.6% is
      not zero, so paths REPORT and never block.

GROUNDING -- the relaxation that makes existence-checks safe
  A claim passes if it resolves NOW, *or* if the token appeared anywhere in this
  session's tool traffic. The reasoning: to correctly report that a thing was
  deleted, moved or rewritten, you must have OBSERVED it, and observation means
  tool output. Existence is non-monotonic; observation-within-a-session is
  monotonic, because the transcript only grows. Grounding restores the
  can't-be-wrong property that raw existence checking loses.

  It costs recall -- anything the orchestrator grepped for is thereafter
  citable. That trade is deliberate and it is the right way round: a missed
  check costs one undetected claim, a false alarm costs the whole gate.

CONSERVATISM RULES (all of these make the gate quieter, never louder)
  * a token that is ambiguous is IGNORED, never flagged
  * SHAs are read only from backtick-delimited citations that are ENTIRELY the
    hex token, with at least one digit and one letter -- so UUID fragments,
    tool-use ids and English words never enter
  * the agent-name check is INERT unless this session's own team directory
    exists, because absent ground truth cannot prove absence
  * any resolver error fails OPEN

WHAT IT CANNOT SEE
  * a nameless action claim -- "dispatching it now", with no agent named --
    contains no identifier at all, so this gate passes it. Requiring that such a
    message name nobody was PROPOSED as a gate and MEASURED at 10.3%: 29 of the
    30 prose hits in 3,532 real messages name nobody, so the refinement removes
    one hit in thirty. See nameless_dispatch(). Reported, never enforced.
  * a bare-role claim about a role that HAS been dispatched before -- "Zach is
    building it now" when a zach agent ran earlier in the session for other
    work. That is the 2026-08-31 failure exactly, and the monotonic test passes
    it. Only live_roles() can see it, liveness is not monotonic, and so it
    reports. Stated here rather than discovered later.
  * a claim that is false about the WORLD but true about identifiers ("the
    tests pass" when they do not)
  * anything after the turn ends. This is a point-in-time check: it proves the
    identifier resolved when the claim was made. A later rewrite that kills an
    already-published SHA is a different problem with a different guard.

Exit codes:
  0  nothing unresolved, or the check could not be evaluated
  2  at least one identifier in the final message resolves against nothing
"""

import json
import os
import re
import subprocess
import sys

# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------

# <role>-<model>-<identifier>, where <model> is one of the four real aliases.
# The middle token is what makes this unambiguous: no English sentence contains
# "word-opus-word" by accident.
AGENT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])"
    r"([a-z][a-z0-9]{1,15})-(fable|opus|sonnet|haiku)-([a-z0-9]{1,12})"
    r"(?![A-Za-z0-9_-])"
)

# A BARE ROLE, USED AS THE SUBJECT OF A PRESENT-PROGRESSIVE VERB.
#
#     "Zach is building it now"        "Dean is writing both hires"
#
# THIS IS THE SHAPE OF THE FAILURE, and it is a far narrower trigger than the
# prose signal's `dispatching|spawning|launching`. Measured over 3,532 real
# final messages it fires 103 times and EVERY ONE of the 103 is a genuine
# reference to a teammate — no ordinary-noun use of "art", "mark", "will" or
# "ray" enters, because the role must be CAPITALIZED and must be the subject of
# a progressive verb. As an extractor it is 103/103.
#
# The role list is DERIVED, never typed: agent definitions on disk, unioned
# with the session roster's own agentType values. A role nobody has defined is
# not a role, and an empty set makes the whole check inert.
PROGRESSIVE = r"(?:is|'s)\s+(?:now\s+|already\s+|still\s+|currently\s+|just\s+)?[a-z]+ing\b"

BACKTICK_RE = re.compile(r"`([^`\n]{1,300})`")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
ABS_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])((?:~|/(?:Users|home|opt|srv|var|etc))/[A-Za-z0-9._/-]+)"
)
LINE_SUFFIX = re.compile(r":\d+(?::\d+)?$")
GLOB_CHARS = set("*?[]{}$()|<>\"'\\ \t")

MAX_TOKENS = 40  # per class, per turn -- a cap so a pathological message cannot
                 # turn turn-end into a git benchmark


def _backticked(text):
    return [m.group(1).strip() for m in BACKTICK_RE.finditer(text)]


def agent_names(text):
    return sorted({m.group(0) for m in AGENT_RE.finditer(text)})[:MAX_TOKENS]


def roster_roles(entity_root, teams_dir, session_id):
    """Every role this installation actually has. Derived from two surfaces."""
    roles = set()
    d = os.path.join(entity_root, ".claude", "agents")
    try:
        for f in os.listdir(d):
            if f.endswith(".md"):
                stem = f[:-3]
                if re.fullmatch(r"[a-z][a-z0-9]{1,15}", stem):
                    roles.add(stem)
    except OSError:
        pass
    for m in _roster_members(teams_dir, session_id):
        t = str(m.get("agentType") or "")
        if re.fullmatch(r"[a-z][a-z0-9]{1,15}", t):
            roles.add(t)
    roles.discard("team")
    return roles


def role_claims(text, roles):
    """[(role, span)] -- bare-role in-flight claims in this message."""
    if not roles:
        return []
    alt = "|".join(sorted(re.escape(r.capitalize()) for r in roles))
    rx = re.compile(r"(?<![A-Za-z0-9_-])(%s)(?![A-Za-z0-9_-])\s+%s" % (alt, PROGRESSIVE))
    out, seen = [], set()
    for m in rx.finditer(text):
        role = m.group(1).lower()
        if role in seen:
            continue
        seen.add(role)
        out.append((role, m.group(0)))
    return out[:MAX_TOKENS]


def sha_claims(text):
    out = set()
    for tok in _backticked(text):
        if not SHA_RE.match(tok):
            continue
        # Both a digit and a letter. Kills pure-decimal ("1234567") and the
        # handful of all-hex English words ("deadbeef", "facade").
        if not (any(c.isdigit() for c in tok) and any(c.isalpha() for c in tok)):
            continue
        out.add(tok)
    return sorted(out)[:MAX_TOKENS]


def path_claims(text):
    cands = list(_backticked(text))
    cands += [m.group(1) for m in ABS_PATH_RE.finditer(text)]
    out = set()
    for tok in cands:
        tok = LINE_SUFFIX.sub("", tok.strip().rstrip(",.;:"))
        if "/" not in tok or len(tok) < 3:
            continue
        if any(c in GLOB_CHARS for c in tok):
            continue
        if "://" in tok or tok.startswith("//"):
            continue
        segs = [s for s in tok.split("/") if s]
        if not segs:
            continue
        # A purely numeric segment means this is a ratio or a label, not a
        # path: "16/16", "C_turbo_rep1/2/3".
        if any(s.isdigit() for s in segs):
            continue
        last = segs[-1]
        ext = last.rsplit(".", 1)[1] if ("." in last and not last.startswith(".")) else ""
        if not (tok.startswith("/") or tok.startswith("~") or tok.endswith("/")
                or (ext and len(ext) <= 5)):
            continue
        out.add(tok)
    return sorted(out)[:MAX_TOKENS]


# --------------------------------------------------------------------------
# ground truth
# --------------------------------------------------------------------------

def name_history(teams_dir):
    """Union of every present session team dir: ledger + roster + event logs.

    Deliberately unioned across ALL sessions rather than scoped to this one.
    A wider set can only make the gate quieter, and the orchestrator does refer
    to teammates from earlier sessions by their exact identifier.
    """
    hist = set()
    if not os.path.isdir(teams_dir):
        return hist
    try:
        entries = os.listdir(teams_dir)
    except OSError:
        return hist
    for d in entries:
        td = os.path.join(teams_dir, d)
        if not os.path.isdir(td):
            continue
        try:
            with open(os.path.join(td, "spawned-names.log"), encoding="utf-8") as f:
                hist.update(x.strip() for x in f if x.strip())
        except Exception:
            pass
        try:
            with open(os.path.join(td, "config.json"), encoding="utf-8") as f:
                for m in (json.load(f).get("members") or []):
                    if isinstance(m, dict) and m.get("name"):
                        hist.add(m["name"])
        except Exception:
            pass
        for logname in ("idle-events.jsonl", "task-events.jsonl"):
            try:
                with open(os.path.join(td, logname), encoding="utf-8") as f:
                    for line in f:
                        try:
                            t = json.loads(line).get("teammate")
                        except Exception:
                            continue
                        if isinstance(t, str) and t:
                            hist.add(t)
            except Exception:
                pass
    hist.discard("team-lead")
    return hist


TERMINAL_STATUS = {
    "shutdown", "shutdown_request", "shutdown_approved", "completed",
    "complete", "done", "terminated", "dead", "exited", "killed", "removed",
    "gone",
}


def _roster_members(teams_dir, session_id):
    if not session_id:
        return []
    p = os.path.join(teams_dir, "session-" + session_id[:8], "config.json")
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f).get("members") or []
    except Exception:
        return []


def live_roles(teams_dir, session_id):
    """Roles with a teammate running RIGHT NOW, or None if unknowable.

    NOT MONOTONIC, and that is why nothing blocks on it. A teammate completes,
    and the set shrinks; the existing agent-name check blocks precisely because
    its ground truth only ever grows. This answers the question "is building it
    NOW" actually asks, and it is REPORTED rather than enforced until its false
    -positive rate has been measured on real traffic -- which it cannot be
    today, because past rosters are not retained.
    """
    members = _roster_members(teams_dir, session_id)
    if not members:
        return None
    live = set()
    for m in members:
        name = str(m.get("name") or "")
        role = str(m.get("agentType") or "") or name.split("-")[0]
        if not role or role == "team-lead" or name == "team-lead":
            continue
        cwd = str(m.get("cwd") or "")
        if "/.claude/worktrees/" in cwd:
            if os.path.isdir(cwd):
                live.add(role)
            continue
        if str(m.get("status") or "").lower() in TERMINAL_STATUS:
            continue
        live.add(role)
    return live


def repo_roots(entity_root, extra):
    """Repositories whose object DBs a SHA may legitimately live in.

    The entity itself, its siblings (an orchestrator routinely cites commits in
    a neighboring checkout), and anything the entity's config names. Bounded
    and cheap; a wider set only makes the gate quieter.
    """
    roots, seen = [], set()

    def add(p):
        if p and os.path.isdir(p) and p not in seen:
            if os.path.exists(os.path.join(p, ".git")):
                seen.add(p)
                roots.append(p)

    add(entity_root)
    parent = os.path.dirname(os.path.abspath(entity_root))
    try:
        for d in sorted(os.listdir(parent))[:60]:
            add(os.path.join(parent, d))
    except OSError:
        pass
    for p in (extra or "").split():
        add(os.path.expanduser(p))
    return roots


def resolve_shas(shas, roots):
    """Return the subset that names a real object in at least one repository."""
    found = set()
    for root in roots:
        todo = [s for s in shas if s not in found]
        if not todo:
            break
        try:
            p = subprocess.run(
                ["git", "-C", root, "cat-file", "--batch-check"],
                input="\n".join(todo) + "\n",
                capture_output=True, text=True, timeout=10,
            )
        except Exception:
            continue  # fail OPEN: a resolver error never invents a violation
        # --batch-check emits one line per input, in order. A missing object
        # echoes the INPUT token; a resolved one echoes the FULL oid, so pair
        # by position rather than by the first column.
        for tok, line in zip(todo, p.stdout.splitlines()):
            if "missing" not in line.split():
                found.add(tok)
    return found


def resolve_path(tok, bases):
    if tok.startswith("~"):
        return os.path.exists(os.path.expanduser(tok))
    if tok.startswith("/"):
        return os.path.exists(tok)
    for base in bases:
        if os.path.exists(os.path.join(base, tok)):
            return True
        if os.path.exists(os.path.join(base, "engine", tok)):
            return True
    return False


# --------------------------------------------------------------------------
# the turn's own tool traffic (grounding)
# --------------------------------------------------------------------------

def _flatten(content):
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                parts.append(b.get("text", ""))
            elif b.get("type") == "tool_use":
                parts.append(json.dumps(b.get("input", {})))
            elif b.get("type") == "tool_result":
                parts.append(_flatten(b.get("content")))
    return "\n".join(parts)


def read_transcript(path, prompt_id=None, limit_bytes=48 * 1024 * 1024):
    """Session-wide tool traffic, plus the tool-call names of THIS TURN ONLY.

    The two scopes are deliberately different and conflating them is a bug that
    silently disarms the reporting layer. GROUNDING wants everything the session
    ever observed, because a citation recalled from an earlier turn is still
    grounded. The "did this turn actually call Agent?" question wants only this
    turn, because the orchestrator spawns agents constantly and a session-wide
    answer is "yes" forever after the first spawn.

    The turn is scoped by promptId, using the binary's own semantic: "UUID
    correlating a user prompt with all subsequent events until the next prompt."
    Assistant records carry no promptId, so the turn is the file-order span from
    the first record bearing this prompt_id to the end of the file (at Stop time
    there is no next prompt yet).

    Absent a prompt_id the turn cannot be scoped, so the window opens at the
    first record and every tool call in the session counts as this turn's. That
    is the QUIET direction: the only consumer is "did this turn call Agent?",
    and answering yes suppresses a report. Scoping to nothing would answer no
    and manufacture one. When a reporting layer cannot tell, it says nothing.

    At Stop time the transcript already holds every tool_use and tool_result of
    the turn; it does NOT yet hold the final assistant text (verified against
    2.1.251 -- the last assistant record at Stop is the tool_use). That is why
    the message itself comes from last_assistant_message and only the tool
    traffic comes from here.
    """
    blob, tools = [], []
    # No prompt_id -> no turn boundary -> count everything (see docstring:
    # the wide answer is the quiet one for the only question asked of it).
    turn_started = prompt_id is None
    if not path or not os.path.isfile(path):
        return "", []
    try:
        if os.path.getsize(path) > limit_bytes:
            return "", []
    except OSError:
        return "", []
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
                if prompt_id and rec.get("promptId") == prompt_id:
                    turn_started = True
                msg = rec.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            if turn_started:
                                tools.append(b.get("name", ""))
                flat = _flatten(content)
                if flat:
                    blob.append(flat)
    except OSError:
        return "", []
    return "\n".join(blob), tools


# --------------------------------------------------------------------------
# reporting layer -- never blocks
# --------------------------------------------------------------------------

INFLIGHT_RE = re.compile(r"\b(dispatching|spawning|kicking off|launching)\b", re.I)


def prose_signal(message, turn_tools):
    """An in-flight dispatch claim in a turn with no Agent call.

    MEASURED AT 17% PRECISION on 418 real turns (1 true, 5 false). It is here
    to be LOGGED, never to block, and this docstring exists so nobody promotes
    it later without re-measuring. Every false positive was the orchestrator
    describing a past action, a negated action, or a past incident.
    """
    if not INFLIGHT_RE.search(message):
        return None
    if "Agent" in turn_tools:
        return None
    for s in re.split(r"(?<=[.!?])\s+", message):
        if INFLIGHT_RE.search(s):
            return s.strip()[:300]
    return None


def nameless_dispatch(message, prose):
    """The prose signal fired and the message named no agent identifier.

    MEASURED AND REJECTED AS A GATE. Over 4,134 real turns (3,532 with a final
    message) the prose signal fired 30 times and 29 of those named nobody, so
    this refinement removes ONE HIT IN THIRTY -- it is not a filter. Hand-
    adjudicating the 29: 3 true, 1 borderline, 25 false, i.e. 10.3% precision
    against the 17% it was proposed to replace.

    The reason is structural rather than tunable: the prose signal's false
    positives are negations ("I'm not dispatching anything"), quotations of
    this very header, past tense ("spawning the duplicate at all") and
    hypotheticals -- and NONE OF THOSE NAME AN AGENT EITHER. "Names nobody" and
    "is a false alarm" are very nearly the same set.

    Kept as a report, with the number in this docstring, so nobody promotes it
    later without re-measuring.
    """
    return bool(prose and not AGENT_RE.search(message))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # unparseable payload never wedges turn-end

    if payload.get("stop_hook_active"):
        # Already blocked once this turn. The binary caps repeats
        # (CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) but a gate that re-blocks its own
        # retry is a gate that can strand a session, so it stands down itself.
        return 0

    message = payload.get("last_assistant_message") or ""
    if not message.strip():
        return 0

    entity_root = os.environ.get("RICHOS_CLAIMS_ENTITY_ROOT") or payload.get("cwd") or os.getcwd()
    teams_dir = os.environ.get("RICHOS_CLAIMS_TEAMS_DIR") or os.path.expanduser("~/.claude/teams")
    extra_repos = os.environ.get("RICHOS_CLAIMS_EXTRA_REPOS", "")
    session_id = payload.get("session_id") or ""

    blob, turn_tools = read_transcript(payload.get("transcript_path"),
                                       payload.get("prompt_id"))

    names = agent_names(message)
    shas = sha_claims(message)
    paths = path_claims(message)
    roles = roster_roles(entity_root, teams_dir, session_id)
    rclaims = role_claims(message, roles)

    # --- BLOCKING: agent names ---------------------------------------------
    # Inert unless THIS session's team directory exists. Absent ground truth
    # cannot prove absence, and a guard that guesses is not a guard.
    unresolved_names = []
    names_evaluable = bool(session_id) and os.path.isdir(
        os.path.join(teams_dir, "session-" + session_id[:8])
    )
    hist = name_history(teams_dir) if names_evaluable else set()
    if names_evaluable and names:
        for n in names:
            if n not in hist and n not in blob:
                unresolved_names.append(n)

    # --- BLOCKING: a bare-role in-flight claim about a role NEVER DISPATCHED -
    # Same ground truth, same monotonicity, same zero-false-positive argument
    # as the name check above: the ledger only ever grows, so "no agent of this
    # role has ever been spawned in this session" cannot become false later.
    #
    # It is deliberately the NARROW half. Over 3,532 real messages it fires
    # ZERO times -- every bare-role claim in the corpus had a prior spawn of
    # that role -- so it ships costing nothing and guarding the case where a
    # role is named that was never dispatched at all. It does NOT catch the
    # 2026-08-31 failure, and that is stated rather than glossed: `Zach is
    # building it now` was false, but `zach-opus-uici1` had been spawned in
    # that same session hours earlier, so the monotonic test passes it. The
    # test that catches it is liveness, which is not monotonic and therefore
    # reports instead.
    #
    # Suppressed entirely when the message names an identifier (then the name
    # check above is the authority) or when this turn actually called Agent.
    undispatched_roles = []
    stale_roles = []
    if names_evaluable and rclaims and not names and "Agent" not in turn_tools:
        live = live_roles(teams_dir, session_id)
        for role, span in rclaims:
            ever = any(n.startswith(role + "-") for n in hist) or (role + "-") in blob
            if not ever:
                undispatched_roles.append((role, span))
            elif live is not None and role not in live:
                stale_roles.append((role, span))

    # --- BLOCKING: commit SHAs ---------------------------------------------
    unresolved_shas = []
    if shas:
        roots = repo_roots(entity_root, extra_repos)
        if roots:
            live = resolve_shas(shas, roots)
            for s in shas:
                if s not in live and s not in blob:
                    unresolved_shas.append(s)

    # --- REPORTING: paths and prose ----------------------------------------
    bases = [entity_root] + [os.path.dirname(os.path.abspath(entity_root))]
    bases += repo_roots(entity_root, extra_repos)
    unresolved_paths = []
    for p in paths:
        if resolve_path(p, bases):
            continue
        base = os.path.basename(p.rstrip("/"))
        if p in blob or (base and base in blob):
            continue
        unresolved_paths.append(p)
    prose = prose_signal(message, turn_tools)
    nameless = nameless_dispatch(message, prose)

    # --- observation record -------------------------------------------------
    # Written for EVERY turn, blocked or not, so the reporting layer is a record
    # rather than a rumour. Identifiers only -- never the message, never the
    # operator's words. This file is state, not source.
    record = {
        "session": session_id,
        "prompt_id": payload.get("prompt_id"),
        "tokens": {"name": len(names), "sha": len(shas), "path": len(paths)},
        "unresolved": {
            "name": unresolved_names,
            "sha": unresolved_shas,
            "path": unresolved_paths,
        },
        "names_evaluable": names_evaluable,
        "prose_signal": prose,
        "nameless_dispatch": nameless,
        "role_claims": [r for r, _ in rclaims],
        "undispatched_roles": [r for r, _ in undispatched_roles],
        "stale_roles": [r for r, _ in stale_roles],
        "verdict": "block" if (unresolved_names or unresolved_shas
                               or undispatched_roles) else "pass",
    }
    try:
        state = os.path.join(entity_root, ".claude", "state")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "claim-checks.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass  # the log is a convenience; losing it never changes the verdict

    # --- verdict ------------------------------------------------------------
    if not (unresolved_names or unresolved_shas or undispatched_roles):
        if unresolved_paths or prose or stale_roles:
            lines = ["=== claim check: PASSED, with observations (not blocking) ==="]
            for p in unresolved_paths:
                lines.append("  path cited but unresolved and ungrounded: %s" % p)
            for role, span in stale_roles:
                lines.append("  in-flight claim about a teammate that is NOT currently running:")
                lines.append("    \"%s\" -- no live %s in this session's roster." % (span, role))
                lines.append("    Name the agent (%s-<model>-<id>) or put the sentence in the past tense." % role)
            if prose:
                lines.append("  in-flight dispatch claim with no Agent call this turn:")
                lines.append("    %s" % prose)
                lines.append("  (this signal measures 17% precision -- it is logged, never enforced)")
                if nameless:
                    lines.append("  ...and it named no agent identifier (10.3% precision -- also never enforced)")
            lines.append("  record: .claude/state/claim-checks.jsonl")
            sys.stderr.write("\n".join(lines) + "\n")
        return 0

    out = ["=== UNRESOLVED IDENTIFIER IN THE FINAL MESSAGE — TURN BLOCKED ==="]
    if unresolved_names:
        out.append("")
        out.append("  Agent name(s) named in your reply that were never spawned:")
        for n in unresolved_names:
            out.append("      %s" % n)
        out.append("")
        out.append("  The spawned-names ledger only ever grows, and only an Agent call")
        out.append("  that actually executed writes to it. So this name has no spawn")
        out.append("  behind it. Either make the call now, or remove the name — a")
        out.append("  specific identifier in a report is a claim that it exists.")
    if unresolved_shas:
        out.append("")
        out.append("  Commit SHA(s) cited that name no object in any repository here,")
        out.append("  and that never appeared in this session's tool output:")
        for s in unresolved_shas:
            out.append("      %s" % s)
        out.append("")
        out.append("  Verify with `git cat-file -e <sha>` and cite the real one, or")
        out.append("  drop the citation. An unverifiable SHA in a report makes every")
        out.append("  other SHA in the report worth re-checking.")
    if undispatched_roles:
        out.append("")
        out.append("  You said a teammate is working, and named a ROLE rather than an agent:")
        for role, span in undispatched_roles:
            out.append("      \"%s\"" % span)
        out.append("")
        out.append("  No agent of that role has been spawned in this session at all, so")
        out.append("  there is nobody the sentence could be about. The ledger only grows")
        out.append("  and only a real Agent call writes to it, so this cannot be a stale")
        out.append("  reading.")
        out.append("")
        out.append("  Make the dispatch now, or name the agent in the checkable form")
        out.append("  (<role>-<model>-<identifier>) so the claim resolves against the")
        out.append("  roster instead of against a word.")
    out.append("")
    out.append("  Fix the reply and finish the turn. Do not weaken or unwire this hook.")
    out.append("(hook: scripts/hooks/guard-unresolved-claims.sh)")
    sys.stderr.write("\n".join(out) + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
