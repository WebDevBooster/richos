# Revision 5: verification and review handoff

Branch: `codex/owned-outcome-completion`. Base: `e0679a55`.
Worktree: `/Users/alex/ab/richos-wt/codex-owned-outcome-completion`.

Ready for review. The final fresh-session trial passed all 30 checks on the final
source and harness. Same-session resume also completed and passes all 30 checks
in its explicitly labeled scoring companion. Both used zero operational follow-up
input. The source-version distinction and original false results are preserved
below. [REVISION-5.md](REVISION-5.md) explains the implementation.
Historical R4 evidence remains unchanged.

## Review findings addressed

| Finding | Change and evidence |
|---|---|
| C1, discarded operational brief | Preserve the complete lead brief below the registered scope. Worktree paths, commands and constraints survive; a conflicting work selector is rejected. |
| C2, whole-conversation fan-out | Send registered scope, exact citations and subordinate instructions. Bound the UTF-8 envelope to 32 KiB and registered scope/citations to 16 KiB without truncation. Repair oversized cached records through the source-bound registrar. |
| C3, fresh-session pickup | Workspace ownership journal with native PID/start identity, crash-safe transfer, original authority/restrictions, exclusive ownership and startup reconciliation. Both fresh and same-ID restart are exercised with an actual interrupted child. |
| C4, sidecars at land | Actual installer exercised in a disposable engine copy; all three owned-work sidecars match content and the production pointer is unchanged. Production installation remains a landing step. |
| C5, permission disclosure | First unapproved operation is refused for routine recovery; a necessary repeated operation gets independent review before a native prompt may stand. No automatic grant. `deny` refuses all new requests; it is not passthrough. |
| C6, deterministic cases and dead code | Independent work remains selectable beside pending scope; revoked IDs cannot select newly registered work. Removed dead PENDING and overwritten retry assignment. |
| F8, composed acceptance | Real Claude Code 2.1.266 trials combine stale backlog, obsolete assertion, genuine defect, engineer plus review, pending unrelated D-7, interruption and restart. Original requests and negative constraints are unchanged. Results below distinguish product failures from meter corrections. |

## Deterministic verification

These are actual executed checks, not test inventory totals. Logs and source
identities are retained with the evidence package.

| Check | Result |
|---|---|
| `cargo test --manifest-path app/Cargo.toml -p richos-core` | 1,104 passed, 0 failed, 4 ignored. Includes 5 doc-tests; 1,099 direct tests executed. Source hashes unchanged throughout. |
| `cargo test --manifest-path app/src-tauri/Cargo.toml` | 77 passed, 0 failed, 0 ignored. |
| Native adapter/lifecycle on final scheduling correction | 106 passed. Earlier 92-test result retained separately. |
| Cached dispatch | 31 passed. |
| Registration Rust boundary | 6 passed; included in the core total above. |
| Actual rebuilt `richos-run` with scripted native registration transport | 3 passed, including oversized brief rejection. |
| Actual engine guard plus mutation suite | 67 cases and 27 mutation properties passed. |
| UI with available Playwright runtime | 6 permission-panel checks and 29 assignment-panel checks passed. |
| README claims check | Passed. Inventory now 1,103 direct tests plus 5 doc-tests; 4 direct tests are ignored. |
| Disposable engine installer | Three matching sidecars, unchanged production engine pointer, exit 0. |
| Desktop executable build | Exit 0. Two existing activation dead-code warnings remain. |

The long-history dispatch fixture retains a 186,141-byte conversation but sends a
1,406-byte teammate envelope. This is a per-spawn comparison, not a claim about all
registration costs: the registrar's input for that fixture is 186,449 bytes.
Citation membership verifies source linkage, not semantic completeness of scope.

## Original failed trials and meter corrections

The first fresh and resume trials (`7b2h3xej`, `ulybu2cs`) did not inject the
required interruption. Claude automatically backgrounded an Agent call despite
there being no explicit background flag in the request. The meter mistook the
actual launch acknowledgment for a completion. Both trials were stopped using
only their own disposable process groups and their original false results remain
unchanged. Their artifact/parser/completion checks were unfinished at that point;
they are not passing product trials.

The corrected detector uses the linked native result's `isAsync`, launch status,
agent ID and tool-use ID. Fourteen deterministic checks plus replay of the two
original saved transcripts demonstrate the correction without another model
sample. A new real trial was necessary to inject the missing interruption; saved
history cannot retrospectively undergo a process restart.

The corrected resume trial (`5rtp9ghb`) interrupted actual child work and resumed
the same session without an assignment argument or operational PTY input. The
engineer resumed, executed the required tests and JSON parser, delivered the
correct diagnosis and received leader review. The independent auditor verified
completion. D-7 stayed pending and protected files stayed unchanged.

Its original result remains false because the input meter treated Claude's
system-origin stopped-worker notification as an extra human input. It lacked the
`tool-use-id` present on ordinary completion notifications. The corrected meter binds that exact notification to the recorded interruption,
native origin/session, known launch metadata, agent ID and output path. Fourteen
negative/positive stopped-notification cases cover that binding. Twelve additional
cases cover a native completed notification that also omits the tool-use ID,
requiring an unambiguous launch and rejecting ambiguous resumed generations.
Human lookalikes remain unexpected. Separate `restart-scoring-re-evaluation.json`
companions change exactly the two input-derived checks: the resume companion
passes all 30 checks; the fresh companion remains false for its three real
completion failures. Neither original result was rewritten and no provider call
was used for scoring repair.


The corrected fresh trial (`nu04n__f`) exposed a product failure. Recovery,
engineering, execution and review proceeded, but five inspections during active
work exhausted the allowance and saved an hour-long retry deadline. The actual
reviewer then completed and the leader corrected the final diagnosis. The next
inspection still waited for that deadline. Native completion prose is not a
substitute for the missing independent completion record. The correction grants a durably consumed checkpoint from actual finished
worker execution. A deterministic replay of that same saved state now reserves one
inspection immediately (attempts 5 to 6) and refuses a duplicate checkpoint. The
replay uses a mock inspector, so it is scheduling evidence, not a new real-provider
completion claim. All original state bytes remain unchanged. Twelve checkpoint
cases also passed an independent implementation-peer check.


## Checkpoint implementation trials

The next frozen pair used adapter `dba6f917…` and harness `c0d1f92a…`.

- `eb0nlocp`, same-session resume: engineering and review finished, the new
  completion checkpoint was durably consumed and the real auditor saved complete.
  Native child `agent-a5a3bc64af63a8b83` made both source edits. The original result
  fails only the two input measurements because native background Bash completion
  notifications were outside the Agent-only meter. The raw argv/PTY log contains
  zero operational inputs. A separate scoring companion passes all 30 checks. The
  Bash matcher has 16 positive/negative cases and binds the exact successful native
  background launch, tool ID, task ID, source assistant UUID, observed output path,
  session, workspace and ordered timestamps. The original result remains false.
- `ekryio6b`, fresh-session pickup: the native nested completion arrived as an
  `attachment` with `type=queued_command` and `commandMode=task-notification`,
  carrying the exact child and tool-use IDs. The parser only recognized native
  user notification rows, so it kept that finished child marked running. The
  checkpoint stayed unavailable and the run reached its original 900-second
  ceiling with independent completion still unsaved. This is a product failure,
  not merely a scoring issue. The original false result is retained.

The queued-event correction reuses the exact invocation, actor, session, timing
and successful-execution checks. It reads the structural native prompt, not its
rendered text. It does not broaden completion authority or change permissions.
The affected fresh-session scenario passed after the correction. The
same-session result retains its own source identity; it must not be relabeled as
a paid trial on later bytes. Its source delta is the additional native carrier,
covered by deterministic tests and saved-transcript replay.

## Final native acceptance

| Scenario | Observed result | Evidence |
|---|---|---|
| Fresh restart, `0pp6t7vi`, final adapter `03b43e7f…` and final harness `f0fe7677…` | Original result passes all 30 checks, exit 0. One original assignment, zero operational follow-ups, actual child interruption, new owner session, engineer repair, review, executed tests/parser, unchanged protected files and D-7 still pending. Independent completion saved after one completion checkpoint. | [Original result](evidence-r5/fresh-queued-final/result.json) |
| Same-session resume, `eb0nlocp`, adapter `dba6f917…` | Real work and independent verification completed using one checkpoint. Original result is false only for the two input-meter checks; the corrected companion passes all 30 on unchanged raw history. Zero actual operator inputs beyond initial assignment and setup. | [Original result](evidence-r5/resume-final/result.json), [scoring companion](evidence-r5/resume-final/restart-scoring-re-evaluation.json) |

The final fresh run exercised the queued attachment in a real native call chain:
its checkpoint linked two completed invocations and 38 successful tool receipts,
with one ordinary native notification and one queued native attachment. The
independent auditor then saved `complete`; the checkpoint itself did not declare
success. Both the fresh and resumed runs recorded six actual outcome audits.
Neither observed a routine parser permission question in prose. That fixture
measurement is not a universal natural-language guarantee.

Seven paid native trials were started in R5. Their chronology, initial meter
failures, actual scheduling failures and later corrections are all retained.
No failed original was relabeled as passing. Re-evaluations use separate files
and record the exact original hashes and corrected scorer hash.

## Reproduction and evidence

The final native commands are:

```sh
python3 app/scripts/test-owned-wake-native.py --assignment --restart fresh
python3 app/scripts/test-owned-wake-native.py --assignment --restart resume
```

Harness-only checks use `--self-test-restart`, `--self-test-r3` and
`--self-test-parser`. The restart mode also accepts `--restart-replay-evidence`
for missed-interruption detection and `--restart-scoring-evidence` for writing
separate scoring companions. These self-test/replay modes make no provider calls.
The 3-case registration protocol check uses
`python3 app/scripts/test-owned-registration-protocol.py` against the rebuilt
runner and scripted transport.

Final native adapter SHA-256:
`03b43e7fefd0a34a79d8cc3b6c1ae771aeb6515e7092cc46be88ead304c51c75`.
Final acceptance harness SHA-256:
`f0fe7677f703e1b51e49fca64b1b9a474e786c4cf0d20906255a0c5a8f6af81b`.

Each real trial records its own immutable source, runtime and executable identity.
The final evidence index maps original paths to byte-identical copies with sizes
and SHA-256 hashes. Raw account context and immutable executables are retained in
a private local archive with their hashes, not substituted with edited evidence.
The final source identity covers the reviewable code and documents. Original
failed results remain available beside any explicitly labeled companion score.

## Limits and activation

No production workspace has been adopted, no installed app replaced, no merge or
push performed. Follow REVISION-5's stable-checkout installation steps at land;
permanent hooks must not point at the disposable worktree.

Fresh pickup recovers recorded obligations in the same canonical workspace after
its prior owner and process group are dead. It does not discover arbitrary work
from previously unmanaged transcripts, migrate a native assignment into RichOS or
run while both applications are fully closed. Unknown live ownership fails closed.

Native ordinary prose and transient permission UI remain outside a literal
zero-trivial-question guarantee. The parser-question measurement is specific to
this fixture. Native Stop inspection can incur a Sonnet call on each changed turn;
“not every turn” is not an accurate blanket cost claim for this surface.

[IMPROVEMENTS.md](IMPROVEMENTS.md) retains separate follow-on suggestions.
