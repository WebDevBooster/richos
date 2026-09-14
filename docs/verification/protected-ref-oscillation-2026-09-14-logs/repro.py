#!/usr/bin/env python3
"""repro.py — the two-agent condition that moved `refs/heads/main` in
/Users/alex/ab/richos three times on 2026-09-13/14, built from nothing in a
throwaway repository.

    python3 repro.py --lib <path to engine/scripts/lib/workspaces.py>

Nothing outside the temporary directory is read or written: HOME,
CLAUDE_CONFIG_DIR and GIT_CONFIG_GLOBAL are redirected into it, so the
operator's real workspace store, sessions and worktrees are untouched.

WHAT IT BUILDS — the shape of the real incident, not an analogy:

  * a repository whose recorded integration branch is `main` (point 14);
  * agent A and agent B, both registered and both running;
  * A opens a tool call while main is at T0        (its window records T0);
  * the LEAD lands A's finished work: main -> T1   (an ordinary merge);
  * B opens a tool call while main is at T1        (its window records T1);
  * A's PostToolUse fires;
  * B's PostToolUse fires.

On the engine as it stood at 2026-09-14, A's Post rewinds main to T0 — Rich's
merge stops being reachable from main — and B's Post puts it back to T1 a
moment later, each write with NO reflog message because the call passes no
`-m`. Two agents, two windows, opposite directions, and the engine's own event
log attributes both.

`--mode destruction` is the same mechanism with different timing, and it is the
one that loses work: between A's rewind and B's restore the lead lands a THIRD
agent's work onto the tip A left behind. B then "restores" main to the tip its
own window recorded, and that second land stops being reachable from main. The
oscillation above is the LUCKY outcome of this; this is the unlucky one.

EXIT CODE: 0 when main ends where the lead put it and the engine wrote nothing;
1 when the engine moved main. So the bug reproducing is a FAILING run.
"""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args, **kw):
    check = kw.pop("check", True)
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy(), **kw)
    if check and r.returncode != 0:
        raise AssertionError("%s failed rc=%d\n%s\n%s" % (args, r.returncode, r.stdout, r.stderr))
    return r


def sha(repo, rev):
    return run("git", "-C", repo, "rev-parse", rev, check=False).stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True, help="the engine's scripts/lib/workspaces.py to exercise")
    ap.add_argument("--mode", choices=("oscillation", "destruction"), default="oscillation")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    root = os.path.realpath(tempfile.mkdtemp(prefix="ref-oscillation-"))
    home = os.path.join(root, "home")
    os.makedirs(home)
    os.environ["HOME"] = home
    os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(home, ".claude")
    os.environ.pop("RICHOS_WORKSPACES_DIR", None)
    os.environ.pop("RICHOS_SESSION_ID", None)
    os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
    gc = os.path.join(home, ".gitconfig")
    with open(gc, "w") as f:
        f.write("[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n")
    os.environ["GIT_CONFIG_GLOBAL"] = gc

    spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(a.lib))
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)

    print("lib      : %s" % os.path.abspath(a.lib))
    print("sandbox  : %s" % root)

    repo = os.path.join(root, "entity")
    os.makedirs(repo)
    run("git", "init", "-q", "-b", "main", repo)
    with open(os.path.join(repo, "README"), "w") as f:
        f.write("x\n")
    run("git", "-C", repo, "add", "-A")
    run("git", "-C", repo, "commit", "-q", "-m", "init")

    sess = subprocess.Popen(["sleep", "600"])
    os.environ["RICHOS_SESSION_PID"] = str(sess.pid)
    time.sleep(0.05)
    sid = "sess-repro-0001"
    ws.record_session_start(sid, repo)
    # Point 14: the branch this body of work integrates on, recorded before the
    # first spawn, exactly as Rich records it.
    ws.record_integration(repo, "main", "the reproduction's body of work", sid)

    def spawn(name, aid):
        payload = {"session_id": sid, "tool_use_id": "tu-" + name, "tool_name": "Agent",
                   "tool_input": {"name": name, "subagent_type": "zach", "prompt": "do it\n",
                                  "isolation": "worktree"}}
        ws.register_spawn(payload, repo)
        path = os.path.join(repo, ".claude", "worktrees", "agent-" + aid)
        run("git", "-C", repo, "worktree", "add", "-q", path, "-b", "worktree-agent-" + aid)
        ws.record_start(sid, aid, path, "zach")
        ws.bind_agent(sid, "tu-" + name, aid, repo)
        return path

    def pre(aid, call):
        return ws.barrier({"session_id": sid, "agent_id": aid, "tool_use_id": call})

    def post(aid, call):
        findings = getattr(ws, "PROTECTED_REF_FINDINGS", None)
        if findings is None:
            findings = getattr(ws, "RESTORED_THIS_CALL", [])
        del findings[:]
        ws.observe({"session_id": sid, "agent_id": aid, "tool_name": "Bash",
                    "hook_event_name": "PostToolUse", "tool_use_id": call})
        return list(findings)

    a_path = spawn("zach-opus-aa1", "aaaa000000000001")
    b_path = spawn("zach-opus-bb1", "bbbb000000000002")
    c_path = spawn("zach-opus-cc1", "cccc000000000003")

    def work(path, fname):
        with open(os.path.join(path, fname), "w") as f:
            f.write("work\n")
        run("git", "-C", path, "add", fname)
        run("git", "-C", path, "commit", "-q", "-m", "work " + fname)

    work(a_path, "a.txt")
    work(b_path, "b.txt")
    work(c_path, "c.txt")

    t0 = sha(repo, "main")
    print("\nT0 main  : %s   (before anything lands)" % t0[:12])

    print("A opens a tool call (its window records main = %s)" % t0[:12])
    pre("aaaa000000000001", "tu-a-1")

    print("the LEAD lands A's work: git merge worktree-agent-aaaa000000000001")
    run("git", "-C", repo, "merge", "-q", "--no-edit", "worktree-agent-aaaa000000000001")
    t1 = sha(repo, "main")
    print("T1 main  : %s   (Rich's merge)" % t1[:12])

    print("B opens a tool call (its window records main = %s)" % t1[:12])
    pre("bbbb000000000002", "tu-b-1")

    fa = post("aaaa000000000001", "tu-a-1")
    after_a = sha(repo, "main")
    print("\nA's PostToolUse -> main = %s   %s"
          % (after_a[:12], "MOVED BY THE ENGINE" if after_a != t1 else "left alone"))
    for f in fa:
        print("    finding: %s" % (f,))

    second_land = ""
    if a.mode == "destruction":
        # The lead lands a THIRD agent's work onto whatever main holds now — he
        # has no way to know an agent rewound it a moment ago, and his merge is
        # an ordinary one.
        run("git", "-C", repo, "merge", "-q", "--no-edit", "worktree-agent-cccc000000000003")
        second_land = sha(repo, "main")
        print("the LEAD lands C's work onto that tip: main = %s" % second_land[:12])

    fb = post("bbbb000000000002", "tu-b-1")
    after_b = sha(repo, "main")
    print("B's PostToolUse -> main = %s   %s"
          % (after_b[:12], "MOVED BY THE ENGINE" if after_b != after_a else "left alone"))
    for f in fb:
        print("    finding: %s" % (f,))

    print("\n--- reflog of refs/heads/main (an EMPTY message is an engine write) ---")
    rl = run("git", "-C", repo, "reflog", "show", "main", "--date=iso", check=False).stdout
    print(rl.rstrip() or "(none)")
    empty = [ln for ln in rl.splitlines() if ln.rstrip().endswith(":")]

    print("\n--- the engine's own event log ---")
    ev = os.path.join(home, ".claude", "state", "workspaces", "events.jsonl")
    rows = []
    if os.path.exists(ev):
        for ln in open(ev):
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            if "protected-ref" in str(d.get("event", "")):
                rows.append(d)
                print(json.dumps(d, sort_keys=True))
    if not rows:
        print("(no protected-ref events)")

    # AN ENGINE WRITE IS A TIP THAT IS NOT WHERE THE LEAD LAST PUT IT — never
    # "it changed", because in --mode destruction the lead himself merges again
    # between the two Posts, and counting that as an engine write would call the
    # fixed engine guilty.
    moved = after_a != t1 or after_b != (second_land or after_a)
    last_land = second_land or t1
    reachable = run("git", "-C", repo, "merge-base", "--is-ancestor", last_land, "main",
                    check=False).returncode == 0
    end = sha(repo, "main")
    print("\n=== VERDICT ===")
    print("mode                                  : %s" % a.mode)
    print("main was moved by the engine          : %s" % ("YES" if moved else "NO"))
    print("empty-message reflog lines            : %d" % len(empty))
    print("the lead's last land still reachable  : %s" % ("yes" if reachable else "NO - HIS LAND IS GONE"))
    print("main ends at                          : %s (the lead left it at %s)" % (end[:12], last_land[:12]))

    if a.keep:
        print("\nsandbox kept: %s" % root)
    sess.kill()
    sess.wait()
    if not a.keep:
        shutil.rmtree(root, ignore_errors=True)
    return 1 if moved else 0


if __name__ == "__main__":
    sys.exit(main())
