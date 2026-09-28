# WAIT delivery to a subagent in a foreground command, measured 2026-09-28

Claude Code 2.1.283, this Mac. Author: zach-opus-waitdeliver1. The mechanism is
`richos/engine/scripts/lib/agent_hold.py` (its module docstring is the design).

## The defect

The generated WAIT went out with SendMessage while the agent was inside a foreground
Bash call. The lead's PostToolUse[SendMessage] hold SIGSTOPped that call's processes.
A queued message reaches a subagent only when its current tool call returns, so the
frozen call kept the message undelivered until the agent's own Bash timeout (10 minutes).

## What was measured first (disposable `claude -p` children; lead + one background subagent)

| # | Setup | Result |
|---|---|---|
| E1 | Subagent in a foreground `sleep 40`; the lead sends a message 30 s before it ends | The message row (`queued_command`) lands **5 ms after the tool result**, 29.9 s after the send. Never during the call. |
| E2 | The same call SIGSTOPped, Bash timeout 20 s | At 20 s the harness moves the call to the background ("You will be notified when it completes") and delivers the message 6 ms later. The subagent handled the message, then **ended its turn, which ended its run**: the lead got its completion notice, and the backgrounded command's completion went to the lead. Nothing was signaled by the harness. |
| E3 | The command runs as a job of its shell, output redirected to a file; at +3 s the job is SIGSTOPped and the shell alone gets SIGUSR1, whose trap prints a line and exits | The tool call returns **about 30 ms** after the signal and the queued message is delivered with it. The stopped job survives its shell's exit, the end of the call and the claude process's exit; after SIGCONT it finished and wrote its output. |
| hup | Same as E3 but the shell does not lead its own session | The job is killed when the shell exits: its process group becomes orphaned with a stopped member, so the kernel sends SIGHUP. Claude Code's Bash shells lead their own session (`ps` shows `Ss`), so under the harness the group was never qualified and nothing is sent. The hold detaches only a session-leader shell and freezes any other whole. |

Also read from the 2.1.283 binary: a message to a running subagent is appended to its
pending queue and drained at its next tool round; the harness's own "background a
command so a queued message can reach the model" path applies only to the main
conversation's commands (`agentId === undefined`), never to a subagent's.

## The design (from that evidence)

1. **Every foreground Bash call of a subagent runs as a job of its own shell** (the
   PreToolUse rewriter, `shell-evidence.py` -> `agent_hold.rewrite()`), output to a
   per-call file. Unheld, the shell prints the output and exits with the job's status.
2. **At a hold,** the job's tree is SIGSTOPped and the shell gets SIGUSR1: it prints a
   fixed WAIT line and exits. The round ends, and the queued WAIT is delivered with it.
3. **A held agent's new Bash call is refused at once** with the WAIT text (exit 75). It
   never suspends itself, because a suspended call keeps the round open (Sage's catch B).
4. **The wait command is exempt** from the refusal and is never frozen (Sage's catch A).
   Its Bash timeout is set to the tool's maximum, and it returns STILL WAITING 15 s
   before that, so the harness never backgrounds it (E2: a backgrounded call is how a
   subagent ends up ending its run). It runs the engine file that wrapped the calls.
5. **After release,** the wait prints RESUMED and then the frozen command's own output
   and exit status once it ends: the same process, from the same point.

**Delivery latency, whatever the foreground is doing (a 10-minute build included):**
the hold's first SIGSTOP round plus the shell's exit, measured at 21 to 64 ms from the
SendMessage call to the WAIT row. It no longer depends on the command's remaining time.

## The live run (disposable child, the pause-acceptance work, the worktree's hooks)

The subagent ran the pause-acceptance task: a background counter and a foreground
60 s `step`. The lead sent the generated WAIT 20 s into a step, waited 300 s, then
sent the generated RESUME.

| Measure | Result |
|---|---|
| SendMessage (WAIT) -> the agent's tool call returns with the WAIT line | 11:22:53.265 -> 11:22:53.327 (62 ms) |
| -> WAIT message row in the agent's transcript | 11:22:53.329 (**64 ms**) |
| -> the agent runs the wait command | 11:22:55.484 (2.2 s) |
| Processes frozen by the hold | 4 in 0.04 s, 0.00 CPU s over the next 0.5 s |
| Hold | 320 s (release at 11:28:13) |
| Counter | frozen at n=98 for **319.3 s**; one pid (59736) throughout; n rising by one and the hash chain unbroken over 570 ticks |
| Nothing ended | no completion notice for the agent until the lead ended the test at 11:30:20 |
| While held | two STILL WAITING cycles (the test's bound was 120 s through the declared seam `RICHOS_AGENT_HOLD_WAIT_SECONDS`), each followed by the same wait command |
| RESUME -> RESUMED plus the frozen step's own output | 11:28:12.486 -> 11:28:14.466 (2.0 s); the RESUME row followed 3 ms later |
| After | the agent ran its next steps (counter 327, then 549) and finished when told |

A 60 s dry run with a 25 s bound gave the same shape: WAIT row 50 ms after the send,
counter frozen 72 s at one pid with an unbroken chain, two STILL WAITING cycles.

**The cost of waiting.** Each STILL WAITING cycle is one model turn. In the dry run each
cycle read the context from the prompt cache (about 18,000 tokens read) and wrote about
350 new tokens and 134 output tokens. With the production bound (585 s) a 5-hour
pause is about 31 turns. Whether the cache survives a 585 s gap is NOT measured here
(a probe was started and not finished before the handoff).

## Changes that follow for other code

- `workspace-pause-hold.test.sh` now starts its calls as the harness does (their own
  session) and asserts the new behavior (the call returns the WAIT; a new call is
  refused; the wait runs while held and collects the frozen command's result).
- `pause-acceptance.py` (not changed here): its held-process checks still hold (the
  frozen job and the counter are in the hold record in state T). The wrapper shell
  is no longer in the record because it exits by design. It could also assert WAIT
  delivery directly: `richos-pause-control` in the agent's transcript within seconds.
- `install.sh` must be re-run at land: `shell-evidence.py` changed.
