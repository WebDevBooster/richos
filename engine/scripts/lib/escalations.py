#!/usr/bin/env python3
"""escalations.py — AN ESCALATION A TEAMMATE WRITES CANNOT QUIETLY FAIL TO ARRIVE.

Read scripts/lib/escalations.sh for the wiring. This file is the mechanism, and
the mechanism has to be exact and testable without a session.

===========================================================================
THE FAILURE THIS EXISTS TO REMOVE
===========================================================================
On 2026-09-02 two teammates finished their work and each wrote a `BLOCKED.md`
recording that a premise in its brief was contradicted by evidence. NEITHER WAS
A STALL. Both were right to write one. They were found on 2026-09-04 by a
worktree cleanup, because somebody was counting directories.

The mailbox is measured at roughly 50% loss and doctrine forbids it carrying
load-bearing signal, so a FILE was chosen as the durable substrate instead. It
is durable in exactly the wrong direction: it survives perfectly and is read by
nobody. An escalation written as a file on a teammate's own branch is visible
only to whoever merges that branch — and a teammate whose branch is never
landed takes its escalation with it.

Three facts shaped everything below:

  1. THE ROOT IS CLOSED. Both wrote to the repository root, which is nine
     entries by permanent CEO ruling (ceo-decisions.md 27). The same escalation
     today would be refused at the write with nowhere obvious to go. That
     ruling names `docs/verification/` as where a block record belongs, so the
     record file goes there and never at a root.

  2. A TEAMMATE CANNOT SEE WHETHER ITS BRANCH WAS LANDED. It finishes; the
     merge happens later or never. So DELIVERY MUST NOT DEPEND ON ANYTHING THE
     TEAMMATE DOES AFTER WRITING, and it must not depend on a merge at all.

  3. THE DURABLE LEDGERS ALREADY REACH THE LEAD WITHOUT A MERGE. That is the
     property to copy, and it is the one this ledger has.

===========================================================================
WHY A LEDGER AND NOT A SECOND MAILBOX — the alternatives, and why each loses
===========================================================================
  THE EXISTING EVENT LOGS (idle-events.jsonl / task-events.jsonl) — REJECTED
    as the carrier, though they were the first place to look and the row said
    so. They are written BY HOOKS from harness payloads; there is no field a
    teammate can put its own words in, and nothing in the payload is authored
    by the teammate at all. Piggybacking would mean a hook lifting a file out
    of the worktree at TeammateIdle — which re-introduces both defects at once:
    it fires only if the teammate idles cleanly, and it reads a path that the
    reaper may already have removed.

  THE MAILBOX (SendMessage) — REJECTED as the carrier and KEPT as the doorbell.
    Half of what crosses it is lost. It stays in the protocol because a doorbell
    that sometimes rings is strictly better than none, and it now costs nothing:
    the ledger row is written first and the message is advisory.

  A FILE IN THE WORKTREE — KEPT as the RECORD and demoted from the delivery
    path. It is genuinely useful (it lands with the branch, it is readable by a
    human opening the worktree, and 27 says a block record belongs under
    `docs/verification/`) and it is genuinely NOT a delivery mechanism.

  A NEW MAILBOX — REFUSED outright. This is a LEDGER: append-only, written by
    the raiser, read by a CHECK rather than delivered to a reader, and closed by
    an acknowledgement row rather than by being consumed. It has one file, one
    writer path, and two readers that both call this module. Two ledgers written
    by one writer and read by nobody is how the waiver count reached 251 on
    2026-09-02; there is exactly one here.

===========================================================================
WHERE IT LIVES, AND WHY NOT IN THE SESSION TEAM DIRECTORY
===========================================================================
    ~/.claude/state/escalations.jsonl

OUTSIDE EVERY REPOSITORY, EVERY WORKTREE AND EVERY SESSION DIRECTORY — the same
substrate the worktree ownership ledger already uses, for the same reason.

The session team directory (<teams>/session-<first8>/) was the obvious home and
it is wrong here, for a reason the original failure demonstrates: THE
ESCALATIONS SAT FOR TWO DAYS, ACROSS SESSIONS. A ledger scoped to a session
dies with the session that raised it, and the sessions that follow — the ones
that would have found it — would each start with an empty world. A per-session
ledger would have hidden this defect rather than fixed it.

Repository scoping is refused for the same class of reason. A femcboost seat
landing work in richos worktrees is the NORMAL shape of this operation, not an
edge; a notice that only reported escalations raised in the seat's own
repository would hide the common case. Every outstanding escalation is
reported, wherever it was raised. The volume that justifies this: two in a week.

===========================================================================
WHAT AN ESCALATION IS, AND THE FIELD THAT SEPARATES IT FROM A STALL
===========================================================================
`state` is REQUIRED, and it is the field that stops this mechanism teaching
teammates not to raise escalations:

  work-complete  The work is DONE. This is a record of something the lead must
                 know, not a request to be unblocked. BOTH of the originals
                 were this, and both said so explicitly. A mechanism that read
                 every escalation as a failure would have punished them for
                 being right.
  proceeding     Raised, and still working on everything that does not depend
                 on the answer. The doctrine's default.
  stopped        The whole task depends on the answer and work has stopped.
                 The only state that is a stall, and the only one the notices
                 frame as blocking.

`for` says who the answer belongs to — `lead` (default) or `ceo`. The two
originals were addressed to the CEO, which is exactly why nobody in between
felt they were theirs to act on. Naming the audience makes the lead's job
explicit: route it or answer it, but not neither.

`question` is REQUIRED and is the smallest question that would unblock. A
record with no question is a note; there is nothing to acknowledge and nothing
would ever close it.

===========================================================================
IDENTITY, AND WHY IT IS DERIVED
===========================================================================
    esc-<UTC timestamp, compact>-<first 8 hex of sha256(teammate|title|worktree)>

Time-ordered, greppable, unique per (teammate, title, worktree) per second, and
typed by nobody. Raising the same escalation twice produces two ids and two
rows on purpose — a duplicate is visible, and de-duplicating would mean
deciding that two teammates' words are the same thing, which is a judgment.

===========================================================================
AGE BUCKETS — why an unacknowledged escalation gets LOUDER
===========================================================================
The turn-end notice is state-change de-duplicated, because a line repeated
under every turn is a line the eye is trained to skip. That de-duplication is
correct and it has one dangerous consequence: a condition that never changes is
announced once and then goes quiet forever. THE ORIGINALS SAT FOR TWO DAYS. A
mechanism that announced them once on day one and then fell silent would have
reproduced the defect with a better audit trail.

So the notice's state key carries an AGE BUCKET, and crossing a boundary is a
state change:

    0 -> 60 minutes   ONE RUN SEGMENT. The measured median teammate run segment
                      on this machine is 40 minutes (22 completed segments,
                      2026-08-30, the same measurement inflight.sh's ack
                      timeout is derived from). An escalation older than one
                      median segment has outlived the teammate that raised it,
                      so nobody is going to bring it up again.
    -> 24 hours       A calendar day. At this point "nobody has looked" has
                      stopped being a timing accident.
    -> 72 hours       Past the observed failure. The originals were found at
                      about 48 hours; a bucket at 72 fires on anything worse
                      than the incident that caused this file to exist.

Plus: the notice ledger is keyed per SESSION, so every new session re-announces
every outstanding escalation from scratch. Silence about an escalation is only
ever "still what I told you this session".

===========================================================================
TWO TEAMMATES RAISING AT ONCE
===========================================================================
Every write is a single `O_APPEND` write of one line, which the kernel serializes
against other appends to the same file — so the normal case needs no lock, and a
lock is refused deliberately: a lock file in `~/.claude/state/` left behind by a
killed agent would block the next teammate's escalation, and a mechanism whose
failure mode is "your escalation was not raised" is the defect being fixed.

The pathological case is a line longer than the pipe buffer interleaving with
another. It is not prevented; it is SURVIVED. A line that will not parse is
counted as malformed and REPORTED by every reader — never silently dropped —
because a half-corrupt ledger reporting as a clean empty world is how this
whole class of defect works.

===========================================================================
CLOSING ONE — an acknowledgement, never a deletion
===========================================================================
`ack` APPENDS a row; nothing is ever removed or rewritten. It requires a
DISPOSITION of at least 30 characters saying what was decided or done, because
an ack with no disposition is a dismissal wearing a ledger row — the exact
shape of the 251 waivers.

Anyone can write an ack. Nothing here checks that the disposition is TRUE; a
string match is not comprehension and this engine does not pretend otherwise.
What is engineered out is an escalation that is never seen AT ALL, which is the
failure that happened.
"""

import argparse
import getpass
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

# --- the two closed vocabularies ------------------------------------------
STATES = ("work-complete", "proceeding", "stopped")
AUDIENCES = ("lead", "ceo")

# Minutes. See the header: one median run segment, one day, past the incident.
AGE_BUCKETS = ((72 * 60, "72h"), (24 * 60, "24h"), (60, "1h"), (0, "new"))

MIN_QUESTION = 20
MIN_DISPOSITION = 30

STATE_GLOSS = {
    "work-complete": "work COMPLETE — a record, NOT a stall",
    "proceeding": "still working on everything that does not depend on this",
    "stopped": "STOPPED — the task depends on the answer",
}


def utcnow():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(s):
    """Parse an ISO timestamp written by this module, or return None.

    Tolerant on purpose: a row whose timestamp cannot be read must still be
    REPORTED (as unknown age), never dropped. A ledger reader that silently
    discards rows it does not understand is the defect one level down.
    """
    if not s:
        return None
    t = str(s).strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        d = datetime.fromisoformat(t)
    except Exception:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d


def ledger_path():
    """The ONE ledger. Overridable for tests and for a non-standard home."""
    p = os.environ.get("RICHOS_ESCALATION_LEDGER")
    if p:
        return os.path.abspath(os.path.expanduser(p))
    return os.path.join(os.path.expanduser("~"), ".claude", "state", "escalations.jsonl")


def read_rows(path=None):
    """Every row, in file order. A malformed line is SKIPPED and COUNTED.

    Returns (rows, malformed_count), or (None, 0) when the ledger exists and
    cannot be read. UNREADABLE IS NOT EMPTY: a reader that returned an empty
    list for an unreadable file would report a clean world over a broken one.
    """
    path = path or ledger_path()
    rows, bad = [], 0
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    bad += 1
                    continue
                if isinstance(d, dict):
                    rows.append(d)
                else:
                    bad += 1
    except FileNotFoundError:
        return [], 0
    except Exception:
        return None, 0
    return rows, bad


def append_row(row, path=None):
    """Append one row. RAISES on failure — a raise that silently no-ops is the
    whole defect, so the teammate has to be told its escalation did not land."""
    path = path or ledger_path()
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    return path


def make_id(when, teammate, title, worktree):
    stamp = when.strftime("%Y%m%dT%H%M%SZ")
    h = hashlib.sha256(
        ("%s|%s|%s" % (teammate or "", title or "", worktree or "")).encode("utf-8")
    ).hexdigest()[:8]
    return "esc-%s-%s" % (stamp, h)


def age_bucket(age_min):
    if age_min is None:
        return "unknown"
    for floor, name in AGE_BUCKETS:
        if age_min >= floor:
            return name
    return "new"


def outstanding(rows, now=None):
    """Every Escalation row with no matching EscalationAck, oldest first.

    Each carries `age_min` and `bucket`. An ack for an id that was never raised
    is IGNORED rather than treated as closing something — it closes nothing, and
    inventing a subject for it would be worse than leaving it in the file.
    """
    now = now or utcnow()
    acked = set()
    for r in rows:
        if r.get("event") == "EscalationAck" and r.get("id"):
            acked.add(str(r["id"]))
    out = []
    for r in rows:
        if r.get("event") != "Escalation":
            continue
        rid = str(r.get("id") or "")
        if not rid or rid in acked:
            continue
        raised = parse_iso(r.get("raised"))
        age = None
        if raised is not None:
            age = int((now - raised).total_seconds() // 60)
            if age < 0:
                age = 0
        e = dict(r)
        e["age_min"] = age
        e["bucket"] = age_bucket(age)
        out.append(e)
    out.sort(key=lambda e: str(e.get("raised") or ""))
    return out


def acks_for(rows, rid):
    return [r for r in rows
            if r.get("event") == "EscalationAck" and str(r.get("id")) == str(rid)]


def age_phrase(age_min):
    if age_min is None:
        return "age unknown"
    if age_min < 60:
        return "%dm old" % age_min
    if age_min < 24 * 60:
        return "%dh old" % (age_min // 60)
    return "%dd old" % (age_min // (24 * 60))


def _actor():
    try:
        return getpass.getuser()
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# RAISE
# ---------------------------------------------------------------------------
def build_row(args, when=None):
    when = when or utcnow()
    teammate = (args.teammate or "").strip()
    title = (args.title or "").strip()
    worktree = os.path.abspath(os.path.expanduser(args.worktree)) if args.worktree else ""
    return {
        "event": "Escalation",
        "id": make_id(when, teammate, title, worktree),
        "raised": iso(when),
        "teammate": teammate,
        "worktree": worktree,
        "branch": (args.branch or "").strip(),
        "repo": (args.repo or "").strip(),
        "head": (args.head or "").strip(),
        "state": args.state,
        "for": args.audience,
        "title": title,
        "question": (args.question or "").strip(),
        "tried": (args.tried or "").strip(),
        "meanwhile": (args.meanwhile or "").strip(),
        "record": (args.record or "").strip(),
        "session_id": (args.session or os.environ.get("CLAUDE_SESSION_ID", "") or "").strip(),
        "actor": _actor(),
    }


def validate_raise(args):
    problems = []
    if not (args.title or "").strip():
        problems.append("--title is required: one line naming what this is about.")
    if "\n" in (args.title or ""):
        problems.append("--title must be ONE line.")
    if args.state not in STATES:
        problems.append(
            "--state must be one of: %s. It is REQUIRED because it is what separates an "
            "escalation from a stall, and a channel that reads every escalation as a failure "
            "teaches teammates not to raise them." % " ".join(STATES))
    if args.audience not in AUDIENCES:
        problems.append("--for must be one of: %s" % " ".join(AUDIENCES))
    q = (args.question or "").strip()
    if len(q) < MIN_QUESTION:
        problems.append(
            "--question is %d characters; it needs at least %d. State the SMALLEST question "
            "that would unblock this. A record with no question can never be closed, because "
            "there is nothing to answer." % (len(q), MIN_QUESTION))
    return problems


# ---------------------------------------------------------------------------
# RENDERING — three audiences, one predicate
# ---------------------------------------------------------------------------
def render_text(rows, bad, now=None):
    """Full detail, for a human at a terminal and for `escalate.sh list`."""
    now = now or utcnow()
    out = ["escalation ledger: %s" % ledger_path()]
    if bad:
        out.append("  ** %d malformed line(s) in the ledger were skipped — read them by hand." % bad)
    live = outstanding(rows, now)
    total = len([r for r in rows if r.get("event") == "Escalation"])
    out.append("  %d raised in all, %d OUTSTANDING (raised and never acknowledged)."
               % (total, len(live)))
    if not live:
        out.append("")
        out.append("  Nothing outstanding.")
        return "\n".join(out)
    for e in live:
        out.append("")
        out.append("=== %s ===" % e["id"])
        out.append("  raised   : %s (%s)" % (e.get("raised", ""), age_phrase(e.get("age_min"))))
        out.append("  from     : %s" % (e.get("teammate") or "<unnamed>"))
        out.append("  state    : %s — %s"
                   % (e.get("state", ""), STATE_GLOSS.get(e.get("state", ""), "")))
        out.append("  for      : %s" % e.get("for", "lead"))
        out.append("  title    : %s" % e.get("title", ""))
        out.append("  question : %s" % e.get("question", ""))
        if e.get("tried"):
            out.append("  tried    : %s" % e["tried"])
        if e.get("meanwhile"):
            out.append("  meanwhile: %s" % e["meanwhile"])
        if e.get("worktree"):
            out.append("  worktree : %s (%s)" % (e["worktree"], e.get("branch") or "no branch"))
        if e.get("record"):
            out.append("  record   : %s" % e["record"])
            out.append("             ^^ IN THE TEAMMATE'S WORKTREE. It may never be merged;")
            out.append("                nothing here depends on it, and this row is the escalation.")
        out.append("  close it : escalate.sh ack %s --disposition \"<what you decided or did>\""
                   % e["id"])
    out.append("")
    out.append("  An outstanding escalation is announced at EVERY session start and gets LOUDER")
    out.append("  as it ages (1h / 24h / 72h). It goes quiet only when it is acknowledged.")
    return "\n".join(out)


def render_hook_summary(rows, bad, now=None):
    """Three lines for the Stop hook: state key, count, the one sentence.

    The wrapper owns none of these. A wrapper that composed its own sentence
    could tell the operator a different number from the one `escalate.sh list`
    prints, and two answers to one question is the failure this engine keeps
    finding in itself.
    """
    now = now or utcnow()
    live = outstanding(rows, now)
    if not live and not bad:
        return "clear\n0\n"
    key_parts = ["%s:%s" % (e["id"], e["bucket"]) for e in live]
    if bad:
        key_parts.append("malformed:%d" % bad)
    key = "outstanding:" + "|".join(key_parts)

    ceo = [e for e in live if e.get("for") == "ceo"]
    stopped = [e for e in live if e.get("state") == "stopped"]
    oldest = live[0] if live else None
    bits = []
    if len(live) == 1 and oldest is not None:
        bits.append("%s raised an escalation %s and NOTHING HAS ACKNOWLEDGED IT: \"%s\""
                    % (oldest.get("teammate") or "a teammate",
                       age_phrase(oldest.get("age_min")), oldest.get("title", "")))
    elif live:
        bits.append("%d ESCALATIONS ARE OUTSTANDING, the oldest %s from %s: \"%s\""
                    % (len(live), age_phrase(oldest.get("age_min")),
                       oldest.get("teammate") or "a teammate", oldest.get("title", "")))
    if ceo:
        bits.append("%d is for the CEO" % len(ceo) if len(ceo) == 1
                    else "%d are for the CEO" % len(ceo))
    if stopped:
        bits.append("%d has STOPPED work" % len(stopped) if len(stopped) == 1
                    else "%d have STOPPED work" % len(stopped))
    if live and not stopped:
        # Said EVERY time, because the opposite reading is what kills the channel.
        bits.append("none is a stall — the work is done or continuing")
    if bad:
        bits.append("%d ledger line(s) are unreadable" % bad)
    sentence = ("ESCALATION OUTSTANDING — " + "; ".join(bits)
                + ". Read it: escalate.sh list. Close it: escalate.sh ack <id> "
                  "--disposition \"...\".")
    return key + "\n" + str(len(live)) + "\n" + sentence + "\n"


def render_session_context(rows, bad, now=None):
    """Two blocks for SessionStart: the model's paragraph, then the operator's.

    Separated by a form feed — one character that cannot occur in either half,
    so the shell can split without a parser.
    """
    now = now or utcnow()
    live = outstanding(rows, now)
    if not live and not bad:
        return ""
    model = ["%d ESCALATION(S) RAISED BY TEAMMATES ARE OUTSTANDING — raised, never "
             "acknowledged, and waiting for you. This is the whole content; nothing has to be "
             "merged, and no worktree has to still exist, to read it." % len(live)]
    for e in live:
        model.append(
            "  [%s] %s (%s), from %s, state=%s (%s), for=%s. QUESTION: %s%s%s"
            % (e["id"], e.get("title", ""), age_phrase(e.get("age_min")),
               e.get("teammate") or "<unnamed>", e.get("state", ""),
               STATE_GLOSS.get(e.get("state", ""), ""), e.get("for", "lead"),
               e.get("question", ""),
               (" TRIED: %s" % e["tried"]) if e.get("tried") else "",
               (" MEANWHILE: %s" % e["meanwhile"]) if e.get("meanwhile") else ""))
    if any(e.get("for") == "ceo" for e in live):
        model.append("  At least one is addressed to the CEO. Routing it to him or deciding it "
                     "yourself are both answers; leaving it is not — that is the failure this "
                     "channel was built from.")
    if not any(e.get("state") == "stopped" for e in live):
        model.append("  NONE of these is a stall. Each teammate either finished its work or is "
                     "still working; they are records of something you must know, not requests "
                     "to be rescued.")
    if bad:
        model.append("  %d ledger line(s) could not be parsed and are NOT counted above." % bad)
    model.append("  Acknowledge each one you have dealt with: escalate.sh ack <id> "
                 "--disposition \"<what you decided or did>\". Until then it is announced at "
                 "every session start and gets louder at 1h, 24h and 72h.")
    if live:
        oldest = live[0]
        op = ("%d ESCALATION(S) OUTSTANDING — oldest %s from %s: \"%s\". escalate.sh list"
              % (len(live), age_phrase(oldest.get("age_min")),
                 oldest.get("teammate") or "a teammate", oldest.get("title", "")))
    else:
        op = "%d unreadable line(s) in the escalation ledger — escalate.sh list" % bad
    return "\n".join(model) + "\f" + op


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def cmd_raise(args):
    problems = validate_raise(args)
    if problems:
        for p in problems:
            sys.stderr.write("escalations: %s\n" % p)
        return 2
    row = build_row(args)
    try:
        path = append_row(row)
    except Exception as exc:
        sys.stderr.write(
            "escalations: COULD NOT WRITE THE LEDGER (%s: %s).\n"
            "  YOUR ESCALATION HAS NOT BEEN DELIVERED. Do not treat this as raised.\n"
            "  Put it verbatim in your final report and in your commit message, and say that\n"
            "  the ledger write failed — a raise that silently does nothing is the exact\n"
            "  defect this channel was built to remove.\n" % (type(exc).__name__, exc))
        return 2
    print(json.dumps({"id": row["id"], "ledger": path}))
    return 0


def cmd_ack(args):
    d = (args.disposition or "").strip()
    if len(d) < MIN_DISPOSITION:
        sys.stderr.write(
            "escalations: --disposition is %d characters; it needs at least %d. Say what you "
            "DECIDED or DID. An acknowledgement with no disposition is a dismissal wearing a "
            "ledger row.\n" % (len(d), MIN_DISPOSITION))
        return 2
    rows, bad = read_rows()
    if rows is None:
        sys.stderr.write("escalations: the ledger at %s could not be read.\n" % ledger_path())
        return 2
    live = dict((e["id"], e) for e in outstanding(rows))
    known = set(str(r.get("id")) for r in rows if r.get("event") == "Escalation")
    if args.id not in known:
        sys.stderr.write(
            "escalations: no escalation with id %r was ever raised. Run `escalate.sh list` — "
            "acknowledging an id that does not exist would record a decision about nothing.\n"
            % args.id)
        return 2
    if args.id not in live:
        sys.stderr.write("escalations: %s is already acknowledged. Nothing appended.\n" % args.id)
        return 1
    row = {
        "event": "EscalationAck",
        "id": args.id,
        "acked": iso(utcnow()),
        "disposition": d,
        "actor": _actor(),
        "session_id": (args.session or os.environ.get("CLAUDE_SESSION_ID", "") or "").strip(),
    }
    try:
        append_row(row)
    except Exception as exc:
        sys.stderr.write("escalations: could not append the ack (%s: %s).\n"
                         % (type(exc).__name__, exc))
        return 2
    print(json.dumps({"id": args.id, "acked": row["acked"]}))
    return 0


def cmd_list(args):
    rows, bad = read_rows()
    if rows is None:
        sys.stderr.write("escalations: the ledger at %s could not be read.\n" % ledger_path())
        return 2
    if args.format == "json":
        print(json.dumps({"ledger": ledger_path(), "malformed": bad,
                          "outstanding": outstanding(rows)}, indent=1))
    elif args.format == "hook-summary":
        sys.stdout.write(render_hook_summary(rows, bad))
    elif args.format == "session-context":
        sys.stdout.write(render_session_context(rows, bad))
    else:
        print(render_text(rows, bad))
    return 1 if outstanding(rows) else 0


def cmd_show(args):
    rows, bad = read_rows()
    if rows is None:
        sys.stderr.write("escalations: the ledger at %s could not be read.\n" % ledger_path())
        return 2
    hits = [r for r in rows if r.get("event") == "Escalation" and str(r.get("id")) == args.id]
    if not hits:
        sys.stderr.write("escalations: no escalation with id %r.\n" % args.id)
        return 2
    print(json.dumps(hits[-1], indent=1, ensure_ascii=False))
    for a in acks_for(rows, args.id):
        print("ACK %s by %s: %s"
              % (a.get("acked", ""), a.get("actor", ""), a.get("disposition", "")))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="escalations.py")
    sub = ap.add_subparsers(dest="cmd")

    r = sub.add_parser("raise")
    r.add_argument("--title", default="")
    r.add_argument("--state", default="")
    r.add_argument("--for", dest="audience", default="lead")
    r.add_argument("--question", default="")
    r.add_argument("--tried", default="")
    r.add_argument("--meanwhile", default="")
    r.add_argument("--teammate", default="")
    r.add_argument("--worktree", default="")
    r.add_argument("--branch", default="")
    r.add_argument("--repo", default="")
    r.add_argument("--head", default="")
    r.add_argument("--record", default="")
    r.add_argument("--session", default="")
    r.set_defaults(func=cmd_raise)

    a = sub.add_parser("ack")
    a.add_argument("--id", required=True)
    a.add_argument("--disposition", default="")
    a.add_argument("--session", default="")
    a.set_defaults(func=cmd_ack)

    l = sub.add_parser("list")
    l.add_argument("--format", default="text",
                   choices=("text", "json", "hook-summary", "session-context"))
    l.set_defaults(func=cmd_list)

    s = sub.add_parser("show")
    s.add_argument("--id", required=True)
    s.set_defaults(func=cmd_show)

    args = ap.parse_args(argv)
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
