# The first-run notice — the visible half of the onboarding offer

**Date:** 2026-09-06
**Author:** Urban (principal product designer)
**Occasion:** `docs/verification/onboarding-honesty-2026-09-06/README.md`, "What is NOT built",
item 2 — *"The first-run sheet is not built. Rich makes the offer in conversation; a CEO who
does not read the first reply never sees it."*
**Scope:** the design call, its reasoning, and the surface built from it.
**Basis:** branch `urban-opus-fr1`, from `32e1dc5`.

**This is not a signoff.** I designed and built this surface, so I cannot be the one who
passes it. It needs an independent UI/UX signoff and it does not have one.

---

## Verification basis — read this before trusting anything below

**Every visual claim here was seen on the real renderer, live, before it was written.** The
target surface for the RichOS shell is WebKit — Tauri renders through WKWebView on macOS — and
the shell was driven under headed WebKit at 1400x950, in **both themes**, through every state
this document describes. What is stubbed is the Tauri bridge (`app/ui/mock.js`, the project's
own preview harness), and that is stated rather than glossed: the two new commands were driven
against the mock, and `app/crates/richos-core` proves the layer beneath them with four
integration tests over real files on disk.

Contrast ratios below were **computed**, twice and independently — by hand against the token
values before any CSS was written, and then in the page off `getComputedStyle` on the rendered
result. Both sets are printed in §7. Nothing here was eyeballed.

Not verified: the packaged `.app`. This has not run inside a real Tauri window, and the two
Tauri commands have not been driven by a real webview. `cargo check` passes on both crates and
the shape is the same as every other command in `main.rs`, but that is a hypothesis about the
build, not a measurement of it.

---

## 1. The question I was asked to answer honestly, and the answer

**Asked:** whether a sheet is even the right form, now that the conversational offer exists and
was measured working.

**Answer: no. A modal sheet is the wrong form, and I am not building the one my own earlier
document proposed.** What is built instead is a **notice at the head of the conversation** —
the same place the interview will happen, visible without a word typed, and answerable at
leisure.

Four reasons, in order of weight.

**1. A modal asks for twenty minutes from a man who has seen nothing.** The three dialogs
already in the first-run chain ask for things RichOS cannot work without — a `claude` binary, a
memory folder, a company. The interview is not in that class; the app works without it. Putting
it fourth in that queue teaches him it is a fourth blocker, and the ask lands at the moment of
least information he will ever have about the product.

**2. A modal has two exits, and the honest answer needs a third.** At that moment the true
answer is often *"I do not know yet — let me look at this thing first."* A modal cannot take
that. Its dismissal is either unrecorded, in which case it reopens at every launch and becomes
the permanent interruption `main.js:3538-3548` already records the memory question becoming; or
it is recorded, in which case a man who meant "later" has been filed as having refused. **The
notice's third exit is to leave it there.** Ignoring it costs nothing and changes nothing.

**3. The offer already exists in the conversation, and a modal would duplicate it across a
seam.** Cell D1 measured Rich making the offer well. A sheet makes the same offer in a place
the interview does not happen, then closes and hands off. The notice sits at the top of the
pane the interview will fill, and its Start control puts a real turn into that pane.

**4. That pane needs authoring anyway.** Driven live: after the first-run chain, the
conversation is an unbroken field with a composer at the bottom. That reads as a fault, not as
a beginning. The notice is the empty state and the offer in one surface — not a widget added on
top of a finished screen, which is what a fourth dialog would have been.

### What this notice is

A block at the head of `#conversation`, in the conversation's own reading column, above the
messages.

> **I don't know your business yet.**
>
> There's nothing on file about what this company does, who it's for, or how you want to work.
> I can ask you about it — about twenty minutes — and write your answers down, so I use them
> from then on. You can stop partway, and "not sure yet" is a real answer to any of it.
>
> *"Not now" means I'll stop offering. You can start it any time by asking.*
>
> `[ Start the questions ]` `[ Not now ]`

---

## 2. The second question — what happens when he dismisses it

**Asked:** what the surface does on dismissal, given that it must not promise something the
built chain does not do.

**The chain holds exactly two durable facts** (`onboarding.rs`): this company has been
described, and he was asked and said not now. There is no third, and the module carries a test
whose only job is to refuse a third.

**And the second of those had no writer.** `OnboardingRecord::record_declination` shipped at
`32e1dc5` with no caller anywhere in the product:

```
$ grep -rn "record_declination" app/ --include="*.rs" | grep -v "src/onboarding.rs"
  (no output)
```

So `OnboardingState::Declined` and `DECLINED_BLOCK` were unreachable outside their own unit
tests, and a CEO who said "not now" into the conversation was re-offered the interview at the
next prime of every new thread, forever. That is the M5 nag with nothing holding it back, in a
module whose own doc names that nag as the reason the record exists.

**So the dismissal is the writer.** "Not now" calls `decline_onboarding`, which writes the
declination. Three consequences, and each is on screen rather than assumed.

- **The effect is stated beside the button, in words.** The write is durable and it stops Rich
  offering; two syllables cannot carry that and stay speakable. So the label stays `Not now`
  and the line under it says what `Not now` does.
- **It is reversible by asking, and the surface says so** — because `DECLINED_BLOCK` tells Rich
  the interview is still there if the CEO brings it up. The button's effect and the product's
  behavior are one claim, not two.
- **The press leaves a receipt, and the receipt is not a panel.** One quiet line — *"Left with
  you. Ask me any time and we'll go through it."* — with the border, the fill and the semibold
  headline gone. It is gone at the next launch, because by then the state is `declined` and
  nothing renders. He pressed a button that wrote something down; a panel that simply vanished
  would give him no way to know that it did.
- **A refused write keeps the notice open and says so.** Closing a notice over a write that
  failed is reporting success over work that did not happen, which is the failure this whole
  line of work exists to remove.

### And it never contradicts Rich

Both the notice and the priming block are derived from `Spine::onboarding_state`, which is
derived from the two facts on disk. Nothing caches an opinion about either, and **nothing
anywhere records that the notice was shown** — the positive-signals-only rule holds.

Both controls move the state **before Rich's first turn**, which is what stops the screen and
the conversation offering the same thing twice.

| he does | the state when Rich is next primed | what Rich is told |
|---|---|---|
| presses Start | unchanged (`not-yet`) | the offer — and the CEO's first turn is already the acceptance |
| presses Not now | `declined` | `DECLINED_BLOCK` — do not offer again unless he raises it |
| ignores it and types something else | unchanged (`not-yet`) | the offer, once, in words |

The last row is not a duplicate. He was ignored, not answered, and a product that shows a thing
this consequential in print and then also asks about it once is behaving correctly.

---

## 3. The five states, and the three that render nothing

| state | on screen | why |
|---|---|---|
| `not-yet` | the offer | the interview is due |
| `unusable` | the statement, no controls | the one state that needs a person, and no button could fix it |
| `described` | nothing | finished |
| `declined` | nothing | answered |
| `no-central-folder` | **nothing, deliberately** | see below |

**`no-central-folder` renders nothing and that is the load-bearing omission.** It means nothing
has looked — there is nowhere for his answers to go. Offering to spend twenty minutes writing
down answers that have no home is the one thing this notice must never do, and it is exactly
what Rich himself refused to do when the condition arose unprompted in cell D3: *"If we go
ahead right now, I'd be holding what you tell me in this conversation only, and a conversation
ends."* The memory question earlier in the first-run chain is the surface that owns that
condition; a second surface saying a version of it would be duplication.

**`unusable` was added deliberately and is declared here rather than left to be discovered.**
It is the visible half of `UNUSABLE_BLOCK`, which had no visible half at all — a CEO whose
company notes are unreadable saw nothing. It draws no control, because no control could fix it,
and it names the party who can. Its two sentences are composed in Rust, like
`history_health`'s, so this window is never in a position to substitute "I could not read your
notes" for "you have no notes".

---

## 4. What the copy does and does not promise

Every clause of the offer is there for a reason, and the omissions are decisions.

**In, and why.**

- **The headline does not say "anything".** It did, until it was put on screen directly
  after the company picker — where the CEO has just typed his company's name, so RichOS
  knows exactly one thing about his business and a headline claiming it knows nothing is a
  small untruth in the product's first sentence. Knowing a name is not knowing a business.
- *"There's nothing on file"* — a fact about this install, not a failure of his.
- *"about twenty minutes"* — the same words `OFFER_BLOCK` gives Rich, so the screen and the
  conversation quote one number.
- *"write your answers down, so I use them from then on"* — the whole and only promise.
- *"You can stop partway, and 'not sure yet' is a real answer"* — said before he can wonder.
  Alone, nobody is there to tell him deferral is honest, and an unanswered question otherwise
  reads as a failure to answer.

**Out, and why — these are the two lies the product could not cover.**

- **Nothing about staffing.** Nothing in the app can spawn a teammate today
  (`onboarding.rs`'s module doc: measured open, not wired), and the CEO's own constraint on
  this work is that a first run reporting it onboarded somebody while having staffed nobody is
  worse than no onboarding at all. `OFFER_BLOCK` already requires Rich to say so plainly during
  the interview; putting it in the *offer* would be answering a question he has not asked, which
  is the over-explaining this product does not do. The suite pins the absence
  (check 6, six forbidden words).
- **Nothing about the home screen.** What is there is a worked example; a new customer's corpus
  compiles to zero. Any copy implying "answer these and watch your company appear" is a lie the
  product cannot cover. Also pinned by check 6.

**It survives being spoken.** "I" is Rich throughout and "you" is the CEO throughout; the
pronouns never trade places, which is the one thing that breaks when screen copy is read aloud.
`Start the questions` and `Not now` both mean the same heard as read. American English
throughout. No pagination — it is one block that never scrolls into a second.

---

## 5. Where it sits, and the two things fixed by looking at it

Inside `#conversation`, after `#history-notice`, before `#messages`.

Not the rail (that is navigation). Not the opening screen (dismissed in one keystroke, and he
reaches the conversation by many paths). Not below the composer (the conversation is the hero
and this is the first thing in it).

**Five defects were found by rendering it, and not one of them would have been found by
reading the code.** They are listed because the list is the argument for the rule: this
surface was designed on screen, in both themes, at three widths, in the order a first-run user
meets it.

1. **It ran the full width of the pane.** `#conversation`'s children are full-bleed by default
   and `#messages` is not — it is `--reading-width` wide with gutters. So the panel's edges sat
   80px outside every sentence below them, which reads as browser chrome bolted on above the
   product.
2. **And the fix was only half a fix.** A `max-width` alone is right only while the pane is
   wider than the reading column. At 1000px, where the rail takes 300 and the pane is 700, the
   panel took the whole 700 and ran hard against the window edge — 28px proud of every sentence
   under it, on both sides. It carries a `width` as well now.
3. **Its gutter was the wide one at every width.** `#messages` uses three — 28px, 24px under
   1180px, 18px once `applyBreakpoint()` sets `bp-narrow`. At 760px the panel sat at x=18's
   neighbor while the text started at x=18. The two sets are a duplicate that cannot share a
   selector, so check 10 reads both boxes off the rendered page at 760, 1000 and 1400 and
   asserts the four verticals are equal.
4. **The "Not now" receipt kept the panel's chrome**, including the 17px semibold headline, so
   a quiet acknowledgement read as a fresh announcement. The chrome and the padding go on
   `declined`, and the type drops to the body tier.
5. **The notice painted over the company picker.** Not a product defect but a harness one, and
   it is the more useful of the two kinds: `onboarding_view_of` returns `no-central-folder` when
   there is no active binding, and `mock.js` answered from its preset regardless — so the
   preview served a state the product cannot produce. Fixed in the mock, and the real order is
   now walked end to end by check 9.

A sixth was found the same way and is a backend defect rather than a layout one: the refusal
put `DoctrineError::Unwritable` on the CEO's screen — *"the standing instruction could not be
written to /Users/…/onboarding.json — RichOS will not start Claude without it"*. Every clause is
false about that file, and it carries an absolute path onto a screen `setup_view.rs` says takes
whole sentences and no paths. That half now goes to the operator's channel and he gets a
sentence written for him.

---

## 6. What was built

| | file | what |
|---|---|---|
| 1 | `app/crates/richos-core/src/spine.rs` | `onboarding_state` (read, derived) and `record_onboarding_declination` (the missing writer; `Err` rather than a silent success when nobody has said where the record lives) |
| 2 | `app/crates/richos-core/tests/onboarding_declination_tests.rs` | 4 tests, over real files; the one that matters drives a **second spine over the same files** so the press has to survive a relaunch |
| 3 | `app/src-tauri/src/main.rs` | `onboarding_view` / `decline_onboarding`, appended to the handler list; the three CEO-facing sentences as consts |
| 4 | `app/ui/index.html`, `style.css`, `main.js` | the surface |
| 5 | `app/ui/mock.js` | `onboarding_view` / `decline_onboarding` arms; default `described`, so no other suite's fixtures start painting this panel |
| 6 | `app/ui/tests/onboarding.js` | 10 checks, 80 assertions, every one run red by breaking the shipped source |
| 7 | `app/ui/tests/contrast.js`, `contrast-debt.json` | two new walked surfaces; check 10c would otherwise refuse a shell-declared panel nobody had measured |
| 8 | `app/ui/tests/affordances.js`, `lib/state-registry.js` | nine states classified, three fixtures driven; every sentence of the offer is ACTIONABLE and names one of the two controls in its own panel |

---

## 7. Contrast and type — computed, both themes

Floors: **4.5:1** normal text, **3:1** large text (18.66px bold, or 24px+) and non-text
indicators. Nothing on this surface is large text; the 17px semibold headline takes the
**4.5:1** tier, because rounding a tier down is how a "large text" pass gets claimed for text
that is not large.

Left column computed by hand against the token values before the CSS existed; right column
computed in the page off `getComputedStyle` on the rendered result. They agree to 0.02, and the
differences are alpha-compositing rounding.

| element | token on surface | floor | dark (hand / page) | light (hand / page) |
|---|---|---|---|---|
| headline | `--ink` on `--surface-raised` | 4.5 | 13.02 / **13.02** | 17.02 / **17.02** |
| body | `--ink` on `--surface-raised` | 4.5 | 13.02 / **13.02** | 17.02 / **17.02** |
| consequence line | `--ink-soft` on `--surface-raised` | 4.5 | 6.09 / **6.08** | 6.24 / **6.22** |
| Start label | `--on-gold` on `--accent` | 4.5 | 7.68 / **7.68** | 4.72 / **4.72** |
| Not now label | `--ink` on `--surface-raised` | 4.5 | 13.02 / **13.02** | 17.02 / **17.02** |
| panel border | `--line-control` vs the pane | 3.0 | 4.57 / **4.57** | 3.35 / **3.35** |
| panel border | `--line-control` vs the panel | 3.0 | 4.09 | 3.82 |
| Start fill | `--accent` vs the panel | 3.0 | 6.87 | 3.60 |
| Not now edge | `--line-control` vs the panel | 3.0 | 4.09 | 3.82 |
| Not now hover label | `--accent-text` on the panel | 4.5 | 6.87 | 6.26 |
| focus ring | `--accent` vs panel / pane | 3.0 | 6.87 / 7.68 | 3.60 / 3.15 |
| declined receipt | `--ink-soft` on `--paper` | 4.5 | 6.47 | 5.86 |
| unusable headline | `--attention` on `--surface-raised` | 4.5 | 7.05 | 6.19 |
| unusable body | `--ink` on `--surface-raised` | 4.5 | 13.02 | 17.02 |
| unusable border | `--attention` vs panel / pane | 3.0 | 7.05 / 7.88 | 6.19 / 5.42 |
| error line | `--danger` on `--surface-raised` | 4.5 | 6.30 | 7.65 |

**Tightest values, named rather than buried:** the Start label at **4.72:1** in light (text,
floor 4.5) and the focus ring at **3.15:1** in light (indicator, floor 3.0). Both are the app's
existing `--accent` / `--on-gold` pair used everywhere else; neither has much headroom and
neither should be darkened further without recomputing both.

**Type.** 17px headline; 16px for body, consequence line, both button labels, the receipt, the
unusable statement and the error line. Nothing below 16px.

**NOTHING ON THIS SURFACE IS EXEMPT AND NOTHING CLAIMS TO BE.** In particular the consequence
line is not: it is the only place the effect of a control is stated, and it is exactly the sort
of line an exemption gets claimed for. The suite asserts that no node inside `#first-run`
carries `data-contrast-exempt`, in both themes.

---

## 8. What is still not built, stated plainly

1. **The declination record is per-INSTALL, not per-company.** `onboarding.json` holds one
   `declined_at_millis` and `state(layer, record)` reads it for every company. So a CEO who
   declines while working on one company is never asked about the next one he adds, silently.
   This surface **inherits** that rather than causing it — the priming block behaves the same
   way today — and it is not fixed here because widening the record means changing
   `the_record_holds_only_a_declination`, whose intent belongs to whoever wrote it. **This is
   the first follow-up.**
2. **Staffing.** Measured open (`--agents <json>` reaches `init.agents` under
   `--setting-sources ''`), not wired. The offer promises nothing about it, on purpose.
3. **The opening screen's own sentence.** *"This is what your home screen could look like once
   Rich knows enough about you and your business"* — seen live at the top right of the splash.
   It was a dead end when nothing could make Rich know more. Now that the interview is
   reachable, that sentence acquires an implied path which ends somewhere else, since answering
   the questions will not put his data on that screen. Somebody should look at it; it is not
   this surface's to change.
4. **An end-to-end interview that really writes `company.md`.** Unchanged from
   `onboarding-honesty-2026-09-06`: what would settle it is running the interview under the
   app's own permission policy with a central folder present, and diffing the file afterwards.
5. **The packaged app.** See the verification basis. This has not run in a real Tauri window.

---

## 9. What this needs next

**An independent UI/UX signoff.** I designed this and I built it, so I am not eligible to pass
it. The reviewer's checks, in order:

1. Drive `app/ui/tests/onboarding.js` and read check 8's printed ratios rather than this table,
   and check 10's printed box geometry rather than my word for the alignment.
2. Look at the offer, the receipt, the refused write and the unusable state **on screen, in both
   themes**, and judge whether the notice reads as part of the conversation or as chrome above
   it. That is the judgment call I made and cannot certify.
3. Decide whether the third row of §2's table — Rich offering in words to a man who ignored the
   notice — is right. I think it is. It is the one place the product says the same thing twice.
