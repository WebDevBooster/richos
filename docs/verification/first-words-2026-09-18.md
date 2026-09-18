# His first words come from the APP, and the priming turn is spent before he types

**2026-09-18 · branch `cc/echo-opus-firstwords1` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`), continuing
`docs/verification/first-reply-2026-09-18.md` and the two levers it named and did not pull
(`esc-20260918T132721Z-19c84d88`)**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*

Two runs of `crates/richos-core/examples/first_reply_timing_e2e.rs` against the real provider on
the CEO's subscription — **six model turns, which is the whole of what was spent**: each run is a
priming turn, a task turn and a question turn. Logs verbatim in `first-words-2026-09-18-logs/`.
`claude` 2.1.275.

**Run B is a finding rather than a confirmation**, and the record is organized around that: on both
of its turns the model wrote the continuity checkpoint before it said anything and nothing refused
it. That is §55's remaining defect, it is not this slice's change, and it is raised rather than
taken (below).

---

## The numbers

Send → his first words, off `LiveEvent::MessageStarted`/`MessageDelta` — the events the webview
renders his text from, so this is when the sentence appears rather than when the turn ends.

| | before this slice (`first-reply-2026-09-18.md`) | **run A** | run B |
|---|---|---|---|
| a task turn, the lease's first VISIBLE turn | 13.464 / 13.628 / **15.513 s** | **7.998 s** | 15.714 s (pre-reply checkpoint) |
| a question turn, warm | 7.128 / 8.505 / **8.920 s** | **6.358 s** | 12.176 s (pre-reply checkpoint) |
| the priming turn, and where it is spent | inside his first message | **2.768 s, before he typed** | 2.802 s, before he typed |
| his first words vs the register's answer | **1.094 s later** (warm), 1.427 s (cold) | **the same instant**: 6.358/6.358 | the same instant: 12.176/12.177 |
| runs of prose he can see | 1 | 1 | 1 |
| the model's own copy of the sentence | shown to him | **withheld, and said on stderr** | withheld |
| model turns the run actually spent | 3, recorded as 2 | **3, recorded as 3** | 3 |

And the one figure from the real window rather than from a probe, for the same defect: **row 2 of
Ray's on-screen audit of nightly 1.2.0-nightly.20260918.3 measured "On it!" at ≈13 s on screen**,
after the back end had already searched and worked. That audit landed on `main` at `6a5b6496`, after
this branch was cut, so it is named here rather than linked: it is not a file in this tree. The
build it walked predates `register1`, so it is two slices behind this one, and nothing in this slice
has been walked on screen (see "What this record does NOT claim").

Run A's accounting, in the same form the two previous records used:

```
front desk made ready before he types : 2.768 s  (Ready { millis: 2767, spawned: false })

he said    : Land the pricing branch and get the staging deploy done.
Rich said  : "On it!"
send -> first words : 7.998 s      send -> turn ended : 9.266 s
      5.836 s  mcp__richos_assignments__record        <- the FIRST tool call
      6.086 s  {"assignment":"Land the pricing branch and get the staging deploy done.","kind":"tas…
      7.998 s  HIS FIRST WORDS
      7.998 s  tool_call closed: {"recorded":true,"say":"On it!","say_nothing_else":true}
runs of prose he can see : 1
[withheld] the model's own "On it!" after the receipt, 6 chars, the same sentence again

he said    : Why has the nightly build been failing since Tuesday? …
Rich said  : "I'll investigate."
send -> first words : 6.358 s      send -> turn ended : 7.567 s
      3.968 s  mcp__richos_assignments__record        <- the FIRST tool call
      4.321 s  {"assignment":"Why has the nightly build been failing since Tuesday, and what is act…
      6.358 s  HIS FIRST WORDS
      6.358 s  tool_call closed: {"recorded":true,"say":"I'll investigate.","say_nothing_else":true}
runs of prose he can see : 1
[withheld] the model's own "I'll investigate." after the receipt, 17 chars, the same sentence again
```

**HIS FIRST WORDS sit between the register's arguments and the record of the register's answer.**
That ordering is the whole evidence that the app said them: both are built from the same frame, and
the text is routed first. A model saying them puts them after that record, a round trip later.

---

## What was changed, and why each is structural rather than a sentence

### 1. The app says the sentence, off the register's own answer

`native.rs`'s reader watches for the register's `tool_use` id — taken from whichever frame arrives
first, the streamed block start or the complete `assistant` message — and when that call's
`tool_result` goes past it reads the sentence with `first_reply::receipt_sentence` and routes it as
TEXT.

**Routing it as text is why there is no UI change at all.** The timeline bubble, the status read and
the speaker are all downstream of `TurnItem::Text` — `ui/main.js:3838` relays exactly this to
`voice_speak_delta` — and it is the ledger's own record of what he was told, at its shared-sequence
position, so a crash-recovered conversation shows the same words. The webview was not touched.

**The app speaks only on the register's own `recorded: true`.** A refused registration
("This conversation is not open for new assignments right now"), a non-JSON answer, a missing or
empty `say` — each yields nothing, the app says nothing, and the model says its copy a round trip
later exactly as it did this morning. The reader reads the register's ANSWER and never the tool
NAME, because a host that spoke because the call was *made* would tell him "On it!" for work that
was not written down.

**The model's own copy is withheld, and said out loud on stderr rather than dropped.** Both turns of
both runs withheld it and both times it was *the same sentence again* — the defect run 1 of the
previous slice found as `"On it!On it!"`, now impossible for him to see.

**The doctrine is deliberately UNCHANGED**, and that is what makes the degradation real: it still
tells the front desk to say the words. Telling it to stay silent would be one flag away from a
silent Rich — a build whose `tool_result` shape this reader no longer recognizes would leave a model
instructed to say nothing and a host that cannot say anything.

**The clarifying-questions path needs nothing.** §55's second reply is "Got it. On it!" and it is
the same mechanism: `after_questions` is already the register's argument and
`Receipt::sentence_after_questions()` is already what it hands back, on the turn AFTER he has
answered. The questions themselves are the model's own prose on an earlier turn with no register on
it, and nothing here touches that.

### 2. The priming turn happens before he types — and it is a MODEL TURN, not a process start

**The correction to the premise, and it decides what could be done about it.** The previous record
and the brief both describe the ~8 s a first turn carried as the lease "waking up" / a "cold
start", with the open question *"if it costs a model turn on his subscription per launch, say so and
make it a process start only."* It cannot be a process start only:

```
spine.rs  prepare_request -> prime_lease_if_needed -> Cognition::reprime
native.rs reprime -> client.prompt_context_only(...)        == A REAL MODEL TURN
```

and `prepare_request` is called from `submit_prompt_inner`, i.e. inside his send. The child PROCESS
is already started before his first message in both paths — the app spawns it from the lease factory
in `prepare_request`, and this probe spawns it with `attach_lease` before its first prompt, yet
still measured 15.513 s on turn 1 against 7.128 s on turn 2. **So the seconds are the continuity
priming turn, and his first message has been paying for it.**

`Spine::prime_front_desk(thread)` spends it earlier: spawn if there is none, then prime, then
nothing. `get_timeline` — the read that opens a thread — hands over its snapshot and kicks it on a
thread of its own, one attempt per thread opened.

**What it spends, stated plainly because it is his subscription: at most one model turn per lease,
and it is the same turn his first message spends today.** The one case where it spends something
that would not have been spent is a launch where he never says anything — one priming turn on a desk
that answered nothing. There is no version of this that is free, because the turn IS the re-prime
payload, which is continuity §2 itself.

**And it is smaller than the previous record implied.** Priming measured **2.768 s and 2.802 s**,
not ~8 s. So part of the 8.4 s gap those three runs showed was provider variance on the day rather
than a fixed cold cost — stated here rather than left as a number this record would otherwise be
seen to confirm. The first visible turn is still slower than a warm one on the same primed desk
(7.998 s against 6.358 s, 90 seconds apart), which is why the two budgets remain two.

**It is never run underneath a turn** (`FrontDeskReady::TurnInProgress`, continuity §3.1), never for
a thread that does not exist, and never creates one. The spine's lock is held for the whole of it,
which is deliberate and never worse than today: `send_message` holds the same lock for the whole of
a turn (`main.rs:707`), and a message he sends during priming waits for exactly the priming his own
message used to perform.

---

## FINDING 1 — the pre-reply checkpoint is not refused on the real wire, and it is what is left of §55

`esc-20260918T141320Z-49570979`.

Run B, both turns: `mcp__richos_continuity__checkpoint` at **8.932 s** and **5.429 s**, before he
had heard anything, the ECS write succeeding, and his first words at 15.714 s and 12.176 s against
7.998 s and 6.358 s on identical code. **It is 3.0 s and 2.4 s of his wait, and it is now the
largest single term in it.**

`native::bookkeeping_before_the_reply` landed this morning as *"the enforcement the doctrine
sentence could not be"*. It is reachable only from a `can_use_tool` control request, and **no
permission frame appears anywhere in run B** — the probe traces every one it is handed, which is why
the absence is evidence and not an assumption. The lease runs with `--permission-mode auto` and the
`autoMode` settings block (`engine_profile.rs:214-222`), under which the binary classifies and
auto-approves its own trusted MCP tools and never asks the app's desk about them.

The function stays and its tests stay: it is correct, it is cheap, and a permission mode that does
ask the desk gets the ordering it describes. What it must not be is quoted as the reason the
pre-reply checkpoint cannot happen. The reason is now written at the function, with this log's path.

## FINDING 2 — and the obvious fix would break the hand-over, which is why it was not taken

`esc-20260918T141601Z-d0505a05`, decided by the lead: the register will open the obligation itself,
in a slice that owns the register's logic, and only then is deferring the grant safe. Neither half
is in this branch.

Deferring the continuity grant until he has been spoken to is app-only and needs no engine release —
the engine's adapter re-reads the scope file on every call and gates both continuity tools on the
app-written `actions_allowed` (`engine/ecs/adapters/mcp.py:18-26`). But:

- the register's `obligation_id` must name an ECS item whose status is `accepted`/`active`/`pending`/
  `blocked` by the time the work lease runs `prepare`, or the engine refuses the dispatch
  (`mega-lander/app.py:318-321`);
- the register takes that id as a MODEL argument and never verifies it;
- and the only tool the front desk has that can create the item is the checkpoint that would be
  deferred (its opening verbs are `priority`/`initiative`/`open_loop`/`commitment`/`decision`/
  `deadline`/`blocker`, `engine/ecs/core/ecs_core.py:57`).

So run B's pre-reply checkpoint WAS the model opening the obligation it then handed the register:
`{"statements":[{"fields":{"id":"land-pricing-branch-staging-deploy", …`.

**And the other half is worse than the three seconds. Run A called the register first with no ECS
write anywhere on the turn — its full trace ends at the register's answer — so both of run A's
assignments carry an obligation that was never opened, and `prepare` would refuse them.** Today a
model that obeys §55 produces undispatchable work, and a model that obeys the obligation contract
costs him 3 s. That is the thing to fix next, and it is not a latency fix.

---

## Where the remaining seconds are, measured off run A's own frames

| term | warm (question) | the lease's first visible turn (task) |
|---|---|---|
| his prompt → the model's register call appears | 3.968 s | 5.836 s |
| that call → the arguments complete | 0.353 s | 0.250 s |
| the arguments → the register's answer **and his first words** | 2.037 s | 1.912 s |
| **total** | **6.358 s** | **7.998 s** |

**The last row is the next lever, and it is not the model's.** The register itself answers in ~1 ms
(`examples/assignment_receipt_timing.rs`), and the model has finished streaming by the start of that
row — yet ~2 s passes between the complete arguments and the answer, on both turns of both runs. It
is not the app's permission desk: no permission frame arrives at all (finding 1). It is inside the
child, between the tool call being complete and the MCP server being called, and it is now a third
of his wait. Unmeasured beyond that, named rather than guessed at, and it needs no model turn to
investigate.

**One model round trip is the floor for the reply itself.** Only the model knows whether what he
said is a task, a check, an investigation or a question it can answer, and that classification IS
the register's arguments. So "his prompt → the arguments" cannot be removed by this app; the second
round trip, which repeated the app's own sentence back to it, is what was removed.

---

## The budgets, and how they were taken

`first_reply::FIRST_WORDS_BUDGET` = **9 s** (was 12 s), from run A's clean warm turn, 6.358 s plus
~42%. `first_reply::FIRST_TURN_BUDGET` = **11 s** (was 20 s), from run A's first visible turn,
7.998 s plus ~38%. Wider headroom than the previous 35% and 29%, deliberately, because each rests
on ONE clean turn rather than three.

**Run B's two turns are excluded, and both constants say so.** The probe already fails those turns
by name on the pre-reply checkpoint, so a budget that absorbed them would be a budget that forgave
the defect this record is about.

`first_reply::RECEIPT_TO_FIRST_WORDS` = **0.25 s** — the gap allowed between the register's answer
and his first words. Measured zero when the app speaks (7.998/7.998, 6.358/6.358) and 1.094 s when
the model does, so the tolerance is an order of magnitude above the first and four times below the
second.

## Proven able to fail

* **The old shape, on the timing:** every unprimed first turn ever measured — 13.464, 13.628, 15.513
  and run B's own 15.714 s — is over the re-derived 11 s
  (`the_shape_where_his_first_message_pays_for_the_priming_turn_is_red`), so
  `RICHOS_PROBE_UNPRIMED=1` fails by design and by measurement rather than by argument.
* **The old shape, on the structure:** `first_words_not_from_the_app` fed run 3's own pairs
  (6.034 → 7.128 and 14.086 → 15.513) goes red, and the same test states the pair honestly: the
  three warm turns of the previous state are asserted, in that same test, to pass the timing budget —
  because what was removed from a
  warm turn is 1.094 s and a budget tight enough to catch that would flap on provider variance.
* **The app's own sentence:** with the injection short-circuited (`if false &&` on the `user`-frame
  arm) two wire tests go red, and the two degradation tests stay GREEN, which is what they are for.
  With the withholding short-circuited, three go red.
* **The priming:** with `prime_front_desk` short-circuited to `AlreadyReady`, 3 of its 5 tests go
  red (`front_desk_priming_tests.rs:65`, `:93`, `:115`); the refusal and turn-in-flight arms stay
  green.
* All restored; `cargo test -q -p richos-core`: **1296 passed, 0 failed, 1 ignored** (1282 was the
  figure `app/README.md` recorded after the register-first land; that figure is theirs and was not
  re-measured here).

## What this record does NOT claim

* **The app was never put on screen.** No window, no `richos-tauri` process, no GUI walk — the probe
  is headless, nothing was launched, and there is no pid to report gone (CEO §54 addendum 4). So
  this record says nothing about what the timer beside his reply reads, or about the voice path: the
  sentence reaches both by the same `TurnItem::Text` the bubble uses, which is an argument from the
  wiring and not a measurement of the screen. An on-screen walk is a QA leg, and the on-screen
  before-figure quoted above belongs to a build two slices back.
* **Nothing here was tested with audio.** No `say`, no playback, no microphone (CEO §53).
* **Two runs, not three.** My brief for this slice set the ceiling — "Model turns on his subscription:
at most six" — and two runs of this probe and two runs of this probe are
  exactly six. Run B is the second, so the clean shape has ONE measurement per arm and the budgets
  say so. No run C was taken; the lead ruled that explicitly after finding 2.
* **The work lease is untouched.** `prime_front_desk` is the conversation's; nothing here changes
  how a background lease starts or when.
* **`HOME` was not replaced.** The provider credentials live there. What is throwaway is the whole
  app state root under the system temp directory, removed on the way out (CEO §54).
* **The obligation gap is stated, not measured end to end.** That run A's assignments would be
  refused at `prepare` is read off `mega-lander/app.py:318-321` and the absence of any ECS write in
  run A's trace; no dispatch was attempted, because the probe never runs the work lease.

## Reproducing it

```
cd richos/app
cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime
```

Three model turns — the priming turn, a task, a question. `RICHOS_PROBE_UNPRIMED=1` reproduces the
shape where his first message pays for the priming turn, and fails. A temp directory it removes, no
audio device, no window.
