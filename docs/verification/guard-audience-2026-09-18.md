# The app's background dispatch is judged by the user's guards, and the nine-guard refusal was a probe artifact

**2026-09-18 — echo-opus-guards1, worktree `/Users/alex/ab/richos-wt/echo-opus-guards1`, branch
`cc/echo-opus-guards1`, from `60458045` (merged `4eeb5143` mid-slice).**

Rich's ruling, 2026-09-18, standing on the CEO's §57 (*"RichOS is a free app for non-technical
CEOs; nothing the user runs depends on our operator setup"*) and §55 (*"Rich **immediately**
replies with: 'On it!' and only after that does all that work"*):

> The app's `prepare`/spawn path is judged only by guards whose reason protects the app user's own
> work on the app user's own machine. A guard whose reason is the operator's session — a paused CI,
> an unasked CEO TODO, a stale staging, a brief-scope convention of the femcboost session — never
> refuses the app, and the front desk never shows a user an operator-session message. Which guards
> fall on which side is a declared list, not an inference, and a test proves the list.

---

## 1. The first finding: the refusal this slice was dispatched to fix was a probe artifact

**The brief's central measured premise does not hold for the shipped app**, and this was found by
re-deriving it before building on it rather than by quoting the escalation that carried it.

The premise, from `esc-20260918T163906Z-60bd48e1`: *"`richos_work.prepare` … runs `spawn.py` with
cwd and project-dir set to the APP's coordination root (`RICHOS_ENTITY_ROOT`), so `spawn.py`
collects every PreToolUse[Agent] guard from `engine/hooks/hooks.json`. Result on this Mac: `spawn:
refused by 1 of 9 guard(s) - NOTHING WAS CREATED`, `guard-owned-state.sh`, over `system: ci …
PAUSED WebDevBooster/richos`."*

That refusal is real and it reproduces. It is also about a path the shipped app never takes.

**`EngineProfile::configure` sets `RICHOS_SPAWN_HOOK_SOURCES` for every real lease**
(`richos/app/crates/richos-core/src/engine_profile.rs`, the last `.env` of `configure`), pointing
`spawn.py` at the app's own `<plugin>/spawn-preflight.json`. The `richos_work` server is
`mega-lander/app.py` launched by the provider child (`native.rs`'s `mcp_config`), so it inherits
that variable, and `spawn.py`'s `settings_sources` returns that one file and nothing else.

**The probe's `drive_prepare` builds its own environment and never set it.** That is the entire
cause of the nine-guard collection.

Measured both ways on ONE binary, this Mac, under the standing CI pause:

| | what `prepare` answered |
|---|---|
| without `RICHOS_SPAWN_HOOK_SOURCES` (the probe, as it stood) | `spawn: refused by 1 of 9 guard(s) - NOTHING WAS CREATED`; `guard-owned-state.sh` REFUSED, 8 ok |
| with it, exactly as `configure` sets it | `status: "prepared"`, agent payload returned |

Logs, committed: `guard-audience-2026-09-18-logs/before-refused-by-1-of-9-the-probe-artifact.log`
and `…/the-same-binary-with-the-lease-s-own-hook-sources.log`.

Raised the moment it was found, as `esc-20260918T165430Z-73020e78` (state `proceeding`), and the
lead narrowed the job on it the same turn.

### And the probe scored the step before the one that matters

`does_it_dispatch` read `if !ok && !detail.contains("spawn: refused by")`. A spawn refusal therefore
counted as REACHING the dispatch and so as a pass — which is how the run printed *"PASS: every
obligation the register opened is one the engine will prepare work against"* over a run in which
every one of them was refused and nothing was created. Only `status: "prepared"` is a pass now.

**Two defects in one check, and they compound:** the wrong environment produced a refusal the
product never sees, and the lenient scoring hid it behind a PASS. The escalation was written off
the refusal text, which was the only part visible.

---

## 2. What the app's guard surface actually was

Not nine. **Three**, spelled out by hand in two files, with no statement anywhere of why those:

| where | guards | what it is |
|---|---|---|
| `EngineProfile::prepare` → `spawn-preflight.json` | `guard-worktree-isolation.sh`, `guard-brief-scope.sh` | the advance check `spawn.py` runs |
| `app-engine-hook.py`, `PreToolUse` | `guard-sealed-worktree.sh` (every tool) | the real gate |
| `app-engine-hook.py`, `PreToolUse` + `Agent` | `guard-worktree-isolation.sh`, `guard-brief-scope.sh` | the real gate |

**One of the three is an operator-session guard.** `guard-brief-scope.sh` refuses a dispatch that
drifts off a design-round specification recorded in the DEVELOPMENT project; its spec pages, round
verdict history and `scope-ceo-word:` escape line are conventions of that session, and the way out
is a sentence only an operator can write. It has never refused a user, because a user's own
repository carries no such record — which is luck, not design. It is off the app's list.

---

## 3. The classification, as data

`richos/engine/spawn-guard-audience.declaration`, located by
`SPAWN_GUARD_AUDIENCE_DECLARATION` in `orchestration.config`, in the same shape
`owned-systems.declaration` uses. Every one of the nine PreToolUse[Agent] guards the engine
registers — read from `hooks/hooks.json` with `spawn.py`'s own matcher rule, so the matcherless
`guard-sealed-worktree.sh` is in the set — carries its side and the one-sentence reason for that
side.

**USER-WORK — the app runs every one of these**

| guard | why this side |
|---|---|
| `guard-sealed-worktree.sh` | refuses every tool to a worker whose run has ended, so a restarted worker can never write into the user's project again |
| `guard-worktree-isolation.sh` | every file-editing worker gets its own isolated copy first, so two pieces of the user's work cannot write over each other |
| `guard-definition-drift.sh` | a worker must boot on the instructions on disk, so the user's work is not done against instructions that were replaced mid-setup |
| `verify-agent-prompt.sh` | the assignment handed to a worker is complete and its name is free; a duplicate, a missing role or a worker hiring workers all produce work the user cannot use |
| `guard-model-ceiling.sh` | refuses a tier above the declared cost ceiling, and the subscription charged is the user's own |

**OPERATOR-SESSION — the app runs none of these, ever**

| guard | why this side |
|---|---|
| `guard-ceo-ask-first.sh` | a decision prepared in the DEVELOPMENT session's CEO-TODOs; the user has no such ledger and the only way to clear it is an operator asking a question in a terminal |
| `guard-stale-staging.sh` | a product tree whose landed commits have not reached OUR staging; the user has no staging, no deploy script and no product tree of ours |
| `guard-owned-state.sh` | a standing system the DEVELOPMENT session's orchestrator owns; both ways out (dispatch somebody at it, or write an acknowledgement line) are an operator's. **This is the one measured refusing the app's own dispatch over a paused CI.** |
| `guard-brief-scope.sh` | a design-round specification recorded in the DEVELOPMENT project, with an escape line only an operator can write |

**The unclassified case is decided, not shrugged at.** A guard registered in `hooks.json` and absent
from the declaration is NOT run for the app: "judged only by guards whose reason protects the user's
own work" is an allowlist, and an undeclared guard has not been shown to protect anything of the
user's. The hazard that creates — a real user-work guard silently falling off the list — is closed
by `scripts/lib/spawn-guard-audience.test.py`, which compares the declaration against the shipped
`hooks.json` in BOTH directions and fails on either disagreement. 45 cases, 0 failures; the
completeness check was proven able to go red by re-deriving it against a declaration with
`guard-model-ceiling.sh` renamed out.

### Both sides now read it, and neither types a list

- `scripts/lib/spawn-guard-audience.py` — the only reader of the file.
- `scripts/lib/spawn.py` — `--audience app` runs user-work only. `operator` is the default and is
  unchanged.
- `scripts/app-engine-hook.py` — the real gate, `audience.user_work_ids()`.
- `engine_profile.rs` — `user_work_guards(engine)` writes `spawn-preflight.json`.
- `runtime.rs` — the declaration and its reader are required component entry points, so a delivery
  without them fails at verification rather than at a user's dispatch.

**This widened the app from three guards to five**, which was measured before it was written: the
dispatch-only probe with all five user-work guards registered reaches `status: "prepared"` on both
of the register's obligations, every verdict ok
(`…/all-five-user-work-guards-registered.log`). The added cost is those guards' own runtime —
0.2 + 0.1 + 0.5 + 0.2 = **1.0 s** on top of the 0.5 s `guard-worktree-isolation.sh` already spent,
read off the guard table of the morning's run — and it is spent on a background dispatch AFTER "On
it!", so §55 is untouched.

---

## 4. The refusal a user can still see

A user-work guard refusing is legitimate. What reaches the front desk is the declared sentence and
nothing else:

- `guard-sealed-worktree.sh` — *"The connection that asked for this work had already finished, so I
  did not start it. Nothing was created."*
- `guard-worktree-isolation.sh` — *"I could not give this work its own separate copy of your
  project, so I did not start it. Nothing was created."*
- `guard-definition-drift.sh` — *"The instructions for this kind of work changed while I was setting
  it up, so I did not start it on the old ones. Nothing was created."*
- `verify-agent-prompt.sh` — *"This assignment was not complete enough to hand to a worker, so I did
  not start it. Nothing was created."*
- `guard-model-ceiling.sh` — *"This work asked for a more expensive model than this app is allowed
  to spend on, so I did not start it. Nothing was created."*

**The raw guard output never leaves `spawn.py` in app audience, on either channel.** `app.py`'s
`run()` raises with our stderr, the work tool hands that to the model, and the model says it — so
stderr is the declared sentence alone, and the JSON on stdout carries the declared REASON in place
of each guard's output so no future reader of that channel can leak one either. `--audience
operator` still prints all of it. `prepare`'s own `"not every required spawn guard passed"` — the
branch for a guard that could not RUN — is now *"A safety check on this work could not run, so I did
not start it. Nothing was created."*

**Proven on the real engine, not only in the hermetic suite.** Moving `guard-owned-state.sh` to the
user-work side for one run and putting it back, what `richos_work.prepare` handed back was:

```
prepare refused : ValueError: TEMPORARY POSITIVE PROBE. Nothing was created.
```

The declared sentence, nothing else — no guard text, no "refused by N of M", no acknowledgement
line. `…/positive-probe-a-user-work-refusal-in-the-app-s-own-words.log`.

**Contrast.** These are strings a person reads, and they are meant to be read: they are rendered by
the front desk's existing message surface, whose type scale and color pairs are set in
`richos/app/ui/style.css` and are not changed by this slice. Nothing here introduces a new color,
weight or size, so no new contrast pair is created; the floor is the surface's, unchanged. No
exemption is claimed for any of them.

---

## 5. Is `RICHOS_APP_SCOPE` the same root? No — and here is why, named rather than assumed

`esc-20260918T163856Z-18731357` found that `RICHOS_APP_SCOPE` is the engine hook's gate for EVERY
`PreToolUse`, not only the two continuity tools. Re-derived here: `engine_profile.rs` registers the
app hook for nine events with **no `matcher` key**, so its `PreToolUse` registration covers every
tool, and `app-engine-hook.py`'s `PreToolUse` branch raises *"This app turn is stopped or is
supplying context. New actions are unavailable."* whenever that file's `actions_allowed` is not
true.

**It is a different root, and the difference is the whole principle.** The guard-audience defect is
*a gate whose reason belongs to somebody else judging the user*. `RICHOS_APP_SCOPE` is the app's
OWN turn lifecycle: `Cognition::prompt` shuts it at the start of a turn and the reader opens it at
his first words. Nothing in it reads a development session — no CI, no staging, no CEO-TODO ledger,
no spec page. An app turn that is stopped, or that is only supplying context, genuinely may take no
action of any kind, so its breadth is correct rather than accidental. Its message is also the app's
own words already.

**What WAS wrong is in scope and is fixed here: the fact lived nowhere in the code.** Two
escalations and one brief were built on the belief that the flag gated two tools, and deferring the
app's action grant on that basis would have made the register itself impossible — the opposite of
§55. So the registration site now says, where a reader will be when the question next comes up,
that there is no matcher and what that means; and `tests/engine_profile.rs` asserts it, proven able
to go red by injecting a `matcher` (`PostToolUse was registered with a matcher; the app hook's reach
is no longer every tool`) and reverting.

The two-scope-file shape obligation2 landed is confirmed present and untouched:
`mcp_config` gives `richos_continuity` its own `continuity_tools_scope`, and the hook's file keeps
the lifecycle it always had (`native.rs`, the `richos_continuity` registration).

---

## 6. Garbage (CEO §54)

Every fixture prefix these runs create — `richos first reply <uuid>` (the probe), `richos profile
fixture <uuid>` (the Rust integration tests), `spawn-test.XXXXXX` (the spawn suite) — counted **0
in `TMPDIR` before and 0 after**, across five probe runs, one `cargo test -p richos-core` and four
spawn-suite runs.

The machine's overall `richos*` count in `TMPDIR` moved **6919 → 5980** during the same window, for
reasons that are not this slice's: another session's reaper removing pre-existing entries, and
`richos-central-*` fixtures appearing from a concurrent run. It is stated here because the honest
number is the one that includes what is not mine.

**No app instance was put on screen.** The probe is headless by construction — no audio device,
nothing played, no window — so there is no pid to report gone.

---

## 7. Reproducing it

```
cd richos/app

# the dispatch join, no lease, no provider, no model turn — green
RICHOS_PROBE_DISPATCH_ONLY=1 cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime

# the classification, and the test that proves it
python3 <path-to>/richos/engine/scripts/lib/spawn-guard-audience.test.py

# spawn.py's two audiences
bash <path-to>/richos/engine/scripts/spawn.test.sh
```

## 8. Tallies

| suite | result |
|---|---|
| `scripts/lib/spawn-guard-audience.test.py` | 45 cases, 0 failures (new) |
| `scripts/spawn.test.sh` | 58 passed, 0 failed, 0 skipped (43 before, 15 new) |
| `mega-lander/tests/app.test.py` | 31 passed |
| `scripts/test-app-engine-hook.py` | 5 passed |
| `cargo test -p richos-core` | 56 suites, 1314 passed, 0 failed |
| `cargo test -p richos-core --test engine_profile` | 13 passed (10 before, 3 new) |

## 9. What is still open

- **`esc-20260918T165430Z-73020e78`** is the record of the false premise. It is closed by this
  slice's work; the question it asked — should `guard-brief-scope.sh` come off the app's list —
  was answered by the lead the same turn ("brief-scope, an operator-session guard, leaves the app's
  list") and that is what is built.
- **`esc-20260918T163906Z-60bd48e1`** (the nine-guard refusal) is answered: it was a probe artifact,
  the probe is fixed, and the real path is green and now declared.
- **`esc-20260918T163856Z-18731357`** (`RICHOS_APP_SCOPE`) is answered as §5 above: a different
  root, left in place by design, with the fact that misled it now written at the registration site
  and pinned by a test.
- **Not touched, and named so nobody assumes otherwise:** whether the app's provider child inherits
  a developer's `~/.claude/settings.json` at all. `configure` does not set `CLAUDE_CONFIG_DIR`, and
  `spawn.py`'s `settings_sources` would read that file if the override were ever absent. The
  override is always set, so this is not live — but it is the second place the app's guard surface
  could pick up an operator's session, and it has not been measured.
