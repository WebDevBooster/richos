# Workspace spec — the CEO's, 2026-09-10, with his 2026-09-11 amendments

**This is the spec. Nothing else governs workspace cleanup.** Every line below is his, from his own
messages; the dates and times are when he wrote them (session `d0eef867` on 2026-09-10, session
`b7869424` on 2026-09-11). Anything built for workspaces is judged against this page and nothing else.

## The spec

1. **Every non-native Claude workspace is named `cc/`.** Among non-native workspaces, only `cc/` ones
   are the system's concern. Native workspaces are covered by point 6.
   *"would giving non-native workspaces the prefix `cc/` make them easier to track ... what if we only
   have to care about those with the prefix and ignore anything else?"* (2026-09-10 12:31)
   *"if the `cc/` prefix helps fix this shitshow once and for all, add it now and be done with it."* (12:43)

2. **`codex/` is never touched.**
   *"Don't touch any workspaces starting with `codex/` unless I expressively say to remove one of those
   things."* (12:37)
   An agent never works inside a `codex/` workspace; it works from a copy in its own `cc/` workspace,
   and landing never deletes anything `codex/`. *(Frank, hole 8)*

3. **Two events, nothing else.** (The second event is landing, or its one alternative, discarding —
   point 7.) If registration fails, the spawn does not happen. Creating a non-native workspace not named
   `cc/` is refused. A `cc/` or native workspace with no registration, and any branch an agent created,
   counts as finished work of an ended session and is handled under point 5. *(Frank, hole 6)*
   Nobody starts a session in its own workspace (`claude --worktree` / `claude -w`) in RichOS; it is
   not allowed. *"I've never done that and no one is allowed to do that in the RichOS app."* (2026-09-11)
   *"1) spawned/workspace registered 2) landed/workspace to be deleted. What the hell else is there needed
   to be?"* (13:14)

4. **Landed means the workspace AND the branch are deleted — automatically, with nothing left undecided.**
   *"AFTER THE WORKSPACE/BRANCH WAS ALREADY DELETED"* (16:08) · *"finally NOT having anything
   'undecided' AFTER the corresponding one was landed."* (12:37) · *"WHEN THE FUCK WILL THE ALL THE
   **FINISHED** GARBAGE START GETTING CLEANED UP AUTOMATICALLY"* (10:51)

5. **ADDED 2026-09-11: Rich lands 100% of everything after the agent is finished — guaranteed.**
   When an agent finishes, everything it produced is landed (or, where point 7 applies, discarded).
   Every time, all of it, no exceptions, no deferral. This is a guarantee, not a habit: it holds whether or not Rich remembers, and whether or
   not a session restarts. Without it, point 3 has nothing to act on and workspaces sit forever.
   **Enforced:** while any finished agent's work is neither landed nor discarded (point 7), Rich can
   neither start new work nor end his turn. A session that starts with such work does that first.
   **Two things are always allowed, and only these two:** answering the CEO or obeying his stop order
   (the reply names the pending work, which is handled right after); and work whose only purpose is
   getting the pending work landed (resolving a clash with main, fixing a failing check). If the only
   way to end a piece of pending work is a discard that needs the CEO's word (point 7), Rich asks him in
   that same turn; that one item then waits on him, is on his TODO list, and blocks nothing else.
   Rich may end his turn when every pending item is either waiting on something he has already started
   to get it landed, or waiting on something outside his reach (the CEO's word, a service that is down);
   the latter goes on the CEO's TODO list. New work stays blocked either way. *(Frank, hole 4)*
   *"WHERE IS THE PART IN MY SPEC FROM YESTERDAY THAT GUARANTEES THAT [RICH] ALWAYS LANDS 100% EVERYTHING
   AFTER THE AGENT IS FINISHED?"* (2026-09-11 07:29) · *"ADD IT TO THE ... SPEC"* (2026-09-11)

6. **ADDED 2026-09-11: native workspaces get exactly the same treatment.** The workspaces Claude Code
   creates itself (`.claude/worktrees/agent-<id>`, branch `worktree-agent-<id>`) follow points 3, 4
   and 5: registered when the agent is spawned, workspace and branch deleted automatically when its work
   is landed. No finished native workspace piles up.
   *"And what happens to the native workspaces now? ... Do I want to keep shit loads of that garbage
   piling up if that doesn't automatically gets cleaned up by Claude????"* (2026-09-11)

7. **ADDED 2026-09-11: finished work ends in exactly one of two ways — landed or discarded. Both delete.**
   Work that must not go into main (an agent cut off halfway, work a reviewer rejected, a branch that
   will not merge) is discarded by Rich: workspace and branch deleted, with the reason recorded. Nothing
   finished is ever left neither landed nor discarded. An agent that produced nothing counts as landed:
   its workspaces are deleted. **Work the CEO ordered is never discarded without his word.**
   Unfinished work can also be finished: a new agent continues from its branch, the old workspaces are
   deleted when the new agent starts, and its work counts as landed when the new agent's does. This is
   work whose only purpose is getting the pending work landed (point 5). *(Frank, hole 3)*

8. **ADDED 2026-09-11: nothing uncommitted is ever landed.** A workspace with uncommitted or ignored
   files it needs is not landed until the agent's work is committed. A finished agent can no longer
   commit (point 9), so Rich commits what it left to its branch before landing, or discards it.
   Deletion therefore never loses anything that was meant to land.

9. **ADDED 2026-09-11: a finished agent never writes again.** The platform restarts finished agents
   (14 times observed). A restarted agent is refused every tool, so it cannot write anywhere, including
   after its workspace is gone. This lock-out already exists and stays. When an agent is finished,
   every process it started is stopped before its workspaces are deleted. *(Frank, hole 5)*

10. **ADDED 2026-09-11: all of an agent's workspaces go together.** An agent working in another
    repository has two: the native one Claude Code creates and its `cc/` one. When its work is landed or
    discarded, every workspace and branch it has is deleted, as one. None is left behind.

11. **ADDED 2026-09-11: "finished" means the agent's run has ended and Rich did not pause it.** That
    covers every ending: it handed in its work, crashed, was cut off by a limit, or was stopped. An agent
    Rich pauses (told to commit and hold, including the automatic pause at the CEO's 93% quota threshold)
    is not finished: it keeps its workspaces, is not locked out, and resumes. Rich records every pause
    when he sends it, so the two are never confused and nothing has to be guessed. **Every pause ends in
    one of two ways:** the agent is resumed, or — when its work is no longer wanted — it is stopped, which
    makes it finished (points 5 and 7 then apply). No agent stays paused forever.
    An agent becomes finished when the platform's own end-of-run signal for it is recorded,
    automatically and never by Rich noticing. Any ending that gives no such signal is handled at session
    end (point 12). *(Frank, hole 1)* A pause names what ends it (the quota reset, the CEO's answer); a
    pause with nothing named counts as pending work under point 5. An agent that ends after handing in
    its work is finished even if a pause was sent. *(Frank, hole 7)*

12. **ADDED 2026-09-11: an agent cannot outlive its session.** When a session ends — closed, crashed or
    restarted — every agent it ran is finished, and the next session lands or discards their work before
    anything else (point 5). While two sessions run at once, each handles only the agents it started.
    Every session records itself when it starts. A session has ended when it recorded its end or when
    its process no longer exists on this machine; that is read from the operating system, never guessed.
    (The record carries more than a process number, since those get reused.) *(Frank, hole 2 — the
    CEO's choice, 2026-09-11: "The computer says so")*

13. **ADDED 2026-09-11: a failed deletion is retried automatically until it succeeds.** If a workspace or
    branch cannot be deleted at that moment (a file held open, a disk error), it is retried with no one's
    involvement. The CEO hears about it only if it keeps failing.

*The lines marked (Frank, hole N) are Frank's fixes from `docs/verification/worktree-spec-review-frank-2026-09-11.md`,
added word for word on the CEO's order of 2026-09-11 ("Add all seven").*

*Points 7–13 and the point-5 allowances: "how fucking hard can it be to AMEND my dead-simple spec with those few SIMPLE changes to
make sure that my spec is ABSOLUTELY 100% AIRTIGHT"* (2026-09-11)

## What is not in the spec

No question of whether an agent is still alive. No "in use markers" — *"Why do you need some 'in use
markers' or anything like that?"* (13:14). No liveness guessing of any kind. If something is not in the
thirteen points above, it is not part of the spec.
