# G0 feasibility: can the native host carry the owned-outcome contract?

Gate G0 of the owned-outcome PRD, which lives in the private HQ repository (its plans folder,
owned-outcome PRD and acceptance matrix, landed there at `5c22af04`; row G0 of section 8 and the
feasibility paragraph of R6). The PRD is not part of this public repository. Run 2026-09-10 on the CEO's machine,
authorized by the CEO for G0 and nothing beyond it. Written by Sage. Every number below names the
probe that produced it; the harness, hook scripts, settings, keystroke scripts and captured ledgers
are committed beside this file under `G0-FEASIBILITY/` so any reader can rerun a probe.

## Verdict

**G0 BLOCKED.** Five of the six capabilities are proven on the pinned host, with named limits.
The sixth, question presentation control, is blocked for the requirement as the PRD words it:
Claude Code 2.1.267 has no fail-closed interception boundary in front of what the terminal
shows. Every hook that touches presentation proceeds on failure, the assistant-text hook is
display-only and repaints the original text on failure or timeout, the permission dialog is drawn
before its hook runs, and one settings key or one command-line flag switches every hook off.
The blocker and the smallest viable alternative are in section 6. The other five capabilities
are reported in full because G1 will need their limits, not because they change the verdict.

## 1. Pinned host

| Item | Value | Established by |
| --- | --- | --- |
| Claude Code version | `2.1.267` | `claude --version` |
| Binary | `~/.local/share/claude/versions/2.1.267` (symlinked from `~/.local/bin/claude`), Mach-O arm64, 200,489,184 bytes | `readlink -f`, `file`, `ls -l` |
| Binary SHA-256 | `a681f3008f0050029aeebcab3af51bb6a55ddeb625a3af3141a4416d43cd2558` | `shasum -a 256` |
| OS | macOS, Darwin 24.6.0, arm64 | session environment |
| Authentication | claude.ai subscription sign-in from the real credential store (see 2.1) | `probe-auth`: an isolated `CLAUDE_CONFIG_DIR` answers `Not logged in` |
| Model used by every probe | `claude-haiku-4-5-20251001` (`--model haiku`) | transcript `model` attachments |
| Hook events the binary carries | 33 names; the ones this gate rests on are `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `MessageDisplay`, `Stop`, `SubagentStart`, `SubagentStop`, `TeammateIdle`, `SessionEnd` | `strings` on the binary |

Documentation for a newer release was read only as a map. Nothing below is asserted from
documentation; where the documentation and the binary disagree, the binary is reported.

## 2. Method

### 2.1 Disposable environments

Each probe ran in a fresh scratch directory under the session scratchpad with its own pinned
`--session-id`, with `--setting-sources ""` (no user, project or local settings, so none of the
engine's guards were loaded), one explicit `--settings <file>` per probe, and an environment
scrubbed of every `CLAUDE*` and `ANTHROPIC*` variable inherited from the session that spawned
this work (`harness/run-claude.sh`, `harness/ptydrive.py`).

The credential store could not be isolated. Sign-in is bound to the config directory: a foreign
`CLAUDE_CONFIG_DIR` returns `Not logged in · Please run /login` (`results/probe-auth` was
deleted; the run is reproducible with `harness/p00-auth.sh`). I did not copy or export the CEO's
token. The probes therefore used the real config directory for credentials only. Residue this
leaves on the machine is listed in section 9.

An early mis-configured run pointed `CLAUDE_CONFIG_DIR` at `~/.claude` itself, which made the
host create a fresh default `~/.claude/.claude.json` (423 bytes, first-start 06:43:50Z). It was
verified to be that fresh default and removed. The real config file `~/.claude.json` was not
touched.

### 2.2 Instruments

- **Headless probes** (`-p --output-format json`) for contracts that do not involve the screen:
  intake, the Stop-block cap, explicit denial, background sessions.
- **A pseudo-terminal driver** (`harness/ptydrive.py`) for everything that involves the screen.
  It runs the pinned binary interactively in a pty, scripts keystrokes, accepts the workspace
  trust dialog, and records every output chunk with a millisecond timestamp, raw and
  ANSI-stripped. "On screen at t" below means the phrase first appeared in the byte stream the
  terminal received at t; nothing is inferred from a transcript.
- **Hook ledgers**: every hook used is a shell script that appends its full stdin payload with a
  millisecond timestamp before acting (`hooks/`). Hook time and paint time therefore share a
  clock.
- **Ground truth**: session transcripts under `~/.claude/projects/`, team config under
  `~/.claude/teams/`, `claude agents --json`, and process listings.

Everything ran against the live host and the live provider. No fixture executable stood in for
Claude. Roughly thirty haiku sessions were spent, each between one and four cents by the host's
own `total_cost_usd`.

### 2.3 How to reread a probe

`results/<probe>.events.jsonl` is the timeline (`out` chunks are the screen, `send` is a
keystroke, `mark`/`waitfile`/`shell` are harness steps). `results/<probe>-<event>.jsonl` are
the hook ledgers. `results/<probe>.sid` is the session id whose transcript sits under
`~/.claude/projects/` on the machine the probe ran on. `harness/analyze*.py` are the scripts
that produced the numbers quoted here.

## 3. Capability verdicts

| Capability | Verdict | One-line basis |
| --- | --- | --- |
| Intake | **Proven** | `UserPromptSubmit` delivers the typed prompt verbatim with session, prompt and transcript identity before the model runs; exit 2 blocks and erases; teammate messages do not fire it (p01-p04, q08) |
| Team handoff | **Proven** | A named `Agent` call spawns an in-process teammate that receives the brief byte-for-byte, with path-with-spaces and negative constraint intact; team config, `SubagentStart`, `TeammateIdle`, `SubagentStop` all carry identity (q08, q08b) |
| Independent continuation | **Proven in-session and for `--bg` sessions; unknown across a live exit** | Worker kept working 2m12s after the lead went idle and woke it on completion (q08); a `--bg` session finished its work under a daemon detached from the launching shell (p10); "Move to background and exit" kept the session but not its worker's child (q08h) |
| Question presentation control | **Blocked** | No fail-closed pre-display boundary exists: see section 6 |
| Cancellation | **Proven, with a kill-method caveat** | `/exit` with live work offers "Exit and stop tasks" and ends the session in 1.1 s with the worker's child gone (q08g); pty close ends it in about 1.0 s with the child gone (q08e); `claude stop` ends a background session in about 1 s (p10b); SIGKILL of the lead orphans tool children (q08b, q08f) |
| Native exit | **Proven, with named costs** | Idle `/exit` 1.2-1.5 s across ten runs; a hung `SessionEnd` hook delays exit by its whole run (31.4 s for a 30 s hook, q09); with live work `/exit` is a three-way dialog, not an exit (q08f); during a running Stop hook the first Ctrl-C interrupts the hook and two more exit (q09c, q09d) |

## 4. The adversarial conditions the gate names

| Condition | What the host does | Probe |
| --- | --- | --- |
| Hooks disabled (`"disableAllHooks": true` in settings) | No hook runs at all: the prompt proceeds, the question shows, no ledger row is written | p04, q04 |
| Hooks disabled by flag (`--bare`, `--safe-mode`) | Declared by `claude --help` to skip hooks; not separately exercised | `claude --help` |
| Hook exits 1 | `UserPromptSubmit`: prompt proceeds (p02). `PreToolUse`: tool proceeds, the `AskUserQuestion` dialog paints 33 ms after the hook was invoked (q05b). `PermissionRequest`: dialog stays for the user (q07b). `MessageDisplay`: original text painted 23 ms after the hook was invoked (q02) | p02, q02, q05b, q07b |
| Hook hangs past its timeout | `MessageDisplay`: the line is held back for the timeout, then the original is painted (hook at 9,555 ms, original on screen at 24,475 ms, timeout configured 15 s) (q03b). `SessionEnd`: exit waits for it (q09) | q03b, q09 |
| Hook exits 2 | `UserPromptSubmit`: prompt blocked and erased, `num_turns` 0, result text `UserPromptSubmit operation blocked by hook` (p03). `Stop`: honored nine times in a row, then the turn ends silently with an empty result (p05) | p03, p05 |
| Explicit permission denial in settings (`"deny": ["Bash(touch:*)"]`) | Refused with no dialog, listed in `permission_denials`; a `PreToolUse` hook answering `allow` for the same call does not override it (p06, p07). The `PermissionDenied` hook did not fire for a rule denial in print mode | p06, p07 |
| Explicit denial by the user at a dialog | Tool result `The user doesn't want to proceed with this tool use ... STOP what you are doing and wait for the user` (q07b) | q07b |
| Explicit denial of the question tool (`"deny": ["AskUserQuestion"]`) | The tool is absent from the model's tool set; no call is attempted; the model reports `TOOL-REFUSED: AskUserQuestion tool is not available in this session` (q06) | q06 |

The pattern is uniform: **every hook the host offers proceeds on failure**, and the only
fail-closed controls are settings rules, which are not hooks and do not see content.

## 5. Capability detail and reproductions

### 5.1 Intake (proven)

Reproduction: `bash harness/p01-intake.sh` (four headless runs, one per condition).

- Healthy hook (p01): the `UserPromptSubmit` payload carries `session_id`, `prompt_id`,
  `transcript_path`, `cwd`, `permission_mode`, `hook_event_name` and the prompt text verbatim
  (`results/p01-prompt.jsonl`). The assignment then ran: the backlog item B1 produced
  `hello.txt` and the reply `DONE hello.txt` in three turns.
- Failing hook (p02): prompt proceeds; a ledger row was still written before the failure.
- Blocking hook (p03): prompt never reaches the model.
- Disabled hooks (p04): no ledger row, work proceeds.
- The Stop payload carries `last_assistant_message`, `stop_hook_active`, `background_tasks`
  and `session_crons` (`results/p01-stop.jsonl`), which is enough for a supervisor to see what the
  turn claimed and what it left running.
- Provenance (observed once, q08): the teammate's completion arrived in the lead as a `user`
  role message wrapped in `<teammate-message teammate_id="worker-a">` and prefixed
  `Another Claude session sent a message:`, and **did not** fire `UserPromptSubmit`
  (`results/q08-userpromptsubmit.jsonl` has one row, the typed prompt). A ledger of
  `UserPromptSubmit` payloads is therefore a ledger of typed prompts, at least for this message
  class. R2's structural-provenance requirement still needs the transcript's own fields for
  cross-session messages and system reminders; that is G1 work, not a G0 blocker.

Limit: intake persistence lives in a hook, and a hook that fails is skipped. R1's rule that a
failed persistence must not be reported as durable ownership is the integration's to keep; the
host gives it the event and the exit-2 lever, nothing more.

### 5.2 Team handoff (proven)

Reproduction: `bash harness/runq.sh q08 --permission-mode acceptEdits` after `python3 harness/gen2.py`
(paths inside the generator are absolute to the scratchpad that ran them; edit `S` to rerun).

- The lead called `Agent` with `name: worker-a` and the brief; `SubagentStart` fired at
  12,175 ms with `agent_id` and `agent_type`; `~/.claude/teams/session-<id>/config.json`
  listed `team-lead` and `worker-a` with `backendType: in-process` (`results/q08.events.jsonl`,
  the first `shell` step).
- The worker's transcript opens with the brief byte-for-byte inside
  `<teammate-message teammate_id="team-lead" summary="...">`; the quoted path with spaces and
  the sentence `do NOT modify BACKLOG.md` are present (`harness/analyze3.py q08`).
- `TeammateIdle` (146,187 ms) and `SubagentStop` (146,133 ms) carried `teammate_name`,
  `agent_transcript_path` and `last_assistant_message: WORKER DONE A`; the lead woke, read the
  idle notification and replied `LEAD SAW: WORKER DONE A`, ending its second turn at 148,305 ms.
- Repeated in q08b with the same shape (worker finished in 27 s; lead replied at 29 s).

Two things G1 must plan for, both observed in the lead's terminal:

1. **A teammate's permission dialog renders in the lead's terminal.** The worker's `ls` of a
   directory outside the working directory raised `Bash command · from the worker-a agent ...
   Do you want to proceed? 1. Yes 2. Yes, allow reading from <dir> from this project 3. No`,
   although `Bash(ls:*)` was allow-listed (q08 at 15,225 ms; q08b at 13,504 ms). The dialog is a
   directory-read grant, not a command grant.
2. **Twice that dialog resolved with no input, and the command ran.** q08b: painted at
   13,504 ms, tool result at about 15,600 ms. q08: painted at 15,225 ms, tool result at about
   135,700 ms. The driver sent no keystrokes in either window (`harness/analyze5.py`), and no
   permission record appears in either transcript. The single-session control (q11: same
   command, same allow rule, no teammate) painted the same dialog at 8,374 ms and was still
   waiting at 155,434 ms. **The mechanism is unknown.** Nothing in this gate depends on it, but
   acceptance row A23 must reproduce it before any policy assumes a teammate's dialog waits for
   a person.

### 5.3 Independent continuation (proven in two forms, unknown in the third)

**In-session (proven, q08).** The lead's turn ended at 13,546 ms (`SPAWNED`); the worker
continued for a further 2m12s and finished at 146,133 ms; the lead's next turn began on the
worker's notification without any user input. The `background_tasks` field of the lead's first
Stop payload listed the running teammate. This is the shape a supervisor inside one session
can rely on.

**Detached background session (proven, p10 and p10b).** `claude --bg '<prompt>'` printed
`Starting background service…` and an id, spawned `claude daemon run --origin transient` whose
parent became pid 1, and ran the session under a pty host owned by the daemon. The launching
shell exited; the session ran `sleep 45` and wrote `bg-done.txt` containing `DONE`;
`claude agents --json` listed it as `kind: background`, `status: idle`, `state: done`;
`claude stop <id>` answered `stopped` within a second; the daemon had retired within 18 s of
the last session stopping. Reproduction: `bash harness/p10-bg.sh` then
`bash harness/p10b-bg-stop.sh` (the second script carries the id printed by the first).

**Carrying a live session across exit (unknown, leaning negative, q08h).** With a worker in a
foreground `python3 -c "import time; time.sleep(300)"`, `/exit` offered
`1. Exit and stop tasks  2. Move to background and exit  3. Stay`. Choosing 2 ended the terminal
in 1,767 ms and `claude agents --json` listed a new background session for the same working
directory, but the worker's child process was gone within 4 s and the background session
reported `state: blocked`; its log showed the lead at its prompt with the teammate spawned and
nothing further. One run, one observation: the session moves, the work does not follow.

**Orphans are not continuation.** After the lead was killed with SIGKILL, a backgrounded
`sleep 240` (q08b, pids 22026/22034) and a foreground python sleep (q08f, pid 57492) kept
running with no owner; the q08f orphan was found alive three minutes later and killed by hand.
After a pty close (q08c, q08d, q08e) and after `/exit` with "Exit and stop tasks" (q08g) the
children were gone within 3 s. Kill method decides whether work survives, which is the finding
the R7 review already recorded and this gate confirms on 2.1.267.

Limits from the host's own documentation and consistent with the observations: in-process
teammates cannot outlive the lead's process, their background work is refused, and `/resume`
does not restore them. A supervisor that must survive the lead therefore has exactly one native
primitive on this version, the `--bg` session under the transient daemon, and that primitive was
not tested under daemon death, logout or reboot.

### 5.4 Question presentation control (blocked)

The literal requirement is that a routine question the model generates never reaches the
CEO's screen, dialog, notification or spoken reply, while conversation stays usable, and that
the mechanism does not reveal the original when it fails. On the native terminal a question can
reach the screen on three channels. Each was probed healthy, failing and disabled.

**Channel 1: assistant prose.** The only host lever is `MessageDisplay`. The binary describes
it as `Display-only: replaces the delta on screen without changing the stored message` and
carries the string `MessageDisplay hook failed for completed message; emitting original text`.

| Probe | Hook | Result on screen |
| --- | --- | --- |
| q01 | healthy, returns `displayContent` for any delta containing `?` | The original question sentence never appeared in the byte stream; `[ROUTINE QUESTION WITHHELD BY G0 FILTER]` was painted 27 ms after the hook fired. The stored message still contains the question and the model still stopped to wait for an answer |
| q02 | exits 1 | Original sentence painted 23 ms after the hook fired |
| q03b | hangs past its 15 s timeout | Nothing shown for 14.9 s, then the original sentence painted |
| q04 | `disableAllHooks: true` | Original sentence painted; no hook ran |

So the prose filter works only while it is healthy, and its failure mode is the exact one the
PRD names as insufficient. It is also display-only: after the replacement the turn has still
ended on a question, so continuing needs a Stop-hook redirect, which is the post-Stop correction
the PRD likewise names as insufficient, and which the host caps (section 7.1).

**Channel 2: the `AskUserQuestion` dialog.**

| Probe | Control | Result |
| --- | --- | --- |
| q05 | `PreToolUse` on `AskUserQuestion` answers `deny` | No dialog; the model received the reason and replied `TOOL-REFUSED` as instructed |
| q05b | same hook exits 1 | The dialog painted 33 ms after the hook fired (`Which filename should I use for the output? 1. alpha.txt 2. beta.txt 3. Type something 4. Chat about this`) and the session waited on it; the harness's next keystrokes answered it |
| q05c | `PreToolUse` deny, prompt permits a plain-text fallback | No dialog; the model asked the same question in prose: `Which filename should I use for the output — alpha.txt or beta.txt?` |
| q06 | settings `"deny": ["AskUserQuestion"]`, no hook | The tool never reached the model; no call attempted; `TOOL-REFUSED: AskUserQuestion tool is not available in this session` |

The settings deny is the one fail-closed control found, and it costs the dialog for genuine
business questions too. Either way the question moves to channel 1.

**Channel 3: permission dialogs.**

| Probe | Control | Result |
| --- | --- | --- |
| q07 | `PermissionRequest` sleeps 6 s then answers `deny` | `Do you want to proceed? 1. Yes 2. Yes, and always allow ... 3. No` painted at 7,616 ms; the hook's ledger row is at 7,799 ms; `Denied by PermissionRequest hook` painted at 13,845 ms. The dialog was on screen for about 6.2 s before the hook resolved it |
| q07b | same hook exits 1 | Dialog stays until answered; Escape produced `Interrupted · What should Claude do instead?` |
| q08, q08b | teammate's dialog | Rendered in the lead's terminal (5.2 above) |

The permission hook can decide, but it cannot pre-empt display: the host draws the dialog and
runs the hook concurrently. This reproduces on 2.1.267 the flash recorded in
`docs/verification/owned-outcome/NATIVE-PERMISSIONS-4.md`.

**The in-process "hooks modules" API.** The binary carries a native plugin surface with
`ui.render`, `$.ui.ask`, `prompt.section`, `prompt.context`, `tool.describe` and
`command.describe`, and a `ui.render (AskUserQuestion)` path that can relabel questions. It also
carries `hooks modules not loaded: rollout flag (` and `not seated: hooks modules are off in
this process`. Its availability on this binary is **unknown**; it is not exposed by
`claude --help`, and I did not attempt to flip an undocumented rollout flag. If it ships enabled
in a later version and its failure mode is fail-closed, the verdict changes and must be rerun
against that version.

**What this means for the requirement.** On the native terminal every interception the host
offers is fail-open and every one of them can be switched off by one settings key or one flag.
A supervisor built on them can promise "withheld while healthy, revealed when not". It cannot
promise "never shown", and the PRD says not to weaken the wording silently.

### 5.5 Cancellation (proven with a caveat)

| Action | Observed | Probe |
| --- | --- | --- |
| Escape during a turn or a dialog | `Interrupted · What should Claude do instead?`; the pending tool call is reported to the model as user-rejected | q07b, q09c |
| `/exit` while a teammate and its shell child are live | Three-way dialog; "Exit and stop tasks" ended the session in 1,092 ms and the child was gone 3 s later | q08f, q08g |
| Terminal closed (pty master closed) with a live foreground child | Session ended in 1,008-1,050 ms (exit status 0 in two runs, 129 in one), `SessionEnd` fired with `reason: other`, child gone within 3 s | q08c, q08d, q08e |
| `claude stop <id>` on a background session | `stopped` within about 1 s; listing cleared; daemon retired within 18 s | p10b, p12 |
| SIGKILL of the lead | Backgrounded and foreground tool children survive with no owner | q08b, q08f |

Not probed: the teammate `shutdown_request` protocol and the agent-panel `x` key.

### 5.6 Native exit (proven with named costs)

| Situation | Exit latency after the exit request | Probe |
| --- | --- | --- |
| Idle, `/exit` | 1,309 / 1,493 / 1,354 / 1,532 / 1,330 / 1,315 / 1,238 / 1,429 / 1,325 / 1,379 ms | q00, q01-q07, q03b, q08 family |
| Idle, Ctrl-C twice | 1,318 ms | q09b |
| Stop hook still running (40 s sleep), Ctrl-C twice | Not exited after 60 s: the first press interrupted the hook, the second showed `Press Ctrl-C again to exit` | q09c |
| Stop hook still running, Ctrl-C three times | 1,402 ms | q09d |
| `/exit` with a `SessionEnd` hook that sleeps 30 s (timeout 60 s) | 31,446 ms | q09 |
| `/exit` with live teammate work, no answer to the dialog | Not an exit; a dialog | q08f |
| Terminal closed | about 1.0 s | q08c, q08e |

The host does not enforce the PRD's 2 s bound on integration-caused exit delay; it runs
`SessionEnd` hooks to completion up to their configured timeout. The bound is the integration's
to keep through hook timeouts and hooks that do nothing slow at exit.

## 6. The blocker and the smallest viable alternative

**Blocker, precisely.** Claude Code 2.1.267 offers no dependable interception boundary in front
of its own presentation surface. Assistant text can only be rewritten by a display-only hook
that repaints the original on error (23 ms, q02), on timeout (14.9 s, q03b) and when hooks are
disabled (q04). The question dialog can be prevented by a hook that fails open (33 ms, q05b) or
removed by a settings rule that also removes it for legitimate questions and pushes the model
to prose (q05c, q06). The permission dialog is painted before its hook runs (q07). All of it is
switched off by `disableAllHooks`, `--bare` or `--safe-mode`. The literal "never asks"
therefore cannot be established on this surface without a host change: a pre-display hook that
fails closed, or the gated in-process render API shipping enabled with fail-closed semantics.

**Smallest viable alternative, as one product decision for the CEO.** Two surfaces, two
contracts, stated openly:

1. **RichOS keeps the literal contract.** RichOS runs Claude with `--print
   --input-format=stream-json --output-format=stream-json ... --permission-prompt-tool stdio`
   (`app/crates/richos-core/src/native.rs`, `child_args`). In that mode nothing is drawn by the
   host; the application decides what a person sees and answers permission requests itself.
   "Never shows a routine question" is then a property of RichOS code, testable with
   deterministic fixtures and independent mutations, and failing closed by construction because
   an unrendered message is not shown. G0 did not test RichOS; it establishes that the boundary
   exists there and not on the terminal.
2. **The native terminal gets the weaker contract, in writing.** "Routine questions are withheld
   while the integration is healthy (MessageDisplay replacement plus a settings deny of
   `AskUserQuestion` plus a Stop-hook redirect inside the host's cap) and are shown when a hook
   fails, times out or is disabled." That is "usually recovers", which the PRD forbids as a
   silent substitution and permits as an explicit one. If the CEO does not accept it, the
   native terminal stays an inspection surface and the femcboost native workflow is not an
   acceptance surface for R6 until the host changes.

Neither option adds a guard. Both are cheaper than the weeks a terminal wrapper would cost, and
a wrapper would still sit behind the same fail-open hooks for everything it did not re-implement.

## 7. Findings that bind G1 even though they do not change the verdict

### 7.1 The Stop-hook cap is nine

A Stop hook that always exits 2 was honored nine times (once with `stop_hook_active: false`,
then eight with `true`), after which the host ended the turn with an empty result and no
message on stderr (`results/p05-stop.jsonl`, `results/p05.json`: `num_turns` 10, `result` `""`).
The binary names the lever: `Set CLAUDE_CODE_STOP_HOOK_BLOCK_CAP to raise this limit`. R4's rule
that supervision must not depend on refusing Stop is therefore not only doctrine; the host will
end the loop and say nothing.

### 7.2 Standalone `sleep` is blocked for the model

A worker's `sleep 25` was refused by the host with `Blocked: standalone sleep 25. To wait for a
condition, use Monitor with an until-loop`, in a session with no user settings loaded (q08,
q08b, q08d). Test fixtures that model long-running work must not use bare `sleep`.

### 7.3 The background-session listing is a listing, not a decision state

`claude agents --json` reports `status` and `state` (`busy`/`working`, `idle`/`done`,
`idle`/`blocked`). "blocked" appeared for the session that lost its worker's child on the move
to background (q08h). What it means is not documented; G1 should not read it as a decision
pending.

### 7.4 Hook payload fields worth keeping

`PreToolUse` and `PermissionRequest` payloads on 2.1.267 carry `scratchpad_dir` and
`permission_suggestions`; `PermissionRequest` omits `tool_use_id` (as NATIVE-PERMISSIONS-4
recorded) while `PreToolUse` carries it; `SubagentStop` carries `agent_transcript_path` and
`last_assistant_message`. The `PermissionDenied` event did not fire for a settings-rule denial
in print mode (p06).

## 8. What I did not do, by choice

- Did not try to enable the in-process hooks-modules API through its rollout flag; an
  undocumented switch is not a supported boundary.
- Did not install tmux or test split-pane teammates; the CEO's sessions run in-process.
- Did not probe the teammate shutdown protocol, `/resume` after a lead crash, daemon death under
  `--bg`, voice, or any long-history case; those are G1/G3 rows, and the PRD's section 9 sequence
  is not a G0 deliverable.
- Did not test RichOS's own presentation; section 6 states where its boundary lies from source,
  not from a run.
- Did not repeat probes for statistics. Each number is one run unless a count is given; ten idle
  exits and three pty closes are the only repeated measurements.

## 9. Residue on the machine, and what was removed

Left in place, all under the retention sweep and all keyed to scratch paths:
session transcripts under `~/.claude/projects/-private-tmp-claude-501-...-scratchpad-env*`
(one directory per probe, including four with the fixed ids `11111111-1111-4111-8111-1111111111{01..05}`
from the first, unauthenticated attempt); trust entries for those scratch directories in
`~/.claude.json` written when the driver accepted the workspace dialog; the scratchpad itself.

Removed or ended: the stray `~/.claude/.claude.json` (section 2.1); the `--bg` session
`4be2606e` and the moved session `690ff24e` (`claude stop`); the transient daemon retired on its
own; orphaned probe children (`sleep 240`, two python sleeps) killed by hand. A final process
sweep found no probe process alive. No file under `~/.claude/settings.json`, the engine, femcboost
or richos-hq was changed.

## 10. Verdict line

**G0 BLOCKED** — capability blocker: question presentation control on the native Claude Code
2.1.267 terminal has no fail-closed pre-display boundary (assistant text: display-only hook that
repaints the original on failure, timeout and disable; question dialog: fail-open hook or
tool-wide settings deny that shifts the question to prose; permission dialog: painted before its
hook runs). Smallest viable alternative: keep the literal contract on RichOS, where the
application renders and answers permissions in print mode, and put the weaker "withheld while
healthy" contract for the native terminal to the CEO once, in writing, before further spending.
Intake, team handoff, in-session and `--bg` continuation, cancellation and native exit are
proven on this host with the limits recorded above.
