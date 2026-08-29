# The in-app feedback channel — design

**Author:** Sage (Software Architect). **Date:** 2026-08-29.
**Base:** richos `main` @ `4c351ec`. Branch `sage/feedback-channel-2026-08-29`.
**Status:** design brief. Nothing here is built. One decision (§2.4) is already ruled on by the CEO.

**Read in full before writing this:**
`app/crates/richos-core/src/{steering,ledger,spine,journal,machinery,config,timeline}.rs`;
`app/src-tauri/{tauri.conf.json,Cargo.toml}`, `app/crates/richos-core/Cargo.toml`, `app/ui/{main,timeline}.js`;
`engine/scripts/lib/publication-boundary.{sh,py}` and `.publication-boundary`;
`docs/briefs/frank-brief-frontend-stress-2026-08-29.md`;
`richos-hq` `wiki/{open-source-strategy,ceo-decisions,executive-continuity-system}.md` and
`richos-hq/docs/case-studies/cs-001-unprepared-task-2026-08-29.md` (PRIVATE — cited by section, never quoted here).

**Publication note.** This file lives in `richos`, which gets published. CS-001 names a real third
party and quotes the CEO. Everything below refers to it by section number and describes its content
in the abstract. No sentence from it is reproduced.

**The richos history was rewritten on 2026-08-29.** Any SHA older than `c2f519a` is dead. This brief
cites files and line numbers, and one live SHA.

---

## 0. The decision that determines whether this ships safely

**Can the model write any part of what leaves the machine?**

Everything else in this design is a parameter. This one is a type, and it decides the whole thing,
because it decides what kind of guarantee is available at all:

- **If any field is model-written prose,** anonymization is a *filter* — a property of a process that
  ran. Filters have false negatives, this one's known false negative is paraphrase, and paraphrase is
  the entire attack surface when the thing doing the writing paraphrases by construction. The
  guarantee is then "someone was careful," which is the exact rule that failed five times on
  2026-08-29 and which `.publication-boundary` exists to abolish.
- **If every field is an enum member, a compile-time constant, or an integer the app computed from
  its own ledger,** anonymization is a *property of the type*. A `FailureClass` value cannot carry a
  client name — not "is unlikely to," *cannot*, because there is no encoding for one.

**Recommendation: no. The model's entire contribution to an outbound payload is a small number of
selections from closed lists shipped in the binary. The app constructs every byte.**

Stated as the testable invariant: **Rich's influence on the payload is N integer indices, and nothing
else.** He proposes a classification; `FeedbackReport` has no constructor that accepts a string he
produced; a test walks the serialized JSON and asserts every string value is a member of a
compile-time set. That is a total check, not a detector — it has no false-negative class.

**CS-001 proves this is not a theoretical preference, and it proves it with the CEO's own material.**
Its §5 (the target payload) and its second §6 control (the payload that must be blocked) are *the same
free-text field, filled in by the same model, differing only in the model's care*. Nothing structural
separates them. §6's second control contains no proper nouns, would be approved by a human reviewer
without hesitation, and still narrows the population to roughly one person. If the field exists, both
outcomes are reachable, and which one you get is a coin the model flips per report.

The corollary, and it is the load-bearing engineering claim in this brief: **§5's information content
survives the removal of the prose field almost entirely** (§2.2 does the decomposition line by line),
while §6's second control **has no representation in the vocabulary at all**. The acceptance test the
CEO set is then passed by construction rather than by inspection.

---

## 1. What is already true in the shipped code

Four facts, verified against the tree at `4c351ec`, that the design rests on. Three of them are much
better news than the brief that commissioned this assumed.

**1.1 The capture problem is already solved, and it cost nothing.** The app durably records the user's
own words at the moment he is dissatisfied, with no prompt and no new collection:

- `steering::IntakeRecord::Steer { thread_id, steering_turn_id, entity_id, text, at }`
  (`steering.rs:92-106`) — words the user typed *while Rich was working*, appended and `sync_all`'d
  **before** anything acts on them (`steering.rs:131-149`). This is literally the mid-work
  interjection CS-001 §4 is a table of.
- `IntakeRecord::Stop { turn_id, at }` (`steering.rs:108`) — a stop press. Zero words, pure behaviour,
  and per `timeline.rs:313-321` it is now *sourced evidence of a user decision* rather than an
  inference.
- Every ordinary user message is already durable in the ledger (`ledger.rs:460` `Message`,
  `ledger.rs:98` `Source`), which ECS restates as turn invariant #1, "the CEO's input is durable
  before delivery" (`richos-hq` `wiki/executive-continuity-system.md`).

**Consequence: this feature adds no data collection whatsoever.** That matters more than it sounds,
because it makes Frank's F4 failure mode structurally impossible here. F4 is techy mode paying 100 %
of a privacy cost while delivering 0 % of the value — retention wired at boot, renderer unbuilt. A
feedback channel built the way this brief describes cannot repeat that, because the retained data
already exists for other reasons and no new byte is stored. **If a future proposal asks to add new
capture ahead of the sender, that proposal is F4 wearing this feature's name, and it should be
refused.**

**1.2 There is no network client anywhere in the app.** `app/crates/richos-core/Cargo.toml` is
`serde`, `serde_json`, `uuid`, `thiserror`. `app/src-tauri/Cargo.toml` is `tauri`, `serde`,
`serde_json`, `richos-core`, `richos-voice`. `richos-voice` is `cpal` and `serde_json`. No `reqwest`,
no `hyper`, no `ureq`, no socket. **The premise is confirmed: this is the first outbound channel, and
adding it adds an HTTP client to a product whose claim is that everything stays local.**

**1.3 `"csp": null` in `app/src-tauri/tauri.conf.json:21`.** The webview has no content-security
policy, so there is no second line of defence against a network call originating in JS. Today there is
no injection sink to exploit — every `innerHTML` in `app/ui/main.js` and `app/ui/timeline.js` is a
clear-to-empty, and rendering is `textContent` (`timeline.js:1235`). But Frank's F4(a) records that
`TauriMachineryEmitter` (`src-tauri/src/main.rs:63-67`) pushes **full unredacted payloads** into the
webview on every record regardless of subscribers. So the renderer process holds the CEO's business in
memory, has no CSP, and would — the moment this feature exists — be running in an app that talks to
the internet. **Requirement: the egress lives in Rust and the webview gets a CSP with an explicit
`connect-src`. The UI must not be able to reach the network at all.**

**1.4 The failure taxonomy does not need to be invented.** CS-001 §4's right-hand column is a
five-member closed vocabulary derived from five real, verbatim irritations in one session: work
wrongly handed to the user as *checking*, *assurance*, *deciding*, *scheduling*, *preparing*. That is
empirical, not designed, and it is the strongest starting vocabulary available.

---

## 2. The five questions

### 2.1 One consent or two? — **Two, and they are different kinds of act.**

**Recommendation:**

| Channel | Consent | Where it is set | Default |
|---|---|---|---|
| Rating (`1`/`2`/`3`) | **standing**, revocable, visible in settings | install-time opt-in | **off** |
| Diagnosis record | **per send**, payload-bound, never standing | the review dialog, every time | n/a |

**Why asymmetric.** The rating is two bits with a closed content channel; there is nothing in it to
review, so requiring a review would be ceremony, and ceremony is what trains people to click through.
It also carries real signal *alone*, and specifically it carries the denominator: three "bad" reports
mean nothing without knowing how many sessions were rated at all. The diagnosis is where every risk
lives, so its consent must be per-instance and bound to the exact bytes (§2.4).

**Three constraints that make the asymmetry safe rather than a loophole:**

1. **The rating must not be smuggled with the diagnosis's metadata.** If a rating ships with a session
   id it is no longer two bits. Rating payload = `{schema_version, app_version, platform, rating,
   date}`. Nothing else. Ever.
2. **Opt-in, default off, for both.** Not a preference — a positioning requirement. Opt-out telemetry
   in an open-source product is a recurring trust catastrophe in this category, and this product's
   stated promise is that everything stays local. Default-off costs response rate; default-on costs
   the promise. `wiki/open-source-strategy.md` makes the licence a hard v1 gate; a channel that ships
   default-on lands in the same release as the licence decision and contaminates it.
3. **A build-time removal path.** A cargo feature (`feedback`) that, when off, removes the module and
   the HTTP dependency entirely. Someone will fork this repo purely to delete telemetry, and a fork is
   a strictly worse outcome for everyone than a flag they can flip. The flag also gives self-hosters
   per `wiki/open-source-strategy.md` a build that *provably* cannot send, rather than one that
   promises not to.

**Naming, and it is not cosmetic.** Do not call this "telemetry" or "analytics" in the UI. And per
Frank §1.1 — the day's most instructive finding was a governance verb (`"Requested approval"`) put on
a calm surface where no approval capability existed — **do not use "approve" here either.** The
buttons are *Send* and *Don't send*.

### 2.2 Prose or taxonomy? — **Taxonomy, and the middle you are looking for is more dimensions, not shorter prose.**

The framing in the commission was "prose maximises fidelity, taxonomy is structurally anonymous but
loses specificity." I think that trade is smaller than it looks, and CS-001 lets me show it rather
than assert it.

**The decomposition of CS-001 §5 into closed vocabulary.** Left column is what §5's prose says; right
column is the field that carries it:

| What §5's prose asserts | Structured field |
|---|---|
| asked the user to perform a manual verification task | `misplaced_work: Preparing` (CS-001 §4 vocabulary) |
| three times across one session | `occurrences: TwoOrThree` |
| without preparing the artifact the task required | `failure_class: UnpreparedTaskHandedToUser` |
| no input file was named | `missing_preconditions: input_artifact` |
| no locations within it were specified | `missing_preconditions: location_within_artifact` |
| no method was given | `missing_preconditions: method` |
| no acceptance criterion was stated | `missing_preconditions: acceptance_criterion` |
| fifteen detailed briefs for sub-agents in the same session; the asymmetry is the defect | `contrast: AgentBriefsPreparedUserBriefsNot` |
| a record section for items awaiting the user made relaying feel like preparing | `contributing_condition: RelayingTreatedAsPreparing` |
| no user-facing item carried an acceptance criterion | `contributing_condition` (second slot) |

Ten assertions, ten fields, **no loss of anything actionable**. What is lost is the *texture* — the
specific artefact, its length, the number of windows. And the texture is precisely the
population-narrowing content, so losing it is the objective, not the cost.

**The sharper version of that argument, using CS-001's own acceptance test.** §5 says the test is
portability: the diagnosis must read identically for a user in an unrelated industry. **A diagnosis
that passes that test has, by definition, no industry-dependent information content — which is another
way of saying it is a category.** The case study proves the taxonomy is sufficient by its own stated
criterion. If prose can only be accepted when it is fully portable, then everything it may legitimately
say is expressible as a selection, and the prose adds nothing except the ability to fail.

**And the second §6 control is unrepresentable.** There is no member of any list below that says what
kind of material the user produces or who he produces it with. That is what "structurally anonymous"
buys: not a filter that catches it, but a vocabulary that has no word for it.

**I agree with the coordinator's fatigue argument, and it independently forces the same answer.** The
CEO ruled that the payload is shown before it leaves. A ten-row record with values spelled out is
reviewable in seconds, fifty times. A paragraph is not, and a paragraph reviewed for the fiftieth time
is not reviewed. So the ruling on question 4 settles question 2 for a reason that has nothing to do
with privacy: **structure is the only shape whose review survives repetition.**

**Where the taxonomy genuinely fails, and the instrument that measures it.** A closed vocabulary can
only report failures we already imagined. That is a real limit and there is exactly one honest
mitigation: **an `other` class that carries no text, and whose rate is the health metric for the
taxonomy itself.** A rising `other` fraction is a measurement of our imagination's shortfall, and it
is the field that must never be dropped for tidiness. Ship v0 with only the classes CS-001 evidences
(§3.1), plus `other`, and let `other` earn every addition. A taxonomy padded with guesses is the same
defect as a documented limit shipped past.

**And a free-text route still exists — outside the app.** When the user wants to say something in his
own words, the right affordance is a button that opens a pre-filled GitHub issue in his browser, under
his own account, in an editor he controls, which he sends himself. The app is not the sender. That is a
categorically different consent act, it costs nothing to build, and it means "no free text" is a
statement about the *automated* channel rather than a refusal to hear anything.

### 2.3 Rich diagnosing Rich — **make him classify a cited artefact, not narrate a session.**

CS-001 §8.2 asks for a corroborating signal before a self-diagnosis is trustworthy enough to send.
Here it is, and it is already on disk (§1.1): **every report is anchored to one specific, timestamped,
user-authored record** — a `Steer` text, a `Stop`, or a ledger `Message`. Rich does not decide *that*
something went wrong; the user's own artefact is the evidence that it did. Rich's job shrinks to
choosing labels for it.

Three properties follow, and together they are what makes it safe enough to send:

1. **The anchor is shown to the user in the review dialog and never leaves the machine.** He sees his
   own words next to the classification. The review question becomes *"is this label right?"* — which
   has a fast answer — instead of *"is this safe?"* — which has none. That is what makes §2.4's gate
   survive repetition.
2. **The failure mode is bounded.** A misclassification produces a wrong category. A bad prose turn
   produces a wrong diagnosis *and* an exfiltration. Same model, same error rate, two very different
   blast radii.
3. **Rich is not trusted to judge what is safe to send.** He is trusted to pick from a list. The safety
   comes from the list. This is the direct answer to "a model grading itself": you do not fix a
   self-grading model by making it more careful — 2026-08-29 is five proofs that care does not hold —
   you remove its ability to write the answer.

**On CS-001 §8.1 ("the user's own words are sharper and cost nothing to collect"): both halves are
right, and they point in opposite directions.** The words are the best evidence *and* the worst
payload. The resolution is that they are the **local anchor and the review substrate**, and they are
never the thing sent. Collect them (already done), classify against them, show them to the user, send
the class.

**One risk this creates, stated rather than hidden.** A classifier that reads user messages looking
for dissatisfaction is surveillance-shaped even when purely local. Three constraints: it runs **on
demand** (when the user asks to report, or when a seam prompt fires) and never continuously; it writes
**no new durable record** beyond a candidate list scoped to the current thread and discarded with it;
and its output is never surfaced as a standing judgement about the user. Local inference over local
data adds no exfiltration risk, but it does add an inference artefact, and that artefact should be
ephemeral by construction.

### 2.4 Showing the payload — **ruled: yes. Necessary, and not sufficient, and here is what makes it real.**

The CEO has ruled that the user sees what his RichOS is about to send. Designed for, not re-opened.

**What is actually shown:** the record itself, field by field, values spelled out in English. Not a
prose rendering of the record — the record. Because the type has a fixed field set, the dialog can
make a promise no prose payload can: **this is the whole thing, there is no "details" to expand, and
nothing is elided.** A diff-style presentation was floated; a diff implies a baseline, and the honest
and stronger framing is completeness rather than delta.

**Why it cannot be the only gate — four reasons, three of them the coordinator's and one from the code:**

1. **Review fatigue.** A payload reviewed carefully every time gets approved unread by the third
   occurrence. Zach's formulation of the same shape today: a warning that fires after the act is an
   obituary, not a guard. Here: a review nobody performs is a rubber stamp.
2. **The user is the worst judge of his own identifying detail.** He spots a client name instantly and
   misses that an unremarkable-to-him fact narrows the population to one. **CS-001 §6's second control
   is this exact failure, made concrete, and its own note says a user would approve it without
   hesitation.**
3. **Any single payload can be clean while a hundred triangulate.** Reviewing report #47 in isolation
   cannot see accumulation.
4. **A user cannot review what he cannot see.** He reviews the payload; he cannot review the *code
   path* that built it, whether a field was populated from an unexpected source, or whether the
   dialog is showing all of it. Only the type can promise that, and only a test can prove the type.

**So: two gates that fail differently, machine first.** The machine gate here is *stronger* than the
scrubber the coordinator's framing implies, because with a closed vocabulary it is not a detector at
all — it is a constructor. It has no false-negative class. The human gate then catches what the machine
structurally cannot: whether the label is *true* of his session. Note the division is the reverse of
the usual one: the machine owns safety, the human owns accuracy.

**Fatigue mitigations that are structural, not exhortation.** Each of these is a property of the code,
not of anyone's diligence:

- **A local rate limit in the type**: at most one report per day, three per week. Fewer reviews means
  each is read. This is also the cheapest mitigation of reason 3.
- **Send is never the default action.** `Enter` does not send. `Escape` does not send. The two
  outcomes require distinct, deliberate keys.
- **No "always send reports like this" checkbox.** That control is the fatigue escape hatch, and
  offering it converts a per-send consent into a standing one on the channel where standing consent is
  precisely what must not exist. Refuse it permanently.
- **The dialog shows the local anchor** (§2.3), so the review is a one-glance accuracy check.
- **A derived line stating what is absent**, generated from the type rather than typed by a human:
  "No text you or Rich wrote is included."

**One thing the machine gate must do and must not do.** It must **drop**, never **redact-and-send**. A
redacted payload teaches the user that the machine cleaned it, so it must be fine — which is exactly
the belief that makes the human gate ornamental. With a closed vocabulary there is nothing to redact,
which is one more argument for the vocabulary.

### 2.5 Timing — **the prompt is the fallback. The capture is already happening, and the irony dissolves.**

CS-001 §4 is evidence, not opinion: **five irritations, all volunteered unprompted, mid-work, none at
session end.** A feature that only asks at a chosen moment would have caught none of them when they
were felt. And §1.1 above establishes that all five were already durable on disk at the instant they
were typed.

**Therefore the prompt's job is not capture. It is consent.** That single reframing removes the irony
the CEO's question identifies: you do not interrupt the user to ask how it is going, because you
already know how it is going. You interrupt only to ask permission to say so.

**Recommended timing, in priority order:**

1. **The mid-work catch, and this is the design's best affordance.** When the user steers or stops,
   the timeline row for that turn gains a quiet, non-blocking "report this" affordance. No modal, no
   focus steal, no expiry. It catches in-the-moment context at zero interruption cost, which is what
   §4's evidence actually asks for.
2. **A seam prompt, as fallback for users who do not volunteer.** Never mid-turn —
   `TurnControl::active_turn()` (`steering.rs:436`) is the gate and it already exists. Fire at a real
   seam: a thread archived, app quit, a long idle after a completed turn. Never on a timer.
3. **Only when there is something to report.** If no candidate evidence was captured, never ask. This
   makes the prompt rare and makes it correlate with a real event, which is the opposite of an
   interruption tax.
4. **At most once per day, and dismissal is respected.** Three consecutive dismissals silence the
   prompt for a period. A prompt that ignores being dismissed is exactly the annoyance this feature
   exists to reduce.

**Three specifics on the CEO's sketch:**

- **"This session" needs defining, and the right unit is the thread, not the app session.** CS-001 §4
  is five distinct moments inside one session; a session-scoped rating collapses them into one number
  and loses four-fifths of the signal. The evidence is already thread-scoped —
  `IntakeRecord::Steer` carries `thread_id`, captured at write time precisely so it cannot be
  re-scoped later (`steering.rs:96-100`).
- **The number keys must not steal keystrokes from the composer.** `1`/`2`/`3`/`0` bound globally in
  an app whose main input is a text box is an interaction defect that would itself generate a report.
  Bind them only while the prompt holds focus.
- **`0: Dismiss` is right and worth keeping.** It distinguishes "no answer" from "neutral," which a
  three-point scale with a neutral would not.

---

## 3. The payload, specified

Two payloads, two consents (§2.1). Every field is an enum member, a compile-time constant, or an
integer the app computed from its own ledger. **No field is written by the model.**

**Rating payload:** `schema_version`, `app_version`, `platform`, `rating`, `date`. Five fields, all
constants or two-bit enums. Nothing else is ever added to it.

**Diagnosis payload:**

| Field | Type | Filled by | Why it exists |
|---|---|---|---|
| `schema_version`, `taxonomy_version`, `app_version` | compile-time constants | app | the server cannot interpret a payload whose vocabulary it does not know; and the user consented to a *shape*, which must not change under him |
| `platform` | enum (3) | app | a failure class that is platform-specific is a different bug |
| `rating` | enum (3) | user | the severity the user assigned |
| `misplaced_work` | enum (6) | model index | CS-001 §4's empirical vocabulary: preparing / deciding / checking / assurance / scheduling / none |
| `failure_class` | enum (7 in v0) | model index | §3.1 |
| `missing_preconditions` | fixed 6-bit set | model indices | input artefact · location within it · method · acceptance criterion · destination for the result · time cost. Derived from CS-001 §1 and §9 |
| `contributing_condition` | enum (incl. `not_identified`) | model index | what let it survive, per CS-001 §3 |
| `occurrences` | bucket (4) | app, from the ledger | once vs. three times is the difference between a slip and a pattern |
| `surface` | enum (6) | app | conversation / dictation / timeline / worker status / proactive message / stop control |
| `date` | `YYYY-MM-DD` | app | coarse by design — a clock time is a fingerprint |

**No install id, no session id, no thread id, no turn id, no locale, no clock time, no free text.**

**Two deliberate design details that exist because I attacked my own proposal:**

- **Every integer is bucketed, and the buckets are computed by the app.** An unbounded integer a model
  fills in is a covert channel; `occurrences: 3` is fine, `occurrences: 1179285` is a payload. The app
  derives counts from its own ledger and maps them onto four buckets before the record exists.
- **The record has no constructor that accepts model output.** Rich returns indices; a total function
  maps indices to enum members and rejects out-of-range. If that function is the only path to a
  `FeedbackReport`, the guarantee is compile-time.

### 3.1 `FailureClass` v0 — only what CS-001 evidences, plus `other`

1. `unprepared_task_handed_to_user` (CS-001 §5's own class name)
2. `asked_a_question_whose_answer_was_already_determined` (§4 row 3)
3. `asked_the_user_to_sequence_work_the_assistant_owns` (§4 row 4)
4. `asked_the_user_to_notice_a_failure_machinery_should_have_caught` (§4 row 1)
5. `asked_the_user_for_assurance_about_recurrence` (§4 row 2)
6. `repeated_a_request_already_made` (§1: three times in one session)
7. `other` — **no text, ever**

Six evidenced classes and one instrument. Every future class must be earned by the `other` rate, not
argued into existence. That is the same discipline the rest of this repository applies to constants:
derive it from measurement or do not ship it.

### 3.2 The keystone test

```
serialize(FeedbackReport) -> walk every JSON string value
  -> each must be a member of TAXONOMY_STRINGS ∪ {app_version, platform, date-pattern}
```

Total, cheap, and it fails loudly the first time anyone adds a `String` field. **This test is the
feature's actual safety guarantee.** If it is ever deleted or weakened, the design described here no
longer holds, and that should be written in the test's own name — this repository already uses test
names as invariant documentation.

### 3.3 The egress boundary

- **One function, one destination, one payload type, in Rust.** The HTTP client is a private
  dependency of the feedback module and is not re-exported. A test asserts no other module reaches it.
- **The UI cannot reach the network.** Set a CSP with an explicit `connect-src` (§1.3) — today
  `"csp": null`.
- **No third-party analytics SDK, ever.** An unauditable dependency on the one path where
  auditability *is* the product claim. One `POST` to one endpoint we own.
- **One report per request.** Batching creates an ordering channel and defeats the per-send review.
- **Failure is silent and terminal.** No retry queue. A queue is a persistent store of pending
  outbound private-adjacent records — a new asset with a new risk for no user benefit. If the send
  fails, it is dropped and the user is told.

---

## 4. Where `publication-boundary` fits, and where it does not

The commission asked whether the guard built this morning fits, and to say plainly where it does not.
**It does not fit on the egress path, and the reason is worth stating carefully, because reaching for
it is the tempting move.**

**Where it genuinely fits:**

- **On the repository, unchanged, doing exactly what it already does.** The taxonomy source file,
  every fixture, every golden payload committed to `richos` is already covered by
  `guard-publication-commits.sh`. Nothing to add.
- **As the design pattern.** Derive the predicate from a declared source of truth; never maintain a
  list; make the guarantee structural. This brief is that pattern applied to a different question.

**Where it does not fit, in order of decisiveness:**

1. **Its corpus assumption inverts on a customer machine.** The detector's measured precision — 17
   flags across 57,034 files, zero non-transcript false positives — depends on `PRIVATE_SOURCES`
   being *narrow*: declared trees, filtered down to files that are themselves recorded speech
   (`publication-boundary.sh`, "WHAT IS DERIVED, AND FROM WHAT"). On the user's machine there is no
   declared private corpus, and the true private corpus is *everything* — the ledger, the journal, the
   entire conversation history. Point a ten-word verbatim-run detector at a user's complete
   conversation log and it will match ordinary English. **`MIN_QUOTE_WORDS=10`
   (`publication-boundary.sh:235`) was tuned against transcripts; against "everything the user has
   ever written" its false-positive rate is unmeasured and plausibly high.** A guard that blocks
   legitimate work gets switched off — the guard's own header says exactly that about a different
   derivation it rejected.
2. **Paraphrase, which its own header names as out of scope** (`publication-boundary.sh:119-121`), is
   the *entire* threat here rather than a residual. CS-001 §6's second control is pure paraphrase with
   no proper nouns: nothing verbatim, nothing to match, still disqualifying. **Adopting this guard
   here would be building on a limit its author already wrote down — which is precisely the failure
   shape Frank names in §5 of his brief and the shape that produced three of his findings.**
3. **It is a Bash/Python guard over files.** Shelling to Python on a desktop app's egress path adds a
   runtime dependency that may not exist on the user's machine, for a check that would not answer the
   question anyway.

**The right conclusion is not "port the guard."** It is: **choose a payload type the guard would have
nothing to inspect**, and leave the guard where it already works — on the repository. A detector is
what you need when the content is open-ended. Close the content and you do not need one.

---

## 5. R2 — inside or outside the deferral

**Outside, and it does not reopen it. Here is the argument rather than the assertion.**

On the CEO's words alone (`wiki/ceo-decisions.md` §1: "sending, spending, committing, publishing,
**sharing**"), a telemetry send lands inside. But the *reasoning* he gave is what defines the scope,
and it points the other way. He deferred R2 because **only each individual CEO can define what counts
as a real business action for themselves** — that is, the undeferrable thing was a *general governance
framework over an open-ended action space*, and nobody can specify one on someone else's behalf.

This channel has none of those properties: one destination fixed at compile time, one payload type
fixed at compile time, one purpose, user-initiated per send, bytes shown before they leave, no
credential, no spend, no third-party account, no counterparty.

**So the honest statement: this feature does not need governance. It needs a boundary.** Governance is
what you build when the action space is open and each case must be judged. Here the action space is one
action of one shape, so the answer is a type, not a policy — which is the same reason §0 lands where it
does.

**And the way it *would* reopen R2, stated so it can be held.** Not by existing. By generalising. The
moment any of the following is true, R2 is live and this classification is void:

- the HTTP client becomes a shared dependency any other module can reach
- the payload gains a `String` field, or any field the model writes directly
- Rich can choose the destination, the timing, or the contents
- a second caller wants "the network thing that already exists"

**Requirement: the design must make the first two mechanically impossible (§3.2, §3.3), not merely
discouraged.** A capability introduced for one purpose and left general is how a deferral gets
reopened by accident, and Frank's §1.1 is today's proof that it happens through something as small as
a string.

---

## 6. v1 scope — the argument

The retroactivity argument is that every session before instrumentation exists is feedback that can
never be recovered, and it is the argument that correctly justified landing techy mode's routing ahead
of its renderer. **It does not hold here, and it fails on the one fact that made it work there.**

Techy mode's routing had to land early because **the ACP stream is ephemeral** — unrouted, those bytes
are gone. Here, the data is **already captured and already durable** (§1.1). `Steer`, `Stop` and every
ledger `Message` are on disk today, fsync'd, with thread and turn scope, for reasons that have nothing
to do with this feature. **The thing the retroactivity argument worries about losing is already being
kept.** So the premise is satisfied without shipping anything, and the argument for shipping the
channel in v1 has to stand on its own merits — which are thin, because v1 has no users and there is
nothing to aggregate.

Against shipping it in v1, three things:

- **It is a new outbound channel in the release that also has to clear the licence gate**
  (`wiki/open-source-strategy.md`) and the signing gate (`wiki/packaging-and-signing.md`). Both are
  trust-sensitive; stacking a telemetry channel on top adds trust surface at the worst moment.
- **The value is zero until there is a population**, and a report from a population of one is a report
  from a man who can tell us directly.
- **The hardest unknown here is not privacy. It is whether the prompt itself is annoying** — and that
  can be measured on one user, locally, with no network at all.

**Recommendation:**

- **v1: nothing outbound.** Land the taxonomy as a versioned document, record the decision on the CEO
  decisions page, and — optionally, cheaply, and with real value — ship the **rating prompt writing to
  the local ledger only**. That dogfoods the timing question (§2.5) with exactly zero privacy risk and
  produces the calibration CS-001 §7 asks for.
- **1.1: the channel**, gated on the licence being decided, the install-time opt-in, the closed
  vocabulary, the keystone test (§3.2), the CSP, and the review dialog.
- **Because the vocabulary is versioned and the evidence is already durable, historical sessions can
  be classified retroactively against taxonomy v0 when the channel does ship.** The retroactivity
  worry is answered by version-stamping the taxonomy now, not by shipping the sender now.

**The one thing to refuse.** If a proposal arrives to add *new* capture — a session-quality log, a
dissatisfaction record, anything persistent — ahead of the sender, that is Frank's F4 exactly: 100 % of
the privacy cost, 0 % of the value, with a renderer that does not exist. Refuse it. This feature's
distinguishing property is that it collects nothing new, and that property is worth protecting.

---

## 7. The open-source surface

`wiki/open-source-strategy.md` makes the licence a hard v1 gate and the business model open core. A
telemetry channel in that context is read as a betrayal unless every one of these is true:

- **default off, opt-in, revocable in one place**
- **buildable out** (§2.1, the cargo feature)
- **the payload type and the endpoint are in the public repo**, readable by anyone. This is the
  strongest trust move available: not a privacy policy asserting what we collect, but a type
  declaring what *can* be collected. It is also why §0's recommendation is the one that makes the
  open-source position defensible at all — a `String` field in a public type promises nothing.
- **published retention and non-linking policy on our side.** "Anonymized" is partly a claim about our
  servers, and nobody can check it from the repo. State the retention period, state that reports are
  not linked, and mean both.

---

## 8. What I am not claiming to have solved

Stated here so nobody has to discover it, in the register the guard's own header uses.

1. **At v1 population, anonymity is arithmetically false.** With ten users, whatever arrives came from
   one of ten people we can name, and the CEO is one of them. The design delivers **content-free**,
   not **anonymous**. **Do not put the word "anonymous" in the UI until the population supports it.**
   Truthful copy: *"No text from your work leaves this machine."* That is a claim the type enforces.
   "Fully anonymized" is a claim about a population we do not have. This is the single most likely
   place for this feature to become a trust failure, and it costs nothing to avoid.
2. **The payload carries roughly twenty-plus bits about the failure.** That is a lot of entropy in the
   abstract, and it could weakly link two reports from an install with an idiosyncratic failure
   pattern. The mitigation is that every axis is a property of *Rich's behaviour*, not of the user;
   plus no id, coarse dates, and the rate limit. **Weak, not zero — and I am not claiming zero.**
3. **Selection is itself a low-bandwidth channel.** Which class the model picks, across many reports,
   carries a little information. Per-send human review and one report per day make it negligible. Not
   nil.
4. **The class choice discloses something, and it is the right something.** Choosing "asked me to
   sequence work" reveals that the user delegates work. That is product-shaped information about how
   RichOS is used, which is what he consented to send.
5. **A new server-side asset.** An unauthenticated POST endpoint is an abuse surface — spam, resource
   exhaustion, garbage in the dataset. An operations problem rather than a privacy one, but it is new
   and it is ours.
6. **I did not build or measure anything.** No code was written. The false-positive prediction in
   §4.1 is reasoning from the guard's stated tuning basis, not a measurement — if anyone wants to
   overturn §4, the way to do it is to run the corpus builder against a real conversation log and
   report the number.
7. **I did not assess the UX.** The dialog described in §2.4 is a set of constraints, not a design.
   Urban owns whether it is any good.

---

## 9. What still needs the CEO

1. **CS-001 §7 — the ratings.** Which number he would have pressed at each of the five moments. It
   calibrates the scale against real annoyance and turns §5 into a fixture with a known-correct
   rating attached. Thirty seconds, and nothing else can supply it.
2. **Whether "no free text in the automated channel, a GitHub issue for prose" is acceptable.** That
   is the one place this design trades a capability he described for a guarantee he cannot otherwise
   have, and he should weigh it knowing that is the trade.
3. **The v1 / 1.1 split in §6.** I have made the argument rather than asked; the call is his.
