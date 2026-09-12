# Workspace spec

**This is the spec. Nothing else governs workspace cleanup.** Anything built for workspaces is judged
against this page and nothing else.

## The spec

1. **Every non-native Claude workspace is named `cc/`.** Among non-native workspaces, only `cc/` ones
   are the system's concern. Native workspaces are covered by point 6.

2. **A `codex/` workspace or branch is never deleted without the CEO's express word.** An agent never
   works inside a `codex/` workspace; it works from a copy in its own `cc/` workspace. Landing never
   deletes anything `codex/`.

3. **Two events, nothing else:** the agent is spawned and its workspace registered; the work is landed
   and its workspace deleted. (The second event is landing, or its one alternative, discarding —
   point 7.) If registration fails, the spawn does not happen. Creating a non-native workspace not named
   `cc/` is refused. A `cc/` or native workspace with no registration, and any branch an agent created,
   counts as finished work of an ended session and is handled under point 5. Nobody starts a session in
   its own workspace (`claude --worktree` / `claude -w`); it is not allowed.

4. **Landed means the workspace AND the branch are deleted — automatically, with nothing left
   undecided.** Finished garbage is cleaned up without anyone asking for it.

5. **Rich lands 100% of everything after the agent is finished — guaranteed.** When an agent finishes,
   everything it produced is landed (or, where point 7 applies, discarded). Every time, all of it, no
   exceptions, no deferral. This is a guarantee, not a habit: it holds whether or not Rich remembers, and
   whether or not a session restarts. Without it, point 3 has nothing to act on and workspaces sit
   forever.
   **Enforced:** while any finished agent's work is neither landed nor discarded (point 7), Rich can
   neither start new work nor end his turn. A session that starts with such work does that first.
   **Two things are always allowed, and only these two:** answering the CEO or obeying his stop order
   (the reply names the pending work, which is handled right after); and work whose only purpose is
   getting the pending work landed (resolving a clash with main, fixing a failing check). If the only
   way to end a piece of pending work is a discard that needs the CEO's word (point 7), Rich asks him in
   that same turn; that one item then waits on him, is on his TODO list, and blocks nothing else.
   Rich may end his turn when every pending item is either waiting on something he has already started
   to get it landed, or waiting on something outside his reach (the CEO's word, a service that is down);
   the latter goes on the CEO's TODO list. New work stays blocked either way.

6. **Native workspaces get exactly the same treatment.** The workspaces Claude Code creates itself
   (`.claude/worktrees/agent-<id>`, branch `worktree-agent-<id>`) follow points 3, 4 and 5: registered
   when the agent is spawned, workspace and branch deleted automatically when its work is landed. No
   finished native workspace piles up.

7. **Finished work ends in exactly one of two ways — landed or discarded. Both delete.** Work that must
   not go in (an agent cut off halfway, work a reviewer rejected, a branch that will not merge) is
   discarded by Rich: workspace and branch deleted, with the reason recorded. Nothing finished is ever
   left neither landed nor discarded. An agent that produced nothing counts as landed: its workspaces are
   deleted. **Work the CEO ordered is never discarded without his word.** Unfinished work can also be
   finished: a new agent continues from its branch, the old workspaces are deleted when the new agent
   starts, and its work counts as landed when the new agent's does. This is work whose only purpose is
   getting the pending work landed (point 5).

8. **Nothing uncommitted is ever landed.** A workspace with uncommitted or ignored files it needs is not
   landed until the agent's work is committed. A finished agent can no longer commit (point 9), so Rich
   commits what it left to its branch before landing, or discards it. Deletion therefore never loses
   anything that was meant to land.

9. **A finished agent never writes again.** The platform restarts finished agents. A restarted agent is
   refused every tool, so it cannot write anywhere, including after its workspace is gone. This lock-out
   already exists and stays. When an agent is finished, every process it started is stopped before its
   workspaces are deleted.

10. **All of an agent's workspaces go together.** An agent working in another repository has two: the
    native one Claude Code creates and its `cc/` one. When its work is landed or discarded, every
    workspace and branch it has is deleted, as one. None is left behind.

11. **"Finished" means the agent's run has ended and Rich did not pause it.** That covers every ending:
    it handed in its work, crashed, was cut off by a limit, or was stopped. An agent Rich pauses (told to
    commit and hold, including the automatic pause at the CEO's 93% quota threshold) is not finished: it
    keeps its workspaces, is not locked out, and resumes. Rich records every pause when he sends it, so
    the two are never confused and nothing has to be guessed. **Every pause ends in one of two ways:** the
    agent is resumed, or — when its work is no longer wanted — it is stopped, which makes it finished
    (points 5 and 7 then apply). No agent stays paused forever. An agent becomes finished when the
    platform's own end-of-run signal for it is recorded, automatically and never by Rich noticing. Any
    ending that gives no such signal is handled at session end (point 12). A pause names what ends it
    (the quota reset, the CEO's answer); a pause with nothing named counts as pending work under point 5.
    An agent that ends after handing in its work is finished even if a pause was sent.

12. **An agent cannot outlive its session.** When a session ends — closed, crashed or restarted — every
    agent it ran is finished, and the next session lands or discards their work before anything else
    (point 5). While two sessions run at once, each handles only the agents it started. Every session
    records itself when it starts. A session has ended when it recorded its end or when its process no
    longer exists on this machine; that is read from the operating system, never guessed. (The record
    carries more than a process number, since those get reused.)

13. **A failed deletion is retried automatically until it succeeds.** If a workspace or branch cannot be
    deleted at that moment (a file held open, a disk error), it is retried with no one's involvement. The
    CEO hears about it only if it keeps failing.

14. **Landed doesn't always mean landed on main.** Landing means merged into the branch this work
    integrates on. Usually that is main. When the work cannot reach main yet — not reviewed, or not ready
    to install — it is that work's dev branch. Rich merges each finished agent's work onto it and deletes
    that agent's workspaces and branches under point 4, exactly as in any other land. The dev branch
    reaches main when the work is certified and ready. **Finished work never waits on the agent's own
    branch**, and "it cannot go to main yet" is never a reason for anything to be left behind or for
    point 5 to be blocked.
    **The branch a body of work integrates on is RECORDED when that work starts, before its first agent
    is spawned. Nothing infers it and nothing guesses it** — without that record there is no fact to test
    a land against, and "landed" goes back to meaning whatever main happens to have.

## What is not in the spec

No question of whether an agent is still alive. No "in use markers". No liveness guessing of any kind.
If something is not in the fourteen points above, it is not part of the spec.
