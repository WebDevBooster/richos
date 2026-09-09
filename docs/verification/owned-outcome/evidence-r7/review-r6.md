# Verdict: ACCEPT WITH NAMED CONDITIONS — merge `125906f5`; C7 and C8 are CLOSED, the housekeeping findings are CLOSED; C3 is NOT CLOSED, and the Claude Code surface stays inactive until C10 and C11 below are met.

Reviewer: Sage (`sage-fable-r6`), 2026-09-09, on the CEO's direct order ("Next for Sage on Fable to review"). Reviewed
commit `125906f5f02057091f3e427b5a89cfda834fcfa4` (`codex/owned-outcome-completion`), the single commit since the
revision my predecessor reviewed (`git log --oneline d8afbc1f..HEAD` → one line, `125906f5 Reconcile restarted
ownership immediately and surface withheld recovery`; `git status --porcelain` in the Codex worktree → empty), checked
out in `/Users/alex/ab/richos-wt/sage-fable-r6`. Merge-base with richos main (`3be0364a`) is `d8afbc1f` (`git merge-base
HEAD 3be0364a`), which is already on main. Nothing under the Codex worktree was written. Nothing here was implemented
or fixed. Every number below carries the command that produced it or the word `unverified:`.

Read in full before starting: the femcboost record
`femcboost/docs/reviews/structural-failure-unacceptable-results-as-user-decisions-2026-09-09.md` (private repository,
not in this tree) and `docs/reviews/sage-fable-r5-owned-outcome-2026-09-09.md` (landed on richos main at `8646f407`,
merged at `3be0364a`; this branch's base predates it, so the r1, r4 and r5 reviews are brought into this branch
byte-identical to main — `shasum -a 256` → `8213a874…`, `eae0eefc…`, `b9e9f634…` on both sides — so the citations
resolve here). This review re-ran the predecessor's probes from his scratchpad rather than inheriting his results,
and it presents the CEO with no choice anywhere: what is unfinished is named as unfinished.

## What the verdict means

**Merge-safe today, as `d8afbc1f` was.** The commit touches the two engine libraries and their tests, one new
harness, four documents and 145 evidence files (`git diff --stat d8afbc1f..125906f5` → `155 files changed, 12447
insertions(+), 23 deletions(-)`; `git diff --numstat … | grep -v evidence-r6` → 10 files: `owned-session.py`
+143/−18, `owned-dispatch.py` +6/−2, `owned-session.test.py` +187, `owned-dispatch.test.py` +23,
`app/scripts/test-owned-recovery.py` +398, `RESULTS-6.md` +130, `REVISION-6.md` +111, `IMPROVEMENTS.md` +20/−2,
`REVIEW.md` +2/−1, `app/README.md` +3). No Rust, UI, hook-registration or engine-guard source changed. The engine
suite passes from this checkout (`bash engine/scripts/hooks/ceo-asks.test.sh` → `67/67 cases passed`, `27/27
properties proven load-bearing`, exit 0). No workspace on this machine is adopted (`ls .claude/owned-work.json` in
femcboost, richos, richos-hq → all `No such file or directory`; `ls ~/.claude/state/richos-owned-work` → `No such
file or directory`; `readlink ~/.claude/richos-engine` → `/Users/alex/ab/richos/engine`).

**Not activatable on the Claude Code surface yet.** Both of the predecessor's blockers are genuinely gone as he
worded them: a replacement that inherits an exhausted inspection burst now reconciles at once (C7), and withheld
recovery is visible with exact process identities on both hook channels (C8). What stops activation is a defect on
the **same-ID resume path** that no prior round could see because every real trial killed the leader with `killpg`:
under the real host, hooks run in their own process group, so a dead leader's sleeping audit hook survives the crash
as an orphan, still holds that session's `.audit-lock`, still passes the ownership check (which never looks at the
process), and **spends the replacement's one reconciliation credit and prints the wake to a parent that no longer
exists** — the replacement never wakes and its own audits sit in the hour sleep. That is the assignment's target
failure ("the CEO restarts, sees nothing happen, types continue") re-entered through a new door. It is small,
specified below, and it is not a trade-off for the CEO.

## Numbers I reproduced

| Claim (RESULTS-6 / handoff) | Reproduced here | Command | Result |
|---|---|---|---|
| Native adapter 119 | **Yes** | `python3 engine/scripts/lib/owned-session.test.py` | `Ran 119 tests in 3.395s … OK`, exit 0 |
| Cached dispatch 33 | **Yes** | `python3 engine/scripts/lib/owned-dispatch.test.py` | `Ran 33 tests in 0.231s … OK`, exit 0 |
| Process integration: 3 cases, 44 checks, zero provider calls | **Yes** | `python3 app/scripts/test-owned-recovery.py --output <scratch>` | `fresh-exhausted-budget PASS`, `resume-exhausted-budget PASS`, `live-straggler-recovery PASS`, `PASS actual-process recovery acceptance; no provider calls`; `result.json` → `passed=True source_unchanged=True provider_calls=0`, checks 12+12+20 = **44**, none failing |
| Reconciliation timings 0.186 s / 0.093 s / 5.324 s | **Consistent** | same run, `reconciliation_timing.elapsed_seconds` | `0.221` / `0.089` / `5.312` s against deadlines 4 / 4 / 8 s |
| Engine 67 cases, 27 mutation properties | **Yes** | `bash engine/scripts/hooks/ceo-asks.test.sh` | `67/67 cases passed`, `27/27 properties proven load-bearing`, exit 0 |
| Disposable installer, three sidecars, pointer unchanged | **Yes, from my worktree** | `python3 docs/verification/owned-outcome/evidence-r6/install-check.py --repo /Users/alex/ab/richos-wt/sage-fable-r6` | `exit 0`, `checks` all `true`, `production_pointer_unchanged: true`, exit 0 |
| Evidence index verifies | **Yes, public only** | `python3 docs/verification/owned-outcome/evidence-r6/verify-evidence.py --public-only` | `verified_artifacts 142, explicitly_skipped_private 54, source_files 10, unexpected_files 0`, exit 0; the private archive directory `/Users/alex/.codex/artifacts/richos-owned-outcome-r6-2026-09-09` exists and was not opened |
| Final adapter `2b29c6ef…`, harness `6f94e22d…` are the tree | **Yes** | `shasum -a 256` | `2b29c6ef6447…52e178` (`owned-session.py`), `6f94e22d5bc9…f1c156` (`test-owned-recovery.py`), `950eeb2330c9…3a593` (`owned-dispatch.py`) — match `integration-final/result.json` and `installer-final/result.json` |
| "Both changed library hashes stayed unchanged throughout the final run" | **Yes** | `../evidence-r6/checks/engine-final-result.json` | `source_before == source_after`, `source_unchanged: true`; the first run's `engine-result.json` honestly records `16ff3f14… → 2b29c6ef…`, `source_unchanged: false` |
| "Real native registry probe … one live owner matched after date parsing" | **Yes** | `scratchpad/probe-f3-registry.py` (read-only) | `pid 20597: registry='Wed Sep  9 09:16:05 2026' ps='Wed 9 Sep 09:16:05 2026' epoch_equal=True (r5 raw-string compare was False)` |
| Independent peer review 32 + 1 (subsets of the 119) | **Read, not rerun** | `../evidence-r6/checks/echo-recovery-review.log`, `../evidence-r6/checks/echo-ownership-fence.log` | `Ran 32 tests … OK`, `Ran 1 test … OK` |
| README claims check, six PASS | **Read** | `../evidence-r6/checks/docs-claims.log` | 6 `PASS` lines; Rust inventory unchanged (`richos-core=1103+5`) |
| Preserved first integration run failed on the harness's own deadline | **Yes** | `integration-first/result.json` | `passed=False`; only `one_immediate_reconciliation_without_hour_sleep` false on the straggler case; the adapter and harness of that run retained |
| Real-provider trials | **None in R6** | — | RESULTS-6 says so; R5's seven trials retain their own hashes |

Runtime: `claude --version` → `2.1.266 (Claude Code)`; `date +%Z` → `BST`; `ps -axo pid=,ppid=,pgid=,lstart=,comm=`
(781 rows) → `real 0.02` s, three runs; `cc` → Apple clang 17.0.0.

## Conditions from R5, ruled one by one

### C7 — CLOSED. A replacement that inherits an exhausted burst reconciles at once, once per real transfer.

Mechanism (`owned-session.py`): `recover_session` builds `transfer_sources` from every dead session it takes
(`:328-347`) and, when the state has human authority and is not finished, appends a `recovery_checkpoints` entry
whose id is the sha256 of `{sources, destination:{session, process}}` (`:392-397`), so a second SessionStart from the
same process computes the same id and adds nothing. `audit_once` treats an unclaimed ticket for its own destination
as a bypass of the retry sleep (`:919-921`), marks it `claimed_at` inside the pacing lock before inference
(`:936-937`), and never lowers `audit_attempts` — counters and the hour deadline are inherited exactly as before.

Probes. The predecessor's own probe A, rerun against this adapter (`scratchpad/probe-c3-r6.py`, his file with the
library path changed and `AssertionError` caught):

```
=== A: restart after burst exhaustion
 replacement recovered: ['old'] attempts 5 inherited delay s 3000 recovery_requires_review True event SessionStart
 native_completion_batch at SessionStart: None
 audit_once -> inspector called (IMMEDIATE: inspector reached without sleeping)
 dispatch/register during window: RecoveryPending -> Recovered assignment is awaiting independent reconciliation; …
```

In R5 the third line read `WOULD SLEEP`. The harness reproduces it with real processes and the shipped CLI: fresh
`0.221 s` and same-ID `0.089 s` from `audit SessionStart` to a returned verdict, with the saved `retry_at` 3,000 s
out, `audit_attempts` 6 afterwards, one inspector call, one ticket claimed, and repeated `SessionStart`/`Stop`
callbacks buying nothing (`repeated_start_stop_cannot_buy_inspection_credit: true`). Pinned by
`test_exhausted_restart_reconciles_immediately_once_per_actual_process` (sleep patched to fail; a duplicate boot
during inference cannot refill; a later real process gets a second ticket; a failed inspector call still consumes it)
and `test_reconciliation_crash_reservation_survives_duplicate_start_and_reclaim`. The `RecoveryPending` refusal on
the last line is correct: it lasts only until the immediate inspection returns, which clears
`recovery_requires_review` (`:977`) whether the verdict is `incomplete` or the call failed.

### C8 — CLOSED as worded; and the question the brief put at the center is answered below.

C8 asked that withheld recovery be visible to the replacement with the blocking process identities. It is.
`recover_session` no longer skips a live-looking owner silently: it records `recovery_blocker` rows (`:162-168`:
`session`, `owner_process`, `reason` ∈ {`live_leader`, `residual_process_group`, `unknown_ownership`}, exact
`live_processes` with pid/ppid/pgid/start/command) into `withheld_recoveries` (`:346`, `:377`), and
`withheld_recovery_message` (`:171-184`) is emitted on both channels of the SessionStart capture
(`systemMessage` and `additionalContext`, `:1374-1376`) and as a host-only exit-2 wake from the audit hook, once per
distinct blocker set (`:875-879`), with no inspector call. The predecessor's probe B, rerun with its `main()` argv
corrected (his copy passed an extra positional argument, so `argparse` exited and the "no notice" line in R5 was an
artifact of the probe; the finding itself was real by code reading):

```
 owner_is_live(dead claude 101, orphan sleep in pgid 101): True
 replacement recovery_obligations: None | messages: 0
 journal old owner still: old
 SessionStart additionalContext mentions withheld/recovered work: True | systemMessage: 'Unfinished owned work is
 withheld because another native owner may still act. … BLOCKING NATIVE IDENTITIES (observations, not authority):
 [{"live_processes": [{"command": "sleep", "pgid": 101, "pid": 555, "ppid": 1, "started": "start-555"}], …
 "reason": "residual_process_group", "session": "old"}]'
```

The harness's `live-straggler-recovery` case does the same with a real `sleep` in a real dead leader's group:
`withheld_notice_visible_on_both_channels`, `empty_replacement_gets_host_only_wake` (exit 2, pid in stderr, zero
inspector rows), `unchanged_blocker_does_not_repeat_wake`, then a scripted `SIGTERM` of that exact pid and
`same_outstanding_stop_hook_picks_up_after_exit` in 5.3 s (`:885-893`, 5 s poll). Pinned by
`test_withheld_straggler_is_visible_wakes_once_and_same_owner_rechecks`,
`test_mechanical_watch_picks_up_later_exit_without_input_or_paid_poll`,
`test_concurrent_withheld_callbacks_reserve_only_one_host_wake`, `test_watch_timeout_refresh_is_durable_and_hourly_paced`.

### C3 — NOT CLOSED. Fresh-session pickup is repaired; same-ID resume pickup loses its wake to the dead session's own hook.

**What is established.** On the fresh path, with the host's real process layout (measured below), a crash in the
hour regime is picked up automatically: probe B2 (`scratchpad/probe-r6-straggler.py`, real fixture processes,
shipped CLI, fake inspector, the old leader's audit hook launched detached as the host launches hooks, leader killed
by `SIGTERM` to its pid only):

```
 old_hook_survives_leader_death: true        old_hook_in_leader_pgid: false
 withheld_reason: []                          (transfer at SessionStart capture)
 sessionstart_audit: exit 2, 0.086 s, "Rich still owns unfinished authorized work. Continue without a CEO nudge…"
 old_hook_lifetime_s: 3.9   inspector_called_for_dead_leader: 0   (orphan fenced by the revision bump, no paid call)
 final: audit_attempts 6, ticket claimed, verdict incomplete, checked set
```

The orphan dies within seconds because `recover_session` re-captures the old state (`:340`), bumping its revision,
and the orphan's next `assert_current_owner` sees `owner != session` and exits 0 — the R5 fence
(`test_superseded_hooks_cannot_write_dispatch_tools_or_wake`) doing exactly its job.

**Why it is not closed.** Probe A2, identical but the replacement resumes the **same session ID**:

```
 old_hook_survives_leader_death: true        old_hook_in_leader_pgid: false
 withheld_reason: []                          (transfer at SessionStart capture; ticket minted)
 sessionstart_audit: exit 0, 0.068 s, ""      ← the replacement's audit found the .audit-lock held and returned
 inspector_calls_6s_after_start_before_any_replacement_stop: 1
 orphan_alive_6s_after_start: false
 orphan_stderr_6s: "Rich still owns unfinished authorized work. Continue without a CEO nudge…"   ← printed to a dead parent
 state_6s: ticket claimed, verdict incomplete, audit_attempts 6, recovery_requires_review cleared
 replacement_second_sessionstart_audit: exit None (timed out at 6 s — it is in the hour sleep)
 replacement_ever_got_exit2_wake: false
```

Three lines make this so. The orphan and the replacement share one state path and one `.audit-lock`
(`location(root, session)`, `:96-98`), the replacement's audit takes that lock non-blocking and returns 0 when it is
held (`:869-871`), and `audit_once` verifies ownership by session only — `assert_current_owner(...)` without
`require_process` at entry (`:867`), in the sleep loop (`:923-926`, which checks only `revision`) and after inference
(`:970`) — so a hook whose leader is dead is indistinguishable from the replacement's own. The orphan wakes on the
capture's revision bump, re-enters, finds the ticket the replacement just minted, claims it (`:936-937`), runs the
inspection, writes the verdict, and exits 2 into nothing. The replacement then has a claimed ticket, no checkpoint,
`retry_at` an hour out, and no wake. Case A of the same probe (hook left in the leader's group, the fixture's
layout) shows the same lock loss on the withheld path: `sessionstart_audit: exit 0`, the orphan emitting the withheld
notice itself and consuming `withheld_notice_key`, so the observer never receives the notice-wake either.

**Reachable.** Same-ID resume is one of the two restart modes this assignment covers and R5 trialed
(`app/scripts/test-owned-wake-native.py:502`, `:1153`, `['--resume', session_id]`); the hour regime is where most of
an assignment's life is spent (predecessor, C3); and a sleeping audit hook exists throughout it. Whether the
replacement's audit loses the lock depends on the host starting the SessionStart `capture` and `audit` hooks
concurrently (the audit then starts while the orphan is mid-sleep and holds the lock continuously) or sequentially
(a ~1 s race, since the orphan checks `revision` once a second). `unverified:` which the host does — settled by the
C11 trial. R5's paid resume trial could not see any of this because the harness killed the leader's whole group
(`test-owned-wake-native.py:182`, `:1404`: `os.killpg`), which takes the hook with it; a real crash does not.

**Ruling.** Cross-session pickup exists and is proven on the fresh path with real processes; the "or explicit CEO
scoping" half of C3 stays moot. The condition is NOT CLOSED because the resume path, under the host's real process
layout, hands the replacement's single reconciliation to a dead session's hook and leaves the replacement idle until
the CEO types. The fix is small and specified under C10; the trial that would have caught it is C11.

### C4 (Rich, at land) — must be discharged AGAIN for this commit.

Both libraries changed. richos main's sidecars carry the R5 hashes (`cat
/Users/alex/ab/richos/engine/scripts/lib/owned-session.py.sha256` → `03b43e7f…`; `owned-dispatch.py.sha256` →
`8592e473…`; `owned-work-policy.sh.sha256` → `9969f9af…`, unchanged), while this commit's are `2b29c6ef…` and
`950eeb23…`. `bash engine/scripts/hooks/install.sh` from the landed checkout; the disposable rerun above shows it
produces matching sidecars.

### C9 (housekeeping) — CLOSED.

- **F3 (legacy `procStart` vs `ps lstart`) — CLOSED.** `native_start_epoch` (`:152-159`) parses both layouts and
  compares UTC instants; `legacy_owner_process` refuses `None` or unequal (`:195-197`). Registry probe above:
  `epoch_equal=True` on the live process where the raw compare was `False`. The machine is in BST and the two strings
  still agree, so the registry stores UTC ctime as the parser assumes. Pinned by
  `test_registry_start_parser_handles_both_native_orders_and_rejects_bad_identity` (both orders accepted; one second
  off, `malformed` and empty rejected).
- **F4 (`claude`-named ancestor) — CLOSED as the predecessor asked:** written as a hard requirement in
  `IMPROVEMENTS.md` ("Native adoption has a hard runtime requirement…"), with the installer preflight kept as the
  enforcement item. Not implemented; not asked to be.
- **F6 — CLOSED.** A `DispatchBriefError` now records `brief_correction` (`owned-dispatch.py:271-273`); probe D:
  `exit 2 | stderr head: DISPATCH BRIEF NEEDS CORRECTION … | ledger outcome recorded: brief_correction` (R5:
  `unverified`); a source failure still records `unverified` (test asserts both). Trailing prose punctuation is
  stripped from an embedded reference (`:223`, `rstrip(".,;:!?)]}'")`); ids are 24 hex characters
  (`owned-dispatch.py:189`), so nothing legitimate is stripped, and
  `test_punctuation_cannot_hide_conflicting_or_extended_selector` keeps `…a,`, `…-other.`, `…/other,` as conflicts.
  The `guard-ceo-ask-first.sh` 240 s timeout is unchanged and needs no change.
- **F5 (cost per changed turn) — duplicate, still disclosed.** No change expected or claimed.

## The five claims, tested

1. "Fixed immediate restart reconciliation, visible blocked-recovery notices, automatic liveness rechecks and the
   housekeeping findings." — **True for the first, second and fourth; the third is true on the fresh path and
   defeated on the resume path by F1 below.**
2. "Process-verification failures now preserve the execution fence." — **What it means:** when `ps` fails or times
   out (5 s) inside a leader hook, `assert_current_owner(require_process=True)` raises `OwnershipUnavailable`
   (`:226-229`) and the CLI answers `tool`/`question` with a deny, `permission` with a deny, `capture` with only a
   system message (`:1388-1395`). Before, the `tool` path exited 0 and allowed. **What it costs:** one denied call
   per failed `ps`, self-healing on the next call, with `ps` measured at 0.02 s against a 5 s timeout — correct
   direction, negligible cost, one exception: inside the hour-long liveness watch a single failed `ps` ends the
   watch (F3 below). A lost `UserPromptSubmit` capture is recovered by the next Stop capture, which re-reads the
   transcript. Pinned by `test_enrolled_observer_process_inspection_failure_denies_actual_cli_tool_path` (both
   `OSError` and `TimeoutExpired`, through the real CLI).
3. "Passed: 119 native tests, 33 dispatch tests, 44 process-integration checks, and the engine's 67 cases plus 27
   mutation checks." — **All five counts reproduced** (table above), each from my worktree at `125906f5`.
4. "Integration used scripted processes, with no paid model calls." — **True, and for C7 scripted coverage is
   sufficient:** the ticket is deterministic state logic exercised through the shipped hook CLI with real OS
   identities, and every host contract it leans on (SessionStart `asyncRewake` exit-2 wake, the `Stop` audit
   running for minutes) was proven on 2.1.266 in R5's paid trials. **For C8 and C3 it is not sufficient,** because
   the fixture's process layout is wrong for the host in the one way that matters (F2 below) and the defect it
   hides (F1) is only reachable with a real crash that does not `killpg`. A real-crash trial is owed as C11.
5. "The documented same-session observer remains read-only and cannot terminate a persistent residual process." —
   **The center of this review; ruled in the next section.**

## The disclosed limit: is C8 FIXED or OBSERVED?

Facts first. Under real Claude Code 2.1.266 on this machine (`scratchpad/measure-hook-pgid.sh`: a real `claude -p`
with `ANTHROPIC_BASE_URL=http://127.0.0.1:9`, so the SessionStart hook fired and no model call could be paid for):

```
hook shell pid=80508 ppid=80495
self:   80508 80495 80508 sh                      ← the hook has ITS OWN process group
up1:    80495 80490 80487 claude                  ← the leader
python child from hook: 80702 80508
```

and the live session's tool shell likewise (`ps -o pid=,ppid=,pgid=,comm= -p $$` → `69399 20597 69399 /bin/zsh`,
leader `20597 … 20597 claude`). The only member of the live leader's group besides itself is Claude Code's own
`caffeinate -i -t 300` (`ps` → `75386 20597 20597 caffeinate`, args `caffeinate -i -t 300`), which exits by itself
within 300 s. So on this runtime the "residual process group" after a real crash is **`caffeinate` for up to five
minutes** — not Rich's background Bash waits (own group), not the adapter's hooks (own group). `unverified:` the
group layout when RichOS's ACP host spawns `claude`; if it spawns through a shell, the leader's `pgid ≠ pid` and
the group check is skipped entirely (`:149`), which is the conservative side.

Now the ruling:

- **The silence is gone on both paths.** Fresh and same-ID replacements are told what is withheld and by which exact
  pids, on both channels, and the audit hook wakes the leader once per distinct blocker set without a model call.
- **On the fresh path C8 is a repair, not a notice.** The replacement keeps its normal tools; the watch polls every
  5 s for up to an hour and picks up within one poll of the blocker's exit (harness: 5.3 s; B2: automatic); the
  realistic blocker clears itself within 300 s. Rich reaping it is a model decision the harness scripted, and that
  is the honest boundary RESULTS-6 draws; it is not needed for pickup here, only for speed.
- **On the same-ID path the limit is real but is not the blocker.** The observer can inspect (`Read`/`Glob`/`Grep`)
  and cannot `kill`; probe A: `observer_bash_kill_decision: deny`, `observer_read_allowed: true`. Against a
  `caffeinate` that dies in ≤300 s this costs at most five minutes. Against a process that never exits the observer
  waits forever, and the fresh session in the identical situation (dead leader, residual group) has full tools —
  the asymmetry is a design choice, not a safety property, and I record it as F5, not as a condition, because with
  the measured blocker population it never bites. What does bite on the same-ID path is F1: the observer never gets
  its notice-wake in the first place, for the same lock reason as C3.

So: **C8 CLOSED.** The defect it named — a silent fail-closed pickup — is repaired on the fresh path and made
visible on the resume path; what remains on the resume path is not the disclosed limit but the undisclosed one (F1).

## Findings, severity-ordered, classified

### F1 — BROKEN (activation blocker, same-ID resume path): the dead session's orphaned audit hook holds the lock, steals the reconciliation credit and the wake

Probes A2 and A above; sites `:867`, `:869-871`, `:923-926`, `:936-937`, `:970`. Fix shape, for an engineer:

1. In `audit_once`, verify process lineage, not just session: at entry, on every tick of the retry sleep
   (`:923-926`) and of the watch (`:885-893`), and inside the pacing lock before a ticket is claimed or inference
   starts (`:930-942`), call `assert_current_owner(root, session, require_process=True, allow_observer=True)`. An
   orphan has no `claude` ancestor once its leader is gone (`native_owner_process`, `:127-137`, walks `ppid` to
   launchd and raises), so it exits 0 within one tick and releases the lock; a superseded process fails the
   `entry['process']` comparison the same way.
2. Make the replacement's audit wait for the lock, bounded, when the state carries an unclaimed
   `recovery_checkpoints` entry for its own destination or `withheld_recoveries` without a `withheld_notice_key` —
   `locked(..., blocking=True)` with a short deadline (the orphan releases in ≤1 s after fix 1) instead of `return
   0, ''` at `:870-871`.

Two tests: (a) an audit sleeping on a state whose journal process is not the hook's own ancestor exits 0 without
inspecting when the revision changes, leaving the ticket unclaimed; (b) a replacement `SessionStart` audit with an
unclaimed ticket and a momentarily held `.audit-lock` still runs the reconciliation and returns 2. The harness
gains a fourth case: the old leader's `audit Stop` launched with `start_new_session=True` before the kill, on both
restart modes, asserting `sessionstart_audit.exit == 2` and `inspector.jsonl` written by the replacement's hook.

### F2 — OBSOLETE PREMISE (in the fixture, not the adapter): the harness makes hooks members of the leader's group; the host detaches them

`test-owned-recovery.py` spawns the leader with `start_new_session=True` and its driver runs hooks with plain
`subprocess.run`, so a fixture hook inherits the leader's pgid; the measured host gives every hook its own group.
The 44 checks therefore prove the fresh-path mechanism against a group straggler — which `caffeinate` really is —
but could not reach F1, and RESULTS-6's sentence "the same replacement can claim the assignment and use its
immediate reconciliation ticket" is true only when no orphaned hook of the same session is alive. The
predecessor's reachability story for F2 (background Bash waits in the dead leader's group) is also wrong for this
runtime — tool shells are detached — and the finding stood anyway, for `caffeinate`. Classification: obsolete
assumption; the code is not wrong, the evidence claims less than they read as.

### F3 — ENVIRONMENTAL, low: one transient `ps` failure ends the hour-long liveness watch

Probe E (`scratchpad/probe-watch-ps-hiccup.py`): with the process table raising `TimeoutExpired` once on the second
call, `audit()` propagates the exception; through the CLI this is the generic handler (`:1397-1410`) — for `audit`
mode an exit-2 wake reading "Continuation capture or review failed; completion remains unverified. Repair the
integration…", which is a wrong diagnosis, and the watch is gone; the state still says withheld with
`withheld_watch_until` in the future. `ps` takes 0.02 s here against a 5 s timeout, so this is environmental. Fix:
catch `(ValueError, OSError, subprocess.TimeoutExpired, OwnershipUnavailable)` inside the watch tick, count it, and
continue polling; give up only after N consecutive failures with a message that says `ps` is failing.

### F4 — BROKEN, narrow, low: a hook killed mid-inference after claiming its ticket leaves the gate up for an hour

Probe F: `KeyboardInterrupt` during the runner call → `recovery_requires_review = True`, ticket claimed, `retry_at`
+3600, and the next `Stop` audit sleeps (`WOULD SLEEP`); `Agent`/`SendMessage` refused with `ASSIGNMENT RECOVERY
PENDING` meanwhile. Reachable only if the hook process itself dies (SIGKILL) while its leader survives — a runner
timeout or error is already handled (`:965-967`). Fix: record `inference_started_at` on the claimed ticket; a later
audit that finds a claimed ticket with no `checked` update and a free `.audit-lock` treats it as reusable once.

### F5 — Design note, no severity: the same-ID observer's tool fence also holds the CEO's new instructions

While `recovery_observer` is set, `withheld_only` is true (`:881`) and every non-`Read`/`Glob`/`Grep` tool is denied
(`:1314-1319`) — including for a fresh CEO message typed into that session. A fresh session with the identical dead
leader and residual group has full tools. With the measured blocker population (`caffeinate`, ≤300 s) the cost is
bounded; with F1 fixed the observer at least receives its notice. Recorded here and in `IMPROVEMENTS.md`
("Discovered during revision 6"); not a condition.

### F6 — DUPLICATE of R4 F6 / R5 F5: native cost is per changed turn; the watch adds ~720 `ps` calls per hour

Unchanged; the watch's per-tick cost (a `ps` at 0.02 s and a transcript re-capture) is negligible. Recorded for
completeness.

## Conditions, in order

- **C7 — CLOSED.** **C8 — CLOSED.** **C9 — CLOSED** (F3, F4, F6 of R5). **C5 — still disclosed.**
- **C3 — NOT CLOSED**, decomposed into:
  - **C10 (before activating the Claude Code surface):** hooks of a dead or superseded process must never audit —
    process-lineage verification in `audit_once` at entry, per sleep/watch tick and before claiming; and the
    replacement's audit waits, bounded, for a held `.audit-lock` when it holds an unclaimed ticket or an unsent
    withheld notice (F1). One engineer, two tests, one harness case.
  - **C11 (before activating):** one real-provider trial per restart mode (fresh and `--resume`), in the hour regime
    (`audit_attempts ≥ 5` with a sleeping `Stop` audit hook), killing the leader with `SIGKILL` **to its pid only,
    never `killpg`**, and recording for the replacement: the `SessionStart` audit's exit code and stderr, which
    process wrote `inspector` rows, the process group of the adapter's own hooks and of every survivor of the old
    leader's group, and the time from replacement start to an allowed `Agent` dispatch. Scripted coverage is
    sufficient for C7 and stays; it is not sufficient for C3/C8 because the fixture's process layout differs from
    the host's in the one respect that matters (F2). Budget for this on R5's figures: about eight inspections per
    trial.
- **C4 (at land, again):** `bash engine/scripts/hooks/install.sh` for the two changed libraries.
- **Housekeeping, no severity:** F3 (watch survives a `ps` hiccup), F4 (claimed-but-unfinished ticket), F5 recorded.

## For the CEO, in plain words

Is this activatable now? **No — and the reason is one small, well-understood defect, not a decision for you.** The
two things my predecessor named are fixed and I reproduced both with real processes: a Claude Code that restarts
after a crash late in a job now checks the work immediately instead of refusing to dispatch for up to an hour, and
if something from the dead session is still running, the new session is told exactly what, by process number, on
both channels, and picks the work up by itself within seconds of that process going away. Starting a **fresh**
session after a crash works end to end on the shipped code. What does not work yet is restarting the **same**
session (`--resume`): under the real Claude Code, a crashed session leaves its own sleeping checker process behind,
and that leftover still looks like the rightful owner, so it spends the new session's one immediate check and
sends the "carry on" signal to a process that no longer exists — the new session sits idle until you type
"continue", which is the exact thing this project exists to remove. Every earlier trial missed it because the test
rig killed the whole family of processes at once, while a real crash kills only the parent. The fix is a few lines
(make a checker verify that its own parent is alive before it acts), plus one real crash trial per restart mode so
this is proven against the host rather than a fixture. Merging this commit changes nothing you use today.

## What I did not do, by choice

No paid model runs; R5's seven native trials retain their hashes and were not rerun; the one real `claude` I started
had its API traffic sent to a closed local port, fired only its SessionStart hook, and was killed by an alarm after
75 s (its stale registry file `~/.claude/sessions/80495.json` is left for the host to clean, as it does for any
killed session; the adapter ignores registry rows whose pid is not live). No merge, push, install, adoption or
activation. No writes anywhere but this branch's `docs/reviews/` and my scratchpad; every fixture process group was
verified empty after each probe (`remaining_group_members: []`; `ps` sweep → "no fixture processes remain"). Every
number I did not measure is marked as read from Codex's evidence, and every gap is marked `unverified:` with what
settles it.
