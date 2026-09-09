# Verdict: ACCEPT WITH NAMED CONDITIONS — merge `0c0d2b43`; C3, C10 and C11 are CLOSED, F3 and F4 are CLOSED, F5 stays a design note; the Claude Code surface is activatable once landed. Two land-time conditions: C12 (the commit ships four dangling public citations that the publication-completeness guard refuses at commit and push; Codex fixes, one file) and C4 (Rich reruns the installer for the one changed library).

Reviewer: Sage (`sage-fable-r7`), 2026-09-09, on the CEO's direct order ("For Sage on Fable to review now").
Reviewed commit `0c0d2b430532f0695e5668b9fa775e97a4323f3a` (`codex/owned-outcome-completion`), the single commit since
the revision my predecessor reviewed (`git log --oneline 125906f5..HEAD` → one line, `0c0d2b43 Fence native audit
ownership and finish crash recovery`; `git status --porcelain` in the Codex worktree → 0 lines; `git merge-base HEAD
6d32916d` → `125906f5`, already on richos main), checked out in `/Users/alex/ab/richos-wt/sage-fable-r7` on branch
`sage-fable-r7`. Nothing under the Codex worktree was written. Nothing here was implemented or fixed. Every number
below carries the command that produced it or the word `unverified:`.

Read in full before starting: the femcboost record
`femcboost/docs/reviews/structural-failure-unacceptable-results-as-user-decisions-2026-09-09.md` (private
repository, not in this tree) and `docs/reviews/sage-fable-r6-owned-outcome-2026-09-09.md` (landed on richos main at
`ba91a881`, merged at `6d32916d`; this branch's base predates it, so the r1, r4, r5 and r6 reviews are staged into this
branch byte-identical to main — `shasum -a 256` of the r6 copy → `422b07237aa3…` on both sides, and identical to the
copy the revision itself carries at `docs/verification/owned-outcome/evidence-r7/review-r6.md`). This review re-ran
the predecessor's own probes from his scratchpad against the new adapter rather than inheriting his results, and it
presents the CEO with no choice anywhere: what is unfinished is named as unfinished.

## The kill-method finding, before anything else

**Every real-provider crash trial in this round killed the leader with `SIGKILL` to its pid only, never `killpg`, and
every one ran under the real host's process layout, with the dead session's sleeping `Stop` audit hook alive in its
own process group at the moment of the crash.** Established from the harness source and the raw evidence, not from
the summary:

- The current harness (`shasum -a 256 app/scripts/test-owned-wake-native.py` → `722103bf…`, the hash the final
  resume trial recorded) contains three `os.killpg` sites (`grep -n killpg` → lines 182, 2093, 2096). Line 182 is
  `stop_owned_group`, used only by the non-crash restart path and a self-test; 2093/2096 are the `finally` branch for
  runs without `--exhausted-crash`. The crash path is line 1775: `kill_leader_only(process, initial_identity,
  owned_processes) if args.exhausted_crash else stop_owned_group(process)`, and `kill_leader_only` (line 332) does
  `os.kill(process.pid, signal.SIGKILL)` after verifying the leader's identity has not changed, then records the
  group before, the group survivors and the detached survivors from `ps`.
- Each trial directory carries the harness that actually ran (`tested-harness.py`); the six hashes match the six
  recorded in `native-trials-summary.json` (`a19c9583…` ×2, `66fa8b33…` ×2, `1327385f…`, `722103bf…`), and every one
  selects `kill_leader_only` on the crash path (lines 422/439 and 1407/1424/1559/1775 of the respective copies).
- Raw `restart-evidence.json`, read directly:

| Trial | `stop.signals` | `leader_exit` | Leader's group before → survivors | Sleeping `Stop` audit at the crash |
|---|---|---|---|---|
| `native-fresh-final` | `[{pid 64871, SIGKILL}]` | `-9` | `claude 64871`, `caffeinate 67208` → `caffeinate 67208` | adapter pid 25608, **pgid 25147 ≠ leader pgid 64871**, lock held (`lsof` listing), detached survivors `25147`, `25608` alive after the kill |
| `native-resume-final` | `[{pid 89768, SIGKILL}]` | `-9` | `claude 89768`, `caffeinate 90289` → `caffeinate 90289` | adapter pid 96772, **pgid 96271 ≠ 89768**, lock held, detached survivors `95548`, `96271`, `96772` alive after the kill, reparented to pid 1 |
| `native-resume-before-carrier-fix` | `[{pid 65412, SIGKILL}]` | `-9` | `claude`, `caffeinate` → `caffeinate` | adapter 15406, pgid 14920 ≠ 65412, lock held |
| `native-fresh-initial` | `[{pid 17493, SIGKILL}]` | `-9` | `claude`, `caffeinate` → `caffeinate` | adapter 63336, pgid 62833 ≠ 17493, lock held |

  The hook's lineage in each record is `adapter → instrumented wrapper → claude`, with the wrapper in its own group —
  the layout my predecessor measured on the real host (`hook shell pid=80508 pgid=80508`), not the fixture layout.
- What the orphan then did, read from the private `adapter-hooks.jsonl` of both final trials (fields read: pid, pgid,
  exit, time, stderr length; no permission context or account data was printed): resume — the sleeping `Stop` audit
  (invocation `96271:1788968324733708000`) exited `0` with empty stderr at `1788968326.119`, **0.29 s after the
  crash** at `1788968325.826`, and the replacement's `SessionStart` audit exited `2` at `1788968327.067` (1.24 s
  after the crash) with the withheld notice; fresh — orphan exit `0`, empty stderr, `0.33 s` after the crash;
  replacement `SessionStart` audit exit `2` 1.98 s after. In both, every post-crash `audit-session` runner call
  carries the replacement's lineage (`no_orphan_session_audit: true`; two calls each), and the first allowed `Agent`
  came at `310.2 s` (resume) and `376.3 s` (fresh) after the replacement launched.
- The mechanical suite no longer runs hooks inside the leader's group: `test-owned-recovery.py` now launches every
  hook through a `--hook` wrapper with `start_new_session=True` (diff at lines 65–107), records `hook_pgid`, and its
  two orphan cases assert `old_hook_detached_and_sleeping_under_lock` and `pid_only_death_leaves_old_audit_alive`
  before killing the leader with `SIGTERM` to its pid only (`stop_owner`, line 225).

So the headline numbers were produced by a harness that can fail on the defect this series exists to catch: had the
orphan claimed the replacement's ticket, `replacement_sessionstart_delivered_actual_wake` (a `SessionStart` audit in
the replacement's lineage exiting `2` with stderr) and `no_orphan_audit_session_owned_replacement_work` would both
have gone false. **C11's kill method and process layout are met.** One precision the summary does not state: in
both live trials the orphan retired 0.3 s after the crash, roughly a second before the replacement's audit ran, so
the *lock-contention* half of C10 (the replacement waiting on a still-held `.audit-lock`) was exercised only in the
mechanical fixture, which freezes the orphan with `SIGSTOP` to force it. That is the right way to force it, and it is
disclosed in RESULTS-7 as the "deterministic scheduling barrier".

## Numbers I reproduced

All from `/Users/alex/ab/richos-wt/sage-fable-r7` at `0c0d2b43`; runtime `claude --version` → `2.1.266 (Claude
Code)`; `date +%Z` → `BST`.

| Claim (RESULTS-7 / handoff) | Reproduced | Command | Result |
|---|---|---|---|
| 132 native adapter tests | **Yes** | `python3 engine/scripts/lib/owned-session.test.py` | `Ran 132 tests in 5.144s … OK`, exit 0 (119 − 1 renamed + 14 new; `git diff … owned-session.test.py \| grep '^[-+]    def test_'` → 1 removed, 14 added) |
| 33 dispatch tests | **Yes** | `python3 engine/scripts/lib/owned-dispatch.test.py` | `Ran 33 tests in 0.231s … OK` |
| 7 mechanical cases, 115 checks, zero provider calls, source unchanged | **Yes** | `python3 app/scripts/test-owned-recovery.py --output <scratch>` then a count over `result.json` | 7 cases all `PASS`, `sum(len(c['checks']))` = **115**, `provider_calls 0`, `source_unchanged True`; timings 0.632 / 0.369 / 1.133 / 0.367 / 0.368 / 5.662 s against RESULTS-7's 0.656 / 0.394 / 0.970 / 0.505 / 0.399 / 5.702 s |
| The four preserved mechanical runs | **Read** | same count over each `evidence-r7/mechanical-*/result.json` | `mechanical-initial` passed False, 86 checks, both orphan cases raised (error field, not a failed check) on sources `a75d7ac6…`/`8e0d37b9…`; `mechanical-final`, `-feedback-final`, `-resume-final` each passed True, 115 checks, `source_unchanged True`; `-resume-final` sources `e6c970d5…`/`ce2554ca…` = this tree |
| Engine 67 cases, 27 mutation properties | **Yes** | `bash engine/scripts/hooks/ceo-asks.test.sh` | `67/67 cases passed`, `27/27 properties proven load-bearing`, exit 0 |
| Real runner lease, 5 checks | **Yes** | `python3 docs/verification/owned-outcome/evidence-r7/check-runner-lease.py --repo <my worktree>` with the recorded binary copied from the Codex worktree into my gitignored `app/target/debug/` (`shasum` → `ee6c9bf2…`, the hash RESULTS-7 records) | all five checks `true`, `provider_calls 0`, exit 0 |
| Disposable installer, three sidecars, pointer unchanged | **Yes** | `python3 …/evidence-r7/install-check.py --repo <my worktree>` | exit 0; `owned-work-policy.sh 9969f9af…`, `owned-dispatch.py 950eeb23…`, `owned-session.py e6c970d5…` all match; `production_pointer_unchanged true`; `readlink ~/.claude/richos-engine` → `/Users/alex/ab/richos/engine` |
| Evidence index verifies | **Yes, public only** | `python3 …/evidence-r7/verify-evidence.py --public-only` | `verified_artifacts 1269, explicitly_skipped_private 4797, source_files 9, unexpected_files 0`, exit 0 |
| Harness self-tests | **Yes** | `test-owned-wake-native.py --self-test-restart / --self-test-parser / --self-test-r3` | restart: 14 restart-evidence checks, 14 + 12 + 16 notification scoring cases, 9 bounded sleeping-hook cases, 24 stopped/resumed generation cases, actual PID-only crash with a surviving detached audit; parser: 9; r3: PASS; no Claude started |
| 38/38 fresh, 41/41 resume | **Yes** | count over `native-fresh-final/result.json`, `native-resume-final/result.json` | 38 checks / 38 true; 41 / 41; `operational_followups 0`; `input_measurement_confirmed True` |
| The four failed native trials | **Yes** | same count | `fresh-initial` 35/38 (three completion checks false), `resume-initial` 25/38, `resume-before-carrier-fix` 33/38 (`operational_followups 1`, `confirmed False`), `resume-no-crash-window` 27/38 — each `result.passed False`, none rewritten |
| 310.2 s / 376.3 s to an allowed `Agent`; 693.1 s to verified completion; two `audit-session` calls; transcript row `c24bd5b9…` at `15:43:33.031Z` | **Yes** | `exhausted-crash-acceptance.json` (private, fields only) and `final-acceptance-receipt.json`; `launches[0].at 1788968242.29`, `completed_at 1788968935.38` → 693.09 s | all match |
| Fresh trial ran runtime `2eb1d3ab…`, not final `e6c970d5…` | **Yes, and I diffed them** | `difflib` over the private snapshot `old-adapter.py` (`sha256 2eb1d3ab…`) and this tree's `owned-session.py` | **88 diff lines, all inside `native_completion_batch`** (the stopped/resumed completion carrier); nothing in the crash, lineage, lock, lease or wake paths differs |
| Live trials complete, none hidden | **Yes** | every `richos-owned-wake-native-*` root under `$TMPDIR` with mtime after 13:20 today, checked for `process-launches.json` / `transcript-*.jsonl` / `terminal.log` | six roots carry a live launch and all six are indexed; four (`f0ougtdp`, `gzhvc9bi`, `nn2vn6bc`, `jijjznko`) carry none — they are harness prepare/self-test roots (barrier installation check, wrapper FD check) matching the `outcome-probe` logs |
| Main's sidecars vs this commit (C4) | **Yes** | `cat /Users/alex/ab/richos/engine/scripts/lib/owned-session.py.sha256` | `2b29c6ef…` on main; this tree `e6c970d5…`; `owned-dispatch.py` `950eeb23…` on both — **one library changed** |
| "Six successful CLI recovery responses carry the inspector report" | `unverified:` not counted; `wake_ack_follows_actual_cli_output` is true in all seven cases of my run, which is the property that matters | | |
| Engine suite "296.1 seconds" | `unverified:` not timed here; irrelevant to acceptance | | |

## Conditions, ruled one by one

### C10 — CLOSED. A hook is bound to its own native ancestor and retires without acting the moment that ancestor is gone.

Mechanism (`owned-session.py`): `audit_binding` (`:940-944`) captures the hook's `claude` ancestor once at start;
`checked_audit_process` (`:947-957`) re-verifies it with `assert_current_owner(require_process=True,
allow_observer=True)`, raises `OwnershipSuperseded` if the ancestor differs from the binding, and retries
`OwnershipUnavailable` three times at 0.2 s. `native_owner_process` now raises `OwnershipSuperseded` — not
`ValueError` — when no `claude` ancestor exists (`:140`), which is exactly an orphan's state after reparenting to
launchd. The check runs at entry (`:1015`), on every 1 s tick of the retry sleep (`:1096`), on every 5 s tick of the
watch (`:1052`), inside the pacing lock before a ticket is claimed (`:1105`), before and after the runner call
(`:1130-1132`), inside the publication lock (`:1156`) and before every wake is returned. The replacement's audit now
waits, bounded to 30 s, for a held `.audit-lock` whenever it carries an unclaimed reconciliation, a withheld notice,
an interrupted inference or an undelivered wake (`pending`, `:1016-1017`; `audit_lease`, `:996-1012`).

Probes. The predecessor's own A2/B2 probe (`scratchpad/probe-r6-straggler.py`, his file with the repository path
changed and nothing else), against this adapter:

```
=== A2 same-ID resume, orphan hook detached (real host layout)
 old_hook_in_leader_pgid False   old_leader_dead True   old_hook_survives_leader_death True
 sessionstart_audit: exit 2, 1.039 s, "Rich still owns unfinished authorized work. Continue without a CEO nudge…"
 inspector_calls_6s_after_start 1   orphan_alive_6s False   orphan_stderr ""   inspector_called_for_dead_leader 0
 state_6s: ticket claimed, verdict incomplete, audit_attempts 6, recovery_requires_review None
 automatic_pickup True   replacement_ever_got_exit2_wake True   remaining_group_members []
=== B2 fresh session, orphan hook detached
 sessionstart_audit: exit 2, 0.38 s   old_hook_lifetime 4.2 s   inspector_called_for_dead_leader 0   pickup True
```

In R6 the A2 lines read `exit 0, 0.068 s, ""` and the orphan's stderr carried the wake. The 1.039 s on A2 is the
replacement waiting on the orphan's lock and then reconciling itself. The mechanical `detached-orphan-resume` case
proves the same with `SIGSTOP` holding the orphan on the lock (`replacement_waits_for_held_audit_lock`,
`orphan_cannot_wake_or_inspect`, `only_replacement_hook_inspects_and_wakes`,
`orphan_cannot_reserve_or_publish_reconciliation`, 1.13 s in my run). Pinned by
`test_old_sleeping_hook_cannot_adopt_same_id_replacement_ticket` (sleep patched to boot a new process; the runner
patched to fail if called; `OwnershipSuperseded` raised, ticket unclaimed, no wake),
`test_replacement_waits_for_old_lock_and_receives_its_own_wake`, and
`test_stale_inference_cannot_save_rejected_decision_or_wake`.

### C11 — CLOSED. One real-provider trial per restart mode, leader-only `SIGKILL`, hour regime, real hook layout, every field recorded.

The kill-method section above is the ruling. Point by point against the condition as I worded it in R6: **per
restart mode** — fresh `mmdlv6q8` and same-ID `o33xokiz`, both passed; **hour regime** — pacing seeded to
`audit_attempts 5`, `retry_at +3600` after real guarded child work (`pacing-injection.json`: `only_pacing_changed
True`, `before 0 → after 5`, honestly labeled "not five paid prior audits"), and `sleeping_stop_audit` requires the
state at `≥5` attempts with `retry_at ≥ now+3000`, the lock non-acquirable and `lsof` listing it in the adapter pid;
**leader pid only** — recorded; **SessionStart audit exit and stderr** — exit 2 with the withheld notice, then the
same outstanding hook picked the work up after the survivor cleared; **which process wrote inspector rows** — two
`audit-session` calls per trial, both in the replacement's lineage; **process groups** — the adapter's hooks in their
own groups, the leader's group holding only `caffeinate`; **time to an allowed `Agent`** — 310.2 s / 376.3 s.

Two limits, both disclosed and both acceptable: the fresh trial ran on `2eb1d3ab…`, whose only difference from the
final adapter is the completion-carrier parser (88 lines, all inside `native_completion_batch`, diffed above) and
whose completion checkpoint the replay in `fresh-checkpoint-equivalence/result.json` shows is identical on both
runtimes (`passed true`, `provider_calls 0`, `hook_calls 0`); and the final resume trial used the opt-in
scheduling barrier (`child-crash-barrier.py`), which holds one original child's next tool after a real `Read`, is
bound to the original leader's exact identity, claims once, and released on `original_leader_identity_ended` after
4.66 s with no signals — an injected interruption of one tool, not a manufactured `Stop`. RESULTS-7 says both of
these in plain words.

### C3 — CLOSED. Cross-session pickup exists on both restart modes under the real host, after a real crash.

R6 held C3 open on one door: the same-ID orphan spending the replacement's reconciliation. That door is shut (C10)
and the trial that would have caught it has run on both modes (C11). The "or explicit CEO scoping" half stays moot.

### C4 (Rich, at land) — must be discharged AGAIN for this commit, for one library.

`owned-session.py` changed (`2b29c6ef… → e6c970d5…`); `owned-dispatch.py` and `owned-work-policy.sh` did not. `bash
engine/scripts/hooks/install.sh` from the landed checkout; the disposable rerun above shows it produces matching
sidecars.

### C12 (NEW, Codex, before land) — the commit ships four dangling public citations, and the completeness guard refuses every commit and push on the tree until they are fixed.

Found when I tried to commit this review. `engine/scripts/hooks/guard-completeness-commits.sh` (blocking, fires on
`git commit` and `git push` in richos) refused with seven findings; after staging the r1, r4, r5 and r6 reviews
byte-identical to main (which resolves the three that are artifacts of this branch's base), exactly four remain
(`bash /Users/alex/ab/richos/engine/scripts/publication-completeness.sh --root <my worktree> --explain` → `4
finding(s)`), all from the revision's own copy of my predecessor's review:

```
[CITATION] docs/verification/owned-outcome/evidence-r7/review-r6.md
  cites `checks/docs-claims.log`          → would be evidence-r7/checks/docs-claims.log, does not exist
  cites `checks/echo-ownership-fence.log`
  cites `checks/echo-recovery-review.log`
  cites `checks/engine-final-result.json`
```

Those four files exist at `evidence-r6/checks/` (`ls` → present), where the review was written to cite them; copied
into `evidence-r7/` the relative citations point at nothing. richos main is green today (`publication-completeness.sh
--root /Users/alex/ab/richos` → `✓`) because `docs/reviews/` is not a scanned document tree and `evidence-r7/` is.
Consequence if landed as is: the merge itself is not gated, but the next `git push` from the main checkout is, so main
could not be pushed until someone fixes it under time pressure. **Fix, for Codex, one file plus its index:** rewrite
the four citations in `evidence-r7/review-r6.md` to `../evidence-r6/checks/…` (or drop the copy and cite
`docs/reviews/sage-fable-r6-owned-outcome-2026-09-09.md` by name in RESULTS-7), then re-record the file's sha256 in
`evidence-r7/artifact-index.json` and its `original_sha256`/`copy_sha256` fields, so `verify-evidence.py` stays
green. Verify with `publication-completeness.sh --root <tree>` → exit 0 and `verify-evidence.py --public-only` → exit
0. I did not make this edit: it is the revision's file, its index asserts the file's bytes, and my brief is review
only. Nor did I add an exemption line to `.richos/publication-completeness`, which would carry the defect to main
green.

### R6 housekeeping findings

- **F3 (watch dies on one transient `ps` failure) — CLOSED.** `native_processes` converts `OSError`/`TimeoutExpired`
  and a non-zero `ps` into `OwnershipUnavailable` (`:113-120`); `checked_audit_process` and `capture_during_audit`
  retry it three times at 0.2 s. The predecessor's probe E replaces `native_processes` wholesale, which bypasses the
  new conversion point, so I wrote one that fails `ps` itself through `subprocess.run` and leaves the real function in
  place (`scratchpad/r7-probe-f3-real-ps.py`): one failure on the watch's first or second `ps` → `(-1, '')` after the
  straggler exits, watch intact (`ps calls 6-7, failed 1`); two consecutive → same (`10, failed 2`); three consecutive
  → `OwnershipUnavailable` after `ps calls 4, failed 3`, which the CLI turns into an exit-2 wake reading "Native audit
  process verification or lease inspection is temporarily unavailable… Retry the native recovery check" (`:1598-1601`)
  — the accurate diagnosis R6 asked for — with the state still withheld and `withheld_watch_until` in the future, so
  the next `Stop` audit re-enters the watch for the remaining interval (`:1048`). Pinned by
  `test_transient_process_failure_preserves_mechanical_watch`.
- **F4 (hook killed mid-inference leaves the gate up for an hour) — CLOSED.** `audit_inference` records
  `{id, owner_process, hook_pid, phase: started, inference_started_at, retry_count}` before the runner call
  (`:1119-1121`); the runner inherits a separate `.inference-lock` descriptor (`pass_fds=(inference_fd,)`, `:1131`),
  proven to survive the hook's death by the real Rust runner (`check-runner-lease.py`, five checks); a later audit
  that finds `phase == 'started'` and `interrupted_audit_retries < 1` skips the sleep once (`:1089-1094`), waits on
  the lease up to 300 s so it never overlaps a live inspector, and consumes the one retry
  (`interrupted_audit_retries += 1`); ordinary counters are untouched and chatter cannot refill it. The predecessor's
  probe F on this adapter reaches the inspector on the very next `Stop` audit (his probe's `AssertionError:
  inspector` is its "reached" signal) where R6 read `WOULD SLEEP`. Mechanical cases `hook-only-mid-inference`
  (`leader_and_inspector_survive_hook_only_signal`, `surviving_inspector_lease_prevents_duplicate_inference`,
  `waiting_retry_does_not_spend_budget`, `one_bounded_immediate_retry_after_child_exit`) and `interrupted-retry-limit`
  (`assistant_chatter_cannot_refill_interrupted_retry`) pass in my run.
- **F5 (the same-ID observer's tool fence also holds the CEO's new instructions) — design note, unchanged, and I
  agree it is not a condition.** `recovery_observer` is still set on the withheld same-ID path (`:310`) and the CLI
  still denies every tool but `Read`/`Glob`/`Grep` while it is set (`:1523-1525`); it clears on transfer (`:384`).
  Two facts sharpen the predecessor's note. First, with F1 of R6 fixed the observer now *receives* its notice-wake
  (both live trials: exit 2 within 2 s), so the window is visible rather than silent. Second, the only member of a
  dead leader's group this runtime ever leaves behind is Claude Code's own `caffeinate -i -t 300` (both trials'
  `leader_group_survivors`), so the window is bounded by that timer — and the finding below removes most of it.

## The five claims, tested

1. **"Fixed orphaned checkers, interrupted inspections, lost feedback and resumed-worker completion tracking."** Four
   claims. *Orphaned checkers* — true (C10). *Interrupted inspections* — true (F4). *Lost feedback* — true as
   disclosed: the first fresh trial reached authorized dispatch in 436 s and then missed completion because the
   continuation renderer discarded the inspector's findings; `continuation_message` now embeds a validated incomplete
   report bound to the audited fingerprint and the owner process (`:719-731`), and
   `test_useful_inspector_report_is_current_owner_and_evidence_bound` shows a changed source, receipt or owner
   suppresses it; the corrected fresh trial then completed. *Resumed-worker completion tracking* — true within a
   narrow carrier: a `stopped` task notification now retires the prior invocation without credit, and a later
   `completed` notice with no tool-use id earns a checkpoint only when the prior generation is stopped, the resume was
   a successful `SendMessage` bound by `sourceToolAssistantUUID`, and the notice's `<result>` text matches exactly one
   assistant row in that child's transcript between the resume and the notice (`resumed_report`, `:753-784`);
   `test_stopped_resume_rejects_ambiguous_historical_and_forged_generation` rejects 27 variants. The final live
   resume trial did not exercise this carrier (`matched_bound_resumed_completion_notifications: 0`); RESULTS-7 says so
   and does not present it as a second live run. Ruled: all four true; the fourth is proven on the earlier failed
   transcript's replay and by tests, not live.
2. **"38/38", "41/41", "132 adapter tests."** All reproduced (table).
3. **"Both finished without user nudges."** How a nudge would be detected: the harness is the only writer to the
   session's pty and logs every write it makes (`input-events.jsonl`, `recorded_operational_inputs`); separately,
   every non-sidechain `user` row in the transcript is classified, and a row is counted as operator input unless it is
   the one initial request or a host notification bound to a known launch (restart notice bound to the killed
   child's `Agent` call and output file; completion notice bound to a launch; Bash notice; a `task-notification`
   naming a known agent and tool-use id). Anything else is `transcript_unexpected_inputs`. `confirmed` requires
   exactly one `argv` request, one initial row, zero recorded inputs and zero unexpected rows
   (`input_measurement`, `:1061-1062`). Final trials: `recorded_operational_inputs []`,
   `transcript_unexpected_inputs []`, `matched_system_messages 3` (resume) — `confirmed True`. The R5-style
   miscount is what `before-carrier-fix` shows (`operational_followups 1` was the native resumed-completion notice,
   not a human); the meter was then taught that carrier, and the final trial did not contain one, so the final
   `0` does not depend on the meter change. Ruled: true.
4. **"The review packet records exact versions, test limitations and every failed trial."** I read them. Six live
   roots with launches exist for the R7 window and six are indexed, four of them failed and retained with their own
   harness and runtime hashes; the first mechanical run is retained with its `SIGSTOP`-barrier exception; the first
   runner-lease fixture is retained with `failure-record.json` (`fixture input missing verified-source provenance;
   runner rejected before scripted provider launch`); the acceptance-contract metadata drift (900 s recorded, 1,200 s
   executed; group-stop wording, pid-only code) is disclosed and I confirmed it in `native-fresh-final/
   acceptance-contract.json` (`ceiling_seconds 900`). No failed trial was reclassified. Ruled: complete.
5. **"Unrelated improvements remain separate."** `git diff --numstat 125906f5..HEAD | grep -v evidence-r7/` → nine
   files: `owned-session.py` +307/−89, its tests +259/−7, the two harnesses, RESULTS-7, REVISION-7, IMPROVEMENTS,
   REVIEW, README; plus 1,272 evidence files (`1281 files changed, 239058 insertions(+), 146 deletions(-)`). No
   Rust, UI, hook registration or guard changed. The diff is **not** limited to C10/C11/F3/F4: it carries three
   further fixes — inspector-report delivery, the stopped/resumed carrier, and durable wake acknowledgment
   (`audit_wake`, at-least-once) — each traceable to a disclosed failed trial or peer finding and each tested. Those
   are the assignment's objective, not unrelated improvements; the genuinely deferred items sit in IMPROVEMENTS.md.
   Ruled: nothing outside the assignment; three things outside the named conditions, all declared.

## Findings, severity-ordered, classified

### F1 — BROKEN (packaging, land-blocking): four dangling public citations in `evidence-r7/review-r6.md`

C12 above. Not a defect in the mechanism; a defect in the delivered tree that the repository's own guard refuses.

### F2 — DESIGN, medium-low: every crash now costs up to 300 s waiting on the dead leader's own `caffeinate`

In both live trials the replacement's first `SessionStart` audit returned the *withheld* notice, not the transfer,
because the dead leader's group still contained `caffeinate -i -t 300` (Claude Code's own idle inhibitor), and the
transfer happened only when it expired: 236 s after the crash on resume (`audit-session` at `1788968562.57` against
the crash at `…325.83`), ~215 s on fresh. That is where most of the 310 s / 376 s goes, and on the same-ID path it is
also the whole F5 window. `recovery_blocker` (`:165-171`) and `owner_is_live` (`:152`) treat any surviving member of
the leader's group as able to act. **Fix, for an engineer:** in both functions, classify a survivor whose command
basename is `caffeinate` as inert (record it in the blocker as `inert_survivors` so the notice stays honest), so
`residual_process_group` is raised only for other survivors. Two tests: a dead leader whose group holds only
`caffeinate` transfers at once; `caffeinate` plus a `sleep` still withholds. One harness case adjustment in
`live-straggler-recovery` to launch a `caffeinate` beside the `sleep`. Expected effect: pickup within seconds of a
crash on both modes, and the same-ID observer window collapses to the orphan's ~0.3 s retirement. Not a condition:
the wait is bounded, visible on both channels, and clears by itself, so the CEO never types "continue".

### F3 — ENVIRONMENTAL, low: a crash landing inside the orphan's inference window costs a few diagnostic wakes

If the leader dies while its audit hook is inside the runner call (≤270 s of each hour), the orphan survives, keeps
`.audit-lock` until the runner returns, then retires without publishing (`checked_audit_process` after the call,
`:1132`). Meanwhile the replacement's pending audit waits 30 s (`audit_lease`), raises `OwnershipUnavailable`, and
the CLI emits the "temporarily unavailable… Retry" wake; each following `Stop` repeats it until the lease frees — up
to roughly nine wakes, each a leader turn. End state correct, one paid inspection wasted. Fix: run the runner with
`Popen` and poll `checked_audit_process` once a second, terminating the runner on `OwnershipSuperseded`, so the
orphan releases within a second whatever it is doing. Not reproduced live; reachable only in that window.

### F4 — DUPLICATE of R6 F6, cost: the hour sleep now runs `ps -axo` every second

`checked_audit_process` on each 1 s tick (`:1096`) is ~3,600 `ps` calls per sleeping hook per hour at 0.02 s each —
about 2% of one core continuously, per owned session. Fine for one operator; worth a 5 s tick before anyone runs
several. Recorded, no severity.

### F5 — DESIGN NOTE, carried from R6: the same-ID observer fence holds typed CEO instructions for the residual window

Ruled above; with F2 fixed the window all but disappears.

### F6 — DISCLOSED, no severity: at-least-once wake delivery can repeat a message

A crash between the CLI's flush and `delivered_at` repeats the same wake once; it carries no new authority and no
inspection credit (`acknowledge_audit_wake`, `:977-987`; `test_unsent_wake_replays_without_model_and_cannot_cross_owner`).

## Conditions, in order

- **C3 — CLOSED. C10 — CLOSED. C11 — CLOSED.** F3 and F4 of R6 CLOSED; F5 recorded.
- **C12 (Codex, before land):** fix the four citations in `evidence-r7/review-r6.md` and re-index; verify with
  `publication-completeness.sh` exit 0 and `verify-evidence.py --public-only` exit 0.
- **C4 (Rich, at land):** `bash engine/scripts/hooks/install.sh` for `owned-session.py`, then the explicit
  workspace-adoption step REVISION-5 documents. No workspace on this machine is adopted today.
- **Improvements, not conditions:** F2 (`caffeinate` as inert), F3 (poll during inference), F4 (5 s tick).

No new engineering condition on the mechanism is required.

## For the CEO, in plain words

Is this activatable now? **Yes, once it is landed — and nothing about the mechanism is left for an engineer.** The
one defect my predecessor found is fixed, and I proved it the hard way: I re-ran his exact failing experiment against
the new code and the crashed session's leftover checker now steps aside in under a second instead of stealing the new
session's turn. Then the team did what he asked for and what no earlier round had done: they crashed a real Claude
Code the way a real crash happens — killing only the main process, leaving its helpers alive — once for a fresh
restart and once for a resume of the same session, and in both the new session picked the work up by itself, finished
the job and had it verified, with nobody typing anything. I checked the kill command in the code that actually ran
and the process records it left behind, not the summary. Two things stand between this and running on your machine,
neither of them a decision for you: the commit's paperwork points at four files that are in the wrong folder, which
the repository's own gate refuses, so Codex fixes one file before Rich lands; and Rich reruns the installer at land
as he does every time. The one cost still in it: after a crash, the new session waits up to five minutes for a
harmless leftover helper process to time out before it resumes — it tells you it is waiting and why, and then
carries on alone. I have written down the small change that removes that wait.

## What I did not do, by choice

No paid model runs; the six recorded trials keep their own hashes and were not rerun. No merge, push, install,
adoption or activation. No edit to any file of the revision, including the four broken citations, and no exemption
line — both would have been me doing the revision's work or hiding its defect. From the private archive I read three
records (`adapter-hooks.jsonl`, `hook-process-events.jsonl`, `exhausted-crash-acceptance.json`) and one runtime
snapshot, printing only process identities, exit codes, timings, the adapter's own message heads and a source diff;
no permission context, transcript text or account data was displayed. Every fixture process my probes started was
verified gone afterward (`remaining_group_members []` on both probe cases; the mechanical suite's
`no_owned_fixture_processes_remain` true on all seven). The recorded runner binary was copied into my worktree's
gitignored `app/target/debug/` to run the lease check and is not part of any commit.
