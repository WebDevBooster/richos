# The readiness gate that refused every background job — what was measured, and what was fixed

**Date:** 2026-09-18. **Branch:** `cc/echo-opus-pluginbind1`. **Base:** richos main `9da3c7d5`
(candidate .7, `v1.2.0-nightly.20260918.1`). **Fix:** `e35634c6`.

**Spec:** the background-work spec, revision 5. **It is not in this repository**, and a reader
with only this one will not find it: it lives in the private richos-hq record, under that
repository's own plans directory, named for 2026-09-17. Section numbers below (§1.1, §1.2, §1.3,
§2.1, §5.4, §5.8a-ii, §7.1) are that document's. Everything asserted here about the CODE carries
its own `file:line` in this repository, so none of it depends on having the spec to hand.

**The headline.** The first real background job ever given to a shipped build failed 6.5 s after
registration, before its lease ran a single turn, and nothing landed. The cause was not a broken
install: the gate that refused it was asking about a fact nobody had reported yet, and reading
"nobody has told us" as "we were told no". **Every background job on every machine failed this
way, by construction.** The plugin it said had not loaded had in fact loaded, and the app was
holding that plugin's own evidence when it said otherwise.

---

## 1. What was measured, from the candidate's own state

Two assignment records under the QA scratch HOME's
`Library/Application Support/com.richos.app/engine-state/assignments/3481a6b4…/`:

| id | `registered_at_ms` | failure raised | delta |
|---|---|---|---|
| `581ed860-f53b-4b9e-90eb-2fcc9a9ae9b4` | 1789719184452 | 1789719190997 | **6545 ms** |
| `1eb68094-4c0a-4bef-be2f-3dd18c0ba379` | 1789719368455 | 1789719375941 | **7486 ms** |

Both carry, verbatim:

```
"state":"failed",
"detail":"cognition protocol: The desktop engine plugin did not load.",
"work_session":null,
```

6.5 s is the time to spawn `claude` and answer the handshake. It is not the time to run a turn,
and `work_session: null` says no session was ever recorded against the work.

**A correction to the brief this work came from, and it matters only for precision.** The brief
quoted `"updated_at_ms": 1789719190997` for `581ed860`. The record's `updated_at_ms` is
**1789719579401** — that is the notice DELIVERY (`delivered_at_ms` holds the same value, 394.9 s
after registration, when the card was shown). 1789719190997 is `notices[0].raised_at_ms`, the
moment of failure. The brief's 6.545 s figure is therefore correct as time-to-failure; only the
field name was wrong. The brief also described one failed assignment; there are **two**.

### 1.1 The refusal was FALSE, not conservative

The work lease's evidence directory
`engine-state/evidence/060e1ec9-27dc-4a2a-b8ca-66b1ac3e5f88/callbacks.jsonl` holds exactly one
line:

```json
{"schema": 1, "callback": {"session_id": "060e1ec9-27dc-4a2a-b8ca-66b1ac3e5f88", …,
 "hook_event_name": "SessionStart", "source": "startup"}}
```

`SessionStart` is registered in **one** place: the engine plugin's own `hooks/hooks.json`,
written by `richos/app/crates/richos-core/src/engine_profile.rs:105-109`. So the plugin had
loaded and its hook had already run. **The app refused the job for the absence of a plugin while
holding, on its own disk, the plugin's evidence that it was there.**

---

## 2. Why, from source at `9da3c7d5`

Every line below was re-derived rather than taken from the brief.

| where | what it establishes |
|---|---|
| `native.rs:1416` | `engine_plugin_loaded` is set **only** inside the `system/init` frame handler, from `msg["plugins"]`. |
| `native.rs:819` | its default is `false`. |
| `native.rs:450-452` | `child_args`'s own doc: the session id is announced *"on `system/init`, which arrives with the first TURN"*. |
| `native.rs:1025` | `session_id` is a locally minted UUID passed as `--session-id`, so nothing about the child is learned at spawn. |
| `native.rs:1185-1250` | `handshake_cancellable` is a `control_request`/`initialize` that reads the reply's `subtype` and *"keeps none of its contents"*. **No init frame at handshake.** |
| `native.rs:2132-2152` | `start_work_lease` calls `spawn_with_tools` and returns. It runs no turn. |
| `work_host.rs:530-552` | `run_one`: `ensure_lease`, then `bind_work_assignment`, **then** the turn. |
| `native.rs:2381/2384/2387` | the bind asserted `engine_plugin_loaded`, `work_tools_loaded` and `automatic_permissions` — all three `bool`, all three set only in that handler. |

**All three were equally broken**; the plugin one merely happens to be checked first. `work_tools_loaded`
(default `false`, `native.rs:809`) and `automatic_permissions` (default `false`, `:812`) would each have
refused the same binding on the same fresh lease.

**Why the conversation lease never hit this.** `prepare_work_turn`'s twin checks at `native.rs:2227`,
`:2250` and `:2260` are reached only after `prepare_request` → `prime_lease_if_needed`
(`spine.rs:3231`, called from `spine.rs:1963`, before the `prepare_work_turn` call at `spine.rs:1974`).
A resident front desk has always taken a priming turn, so its init frame has landed.

**Why it was never seen.** `docs/verification/background-work-app-2026-09-17.md:15-16` says so in its
own words: *"§7.1–7.3 were not walked on screen, and this record does not claim they were."* The
front-desk slice measured the conversation lease only, and the `work_host` unit tests use a fake
cognition (`work_host.rs`, `WorkLease`).

`claude --version` on this Mac: `2.1.275 (Claude Code)`.

---

## 3. The fix — `e35634c6`

`InitFact { NotYetReported, Yes, No }` (`native.rs`), deliberately the same shape and the same
argument as `skills::SkillsVerdict`, whose own doc already said it: *"'we have not been told yet'
and 'we were told it is not there' call for opposite responses, and collapsing them is how an
absence gets reported as a fact."* `skills_verdict` was given that third state for exactly this
reason; these three fields were not.

`InitFact::reported` has no way to produce `NotYetReported`, so the three fields can only leave
that state inside the init handler — which makes "nobody has told us" a statement about the wire
rather than about the order the app happened to call things in.

| path | when it runs | rule |
|---|---|---|
| `bind_work_assignment` | **before** the lease's first turn | only `No` refuses |
| `Cognition::work_readiness_after_turn`, read by `work_host::run_one` step 3a | **after** the turn, before the settle reading | anything that is not `Yes` refuses |
| `prepare_work_turn` (conversation lease) | after priming | `!= Yes` — byte-identical to the old `!flag` |

**This is a MOVE, not a relaxation, and that distinction is the whole of it.** The check exists
because `--plugin-dir` accepts a path it cannot use and still reports success — measured, cell K4
of `docs/verification/inner-doctrine-skills-2026-09-06/`: exit 0, clean handshake, `plugins: []`.
A genuinely absent plugin still fails the job and still says so, in the same words, one turn
later. The three sentences are now shared constants (`ENGINE_PLUGIN_ABSENT`, `WORK_TOOLS_ABSENT`,
`AUTOMATIC_PERMISSIONS_ABSENT`), so the two gates cannot drift over which fact carries which
words. **No new user-visible sentence was introduced.**

`richos-app-engine` was a literal in two files. It is now `engine_profile::PLUGIN_NAME`, used by
the manifest writer and by the wire check, with a test — two spellings of one name would make
this readiness check answer a false absence, which is precisely the failure being fixed.

### 3.1 A third design, considered and rejected ON MEASUREMENT

The `SessionStart` callback of §1.1 is a *positive* signal that the plugin loaded, and it exists
before any turn. Gating the bind on it was rejected: that directory's birth time is **1789719190**
and the refusal was raised at **1789719190997** — the hook's evidence and the refusal landed in
the same second. Gating on it means waiting on an asynchronous Python hook against a deadline,
which is a timing guess dressed as a check, and a slow hook would resurrect this exact false
refusal.

### 3.2 What this fix does NOT do — named rather than left to be discovered

On an install whose plugin genuinely did not load, the **first** assignment on each work lease now
reaches its turn before being failed by name; every subsequent one is refused at the bind. The
stronger variant — aborting the turn the instant the init frame lands, before the model can act —
was not built. It needs reader-thread-to-cancel wiring and a way to tell a readiness abort from
the CEO's own stop, which is a larger change than this blocker needs. The cost of not having it is
bounded: without the plugin there are no `worker.md`/`reviewer.md` agent definitions
(`engine_profile.rs:91-96`) so the back end cannot dispatch, and the engine's authorization does
not live in the plugin — `mega-lander` enforces the standing grant, the frozen instruction and the
seat server-side. What is lost for that one turn is the plugin's hook evidence and spawn preflight.

---

## 4. Tests — before and after

`cargo test -p richos-core`, run from `richos/app`. Baseline on `9da3c7d5`: **671 passed, 0 failed,
1 ignored**. After: **676 passed, 0 failed, 1 ignored** — the five new tests, nothing else moved.

### 4.1 The regression test, written first and proven RED on `9da3c7d5`

`native.rs::native_driver_tests::a_fresh_work_lease_is_never_refused_over_a_fact_its_child_has_not_reported_yet`

```
running 1 test
test native::native_driver_tests::a_fresh_work_lease_is_never_refused_over_a_fact_its_child_has_not_reported_yet ... FAILED

thread '…' panicked at crates/richos-core/src/native.rs:2807:13:
a lease that has run no turn was refused over a fact nobody has reported: cognition protocol: The desktop engine plugin did not load

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 672 filtered out; finished in 0.09s
```

The panic quotes the production sentence, byte-identical to the `detail` on disk in both failed
records of §1. After the fix, the same test:

```
running 1 test
test native::native_driver_tests::a_fresh_work_lease_is_never_refused_over_a_fact_its_child_has_not_reported_yet ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 672 filtered out; finished in 0.10s
```

It asserts the binding **reaches the seat bind** (the fixture bridge cannot hold one), so the three
negatives are evidence rather than a gate that quietly moved elsewhere, and it re-reads the three
fields afterwards to prove they are still `NotYetReported` — the gate passed because it asked about
a reported absence, not because the fields were made optimistic.

### 4.2 The positive controls

- `a_work_lease_whose_init_frame_omits_the_engine_plugin_still_fails_the_assignment_by_name` —
  drives the real reader thread with a scripted child over four cases: plugin absent, work tools
  partial (four of five), `permissionMode` not `auto`, and all present. Each reported absence
  refuses **both** the post-turn read and the next binding on the same lease, with its own sentence.
- `only_a_reported_absence_refuses_a_binding_and_silence_refuses_only_after_a_turn` — the two gates
  as pure functions, including that a reported absence outranks an unreported fact earlier in the list.
- `the_engine_plugin_is_named_once_and_the_manifest_and_the_wire_check_share_it`.
- `work_host.rs::tests::a_lease_that_reports_one_turn_late_that_it_had_no_engine_plugin_fails_the_job_by_name`
  — at the level the CEO sees. The obligation is deliberately `Settled`, the most favorable settle
  reading there is, so the readiness sentence has to win over it; the row and the notice both name
  what was missing. Control on the same harness: an equipped lease still settles.

### 4.3 The other gates

- `cargo check` in `richos/app/src-tauri`: **Finished**, 4 pre-existing dead-code warnings, none
  of them referencing anything this change touched.
- `richos/app/ui/` was not touched, so the UI runner was not run.
- `bash richos/app/scripts/gui-boot.test.sh`: run in the foreground after confirming
  `pgrep -fl "MacOS/richos-tauri"` was empty (the candidate had exited during this session — it was
  pid `98757` at session start). **14 PASS, 0 FAIL** (S1, A0–A8, C1–C4), then it stopped at exit 2:

  ```
  gui-boot.test.sh: provide an extracted engine with runtimes via RICHOS_GUI_ENGINE_SOURCE, or a verified RICHOS_RUNTIME_DIR.
  ```

  That is an environment precondition — an extracted engine delivery with runtimes — not a failure
  of this change, and the brief forbids sourcing it from `~/RichOS`. The boot cases beyond C4 were
  therefore **not reached here**; they belong to the land, where the engine is available. Its
  `trap cleanup EXIT` (line 812) fired: no temp directories and no processes were left behind.

---

## 5. The receipt sentence — NOT fixed, and why it is not mine to fix

The front desk said *"It's running now"* about a job that had already failed. Traced end to end:

- `assignment.rs:279-283` builds it: *"I've taken down your assignment: {}. It's running now, and
  you'll find it with your saved work. I'll tell you when there's something for you to look at."*
- `assignment_tools.rs:170` returns `{"recorded": true, "say": receipt.sentence()}` — the model is
  handed that string **to say**. So it was reciting a receipt, not paraphrasing one.
- **The spec requires it.** §1.2, revision 5, at line 270 of the private richos-hq spec named in
  the header above: *"Rich's closing sentence names the assignment in the CEO's own terms, **says
  it is running**, and says where it will show up."*
- **The status read was never the gap.** `status_tools.rs:176-178` sorts `Failed` to `finished`; only
  `Registered | Preparing | Running` reach `running`. It cannot report a failed job as running.

So it is neither a model paraphrase nor a code defect. It is a conflict inside the spec, and
`assignment.rs:265-268` argues the other side of it in its own comment — *"**"Taken down" and not
"started".** … so at the moment this sentence is said no workspace exists yet. A sentence claiming
one would be false for the 3.0–3.8 seconds that matter most"* — while the sentence it returns
claims exactly that. §1.3 guarantees only that the assignment is on disk and a workspace exists or
is being created.

Changing a spec-mandated, CEO-facing sentence is not an engineer's call, so it is raised rather than
taken: **`esc-20260918T084325Z-abbf4b04`**, state `work-complete`, for the CEO (its record is beside
this one, under `docs/verification/escalations/`). With this fix landed
the claim is no longer announcing a job that is about to fail seconds later, which is what made it
acute.
