#!/usr/bin/env python3
"""Sage's reproductions for the call-window / recorded-target round, against ANY
scripts/lib/workspaces.py.

    python3 -B certification-sage-window-and-target-2026-09-12.probe.py \\
        <path-to-workspaces.py> [case ...]

Run it against `git show 84e12d32:engine/scripts/lib/workspaces.py` and against
the branch; the DIFFERENCE is the evidence. It imports no engine test file and
no other probe, and drives the library through the entry points the hooks use:

    PreToolUse  (matcherless)  guard-sealed-worktree.sh  -> barrier()
    PostToolUse (matcherless)  observe-created-refs.sh   -> observe()
    SubagentStart / PostToolUse[Agent] / SubagentStop    -> record_start /
                                                           bind_agent / record_end

FOUR CASES, each one a claim I was asked to rule on rather than a restatement of
the round's own probe:

  A  d2-harm-ended     The harm my D2 named, re-derived with the integration
                       branch RECORDED (which my round-3 fixtures never did):
                       a side branch created in a second, overlapping call of
                       the agent's own. The harm is `land()` reporting LANDED
                       over a commit that reached no integration branch with
                       NOTHING pending -- not the survival of the ref, which a
                       correct refusal leaves exactly where it is.

  B  escalation-stray  esc-20260912T112834Z-91a77eef, reproduced both ways: a
                       ref created while the repository has NO recorded
                       integration branch, after Rich records the branch and the
                       land succeeds. Named outside the conventions it is left
                       behind and nothing will come back for it; named `cc/...`
                       the point-3 sweep still finds it.

  C  ref-after-post    The gap the engineer DECLARED and did not fix: a ref
                       created after a call's PostToolUse and before the next
                       PreToolUse -- a backgrounded process outliving its call --
                       and the same ref created after the LAST Post, before the
                       end-of-run signal.

  D  rich-between-calls  Whether keying the window by the call WIDENS the
                       indistinguishable class: two windows open at the end of
                       the run are intersected ("the widest one decides"), so a
                       ref RICH cuts between the agent's two PreToolUse calls is
                       judged against the older window. Compare with 84e12d32,
                       where the second Pre overwrote the first and the same ref
                       was not attributed.

EVERYTHING IS SANDBOXED. HOME, CLAUDE_CONFIG_DIR, TMPDIR, GIT_CONFIG_GLOBAL and
RICHOS_WORKSPACES_DIR are redirected into a temporary directory removed at the
end; the operator's real registry, sessions and repositories are never read or
written. Exit 0 when every selected case holds, 1 otherwise.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

CASES = ["d2-harm-ended", "escalation-stray", "escalation-stray-cc", "ref-after-post",
         "rich-between-calls", "rich-out-of-order", "mismatched-ids",
         "two-bodies-of-work"]


def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-40s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib, record=""):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="sage-c4-"))
        os.environ["HOME"] = os.path.join(self.root, "home")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.root, "home", ".claude")
        os.environ["TMPDIR"] = os.path.join(self.root, "tmp")
        os.environ["RICHOS_WORKSPACES_DIR"] = os.path.join(self.root, "registry")
        os.environ.pop("RICHOS_SESSION_ID", None)
        os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
        os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        os.makedirs(os.environ["TMPDIR"])
        os.makedirs(os.environ["RICHOS_WORKSPACES_DIR"])
        gc = os.path.join(self.root, "home", ".gitconfig")
        with open(gc, "w") as f:
            f.write("[user]\n\tname = probe\n\temail = probe@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = gc
        spec = importlib.util.spec_from_file_location("workspaces_under_test", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        self.sid = "sess-sage-c4444444"
        self.session(self.sid, self.entity)
        if record:
            # Point 14, the form the page asks for: Rich records the branch this
            # body of work integrates on, before the first agent is spawned.
            self.ws.record_integration(self.entity, record, "the probe's body of work", self.sid)

    def repo(self, name):
        p = os.path.join(self.root, name)
        os.makedirs(p)
        run("git", "init", "-q", "-b", "main", p)
        with open(os.path.join(p, "README"), "w") as f:
            f.write("x\n")
        run("git", "-C", p, "add", "-A")
        run("git", "-C", p, "commit", "-q", "-m", "init")
        return p

    def session(self, sid, cwd):
        pr = subprocess.Popen(["sleep", "600"])
        self.procs.append(pr)
        os.environ["RICHOS_SESSION_PID"] = str(pr.pid)
        time.sleep(0.05)
        self.ws.record_session_start(sid, cwd)

    def close(self):
        for pr in self.procs:
            try:
                pr.kill()
                pr.wait()
            except OSError:
                pass
        shutil.rmtree(self.root, ignore_errors=True)

    # --- the entry points the hooks use ----------------------------------
    def spawn(self, name):
        self.ws.register_spawn({"session_id": self.sid, "tool_use_id": "tu-" + name,
                                "tool_name": "Agent",
                                "tool_input": {"name": name, "subagent_type": "zach",
                                               "prompt": "do it\n", "isolation": "worktree"}},
                               self.entity)
        aid = "a" + name.replace("-", "")[:12] + "0000"
        npath = os.path.join(self.entity, ".claude", "worktrees", "agent-" + aid)
        run("git", "-C", self.entity, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
        self.ws.record_start(self.sid, aid, npath, "zach")
        self.ws.bind_agent(self.sid, "tu-" + name, aid, self.entity)
        return aid, npath

    def pre(self, aid, call=""):
        payload = {"session_id": self.sid, "agent_id": aid}
        if call:
            payload["tool_use_id"] = call
        return self.ws.barrier(payload)

    def post(self, aid, call=""):
        if not hasattr(self.ws, "observe"):
            return []
        payload = {"session_id": self.sid, "agent_id": aid,
                   "hook_event_name": "PostToolUse", "tool_name": "Bash"}
        if call:
            payload["tool_use_id"] = call
        return self.ws.observe(payload)

    def call(self, aid, c=""):
        self.pre(aid, c)
        return self.post(aid, c)

    def commit(self, path, fname):
        with open(os.path.join(path, fname), "w") as f:
            f.write("work\n")
        run("git", "-C", path, "add", fname)
        run("git", "-C", path, "commit", "-q", "-m", "work " + fname)

    def finish(self, aid):
        self.ws.record_end(self.sid, aid, "SubagentStop")

    def rec(self, name):
        return self.ws.load_agent(self.ws.named_key(self.sid, name)) or {}

    def created(self, name):
        return sorted(b for _r, b in (tuple(x) for x in (self.rec(name).get("created_branches") or [])))

    def branches(self, repo):
        return sorted(run("git", "-C", repo, "for-each-ref", "--format=%(refname:short)",
                          "refs/heads").split())

    def land(self, name):
        try:
            self.ws.land(name, self.sid)
            return "landed"
        except Exception as e:                                  # SpecError, by design
            return "REFUSED: %s" % e

    def pending(self):
        return sorted(i["name"] for i in self.ws.pending(self.sid, self.entity, scan=True))

    def events(self, kind):
        p = os.path.join(os.environ["RICHOS_WORKSPACES_DIR"], "events.jsonl")
        if not os.path.exists(p):
            return []
        rows = []
        for line in open(p):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") == kind:
                rows.append(e)
        return rows


# ---------------------------------------------------------------------------
# A — the harm D2 named, judged on the harm and not on my old predicate
# ---------------------------------------------------------------------------
def case_d2_harm_ended(s):
    """A. Side branch created in a second, overlapping call of the agent's own."""
    aid, npath = s.spawn("zach-opus-h1")
    s.call(aid, "tu-warm")
    s.pre(aid, "tu-A")                                    # call A opens
    s.pre(aid, "tu-B")                                    # call B opens alongside
    s.post(aid, "tu-A")                                   # A closes first
    run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
    s.commit(npath, "side.txt")                           # real work, inside call B
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-B")                                   # B closes
    side = run("git", "-C", s.entity, "rev-parse", "tmpwork")
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-h1")
    pend = s.pending()
    out("created_branches", s.created("zach-opus-h1"))
    out("land", verdict[:130])
    out("its side-branch commit in main",
        "work side.txt" in run("git", "-C", s.entity, "log", "--format=%s", "main"))
    out("pending after the land", pend)
    out("the side commit is still on tmpwork",
        side == run("git", "-C", s.entity, "rev-parse", "tmpwork"))
    # THE HARM, stated as the thing that must not happen: a land that reports
    # LANDED over a commit in no integration branch, with nothing pending.
    harm = verdict == "landed" and pend == []
    out("HARM (landed + nothing pending)", harm)
    if verdict.startswith("REFUSED"):
        run("git", "-C", s.entity, "merge", "-q", "--no-edit", "tmpwork")
        out("land once tmpwork is merged", s.land("zach-opus-h1"))
        out("branches after that land", s.branches(s.entity))
    return not harm


# ---------------------------------------------------------------------------
# B — the escalation, both ways
# ---------------------------------------------------------------------------
def _stray_in_unrecorded_repo(s, name, ref):
    aid, npath = s.spawn(name)
    s.call(aid, "tu-warm")
    s.commit(npath, name + ".txt")        # unique: a sibling's file is already in main
    s.pre(aid, "tu-1")
    run("git", "-C", npath, "branch", ref)                # created with NO record
    s.post(aid, "tu-1")
    out("created_branches while unrecorded", s.created(name))
    skipped = [e for e in s.events("attribution-skipped") if ref in (e.get("refs") or [])]
    out("attribution-skipped names it", bool(skipped))
    s.finish(aid)
    # Rich records the branch afterwards and the work reaches it
    s.ws.record_integration(s.entity, "main", "this body of work", s.sid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land after the branch is recorded", s.land(name)[:110])
    after = s.branches(s.entity)
    out("branches after the land", after)
    pend = s.pending()               # this RUNS the point-3 sweep, which may act
    out("pending (the point-3 sweep)", pend)
    after2 = s.branches(s.entity)
    out("branches after the sweep", after2)
    return ref in after2, pend


def case_escalation_stray(s):
    """B. A ref created while nothing is recorded, after the land succeeds."""
    left, pend = _stray_in_unrecorded_repo(s, "zach-opus-e1", "tmpwork")
    out("=> stray OUTSIDE the conventions left behind", left)
    out("=> and nobody will come back for it", pend == [])
    # The case HOLDS when the ref does NOT survive unaccounted for.
    return not left or pend != []


def case_escalation_stray_cc(s):
    """B2. The same, with the stray named cc/... : does the point-3 sweep find it?"""
    left, pend = _stray_in_unrecorded_repo(s, "zach-opus-e2", "cc/zach-opus-e2-side")
    out("=> stray named cc/... left behind", left)
    out("=> the sweep lists it as pending work", pend != [])
    return not left or pend != []


# ---------------------------------------------------------------------------
# C — the declared gap: a ref created outside every window
# ---------------------------------------------------------------------------
def case_ref_after_post(s):
    """C. A ref created after a Post and before the next Pre, and after the last Post."""
    aid, npath = s.spawn("zach-opus-g1")
    s.call(aid, "tu-1")
    s.commit(npath, "own.txt")
    s.pre(aid, "tu-2")
    s.post(aid, "tu-2")                                   # the call returns...
    run("git", "-C", npath, "branch", "bg-after-post")    # ...its child then cuts a ref
    s.pre(aid, "tu-3")                                    # the next call opens
    s.post(aid, "tu-3")
    out("created_branches (between two calls)", s.created("zach-opus-g1"))
    run("git", "-C", npath, "branch", "bg-after-last-post")
    s.finish(aid)                                         # end of run consumes all windows
    out("created_branches (after the last Post)", s.created("zach-opus-g1"))
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-g1")[:110])
    after = s.branches(s.entity)
    out("branches after the land", after)
    out("pending (the point-3 sweep)", s.pending())
    out("=> both refs left behind, attributed to nobody",
        "bg-after-post" in after and "bg-after-last-post" in after)
    return "bg-after-post" in after and "bg-after-last-post" in after


# ---------------------------------------------------------------------------
# D — does keying by the call widen the indistinguishable class?
# ---------------------------------------------------------------------------
def case_rich_between_calls(s):
    """D. A ref RICH cuts between the agent's two PreToolUse calls, no Post for either."""
    aid, npath = s.spawn("zach-opus-r1")
    s.call(aid, "tu-warm")
    s.commit(npath, "own.txt")
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    s.pre(aid, "tu-A")                                    # call A opens
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)   # RICH, between the two
    s.pre(aid, "tu-B")                                    # call B opens: it SEES rich/rescue
    s.finish(aid)                                         # neither Post arrived
    got = s.created("zach-opus-r1")
    out("created_branches at the end of the run", got)
    out("=> Rich's ref attributed to the agent", "rich/rescue" in got)
    look = os.path.join(s.root, "rich-look")             # Rich's OWN work, after the run
    run("git", "-C", s.entity, "worktree", "add", "-q", look, "rich/rescue")
    s.commit(look, "rich-own.txt")
    run("git", "-C", s.entity, "worktree", "remove", "--force", look)
    rich_tip = run("git", "-C", s.entity, "rev-parse", "rich/rescue")
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-r1")[:110])
    out("Rich's commit reachable from any branch",
        run("git", "-C", s.entity, "branch", "--contains", rich_tip, check=False).strip() or "(nothing)")
    d = s.ws.discard("zach-opus-r1", "the only other way to end pending work",
                     not_ceo_ordered="a probe, not the CEO's order", me=s.sid)
    out("discard recorded tips", sorted(t.split(":")[-1] for t in d["tips"]))
    after = s.branches(s.entity)
    out("branches after the discard", after)
    out("=> Rich's ref deleted with the agent", "rich/rescue" not in after)
    # The case "holds" when Rich's ref is NOT taken. It is reported either way.
    return "rich/rescue" not in got


def case_rich_out_of_order(s):
    """D2. The same, with both Posts arriving — the earlier call simply finishes last."""
    aid, npath = s.spawn("zach-opus-r2")
    s.call(aid, "tu-warm")
    s.commit(npath, "own.txt")
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    s.pre(aid, "tu-A")                                    # call A opens
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)    # RICH, between the two
    s.pre(aid, "tu-B")                                    # call B opens: it SEES rich/rescue
    s.post(aid, "tu-B")                                   # B finishes first
    out("created_branches after Post(B)", s.created("zach-opus-r2"))
    s.post(aid, "tu-A")                                   # A finishes last
    got = s.created("zach-opus-r2")
    out("created_branches after Post(A)", got)
    out("=> Rich's ref attributed to the agent", "rich/rescue" in got)
    return "rich/rescue" not in got


def case_mismatched_ids(s):
    """E. The Pre carries the platform's call id and the Post does not (or vice
    versa): what is lost, and does the end-of-run signal still catch it?"""
    aid, npath = s.spawn("zach-opus-m1")
    s.call(aid, "tu-warm")
    s.commit(npath, "own.txt")
    s.pre(aid, "tu-A")                                    # Pre KEYED
    run("git", "-C", npath, "branch", "keyed-pre-only")
    s.post(aid, "")                                       # Post UNKEYED
    out("after Pre(keyed) / Post(unkeyed)", s.created("zach-opus-m1"))
    s.pre(aid, "")                                        # Pre UNKEYED
    run("git", "-C", npath, "branch", "unkeyed-pre-only")
    s.post(aid, "tu-B")                                   # Post KEYED
    out("after Pre(unkeyed) / Post(keyed)", s.created("zach-opus-m1"))
    s.finish(aid)                                         # the end of the run
    got = s.created("zach-opus-m1")
    out("after the end-of-run signal", got)
    out("=> nothing is lost, only deferred",
        got == ["keyed-pre-only", "unkeyed-pre-only"])
    return got == ["keyed-pre-only", "unkeyed-pre-only"]


def case_two_bodies_of_work(s):
    """F. TWO bodies of work in ONE repository. The record is per REPOSITORY, and
    point 14 says the branch is the one THIS body of work integrates on."""
    run("git", "-C", s.entity, "branch", "dev/first")
    s.ws.record_integration(s.entity, "dev/first", "body of work ONE", s.sid)
    aid, npath = s.spawn("zach-opus-b1")                  # agent of body ONE
    s.call(aid, "tu-1")
    s.commit(npath, "one.txt")
    # A SECOND body of work starts in the same repository WHILE that agent is
    # still running -- which point 5 permits, because point 5 blocks new work
    # only for FINISHED work that is neither landed nor discarded -- and Rich
    # records its branch, exactly as point 14 requires of him.
    run("git", "-C", s.entity, "branch", "dev/second")
    s.ws.record_integration(s.entity, "dev/second", "body of work TWO", s.sid)
    out("the repository's record now says",
        s.ws.integration_record(s.entity)["branch"])
    s.finish(aid)                                         # body ONE's agent ends
    run("git", "-C", s.entity, "branch", "-f", "dev/first",
        run("git", "-C", npath, "rev-parse", "HEAD"))     # merged onto ITS branch
    out("its work is in dev/first", True)
    out("the superseded record is kept where nothing reads it",
        bool((s.ws.read_json(s.ws._integration_path()) or {}).get("history")))
    verdict = s.land("zach-opus-b1")
    out("land of the FIRST body's agent", verdict[:260])
    out("its workspace still on disk", os.path.exists(npath))
    out("pending (point 5 is blocked)", s.pending())
    return verdict == "landed"


RUNNERS = dict(zip(CASES, [case_d2_harm_ended, case_escalation_stray,
                           case_escalation_stray_cc, case_ref_after_post,
                           case_rich_between_calls, case_rich_out_of_order,
                           case_mismatched_ids, case_two_bodies_of_work]))
# A and D are about the window, so their repository has the branch recorded, as
# point 14 requires. B is about a repository that has NO record: that is its
# whole subject. C records it so the land is judged on the refs, not on a
# missing record.
RECORD = {"d2-harm-ended": "main", "escalation-stray": "", "escalation-stray-cc": "",
          "ref-after-post": "main", "rich-between-calls": "main",
          "rich-out-of-order": "main", "mismatched-ids": "main",
          "two-bodies-of-work": ""}


def main(argv):
    if not argv:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    lib = os.path.abspath(argv[0])
    print("workspaces.py under test: %s" % lib)
    wanted = argv[1:] or CASES
    unknown = [c for c in wanted if c not in RUNNERS]
    if unknown:
        sys.stderr.write("unknown case(s): %s\nknown: %s\n" % (", ".join(unknown), ", ".join(CASES)))
        return 2
    bad = []
    for name in CASES:
        if name not in wanted:
            continue
        print("\n=== %s — %s" % (name, RUNNERS[name].__doc__.splitlines()[0]))
        s = Sandbox(lib, record=RECORD[name])
        try:
            ok = bool(RUNNERS[name](s))
        except Exception as e:
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:300]))
        finally:
            s.close()
        print("    EXPECTATION HELD                         %s" % ok)
        if not ok:
            bad.append(name)
    print("\n=== held: %d/%d%s" % (len(wanted) - len(bad), len(wanted),
                                   ("; NOT HELD: " + ", ".join(bad)) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
