#!/usr/bin/env python3
"""Sage's independent probe of observe_branches attribution.

Usage: probe.py <path-to-workspaces.py> <scenario>

Written for this review; it does not import or reuse the engine's own test file.
Everything runs in a temporary root with HOME, CLAUDE_CONFIG_DIR, TMPDIR and
RICHOS_WORKSPACES_DIR redirected into it.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

LIB = os.path.abspath(sys.argv[1])
SCENARIO = sys.argv[2]

ROOT = os.path.realpath(tempfile.mkdtemp(prefix="sage-probe-"))
HOME = os.path.join(ROOT, "home")
os.makedirs(HOME)
os.environ["HOME"] = HOME
os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(HOME, ".claude")
os.environ["TMPDIR"] = ROOT
os.environ["RICHOS_WORKSPACES_DIR"] = os.path.join(ROOT, "registry")
os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
os.environ["RICHOS_WORKSPACES_STOP_GRACE"] = "1"
os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
gc = os.path.join(HOME, ".gitconfig")
with open(gc, "w") as f:
    f.write("[user]\n\tname = p\n\temail = p@example.invalid\n[init]\n\tdefaultBranch = main\n")
os.environ["GIT_CONFIG_GLOBAL"] = gc
os.environ.pop("RICHOS_SESSION_ID", None)

spec = importlib.util.spec_from_file_location("workspaces", LIB)
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

SID = "sess-probe-0001"
PROCS = []


def sh(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy(), **kw)
    return r


def git(repo, *args):
    return sh("git", "-C", repo, *args)


def mkrepo(name):
    p = os.path.join(ROOT, name)
    os.makedirs(p)
    sh("git", "init", "-q", "-b", "main", p)
    open(os.path.join(p, "README"), "w").write("x\n")
    git(p, "add", "-A")
    git(p, "commit", "-q", "-m", "init")
    return p


def branches(repo):
    return sorted(git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split())


def session():
    pr = subprocess.Popen(["sleep", "900"])
    PROCS.append(pr)
    os.environ["RICHOS_SESSION_PID"] = str(pr.pid)
    time.sleep(0.05)
    ws.record_session_start(SID, ENTITY)
    return pr


def spawn(name, cc_repo, native=True):
    """A spawn exactly as the hooks make it: cc workspace registered + created,
    native workspace created and started, then the id bound."""
    ccpath = os.path.join(ROOT, "wt", name)
    ws.register_cc(SID, name, cc_repo, ccpath, "cc/" + name)
    git(cc_repo, "worktree", "add", "-q", ccpath, "-b", "cc/" + name, "HEAD")
    ws.confirm_cc(SID, name, ccpath, True)
    prompt = "do it\ncross-repo-worktree: %s\n" % ccpath
    ws.register_spawn({"session_id": SID, "tool_use_id": "tu-" + name, "tool_name": "Agent",
                       "tool_input": {"name": name, "subagent_type": "zach", "prompt": prompt,
                                      "isolation": "worktree" if native else ""}}, ENTITY)
    aid = "a" + name.replace("-", "")[:12] + "0000"
    npath = ""
    if native:
        npath = os.path.join(ENTITY, ".claude", "worktrees", "agent-" + aid)
        git(ENTITY, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
        ws.record_start(SID, aid, npath, "zach")
    ws.bind_agent(SID, "tu-" + name, aid, ENTITY)
    return {"name": name, "aid": aid, "cc": ccpath, "native": npath}


def call(aid):
    return ws.barrier({"session_id": SID, "agent_id": aid})


def rec(name):
    return ws.load_agent(ws.named_key(SID, name))


def out(label, value):
    print("%-42s %s" % (label, json.dumps(value, sort_keys=True)))


def cleanup():
    for pr in PROCS:
        try:
            pr.kill(); pr.wait()
        except OSError:
            pass
    sh("chmod", "-R", "u+w", ROOT)
    shutil.rmtree(ROOT, ignore_errors=True)


ENTITY = mkrepo("entity")
OTHER = mkrepo("other")
session()
try:
    if SCENARIO == "two-agents-land":
        # Two agents live in ONE repository, tool calls interleaved.
        a = spawn("zach-opus-a1", OTHER)
        b = spawn("mark-opus-b1", OTHER)
        call(a["aid"]); call(b["aid"]); call(a["aid"]); call(b["aid"])
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        out("B.created_branches", rec(b["name"]).get("created_branches"))
        # A commits and Rich merges it, then A finishes; B is still running.
        for p in (a["cc"], a["native"]):
            open(os.path.join(p, "w.txt"), "w").write("a\n")
            git(p, "add", "-A"); git(p, "commit", "-q", "-m", "a work")
        git(OTHER, "merge", "-q", "--no-edit", "cc/" + a["name"])
        git(ENTITY, "merge", "-q", "--no-edit", "worktree-agent-" + a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        try:
            out("land(A)", ws.land(a["name"], me=SID))
        except Exception as e:
            out("land(A) RAISED", "%s: %s" % (type(e).__name__, e))
        out("other branches after land(A)", branches(OTHER))
        out("entity branches after land(A)", branches(ENTITY))
        out("B workspace still there", os.path.isdir(b["cc"]))

    elif SCENARIO == "two-agents-staggered":
        # The ordinary order: A is already working when B is spawned.
        a = spawn("zach-opus-a1", OTHER)
        call(a["aid"])
        b = spawn("mark-opus-b1", OTHER)
        call(a["aid"])
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        out("B.created_branches", rec(b["name"]).get("created_branches"))
        # B has real work committed on its own branch; A has nothing to land.
        open(os.path.join(b["cc"], "b.txt"), "w").write("b\n")
        git(b["cc"], "add", "-A"); git(b["cc"], "commit", "-q", "-m", "b work")
        btip = git(OTHER, "rev-parse", "cc/" + b["name"]).stdout.strip()
        ws.record_end(SID, a["aid"], "SubagentStop")
        out("A.created_branches at end", rec(a["name"]).get("created_branches"))
        try:
            out("land(A)", ws.land(a["name"], me=SID))
        except Exception as e:
            out("land(A) RAISED", "%s: %s" % (type(e).__name__, str(e)[:400]))
        r = None
        try:
            r = ws.discard(a["name"], "probe: A produced nothing and is discarded",
                           not_ceo_ordered="probe scenario, nobody ordered it", me=SID)
            out("discard(A).tips", sorted(r["tips"].keys()))
        except Exception as e:
            out("discard(A) RAISED", "%s: %s" % (type(e).__name__, str(e)[:400]))
        out("other branches after discard(A)", branches(OTHER))
        out("B branch tip survived", git(OTHER, "rev-parse", "--verify", "-q", "cc/" + b["name"]).stdout.strip() == btip)
        out("B native branch survived", "worktree-agent-" + b["aid"] in branches(ENTITY))
        out("B workspace still there", os.path.isdir(b["cc"]))

    elif SCENARIO == "two-agents-discard":
        a = spawn("zach-opus-a1", OTHER)
        b = spawn("mark-opus-b1", OTHER)
        call(a["aid"]); call(b["aid"]); call(a["aid"])
        # B has real work committed on its own branches.
        open(os.path.join(b["cc"], "b.txt"), "w").write("b\n")
        git(b["cc"], "add", "-A"); git(b["cc"], "commit", "-q", "-m", "b work")
        btip = git(OTHER, "rev-parse", "cc/" + b["name"]).stdout.strip()
        call(a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        r = ws.discard(a["name"], "probe: discarding A while B is live",
                       not_ceo_ordered="probe scenario, nobody ordered it", me=SID)
        out("discard(A).tips", sorted(r["tips"].keys()))
        out("other branches after discard(A)", branches(OTHER))
        out("B branch tip survived", git(OTHER, "rev-parse", "cc/" + b["name"]).stdout.strip() == btip)
        out("B workspace still there", os.path.isdir(b["cc"]))

    elif SCENARIO == "stray-plain-branch":
        a = spawn("zach-opus-a1", OTHER)
        call(a["aid"])
        # Two branches created inside its own workspace, never checked out.
        git(a["cc"], "branch", "spare")
        git(a["cc"], "branch", "cc/zach-opus-a1-side")
        call(a["aid"])
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        git(OTHER, "merge", "-q", "--no-edit", "cc/" + a["name"])
        git(ENTITY, "merge", "-q", "--no-edit", "worktree-agent-" + a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        out("A.created_branches at end", rec(a["name"]).get("created_branches"))
        out("land(A)", ws.land(a["name"], me=SID))
        out("other branches after land", branches(OTHER))
        made = ws.scan_unregistered([OTHER, ENTITY])
        out("scan_unregistered keys", made)
        out("scan names", sorted((ws.load_agent(k) or {}).get("name") for k in made))

    elif SCENARIO == "stray-switch-away":
        a = spawn("zach-opus-a1", OTHER)
        call(a["aid"])
        # Created, committed on, and switched away from inside ONE tool call.
        git(a["cc"], "checkout", "-q", "-b", "tmpwork")
        open(os.path.join(a["cc"], "t.txt"), "w").write("t\n")
        git(a["cc"], "add", "-A"); git(a["cc"], "commit", "-q", "-m", "side work")
        tip = git(OTHER, "rev-parse", "tmpwork").stdout.strip()
        git(a["cc"], "checkout", "-q", "cc/" + a["name"])
        call(a["aid"])
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        git(OTHER, "merge", "-q", "--no-edit", "cc/" + a["name"])
        git(ENTITY, "merge", "-q", "--no-edit", "worktree-agent-" + a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        out("land(A)", ws.land(a["name"], me=SID))
        out("other branches after land", branches(OTHER))
        out("tmpwork tip still present", git(OTHER, "rev-parse", "--verify", "-q", "tmpwork").stdout.strip() == tip)
        out("tmpwork commit in main", git(OTHER, "merge-base", "--is-ancestor", tip, "main").returncode == 0)
        out("pending after land", sorted(i["name"] for i in ws.pending(SID, ENTITY, scan=True)))

    elif SCENARIO == "preexisting-checked-out":
        # A branch somebody else made, carrying work not in main, that the agent
        # checks out in its own workspace.
        git(OTHER, "branch", "human/keep")
        wt = os.path.join(ROOT, "human-wt")
        git(OTHER, "worktree", "add", "-q", wt, "human/keep")
        open(os.path.join(wt, "h.txt"), "w").write("h\n")
        git(wt, "add", "-A"); git(wt, "commit", "-q", "-m", "human work")
        tip = git(OTHER, "rev-parse", "human/keep").stdout.strip()
        git(OTHER, "worktree", "remove", "--force", wt)
        a = spawn("zach-opus-a1", OTHER)
        call(a["aid"])
        git(a["cc"], "checkout", "-q", "human/keep")
        call(a["aid"])
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        git(ENTITY, "merge", "-q", "--no-edit", "worktree-agent-" + a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        try:
            out("land(A)", ws.land(a["name"], me=SID))
        except Exception as e:
            out("land(A) RAISED", "%s: %s" % (type(e).__name__, str(e)[:300]))
        r = ws.discard(a["name"], "probe: agent's work rejected by a reviewer",
                       not_ceo_ordered="probe scenario, nobody ordered it", me=SID)
        out("discard tips", sorted(r["tips"].keys()))
        out("other branches after discard", branches(OTHER))
        out("human/keep tip survived", git(OTHER, "rev-parse", "--verify", "-q", "human/keep").stdout.strip() == tip)

    elif SCENARIO == "rescue-after-end":
        a = spawn("zach-opus-a1", OTHER)
        call(a["aid"])
        open(os.path.join(a["cc"], "w.txt"), "w").write("a\n")
        git(a["cc"], "add", "-A"); git(a["cc"], "commit", "-q", "-m", "a work")
        call(a["aid"])
        ws.record_end(SID, a["aid"], "SubagentStop")
        # Rich cuts a rescue copy in the agent's own workspace, after the end.
        git(a["cc"], "checkout", "-q", "-b", "rescue/a1")
        out("A.created_branches", rec(a["name"]).get("created_branches"))
        out("barrier for the finished agent", list(call(a["aid"]))[0])
        out("A.created_branches after refused call", rec(a["name"]).get("created_branches"))
        git(OTHER, "merge", "-q", "--no-edit", "rescue/a1")
        git(ENTITY, "merge", "-q", "--no-edit", "worktree-agent-" + a["aid"])
        try:
            out("land(A)", ws.land(a["name"], me=SID))
        except Exception as e:
            out("land(A) RAISED", "%s: %s" % (type(e).__name__, str(e)[:300]))
        out("other branches after land", branches(OTHER))
        out("rescue/a1 survived", "rescue/a1" in branches(OTHER))

    elif SCENARIO == "cost":
        a = spawn("zach-opus-a1", OTHER)
        for i in range(40):
            git(OTHER, "worktree", "add", "-q", os.path.join(ROOT, "extra%d" % i), "-b", "cc/extra%d" % i, "HEAD")
        t0 = time.time()
        for _ in range(20):
            call(a["aid"])
        out("20 barrier calls, 42 worktrees, seconds", round(time.time() - t0, 3))

    else:
        raise SystemExit("unknown scenario " + SCENARIO)
finally:
    reg = os.path.join(os.path.expanduser("~"), ".claude", "state", "workspaces")
    out("sandbox HOME registry used", os.path.isdir(os.environ["RICHOS_WORKSPACES_DIR"]))
    cleanup()
