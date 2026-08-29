# Frank — Stress-test of the two front-end bets, and of what shipped on 2026-08-29

**Author:** Frank (Expert Advisor / Devil's Advocate). **Date:** 2026-08-29.
**Base:** richos `main` @ `e37d140`. Branch `frank/frontend-stress-2026-08-29`.
**Closes (partially):** `richos-hq` `wiki/open-items.md` 3.6.

**Read in full:** `app/crates/richos-core/src/{spine,steering,acp,ledger,timeline,machinery,journal,live,reprime,worker_events,worker_status,config,stream}.rs`;
`app/src-tauri/src/{main,timeline_view,nav}.rs`; `app/ui/{main,timeline}.js`; `app/STREAMING.md`;
`app/crates/richos-core/tests/{steering,live_event,timeline}_tests.rs`; `app/ui/tests/`;
`docs/verification/acp-emission-probe-2026-08-28/` (all five raw runs);
`richos-hq` `wiki/{richos-frontend,open-items}.md`, `richos-hq/docs/plans/richos-techy-mode-2026-08-26.md` §6–7,
`richos-hq/docs/briefs/frank-frontend-stress-test-2026-08-24.md`. `git log` on `main` was the source, not any summary.

**This is late, and the framing of 3.6 is now wrong.** It says "before further front-end engineering."
Ten slices landed first, so this is an audit, not a prevention. What that cost is nameable and I state it
in §5 — it is smaller than usual, because the engineering was itself adversarial, but it is not zero and
it is concentrated in one place: three of my four top findings are limits an engineer **correctly wrote
down inside his own slice and then shipped past**, because nobody was in the seat whose job is to say
"that limit is load-bearing — stop."

I did not manufacture objections. Where something holds I say so in a line and move on (§4, §5).

---

## 0. Lead — the most dangerous thing I found

**RichOS decides whose AI workers it is looking at by picking the most recently modified directory under
`~/.claude/teams/`, and then injects that answer into Rich's own re-prime payload under a header that
calls it authoritative ground truth.**

- `worker_status::resolve_team_dir()` (`worker_status.rs:229`) returns
  `max_by_key(mtime)` over `~/.claude/teams/session-*`.
- The shipping app wires that as the worker source for both surfaces:
  `main.rs:315` `spine.set_worker_events(WorkerEventsSource::CurrentTeamDir)`, and
  `main.rs:473` `get_worker_status()` → `current_status()`.
- **And `reprime.rs:178` calls `worker_status::current_status()` directly** — so the result becomes
  Tier B #7, "live worker state", inside the payload injected into every fresh Claude session on every
  rotation and every crash recovery.

**This is not hypothetical. It fires on this machine right now.** `~/.claude/teams/` currently holds four
`session-*` directories; the most recently modified is `session-9e3192d3`, which belongs to the
development session that produced this brief. If RichOS were running on this Mac at this moment, its
"3 working" chip would be counting *my* teammates, and Rich would be told, in his priming prompt, that
they are his.

Every honesty guarantee downstream is intact and none of them can see this. The host-pid signal-0 probe,
the `created`/`run_ended` arithmetic, the refusal to infer from mtimes or idle logs, the `SessionScope`
row filter — all correct, and all applied *after* a directory chosen by an mtime. `SessionScope` scopes
rows to the name of the directory it was given, which is circular: it cannot detect that the whole
directory belongs to someone else. `worker_status.rs:221-227` defends the mtime read against the Phase-4
gate ("directory SELECTION, not state inference"). That defence is correct about the gate's wording and
beside the point: the *attribution* — these workers are Rich's — is the inference, and it is made from a
file timestamp.

**Severity: high, and it is a false-attribution channel into the model context**, which is the exact class
the whole continuity design (`reprime.rs`'s identity assertion, §6) exists to structurally exclude. A
mislabelled duration row is a wrong pixel. This one propagates: Rich can tell the CEO that work is in
progress that is not his and never was.

**Likelihood by population.** Certain on the founder's dogfood machine (a dev session is always running
and always newer). Certain for any customer who also runs Claude Code — which per
`richos-market-fit.md` is the stated ICP ("AI-enabled founder-CEOs"), i.e. most of them. Low on a machine
that runs nothing but RichOS, where the mtime pick lands on Rich's own dir; there the residual is a stale
previous-session dir plus PID recycling, which the tri-state probe mostly absorbs.

**Fix, and it is cheap and already half-written.** The correct key is known at the call site: the ACP
session id (`Cognition::session_id()`), whose team dir is `session-<first8>`. `resolve_team_dir` already
takes an override (`RICHOS_TEAM_DIR`). Derive the dir from the live lease's session id; fall back to
mtime only when no lease exists, and mark that result `unknown` rather than counting it.

**And the id spaces DO match — I proved it for free, from artifacts already on this disk.** The probe's
ACP session id `55c79b81-ace3-4b07-a5f3-406853ac1a36`
(`docs/verification/acp-emission-probe-2026-08-28/run1.raw.jsonl`) has a Claude Code transcript at
`~/.claude/projects/-Users-alex-ab-richos-engine/55c79b81-ace3-4b07-a5f3-406853ac1a36.jsonl`. That
settles the open question named in `timeline.rs:770-773` — *"the ACP session id and the harness session
id are DIFFERENT ID SPACES, in which case the join can never fire in production and §7's whole worker
treatment is dead on the wire while every test stays green."* They are the **same** id space. So
`WorkerActivity` is not dead code, and the derived-team-dir fix will make it fire. **No live adapter run
was needed and none should be commissioned for this question.**

---

## 1. The four questions, answered

### 1.1 Does the machinery stream reopen R2? — **Not the way it was expected to, and yes by one specific accident.**

First, correct a premise: **the machinery renderer did not ship.** `get_timeline` can produce only
`ViewMode::Ceo` (`timeline_view.rs:27-29`), there is no `get_machinery` command, no per-thread toggle and
no `techy_default` (`config.rs` has neither). What shipped is routing, retention, and a *typed timeline
with a visibility gate*. So the "rendered machinery stream" in 3.6's wording does not yet exist, and the
R2 pressure I was asked to look for is smaller than the question assumes.

The read-only inspector is clean. `945800d` bounds it to two interactive elements and machine-checks the
control labels against `retry|interrupt|approve|resume|stop|model|permission|prompt`. That is the right
boundary drawn the right way — as a **type-level** constraint, not a convention. No objection.

**The back door that did open is a string.** `MachineryKind::PermissionRequested` maps to
`ActivityType::Approval` (`timeline.rs:1382`), whose CEO-facing semantic line is
**`"Requested approval"`** (`timeline.rs:1426`), and whose visibility falls through to
`Visibility::Ceo` (`timeline.rs:1318`) — it is not `internal`, not a `Thought`, not `Unknown`. The
renderer rolls it up as **`"Requested approval 7 times"`** (`app/ui/timeline.js:280`). The emission probe
measured **7 `session/request_permission` calls across five short runs**, so this is frequent, not an
edge case.

Nobody approved anything. `acp.rs:184-205` auto-approves every permission request — gap #1, deferred by
CEO decision. The product now puts **governance vocabulary, in the calm default view, describing a
decision that was never taken**, and marks it `state: completed`, which a reasonable CEO reads as
*granted*. That is R2 by the back door: not an approval queue anyone built, but the demand for one,
manufactured by a summary string. The first CEO who asks "approval from whom?" has opened the deferral.

This is worse than a naming quibble because it is the one place where the shipped surface *asserts* a
governance act. Everything else in the family was refused with discipline — `rich://approval-requested`
and `-resolved` are deliberately not emitted, and `TimelineItem::Approval` is modelled with no
constructor (`timeline.rs:629-636`). The refusals held; the noun leaked past them.

**Fix (one of three, in order of preference).**

1. Make `PermissionRequested` `Visibility::Technical`. It is machinery by every other test in this file,
   it has no semantic CEO meaning, and it belongs with the auto-approve it records.
2. If it must stay CEO-facing, say what happened: *"Approved a tool automatically"* — a fact, not a
   request, and one that does not imply a decision-maker.
3. What must not happen: keep the word "approval" on the calm surface while there is no approval
   capability. That is the shape the CEO deferred.

**The line, stated so it can be held.** Machinery is CEO-facing when it is a *semantic statement of work
done* ("Ran a command", "Read 8 files"). It becomes governance the moment it names a **decision, an
authorisation, or an actor**. "Requested approval" does all three. "A window, not a cockpit" (§5) is
defensible under real use — but only if the window's captions stop narrating decisions.

### 1.2 Is stop really session control? — **Yes, the classification is right. Two of its claims are not.**

Rich's judgement holds and I tried hard to break it. Stop cancels a compute lease
(`AcpCancelHandle::cancel`, `acp.rs:481`), records a terminal state, and stops the *queued* turns behind
it (`settle_stop_claim`, `spine.rs:1114`). It **authorises nothing and creates no external effect**. R2
governance is about gating actions with real-world consequence; stop only *withholds*, which is the safe
direction, and a withhold-only control is not a business action. Classification: **correct, keep it.**

What stop does **not** stop, and this should be written down before anyone says otherwise: side effects
already executed. If Rich's last tool call sent the email, pushed the commit or merged the PR, stop
cancels the *turn* and unwinds nothing. That is inherent, not a defect — but it is exactly the gap a CEO
will assume a stop button closes. The two claims below make that assumption easier to form.

**Claim 1 — `"nothing new will start"` (`app/ui/main.js:1174`), on the `reachedLease === false` path.**
The full sentence: *"I've noted that you stopped this. I couldn't interrupt the work already in flight,
so it may finish on its own — nothing new will start."* It is **true at turn grain** (`settle_stop_claim`
stops the queue) and **false at action grain**: the un-cancelled turn is still running and Rich will keep
starting new tool calls in it — arbitrarily many, for as long as it lasts. The sentence is delivered at
the exact moment a CEO is trying to stop something, and it is ambiguous in the most dangerous direction.
**Fix:** *"…so it may run to the end of what it's already doing. I won't start a new turn."* Name the
unit.

**Claim 2 — `"You stopped after {duration}"` can be rendered for a turn that ran to completion.** This is
the sharper one and it is a live defect.

`deliver()` takes the stop branch **before it looks at what the lease reported**:

```rust
// spine.rs:976
if let Some(claim) = stop_claim {
    self.finish_stopped_turn(turn_id, binding, &claim, stop.as_deref().ok())?;
    return Ok(());
}
match stop {
    Ok(stop_reason) => { self.ledger.complete_turn(turn_id, &stop_reason)?; ... }
```

So `complete_turn` is never reached, and the ledger's own guard for this case —
*"A stop OVERRIDES nothing that already ended: a turn that completed before the stop request reached the
lease stays completed, because it did"* (`ledger.rs:635-643`) — **is unreachable on the live path**,
because the turn is still `InFlight` when `stop_turn` is called. `Ledger::stop_turn` then writes
`TurnState::Stopped` with `ended_at` anchored to the request timestamp, and `app/ui/timeline.js:225`
renders **`You stopped after {d}`** — §6.1's attribution row, the *only* place in that file that names
the CEO as the cause of anything — above a complete, successful answer.

The race: the CEO presses stop while the adapter's `Done` is already in the channel. `cancel()` clones
the sink and appends `ChunkMsg::Cancel` *after* it; `rx.recv()` returns `Done` first and `prompt` returns
`"end_turn"` (`acp.rs:443-450`). `AcpCancelHandle`'s doc comment shows the ordering was thought about —
*"The reverse order would let a very fast adapter's `Done` overtake the wake"* — but the guard addresses
`Done` **racing** the wake, not `Done` **already queued** before the wake exists.

**The distinguishing signal exists, is passed into the function, and is thrown away.**
`finish_stopped_turn` receives `lease_stop_reason` (`spine.rs:1075`) and uses it for exactly one thing:
deciding whether to rotate on `cancel_unacknowledged`. `STOP_REASON_CANCELLED` — the adapter's
acknowledgement that it actually honoured the cancel (`acp.rs:32`) — **has no production reader at all**;
`grep` finds it only in `acp_cancel_tests.rs` and `cognition.rs`.

**And there is a test that reads as if this were handled, and is not.**
`steering_tests.rs:103`, `a_stop_arriving_after_the_turn_already_completed_does_not_rewrite_history`,
opens with *"The race §9.3 has to survive: the CEO presses stop at the exact moment Rich finishes.
Whoever wins, the log must say what actually happened — and what happened is that the turn completed."*
It calls `ledger.complete_turn()` then `ledger.stop_turn()` **directly**. It proves the ledger primitive
and nothing about the spine, which never calls those two in that order. Every spine-level stop test
(`steering_tests.rs:228, 268, 315`) uses a 60-chunk turn where the stop genuinely lands. **There is no
test for "stop requested, lease returned `end_turn`."**

**Fix (small).** In `finish_stopped_turn`, when `lease_stop_reason` is neither `STOP_REASON_CANCELLED`
nor `STOP_REASON_CANCEL_UNACKNOWLEDGED` — i.e. the lease reported a natural terminal — call
`complete_turn` and let the ledger guard do its job, recording the stop request as a fact that did not
land. The label then reads `Worked for {d}`, which is what happened. Add the missing spine test.

**Why this matters more than its narrow window.** Stop is the first genuine control in the product and
the only thing in the UI that attributes an outcome to the CEO. A control that can claim it stopped work
which in fact completed is a governance claim with nothing behind it — and it fails in the direction
where the CEO believes he prevented something he did not.

### 1.3 Do the two bets still hold? — **Bet 1: yes, with R1 still open and now measurably mis-set. Bet 2: untested, because it is unbuilt.**

Full verdicts in §3.

### 1.4 Where is the product claiming something it cannot know?

Ranked in §2, with the two already covered above omitted. The pattern the CEO named — a rule with nothing
enforcing it — recurs; so does a second pattern he did not name: **a constant that the wire has since
contradicted.**

---

## 2. Findings, ranked

**F1 — Worker attribution by mtime, injected into the re-prime.** §0. High / High.

**F2 — The rotation watermark is anchored to a number the wire measures and contradicts, and fed by a
numerator that ignores the majority of context.** `spine.rs:114`:
`const DEFAULT_CONTEXT_WINDOW_TOKENS: usize = 200_000;` with `DEFAULT_WATERMARK_RATIO = 0.70`, so the
app rotates at an estimated 140k tokens. **All five probe runs on this machine measured
`"size": 1000000`** (`docs/verification/acp-emission-probe-2026-08-28/*.raw.jsonl`) — the adapter's own
statement of the context window. The app is set to rotate at **14 % of real capacity**, and every
rotation costs a handoff-summary turn plus a re-prime payload, billed to the CEO under BYO-Anthropic.

The numerator errs the other way and by an unbounded amount: `spine.rs:967` is
`self.context_chars += text.len() + reply_len;` — **prompt characters and assistant reply characters
only.** Every tool input and every tool output is uncounted. For an orchestrator Rich, that is the large
majority of context. A turn that reads forty files adds roughly nothing to the estimate.

So the watermark is an undercounting numerator over a 5×-wrong denominator: two unbounded errors in
opposite directions that do not cancel in any predictable way. **The exact signal that settles both is
`usage_update`'s `{used, size}` pair — measured 50 times across five runs, routed to the machinery
journal, and read by nothing.** The design promised this: *"Routing this replaces an estimate with a
measurement"* (`richos-techy-mode-2026-08-26.md` §1.2). It did not happen. Worse, the code still carries
the superseded claim — `spine.rs:104-105`: *"`AcpClient::prompt` currently discards the wire `usage`
field entirely."* It no longer does.

Consequence: R1 — the deepest risk in Bet 1, and the one I named as make-or-break in August — is not
mitigated. The realistic failure is not an early rotation; it is the lease hitting a hard context limit
**mid-turn**, which is the one place the design says rotation must never happen. **Medium-high / high.**
**Fix:** consume `usage_update` live for the watermark (`used / size`), keep the char estimate only as
the fallback for a lease that has not reported yet, and delete the stale comment. Note that `usage_update`
lands in the *evictable* Tier B (`machinery.rs:230`, `journal.rs:129`), so read it from the stream, not
from the journal.

**F3 — The calm view's one structural guarantee has no test.** `app/STREAMING.md` and
`main.rs:50-57` both state the invariant: *"The default conversation view does NOT subscribe to
`rich://machinery`, and must not."* The techy-mode design calls this *provable, not promised* (§3.3
test (a): "the default UI's subscription list is the proof"). **There is no such test.** `grep -rn
"machinery" app/ui/tests/` returns one unrelated hit. The invariant is one line of CI away
(`grep -c 'rich://machinery' app/ui/main.js` must be `0`) and is currently held by a comment.
**Low likelihood / high severity** — this is the guarantee the whole clean-output claim rests on.

**F4 — RichOS pays 100 % of techy mode's privacy cost and delivers 0 % of its value, today.** Retention
is unconditional and wired at boot (`main.rs:284-294`); the renderer, the toggle and `get_machinery` are
all unbuilt. So every raw ACP payload — every command line, every `Write` body, every env value or
credential that passes through a tool argument — is persisted **unredacted** for 14 days / 2 GB
(`journal.rs:78-81`) in the app data dir, and **no code path in the shipping app can display any of it.**
That is the worst point on the curve. It is a deliberate, documented trade ("the accepted cost is
~1-2 MB/day of machinery an owner may never look at") — but the cost that was named is disk, and the cost
that was actually taken is a second unredacted copy of the CEO's business, on a product sold on
"everything stays local."

Two aggravations. (a) `TauriMachineryEmitter` (`main.rs:63-67`) emits the **full record including
`payload`** to the webview on every record, unconditionally, whether or not anything listens — the
structural guarantee is that a non-subscribing UI cannot *render* it, not that the bytes stay out of the
renderer process. (b) Eviction runs **only at boot** (`main.rs:290`), so an app left running for a month
evicts nothing.

**F5 — Sage's item 3 (no redaction) does not survive contact with objective number one.** He asked for
this one to be attacked hardest. The argument — *"Claude Code already writes the same bytes unredacted
next door"* — is true and **not sufficient**, for three reasons that are specific to this product:

1. **Different owner, different promise.** Those are a developer's tool's files, under a dotfile, on a
   developer's machine. RichOS ships to a CEO who is told everything stays local and who does not know a
   second copy exists.
2. **Different content class.** Rich's tools operate on the CEO's business, not on a repo. A `Bash`
   payload here can carry a contract, an email draft, a customer list.
3. **Decisive: a rendered raw pane is a live leak surface and a JSONL file is not.** *Objective number
   one*, CEO 2026-08-25, is CEOs posting **screen-recording videos** of RichOS. A raw-payload inspector
   is the one screen in this product where a secret can be filmed. Whoever builds the renderer inherits a
   redaction requirement that this design explicitly declined to have.

**Recommendation:** keep no redaction at *rest* (the argument is sound there), and make redaction a
**precondition of the renderer**, not a follow-up. Also decide 7.4 before the renderer, not after — and
note that `journal.delete_thread()` (`journal.rs:198`) currently has **no caller**, because thread
deletion does not exist in the app at all (only `set_thread_archived`).

**F6 — `"N working"` is a worker-grain claim reconciled by a host-grain signal.** `host_pid` is
`CLAUDE_PID` (`engine/scripts/hooks/worker-*-handoff.sh`) — the **host CLI's** pid, shared by every
worker in the session. `worker_events.rs:74-80` is honest about this ("If the host CLI died mid-run, its
workers died with it"). The gap: a worker that dies while the host lives — SIGKILL, a hook that did not
fire, an abnormal exit — leaves an open run that is counted **`active` forever**, because nothing ages an
open run out and the module (correctly) refuses timeouts. The chip renders that as `"3 working"`
(`app/ui/main.js:1465`) — present tense, work happening now. **Medium / medium.** The refusal to guess is
right; the CEO-facing verb is where the claim exceeds the signal. Cheapest honest fix: an open run whose
last event predates the current lease's start is `unknown`, not `active` — that is a statement about
*the record*, not a timeout on the worker.

**F7 — Sage's item 6 (latency) is still unmeasured, and the hot path is heavier than the design assumed.**
Per machinery record, on the streaming loop that also persists the CEO's assistant deltas:
`cap_payload` (`machinery.rs:444-453`) serialises the whole payload **just to measure its length**, then
deep-clones it; `journal.append` (`journal.rs:116-140`) does a `create_dir_all`, clones the record again,
and serialises **twice** more into two separately-opened files. That is three serialisations, two deep
clones and up to three syscalls per record, ~4,600 records/day measured. The no-fsync call (§2.2) is
**right** and I am not attacking it. The open-per-append and the measure-by-serialise are not defended
anywhere and were never measured, which is precisely what Sage asked for. **Low / medium.**

**F8 — Three code comments still assert facts this session falsified, and six cite a purged SHA.**
The same superseded claim — "no active/decision-required signal exists" — survives in `reprime.rs:171-176`
and `main.rs:470-472` after slice 2b made `active` real. `spine.rs:104-105` still says the wire `usage`
field is discarded. And `d14bc54` is cited as a live commit in five source files and one UI file
(`worker_status.rs:10,98`; `timeline.rs:93,1883`; `worker_events.rs:3`; `app/ui/main.js:1417`) — it does
not resolve in this repository. Housekeeping, but under a doctrine where a citation is the evidence, a
dead citation is an unfalsifiable claim. **Low.**

---

## 3. The two bets

### BET 1 — ACP-client-replaces-relay: **it holds. The relay was never the risk; R1 still is, and F2 makes that measurable rather than arguable.**

Everything I flagged in August about the *client subsystem* has been built and, in two cases, built better
than I asked for:

- **Permission requests are answered** (`acp.rs:184-205`), so Rich does not hang. Built.
- **Clean output was rebuilt on the direct-ACP topology, and made structural rather than behavioural.**
  Machinery is not a `StreamEvent` at all; `Timeline` deliberately does not implement `Serialize` and
  carries a compile-fail doctest; `view(ViewMode::Ceo)` **removes** technical bytes rather than masking
  them, so `get_timeline` never holds them. This is a stronger answer than the one I asked for — I asked
  for the test to be re-run, and instead the class was made unrepresentable. Credit where due. The one
  hole is F3: the JS half of the same invariant is enforced by a comment.
- **Queue-not-interrupt keys on turn-in-progress, not workers-live** (`spine.rs`, `Queued`), which is
  the subtlety I said the plan missed. Fixed.
- **The deliberate steering gesture is specified and does not use `session/cancel`** (`steering.rs`
  module doc). The UI says in words that the message lands at the boundary rather than mid-thought
  (`app/ui/main.js:1114-1125`). This is the honest version and I have no objection to it.
- **Mid-turn crash recovery exists** (`recover_and_replay`, `spine.rs:1291`) with `supersedesTurnId` as a
  merge instruction. Sound.

**What is still open, and it is the same thing it was in August.** The re-prime's "ground truth for what
Rich has done" is, in production, **exactly one action kind**: `proactive_message`. `record_action_with`
has five production call sites (`spine.rs:546, 1305, 1372, 1424, 1537`) and four of them are `Internal`
(rotation, re-prime, crash recovery) and are deliberately excluded from the digest (`reprime.rs:144-150`).
So `ledger.rs:274`'s promise — *"Recorded AS the action happens … so replay can't double-execute"* —
protects proactive messages and **nothing else**. `recover_and_replay` re-sends the CEO's original prompt
verbatim to a fresh lease that has no record of what the crashed one already did. The machinery journal
**does** hold that record, durably, and neither the re-prime nor the replay reads it.

I am not filing that as a v1 defect — automatic re-execution of business actions is R2, deferred, and the
carve-out was correctness of the ledger, not coverage of it. I am filing it as the honest statement of
where the bet stands: **the ACP client is sound; the thing that makes a successor Rich trustworthy is
one action kind wide.** Whoever un-defers R2 should start here, and the machinery journal is the source
they will want.

**Verdict: the bet holds. Fix F2 and it holds with a rotation trigger that is anchored to something.**

### BET 2 — Proactive-via-synthetic-prompt: **unbuilt, therefore untested. Nothing this session moved it, and it must not be marked validated.**

`raise_proactive_message` (`main.rs:481`) says so plainly: *"Judgment of WHEN to raise one is explicitly
NOT here — no timer/log-watcher trigger is wired yet."* There is no synthetic prompt, no attention seam
trigger, no rate shaping. The app writes the text it is handed. Every production caller is a test or the
mock.

So my August findings stand **verbatim and unretired**: (A) token cost of silent deliberation, unaddressed
because the deliberation does not exist yet; (C) judgment on thin post-rotation context, unaddressed; and
the loro-reconciliation trigger is still vapour (`open-items` 3.5: loro's writer is not wired to Rich).

**One thing did improve, and one thing got worse.** Improved: failure mode (B), the synthetic-prompt vs
queue-not-interrupt contradiction, is now answered in code — `pending_proactive_emits` (`spine.rs:553-560`)
defers the emit past a running turn, so a proactive message can neither interrupt nor be lost. Got worse:
F2, since (C) lands in whatever context a rotation just built and the rotation trigger is now known to be
mis-set. My recommended mitigation for (A) was to make the interrupt/digest/silent tier a **deterministic
function of a typed trigger**, and `AttentionTier` now exists as exactly that type — but with no trigger
wired to it, the type is a promise, not a mechanism. Build the triggers against the tier, not against an
LLM judgement, and (A) mostly evaporates before it can cost anything.

**Verdict: the bet is neither vindicated nor falsified. Do not let ten green slices launder it into
"validated" — none of them touched it.**

---

## 4. Sage's seven, one line each

1. **G1 across threads.** **Sound.** `seq` is assigned at the single mpsc drain point in `AcpClient::prompt`
   (`acp.rs:400-460`), which is genuinely single-threaded, and it is now durable per delta. Reordering
   *inside* the adapter is undefendable from here and does not need defending: `seq` records our arrival
   order, which is the only order we can honestly claim, and `STREAMING.md` says exactly that.
2. **Between-turn traffic.** **No second sink.** `turn_id: None` records are rejected as `NotTurnScoped`
   (`timeline.rs:759`) and reach no render path. One cosmetic residual: they are still filed under a
   thread's day-shard by `record.stamp(thread_id, None, …)`, so the journal attributes between-turn
   traffic to a thread it belongs to no turn of. Harmless while nothing renders it; name it before the
   renderer lands.
3. **No redaction.** **Overturned, on product grounds, not on security grounds.** See F5. Sound at rest;
   not sound the moment a raw pane exists on a surface built to be screen-recorded.
4. **Volume.** Measured at ~4,600 lines/day, 1.5–2.3× the estimate. A single-CEO Rich is an orchestrator
   too, so there is no reason to expect lower; an adapter upgrade that streams subagent activity makes it
   worse. **No decision changes.** The real volume bug is that eviction runs only at boot (F4).
5. **R2 by the back door.** **Yes, via one string, and not via the inspector.** §1.1.
6. **Latency.** **Still unmeasured, and heavier than assumed.** F7. The no-fsync call is right.
7. **The toggle-off invariant.** **Moot — the toggle does not exist.** The invariant that actually needs
   pinning today is the subscription list, and it has no test. F3.

---

## 5. What held — and what running this late actually cost

I am not grading this session kindly because a lot of it landed, and I am not grading it harshly to
justify the seat. Three things genuinely held, and they are the reason my list is not longer:

- **The refusals held under pressure.** `phase` is `"unknown"` and rendered as such, with the tempting
  fallback named and rejected in writing. Five §13 events are not emitted rather than emitted empty.
  `waiting_for_user` was not invented, and slice 6 explicitly declined to invent it even though it had
  every excuse. `WorkerState` refuses `completed`. `needs_you` was deleted rather than left dormant —
  *"a branch that can never fire is a claim waiting for someone to make it fire"* is the correct
  instinct and it should become doctrine.
- **Two corrections were made by running the thing, not by reasoning about it**, and both were real
  defects the reasoning had blessed: the six `"Worked"` rows per real command (`timeline.rs:1292-1313`),
  and the group-state precedence reporting `running` for a group where nothing was running
  (`app/ui/timeline.js:284-299`). That is the discipline working.
- **`WorkerSessionMismatch` (`timeline.rs:768-777`) is the single best thing in the session.** An
  engineer wrote down, inside his own slice, the exact hypothesis under which his feature would be dead
  in production while every test stayed green — and made it a reportable value rather than a log line.
  §0 closes it for him.

**Where the discipline did not hold is where nobody was looking, and it has one shape.** F1, F2 and F5
are all cases where an engineer **wrote the limit down correctly inside his slice and then shipped past
it**, because a slice's job is to land and nobody's job was to say "that limit is load-bearing."
`worker_status.rs:221-227` argues its own mtime read past the Phase-4 gate. `spine.rs:104-105` names the
estimate as an estimate and keeps a denominator the same repository's probe data contradicts. Sage's
item 3 was flagged *by its own author* as the one he most wanted attacked, and it shipped unattacked.
**That is the cost of running 3.6 after the engineering rather than before: not bad work, but three
self-documented limits that nobody was empowered to convert into a stop.**

The correct correction is not more review. It is that a slice which documents a limit affecting a
**different** slice's guarantee must raise it, not merely record it.

---

## 6. What I could not test, and what I refuse to claim

- **No live ACP turn was run.** Everything about `session/cancel` behaviour under a real adapter,
  `CANCEL_GRACE_MS = 3000` (`acp.rs:53`, explicitly unmeasured by its own author), and the F2 race window
  is read from source and from the committed probe artifacts. **The first live stop should measure the
  cancel turnaround and replace that constant with a p99, as the comment asks.**
- **I did not run the test suites.** Four agents are live in this tree; I read tests as specifications of
  intent, and where I claim a test is missing I claim only that `grep` does not find it.
- **F1's population estimate is reasoning, not telemetry.** I demonstrated the misresolution on this
  machine at this moment; I did not measure how often a customer machine has a competing session.
- **I did not assess visual or UX quality.** That is Urban's, and none of this brief is a UX verdict.
