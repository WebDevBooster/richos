#!/usr/bin/env python3
"""inflight.py — THE PREDICATE. Who is in flight, who is behind, who was told,
and who has proved they heard it.

===========================================================================
WHAT THIS ANSWERS, AND WHY IT IS ONE FILE
===========================================================================
Landing moves `main`. Every teammate still working was cut from an older base
and is now silently behind. `rich-lander/SKILL.md` §8b is the written step that
says to sweep them; this file is the machine underneath it, and it is a single
file for the reason `row-currency.py` is: a predicate kept in two copies is the
defect class this engine keeps finding in itself.

Four consumers, one predicate:

    scripts/hooks/guard-inflight-notify.sh   BLOCKS a push that leaves a live
                                             teammate behind and un-notified.
    scripts/hooks/notice-inflight-acks.sh    Stop-hook notice: notified, but
                                             no ack, past the timeout.
    scripts/inflight-notify.sh               the by-hand runner (status /
                                             check / waive / acks).
    scripts/inflight-ack.sh                  the teammate's ack writer, which
                                             uses only the ack-path rule here.

===========================================================================
THE THREE FACTS, AND WHERE EACH ONE COMES FROM
===========================================================================
1. WHO IS IN FLIGHT — `git worktree list --porcelain`, in the repository being
   landed. Not a roster, not the SendMessage agent list: a worktree is a thing
   on disk with a branch and a base, and it is the only in-flight record that
   survives the lead's context.

2. WHO WAS TOLD — an append-only ledger written by a PostToolUse[SendMessage]
   hook, in the LEAD's own execution, at the moment the tool call resolves.
   This is the same trick worker-updated-handoff.sh uses and it is the whole
   reason the send half can be guaranteed at all: the witness observes the
   SEND, not the delivery, so it is true even when the mailbox drops the
   message. The lander cannot satisfy it by remembering to write a file — the
   only way to produce the record is to actually call SendMessage.

   IT IS NOT FRAUD-PROOF, and that is stated rather than implied: anyone with
   Bash can append a line to a JSONL file. The failure being engineered out is
   FORGETTING, which is what happened twice on 2026-08-30. Fabrication is a
   different act and this guard does not pretend to stop it.

3. WHO HEARD IT — an artifact in the teammate's OWN worktree, written by the
   teammate. A reply the lead may never receive proves nothing to the lead; a
   file the lead can stat proves it, and it proves it after the session that
   sent the message is gone. See ack_status() for exactly which parts of that
   artifact a machine checks and which part it cannot.

AND, UNDERNEATH ALL THREE, WHO A TEAMMATE IS — scripts/lib/teammate-identity.py,
imported rather than re-derived. Facts 2 and 3 are joined by NAME, and until
2026-08-31 this file resolved that name from `worker-events.jsonl`'s
`agent_type`, which is the ROLE (`zach`), while the witness recorded
SendMessage's `to`, which is the mandatory unique name (`zach-opus-s1`). Two
notices that were genuinely sent, witnessed and logged were reported as
OWED-NO-NOTICE and waived through, because one half of the engine wrote `zach`
and the other wrote `zach-opus-s1`. There is now ONE definition of a teammate's
name and both halves import it.

===========================================================================
LIVENESS — TWO KINDS OF WORKTREE, TWO DIFFERENT ANSWERS
===========================================================================
NATIVE (`.claude/worktrees/agent-<id>`): the harness locks it while the agent
runs, and the lock line carries a pid. That is the authoritative signal the
rest of the engine already uses (remove-agent-worktree.sh). locked + live pid
= LIVE; locked + dead pid = stale lock, not live; unlocked = not live.

HAND-ROLLED (any other registered worktree — the shape this whole operation
actually runs in: /Users/alex/ab/richos-wt/<name>): NO LOCK IS EVER TAKEN, so
the lock signal says nothing at all. Absence of a lock here is absence of
evidence, and the doctrine is explicit that an agent is never inferred dead
from filesystem quiet. So a hand-rolled worktree is PRESUMED LIVE.

That presumption is deliberately the over-blocking direction, and it is bounded
by two things that cost the lander seconds rather than minutes: a worktree
whose branch is already contained in the tip is discharged automatically (it
has landed — there is nothing to tell it), and anything else can be waived with
a recorded reason. An unbounded presumption with no way out would be the
"guard that wedges the session" this was explicitly told not to build.

===========================================================================
WHAT IS OWED — AND WHY RELEVANCE IS NOT FILTERED
===========================================================================
A live worktree is owed a notice when the tip contains commits its base does
not. NOT "when the moved files overlap its own files".

That is not laziness, it is the second of the two failures §8b was written
from. The library agent did not TOUCH the twelve new design variations; it
CONSUMED them, and shipped 7 of 19 because nobody told it they existed. A
path-overlap filter would have cleared that agent as unaffected. Overlap is
computed and REPORTED, because it separates "will hit a merge conflict" from
"may be building on a stale fact", and the second is the one that needs a human
sentence rather than a diff. It is never used to excuse a notice.
"""

import json
import os
import re
import subprocess
import sys
import time

DEFAULT_ACK_TIMEOUT_MIN = 30


def _identity_module():
    """scripts/lib/teammate-identity.py — THE definition of a teammate's name.

    Loaded by path because the filename is hyphenated. If it is missing this
    predicate degrades to the role, which is exactly the 2026-08-31 defect, so
    the absence is RECORDED in the assessment rather than swallowed."""
    try:
        import importlib.util as ilu
        here = os.path.dirname(os.path.abspath(__file__))
        spec = ilu.spec_from_file_location(
            "teammate_identity", os.path.join(here, "teammate-identity.py"))
        mod = ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


IDENTITY = _identity_module()

# Tokens that carry no identity: the model alias in <role>-<model>-<id> names,
# and dates in hand-rolled worktree names. Stripped before name matching.
_NOISE_TOKENS = {"fable", "opus", "sonnet", "haiku", "wt", "worktree", "agent"}
_DATE_RE = re.compile(r"^\d{4}-?\d{2}-?\d{2}$")
_SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
_NATIVE_ID_RE = re.compile(r"^a(?P<name>[a-z0-9][a-z0-9-]*?)-[0-9a-f]{12,}$")

ACK_DIR_REL = os.path.join(".claude", "inflight-acks")


def norm(path):
    """A path in the one form two of these comparisons can agree on.

    macOS hands /var/folders/... to a caller and /private/var/folders/... back
    out of git, because /var is a symlink. abspath does not resolve that, so a
    waiver recorded against a worktree failed to match the same worktree ten
    lines later — caught by inflight-notify.test.sh case 5j, not by reading."""
    if not path:
        return ""
    return os.path.realpath(os.path.abspath(path)).rstrip("/")
ACK_IMPACTS = ("conflict", "stale-record", "grew-scope", "none")
ACK_MIN_DETAIL = 40


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------
def git(repo, *args, check=False):
    try:
        res = subprocess.run(
            ["git", "-C", repo] + list(args),
            capture_output=True, text=True, timeout=30,
        )
    except Exception as exc:
        if check:
            raise RuntimeError("git %s failed: %s" % (" ".join(args), exc))
        return ""
    if res.returncode != 0:
        if check:
            raise RuntimeError(
                "git %s exited %d: %s"
                % (" ".join(args), res.returncode, (res.stderr or "").strip()[:200])
            )
        return ""
    return res.stdout


def main_checkout(repo):
    """The TRUE main checkout for this repository, from any worktree inside it.

    Same resolution resolve-main-checkout.sh uses: --git-common-dir points at
    the main checkout's .git regardless of which worktree asked."""
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    if not common:
        return os.path.abspath(repo)
    return os.path.dirname(common.rstrip("/"))


def is_ancestor(repo, a, b):
    try:
        res = subprocess.run(
            ["git", "-C", repo, "merge-base", "--is-ancestor", a, b],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return False
    return res.returncode == 0


def list_worktrees(repo):
    """Parse `git worktree list --porcelain` into dicts.

    Fields per entry: path, head, branch, detached, locked (the raw lock line
    or None), prunable."""
    out = git(repo, "worktree", "list", "--porcelain")
    entries = []
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            if cur is not None:
                entries.append(cur)
            cur = {"path": line[len("worktree "):], "head": "", "branch": "",
                   "detached": False, "locked": None, "prunable": False}
        elif cur is None:
            continue
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):].strip()
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].strip().replace("refs/heads/", "", 1)
        elif line.startswith("detached"):
            cur["detached"] = True
        elif line.startswith("locked"):
            cur["locked"] = line
        elif line.startswith("prunable"):
            cur["prunable"] = True
    if cur is not None:
        entries.append(cur)
    return entries


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError):
        return False
    return True


# --------------------------------------------------------------------------
# identity
# --------------------------------------------------------------------------
def name_tokens(text, strip_digits=True):
    """Identity tokens of a teammate name or a worktree basename.

    strict (strip_digits=False):
        'zach-opus-ackguard1'       -> {'zach', 'ackguard1'}
    loose (strip_digits=True):
        'zach-opus-ackguard1'       -> {'zach', 'ackguard'}
        'zach-ackguard-2026-08-30'  -> {'zach', 'ackguard'}

    Dates and model aliases are dropped from both, because neither carries
    identity. The digits are the difference, and BOTH readings are needed:
    a hand-rolled worktree is named for a date while its teammate is named
    'ackguard1', so only the loose reading joins them — but this house's own
    naming rule turns 'mark-sonnet-f1' into 'mark-sonnet-f2' for the next
    teammate, and under the loose reading those two are the same person. That
    collision is not hypothetical; it is the convention. So the strict reading
    is tried first and the loose one only breaks a tie nothing else could."""
    text = (text or "").lower()
    text = re.sub(r"\d{4}-\d{2}-\d{2}", " ", text)
    parts = [p for p in re.split(r"[^a-z0-9]+", text) if p]
    toks = set()
    for p in parts:
        if _DATE_RE.match(p) or p.isdigit():
            continue
        if strip_digits:
            p = re.sub(r"\d+[a-z]?$", "", p)
        if len(p) < 3 or p in _NOISE_TOKENS:
            continue
        toks.add(p)
    return toks


def identity_index(teams_dir, transcript_path="", session_id=""):
    """The shared identity index, or an empty one that says why it is empty.

    Delegated in full to scripts/lib/teammate-identity.py. Kept as a wrapper so
    that a missing module degrades to "no names, and here is the reason"
    instead of silently reverting to the role — the failure mode this whole
    change exists to remove."""
    if IDENTITY is None:
        return {"names": {}, "sources": {}, "roles": {}, "spawned": [],
                "tried": ["scripts/lib/teammate-identity.py — MISSING, so no "
                          "exact name join was possible at all"],
                "found": []}
    try:
        return IDENTITY.identity_index(teams_dir, transcript_path, session_id)
    except Exception as exc:
        return {"names": {}, "sources": {}, "roles": {}, "spawned": [],
                "tried": ["scripts/lib/teammate-identity.py raised %s" % exc],
                "found": []}


def resolve_worktree_identity(wt_path, index):
    """(kind, agent_id, name, role, how) for a worktree path.

    NAME and ROLE are different fields and are never conflated again. `name` is
    the unique spawn name SendMessage addresses; `role` is the agent_type, and
    a role is not an address. When no exact source resolves the name, `name` is
    EMPTY and `how` says which sources were tried — an honest unresolved beats
    a role wearing a name's field, which is what produced two waivers on
    2026-08-31."""
    base = os.path.basename(wt_path.rstrip("/"))
    if base.startswith("agent-"):
        agent_id = base[len("agent-"):]
        name = index["names"].get(agent_id, "")
        role = index["roles"].get(agent_id, "")
        if name:
            return "native", agent_id, name, role, index["sources"].get(agent_id, "")
        # The agent id itself sometimes embeds the name (a<name>-<hex>). Exact,
        # and it costs nothing to read when the ledgers are silent.
        m = _NATIVE_ID_RE.match(agent_id)
        if m:
            return "native", agent_id, m.group("name"), role, "agent-id"
        return "native", agent_id, "", role, "unresolved"
    # A hand-rolled worktree IS named for its teammate by convention — that is
    # the only naming rule it has — so a basename of the enforced spawn shape
    # is the name, not a guess about one.
    if IDENTITY is not None and IDENTITY.looks_like_teammate_name(base):
        return "hand-rolled", "", base, IDENTITY.role_of(base), "worktree basename"
    return "hand-rolled", "", "", "", "token-match"


def credit_notices(worktrees, notices, tip, index=None):
    """Attach each notice to at most ONE live worktree.

    THE ADDRESS IS THE JOIN. A notice records who it was addressed to; a
    worktree resolves to the set of things that address it (its unique spawn
    name, its agent id, its directory). Equality between the two is the whole
    rule, and it is exact.

    The witness now also records `to_agent_id` — resolved at send time, in the
    lead's own execution, from the same identity module — so the first reading
    does not depend on the debt side being able to resolve the name at all.
    Two independent exact paths to the same fact; either one suffices.

    THE ADDRESS BOOK HAS TWO ENTRIES PER TEAMMATE, because SendMessage takes
    two forms and both are legal: the unique spawn name, and — its own
    documentation says so, "use the raw agentId when the agent has no name" —
    the bare agent id. The lead used the SECOND form on 2026-09-01, and the
    fixed guard immediately reported OWED-NO-NOTICE against a notice that had
    been sent, witnessed and logged, because a HAND-ROLLED worktree in another
    repository has no agent id of its own to compare against. Same defect
    class, one layer over: the halves agreed about the teammate and disagreed
    about which of its two legal addresses counts.

    So the notice's recipient is expanded through the identity index BEFORE
    matching — an id to its name, a name to its id — and either form finds the
    same teammate. The expansion is the exact index, so it adds no guess.

    NO ROLE FALLBACK. `zach-opus-s1` is not credited to a worktree known only
    as `zach`: three Zachs ran at once on the day of the defect, and a
    role-prefix credit would report a teammate as told when a different
    teammate was told. When nothing resolves, the debt stands and the report
    names the sources that came up empty.

    AMBIGUITY CREDITS NOTHING — if a notice's recipient matches two live
    worktrees, neither is credited."""
    tip = (tip or "").lower()
    names = (index or {}).get("names", {}) or {}
    for wt in worktrees:
        wt["notice"] = None
    for note in notices:
        if not any(tip.startswith(tok) and len(tok) >= 7 for tok in note.get("sha_tokens", [])):
            continue
        to = note.get("to", "") or ""
        if not to:
            continue
        # 1. THE WITNESS'S OWN RESOLUTION, joined on agent id. Independent of
        #    whatever the debt side can resolve now.
        to_aid = (note.get("to_agent_id") or "").strip()
        if not to_aid and names and to in names:
            to_aid = to                      # addressed by raw agent id
        hits = [w for w in worktrees if to_aid and w.get("agent_id") == to_aid]
        # 2. The address set: unique spawn name, agent id, directory name —
        #    against BOTH legal forms of the recipient's address.
        if len(hits) != 1:
            forms = {to}
            if to_aid:
                forms.add(to_aid)
                forms.add("agent-" + to_aid)
                if names.get(to_aid):
                    forms.add(names[to_aid])
            hits = [w for w in worktrees
                    if forms & set(w.get("addresses", ()))]
        # 3/4. The token readings, unchanged, for names that predate the
        #    enforced <role>-<model>-<id> shape.
        if len(hits) != 1:
            strict = name_tokens(to, strip_digits=False)
            hits = [w for w in worktrees
                    if strict and len(strict & w["identity_tokens_strict"]) >= 2]
        if len(hits) != 1:
            loose = name_tokens(to)
            hits = [w for w in worktrees
                    if loose and len(loose & w["identity_tokens"]) >= 2]
        if len(hits) != 1:
            continue  # zero matches, or ambiguous — credit nothing
        wt = hits[0]
        prev = wt.get("notice")
        if prev is None or note.get("timestamp", "") > prev.get("timestamp", ""):
            wt["notice"] = note


# --------------------------------------------------------------------------
# ledgers
# --------------------------------------------------------------------------
def read_jsonl(path):
    rows = []
    if not path or not os.path.isfile(path):
        return rows
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        pass
    return rows


def notice_ledger_path(teams_dir):
    return os.path.join(teams_dir, "inflight-notices.jsonl") if teams_dir else ""


def waiver_ledger_path(teams_dir):
    return os.path.join(teams_dir, "inflight-waivers.jsonl") if teams_dir else ""


def sha_tokens(text):
    """Every 7-40 char lowercase hex run in a message body.

    Deliberately the ONLY thing extracted from a message besides its length and
    digest. A commit SHA is a public identifier, not a credential, so recording
    it does not reopen the privacy question worker-updated-handoff.sh settled
    when it refused to log message bodies."""
    return sorted({m.group(0) for m in _SHA_RE.finditer((text or "").lower())})


# --------------------------------------------------------------------------
# the ack artifact
# --------------------------------------------------------------------------
def ack_path(worktree, tip):
    return os.path.join(worktree, ACK_DIR_REL, "%s.ack" % (tip or "")[:12])


def parse_ack(path):
    fields = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except Exception:
        return None, ""
    for line in raw.splitlines():
        m = re.match(r"^([a-z_]+):\s*(.*)$", line.strip())
        if m:
            fields.setdefault(m.group(1), m.group(2).strip())
    return fields, raw


def ack_status(wt, tip, notices_ts, worker_updates, timeout_min):
    """Did this teammate prove it holds the new fact?

    TWO CHANNELS, AND THEY PROVE DIFFERENT AMOUNTS.

    PRIMARY — the artifact at <worktree>/.claude/inflight-acks/<tip12>.ack,
    written by the teammate (scripts/inflight-ack.sh writes it). Independent of
    the mailbox in both directions, survives the session, and the lead verifies
    it with stat + read. Machine-checkable:
        sha:     must equal the full 40-char tip EXACTLY. A teammate that does
                 not hold the new fact cannot produce it.
        impact:  one of conflict / stale-record / grew-scope / none — §8b's own
                 three questions plus "not affected", forcing a choice rather
                 than a nod.
        detail:  >= 40 characters of the teammate's own words.
        paths:   repo-relative paths, each of which must EXIST in that
                 teammate's worktree or in the moved changeset — the one field
                 that cannot be filled by copying the notice, because it is
                 about the teammate's own workspace.

    WHAT NO MACHINE HERE CAN CHECK, stated plainly rather than dressed up: the
    `detail` line is checked for LENGTH and for not being a copy of anything in
    the notice. Whether it is CORRECT — whether the teammate actually
    understood which of its assumptions broke — is comprehension, and a string
    match is not comprehension. The verifier prints `detail` and labels it
    HUMAN JUDGMENT REQUIRED. A guard that scored that line would be inventing a
    reading it did not do.

    SECONDARY — a witnessed reply: a WorkerUpdated row in worker-events.jsonl
    from this teammate, after the notice, with the tip's short SHA in its
    `summary`. That hook fires inside the SENDER's execution when its tool call
    resolves, so it witnesses the send even when delivery drops — a durable
    substrate, not a mailbox read. It is secondary because that log stores only
    the 200-character summary, so it can carry a token but never a restatement.
    It proves DELIVERY AND READING. It does not prove content."""
    tip = (tip or "").lower()
    short = tip[:12]
    path = ack_path(wt["path"], tip)
    out = {"state": "none", "verified": False, "problems": [], "detail": "",
           "path": path, "channel": "", "age_sec": None, "overdue": False}

    if os.path.isfile(path):
        fields, raw = parse_ack(path)
        out["state"] = "artifact"
        out["channel"] = "artifact"
        problems = []
        got_sha = (fields or {}).get("sha", "").lower()
        if got_sha != tip:
            problems.append(
                "sha: is %r, must be the full 40-char tip %r"
                % (got_sha or "<missing>", tip))
        impact = (fields or {}).get("impact", "")
        if impact not in ACK_IMPACTS:
            problems.append(
                "impact: is %r, must be one of %s"
                % (impact or "<missing>", "/".join(ACK_IMPACTS)))
        detail = (fields or {}).get("detail", "")
        if len(detail) < ACK_MIN_DETAIL:
            problems.append(
                "detail: %d chars, needs >= %d in the teammate's own words"
                % (len(detail), ACK_MIN_DETAIL))
        paths_field = (fields or {}).get("paths", "")
        if not paths_field:
            problems.append("paths: missing — list affected paths, or the word 'none'")
        elif paths_field.strip() != "none":
            moved = set(wt.get("moved_paths", []))
            for p in paths_field.split():
                if p in moved:
                    continue
                if os.path.exists(os.path.join(wt["path"], p)):
                    continue
                problems.append(
                    "paths: %r is neither in the moved changeset nor present in "
                    "this worktree — it cannot have been read off either" % p)
        out["problems"] = problems
        out["verified"] = not problems
        out["detail"] = detail
        try:
            out["age_sec"] = int(time.time() - os.path.getmtime(path))
        except Exception:
            pass
        return out

    for row in worker_updates:
        if row.get("agent_type") != wt.get("resolved_name"):
            continue
        if notices_ts and row.get("timestamp", "") <= notices_ts:
            continue
        summary = (row.get("summary") or "").lower()
        if short[:7] and short[:7] in summary:
            out["state"] = "witnessed"
            out["channel"] = "worker-events WorkerUpdated"
            out["verified"] = True
            out["detail"] = row.get("summary") or ""
            return out

    if notices_ts:
        try:
            sent = time.mktime(time.strptime(notices_ts[:19], "%Y-%m-%dT%H:%M:%S"))
            # The ledger writes UTC; compare in UTC.
            age = int(time.time() - (sent - time.timezone))
            out["age_sec"] = age
            out["overdue"] = age > timeout_min * 60
        except Exception:
            pass
    return out


# --------------------------------------------------------------------------
# the assessment
# --------------------------------------------------------------------------
def assess(repo, tip=None, teams_dir="", timeout_min=DEFAULT_ACK_TIMEOUT_MIN,
           session_id="", transcript_path=""):
    root = main_checkout(repo)
    if not tip:
        tip = git(root, "rev-parse", "HEAD").strip()
    tip = (tip or "").lower()

    # The team directory is resolved HERE when the caller did not name one, so
    # that the runner, the guard and the Stop notice cannot disagree about
    # which ledger they are talking about.
    teams_dir_source = os.environ.get("INFLIGHT_TEAMS_DIR_SOURCE") or "given by the caller"
    if not teams_dir and IDENTITY is not None:
        try:
            teams_dir, teams_dir_source = IDENTITY.resolve_teams_dir(session_id)
        except Exception:
            teams_dir, teams_dir_source = "", "resolution raised"

    notices = [r for r in read_jsonl(notice_ledger_path(teams_dir))
               if r.get("event") == "InflightNotice"]
    waivers = [r for r in read_jsonl(waiver_ledger_path(teams_dir))
               if r.get("event") == "InflightWaiver"]
    updates = [r for r in read_jsonl(os.path.join(teams_dir, "worker-events.jsonl"))
               if r.get("event") == "WorkerUpdated"] if teams_dir else []
    index = identity_index(teams_dir, transcript_path, session_id)

    result = {
        "repo": os.path.abspath(repo),
        "main_checkout": root,
        "tip": tip,
        "teams_dir": teams_dir,
        "teams_dir_source": teams_dir_source,
        "notice_ledger": notice_ledger_path(teams_dir),
        "waiver_ledger": waiver_ledger_path(teams_dir),
        "ack_timeout_min": timeout_min,
        "identity_sources_tried": index.get("tried", []),
        "identity_sources_found": index.get("found", []),
        "worktrees": [],
        "blocking": [],
        "unacked": [],
        "live_count": 0,
    }
    if not tip:
        result["error"] = "could not resolve a tip commit for %s" % repo
        return result

    for entry in list_worktrees(root):
        path = entry["path"]
        if norm(path) == norm(root):
            continue  # the main checkout is not a teammate
        kind, agent_id, name, role, how = resolve_worktree_identity(path, index)
        base = os.path.basename(path.rstrip("/"))
        # EVERY EXACT WAY THIS WORKTREE CAN BE ADDRESSED. A notice is credited
        # on equality with one of these and on nothing looser; the role is
        # deliberately absent, because a role is not an address.
        addresses = {a for a in (name, base, agent_id,
                                 ("agent-" + agent_id) if agent_id else "") if a}
        wt = {
            "path": path,
            "branch": entry["branch"],
            "head": entry["head"],
            "kind": kind,
            "agent_id": agent_id,
            "resolved_name": name,
            "role": role,
            "name_source": how,
            "addresses": sorted(addresses),
            "identity_tokens": name_tokens(name or base),
            "identity_tokens_strict": name_tokens(name or base, strip_digits=False),
            "present": os.path.isdir(path),
        }

        # --- liveness (see the module header) ---------------------------
        if kind == "native":
            lock = entry["locked"]
            if not lock:
                wt["liveness"] = "not-live (native worktree, unlocked)"
                wt["live"] = False
            else:
                m = re.search(r"\(pid\s+(\d+)", lock)
                if not m:
                    wt["liveness"] = "not-live (locked, but the lock line carries no pid)"
                    wt["live"] = False
                elif pid_alive(m.group(1)):
                    wt["liveness"] = "LIVE (locked, pid %s running)" % m.group(1)
                    wt["live"] = True
                else:
                    wt["liveness"] = "not-live (stale lock, pid %s is dead)" % m.group(1)
                    wt["live"] = False
        else:
            wt["liveness"] = "presumed LIVE (hand-rolled worktree — no lock is ever taken here, so quiet is not death)"
            wt["live"] = True
        if not wt["present"]:
            wt["liveness"] = "not-live (registered, but the directory is gone)"
            wt["live"] = False

        head = entry["head"] or wt["branch"]
        contained = bool(head) and is_ancestor(root, head, tip)
        wt["landed"] = contained
        wt["behind"] = bool(head) and not is_ancestor(root, tip, head)

        wt["base"] = ""
        wt["moved_shas"] = []
        wt["moved_paths"] = []
        wt["own_paths"] = []
        wt["overlap"] = []
        if wt["behind"] and head:
            base = git(root, "merge-base", tip, head).strip()
            wt["base"] = base
            if base:
                wt["moved_shas"] = git(root, "rev-list", "%s..%s" % (base, tip)).split()
                wt["moved_paths"] = sorted(set(
                    git(root, "diff", "--name-only", base, tip).split("\n")) - {""})
                wt["own_paths"] = sorted(set(
                    git(root, "diff", "--name-only", base, head).split("\n")) - {""})
                wt["overlap"] = sorted(set(wt["moved_paths"]) & set(wt["own_paths"]))

        result["worktrees"].append(wt)

    live = [w for w in result["worktrees"] if w["live"]]
    result["live_count"] = len(live)
    credit_notices(live, notices, tip, index)

    for wt in result["worktrees"]:
        wt.setdefault("notice", None)
        wt["waiver"] = None
        for w in waivers:
            if w.get("tip", "").lower() != tip:
                continue
            if norm(w.get("worktree", "")) == norm(wt["path"]):
                wt["waiver"] = w
        wt["identity_tokens"] = sorted(wt["identity_tokens"])
        wt["identity_tokens_strict"] = sorted(wt["identity_tokens_strict"])

        if not wt["live"]:
            wt["verdict"] = "NOT-LIVE"
        elif wt["landed"]:
            wt["verdict"] = "CLEAN-LANDED"
        elif not wt["behind"] or not wt["moved_shas"]:
            wt["verdict"] = "CLEAN-NOT-BEHIND"
        elif wt["waiver"]:
            wt["verdict"] = "WAIVED"
        elif not wt["notice"]:
            wt["verdict"] = "OWED-NO-NOTICE"
            result["blocking"].append(wt["path"])
        else:
            ack = ack_status(wt, tip, wt["notice"].get("timestamp", ""), updates, timeout_min)
            wt["ack"] = ack
            if ack["verified"]:
                wt["verdict"] = "NOTIFIED-ACKED"
            elif ack["state"] == "artifact":
                wt["verdict"] = "NOTIFIED-ACK-INVALID"
                result["unacked"].append(wt["path"])
            else:
                wt["verdict"] = "NOTIFIED-NO-ACK"
                result["unacked"].append(wt["path"])
        wt.setdefault("ack", {"state": "n/a", "verified": False, "problems": [],
                              "detail": "", "path": "", "channel": "",
                              "age_sec": None, "overdue": False})
    return result


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
def render_text(res):
    out = []
    a = out.append
    a("in-flight sweep — %s" % res["main_checkout"])
    a("  tip            : %s" % res["tip"])
    a("  ack timeout    : %s min" % res["ack_timeout_min"])
    a("  notice ledger  : %s" % (res["notice_ledger"] or "<no team dir resolved>"))
    a("  resolved by    : %s" % res.get("teams_dir_source", ""))
    a("  identity from  : %s"
      % ("; ".join(res.get("identity_sources_found") or [])
         or "NOTHING RESOLVED — sources tried: %s"
            % "; ".join(res.get("identity_sources_tried") or ["<none>"])))
    if res.get("error"):
        a("  ERROR: %s" % res["error"])
        return "\n".join(out)
    if not res["worktrees"]:
        a("  NO teammate worktrees registered — nothing is in flight, nothing is owed.")
        return "\n".join(out)
    for wt in res["worktrees"]:
        a("")
        a("  %-22s %s" % (wt["verdict"], wt["path"]))
        a("      branch     : %s @ %s" % (wt["branch"] or "(detached)", (wt["head"] or "")[:12]))
        a("      teammate   : %s (%s)%s"
          % (wt["resolved_name"] or "<unresolved>", wt["name_source"],
             ("   role: %s" % wt["role"]) if wt.get("role") else ""))
        if not wt["resolved_name"]:
            a("                   NO EXACT NAME JOIN. A notice is addressed to the")
            a("                   unique spawn name, so nothing can be credited to this")
            a("                   worktree until one of these resolves it:")
            for src in (res.get("identity_sources_tried") or []):
                a("                     - %s" % src)
        a("      liveness   : %s" % wt["liveness"])
        if wt["behind"] and wt["moved_shas"]:
            a("      base       : %s" % wt["base"][:12])
            a("      moved      : %d commit(s), %d path(s)%s"
              % (len(wt["moved_shas"]), len(wt["moved_paths"]),
                 ("; OVERLAPS %d of its own file(s): %s"
                  % (len(wt["overlap"]), " ".join(wt["overlap"][:6]))) if wt["overlap"] else ""))
        if wt.get("notice"):
            a("      notified   : %s  (to %r)" % (wt["notice"].get("timestamp", ""), wt["notice"].get("to", "")))
        if wt.get("waiver"):
            a("      WAIVED     : %s" % wt["waiver"].get("reason", ""))
        ack = wt.get("ack") or {}
        if ack.get("state") == "artifact":
            a("      ack        : %s  %s" % (ack["path"], "VERIFIED" if ack["verified"] else "INVALID"))
            for p in ack.get("problems", []):
                a("        - %s" % p)
            if ack.get("detail"):
                a("        detail (HUMAN JUDGMENT REQUIRED — no machine here reads it for correctness):")
                a("          %s" % ack["detail"])
        elif ack.get("state") == "witnessed":
            a("      ack        : witnessed reply (%s) — proves delivery+reading, NOT content" % ack["channel"])
        elif ack.get("state") == "none" and wt.get("notice"):
            age = ack.get("age_sec")
            a("      ack        : NONE%s" % (" — %d min since the notice%s"
              % (age // 60, " (OVERDUE)" if ack.get("overdue") else "") if age is not None else ""))
    a("")
    a("  live worktrees: %d   blocking: %d   notified-but-unacked: %d"
      % (res["live_count"], len(res["blocking"]), len(res["unacked"])))
    return "\n".join(out)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="inflight.py")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tip", default="")
    ap.add_argument("--teams-dir", default="")
    ap.add_argument("--timeout-min", type=int, default=DEFAULT_ACK_TIMEOUT_MIN)
    ap.add_argument("--session", default="")
    ap.add_argument("--transcript", default="")
    ap.add_argument("--format", choices=("json", "text"), default="text")
    args = ap.parse_args(argv)

    res = assess(args.repo, args.tip, args.teams_dir, args.timeout_min,
                 args.session, args.transcript)
    if args.format == "json":
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        print(render_text(res))
    if res.get("error"):
        return 2
    return 1 if res["blocking"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
