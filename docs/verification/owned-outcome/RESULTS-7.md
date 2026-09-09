# Revision 7: verification and review handoff

Branch: `codex/owned-outcome-completion`. Base: `125906f5`.
Worktree: `/Users/alex/ab/richos-wt/codex-owned-outcome-completion`.

This revision fixes the orphaned checker ownership defect identified in
[Sage's R6 review](evidence-r7/review-r6.md). It adds durable inspection and wake
delivery records and tests detached hook processes rather than treating every
hook as a member of the leader's process group. See [REVISION-7.md](REVISION-7.md).

## Findings addressed

| R6 finding | R7 correction |
|---|---|
| F1 / C10: old hook consumes replacement reconciliation | Bind each audit to its actual native ancestor at entry. Recheck that immutable binding through waiting, reservation, inspection, publication and actual output delivery. |
| F2 / C11: crash proof misses native process layout | Mechanical hooks run in separate process groups. Real native trials seed exhausted pacing and kill only the recorded leader PID while its actual detached Stop hook sleeps. |
| F3: transient process observation aborts recovery | Three bounded attempts distinguish unavailable observation from confirmed ownership loss. Persistent failure retains unfinished work and emits an accurate recovery diagnostic. |
| F4: hook death strands a consumed attempt | Persist inference lifecycle, inherit a separate lock through the actual runner and permit one immediate interrupted-attempt retry after that lease becomes free. |
| Live acceptance: lost incomplete findings | Deliver current validated incomplete findings in a source/owner-bound inspector data envelope, separate from host instructions and native permissions. |
| Live acceptance: stopped/resumed native completion | Recognize only the narrowly generation-linked completed result of a successful native resume; stopping alone earns no completion credit. |
| C4: installation sidecars | Isolated real installer passes with matching final sources and unchanged production pointer. Stable-checkout installation remains required at land. |

Peer review also caught stale queued wake text surviving a CEO correction. Wake
records now bind to the current instructions and evidence. Delivery rechecks that
context under the state lock, flushes output and only then acknowledges it. This
is at-least-once delivery: a crash between flush and acknowledgment may repeat the
same message without granting more authority or another inspection.

## Executed checks

| Check | Result |
|---|---|
| Native adapter suite | 132 tests passed on final runtime `e6c970d5…`. |
| Cached dispatch suite | 33 tests passed. |
| Actual-process mechanical suite | 7 cases, 115 checks passed with unchanged source identity and zero provider calls. |
| Actual Rust runner lease | 5 checks passed using scripted native transport. Its inherited lock remains held after the parent closes its descriptor and is released when the runner exits. Zero provider calls. |
| Engine guard and mutation suite | 67 of 67 cases and 27 of 27 mutation properties passed, exit 0, in 296.1 seconds on unchanged final sources. Earlier passes retain their original source hashes. |
| Isolated installer | Exit 0, all three owned-work sidecars match final sources and production pointer unchanged. No production activation. |
| Native harness selftests | Restart, process cleanup, permission parsing, wrapper FD forwarding and mixed audit/registrar scoring passed. Seven actual disposable-process barrier cases and 24 resumed-generation scorer cases passed; composed installation contains exactly one additional synchronous fixture hook. |
| README claims | Six checks passed. Rust inventory is unchanged. |

No Rust or UI runtime source changed in R7. Earlier Rust and UI tests retain their
original revision identity and are not relabeled as newly executed tests.

## Mechanical process acceptance

The [final result](evidence-r7/mechanical-resume-final/result.json) proves:

- Detached old hooks cannot inspect, reserve replacement work, publish or wake
  after their original native leader dies. Fresh replacement reconciliation took
  0.394 seconds. Same-ID replacement waited for the shared audit lock and
  reconciled in 0.970 seconds.
- Killing only an audit hook leaves its inspector alive with the inherited lease.
  The replacement does not spend another inspection while that inspector lives.
  After it exits, one immediate retry reconciles in 0.656 seconds.
- Killing that retry too does not grant a third immediate attempt. Ordinary
  assistant chatter preserves both the consumed retry and ordinary pacing.
- A live residual group member withholds transfer and is identified in both hook
  channels. Following scripted removal of that exact fixture process, the same
  outstanding hook picks up the work in 5.702 seconds, within the declared
  five-second poll plus three-second transport margin.

These are real OS processes and shipped hook CLIs with scripted leader actions
and a fake inspector. They do not establish model behavior. The runner lease
check additionally invokes the actual `richos-run` executable, using scripted
native transport rather than a paid model.

## Real native crash acceptance

Fresh crash recovery passed all 38 checks, including saved independent
completion and zero measured operational follow-ups. It ran runtime `2eb1d3ab…`
and harness `66fa8b33…`. The replacement reached an allowed Agent call in
376.3 seconds, including natural expiry of the original group's `caffeinate`.
The inspector report reached the actual native transcript.

That live fresh result predates the narrow stopped/resumed completion-carrier
correction. It is not a live run of final runtime `e6c970d5…`. A positive offline
comparison on the immutable passing fresh transcript shows both runtimes produce
the same non-null completion checkpoint. The comparison removes only the already
consumed checkpoint IDs from a derived preclaim state and rebinds paths to
byte-identical transcript copies. No source rows or timestamps are altered and
no provider or hook runs. See
[fresh checkpoint equivalence](evidence-r7/fresh-checkpoint-equivalence/artifact-index.json).

The final same-ID trial passed all 41 checks on final runtime `e6c970d5…`
and harness `722103bf…`, with zero operational follow-ups and successful exact
process cleanup. The replacement reached an allowed Agent call in 310.2 seconds,
including natural expiry of the original group's survivor. Verified completion
was saved 693.1 seconds after the initial launch. There were two actual
`audit-session` calls. The detailed inspector report reached native transcript
row `c24bd5b9-219f-400e-9fd1-6035f2eeafd9` at `2026-09-09T15:43:33.031Z`.
See the [final result](evidence-r7/native-resume-final/result.json) and
[derived receipt](evidence-r7/native-resume-final/final-acceptance-receipt.json).

That trial used the explicitly disclosed scheduling/interruption fixture. The
original child had completed a real Read, then its next tool was held for 4.66
seconds. A real detached Stop audit was sleeping at the crash. Only the original
leader PID was killed; the held original tool was aborted after that death and
all other survivors were retained. The replacement received no assignment or
nudge and independently finished repair and review.

The CLI resumed the same session but chose to dispatch a replacement worker.
It did not exercise SendMessage reuse of the stopped worker in this final live
run. That distinct carrier is verified against the earlier actual failed
transcript and by regression tests, as described below. The final live result
must not be presented as a second live execution of that carrier.

| Live acceptance | Runtime | Result |
|---|---|---|
| Fresh crash, after diagnostic-delivery fix | `2eb1d3ab…` | 38/38, verified complete, zero operational follow-ups |
| Same-ID crash, bounded scheduling/interruption fixture | `e6c970d5…` | 41/41, verified complete, zero operational follow-ups |

These are bounded acceptance results with the source and fixture distinctions
above. They do not prove universal autonomous completion.

The harness explicitly injects only pacing fields after real guarded child work
starts. It does not claim five paid audits occurred. Crash injection is a single
SIGKILL to the original leader PID. Detached hooks and other survivors remain
alive through recovery. The replacement receives no assignment or nudge.

## Preserved preliminary failures

The first mechanical run passed five cases but failed both orphan cases: its
SIGSTOP barrier could freeze the hook while a state or ownership lock was also
held, preventing replacement capture. It also spanned the last process-observation
retry source change. The original false result and exact snapshots remain in
`mechanical-initial`. The corrected barrier proves those other locks are free. Its passing result
remains under `mechanical-final`. After the feedback correction, all seven cases
passed again under `mechanical-feedback-final` with unchanged runtime `2eb1d3ab…` throughout that run.
Six successful CLI recovery responses actually carry the inspector report with
the replacement leader's matching identity; the interrupted-retry limit emits none.
The final stopped/resumed carrier correction passed all seven cases again under
`mechanical-resume-final`, with unchanged final source identity.

The first scripted runner-lease fixture omitted verified provenance from its
artificial user message. The actual runner correctly refused it before provider
launch. That failed fixture and its original bytes are retained. Adding the
required fixture provenance allowed the independent lease check to run.

The first real fresh trial passed 35 of 38 checks, including every crash,
owner-lineage, startup-wake and inherited-lease check. It reached authorized Agent
dispatch in 436.5 seconds after replacement startup, including natural expiry of
the original group's `caffeinate` process. It nevertheless failed independent
completion within the actual 20-minute execution ceiling. Detailed inspector findings
stayed in private state while the renderer emitted generic continuation. The fresh replacement also used normally permitted tools to edit fixture files
before transfer; this is not evidence of an exclusive filesystem execution fence.
That boundary is recorded separately in IMPROVEMENTS.md. All
three failed checks concern missing verified completion. The original failed
result and exact process cleanup are retained; no passing result replaces them.
The corrected fresh trial subsequently passed all 38 checks with actual report
delivery, independent completion and zero measured operational follow-ups.

The first real resume trial selected an authorization ledger instead of the
primary session file when injecting exhausted pacing. It therefore did not test
the claimed crash condition. Its original run and exact cleanup receipt are
retained as a failed trial, not converted into a pass. The selector now derives the adapter's exact canonical primary-state filename.
Its regression creates the authorization ledger first and verifies its bytes
remain unchanged.

The second real resume trial received the detailed findings and finished actual
engineering and review. It still failed verification at the execution ceiling:
the old agent's native stopped notice was ignored, so a later same-agent resumed
completion without a tool-use ID could not earn a final inspection checkpoint.
Three completion checks failed. The input meter also rejected that native notice,
causing two additional failed checks. The original failed result, full transcript
snapshot and read-only reproduction are preserved. The corrected parser produces a valid two-invocation checkpoint on an immutable
replay of this exact input, while the prior parser returns none. Four altered
authentic-row variants remain rejected and the consumed checkpoint earns no
duplicate credit. No provider or hook ran during that comparison and the original
bytes remained unchanged.

The next same-ID trial ran final runtime `e6c970d5…` and completed the assignment
before a sleeping Stop crash window appeared. Its work checks and independent
completion passed, but the aggregate `artifact_completion_verified` field remains
false because that existing meter also includes restart checks. It failed the crash
acceptance protocol, despite completing the actual work without operational
follow-ups. Its original false result remains under
`native-resume-no-crash-window`. Repeating the same fixture would merely sample
a different model strategy. The affected follow-up instead adds an explicit
bounded scheduling/interruption barrier, described in REVISION-7.md. It does not change product behavior
or the assignment.

The live-tested harness also had stale descriptive metadata: its
`acceptance-contract.json` recorded a 900-second ceiling and group-stop wording,
while the executed code used 1,200 seconds and sent SIGKILL only to the leader
PID. The command implementation, timestamps and exact signal receipts establish
what ran. Those original records are preserved. The corrected harness uses one shared ceiling value for metadata and execution
and describes the PID-only crash. Metadata and 24 resumed-generation scorer
cases pass. Earlier live results retain their own source identities; they are
not relabeled as runs of the final harness.

## Reproduction and evidence

The runner checks require `app/target/debug/richos-run`. Build it if absent with
`cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run`.
R7 reused the unchanged, recorded binary rather than claiming a new Rust build.

From this checkout:

```sh
python3 engine/scripts/lib/owned-session.test.py
python3 engine/scripts/lib/owned-dispatch.test.py
python3 app/scripts/test-owned-recovery.py
bash engine/scripts/hooks/ceo-asks.test.sh
python3 docs/verification/owned-outcome/evidence-r7/check-runner-lease.py
python3 docs/verification/owned-outcome/evidence-r7/install-check.py
python3 docs/verification/owned-outcome/evidence-r7/verify-evidence.py
```

Paid native acceptance uses `app/scripts/test-owned-wake-native.py` with
`--assignment --restart fresh --exhausted-crash`, then the same flags with
`--restart resume --hold-child-for-crash` for the final affected trial. The
additional flag holds one original child after a real Read, then aborts its held
tool on original leader death or after 180 seconds. Existing product hooks and
permissions remain intact. A timeout without a naturally sleeping Stop fails
the fixture. Each live trial has a 20-minute ceiling. These commands launch real
Claude sessions and are distinct from the zero-provider mechanical suite.

The global artifact index maps original evidence to byte-identical public or
private copies with SHA-256 hashes and byte counts. Raw account context and
binaries are retained privately in
`/Users/alex/.codex/artifacts/richos-owned-outcome-r7-2026-09-09`, with restricted
permissions. Mechanical public transport records explicitly omit nonfixture
configuration and point to their exact private raw inputs; they are not presented
as unredacted raw inputs. The verifier's `--public-only` option explicitly counts skipped
private artifacts. Source identity is recorded separately from artifact identity.

Runtime SHA-256:
`e6c970d530ffbacb817a9abfef821160f56f6391a26d29a85e5a09ceda8df7db`.
Actual runner SHA-256:
`ee6c9bf28ad0d42ea71b22adc08cbc094203e4ed68c8f4afc878623491935fb3`.

## Activation and remaining limits

No merge, push, production installation or workspace adoption occurred. This is
an isolated review handoff. The stable checkout still needs the installer at land.

The same-ID observer remains read-only while the old group can act. It cannot
terminate a persistent straggler with Bash. Native ordinary prose still has no
universal zero-trivial-question guarantee. These limits and unrelated improvement
suggestions remain in [IMPROVEMENTS.md](IMPROVEMENTS.md). Passing this bounded crash
protocol does not establish universal autonomy for arbitrary assignments.
