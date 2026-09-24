// THE CLASSIFICATION. One row per user-visible state string, and the source is the
// authority over it — not the other way round.
//
// THE RULE THIS SERVES
// ====================
//   A state the user could change must be rendered together with the control that changes
//   it. A state change requiring a human action is not a status, it is a request.
//
// HOW THIS FILE IS KEPT HONEST
// ============================
// `lib/state-strings.js` scrapes the shipped source and produces the inventory. This file
// annotates it. `affordances.js` asserts the two sets are EQUAL — a string added to ANY
// shipped UI file, to the Tauri command layer or to a `ceo_message()` and not classified
// here fails the suite, and a row here whose string no longer exists in the product fails it
// too. There is no way to add a state and quietly skip the question.
//
// "ANY SHIPPED UI FILE" IS NEW WORDING AND IT USED TO BE A LIE. This sentence read
// "index.html, main.js, timeline.js" until 2026-09-05, and so did the scraper — three files
// against nine `<script src>` tags. `lib/ui-sources.js` derives the list from the tree now;
// the 55 rows that arrived the day it landed are grouped at the bottom of this file under
// the heading that says which surfaces had no gate over them.
//
// This file is therefore a list, and a list is the thing this whole sequence has been
// burned by eleven times. The difference is that nothing READS this list as an inventory:
// the inventory is derived, every run, and this file is checked against it. A list that is
// verified against a derivation is an annotation. A list that IS the derivation is a defect
// waiting for its first drift.
//
// IT LIVES IN `lib/` FOR A SMALL, EXACT REASON. `run.js` discovers suites as "every .js
// file in tests/ that is not run.js", and `lib/` is where it expects shared harness code
// rather than suites. A data module sitting in tests/ would be spawned as a suite, exit 0
// having asserted nothing, and be counted in "N suites passed" — a reassuring fraction over
// a file that tests nothing, which is the exact shape of every defect above.
//
// THE BUCKETS
// ===========
// The three the rule needs:
//
//   ACTIONABLE          the user could change this. MUST name a `control`: a selector for a
//                       button, field or row that is present, visible and enabled in the
//                       same view when the state renders. A doc link is not a control.
//   NEEDS-SOMEONE-ELSE  he cannot fix it; somebody can. MUST either name a party in the
//                       text itself (checked by regex — a future edit that deletes the
//                       party fails the suite) or carry `explainedBy`, pointing at the
//                       state in the same view that names it.
//   INFORMATIONAL       genuinely nothing to do. MUST NOT read as a request: no imperative
//                       aimed at the reader.
//
// And three that exist because the scrape returns strings, not states, and pretending
// otherwise would force a clean split the material does not have:
//
//   CONTROL       the string IS a control's label or accessible name. It is an affordance,
//                 not a state that needs one.
//   FRAGMENT      a piece of a composed sentence that never renders on its own (blind spot
//                 B1). Classified against the sentence it belongs to.
//   UNREACHABLE   present in source, and no path in the shipped UI reaches it. The reason
//                 is stated per row and is a claim someone can check.
//   NOT-RENDERED  a literal the prose filter caught that never reaches the DOM at all.
//
// WHERE A STATE IS TWO THINGS AT ONCE, both are said in `why` rather than forced into one
// bucket. The §21 unbound screen is the clearest case: the binding needs an operator
// (NEEDS-SOMEONE-ELSE) and starting fresh elsewhere is entirely the CEO's (ACTIONABLE), so
// it is classified by the thing the CEO cannot do and carries the control for the thing he
// can.

"use strict";

module.exports = [
  {
    "s": "unsupported web push service; refused: {}",
    "c": "NOT-RENDERED",
    "why": "Internal PhoneError from the outbound Web Push allowlist. The Mac logs this refusal; the phone receives the existing generic API error. It is not rendered as a CEO instruction or a desktop state."
  },
  {"s":"Manage reply notifications in the RichOS iPhone app under Settings.","c":"ACTIONABLE","control":"#phone-close","fixture":null,"why":"Native preferences are on the phone. This Mac view names their exact location and retains the close control, like the existing phone-side Web Push instructions. phone.js check 9d proves the native instruction excludes Safari installation."},
  // Native notification API states.
  {"s": "Invalid notification registration", "c": "UNREACHABLE", "why": "Defensive duplicate validation inside the native notification desk. The authenticated route rejects malformed registrations before calling it and the native adapter supplies fixed bundle/environment values."},
  {"s": "Native notifications are unavailable", "c": "UNREACHABLE", "why": "Default bridge refusal. Production overrides it and routes refuse unsupported native-push capability before calling the default."},
  {"s": "Reply notifications could not reach the service. Your conversation still works. Retry notifications in settings.", "c": "ACTIONABLE", "control": "#notifications-refresh", "fixture": null, "why": "Phone notification setup failure. The native settings view contains Retry notifications alongside its status; shared client tests prove that failure does not disable text."},
  {"s": "This phone is no longer paired.", "c": "INFORMATIONAL", "why": "A registration racing revocation is rejected. No notification registration is retained for the revoked device. The route translates it to a bounded failure response."},

  // Native phone voice API states.
  {"s": "I could not hear speech in that recording. Your recording is still on your phone.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "I could not transcribe that recording. Your recording is still on your phone.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "I could not understand that recording. Your recording is still on your phone.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "This voice message exceeds the 30-minute sending limit. It has been kept on your phone.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "The recording exceeds the upload limit.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "This recording is not a supported WAV file.", "c": "ACTIONABLE", "control": "#record-start", "fixture": null, "why": "Authenticated phone voice refusal. The native conversation keeps the microphone, queued-message recovery and typed composer available in the same view. Mobile client voice checks cover retained files and no dispatch on cancellation; the Mac renderer does not display this phone API response."},
  {"s": "Audio playback is unavailable. The reply remains in the conversation.", "c": "INFORMATIONAL", "why": "Playback failure leaves the already visible reply readable. No setup action is required to continue the conversation."},
  {"s": "This reply is not available for playback.", "c": "INFORMATIONAL", "why": "Playback failure leaves the already visible reply readable. No setup action is required to continue the conversation."},
  {"s": "Audio playback is unavailable", "c": "UNREACHABLE", "why": "Bridge default for test or unsupported implementations. The production PhoneBridge overrides this method and unsupported capabilities prevent dispatch."},
  {"s": "Speech recognition is unavailable", "c": "UNREACHABLE", "why": "Bridge default for test or unsupported implementations. The production PhoneBridge overrides this method and unsupported capabilities prevent dispatch."},
  {"s": "This reply is too long for audio playback. The complete reply is in the conversation.", "c": "INFORMATIONAL", "why": "The complete reply is already displayed in the conversation. Reading it requires no hidden action or navigation."},
  {"s": "Speech recognition is not ready on this Mac. Whoever set RichOS up needs to prepare it. Your recording is still on your phone.", "c": "NEEDS-SOMEONE-ELSE", "party": true, "fixture": null, "why": "The Mac speech prerequisite needs its operator. The phone retains the recording and its typed composer remains available."},

  // -------------------------------------------------------------------------------------
  // ACTIONABLE
  // -------------------------------------------------------------------------------------
  {
    s: "Anything I'd written is above. Your message is safe — I'll put it back in the box for you.",
    c: "ACTIONABLE",
    control: ".tl-intervention--quiet button.tl-intervention-action",
    fixture: "unknown-turn",
    why: "§14's unknown-outcome card. Offers to restore his message; the button is in the card.",
  },
  {
    s: "This turn was still running the last time RichOS was open, and I can't tell you how it ended.",
    c: "ACTIONABLE",
    control: ".tl-intervention--quiet button.tl-intervention-action",
    fixture: "unknown-turn",
    why: "The same card's body. The outcome is unknowable; picking the message back up is his move.",
  },
  {
    s:
      "Not now is fine. I'll leave the message box switched off until you pick one, and " +
      "the button to do it stays right there.",
    c: "ACTIONABLE",
    control: "#entity-picker-later",
    fixture: null,
    why:
      "The cost of deferring the first-run company question — the 2026-09-17 nightly's D5. " +
      "First run stacked three sheets and this was the one with no \"Not now\" on it; the " +
      "audit called it \"at least inconsistent and at most a wall\". The control it names is " +
      "the deferral itself, because this sentence is about what pressing THAT does. It is " +
      "modelled on the interview offer, which the audit singled out for saying what its own " +
      "\"Not now\" costs — and the cost here is the opposite one: the question returns, " +
      "because he cannot type until it is answered. Driven by ui/tests/setup.js check 1a, " +
      "which also asserts the composer is still blocked and #composer-choose-company still " +
      "on screen afterwards, so deferring can never become the §21 armed-composer leak.",
  },
  {
    s: "I hit a snag mid-thought and had to stop before I finished.",
    c: "ACTIONABLE",
    control: ".tl-intervention button.tl-intervention-action",
    fixture: "failed-turn",
    why:
      "§5.5 failure card. 'Say the word' is answered by the button directly beneath it. " +
      "STILL REACHABLE AFTER 2026-09-17, and deliberately: it is now the FALLBACK, shown " +
      "only for a turn whose cause was never classified — every record written before that " +
      "date, and any record whose classification could not be written. The five rows below " +
      "are what a turn with a known cause gets instead.",
  },

  // -----------------------------------------------------------------------------------
  // WHY A TURN ENDED WITHOUT FINISHING — richos-core `interruption.rs`, the nightly's D2
  //
  // `docs/verification/2026-09-17-nightly-1.2.0-20260917.1-onscreen-audit.md` §D2: the
  // published nightly held `Not logged in · Please run /login` in its own ledger and showed
  // the generic card above it — a permanent condition called a snag, a promise about saved
  // work that did not exist, and a retry that could not succeed.
  //
  // `fixture: null` on all five, for the reason the richos-voice rows above it give: these
  // sentences are produced by a CLASSIFIED interruption, which the mock bridge does not
  // reach — it has no lease and therefore no `CognitionError` to classify. They are driven
  // directly, against the real renderer, by `ui/tests/interruption.js`, which asserts each
  // one's control (or its deliberate absence) on the rendered card.
  // -----------------------------------------------------------------------------------
  {
    s:
      "I couldn't start that, because I'm not connected to your Anthropic account right " +
      "now — either nobody has signed in on this Mac yet, or the sign-in ran out. You can " +
      "connect it in Settings, under Account connection, and then send this to me again.",
    c: "ACTIONABLE",
    control: "#rail-settings",
    fixture: null,
    why:
      "`InterruptionCause::NotSignedIn`. HIS to fix, which is why it is ACTIONABLE and not " +
      "NEEDS-SOMEONE-ELSE: the account is his and the screen exists. The audit's third " +
      "finding was that the app never mentioned the account at all 'even though the app " +
      "offered to connect one on first run, knows it was declined, and has a working route " +
      "to it'. The control is the rail's settings button, which is on screen in every view " +
      "this card can appear in, and the sentence itself names the route in words. It was TWO sentences briefly, the second returned by a `route()` method — deleted because under app/crates this registry can only see literals inside a function called `ceo_message`, so a route authored anywhere else would reach his screen while being invisible to the one inventory that asks whether he can act on what he is told.",
  },
  {
    s:
      "I couldn't start that. There is an account credential set up on this Mac and " +
      "Anthropic turned it down, so the request never left the machine. This one needs " +
      "whoever set RichOS up — it isn't something you can fix from here, and asking me " +
      "again won't change it.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "`InterruptionCause::CredentialRejected`, and a DIFFERENT class from the sign-in row " +
      "on purpose: the four vendor constants behind it (`Invalid API key`, `Invalid auth " +
      "token`, `Invalid ANTHROPIC_CUSTOM_HEADERS`, `Invalid request header from the " +
      "environment`, read verbatim out of the installed bundle) describe a credential in " +
      "this machine's ENVIRONMENT. Sending him to the account screen would send him " +
      "somewhere that cannot help. It names the party and offers no control, which is the " +
      "honest shape for a state he does not own.",
  },
  {
    s:
      "I couldn't start that. The copy of Claude Code RichOS tried to run isn't on this Mac " +
      "where I expected it, so there was nothing here to think with. This one needs whoever " +
      "set RichOS up — it isn't something you can fix from here, and asking me again won't " +
      "change it.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "`InterruptionCause::ProviderMissing` — the 2026-09-17 candidate-walk defect. " +
      "`resolve_claude_bin` used to fall through to a bare `claude` that a Finder-launched " +
      "provider's own replaced PATH could never resolve, and the resulting failure " +
      "(`provider-supervisor.py`'s own `Provider could not start: [Errno 2] No such file or " +
      "directory`) was misclassified as `Transient`, promising a retry that could never work. " +
      "A DIFFERENT class from the credential row above for the same reason that row is " +
      "different from the sign-in row: the CEO's own account is fine, and the fix (installing " +
      "or pointing at Claude Code) is whoever set RichOS up's to make, not his.",
  },
  {
    s: "Stopped, as you asked. Nothing is running, and nothing of yours was lost.",
    c: "INFORMATIONAL",
    fixture: null,
    why:
      "`InterruptionCause::StoppedByCeo`. Nothing failed, so there is nothing to retry and " +
      "no control belongs on the card — a control that hands his words back would dress his own " +
      "deliberate stop as an error. It issues no instruction and asks for nothing.",
  },
  {
    s:
      "I lost my connection to the part of me that thinks, partway through. That kind of " +
      "thing usually clears on its own, so asking again is worth a try.",
    c: "ACTIONABLE",
    control: ".tl-intervention button.tl-intervention-action",
    fixture: null,
    why:
      "`InterruptionCause::Transient` — the ONE class where asking again is honest advice, " +
      "and therefore the one that still draws the card's button. It is the positive control " +
      "for the whole change: without a class that keeps the control, 'the sign-in case has " +
      "no button' could just mean the card stopped drawing one.",
  },
  {
    s:
      "That stopped before I finished, and I can't tell you why — I don't recognize what " +
      "came back. Asking again is reasonable; if it stops the same way, it needs whoever " +
      "set RichOS up.",
    c: "ACTIONABLE",
    control: ".tl-intervention button.tl-intervention-action",
    fixture: null,
    why:
      "`InterruptionCause::Unknown`, the arm a reworded vendor string falls to. ACTIONABLE " +
      "rather than NEEDS-SOMEONE-ELSE because the first thing offered is his and is drawn " +
      "on the card; the named party is the second sentence, for when the first does not " +
      "work. It claims no cause it cannot support and points at no screen that might be " +
      "wrong.",
  },
  {
    s: "Rich stopped before finishing.",
    c: "ACTIONABLE",
    control: ".tl-intervention button.tl-intervention-action",
    fixture: "failed-turn",
    why:
      "The §18 announcement that mirrors the failure card. For a screen-reader user it is the " +
      "only signal, so the card's control must be in the DOM when it fires.",
  },
  {
    s: "Set your name",
    c: "ACTIONABLE",
    control: "#rail-identity",
    why:
      "The rail footer's honest unset state (CEO correction to round 10.1). There is no " +
      "user-name preference on a fresh install, so this is what almost every install shows, " +
      "and it is deliberately NOT an invented name or a '??' placeholder. It is ACTIONABLE " +
      "because it is an imperative aimed at the reader, and the control is the row itself — " +
      "in the unset state `#rail-identity` is a button that opens the preferences popover " +
      "where the field lives. Once a name is set the row stops being a control and the " +
      "string stops rendering, which is the correct pairing in both directions.",
  },
  {
    s: "No name is set. Open preferences to add yours.",
    c: "ACTIONABLE",
    control: "#rail-identity",
    why:
      "The accessible name of the same row, and for a screen-reader user it is the whole " +
      "message — the empty initials circle is `aria-hidden`. Same control, stated longer " +
      "because a two-word label reads as a heading when it is announced alone.",
  },
  {
    s: "I can't hear anything. Check your mic isn't muted, then try again.",
    c: "ACTIONABLE",
    control: "#voice-retry",
    fixture: "voice-no-audio",
    why: "The mic is open and silent. He unmutes, then presses the control this line names.",
  },
  {
    s: "I couldn't record that stop, so I haven't acted on it. Press Stop again and I'll have another go.",
    c: "ACTIONABLE",
    control: "#stop",
    fixture: "working-turn",
    why: "Only reachable with a live turn, which is exactly when syncComposerMode shows Stop.",
  },
  {
    s: "I couldn't take that down while I was working — it's back in the box below, nothing lost.",
    c: "ACTIONABLE",
    control: "#send",
    fixture: "working-turn",
    why: "§9.2 steering refused. The words are restored; Send is what sends them again.",
  },
  {
    s: "I couldn't start that thread just now. Your words are still in the box below — press Send to try again.",
    c: "ACTIONABLE",
    control: "#send",
    fixture: "thread-create-refused",
    why: "create_thread_in refused. Entity view, sendBlockedReason null, so Send is live.",
  },
  {
    s: "Your words are back in the box below, word for word — press Send when you want me to try again.",
    c: "ACTIONABLE",
    control: "#send",
    fixture: "not-connected",
    why: "The second half of every refused send. Names the control that retries.",
  },
  {
    s: "Nothing matches that.",
    c: "ACTIONABLE",
    control: "#search-input",
    fixture: "search-empty",
    why: "A search with no hits. The field he retypes into is the affordance, and it is focused.",
  },
  {
    s: "I can't find a microphone on this machine — plug one in and tap ◉ again.",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why: "Precise instruction naming ◉, which is #talk-toggle and never hides (index.html:150).",
  },
  {
    s: "I couldn't open the microphone. In System Settings, under Privacy and Security, give RichOS microphone access — then tap ◉ again.",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why: "Names the settings pane AND the control to press afterwards.",
  },
  {
    s: "This microphone gives me audio I can't work with — pick a different one in System Settings, under Sound, then tap ◉ again.",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why: "There is no device picker in RichOS, so the instruction names the one that exists.",
  },
  {
    s: "I can't reach the speakers on this machine, so I'll keep answering in text. Plug in headphones or speakers and tap ◉ again if you want me talking.",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why: "Every PlayoutError variant is a missing or unusable output device. Plugging one in is his.",
  },
  {
    s: "The mic still won't open. I've switched us back to typing — tap ◉ when you want to try voice again.",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why: "Said after #voice-retry fails and voice mode is torn down. ◉ is the way back in.",
  },
  {
    s: "I didn't catch that — say it again?",
    c: "ACTIONABLE",
    control: "#talk-toggle",
    fixture: "shell",
    why:
      "The mic is already open, so the action is simply to speak; ◉ is present either way and " +
      "is the control if he would rather stop.",
  },
  {
    s: "ended with an error",
    c: "ACTIONABLE",
    control: ".nav-thread",
    fixture: "rail-mark",
    why:
      "A rail status mark. The mark is appended INSIDE the thread's own <button> " +
      "(main.js buildThreadRow), so the affordance is structural: the state cannot render " +
      "outside the control that opens the thread carrying it.",
  },
  {
    s: "last turn ended without finishing",
    c: "ACTIONABLE",
    control: ".nav-thread",
    fixture: "rail-mark",
    why: "Same structural affordance as 'ended with an error'.",
  },
  {
    s: "outcome unknown — a turn never finished",
    c: "ACTIONABLE",
    control: ".nav-thread",
    fixture: "rail-mark",
    why: "Same structural affordance. Opening the thread reaches §14's card, which has the button.",
  },

  // THE OTHER NO-LEASE CAUSE, and the reason it is ACTIONABLE where the sentence above it is
  // NEEDS-SOMEONE-ELSE. Nothing is signed out here; something was never installed, and the
  // app can install it. ray-opus-a2 met this state on published v1.0.1 and was handed the
  // sentence below instead — "quit and reopen" on a machine with no engine, which the next
  // boot would fail in exactly the same way.
  {
    s: "I can't take that on yet — the RichOS engine isn't on this Mac, and that's the part of me that knows how I work. I've put the setting up back on your screen: press Set it up and I'll fetch it. There's nothing to quit and nothing to reopen.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-refused-engine",
    why:
      "He can fix this himself, in one press, without leaving the window. The sheet is " +
      "reopened by the same catch that renders the notice, so the control the sentence " +
      "names is on screen when he reads it.",
  },
  {
    s: "I can't take that on yet — Claude Code isn't on this Mac, and that's the program I think with. I've put the setting up back on your screen: press Set it up and I'll fetch it. There's nothing to quit and nothing to reopen.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-refused-claude",
    why: "Same state, other component. A Mac set up once and since had its binary removed.",
  },
  {
    s: "I can't take that on yet — this Mac doesn't have Claude Code or the RichOS engine, and those are what I think with. I've put the setting up back on your screen: press Set it up and I'll fetch them. There's nothing to quit and nothing to reopen.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-refused-both",
    why: "The customer's Mac on the day he installs, after he answers the sheet with 'Not now'.",
  },
  {
    s: "Your words are back in the box below, word for word — they'll be there when the setting up is done.",
    c: "FRAGMENT",
    why:
      "Appended to the three sentences above, and only to those. The ordinary tail names " +
      "Send; this one deliberately does not, because the setup sheet is covering the " +
      "composer at the moment he reads it and an instruction he cannot follow is worse " +
      "than none.",
  },

  // -------------------------------------------------------------------------------------
  // NEEDS SOMEONE ELSE
  // -------------------------------------------------------------------------------------
  {
    s: "I'm not connected to my thinking right now, so I can't take that on. Quit RichOS and open it again — that clears it most of the time. If it keeps happening, whoever set RichOS up has to sign me back in; that part isn't yours to fix.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    control: "#send",
    fixture: "not-connected",
    why:
      "Two contexts in one sentence, and both are stated. Quitting and reopening is his and " +
      "needs no control; signing the lease back in is not, and is named as somebody else's. " +
      "Send is required because the same notice restores his words.",
  },
  {
    s: "I've taken that down, but I haven't got a thread open to show it in. Quit RichOS and open it again; if it still isn't here, whoever set RichOS up needs to look.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "send_message's no-active-thread path. Not drivable from the browser harness: it needs a " +
      "boot where boot_entity() resolves to None, which the mock bridge cannot produce.",
  },
  {
    s: "I can't open this one. It has no entity home — it predates entity scoping, and I won't guess which entity this work belongs to. Filing it under the wrong one would mix up two companies' records, and that's not a mistake worth risking to save you a question.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "the detail line beneath it, which names whoever set RichOS up",
    control: "#unbound-new-thread",
    fixture: "unbound",
    why: "§21's body. He cannot bind the thread; he can start the work again where it belongs.",
  },
  {
    s: "Filing it under a company is a job for whoever set RichOS up — there is no control for it in the app yet, so it will not sort itself out. Meanwhile the button above starts a fresh thread wherever you say, and I'll carry on there.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    control: "#unbound-new-thread",
    fixture: "unbound",
    why: "The line that names the party and points at the way out. 'The button above' must exist.",
  },
  {
    s: "This thread has no entity home: it predates entity scoping, and Rich will not guess which entity this work belongs to. An operator must bind it explicitly.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    control: "#unbound-new-thread",
    fixture: "unbound",
    why:
      "The CORE's own wording, relayed verbatim so the screen and the guard cannot drift " +
      "(main.rs:915 <- ledger.rs:52). 'An operator' is the party; the CEO-legible restatement " +
      "follows it in the same paragraph.",
  },
  {
    s: "This thread has no entity home, so I can't take a message in it.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "#unbound-view-detail, in the same view",
    control: "#unbound-new-thread",
    fixture: "unbound",
    why: "The composer-blocked line. Deliberately short; the screen above it carries the who.",
  },
  {
    s: "Send is off for this thread",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "#unbound-view-detail, in the same view",
    control: "#unbound-new-thread",
    fixture: "unbound",
    why:
      "The disabled composer's placeholder. §21: an inviting placeholder over a dead field is " +
      "the composer telling a small lie, so it states the block instead.",
  },
  {
    s: "Needs an entity",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "#unbound-view, which every row in this group opens",
    control: ".nav-group--unbound .nav-thread",
    fixture: "rail-mark",
    why: "The rail group heading. Two words; the destination screen carries the party and the way out.",
  },
  {
    s: "no entity home",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "#unbound-view, which the row carrying this mark opens",
    control: ".nav-thread",
    fixture: "rail-mark",
    why: "The rail status mark for an unbound thread, rendered inside the row's own button.",
  },
  {
    s: "I can't show priorities for this area yet, and the area itself is set up inside RichOS rather than in settings — whoever set RichOS up is the one who changes it. Nothing here needs you.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: "entity-view",
    why:
      "No control, correctly: there is nothing here for him to press. A NEEDS-SOMEONE-ELSE " +
      "state owes a party and a next step, not an affordance, and it closes the loop explicitly.",
  },
  {
    s:
      "I can hear sound, but I'm not getting words out of it — the microphone may be " +
      "picking up the room rather than you. Voice is still on.",
    c: "INFORMATIONAL",
    why:
      "`VoiceNotice::SoundButNoWords`, added 2026-09-04. Three utterances in a row came " +
      "back as whisper's documented silence noise, which is the ONE path in the recognizer " +
      "thread that used to produce nothing at all: an utterance in, an eprintln out, and " +
      "the panel still saying \"listening…\". Ray measured 25+ seconds of exactly that on " +
      "published v1.0.0. It is INFORMATIONAL rather than ACTIONABLE deliberately — it " +
      "invents no control, because the ◉ that ends voice is already on screen with its own " +
      "footnote two lines below the notice, and a sentence pointing at a control that is " +
      "already offered is a request wearing a status's clothes.",
  },
  {
    s:
      "That didn't come through as speech, so I haven't sent anything. I'm still " +
      "listening.",
    c: "INFORMATIONAL",
    why:
      "`VoiceNotice::HeardNoVoice`, added 2026-09-05. The audio-grounded gate in " +
      "`crates/richos-voice/src/voiced.rs` measured the recording and found no voice in " +
      "it, so whisper was never called and nothing was submitted. It exists because the " +
      "alternative shipped: on 2026-09-04, on published v1.0.1, on the CEO's own Mac, a " +
      "tap on the talk button in a quiet room produced \"1, 2, 3, testing.\" and the app " +
      "SENT IT as his message (ray-opus-a2). " +
      "Two things are load-bearing in the wording. It says nothing was sent, because the " +
      "defect being fixed is the app sending a sentence he never said and a refusal that " +
      "leaves that question open is no better than the drop. And it ends with a status " +
      "rather than \"say it again\": the affordance for repeating himself is the open " +
      "microphone, there is no button to point at, and an imperative with no control is a " +
      "request wearing a status's clothes — the same reason `SoundButNoWords` ends with " +
      "\"Voice is still on.\" It is latched per run of refusals, so it states the refusal " +
      "once and never becomes a drip.",
  },
  {
    s:
      "While I was speaking, I couldn't tell your voice from my own — so if you said " +
      "something just then, it didn't reach me and I haven't sent anything. I'm listening now.",
    c: "INFORMATIONAL",
    why:
      "`VoiceNotice::CouldNotListenWhileSpeaking`, added 2026-09-17 for audit-3 §4 #1 and " +
      "REWRITTEN the same day after Ray's candidate-.4 walk proved the first wording false " +
      "on the CEO's own rig. It used to read \"You started talking while I was still " +
      "speaking…\" and it fired at him while he was provably silent: at output volume 85 a " +
      "spoken turn produced it with nobody talking, and the identical turn with the output " +
      "volume set to 0 produced no discard and no notice at all. The single variable was " +
      "whether Rich's own voice was audible in the room. " +
      "THE CODE SAYS THE SAME THING STRUCTURALLY. `push_residual` sets `tainted = speaking " +
      "&& !barged && !confident`, so a tainted discard REQUIRES the canceller to have " +
      "declined to vouch for its residual; when it IS confident the utterance is admitted " +
      "rather than discarded and there is nothing to announce. The old sentence was " +
      "therefore emitted only, and exactly, on the path where the app cannot know whose " +
      "voice it heard — so the accusation was deleted rather than gated behind a condition " +
      "that never occurs. " +
      "EVERY CLAUSE ABOUT THE CEO IS NOW CONDITIONAL (\"if you said something just then\"), " +
      "and what it asserts outright is only what this file can prove: Rich was speaking, the " +
      "two voices could not be separated, and that audio was not used. " +
      "AND IT IS NOT A WARM-UP STATE ON HIS HARDWARE. Measured on his Mac on 2026-09-17 " +
      "(docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md): Mac mini Speakers out, " +
      "Elgato Wave:3 in, steady-state ERLE of −0.5 to +0.7 dB across five live runs — nothing " +
      "measurably removed — while confidence needs the residual to hold under −52.04 dBFS and " +
      "the microphone reads −42 to −46 dBFS during Rich's speech. A recording of that exact " +
      "path is committed as a test fixture and replays under `cargo test` without reaching " +
      "confidence, so every spoken answer through the speakers produces one of these " +
      "discards. " +
      "INFORMATIONAL, and it still makes NO capability claim: \"I can't hear you while I'm " +
      "speaking\" would be false twice, because talking over him for 5.008 s cuts him off " +
      "today and a confident canceller admits the utterance outright. It still states the " +
      "consequence, because the failure it explains is the app sending the TAIL of his " +
      "sentence as though it were the whole of it. It ends with a status rather than \"wait " +
      "until I finish\", which would be an instruction to use the product more carefully to " +
      "work around a limitation. Latched ONCE PER VOICE SESSION (`RefusalNotices`), not " +
      "per run: cleared-on-heard would mean one line after every single spoken answer, " +
      "forever, about a condition nothing he does can change. " +
      "AND SINCE 2026-09-17 IT SPENDS ONE BUDGET WITH THE THREE RECOGNIZER LINES. Ray's " +
      "candidate-.6 walk found THREE cards stacked on the first spoken answer of a voice " +
      "session while the CEO had said nothing, because each of the three latches honored " +
      "\"at most once\" independently, in two different threads. This is the strongest " +
      "sentence in that family, so it is the one that stands and the other two cannot add " +
      "themselves on top of it.",
  },
  {
    s: "I didn't catch that, so I haven't sent anything. I'm still listening.",
    c: "INFORMATIONAL",
    why:
      "`VoiceNotice::DidNotCatchThat`, added 2026-09-17 for audit-3 §4 #4. Whisper RAN and " +
      "returned non-speech noise — `(clears throat)` — which `stt::is_meaningful` refuses. " +
      "It closes an ASYMMETRY between the two refusal paths that sit side by side in " +
      "`RecognizerDesk::handle`: the pre-whisper gate in `voiced.rs` spoke on the FIRST " +
      "refusal (`HeardNoVoice`, above), while this path said nothing at all until the THIRD " +
      "in a row (`SoundButNoWords`). So the case where he definitely DID speak — a voice was " +
      "measured, a stronger signal than the pre-whisper path ever has — was the quieter of " +
      "the two. Ray walked it on the CEO's screen at frame `a3-15`: a 2.3 s utterance, and " +
      "\"the window did not change at all\", leaving him unable to tell \"not heard\" from " +
      "\"heard and discarded\" from \"broken\". " +
      "INFORMATIONAL for the reason its two neighbors are: it invents no control, because " +
      "the affordance for saying it again IS the open microphone and there is no button to " +
      "point at — so it ends with a status, in the same three words `HeardNoVoice` ends " +
      "with, rather than an imperative aimed at a reader. It is latched per run of discards " +
      "and cleared by an admitted utterance that was also UNDERSTOOD, so it states the " +
      "discard once and never becomes a drip; at the third discard `SoundButNoWords` takes " +
      "over and this line stands aside, so a run produces two sentences in total and never " +
      "two at once. Since 2026-09-17 it also cannot follow `HeardNoVoice` for one noise " +
      "(audit-5 #8, the double card) or follow the half-duplex line at all: the four share " +
      "one budget and only a STRICTLY stronger sentence replaces the one standing. It rides " +
      "`rich://voice-notice`, not `rich://voice-error`: nothing failed and voice did not " +
      "stop, and the notice listener in main.js is the only one of the four that is not " +
      "suppressed when the voice panel is closed.",
  },

  // ---- hardware.rs — which recognizer this machine got, said once at voice-mode start ---
  //
  // `Resolution::ceo_message()` at hardware.rs:358-380, relayed as `rich://voice-notice`
  // (event.rs:31) and rendered by main.js's listener through `richVoiceSays` — one of Rich's
  // own lines in the thread. It is silent on `Basis::TopRung` and `Basis::Override`, so these
  // three are the only sentences it can say. Added by echo-opus-hw1 (978a34ab) without rows
  // here, which is what turned `affordances.js` red on main from c1df6f24; classified by
  // echo-opus-ci1. All three are INFORMATIONAL for the reason `SoundButNoWords` is: the
  // product made a choice for him and is saying so, it asks nothing, and there is no setting
  // that overrides it — the only lever, turning voice off and on with ◉, re-runs the same
  // resolution and is already on screen, and the one sentence that relies on it says so
  // itself rather than instructing him.
  {
    s:
      "I'm using my faster hearing on this machine. The more accurate one takes long enough " +
      "here that you'd be waiting after every sentence, and a conversation with pauses in it " +
      "isn't a conversation. You can still say anything you like — I just might misread an " +
      "unusual name now and then.",
    c: "INFORMATIONAL",
    why:
      "`Basis::TooSlow` (hardware.rs:361). A better rung exists and this machine decodes it " +
      "too slowly — measured, per hardware.rs:288. Nothing about it is his to change — it " +
      "is a fact about the hardware — and 'You can still say anything you like' is " +
      "reassurance, not an instruction.",
  },
  {
    s:
      "I'm using my lighter hearing on this machine — there isn't enough free memory right " +
      "now for the more accurate one, and I'd rather not slow everything else down. You can " +
      "still say anything you like.",
    c: "INFORMATIONAL",
    why:
      "`Basis::TooLarge` (hardware.rs:368). The one of the three he could in principle " +
      "influence, by freeing memory, and the sentence deliberately does not ask him to: " +
      "'right now' is a statement of the reading, resolution re-runs at every voice-mode " +
      "start, and a request to go and close applications would be an instruction with no " +
      "control in the app to answer it.",
  },
  {
    s:
      "I couldn't work out how fast this machine hears, so I've started with the setting " +
      "that works everywhere. I'll check again next time you turn voice on.",
    c: "INFORMATIONAL",
    why:
      "`Basis::Unmeasured` (hardware.rs:374). Nothing could be measured — no probe, no " +
      "binary, no cache (hardware.rs:292) — so the resolver took the safe rung. The retry is the product's " +
      "('I'll check again'), triggered by the ◉ voice toggle that is already on screen — " +
      "named as a time, not issued as a command.",
  },
  {
    s: "My ears aren't installed on this machine yet — whoever set RichOS up adds those. I can still read what you type.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "Needs a real SttError::BinaryNotFound from a live pipeline; the mock bridge does not " +
      "reach richos-voice. The fallback it names (typing) is the composer, always present.",
  },
  {
    s:
      "My speech model isn't on this machine yet. I can fetch it myself now, so I'll offer " +
      "to download it the next time you turn voice on. I can still read what you type.",
    c: "INFORMATIONAL",
    why:
      "SttError::ModelNotFound (stt.rs:112), split from BinaryNotFound's row above on " +
      "2026-09-17 — the nightly QA audit's §D2 — the day it stopped being true that nobody " +
      "but 'whoever set RichOS up' could close this gap. `crate::provision` (landed " +
      "516975db) fetches the model itself, so this one names no party and states what " +
      "happens next instead, phrased like the `Basis::Unmeasured` row above: a retry tied " +
      "to the ◉ voice toggle already on screen, never a command aimed at the reader. Needs " +
      "a real SttError::ModelNotFound from a live pipeline; the mock bridge does not reach " +
      "richos-voice, same as the row above.",
  },
  {
    s: "Something about my hearing changed on this machine and I'd rather not guess at what you said than get it wrong. Whoever set RichOS up can put it right. I can still read what you type.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "`SttError::ToolchainRefused` at stt.rs:74, and DIFFERENT WORDS from the row above on " +
      "purpose — its own comment says why: the transcriber is installed and refused, so " +
      "'not installed yet' would be false and would send whoever helps him to install " +
      "something already there. Same class, same named party, same always-present fallback. " +
      "No fixture for the same reason as its neighbour: the mock bridge does not reach " +
      "richos-voice, so only a live pipeline produces this variant.",
  },
  {
    s: "My voice isn't working on this machine — whoever set RichOS up would need to look at that. I'll keep answering in text.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why: "Same: a real TtsError from a live pipeline, unreachable from the browser harness.",
  },

  // -------------------------------------------------------------------------------------
  // INFORMATIONAL
  // -------------------------------------------------------------------------------------
  {
    s: "Active time from when Rich accepted the message to when the turn ended.",
    c: "INFORMATIONAL",
    why: "The duration row's accessible description. States a measure; asks nothing.",
  },
  {
    s: "Added while Rich was working",
    c: "INFORMATIONAL",
    why: "§9.2's cue on a steering bubble. A fact about ordering.",
  },
  {
    s: "Anything I'd written is above. Nothing of yours was lost.",
    c: "INFORMATIONAL",
    why:
      "§14's card when there is no message to restore. Deliberately carries NO control: a " +
      "that puts nothing back is worse than none.",
  },
  {
    s: "Everything I'd already written above is saved.",
    c: "INFORMATIONAL",
    why: "The note inside the failure card. The card's body carries the action.",
  },
  {
    s: "How long it ran was not recorded — the turn ended without writing an end time.",
    c: "INFORMATIONAL",
    why: "A statement about what the ledger holds. Nothing anyone can do.",
  },
  {
    s: "How long this took was not recorded.",
    c: "INFORMATIONAL",
    why: "A completed turn whose activeMs never made it to disk. Nothing recovers it after the fact.",
  },
  {
    s: "This turn was still running when RichOS last closed, and nothing recorded how it ended.",
    c: "INFORMATIONAL",
    why: "The duration row's tooltip. The card beneath it is where the action lives.",
  },
  {
    s: "I've noted that you stopped this. I couldn't interrupt the work already in flight, so it may finish on its own — nothing new will start.",
    c: "INFORMATIONAL",
    why:
      "Reports a durable fact and claims nothing further. Correctly offers no control: the stop " +
      "IS recorded, and pressing it again would change nothing.",
  },
  {
    s: "Your stop is recorded. Rich is letting go of this turn.",
    c: "INFORMATIONAL",
    why: "The stopping row's description. In flight; nothing to press.",
  },
  { s: "You stopped it", c: "INFORMATIONAL", why: "§6.1's attribution label." },
  { s: "You stopped it.", c: "INFORMATIONAL", why: "The §18 announcement of the same." },
  {
    s: "Stopped before it finished",
    c: "INFORMATIONAL",
    why: "The duration label. The failure card renders beside it and carries the control.",
  },
  {
    s: "Rich started working",
    c: "INFORMATIONAL",
    why: "§18's once-per-turn announcement.",
  },
  { s: "Rich is speaking", c: "INFORMATIONAL", why: "Voice state. #voice-barge-in sits beside it anyway." },
  { s: "Rich reached out", c: "INFORMATIONAL", why: "§5.2 proactive marker." },
  {
    s: "The spawn was accepted. Nothing has reported back yet.",
    c: "INFORMATIONAL",
    why:
      "Worker state note. FLAGGED FOR URBAN, not changed here: 'spawn' is machinery vocabulary " +
      "on a §7.2 surface the CEO reads, and that is a copy decision, not an affordance defect.",
  },
  {
    s: "This run is open — no end has been recorded for it.",
    c: "INFORMATIONAL",
    why: "Worker state note.",
  },
  {
    s: "This run has ended. Nothing recorded whether the work finished, stopped or failed — so I'm not going to call it either way.",
    c: "INFORMATIONAL",
    why: "The `unknown` worker note. Refuses a verdict; asks nothing.",
  },
  {
    s: "This run has ended. Nothing recorded whether the work finished, was cut short or failed — so I'm not going to call it either way.",
    c: "INFORMATIONAL",
    why: "The inspector's copy of the same statement.",
  },
  {
    s: "This run was first seen already underway, so no display name was recorded for it.",
    c: "INFORMATIONAL",
    why: "Explains an absent name.",
  },
  {
    s: "This worker reported a state RichOS does not know how to read.",
    c: "INFORMATIONAL",
    why: "The unrecognized-state fallback. Nothing for the CEO to do about a protocol surprise.",
  },
  {
    s: "I don't have this worker's brief, its output or the files it touched — nothing records those yet, and I'd rather say so than show you a blank.",
    c: "INFORMATIONAL",
    why:
      "§7.2's honest empty pane. Two contexts, and the row states the one that matters: nothing " +
      "the CEO can do. That it is also future engineering work is true and is not his to chase, " +
      "and the sentence does not imply it is.",
  },
  {
    s: "I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from there.",
    c: "INFORMATIONAL",
    why:
      "First-run greeting. An invitation, not a state he could change, and it names the " +
      "control it invites (#input).",
  },
  {
    s: "You can type, or tap ◉ to talk to me.",
    c: "INFORMATIONAL",
    why:
      "The voice half of the first-run greeting, SPLIT OFF on 2026-09-04 and appended only " +
      "when `voice_readiness` says this machine can transcribe. It was one sentence with " +
      "the line above, and on a fresh Mac with no speech model it named a control that " +
      "opened a hot microphone, said \"listening…\" and never transcribed. A sentence that " +
      "names a control is a promise the control works, so it is now withheld with the " +
      "control rather than shipped beside its absence.",
  },
  {
    s: "Talking out loud needs the desktop app — here in the preview, type to me.",
    c: "INFORMATIONAL",
    why:
      "Browser-preview only: reachable solely when Bridge.isMock. Never renders in the shipped " +
      "app, and the composer it points at is on screen.",
  },
  { s: "Edited a file", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Ran a command", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Set up the environment", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Updated a thread", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Used an integration", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Used the web", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "Viewed an image", c: "INFORMATIONAL", why: "§5.3 activity rollup label." },
  { s: "name not recorded", c: "INFORMATIONAL", why: "Worker chip qualifier." },
  { s: "outcome not recorded", c: "INFORMATIONAL", why: "Worker chip qualifier." },
  { s: "new result ready", c: "INFORMATIONAL", why: "Rail mark: navigational, nothing broken." },
  { s: "Time spent working", c: "INFORMATIONAL", why: "Inspector field label." },

  {
    s: "Shown at the foot of the rail, with your initials.",
    c: "INFORMATIONAL",
    why:
      "Sits under the 'Your name' field and says what setting it does. It is not a request — " +
      "the imperative is on the rail row that sent him here, and this line is the consequence " +
      "of the field he is already looking at.",
  },

  // -------------------------------------------------------------------------------------
  // CONTROL — the string is an affordance, not a state that needs one
  // -------------------------------------------------------------------------------------
  { s: "+ New thread", c: "CONTROL", why: "#rail-new-thread." },
  { s: "Start a new thread instead", c: "CONTROL", why: "#unbound-new-thread — §21's way out." },
  {
    s: "Put it back in the box",
    c: "CONTROL",
    why:
      "`timeline.js`'s RETRY_LABEL — the one control on both intervention cards. It read " +
      "\"Pick it back up\" until the 2026-09-17 nightly's D6 measured what pressing it did: " +
      "his text went back in the composer, with no new turn and no log line. The behavior " +
      "is right (resending spends his subscription and starts work, so it is his to " +
      "trigger) and the words were the defect, so the label is now what it does.",
  },
  { s: "Jump to latest", c: "CONTROL", why: "#jump-latest accessible name." },
  { s: "Close worker details", c: "CONTROL", why: "#inspector-close accessible name." },
  { s: "open worker details", c: "CONTROL", why: "Worker chip accessible name." },
  { s: "Copy Rich's message", c: "CONTROL", why: "Copy button accessible name." },
  { s: "Copy your message", c: "CONTROL", why: "Copy button accessible name." },
  { s: "Hide what Rich did.", c: "CONTROL", why: "Duration-row disclosure accessible name." },
  { s: "Show what Rich did.", c: "CONTROL", why: "Duration-row disclosure accessible name." },
  { s: "Show what Rich did:", c: "CONTROL", why: "Collapsed-summary button accessible name." },
  { s: "Rename this thread", c: "CONTROL", why: "Thread overflow menu item." },
  { s: "Restore from archive", c: "CONTROL", why: "Thread overflow menu item." },
  { s: "Entities and threads", c: "CONTROL", why: "#rail accessible name." },
  { s: "Left navigation width", c: "CONTROL", why: "#rail-resizer accessible name." },
  { s: "Worker panel width", c: "CONTROL", why: "#inspector-resizer accessible name." },
  { s: "Under the hood", c: "CONTROL", why: "Slide-over title and its trigger." },
  { s: "back to Rich", c: "CONTROL", why: "#slideover-close." },
  { s: "How much should Rich interrupt you?", c: "CONTROL", why: "Assertiveness popover title over its radios." },
  { s: "Only when it's urgent", c: "CONTROL", why: "Assertiveness radio label." },
  { s: "Which company is this work in?", c: "CONTROL", why: "Entity picker title over its list. \"company\", never \"entity\" — Ray candidate-.11 §3.5." },
  { s: "Search entities, threads and conversations…", c: "CONTROL", why: "#search-input placeholder." },
  { s: "Talk to Rich", c: "CONTROL", why: "#talk-toggle title." },
  {
    s: "Message to Rich",
    c: "CONTROL",
    why:
      "#input's accessible name — candidate-.2 defect #7. The box had none and fell back to " +
      "its PLACEHOLDER, which is state: it reads 'Send is off until I know the company' while " +
      "a company block is up, so the control was renamed underneath a screen-reader user as " +
      "the app changed condition. The name holds still now and the placeholder carries the " +
      "state. Not 'Talk to Rich', which is #talk-toggle's name three rows up: two controls " +
      "with one name is the thing a screen reader cannot tell apart.",
  },
  { s: "Talk to Rich…", c: "CONTROL", why: "#input idle placeholder." },
  { s: "Add context or steer Rich…", c: "CONTROL", why: "#input working placeholder (§9.2)." },
  { s: "more threads in", c: "CONTROL", why: "'Show more' accessible name." },

  // -------------------------------------------------------------------------------------
  // FRAGMENT — half of a composed sentence, never rendered alone (blind spot B1)
  // -------------------------------------------------------------------------------------
  {
    s: "Everything I'm holding for",
    c: "FRAGMENT",
    why: "Entity overview line, completed with the entity name.",
  },
  {
    s: "Nothing here yet. I'll keep work for",
    c: "FRAGMENT",
    why: "Empty-entity line, completed with the entity name and 'in this area.'",
  },
  { s: "in this area.", c: "FRAGMENT", why: "The tail of the empty-entity line." },
  { s: "New thread in", c: "FRAGMENT", why: "Composer scope prefix and a group's 'new thread' accessible name." },
  { s: "Talk to Rich about", c: "FRAGMENT", why: "Composer scope prefix, completed with the entity name." },
  {
    s: "I couldn't get that to my desk just now, and nothing is running.",
    c: "FRAGMENT",
    why:
      "The generic first half of a refused send, used only when the backend supplied no " +
      "sentence of its own. Always rendered followed by the 'back in the box' half, which is " +
      "classified ACTIONABLE and carries the control.",
  },
  {
    s: "Press Stop again and I'll have another go.",
    c: "FRAGMENT",
    why: "Appended to the backend's own sentence in the failed-stop notice.",
  },
  { s: "You stopped after", c: "FRAGMENT", why: "Completed with a duration." },
  { s: "Set up the environment ( steps)", c: "FRAGMENT", why: "Template hole: the step count." },
  { s: "Used the web times", c: "FRAGMENT", why: "Template hole: the count." },
  { s: "Worked ( steps)", c: "FRAGMENT", why: "Template hole: the step count." },
  { s: "are no longer running", c: "FRAGMENT", why: "Worker group verb, completed with names." },
  { s: "is no longer running", c: "FRAGMENT", why: "Worker group verb, completed with a name." },
  { s: "headphones recommended · tap", c: "FRAGMENT", why: "Voice footnote, completed by the ◉ glyph." },
  { s: "to end voice", c: "FRAGMENT", why: "The tail of the same footnote." },


  // -------------------------------------------------------------------------------------
  // THE CORRECTION DESK (§7 "ask, never infer") — RICH-TODOs row 5b
  //
  // Two families on one surface, and the classification turns on a distinction the desk
  // itself is built around: `loro_available` false is a statement about THIS INSTALL that
  // nobody in the app can change (NEEDS-SOMEONE-ELSE), while a desk that is present and
  // did not answer is transient and carries a retry (ACTIONABLE). Rendering either as an
  // empty list would say "nothing to correct", which is the one thing neither means.
  // -------------------------------------------------------------------------------------
  {
    s: "This install has no company memory it can write to, so there is nothing to read or correct here. That is a statement about this install, not about what is recorded.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "Switching that on is a job for whoever set RichOS up — there is no control for it in here.",
    fixture: "corrections-off",
    why:
      "The loro desk's own refusal (main.rs, `desk()`), relayed verbatim and never reworded. " +
      "It names no party by itself, so the surface appends the owner line in the SAME " +
      "paragraph rather than paraphrasing the backend — the backend says what is missing, " +
      "the UI says who can do something about it, and neither guesses the other's half.",
  },
  {
    s: "I can't record corrections right now — my correction log could not be opened. Nothing you say is being lost from the conversation itself.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "Switching that on is a job for whoever set RichOS up — there is no control for it in here.",
    fixture: "corrections-off",
    why: "The spoken desk's refusal (main.rs, `spoken_desk()`), same relay and same owner line.",
  },
  {
    s: "Switching that on is a job for whoever set RichOS up — there is no control for it in here.",
    c: "NEEDS-SOMEONE-ELSE",
    fixture: "corrections-off",
    why:
      "The owner half of both sentences above, and the only part of an unavailable desk this " +
      "UI authors. It names the party the regex requires and promises no control, because " +
      "configuring a corpus or a service binary is not reachable from any screen in the app.",
  },
  {
    s: "I couldn't read that just now. Nothing has changed.",
    c: "ACTIONABLE",
    control: ".desk-broke:not([hidden]) .desk-btn",
    fixture: "corrections-read-failed",
    why:
      "The other unavailable state: the desk said it was there (`loro_available` true) and " +
      "then a read refused. Transient in the common case, so the retry sits inside the block; " +
      "where the reason is NOT transient the backend's own sentence renders directly beneath " +
      "and names its owner (see the entity row above).",
  },
  {
    s: "Nothing about the company record is waiting on you.",
    c: "INFORMATIONAL",
    fixture: "corrections-empty",
    why:
      "A readable desk with nothing pending — and it renders ONLY when the read succeeded, " +
      "which is why it is a different element from the two unavailable states rather than " +
      "the same empty list serving all three.",
  },
  {
    s: "No word is waiting on you.",
    c: "INFORMATIONAL",
    fixture: "corrections-empty",
    why: "The spoken half of the same fact, under its own availability check.",
  },
  {
    s: "What I believe",
    c: "INFORMATIONAL",
    fixture: "corrections",
    why: "Section heading over the loro family — what the company record says, in the CEO's terms rather than 'loro'.",
  },
  {
    s: "Words I may have got wrong",
    c: "INFORMATIONAL",
    fixture: "corrections",
    why: "Section heading over the spoken family — a word Rich mis-transcribed, not a belief.",
  },
  {
    s: "Never ask again",
    c: "ACTIONABLE",
    control: ".desk-suppressed:not([hidden]) .desk-btn--lift",
    fixture: "corrections-loro-never",
    why:
      "§7 requires the suppression list to be inspectable 'or a term silently refuses to " +
      "learn with no way to see why', and a list you can see and cannot clear is only half " +
      "of that. Every row under this heading carries its own lift button, so the heading is " +
      "classified by what the CEO can still do about what is under it.",
  },
  {
    s: "Because you said:",
    c: "INFORMATIONAL",
    fixture: "corrections",
    why:
      "Labels the CEO's OWN words — the loro proposal's `why`, or the utterance the spoken " +
      "trigger fired on. A correction with no stated reason is the shape an inferred one " +
      "takes, so this label is what makes the difference visible on the card.",
  },
  {
    s: "What would be written, exactly:",
    c: "INFORMATIONAL",
    fixture: "corrections",
    why:
      "Labels the writer's own `--dry-run` bytes. 'Exactly' is a claim the card can make " +
      "because the preview is `WriteOutput.text` and not a description of it " +
      "(`correction.rs:366-369`).",
  },
  {
    s: "Yes, that's right",
    c: "CONTROL",
    fixture: "corrections",
    why: "The confirm button on a loro proposal — the only path in this application to a loro write.",
  },
  {
    s: "Never ask about this record",
    c: "CONTROL",
    fixture: "corrections",
    why: "§7's third outcome on a loro proposal: suppress this ref, on a list that reads back and lifts.",
  },
  {
    s: "Show me what's on record now",
    c: "CONTROL",
    fixture: "corrections",
    why:
      "`loro_show_record`. Reading is not correcting (`correction.rs:592-595`), so it needs " +
      "no proposal — and it is absent on an append, where there is no prior record to show.",
  },
  {
    s: "Yes, learn it",
    c: "CONTROL",
    fixture: "corrections",
    why: "The confirm button on a spoken candidate — the only path from a staged pair to the vocabulary.",
  },
  {
    s: "Never ask about this term",
    c: "CONTROL",
    fixture: "corrections",
    why: "§7's third outcome on a spoken candidate.",
  },
  {
    s: "Ask about this again",
    c: "CONTROL",
    fixture: "corrections-loro-never",
    why: "Lifts one suppression. The half of 'inspectable' that a read-only list would be missing.",
  },
  {
    s: "Done. That's what I have on record now.",
    c: "INFORMATIONAL",
    fixture: "corrections-written",
    why:
      "The confirmed write landed. Said only when the returned proposal is in state `written` " +
      "— never optimistically, because the same call can come back `failed`.",
  },
  {
    s: "I said yes to that and the write didn't land, so nothing changed. Here is exactly what my writer said:",
    c: "INFORMATIONAL",
    fixture: "corrections-write-failed",
    why:
      "He confirmed and the writer refused. Nothing to press: `confirm` refuses a proposal " +
      "that is not awaiting an answer (`correction.rs:541`), so the card is spent. The " +
      "writer's own sentence follows verbatim on the next line and is often an instruction to " +
      "HIM ('that is a PROSE section — edit the page'), which is exactly why it is relayed " +
      "rather than reworded.",
  },
  {
    s: "Left it alone. I'll ask again if it comes up.",
    c: "INFORMATIONAL",
    fixture: "corrections-loro-declined",
    why:
      "§7: a plain decline is NOT permanent, because a decline is ambiguous — not a record / " +
      "not now / misclicked — while a repeat is the evidence. The sentence says so rather " +
      "than letting him assume he has settled it.",
  },
  {
    s: "I won't ask about that record again. It's in the list below if you change your mind.",
    c: "ACTIONABLE",
    control: "#desk-loro-suppressed-list .desk-btn--lift",
    fixture: "corrections-loro-never",
    why:
      "A permanent decline that vanished would be a lost correction. It names where the " +
      "suppression went, and the lift control is in that list in the same view.",
  },
  {
    s: "Learned. I'll write it that way from now on.",
    c: "INFORMATIONAL",
    fixture: "corrections-learned",
    why: "`LearnOutcome.changed` true — the pair reached the vocabulary.",
  },
  {
    s: "I already had that one, so nothing changed.",
    c: "INFORMATIONAL",
    fixture: "corrections-already-knew",
    why:
      "`changed: false` — the vocabulary already knew the pair. A DIFFERENT fact from a " +
      "refusal, and `staging.rs:141-144` says he is entitled to both, so the two are not " +
      "collapsed into one cheerful sentence.",
  },
  {
    s: "Left it alone. I'll ask again the next time you say it.",
    c: "INFORMATIONAL",
    fixture: "corrections-spoken-declined",
    why:
      "The spoken half of the same outcome, and more specific because §7 is more specific " +
      "for words: re-ask on the very next repeat, no threshold and no cool-off, because " +
      "repetition IS the evidence and waiting dilutes it.",
  },
  {
    s: "I won't ask about that word again. It's in the list below if you change your mind.",
    c: "ACTIONABLE",
    control: "#desk-spoken-suppressed-list .desk-btn--lift",
    fixture: "corrections-spoken-never",
    why: "The spoken suppression, and its way back out, in the same view.",
  },
  {
    s: "Back on the table. I'll ask about it if it comes up again.",
    c: "INFORMATIONAL",
    fixture: "corrections-lifted",
    why:
      "A suppression was lifted. It promises a future ask rather than an immediate one, " +
      "because nothing here re-proposes — something has to raise the correction again.",
  },

  // -------------------------------------------------------------------------------------
  // THE FEEDBACK CHANNEL (`feedback.rs`) — the local half, made reachable
  //
  // Almost every sentence on this surface comes from the BACKEND (`feedback_wording`,
  // `feedback_taxonomy`), and `feedback.rs` holds them as constants precisely so a UI
  // cannot paraphrase them — which is why the question, the four key labels, the report
  // offer, the disclosure heading and every term's sentence appear in NO row below. They
  // are not in this inventory because they are not in `index.html`, `main.js` or the
  // command layer; they are projections of one module's constants, and `feedback.js` joins
  // each of them to a fixture a cargo test regenerates from the live Rust values.
  //
  // What IS below is the small amount this surface genuinely authors: four group legends,
  // four button labels, three outcome sentences, two history labels, one section heading,
  // one empty line, and the three refusals the command layer writes.
  // -------------------------------------------------------------------------------------
  {
    s: "I can't keep an answer right now — the file I record them in wouldn't open, and I'm not going to ask you what you think and then lose it. That one is for whoever set RichOS up to look at; it isn't yours to fix.",
    c: "NEEDS-SOMEONE-ELSE",
    fixture: "feedback-unavailable",
    why:
      "`FEEDBACK_STORE_UNAVAILABLE`. The one file would not open, which nothing in the app " +
      "can change, so it names the party who can and offers no control. The four keys are " +
      "NOT rendered beside it: asking him what he thinks and then dropping the answer is " +
      "worse than not asking, and a set of buttons that record nothing would be exactly that.",
  },
  {
    s: "What's on this machine",
    c: "INFORMATIONAL",
    fixture: "feedback",
    why:
      "The history section's heading, and a deliberate statement of scope rather than a " +
      "neutral label — 'this machine' is the whole of where an answer goes in this version.",
  },
  {
    s: "Nothing is recorded here yet. RichOS never puts the question to you on its own — this panel is the only place it is asked.",
    c: "INFORMATIONAL",
    fixture: "feedback",
    why:
      "A readable store holding nothing — and it renders ONLY when the read succeeded, " +
      "which is why it is a different element from the store-would-not-open state. The " +
      "second sentence exists because an empty history could otherwise read as 'you had " +
      "nothing to say'; the truthful reason is that nothing has ever asked him, and this " +
      "build deliberately never will (`feedback.rs`: all five moments in the reference case " +
      "were volunteered mid-work, none at session end).",
  },
  {
    s: "What kind of failure was it?",
    c: "CONTROL",
    fixture: "feedback-choosing",
    why: "The accessible name of the failure-class radio group — a `<legend>` over its own controls.",
  },
  {
    s: "How many times this session?",
    c: "CONTROL",
    fixture: "feedback-choosing",
    why: "The accessible name of the occurrence radio group. Closed, never an integer field.",
  },
  {
    s: "What went wrong",
    c: "CONTROL",
    fixture: "feedback-choosing",
    why: "The accessible name of the diagnosis checkbox group — the terms that compose the report.",
  },
  {
    s: "What let it happen",
    c: "CONTROL",
    fixture: "feedback-choosing",
    why: "The accessible name of the contributing-condition group. Optional, and omitted from the report entirely when empty.",
  },
  {
    s: "Show me exactly what you'd say",
    c: "CONTROL",
    fixture: "feedback-choosing",
    why:
      "#feedback-show-preview. Disabled until the selection can actually be assembled, " +
      "because a control that appears and then refuses teaches him the surface is unreliable.",
  },
  {
    s: "Yes, report that",
    c: "CONTROL",
    fixture: "feedback-previewing",
    why: "#feedback-approve — and it is only reachable after the report has been rendered and read.",
  },
  {
    s: "No, don't report that",
    c: "CONTROL",
    fixture: "feedback-previewing",
    why: "#feedback-refuse. A declined report is not a report: the payload is dropped and nothing about it is recorded.",
  },
  {
    s: "Taken down. It stays on this machine.",
    c: "INFORMATIONAL",
    fixture: "feedback-rated",
    why: "A rating recorded with no offer made — a `3`, or a dismissal. States where it went, and promises nothing else.",
  },
  {
    s: "Taken down, with no report attached.",
    c: "INFORMATIONAL",
    fixture: "feedback-declined-report",
    why: "He was offered the chance to report and said no. Says what was kept, which is the rating and only the rating.",
  },
  {
    s: "Taken down, word for word as you read it — and it stays on this machine.",
    c: "INFORMATIONAL",
    fixture: "feedback-approved",
    why:
      "An approved report. 'Word for word as you read it' is a checked claim rather than a " +
      "reassurance: `feedback_record` re-renders the selection and refuses the write if it " +
      "is not byte-identical to the block he was shown.",
  },
  {
    s: "You approved this report:",
    c: "INFORMATIONAL",
    fixture: "feedback-approved",
    why:
      "The label over a stored approval's text, which is re-rendered from the stored payload " +
      "rather than kept as a second free-text copy — the copy would have put an unvalidated " +
      "string in the durable record, which is the channel this design exists to close.",
  },
  {
    s: "You were offered a report and said no.",
    c: "INFORMATIONAL",
    fixture: "feedback-declined-report",
    why:
      "A stored `ReportDecision::Declined`. The offer having been made is part of what " +
      "happened, and a row that showed only the rating would lose it.",
  },

  // -------------------------------------------------------------------------------------
  // WHICH COMPANY THIS COPY OF RICH WORKS FOR (slice 4, 2026-09-01)
  //
  // WHAT IS NOT HERE, AND WHY. The durable SETTING for this — the row in the universal
  // settings menu — lives in `settings-button.js`, which `UI_SOURCES` does not scan
  // (`index.html`, `main.js`, `timeline.js` only). So its four strings are outside this
  // registry, exactly as Techy Mode's and the opening screen's rows in the same file
  // already are. That is a blind spot of the derivation, not an exemption granted here, and
  // it is covered instead by two named checks at the foot of `affordances.js` which drive
  // the real menu and assert the control and the pinned statement. The strings BELOW are
  // the ones the shell itself renders: the launch picker, the composer's block, and the
  // Rust refusals the shell relays verbatim.
  //
  // Every row here exists because a double-clicked bundle has working directory `/`, which
  // owns no entity, so `EntityRegistry::resolve_root` refuses to guess (ECS §3.3 — correct,
  // and unchanged). Before this pass the ONLY routes to an entity were `RICHOS_ENTITY` and
  // a working directory, and a CEO opening an app from Finder has neither. These are the
  // states of the surface that gives him one.
  // -------------------------------------------------------------------------------------
  {
    s: "Choose the company",
    c: "CONTROL",
    why: "The button beneath the composer's block (`#choose-company-btn`). It IS the affordance.",
  },
  {
    s: "Which company is this copy of Rich for?",
    c: "CONTROL",
    why:
      "Two places, one string, and it is a LABEL in both: the picker dialog's title, which " +
      "`aria-labelledby` points the listbox at, and the settings popover's heading, which " +
      "names the radiogroup below it. Neither is a state; each is the accessible name of the " +
      "control it sits above.",
  },
  {
    s: "I don't know which company this work is for yet, so I won't file it anywhere. Pick one and I'll take it from there.",
    c: "ACTIONABLE",
    control: "#choose-company-btn",
    fixture: "company-unchosen",
    why:
      "The composer's block on a launch that resolved no company — the state EVERY " +
      "double-clicked launch is in until he answers once. It is his to clear, so the control " +
      "is rendered directly beneath the sentence rather than described: the same button also " +
      "reopens the picker if he dismissed it.",
  },
  {
    s: "Send is off until I know the company",
    c: "ACTIONABLE",
    control: "#choose-company-btn",
    fixture: "company-unchosen",
    why:
      "The composer's placeholder while a company block is up — candidate-.2 defect #6. The " +
      "box used to read 'Talk to Rich…' over a field that would take his sentence and refuse " +
      "to send it, which `showUnboundView` had already named for the OTHER blocked state: " +
      "'an inviting Talk to Rich… above a dead field is the composer telling a small lie " +
      "about what it will do'. Same treatment, same reason, and the sibling row 'Send is off " +
      "for this thread' is the one this follows. " +
      "ONE STRING FOR THREE BLOCKS, and the class is the one that fits the two he can clear: " +
      "no company chosen and no company known are both his, and `#choose-company-btn` sits " +
      "directly beneath. The third — a company pinned from outside the window that cannot be " +
      "made sense of — is NEEDS-SOMEONE-ELSE, and it is `COMPANY_PINNED_BLOCK`'s own row that " +
      "carries that, rendered in the line immediately above the box and attached to the box " +
      "itself by `aria-describedby`. The placeholder says only what the box will do and names " +
      "neither a party nor an instruction, which is why it does not have to.",
  },
  {
    s: "I'll keep everything you tell me under the company you pick, and I'll remember it — you won't be asked again. You can change it later in Settings.",
    c: "ACTIONABLE",
    control: "#entity-picker-list .picker-item",
    fixture: "company-unchosen",
    why:
      "The picker's second line, shown only when the question is about this COPY of Rich " +
      "rather than about one thread. It exists because the same dialog asked the same-looking " +
      "question on every launch before this pass and remembered nothing; saying the answer is " +
      "kept is the difference between one question and a permanent one. The control is the " +
      "list of companies directly beneath it.",
  },
  // ---- ADDING A COMPANY (2026-09-04) ----------------------------------------------------
  //
  // WHY THESE ROWS EXIST. Until today the picker's rows WERE the registry, the registry was
  // a `const` table of the app author's six companies compiled into the binary, and there
  // was no door anywhere in the product for a second person to add his own. On any machine
  // but his the app offered him a choice among businesses that were not his, or a composer
  // that refused every send. Every string below is part of the door.
  {
    s: "I don't know about any of your companies yet. Tell me one and I'll start keeping its work together — you can add the rest whenever you like.",
    c: "ACTIONABLE",
    control: "#entity-add-name",
    fixture: "company-none-registered",
    why:
      "The picker's opening line on a FIRST LAUNCH, where the list is empty. It is his to " +
      "clear and the field that clears it is directly beneath, which is why this is the " +
      "line rather than a silent empty dialog — a registry-driven picker renders nothing at " +
      "all when the registry is empty, and nothing is not an answer.",
  },
  {
    s: "Not one of these? Add it here.",
    c: "ACTIONABLE",
    control: "#entity-add-name",
    fixture: "company-unchosen",
    why:
      "The same form's lead when he DOES have companies listed. Two sentences rather than " +
      "one, because 'I don't know about any of your companies' is false on an install that " +
      "has five of them, and a line that is false in one of its two states is a line nobody " +
      "reads in either.",
  },
  {
    s: "What's the company called?",
    c: "CONTROL",
    why:
      "The `<label for=\"entity-add-name\">` — the field's accessible name, not a state. It " +
      "is a question because the control is a text field and the field has nothing else to " +
      "say what belongs in it.",
  },
  {
    s: "Its folder on this Mac",
    c: "CONTROL",
    why:
      "The `<label for=\"entity-add-folder\">`. The word 'optional' is inside the same " +
      "label element, so a screen reader announces the field as optional rather than " +
      "leaving that in a hint below it.",
  },
  {
    s: "Give me a folder and I'll pick this company on my own whenever you start RichOS from inside it. Leave it blank and you'll just pick it yourself — everything else works the same.",
    c: "INFORMATIONAL",
    fixture: "company-unchosen",
    why:
      "What the folder DOES, beside the field that takes it. It is not a request: it names " +
      "the consequence of both answers and says plainly that leaving it blank costs him " +
      "nothing but the automatic pick. A person who does not know his own folder path must " +
      "not stop here, and without this sentence he would.",
  },
  {
    s: "Add this company",
    c: "CONTROL",
    why: "The button's label (`#entity-add-go`). It IS the affordance the two rows above name.",
  },
  {
    s: "I don't know about any of your companies yet, so I've nothing to file this under. Tell me one and I'll take it from there.",
    c: "ACTIONABLE",
    control: "#choose-company-btn",
    fixture: "company-none-registered",
    why:
      "The composer's block on a first launch, and a SEPARATE sentence from 'Pick one and " +
      "I'll take it from there' — because 'pick one' is not an instruction a person with an " +
      "empty list can follow. The control reopens the picker, where the form that clears it " +
      "lives.",
  },
  {
    s: "Your list of companies is saved at",
    c: "FRAGMENT",
    fixture: "company-registry-unreadable",
    why:
      "The opening of the unreadable-registry sentence, composed in `registryUnreadableLine` " +
      "around the file's own path. Classified against the whole sentence, whose row is " +
      "below; the path between the halves is a fact about one machine, not a string.",
  },
  {
    s: ", and I couldn't read it just now, so I'm not showing any — rather than showing you a wrong list. That file is fixed by whoever set RichOS up. You can also add a company here in the meantime.",
    c: "NEEDS-SOMEONE-ELSE",
    fixture: "company-registry-unreadable",
    why:
      "The close of the same sentence, and the state it describes is not his: a file that " +
      "will not parse is fixed by whoever set RichOS up, and it names that party. It is " +
      "NOT the empty-list sentence and must never be collapsed into it — telling him he has " +
      "not named a company, when he has and it is one typo from working, would invite him " +
      "to enter it twice. The last clause carries the thing he CAN do, which is add one " +
      "here without waiting.",
  },
  // ---- and the Rust refusals the shell relays verbatim ---------------------------------
  {
    s: "I need a name for the company before I can file anything under it. Anything you'd recognize on a button is fine — you can change it later.",
    c: "ACTIONABLE",
    control: "#entity-add-name",
    fixture: "company-none-registered",
    why:
      "`register_entity`'s refusal of a blank name, rendered into `#entity-add-error` " +
      "beside the field that fixes it. It says what a good answer looks like rather than " +
      "only that the answer was wrong.",
  },
  {
    s: "That name doesn't have any letters or numbers in it, so I can't make a file-safe label out of it. Try a name with a word in it.",
    c: "ACTIONABLE",
    control: "#entity-add-name",
    fixture: "company-none-registered",
    why:
      "The other way a name is refused: the id is DERIVED from what he typed, and a name " +
      "with nothing in the id's character class derives nothing. Same field, same place.",
  },
  {
    s: "I already have a lot of companies with names like \"{name}\" and I couldn't make a distinct label for another one. Try a name that's a bit more specific.",
    c: "UNREACHABLE",
    why:
      "`register_entity`'s 99-collision bound. It needs ninety-nine companies whose names " +
      "all derive to one label; no fixture builds that and no person will. It exists so the " +
      "suffix loop terminates in a sentence rather than in a panic, and it is listed here " +
      "so the claim that it is unreachable is on the record rather than assumed.",
  },
  {
    s: "there's nothing at that path on this Mac",
    c: "FRAGMENT",
    why:
      "One of three reasons composed into `company_folder_message`, which wraps them in a " +
      "sentence naming the folder and the way out ('or leave it blank'). Never rendered " +
      "alone. This is the common one — a typed path that names nothing — and it is checked " +
      "rather than assumed precisely because a company registered against a folder that is " +
      "not there can never be selected by launching from it, and would surface weeks later " +
      "as 'Rich keeps asking me which company this is'.",
  },
  {
    s: "it isn't a full path from the top of the disk",
    c: "FRAGMENT",
    why:
      "The second reason in the same sentence: resolution is lexical, so a relative root " +
      "can never match anything and storing one would be a dead entry that looks live.",
  },
  {
    s: "that's a file, not a folder",
    c: "FRAGMENT",
    why: "The third reason in the same sentence, kept distinct because the fix differs.",
  },
  // ---- FIRST-RUN SETUP (Option D) — `setup.rs`, `setup_view.rs` -------------------------
  //
  // §19 states the condition these rows exist for: "today RichOS runs on his Mac and would
  // not run on anyone else's". Every machine but the CEO's opens on this sheet.
  {
    s: "There's a bit of setting up to do first.",
    c: "CONTROL",
    why:
      "The setup sheet's title, and `aria-labelledby` points the dialog at it. It is the " +
      "accessible name of the control beneath it, not a state — the same classification, " +
      "for the same reason, as the memory dialog's and the entity picker's titles. It is " +
      "replaced at open by one of the two counted titles below.",
  },
  {
    s: "There are a couple of things I need on this Mac.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-missing-both",
    why:
      "The title a customer's Mac opens on — no Claude Code and no engine directory. It is " +
      "entirely his to clear and it takes one press, so the button sits in the same dialog. " +
      "It counts in words rather than items because \"2 items\" is a package manager's " +
      "sentence and this is a conversation.",
  },
  {
    s: "There's one thing I need on this Mac.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-missing-engine",
    why:
      "The same state with one piece missing rather than two — a machine that already has " +
      "Claude Code and no engine, which is what a customer who installed Claude Code " +
      "himself is in. Same control, same press. It has its OWN fixture because the plural " +
      "title and this one cannot both render at once, and a fixture that happened to show " +
      "the other would have asserted nothing.",
  },
  {
    s: "I can get them myself — you just have to say so.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-missing-both",
    why:
      "The sheet's second line, shown only when this build can actually install what is " +
      "missing. It is the sentence that makes the press meaningful, so it is classified " +
      "with the press and not as a description — and it is deliberately absent in the " +
      "unpinned state below, where no press would help.",
  },
  {
    s: "I can get it myself — you just have to say so.",
    c: "ACTIONABLE",
    control: "#setup-go",
    fixture: "setup-missing-engine",
    why:
      "The same sentence for one missing piece rather than two. It has its own row for the " +
      "reason the two titles do: until 2026-09-04 there was only the plural, so a machine " +
      "missing only the engine read \"There's one thing I need on this Mac. I can get them " +
      "myself\" — the first screen a customer ever sees, disagreeing with itself in its own " +
      "second sentence.",
  },
  {
    s: "I couldn't finish the setup.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy:
      "the note directly beneath it — \"That's everything I could do — something is still " +
      "missing. That part is for whoever set RichOS up to look at.\" — which names the party",
    why:
      "The other ending's heading, and it carries no fixture for the same reason its note " +
      "carries none: reaching it needs a component to vanish between the install and the " +
      "backend's re-read of the disk. It does not name the party itself because the sentence " +
      "under it does, in the same view, and repeating it would make a two-line dialog say the " +
      "same thing twice.",
  },
  {
    s:
      "This copy of RichOS wasn't built with an engine to install, so I can't fetch one. It " +
      "needs whoever set RichOS up to publish one and pin it.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: "setup-unpinned",
    why:
      "A build carrying no engine pin. `setup.rs` refuses rather than fetching whatever a " +
      "URL returns, so the sheet explains and names the party — and `#setup-go` is HIDDEN, " +
      "because a button that would certainly fail is worse than no button. It ships as " +
      "`setup_view::SETUP_UNPINNED_NOTE` as well as `SetupError::EngineUnpinned`'s Display, " +
      "with a Rust test requiring the two to be one string: an `#[error(...)]` attribute is " +
      "not somewhere this scrape can see, and a sentence this registry cannot see is one " +
      "nobody has said whether the CEO can act on.",
  },
  {
    s: "Setup is done.",
    c: "INFORMATIONAL",
    fixture: "setup-finished",
    why:
      "The installation heading confirms that software setup completed. Account connection is reported separately below it.",
  },
  {
    s: "That's everything I could do — something is still missing. That part is for whoever set RichOS up to look at.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    why:
      "The other ending, and the reason `run_setup` re-reads the disk instead of trusting " +
      "that no step threw: a run whose steps all returned Ok while something is still " +
      "absent must not say \"I'm ready\". It names the party because the fact of WHICH piece " +
      "is missing is on the operator's boot line and not on his screen. Reaching it needs a " +
      "component to vanish between the install and the re-read, so it is classified here " +
      "rather than fixtured — an unreachable-from-the-mock state that is still shipped is " +
      "exactly the kind this registry exists to keep honest.",
  },
  {
    s: "Your memory folder.",
    c: "CONTROL",
    why:
      "The same dialog's heading AFTER he has answered it, and it exists because the question " +
      "used to stay on screen above its own answer: \"Where should I keep what you tell me?\" " +
      "over \"That's set up.\" — and, on a machine with no compiler, over the sentence saying " +
      "the folder cannot be read yet. It is the accessible name of the dialog it labels, not a " +
      "state, which is the same classification the question below carries.",
  },
  {
    s: "Where should I keep what you tell me?",
    c: "CONTROL",
    why:
      "The first-run memory dialog's title, and `aria-labelledby` points the dialog at it. " +
      "It is the accessible name of the control beneath it, not a state — the same " +
      "classification, for the same reason, as the entity picker's title.",
  },
  {
    s:
      "I'll keep your decisions, your companies and how you work in a folder on this Mac, and " +
      "nothing in it leaves this Mac. If this looks right, I'll set it up now.",
    c: "ACTIONABLE",
    control: "#memory-setup-go",
    fixture: "memory-unprovisioned",
    why:
      "The state a fresh install is in: no corpus anywhere, which is what the installed " +
      "bundle measurably reported the moment its hand-made pointer was removed. It is " +
      "entirely his to clear and it takes one click, so the button sits directly beneath " +
      "the sentence and the location it will use is SHOWN above it — his part is a choice, " +
      "never a path he types. Nothing behind the button picks a location when he has not: " +
      "`provision` refuses an unset target by name.",
  },
  {
    s:
      "That's set up. From now on I'll keep what you tell me in that folder and read it back " +
      "when it matters.",
    c: "INFORMATIONAL",
    why:
      "What he sees after answering, when the corpus resolved AND the compiler is installed. " +
      "Nothing to do — it is the confirmation that the question is over, and it carries no " +
      "imperative aimed at him.",
  },
  {
    s:
      "Your memory folder is on this Mac, and I can't read or write it yet — the part of me that " +
      "does isn't in this version. Nothing else is affected: our conversations stay on this Mac " +
      "and I pick them up when you come back. There's nothing for you to install and nothing for " +
      "you to fix — I'll start using the folder on my own as soon as that part arrives.",
    c: "INFORMATIONAL",
    fixture: "memory-no-compiler",
    why:
      "Two moments, one sentence: a boot that resolves a corpus and no compiler, and a setup " +
      "that finishes the same way. " +
      "IT WAS NEEDS-SOMEONE-ELSE UNTIL 2026-09-04 AND THE PARTY WAS THE DEFECT. The sentence " +
      "read \"It needs whoever set RichOS up to add it\", which is the right shape on a machine " +
      "somebody else set up and a dead end on a customer's: Andreas installs RichOS himself, so " +
      "the party is HIM, and the product's headline promise ended on an instruction to fetch a " +
      "third party who does not exist. That is the same argument the Anthropic-account row above " +
      "makes for its own bucket — when the person is him, NEEDS-SOMEONE-ELSE is the wrong " +
      "answer, because that bucket exists to point him at somebody who is not him. " +
      "HERE THERE IS NOBODY AT ALL, WHICH IS WHY IT IS INFORMATIONAL AND NOT ACTIONABLE. The " +
      "missing piece is the loro compiler, and it has no route onto any machine: the public " +
      "product repo tracks no `loro/` file, the signed bundle's Resources hold `icon.icns` and " +
      "nothing else, and the engine release asset carries `engine/`, which holds no compiler. " +
      "Neither he nor an operator can install what ships from nowhere, so no control is drawn " +
      "and no party is named — the sentence states what does not work, what still does, and " +
      "that nothing is required of him. It issues no instruction to him, which is the property " +
      "the INFORMATIONAL bucket owes.",
  },
  {
    s: "This copy of me was told which company it works for when it was started up, from outside this window, and I can't make sense of what it was told — so I won't file anything until whoever set RichOS up has sorted it out.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: "company-pinned-unresolved",
    why:
      "`RICHOS_ENTITY` set to something this build does not have. The variable short-circuits " +
      "resolution BEFORE the saved choice, so no picker is opened — every answer he could give " +
      "would be written to disk and then never read, and asking a question whose answer is " +
      "guaranteed to be swallowed is worse than saying who owns the fix.",
  },
  {
    s: "This copy of me was told which company it works for when it was started up, from outside this window, so I can't move it from in here. Whoever set RichOS up is the one who changes that.",
    c: "UNREACHABLE",
    why:
      "`ENTITY_PINNED_MESSAGE` — `choose_entity`'s refusal when `RICHOS_ENTITY` is set. No " +
      "path in the shipped UI reaches it, and that is checkable rather than asserted: the two " +
      "callers of `choose_entity` are the picker's rows and the settings radios, and " +
      "`buildCompanyRow` (settings-button.js) draws a statement and no control while " +
      "`pinnedByEnvironment` is true, and `requireCompanyChoice` returns before opening the " +
      "picker in the same condition. It is " +
      "the guard for a caller that is not this UI. If it ever renders, the bug is ours.",
  },
  {
    s: "first-run setup is incomplete",
    c: "NOT-RENDERED",
    why:
      "`send_message` could not attach a lease AND `setup_view::detect` found something missing on disk. The CEO gets `SETUP_INCOMPLETE_*` instead; this is the operator half. " +
      "It is the `why` argument to `main.rs::refused_send`, which prints it with " +
      "`eprintln!` and returns the CEO sentence UNCHANGED — the nightly's D4, where a " +
      "typed message that never became a turn reached the window and said nothing to the " +
      "log. This scrape sees it because it sits beside `Err(` in the command layer, " +
      "which is the one shape `RUST_CEO_CONTEXT` cannot tell apart from CEO copy.",
  },
  {
    s: "no compute lease and no factory",
    c: "NOT-RENDERED",
    why:
      "The same refusal with nothing missing on disk, so the cause is the account rather than the install. The CEO gets `LEASE_UNAVAILABLE_MESSAGE`. " +
      "It is the `why` argument to `main.rs::refused_send`, which prints it with " +
      "`eprintln!` and returns the CEO sentence UNCHANGED — the nightly's D4, where a " +
      "typed message that never became a turn reached the window and said nothing to the " +
      "log. This scrape sees it because it sits beside `Err(` in the command layer, " +
      "which is the one shape `RUST_CEO_CONTEXT` cannot tell apart from CEO copy.",
  },
  {
    s: "no active thread",
    c: "NOT-RENDERED",
    why:
      "No thread is open to file the message under. The CEO gets the open-a-conversation line. " +
      "It is the `why` argument to `main.rs::refused_send`, which prints it with " +
      "`eprintln!` and returns the CEO sentence UNCHANGED — the nightly's D4, where a " +
      "typed message that never became a turn reached the window and said nothing to the " +
      "log. This scrape sees it because it sits beside `Err(` in the command layer, " +
      "which is the one shape `RUST_CEO_CONTEXT` cannot tell apart from CEO copy.",
  },
  // GONE, 2026-09-17, and the deletion is the point rather than the tidying: "the active
  // thread changed between render and send" and its CEO sentence, "The conversation changed
  // before your message was sent. Open the original conversation to try again.", were the
  // refusal `send_message` gave when the named conversation was not the single active one.
  // The CEO's Two Riches page is "any number of conversation threads" and "the CEO could
  // open and run multiple things in parallel"; a message to any conversation is now
  // answered on that conversation, so there is no state here to classify. Two states
  // removed from the product is two rows removed from this file — the suite requires it in
  // both directions, and it is what failed when the rows outlived the strings.
  {
    s: "entity not resolved from {}: {e}",
    c: "NOT-RENDERED",
    why:
      "A note from `resolve_boot_entity`, printed by `boot_entity` with `eprintln!` and never " +
      "returned to the webview. It is a `format!` rather than an `eprintln!` for one reason: " +
      "the resolver is a pure function of its arguments so the ORDER of the four steps can be " +
      "asserted by a test, which the version it replaced — reading `std::env::var` and " +
      "`current_dir()` inline — structurally could not be. Its audience is a terminal.",
  },

  // -------------------------------------------------------------------------------------
  // UNREACHABLE / NOT-RENDERED
  // -------------------------------------------------------------------------------------
  {
    s: "I can't tell which company this work belongs to, so I won't guess — filing it under the wrong one would mix two companies' records together, and that's not a mistake worth risking to save you a question. Pick the company and I'll keep everything under it from then on.",
    c: "ACTIONABLE",
    control: "#choose-company-btn",
    fixture: "corrections-read-failed",
    why:
      "IT CHANGED BUCKET ON 2026-09-01, and the bucket is the whole point of the change. " +
      "`loro_pending_corrections` resolves the entity BEFORE it touches the desk, so on a " +
      "launch with no company chosen `loro_available` is still true and the pending read " +
      "refuses with this sentence, verbatim, in the desk's `readFailed` branch. It used to " +
      "be NEEDS-SOMEONE-ELSE and it named its party, because picking a company genuinely " +
      "was not something the app could do — `RICHOS_ENTITY` or a working directory were " +
      "the only two routes and a CEO has neither. Slice 4 gave him both a launch picker " +
      "and a preferences row, so the party clause was retired as a lie and this is now HIS " +
      "to fix. " +
      "THE COST, stated where a reviewer sees it: the control is `#choose-company-btn` on " +
      "the composer, and while the corrections desk is open it sits BEHIND that modal — " +
      "the desk carries its own close button (`#corrections-close`) and the same choice is " +
      "in the preferences popover, so it is one dismissal away rather than nowhere, but " +
      "this suite does not check occlusion and it would be dishonest to let the row imply " +
      "otherwise.",
  },
  {
    s: 'unknown theme {theme:?} — expected "dark", "light" or "system"',
    c: "UNREACHABLE",
    why:
      "`set_theme`'s refusal (src-tauri/src/main.rs). No path in the shipped UI reaches it: " +
      "the only caller is `RichSettings`'s theme segment, whose three buttons carry " +
      "`data-th=\"light\" | \"system\" | \"dark\"` and nothing else, and `RichTheme.setTheme` " +
      "validates again before the write. It exists because the alternative — coercing an " +
      "unexpected string to the default — would look exactly like the CEO changing his own " +
      "mind about his own machine, silently. It is the guard for a caller that is not this " +
      "UI, and it carries no control because there is nothing for him to press: if it ever " +
      "renders, the bug is ours.",
  },
  {
    s: "That isn't one of the four answers, so I haven't written anything down.",
    c: "UNREACHABLE",
    why:
      "`FEEDBACK_KEY_NOT_ONE_OF_FOUR` — `PromptOutcome::from_key`'s `None`, said out loud. " +
      "No path in the shipped UI reaches it: the only callers of `feedback_preview` and " +
      "`feedback_record` are the four buttons `renderFeedbackKeys` builds from " +
      "`feedback_wording.ratings` plus its `dismiss`, and each carries its own key. It is " +
      "the guard for a caller that is not this file, and `feedback.js` check 7b invokes the " +
      "command directly to prove it refuses rather than inventing a dismissal.",
  },
  {
    s: "I won't record that. What you were shown isn't what I would say now, so approving it would be approving something you haven't read. Ask me to show it again.",
    c: "UNREACHABLE",
    why:
      "`FEEDBACK_PREVIEW_MISMATCH`. In-process, 'he saw exactly this' is structural — " +
      "`ApprovedReport` has no public constructor and the only route to one is " +
      "`Disclosure::approve`, which cannot exist without having rendered its text. That does " +
      "not survive an IPC boundary, so the command re-renders and compares. `main.js` holds " +
      "the rendered block verbatim in `feedback.shown` and posts it back unmodified, so no " +
      "path in the shipped UI produces a mismatch; `feedback.js` check 7 invokes the command " +
      "with altered text to prove the guard is real rather than decorative.",
  },
  {
    s: "I couldn't read that audio file.",
    c: "UNREACHABLE",
    why: "CaptureError::WavRead comes only from the file-input path, which no Tauri command exposes.",
  },
  {
    s: "unknown attention tier: {tier}",
    c: "UNREACHABLE",
    why: "raise_proactive_message's Err. Registered, never invoked by main.js.",
  },
  {
    s: "no correction {key} is awaiting an answer",
    c: "INFORMATIONAL",
    why:
      "`spoken_confirm_correction`'s refusal when the key names no pending candidate. It DOES " +
      "reach the DOM now — the desk relays every rejection verbatim into #corrections-notice — " +
      "but only from a card that is already stale, and the desk re-reads both families after " +
      "every answer, so the row it names is gone by the time the sentence is on screen. " +
      "Nothing to press, and the `{key}` hole means it never renders in this literal form.",
  },
  {
    s: "nothing to add",
    c: "NOT-RENDERED",
    why:
      "`steer_message`'s empty-text refusal. Two independent reasons it never reaches the DOM: " +
      "`send()` returns at main.js:1097 before any invoke when the trimmed text is empty, and " +
      "`steer()`'s catch (main.js:1212-1219) replaces whatever the backend said with its own " +
      "authored notice about the words being back in the box.",
  },
  {
    s: "unexpected intake record: {other:?}",
    c: "NOT-RENDERED",
    why:
      "A `{other:?}` Debug hole in `steer_message` — machinery for an engineer, and unreachable " +
      "besides: `TurnControl::steer` (steering.rs:470-475) constructs `IntakeRecord::Steer` and " +
      "returns nothing else. `steer()`'s catch would swallow it either way.",
  },
  {
    s: "mock: no such command",
    c: "NOT-RENDERED",
    why:
      "A comparison string (`msg.startsWith(...)` at main.js:1057), never written to the DOM. " +
      "A genuine false positive of the prose filter, kept visible rather than special-cased " +
      "away — a filter with a hidden exception list is the next drift.",
  },

  // -------------------------------------------------------------------------------------
  // TECHY MODE (open-items row 3.1, techy-mode design §3.1/§3.3/§3.4)
  //
  // The four state sentences answer ONE question — "why is there no machinery here?" — and
  // they are deliberately four different answers. Two are INFORMATIONAL (there is genuinely
  // nothing to do about a record that was never written) and two are NEEDS-SOMEONE-ELSE (a
  // store the OS is refusing has an owner, and it is not the CEO). Collapsing them into one
  // bucket would be the same mistake as collapsing them into one sentence.
  // -------------------------------------------------------------------------------------
  {
    s: "I can't read the technical record for this conversation. It's on this machine and I haven't lost it — something is refusing to open it, and whoever set RichOS up needs to look.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: "techy-unreadable",
    why:
      "`machinery_view.rs::UNREADABLE`. Nothing to press: the CEO cannot chmod a directory " +
      "from a conversation, and offering him a Retry over a permission bit would be a " +
      "control that does nothing. It names the owner instead, and says plainly that the " +
      "record is not lost — the state it must never be confused with is `nothing_recorded`, " +
      "which claims the opposite.",
  },
  {
    s: "I can't read the stored output for this one. It's on this machine and I haven't lost it — whoever set RichOS up needs to look.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    why:
      "`main.rs::RAW_UNREADABLE`, the same fault one level down — the Tier-B raw shard for " +
      "ONE record. No fixture: reaching it needs the raw sibling to be unreadable while the " +
      "Tier-A shard is fine, which is a real filesystem state and not one this harness can " +
      "produce, because `breakMachinery` takes the whole thread directory (and then there " +
      "are no rows left to expand). Named rather than left unclassified.",
  },
  {
    s: "Not part of any one exchange — this is what the session said with no turn running.",
    c: "INFORMATIONAL",
    fixture: "techy-on",
    why:
      "`index.html`'s `#between-turns-lede` — the lede over §1.5's between-turn lane. It " +
      "exists because a section of rows placed OUTSIDE the conversation invites the " +
      "question 'why are these not up there with everything else', and the answer is a " +
      "fact about the records: they carry no turn (`turnId: None`, §1.4 G4), so they have " +
      "no position in the conversation to be drawn at. Nothing for the CEO to do — it " +
      "explains a layout, it does not ask for a decision.",
  },
  {
    s: "Nothing was recorded between turns in this conversation. Rich started keeping this on 2026-08-30 — so in an older conversation that is a gap in the record, not proof the session was quiet.",
    c: "INFORMATIONAL",
    // `techy-empty`, not `techy-on`: the `acme` thread that `techy-on` opens HAS
    // between-turn traffic, so the sentence correctly does not render there. The fixture
    // that shows it is the conversation with nothing recorded at all — which is also the
    // commonest way a CEO will meet it, since every thread older than 2026-08-30 is one.
    fixture: "techy-empty",
    why:
      "`machinery_view.rs::BETWEEN_TURNS_QUIET`. The honest empty state for the lane, and " +
      "shaped like `NOTHING_RECORDED` for the same reason: the lane is empty in two " +
      "different situations and only one of them means the session was quiet. Nothing to " +
      "act on — between-turn retention began on 2026-08-30 and what was never written down " +
      "is unrecoverable, exactly as it is one level up.",
  },
  {
    s: "No machinery was recorded for this conversation. Retention started on 2026-08-28, and anything Rich did before that was never written down — so this is a gap in the record, not a quiet conversation.",
    c: "INFORMATIONAL",
    fixture: "techy-empty",
    why:
      "`machinery_view.rs::NOTHING_RECORDED`. THE honest empty state, and there is nothing " +
      "to do about it by construction: routing began at richos `48561e4` and dropped bytes " +
      "are unrecoverable, forever. The second clause exists because the sentence would " +
      "otherwise read as a claim about the CONVERSATION rather than about the RECORD.",
  },
  {
    s: "Nothing has been recorded on this machine yet. The technical view reads a store that hasn't been written to — it fills up as Rich works.",
    c: "INFORMATIONAL",
    why:
      "`machinery_view.rs::NOT_RETAINED` — a fact about the INSTALL, not the thread: no " +
      "machinery root at all, or a spine with no journal attached. No fixture: the mock " +
      "always has a journal, and faking the state would prove the mock. Nothing to do — " +
      "retention is unconditional (§3.2) and starts the first time Rich uses a tool.",
  },
  {
    s: "The full output isn't kept this long — what's above is the whole record that was.",
    c: "INFORMATIONAL",
    fixture: "techy-on",
    why:
      "`main.rs::RAW_NOT_RETAINED`. §2.4's honest degrade: the Tier-B window passed over " +
      "this row and the normalized record above it is untouched. Nothing to do, and it " +
      "deliberately names NO duration — how long raw payloads survive is §7.2, the CEO's " +
      "open question, and a sentence saying '14 days' would answer it in copy.",
  },
  {
    s: "This output was longer than RichOS keeps; you're seeing the start of it.",
    c: "INFORMATIONAL",
    fixture: "techy-on",
    why:
      "`main.rs::RAW_TRUNCATED` — §2.4's 32 KB per-record cap fired and what is on screen " +
      "is a prefix. Nothing to do; the label exists because a prefix that looks whole is " +
      "worse than one that says it is not.",
  },
  {
    s: "The stored output isn't reachable in this build.",
    c: "INFORMATIONAL",
    why:
      "main.js's fallback when `get_machinery_raw` is not a registered command — the mock " +
      "harness, or a shell built without the techy commands. It states the limit rather " +
      "than leaving an empty pane, and there is nothing for the CEO to do about which " +
      "commands his build registered.",
  },
  {
    s: "Technical view · this conversation",
    c: "CONTROL",
    why: "#techy-chip's label when a per-thread pin is holding it on. Pressing it turns it off.",
  },
  {
    s: "Technical view · everywhere",
    c: "CONTROL",
    why: "#techy-chip's label when the global default is holding it on. Same button, different cause.",
  },
  {
    s: "Technical view · this company",
    c: "CONTROL",
    why:
      "#techy-chip's label when a COMPANY pin is holding it on — §7.1's middle tier, added " +
      "on the CEO's answer of 2026-09-18. Third cause, same button. The chip names the tier " +
      "rather than the company, because the scope crumb beside it already names the company " +
      "and two places printing one name is two places that can disagree.",
  },
  {
    s: "Technical view is on for every conversation in this company. Turn it off here.",
    c: "CONTROL",
    why: "#techy-chip's accessible name in the company case, matching the two beside it.",
  },
  {
    s: "Technical view is on for this conversation. Turn it off.",
    c: "CONTROL",
    why: "#techy-chip's accessible name in the pinned case — the label plus what pressing it does.",
  },
  {
    s: "Technical view is on for every conversation. Turn it off here.",
    c: "CONTROL",
    why: "#techy-chip's accessible name in the global case. 'here' because the switch it undoes is in Settings.",
  },
  // THE RAIL'S TECHY GROUP HAS NO ROW HERE ANY MORE, and that is this gate working rather
  // than a gap. Its title was "Show the technical view" and its label "In every
  // conversation"; on 2026-09-18 they became "Technical view" and "Show it" — the
  // subject/act split the Opening screen group below already uses — because a label naming
  // one scope is true of exactly one of the CEO's three choices now that the switch asks
  // which. Both new strings fall under `state-strings.js`'s documented prose floor (12
  // characters AND 3 words), so the scraper does not see them, and the staleness half of
  // the classification check refused the rows the moment they were written: a registry may
  // not claim coverage of a string nothing tracks. Where the switch applies is said in
  // #techy-hint, which IS above the floor and IS classified, three tiers' worth.
  {
    s: "On for this conversation. asks where to change it.",
    c: "CONTROL",
    why:
      "#techy-hint under the Settings switch, with the `${key}` shortcut hole folded out by " +
      "the scraper — it renders as 'On for this conversation. ⌘⇧T asks where to change it.' " +
      "It names WHICH of the three tiers is holding this conversation on, which the switch's " +
      "label carried until 2026-09-18 and can no longer carry, and it describes the KEYBOARD " +
      "affordance beside it. A control's description rather than a state: there is no fault " +
      "here and nothing has gone wrong.",
  },
  {
    s: "On for all conversations in this company. asks where to change it.",
    c: "CONTROL",
    why: "The same hint over §7.1's middle tier — a company pin is holding this one on.",
  },
  {
    s: "On for all conversations in all companies. asks where to change it.",
    c: "CONTROL",
    why: "The same hint over the global tier. Three tiers, three sentences, one hint.",
  },
  {
    s: "asks where to show it.",
    c: "CONTROL",
    why:
      "The OFF branch of #techy-hint: with the technical view off there is no tier to name, " +
      "so the hint is the shortcut, and what the shortcut DOES is ask. All four branches " +
      "promised one conversation ('shows it for one conversation only', 'changes just this " +
      "one') until 2026-09-18, when ⌘⇧T stopped being the entrance that answered the CEO's " +
      "question on his behalf — and that promise had been the whole argument for the " +
      "exception.",
  },

  // ---- §7.1'S THREE-WAY SCOPE SHEET (the CEO's answer, 2026-09-18) ---------------------
  //
  // Every string here is CONTROL and none of them is a state: the sheet is a question the
  // CEO opened by touching a switch, its three answers are radio buttons in front of him,
  // and both ways out (Cancel, Escape) are one keystroke away. Nothing has gone wrong and
  // there is nothing for him to fix — which is the distinction this registry exists to
  // make, and the reason a question's own words are not an ACTIONABLE state.
  {
    s: "Turn on the technical view",
    c: "CONTROL",
    why:
      "#techy-scope-title on the switch-ON path, and the sheet's own accessible name. It " +
      "says which direction the confirm goes, so that is never inferred from which switch " +
      "was touched. Also the markup's shipped default, which is why it is scraped from " +
      "index.html as well as from main.js.",
  },
  {
    s: "Turn off the technical view",
    c: "CONTROL",
    why: "The same title on the switch-OFF path — his 'switch it off for a given company or a given thread'.",
  },
  {
    s: "For all conversations in all companies",
    c: "CONTROL",
    why:
      "His first radio, preselected, in his own words with 'threads' -> 'conversations' — " +
      "the word every other surface in this product says to him.",
  },
  {
    s: "For all conversations in this company",
    c: "CONTROL",
    why:
      "His second radio. Hidden, not disabled, for a conversation with no company binding: " +
      "`ConfigStore::apply_techy_scope` refuses a company scope without one, and offering a " +
      "choice the store will reject is worse than offering two.",
  },
  { s: "For this conversation only", c: "CONTROL", why: "His third radio — the scope ⌘⇧T applies directly." },
  {
    s: "unknown techy scope: {scope}",
    c: "NOT-RENDERED",
    why:
      "`set_techy_scope`'s refusal of a scope this build does not know (main.rs). It never " +
      "reaches the DOM, and there are two independent reasons: the only caller is " +
      "`confirmTechyScope`, which sends the `value` of a radio the SHELL ships, so the " +
      "string cannot be reached from the product at all; and `invokeQuiet` swallows a " +
      "refusal and returns null, on which that function repaints every switch from the " +
      "store rather than rendering a message. It exists so a scope is refused by name " +
      "instead of being rounded to an adjacent tier — which would apply the CEO's switch " +
      "somewhere he did not point it — and the sentence is for whoever reads the log.",
  },

  // ---- §7.2: the raw-retention window, in the same Settings group ----------------------
  //
  // Every hint below follows the #techy-hint precedent two rows up: they sit under the
  // control they describe, in the same popover, and they describe what it does rather than
  // report a fault. Nothing here is a state the CEO is being asked to fix — the three radios
  // are RIGHT THERE, and the sentence exists so that picking one is an informed act rather
  // than a guess about what "whichever binds first" will do to his stored output.
  { s: "Keep the stored output", c: "CONTROL", why: "Settings popover title over the raw-retention radio group." },
  { s: "For two weeks", c: "CONTROL", why: "The `two-weeks` radio's label — the shipping default (`config.rs`)." },
  { s: "For three months", c: "CONTROL", why: "The `three-months` radio's label." },
  {
    s: "Nothing is ever removed.",
    c: "CONTROL",
    why:
      "#retention-hint when both axes are `forever`. It describes what the selected radio " +
      "beside it means, and the whole point of saying it plainly is that eviction is an " +
      "`unlink` nothing else in the product would ever mention.",
  },
  {
    s: "of output — whichever comes first.",
    c: "FRAGMENT",
    why:
      "The tail of #retention-hint's two-axis sentence, with the day and byte holes folded " +
      "out by the scraper — it renders as 'Kept for 14 days, or 2.1 GB of output — whichever " +
      "comes first.' Never on its own.",
  },
  {
    s: "Kept until it reaches",
    c: "FRAGMENT",
    why:
      "The head of the other #retention-hint branch — a byte ceiling with no day window, " +
      "reachable only from a hand-edited config.json. Completed by the size and the row below.",
  },
  {
    s: ", oldest first.",
    c: "FRAGMENT",
    why: "The tail of that same sentence. Says which end of the store the ceiling eats from.",
  },
  {
    s: "Removed the stored output from",
    c: "FRAGMENT",
    why:
      "The head of #retention-hint's announcement after a window change actually evicted, " +
      "completed by the day count and 'The records are still there; their output is not.' " +
      "IT IS THE SENTENCE THE WHOLE CONTROL EXISTS FOR: a delete that says nothing is how a " +
      "CEO finds an empty row weeks later and cannot connect it to anything he did.",
  },
  {
    s: "1 earlier day",
    c: "FRAGMENT",
    why: "The singular arm of that count. 'N earlier days' is the plural and is built from the number.",
  },
  {
    s: "Set by hand in config.json, so none of the three is selected.",
    c: "CONTROL",
    why:
      "#retention-hint when the stored window matches no menu entry (`RetentionChoice::Custom`). " +
      "It explains why no radio is checked instead of checking the nearest one — rounding " +
      "would misreport his setting AND the next click on any other control would write the " +
      "rounded value back over it. The fix, if he wants one, is the radio group it sits under.",
  },
  {
    s: "This build can't reach the retention setting.",
    c: "INFORMATIONAL",
    why:
      "main.js's fallback when `raw_retention` is not a registered command — the mock harness, " +
      "or a shell built without them. Same shape and same reasoning as 'The stored output " +
      "isn't reachable in this build.' above: it states the limit rather than showing a radio " +
      "group with nothing behind it, and there is nothing for the CEO to do about which " +
      "commands his build registered.",
  },
  {
    s: "unknown retention choice: {choice}",
    c: "UNREACHABLE",
    why:
      "`set_raw_retention`'s Err. The only caller in the shipped UI is the change handler over " +
      "`input[name=raw-retention]`, whose three values are exactly the three `RetentionChoice::parse` " +
      "accepts — so the refusal arm is real, is tested in Rust, and no path in the webview reaches it.",
  },

  // -------------------------------------------------------------------------------------
  // UPSTREAM MODEL-API FAILURE (`crates/richos-core/src/upstream.rs`, row 3.30, 2026-09-05)
  //
  // On 2026-09-03 the Anthropic API returned `529 Overloaded` and killed four running
  // agents mid-task, plus a fifth on a session limit. The four `UpstreamFault` sentences
  // below are all INFORMATIONAL and all for the same reason: there is no control in RichOS
  // that makes Anthropic less busy or rolls a usage window over early. An ACTIONABLE
  // classification would owe a control, and inventing one would be worse than the silence
  // it replaces. None of them contains an imperative aimed at the reader.
  // -------------------------------------------------------------------------------------
  {
    s:
      "Anthropic's servers are at capacity, so that request never reached Claude. This " +
      "one ends when their capacity frees up, and nothing on this machine brings it back " +
      "sooner.",
    c: "INFORMATIONAL",
    why:
      "`UpstreamFault::Overloaded` — HTTP 529. Its last clause is the half that does the " +
      "work: it says waiting is the only move AND that waiting has no known end, which is " +
      "exactly what separates it from the 429 row below. Before this existed both arrived " +
      "as the same raw `API Error: …` string relayed into the timeline, so the CEO could " +
      "not tell 'this comes back on its own' from 'this comes back when your window rolls " +
      "over'.",
  },
  {
    s:
      "Your Claude usage limit is used up, so that request never reached Claude. Unlike a " +
      "capacity problem, this one ends on a schedule: your plan's usage window has to roll " +
      "over. RichOS was not told what time that is.",
    c: "INFORMATIONAL",
    why:
      "`UpstreamFault::RateLimited` — HTTP 429. It names the schedule because the schedule " +
      "is the whole difference, and it explicitly declines to name a TIME because no " +
      "captured sample carries a reset timestamp or a Retry-After. Stating a wait it cannot " +
      "measure would be the reassuring-fraction defect in sentence form. INFORMATIONAL " +
      "rather than ACTIONABLE: changing a Claude plan happens on Anthropic's website, not " +
      "in this app, so there is no control here to name.",
  },
  {
    s:
      "Claude's API answered with a server error, so that request never reached the model. " +
      "It is on Anthropic's side rather than yours, and it carries no schedule.",
    c: "INFORMATIONAL",
    why:
      "`UpstreamFault::ServerError` — any 5xx that is not 529. It says 'no schedule' for " +
      "the same reason the overload row does: the CEO's next decision is whether waiting " +
      "is a plan.",
  },
  {
    s:
      "Claude's API refused that request and RichOS has no name for the reason. Its own " +
      "words are kept with this message rather than summarized.",
    c: "INFORMATIONAL",
    why:
      "`UpstreamFault::Unclassified` — an `API Error:` with a status RichOS has no bucket " +
      "for (a 400, a 401, a status invented after this was written). It exists so an " +
      "unknown fault is NAMED as unknown instead of being folded into whichever known arm " +
      "looked closest, which would tell him to wait for something that is not coming. The " +
      "vendor's own line is quoted after it by `UpstreamFailure::ceo_message`.",
  },
  {
    s: "{} Claude reported: {}",
    c: "FRAGMENT",
    why:
      "`UpstreamFailure::ceo_message` — the fault's own sentence, then the vendor's line " +
      "verbatim. The attribution is load-bearing: an `API Error: 529 …` string arriving as " +
      "an assistant message is otherwise appended to the ledger as Rich's own reply, and " +
      "the CEO reads a vendor diagnostic in Rich's voice with no way to tell it from an " +
      "answer.",
  },
  {
    s: "RichOS tried once and stopped there.",
    c: "FRAGMENT",
    why:
      "The singular arm of `RetryBudget::ceo_message`. Written out rather than composed " +
      "with an 's' so the scrape sees a sentence instead of a stem.",
  },
  {
    s: "RichOS tried {} times and stopped there.",
    c: "FRAGMENT",
    why: "The plural arm of `RetryBudget::ceo_message`. The number is the billed attempt count.",
  },
  {
    s:
      "{} {} Each attempt costs against your Claude usage whether or not it produces an " +
      "answer, so it is not repeating this on its own.",
    c: "FRAGMENT",
    why:
      "`RetryBudget::ceo_message`'s frame: the fault's sentence, the attempts spent, then " +
      "why there will not be more. Four consecutive retries on 2026-09-03 consumed quota " +
      "and produced nothing, so the cost is named rather than implied — a ceiling nobody " +
      "is told about is still a silent retry, it just stops sooner.",
  },
  {
    s: "On disk: {}.",
    c: "FRAGMENT",
    why: "`TurnLoss::ceo_message`'s heading for the list of what survived the failure.",
  },
  {
    s: "what you asked for is saved",
    c: "FRAGMENT",
    why:
      "`TurnLoss::ceo_message`, first clause. Read off the ledger — the prompt is journaled " +
      "before it is delivered — never asserted.",
  },
  {
    s: "the {} characters of the answer that had already arrived are saved",
    c: "FRAGMENT",
    why:
      "`TurnLoss::ceo_message`, second clause. A measured count, because every assistant " +
      "delta is persisted before it is emitted, so the number is a fact about the file.",
  },
  {
    s: "and the {} recorded action(s) for this turn are saved",
    c: "FRAGMENT",
    why:
      "`TurnLoss::ceo_message`, third clause. Actions are claimed before they are executed, " +
      "so the record of what was DONE outlives the lease that did it.",
  },
  {
    s: "Nothing had been written to disk yet for this turn.",
    c: "FRAGMENT",
    why:
      "`TurnLoss::ceo_message` when every count is zero — which is the 2026-09-03 shape " +
      "exactly: each of the five agents died between dispatch and its first tool call. It " +
      "is a sentence rather than a list of zeros, and it is always followed by the " +
      "'Not on disk:' clause.",
  },
  {
    s:
      "Not on disk: everything the session had worked out in its head and had not yet " +
      "said. Asking again starts that part over.",
    c: "FRAGMENT",
    why:
      "`TurnLoss::ceo_message`'s closing clause, and the one that must never be dropped. " +
      "The statement never says 'nothing was lost', because the lease's working context is " +
      "always gone on this failure class and implying otherwise is the defect the row names.",
  },

  {
    s:
      "I was cut off partway through that answer, so what you heard is all I got out. " +
      "I'm still listening.",
    c: "INFORMATIONAL",
    why:
      "`VoiceNotice::ReplyCutOff`, added 2026-09-05 for open-items row 3.30. THE ONLY " +
      "NOTICE IN THIS REGISTRY THAT IS SPOKEN ALOUD AS WELL AS SHOWN, and that is the " +
      "requirement rather than a flourish: in voice mode the CEO's eyes are not on the " +
      "panel. What it replaces was worse than silence — on `rich://turn-error` the shell " +
      "called `voice_speak_end`, which FLUSHES the sentence chunker's tail, so a turn that " +
      "died mid-sentence spoke half a sentence aloud, trailed off, and said nothing " +
      "further. Trailing off is exactly what a person does while thinking, so he waited " +
      "for the rest of an answer that was never coming. " +
      "Two things are load-bearing in the wording. It states the CONSEQUENCE — what he " +
      "heard is all there is — because the alternative leaves the question open. And it " +
      "ends with a status rather than 'ask me again': the affordance for asking again is " +
      "the open microphone, there is no button to point at, and an imperative with no " +
      "control is a request wearing a status's clothes — the same reason `SoundButNoWords` " +
      "ends with \"Voice is still on.\" INFORMATIONAL for that reason and not because " +
      "nothing happened. The REASON (a 529, a 429) is a separate sentence supplied by " +
      "`richos-core`'s `upstream.rs` and classified above; voice never invents one.",
  },
  // -------------------------------------------------------------------------------------
  // REACHABILITY (`crates/richos-core/src/reachability.rs`, row 3.30, 2026-09-05)
  //
  // All three are UNREACHABLE, and that classification is the honest one rather than a
  // parking space. The module's only caller today is
  // `examples/reachability_probe.rs` — a `cargo run` operator tool that refuses to send
  // anything without `--spend`. No Tauri command exposes it and no path in the shipped
  // webview reaches these sentences. The module exists so that the FIRST surface to report
  // a reachability status cannot earn it with a cheap ping; when that surface is built,
  // these rows get reclassified against it and measured for contrast then.
  //
  // The fourth arm, `Failed`, mints no literal of its own — it returns
  // `UpstreamFault::ceo_message()`, which is already classified above.
  // -------------------------------------------------------------------------------------
  {
    s:
      "Claude answered a request of {probe_chars} characters just now, which is the size " +
      "RichOS actually sends. It is working.",
    c: "UNREACHABLE",
    why:
      "`ReachabilityVerdict::Reachable`. It names the SIZE rather than saying 'online', " +
      "because on 2026-09-03 a three-character probe succeeded while every large brief died " +
      "on a 529 — so 'it is up' is not a fact and 'it is up for a request this big' is. No " +
      "shipped UI path reaches it: the only caller is the `reachability_probe` example.",
  },
  {
    s:
      "That check sent {probe_chars} characters where RichOS's own work runs to " +
      "{floor_chars}, so it proves nothing about whether real work would get through. A " +
      "small request can succeed while every large one fails.",
    c: "UNREACHABLE",
    why:
      "`ReachabilityVerdict::Unproven`, and the sentence the whole module exists for. It " +
      "says neither 'healthy' nor 'down' — it says the check did not run at the size that " +
      "matters, which is the true answer a cheap ping would have replaced with a green " +
      "tick. Same reachability status as the row above: example-only today.",
  },
  {
    s:
      "RichOS has not sent Claude enough work yet to know what size to test at, so there " +
      "is nothing honest to report about whether it is reachable.",
    c: "UNREACHABLE",
    why:
      "`ReachabilityVerdict::Unmeasured` — a fresh install with no measured request sizes. " +
      "It refuses to probe at all rather than pick a number, because a probe with no scale " +
      "would spend the customer's own Claude quota to learn nothing. Example-only today.",
  },

  // =======================================================================================
  // THE SIX FILES THE INVENTORY COULD NOT SEE UNTIL 2026-09-05
  // =======================================================================================
  //
  // `lib/state-strings.js` read three files — index.html, main.js, timeline.js — while
  // `index.html` shipped nine `<script src>` tags and the tree held twelve product files.
  // Everything from here down was OUTSIDE the affordance rule entirely: a state in any of
  // these could have asked the CEO to do something with no control anywhere near it and
  // this suite would have reported green over it.
  //
  // The source list is derived now (`lib/ui-sources.js`), so these arrived as 55
  // unclassified states the moment the derivation landed, and each one is answered below.
  // They are grouped by file rather than by bucket, because what is worth reading here is
  // which surface had no gate over it — the buckets are on every row anyway.

  // ---- updates.js — the update surface, CEO ruling §26 ----------------------------------
  //
  // THE ONE THAT MATTERS MOST. §26 governs this file, and the clause it turns on is that
  // the update affordance must not be ACTIONABLE while work is running. The gate that would
  // check whether that state names its control could not see the file the state lives in.
  {
    s: "The update did not complete.",
    c: "ACTIONABLE",
    control: "#update-check",
    fixture: "updates-failed",
    why:
      "The `failed` headline for every failure that is not a refused signature. He can act: " +
      "`paint()` keeps `#update-check` visible in `failed` and relabels it 'Try again'. A " +
      "REFUSED SIGNATURE is the deliberate exception — `isSignature(v)` leaves the label as " +
      "'Check for updates' rather than inviting a retry of a security check that will refuse " +
      "identically — and it still has a control, so the row holds in both.",
  },
  {
    s: "It will activate automatically next time RichOS opens. Your work will continue uninterrupted.",
    c: "INFORMATIONAL",
    fixture: "updates-ready",
    why:
      "The `ready` sub-line, and it CHANGED CLASS on 2026-09-10 rather than merely changing " +
      "words. It read 'Restart when you are ready — nothing is lost.', which was an offer, " +
      "and it was ACTIONABLE because `#update-relaunch` stood directly under it. Commit " +
      "01e9b8d8 removed that button from `paint()` — an update now activates at the next " +
      "launch instead of asking him to restart — so the state stopped being one he acts on " +
      "and became one RichOS reports. INFORMATIONAL for the same reason the §26 waiting " +
      "sentence is: the control is REMOVED by design rather than missing, and nothing is " +
      "asked of anyone. Not NEEDS-SOMEONE-ELSE either — the party that will act is RichOS.",
  },
  {
    s: "This update will activate next time RichOS opens. Your work will continue uninterrupted.",
    c: "INFORMATIONAL",
    fixture: "updates-waiting-ready",
    why:
      "CEO ruling §26, and the reason this file had to become visible to this rule. RichOS " +
      "is working, an update is staged, and the restart control is REMOVED rather than " +
      "disabled — 'instead of a regular update button, they'd get some other visual cue but " +
      "not an actionable thing'. So there is deliberately nothing to press, and the sentence " +
      "is INFORMATIONAL rather than ACTIONABLE: it is RichOS saying it will act by itself. " +
      "Not NEEDS-SOMEONE-ELSE either — nobody is being waited on but RichOS. It said 'I'll " +
      "wait to restart until everything has finished' until 01e9b8d8 ended the restart.",
  },
  {
    s: "I'll wait until everything has finished — nothing will be interrupted.",
    c: "INFORMATIONAL",
    fixture: "updates-waiting-available",
    why:
      "The same ruling in the `available` state, and mode-proof on purpose: it does not say " +
      "the button comes back and it does not say RichOS will install by itself, because each " +
      "of those is true of exactly one of the two update modes.",
  },
  {
    s:
      "There is no update server yet, so RichOS cannot check for new versions. Where updates " +
      "are published has not been decided.",
    c: "INFORMATIONAL",
    fixture: "updates-unconfigured",
    why:
      "The `unconfigured` state, and the honest one: this build points at a placeholder " +
      "endpoint. NOT ACTIONABLE — `paint()` disables `#update-check` in exactly this state, " +
      "so there is no control and the row does not claim one. NOT NEEDS-SOMEONE-ELSE either, " +
      "and that is the interesting half: there is no party to name. It is not an operator's " +
      "setting he could be pointed at, it is a decision the RichOS project has not taken, so " +
      "a sentence naming 'whoever set RichOS up' would be inventing an owner. It states the " +
      "fact and stops, which is what an INFORMATIONAL state is for.",
  },
  {
    s: "RichOS has not checked for updates yet.",
    c: "INFORMATIONAL",
    fixture: "updates-idle",
    why:
      "The `idle` state on a launch that has not reached its three-second check. 'Never " +
      "checked' is deliberately a DIFFERENT state from 'checked, and you are current' — a " +
      "row that collapsed the two would be silent about an updater that had stopped running.",
  },
  {
    s: "Checking for updates…",
    c: "INFORMATIONAL",
    why: "The `checking` state. Transient, self-resolving, and nothing is asked of anyone.",
  },
  {
    s: "Checking and preparing the update…",
    c: "INFORMATIONAL",
    why:
      "The `installing` headline. Bytes are already moving; nothing is waiting on him. It " +
      "says PREPARING rather than installing since 01e9b8d8, because the bundle is staged " +
      "for the next launch rather than swapped underneath a running app.",
  },
  {
    s: "RichOS is confirming this update was signed by us before preparing it for the next launch.",
    c: "INFORMATIONAL",
    why:
      "The `installing` sub-line, and it is on screen for a reason: the signature check is " +
      "the property the whole updater rests on, and a step nobody is told about is a step " +
      "nobody misses when it stops happening.",
  },
  {
    s: "RichOS cannot tell what state the update is in.",
    c: "INFORMATIONAL",
    why:
      "The `default` arm — a state the backend sent that this file does not know. It reports " +
      "itself as unknown, which the file's own comment calls the alternative to 'the single " +
      "worst answer this file could give', namely falling back to 'up to date'. `#update-" +
      "check` is visible and enabled here, so he is not stuck; the sentence itself asks " +
      "nothing and claims nothing.",
  },
  {
    s: "It has been ready for a day.",
    c: "INFORMATIONAL",
    why:
      "`readyFor()` at exactly one day. It appears only after a day and never under one, so " +
      "it is not a line that is always there, and it is a fact rather than a nudge — the " +
      "control it would nudge toward is either present already or deliberately absent.",
  },
  {
    s: "Check for updates",
    c: "CONTROL",
    why: "`#update-check`'s label in every state but a non-signature failure, where it reads 'Try again'.",
  },
  {
    s: "Show the technical reason",
    c: "CONTROL",
    why: "`#update-why`'s collapsed label — the vendor's own error text, one press behind the sentence.",
  },
  {
    s: "Hide the technical reason",
    c: "CONTROL",
    why: "The same button once expanded. Both labels ship, so both are in the inventory.",
  },
  {
    s: "Downloading the update",
    c: "CONTROL",
    why:
      "The `aria-label` of `#update-progress`. It is the accessible name of an element, which " +
      "is what this bucket is for — but the element is a `progressbar`, not something to " +
      "press, so it names no affordance and needs none.",
  },
  {
    s: "Open the update settings.",
    c: "CONTROL",
    why:
      "The tail of `#update-cue`'s accessible name, composed as `said + ' Open the update " +
      "settings.'`. The visible label is a STATEMENT ('RichOS 0.1.2 is available.') and a " +
      "button's name should say what pressing it does, so the name is the statement plus the " +
      "act — WCAG 2.5.3 'Label in Name' is why the visible words come first and verbatim.",
  },
  {
    s: "You are running",
    c: "FRAGMENT",
    why: "`'You are running ' + currentVersion + '.'` — the `available` sub-line's tail, never alone.",
  },
  {
    s: "You are still running RichOS",
    c: "FRAGMENT",
    why: "`'You are still running RichOS ' + currentVersion + '.'` — the `failed` sub-line.",
  },
  {
    s: "It has been ready for",
    c: "FRAGMENT",
    why: "`'It has been ready for ' + days + ' days.'` — the plural arm of `readyFor()`.",
  },
  {
    s: "1 minute ago",
    c: "FRAGMENT",
    why: "`when()`'s singular arm, composed into `'Checked ' + when(...) + '.'` and never rendered alone.",
  },
  {
    s: "is up to date.",
    c: "FRAGMENT",
    why: "`current + ' is up to date.'` — the `upToDate` headline's tail.",
  },
  {
    s: "is ready to install.",
    c: "FRAGMENT",
    why: "`waitingSaid()`'s `available` head: `version + ' is ready to install.'`.",
  },
  {
    s: "is ready for the next launch.",
    c: "FRAGMENT",
    why:
      "One literal, used by both `waitingSaid()`'s `ready` head and `sub()`'s `ready` " +
      "headline: `version + ' is ready for the next launch.'`. It read 'is installed and " +
      "needs a restart.' until 01e9b8d8 — the same sentence making a promise the product " +
      "stopped keeping, because there is no restart to need.",
  },

  // ---- update_startup.rs — the activation that runs BEFORE there is a webview -----------
  //
  // NINE STRINGS, ONE CLASSIFICATION, AND THE REASON IS ONE CALL SITE. `update_startup::
  // prepare()` runs at main.rs:898, ahead of home resolution, leases, Tauri and every native
  // worker — its own header says so. Its whole error type is `Result<_, String>`, and
  // main.rs:900-903 is the only thing that ever reads one:
  //
  //     Err(error) => { eprintln!("[richos] application startup: {error}"); return; }
  //
  // `eprintln!` then `return`, before a window exists. So not one of these sentences can
  // reach the DOM, and NOT-RENDERED is the honest class rather than a convenient one — the
  // claim is checkable at that line and fails the moment somebody routes one to the webview.
  //
  // WHAT THAT MEANS FOR THE PERSON, said here rather than filed as covered: an activation
  // that fails this way is an app that does not open, with the reason on a stderr stream
  // nobody is reading. That is a product question about a startup path, not a gap in this
  // rule, and this rule is the wrong place to fix it. It is named in the QA report that
  // added these rows so it is somebody's rather than nobody's.
  {
    s: "Update redirect did not enter an application bundle.",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:52, when the redirected executable is not inside a bundle. Read only by main.rs:900-903 — `eprintln!` and return, before Tauri starts.",
  },
  {
    s: "Application home is unavailable.",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:55, when `HOME` is unset. Same single call site, same `eprintln!` and return, no webview yet.",
  },
  {
    s: "Redirected update changed application data scope.",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:62 — a redirect that would move the user's data. Refused before anything opens; main.rs:900-903 prints it and returns.",
  },
  {
    s: "Invalid update session descriptor.",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:69, on an unparseable inherited `RICHOS_UPDATE_SESSION_FD`. Never leaves stderr.",
  },
  {
    s: "Update activation needs recovery before the app can start: {error}",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:92. A `{error}` Debug hole for an engineer, and unreachable by the webview besides — main.rs returns rather than opening a window.",
  },
  {
    s: "redirected executable disagrees with its verified release",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:105 — the identity check that stops a swapped binary. Fails the launch on stderr; nothing renders it.",
  },
  {
    s: "Changed application cannot redirect to an older release",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:111, refusing a downgrade. Same call site, same stderr-and-return.",
  },
  {
    s: "Changed application has no publication receipt.",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:125 — an activated bundle with no receipt to check. Refused before the window opens.",
  },
  {
    s: "The activated application could not start: {error}",
    c: "NOT-RENDERED",
    why: "`prepare()` at update_startup.rs:132, when the re-executed bundle will not run. The last thing this process does is print it.",
  },

  // ---- startup_alert.rs — the surface the nine rows above did not have -----------------
  //
  // WHAT CHANGED UNDER THE NINE ROWS ABOVE, said here because their line numbers and their
  // "stderr and return" wording predate it. echo-opus-st1 (b052f0b0, merged 2026-09-10)
  // routed that call site through `startup_alert::cannot_start` (now main.rs:934): the
  // engineer's sentence — which is where the nine strings above go — is written to stderr
  // AND to `~/Library/Logs/RichOS/startup.log`, the process exits 1 rather than 0, and the
  // person gets a native system alert carrying ONE fixed sentence instead. So the nine are
  // still NOT-RENDERED, now for a stronger reason: they are the log's text, and the screen
  // shows a different, deliberately generic sentence.
  //
  // The two constants below are what that alert says, and they ARE read by the person —
  // so NOT-RENDERED here means exactly the bucket's definition, "never reaches the DOM",
  // and must not be read as "nobody sees it". The surface is `CFUserNotificationDisplayAlert`
  // (`show_alert`, startup_alert.rs:408-503), raised only while the app has no window (armed
  // at `install`, disarmed at boot complete). This WebKit suite cannot render a CoreFoundation
  // alert, so the rule's question is answered on that surface instead, and the answer is
  // recorded here so a reviewer can check it: the alert carries "OK" and "Show Details", and
  // "Show Details" reveals the log in Finder (`/usr/bin/open -R`, startup_alert.rs:492-499).
  // Classified by echo-opus-ci1; these two are what turned `affordances.js` red on main,
  // first at the echo-opus-st1 merge 8cb30972 (ui-suite-ci run 34458859801).
  {
    s: "RichOS could not open",
    c: "NOT-RENDERED",
    why:
      "`startup_alert::HEADLINE` (startup_alert.rs:150) — the header of the native alert for " +
      "every member of the can't-open class. Read by the person, never by the DOM: it is " +
      "shown only while there is no window to render anything in. See the section note for " +
      "what the alert offers him.",
  },
  {
    s:
      "RichOS ran into an unexpected problem while starting up and closed itself rather " +
      "than open a window that would not work.",
    c: "NOT-RENDERED",
    why:
      "`startup_alert::PANIC_SENTENCE` (startup_alert.rs:155), the body the panic hook " +
      "passes to `cannot_start` for any panic before boot completes. Same native alert, " +
      "same two buttons, and the log's path is appended to it by `person_message` " +
      "(startup_alert.rs:238) so the details are named on the surface itself. Nothing in " +
      "it asks him to act; the fault is not his.",
  },

  // ---- the two remaining update strings, and they are NOT alike -------------------------
  {
    s: "RichOS could not prepare this update.",
    c: "ACTIONABLE",
    control: "#update-check",
    fixture: "updates-install-failed",
    why:
      "`install_failure()`'s headline at updates.rs:271 — the `failed` state with kind " +
      "`install`, which is every staging failure that is not a refused signature. He can " +
      "act, and the control is the same one the network failure names: `isSignature(v)` is " +
      "false here, so `paint()` keeps `#update-check` visible and relabels it 'Try again'. " +
      "It gets its OWN fixture rather than borrowing `updates-failed`, because the row " +
      "claims this headline renders with that control and the network fixture renders a " +
      "different headline.",
  },
  {
    s: "Password-free application updates are not implemented on this platform.",
    c: "UNREACHABLE",
    why:
      "updates.rs:593, and the guard above it is the whole reason: the literal is inside " +
      "`#[cfg(not(target_os = \"macos\"))]`, so it is not compiled into the build this app " +
      "ships. RichOS is macOS-only at v1 — `app/README.md` and `windows-companion-ci.yml` " +
      "both say so — which makes this a sentence that exists for a port that does not exist " +
      "yet. UNREACHABLE rather than NOT-RENDERED: it WOULD render on the update row if such " +
      "a build were ever made, and on that day it needs a class of its own and a party.",
  },

  // ---- the way back off a bad release (2026-09-20) --------------------------------------
  //
  // SIX STRINGS, AND NOT ONE OF THEM ASKS ANYTHING OF HIM. That is the point of the
  // classification rather than an accident of wording: the ACT is the "Go back to <version>"
  // control, which `paint()` offers in `idle`/`upToDate`/`available`/`failed`; everything
  // below is what the row says AFTER he has pressed it, while RichOS does the rest. The same
  // shape, and the same classes, as the update sentences directly above — a rollback and an
  // update are one exchange of two directories, and a surface that treated them as two
  // different kinds of event would eventually describe them inconsistently.
  {
    s: "RichOS will go back to",
    c: "FRAGMENT",
    why:
      "One literal used three times — `sentences()`'s `ready` headline, `cue()`'s pill and " +
      "`waitingSaid()`'s `ready` head — always completed with the version and 'when you " +
      "next open it.'. The counterpart of 'is ready for the next launch.' on the way down, " +
      "and deliberately a different sentence rather than the same one with a smaller " +
      "number: 'ready' says something arrived, and going back is not an arrival.",
  },
  {
    s: "when you next open it.",
    c: "FRAGMENT",
    why:
      "The tail of the sentence above (updates.js:263 and :781). Split only by the version " +
      "in the middle; it never appears alone.",
  },
  {
    s: "It will go back automatically next time RichOS opens. Your work will continue uninterrupted.",
    c: "INFORMATIONAL",
    fixture: "updates-rolling-back",
    why:
      "The `ready` sub-line for a staged rollback, and INFORMATIONAL for exactly the reason " +
      "its update twin four hundred lines above is: the control is REMOVED by design rather " +
      "than missing, nothing is asked of anyone, and the party that will act is RichOS at " +
      "the next launch. Not NEEDS-SOMEONE-ELSE — nobody is being waited on.",
  },
  {
    s: "RichOS is confirming this earlier version was signed by us before preparing it for the next launch.",
    c: "INFORMATIONAL",
    why:
      "The `installing` sub-line while a rollback is verified. Its update twin says 'this " +
      "update'; this one says 'this earlier version', because THE SIGNATURE CHECK IS THE " +
      "SAME CHECK and the sentence has to be able to say so without calling a downgrade an " +
      "update. Bytes are already moving; nothing is waiting on him.",
  },
  {
    s: "Checking and preparing RichOS",
    c: "FRAGMENT",
    why:
      "The `installing` headline for a rollback, completed with the version and an ellipsis " +
      "(updates.js:254). The update arm says 'the update' and has nothing to name; this one " +
      "names the version, because 'preparing the update' over a downgrade would be wrong.",
  },
  {
    s: "Going back to an earlier version is not implemented on this platform.",
    c: "UNREACHABLE",
    why:
      "updates.rs's `rollback`, inside `#[cfg(not(target_os = \"macos\"))]` exactly as the " +
      "'Password-free application updates' row above is, and for the same reason: the " +
      "literal is not compiled into the build this app ships. It is worded as its own " +
      "sentence rather than reusing that one because a person meeting it is asking about a " +
      "different act. Same day as that row's port, same class, same party.",
  },

  // ---- home.js — the home screen the CEO lands on ---------------------------------------
  {
    s:
      "Every button shows a number, and clicking one slides that company's name out. Give a " +
      "button its own label here instead, or take it off the home screen. This changes the " +
      "button only — the company itself, and everything filed under it, stays exactly as it " +
      "is.",
    c: "ACTIONABLE",
    control: "#home-prefs-list input.home-prefs-label",
    fixture: "home-prefs",
    why:
      "The company-buttons dialog's note, and it is an instruction in two clauses — 'Give a " +
      "button its own label here instead, or take it off the home screen'. Both controls are " +
      "in the same dialog: the text box named here, and the checkbox beside it. The text box " +
      "is the one the first clause points at and the one whose absence would make the " +
      "sentence a lie.",
  },
  {
    s: "I couldn't draw the picture on this display. Everything else works.",
    c: "INFORMATIONAL",
    why:
      "`degrade()` — no WebGL, a script that would not load, a shader that would not " +
      "compile. Deliberately not ACTIONABLE and deliberately not an apology with a retry " +
      "button: there is nothing he can do about a display that cannot run the composition, " +
      "and the second clause is the part that matters, because the way through to the app " +
      "stays reachable. `loading.style.pointerEvents = 'none'` is that promise in code.",
  },
  {
    s: "This is what your home screen could look like once Rich knows enough about you and your business.",
    c: "INFORMATIONAL",
    why:
      "The note under the demonstration composition. On an open-source launch it is the " +
      "first sentence a stranger reads inside RichOS, and it deliberately carries no " +
      "asterisk, no 'demo mode' and nothing to dismiss.",
  },
  {
    s: "I can't read your companies right now, so there is nothing to change here yet.",
    c: "INFORMATIONAL",
    fixture: "home-prefs-no-entities",
    why:
      "`prefsFoot()` with zero rows — the backend has not answered, or answered with " +
      "nothing. It is INFORMATIONAL rather than a failure with a retry because the read " +
      "retries itself and the dialog is already open on his own action; what it must not do " +
      "is render an empty list and let him think he has no companies.",
  },
  {
    s: "With one company shown, the buttons are off the home screen — a row of one is just noise.",
    c: "INFORMATIONAL",
    why:
      "`prefsFoot()` at one visible row. The CEO's rule — 'the company buttons should only " +
      "appear if the user has more than one company' — stated where the control that " +
      "produced it is, so a row disappearing is explained rather than mysterious.",
  },
  {
    s: "With no companies shown, the buttons are off the home screen.",
    c: "INFORMATIONAL",
    why: "The same line at zero visible rows, said without the aside that only fits the one-row case.",
  },
  {
    s: "RichOS — go to the home screen",
    c: "CONTROL",
    why:
      "The rail wordmark's accessible name once `bindWordmark()` gives it `role=button`. It " +
      "is the CEO's own instruction — 'a click on the logo (in the upper left corner) brings " +
      "the user back to the home screen' — and the name says where it goes rather than what " +
      "it is a picture of.",
  },
  {
    s: "Which company this picture is of",
    c: "CONTROL",
    why:
      "`#home-entities-label`, the accessible name of the entity row's `role=group`. It " +
      "labels a set of controls; it is not a state anything can be in.",
  },
  {
    s: "Company buttons on the home screen",
    c: "CONTROL",
    why:
      "`#home-prefs-title`, and the dialog's own accessible name through `aria-labelledby`. " +
      "A heading that names the surface it opens, not a state the surface can be in.",
  },
  {
    s: "button says on the home screen",
    c: "FRAGMENT",
    why:
      "`'What the ' + name + ' button says on the home screen'` — each label box's accessible " +
      "name, composed around the company's name and never rendered without it.",
  },
  {
    s: "showing on the home screen.",
    c: "FRAGMENT",
    why: "`shown + ' of ' + rows.length + ' showing on the home screen.'` — `prefsFoot()`'s ordinary arm.",
  },
  {
    s: "did not load",
    c: "NOT-RENDERED",
    why:
      "`new Error(src + ' did not load')` in the script loader. It reaches `state.fieldError` " +
      "and stops there: `degrade()` records the reason and paints its own fixed sentence, so " +
      "no path puts this text on screen. Verified by reading every use of `state.fieldError` " +
      "— it is written at home.js:815 and :1234 and read nowhere.",
  },
  {
    s: "the picture did not start within 8 seconds",
    c: "NOT-RENDERED",
    why:
      "`settled()`'s deadline rejection, and the bound on how long the honest failure can " +
      "take. Same path as above: it becomes `state.fieldError`, which nothing renders.",
  },
  {
    s: "the home screen would not build:",
    c: "NOT-RENDERED",
    why:
      "The `start()` catch. A home screen that will not build leaves NOTHING behind and the " +
      "app boots normally, so there is no surface for this to be printed on — which is the " +
      "posture `splash.js` takes for the same reason.",
  },

  // ---- home/field-engine.js — the WebGL composition's own text --------------------------
  {
    s: "loro · <span class=\"v\" data-k=\"months\"></span> months · <b><span class=\"v\" data-k=\"memories\"></span> memories</b>",
    c: "INFORMATIONAL",
    why:
      "`#home-brand-line`. It renders as 'loro · 14 months · 7,500 memories' — the two " +
      "numbers are filled by `setSignals()` and the markup is the sentence's skeleton. " +
      "Nothing is asked; it is the composition saying what it is a picture of.",
  },
  {
    s: "· working now",
    c: "FRAGMENT",
    why: "`'· ' + N + ' working now'`, the small line under the specialist count. Never alone.",
  },
  {
    s: "tasks handled without you",
    c: "FRAGMENT",
    why: "A signal's label, rendered under its number by `sig()`. The number is the sentence.",
  },
  {
    s: "of your attention saved",
    c: "FRAGMENT",
    why: "The same shape: `'1,234 h'` above, this beneath it.",
  },
  {
    s: "an email thread",
    c: "FRAGMENT",
    why:
      "`SOURCE_WORD['email-thread']`, composed into the learning ticker — 'Ash learned from " +
      "an email thread · Finance → 3 new memories'. One noun out of a ten-entry map.",
  },
  {
    s: "· <i></i> → new memor",
    c: "FRAGMENT",
    why:
      "The ticker's own skeleton between its interpolations, caught by the scrape as the " +
      "literal run of text between `${}` holes. It is three fragments of one sentence, and " +
      "the sentence is the row above.",
  },
  {
    s: "the picture could not start",
    c: "NOT-RENDERED",
    why:
      "The last-resort value of `window.__loroFailed` when the thrown error carried no " +
      "message. `home.js`'s `settled()` reads it, rejects, and `degrade()` paints its own " +
      "sentence — so this string is a diagnostic the CEO never sees.",
  },

  {
    s:
      'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), ' +
      'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    c: "NOT-RENDERED",
    why:
      "`home.js`'s FOCUSABLE — the CSS selector the home screen uses to find the control a " +
      "desk sheet would have focused itself, had the screen let it. A selector, never prose.",
  },

  {
    s: "It has reached this Mac. Check that the six words on it are the six words below, then press They match.",
    c: "ACTIONABLE",
    control: "#phone-mac-match",
    why:
      "The phone card while a phone that redeemed the code waits for the press ON THIS MAC — " +
      "Sage's pairing review F1 (High), 2026-09-24: the phone's own confirmation was the only one " +
      "the Mac recorded, so a device that paired first with a code seen on a screen share could " +
      "confirm itself. The answer is now given here: They match (#phone-mac-match) activates the " +
      "phone, They do not match (#phone-mac-mismatch) runs the rejection teardown, and both are " +
      "on the card beside the six words. Until then the phone's key reaches nothing. ui/tests/" +
      "phone.js checks 9e and 9g press both and measure the sentence and the buttons in both themes.",
  },
  {
    s: "This Mac accepted it. Finish on your phone by pressing They match there too.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "the paired card's own name line above it, which names the phone that still has to answer",
    why:
      "The phone card after the press on this Mac and before the phone's own answer arrives " +
      "(Sage F1): the Mac's half is done, and the remaining act is on the phone the heading names. " +
      "The card polls until the phone answers, then says It is paired.",
  },
  {
    s: "This Mac accepted it. Waiting for your phone to finish.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "the paired card's own name line above it, which names the phone that has not used the pairing yet",
    why:
      "Sage's pair-v2 hypotheses review §2, 2026-09-24: both presses are in and the phone has not " +
      "made its first ordinary request yet (`PhoneStatus.completed === false`). The press on this " +
      "Mac is not evidence the phone heard it — a phone that lost the Mac throws its key away at " +
      "its deadline — so `It is paired` waits for the phone to use the pairing. Nothing is his to " +
      "do here: the remaining act is the phone's, which the card names; the card polls, and moves " +
      "to `It is paired` or to the stopped screen by itself. Forget this phone stays on the card. " +
      "ui/tests/phone.js check 9e reads the sentence.",
  },
  {
    s: "Someone used this phone's pairing code again after you paired it. If you did not expect that, press Forget this phone and pair again where nobody else can see this screen.",
    c: "ACTIONABLE",
    control: "#phone-forget",
    why:
      "Sage's spent-code alarm, the keep-it-and-warn half: a second correct use of the pairing " +
      "code AFTER the person confirmed the phone on this Mac. The phone is kept (he confirmed it), " +
      "and the card says what happened and names the control that undoes it, which is on the " +
      "same card. ui/tests/phone.js check 9h.",
  },
  {
    s: "It is paired. Open Rich on it and keep talking.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "the paired card's own name line above it, which names the phone that answered",
    why:
      "The phone card once the phone has confirmed the six words: the next act is on the phone, " +
      "which the sentence names; the Mac's own controls here are Forget this phone and Close.",
  },

  // ---- settings-button.js — the universal settings button, CEO ruling §15 ----------------
  {
    s:
      "That was set when RichOS was started up, from outside this window, so it can't be " +
      "changed from in here — whoever set RichOS up is the one who changes it.",
    c: "NEEDS-SOMEONE-ELSE",
    why:
      "The pinned-company row's `title`. He cannot change it and the sentence names who can, " +
      "which is the whole of this bucket's contract. It is also the row `affordances.js` " +
      "already drove by hand — 'a company pinned outside the window is stated, never offered " +
      "as a dead control' — with a comment saying the string inventory could not see it. It " +
      "can now, so the hand-written cover and the derived rule agree on the same sentence.",
  },
  {
    s:
      "Got it — the bug report starts from this exact screen, as it stands. Nothing leaves " +
      "this machine until you say so.",
    c: "INFORMATIONAL",
    why:
      "The 'Bust a bug' acknowledgement toast. What the button opens is not designed yet, and " +
      "a control that appears to do nothing is indistinguishable from a broken one — so it " +
      "says the one thing that IS decided. Nothing is asked of him; the second sentence is a " +
      "promise, not an instruction.",
  },
  {
    s: "Follow the system",
    c: "CONTROL",
    why:
      "The accessible name of the theme segment's middle option. §15 makes `system` something " +
      "he can pick and never the thing he gets without picking, which is why it is a control " +
      "and not a state.",
  },

  // ---- splash.js and splash-library.js — the opening curtain ----------------------------
  {
    s: "The Operating System for the AI-Enabled CEO",
    c: "INFORMATIONAL",
    why:
      "The only text on the opening curtain, at 18px — above §15's 16px floor for text meant " +
      "to be read. The curtain is `pointer-events: none` for its whole life and yields on the " +
      "first of three signals, so there is nothing on the surface to act on by construction.",
  },
  {
    s: "Splash screen #1 — the ruled standard, the rule struck along its own ghost",
    c: "NOT-RENDERED",
    why:
      "A library entry's `name` field. `splash.js` reads `id`, `seconds` and `tokens` from an " +
      "entry and never `name` — it is there so a person opening `splash-library.js` can tell " +
      "the two approved compositions apart. Verified: `entry.name` appears nowhere in " +
      "splash.js.",
  },
  {
    s: "Splash screen #2 — midnight suede, the strap sewn live in gold thread",
    c: "NOT-RENDERED",
    why: "The second entry's `name`, on the same footing as the first.",
  },
  {
    s: "not a fresh launch (",
    c: "NOT-RENDERED",
    why:
      "`state.declined`, which records WHY the curtain did not run. It is read by " +
      "`RichSplash.state()` for the suite and painted nowhere — the whole point of the branch " +
      "is that a crash-restart costs nothing at all, and printing an explanation would be a " +
      "cost. Verified: every use of `state.declined` in splash.js is a write.",
  },
  {
    s: "no usable variation in the library",
    c: "NOT-RENDERED",
    why: "The same field, for a missing, unparseable or wholly malformed library.",
  },
  {
    s: "the chosen variation would not render:",
    c: "NOT-RENDERED",
    why:
      "The same field again, after `build(entry)` threw. `removeSelf()` runs first, so the " +
      "launch is a normal one with nothing drawn and there is no curtain left to print on.",
  },

  // -------------------------------------------------------------------------------------
  // WHY HIS OWN LORO IS NOT THE PICTURE (`home_field_data`, 2026-09-06)
  //
  // Four reasons the home screen keeps drawing the demonstration. NOT ONE OF THEM REACHES
  // THE DOM, and that is the design rather than an oversight: the demonstration is what the
  // CEO asked to keep — *"The demo is definitely needed, initially, for the user"* — so a
  // launch that draws it has nothing to report. There is no failure to explain, no request
  // to make of him, and nothing for him to act on; the screen already carries the one
  // sentence that matters, which is the first-run banner.
  //
  // Two land on `RichHome.state.fieldOffer`, which the acceptance suite reads and the CEO
  // never sees. Two are `eprintln!` in the boot log, which is the operator's window and not
  // his — the same split `MemoryStatus::detail` already uses.
  // -------------------------------------------------------------------------------------
  {
    s: "the backend said nothing about a corpus",
    c: "NOT-RENDERED",
    why:
      "`home.js`'s own words for an answer that was not a positive `available: true` with a " +
      "dataset attached. Recorded on `state.fieldOffer.reason` for the acceptance suite; " +
      "nothing renders it, because the screen is drawing the demonstration and that is what " +
      "it is supposed to be doing.",
  },
  {
    s: "the corpus did not compile within",
    c: "NOT-RENDERED",
    why:
      "The head of `home.js`'s timeout sentence (it continues with the millisecond ceiling). " +
      "Same destination: `state.fieldOffer.reason`, read by the suite and by nobody else. A " +
      "timeout is not evidence of anything, so the demonstration stays and says nothing new.",
  },
  {
    s: "the corpus could not be read: {e}",
    c: "NOT-RENDERED",
    why:
      "`main.rs::home_field_data`, the census-probe failure, returned as `reason` on an " +
      "`available: false` answer and printed to the boot log beside it. Machine-facing: `{e}` " +
      "is a compiler's stderr line, which is not CEO copy — the same split `MemoryStatus` " +
      "makes between its `detail` and the surface's own sentence.",
  },
  {
    s: "the corpus could not be compiled: {e}",
    c: "NOT-RENDERED",
    why:
      "The same, for the arm where every topic failed to compile. Neither string is shown to " +
      "the CEO and neither asks anything of him; whoever set RichOS up reads them in the " +
      "boot log.",
  },
  // -------------------------------------------------------------------------------------
  // THE WAITING STATE (main.js "THE WAITING STATE", 2026-09-06)
  // -------------------------------------------------------------------------------------
  //
  // Eight strings, added because the first outside user of RichOS said a long turn "looks
  // like a crashed application" and the app had one 14px line and a 5px dot to answer him
  // with. Every one is a STATEMENT of something observed — none asks the CEO for anything,
  // and none can be made true or false by an act of his. `#stop` is visible for the whole
  // of every live turn (`syncComposerMode`), so a CEO who wants the turn back always has
  // the control; it is simply not what any of these sentences is about.
  //
  // Kept together at the end of the file, on purpose: `app/ui/tests/**` belongs to another
  // engineer this session, so this block is strictly additive and touches no existing row.
  {
    s: "Rich is working",
    c: "INFORMATIONAL",
    why:
      "The waiting band's headline for `rich://turn-status: working` — the ledger's own " +
      "transition, read back out of the ledger before it is emitted (`spine.rs` " +
      "`turn_status_event`). A statement about a turn, with nothing in it for him to do.",
  },
  {
    s: "Rich has your message",
    c: "INFORMATIONAL",
    why:
      "The same band's headline for `queued`: the prompt is durably `received` and no lease " +
      "has been handed it yet. Nothing to act on — the turn moves itself to `working`.",
  },
  {
    s: "Waiting to start",
    c: "INFORMATIONAL",
    why:
      "The detail line under `queued`, and the whole content of that state: the message is " +
      "recorded and the work has not begun. It reports; it does not ask.",
  },
  {
    s: "Rich is picking this back up",
    c: "INFORMATIONAL",
    why:
      "The headline for `rich://turn-status: recovering` — a turn whose lease died and is " +
      "being replayed. The replay is automatic (`spine.rs`), so there is nothing to press.",
  },
  {
    s: "Rich is letting go of this turn",
    c: "INFORMATIONAL",
    why:
      "The headline while a CEO stop is in flight, set from `stop_turn`'s durable answer " +
      "rather than an event (the same source `timeline.js`'s `stopping` row uses). He has " +
      "already acted; this is the acknowledgement of it.",
  },
  // REMOVED 2026-09-20: "Nothing has come back yet". The product no longer renders it, so the
  // row goes with it — part 1's exact set comparison is the thing that makes this registry a
  // record of the shipped product rather than of its history. What used to occupy this state
  // (zero content events on a turn watched from its start, under the quiet threshold) is now
  // an EMPTY detail, which is not a string and therefore has no row: Ray's `.20260920.1` walk
  // measured the sentence on the real window for 10.5-14.5 s on five healthy turns and named
  // it a report of absence sitting where the eye settles (defect 2 of
  // `docs/verification/2026-09-20-nightly-1.2.0-nightly.20260920.1-mac-to-phone-in-the-vm-audit.md`).
  // The silence is still named, past QUIET_AFTER_MS, by "Nothing new for" below.
  {
    s: "Nothing new for",
    c: "FRAGMENT",
    why:
      "Template hole: completed by a formatted duration (`Nothing new for 41s`). The whole " +
      "sentence is informational — it says how long it has been since the last event the " +
      "timeline accepted for this thread, which is true at every value it can take.",
  },
  {
    s: "Writing the reply",
    c: "INFORMATIONAL",
    why:
      "What `rich://message-started` / `message-delta` licenses and nothing more. `phase` is " +
      "`unknown` on every message this runtime emits (`live.rs`), so naming a kind of " +
      "writing would be inventing one.",
  },

  // ---- THE FIRST-RUN NOTICE (2026-09-06) ------------------------------------------------
  //
  // The visible half of the onboarding offer. Every sentence of the offer is ACTIONABLE and
  // every one of them names a control that is on screen beside it, because that is the whole
  // shape of this surface rather than a property it happens to have: the notice exists to put
  // a state the CEO can change next to the two things that change it.
  //
  // Two of its states are NEEDS-SOMEONE-ELSE and both name the party in their own words. The
  // `PARTY` regex gained `Whoever set RichOS up` on the same day for that reason — it already
  // carried both cases of "operator" and only one of this phrase.
  {
    s: "I don't know your business yet.",
    c: "ACTIONABLE",
    control: "#first-run-start",
    fixture: "first-run-offer",
    why:
      "The headline of the first-run notice. It is a state he can change — that is the point " +
      "of it — and the control that changes it is in the same panel, two lines below.",
  },
  {
    s:
      "There's nothing on file about what this company does, who it's for, or how you want to " +
      "work. I can ask you about it — about twenty minutes — and write your answers down, so I " +
      'use them from then on. You can stop partway, and "not sure yet" is a real answer to any ' +
      "of it.",
    c: "ACTIONABLE",
    control: "#first-run-start",
    fixture: "first-run-offer",
    why:
      "The offer itself. It names the cost in his own units, the one promise the chain can " +
      "keep, and that stopping partway is honest — and it renders with the control that " +
      "starts it.",
  },
  {
    s: "\"Not now\" means I'll stop offering. You can start it any time by asking.",
    c: "ACTIONABLE",
    control: "#first-run-later",
    fixture: "first-run-offer",
    why:
      "What the second control DOES, stated beside it. The write is durable and a " +
      "two-syllable label cannot carry that and stay speakable, so the effect is in words " +
      "and the control it describes is the one it names.",
  },
  {
    s: "Start the questions",
    c: "CONTROL",
    why: "The label of `#first-run-start`.",
  },
  {
    s: "Let's do the twenty minutes of questions about my business.",
    c: "CONTROL",
    why:
      "TWO THINGS AT ONCE, so both are said here rather than forced into one bucket. It is " +
      "not a state of the app and never renders as one: it is the payload `#first-run-start` " +
      "sends through the ordinary `send()` path, and it renders as the CEO's own turn in the " +
      "conversation, because he did send it — he pressed a button whose label is exactly " +
      "this. Filed CONTROL as the closest honest bucket: it is an affordance's effect spelled " +
      "out, not a status that owes one.",
  },
  {
    s: "Left with you. Ask me any time and we'll go through it.",
    c: "INFORMATIONAL",
    why:
      "The receipt for a press that wrote something down, and there is genuinely nothing to " +
      "do about it — it names the way back rather than asking for one. It is not an " +
      "instruction: he has already given the answer this acknowledges, and nothing is waiting " +
      "on him. It is gone at the next launch, when the state is `declined` and the notice " +
      "renders nothing.",
  },
  {
    s: "I couldn't read your notes about this company.",
    c: "NEEDS-SOMEONE-ELSE",
    explainedBy: "I'm working without them, and I won't guess at what they said. Whoever set RichOS up will need to look at that.",
    fixture: "first-run-unusable",
    why:
      "A file on disk that the app cannot use. Nothing the CEO can press fixes it, and the " +
      "notice deliberately draws no control in this state. The party is named by the sentence " +
      "directly beneath it, in the same panel, which is what `explainedBy` points at.",
  },
  {
    s:
      "I'm working without them, and I won't guess at what they said. Whoever set RichOS up " +
      "will need to look at that.",
    c: "NEEDS-SOMEONE-ELSE",
    fixture: "first-run-unusable",
    why:
      "The consequence and the party, in one sentence. \"I won't guess\" is not decoration — " +
      "it is `UNUSABLE_BLOCK`'s own instruction to Rich, said on screen so the window and the " +
      "conversation make one claim rather than two.",
  },
  {
    s:
      "I couldn't write that down, so it isn't recorded and I'll ask again next time. I'd " +
      "rather say so than let you think it was settled. Whoever set RichOS up will need to " +
      "look at that.",
    c: "NEEDS-SOMEONE-ELSE",
    fixture: "first-run-decline-refused",
    why:
      "\"Not now\" could not be written. He can press it again and it may work, but what would " +
      "MAKE it work is somebody else's — so it is classified by the thing he cannot do, and " +
      "the offer is deliberately left open behind it. Closing the notice here would report " +
      "success over work that did not happen.",
  },
  { s: "Sending your message", c: "INFORMATIONAL", why: "The invoke is pending. This does not claim the backend has accepted the words." },
  { s: "Waiting for Rich to accept it", c: "INFORMATIONAL", why: "The local request has no authoritative queued event yet." },
  { s: "Your message is recorded.", c: "INFORMATIONAL", why: "The queued event follows the durable acceptance." },
  { s: "Rich is picking this back up.", c: "INFORMATIONAL", why: "A one-time announcement of an authoritative recovery transition." },
  { s: "Resume the questions", c: "CONTROL", why: "The existing Start control continues an incomplete interview." },
  { s: "Let's pick up the questions about my business where we stopped.", c: "CONTROL", why: "The explicit Resume acceptance sent through the ordinary message path." },
  { s: "Your business notes are started.", c: "ACTIONABLE", control: "#first-run-start", fixture: "first-run-partial", why: "Saved partial answers have a Resume control in the same panel." },
  { s: "Your saved answers are kept. We can pick up the remaining questions where we stopped. Press Resume the questions when you're ready.", c: "ACTIONABLE", control: "#first-run-start", fixture: "first-run-partial", why: "Explains that resuming keeps existing answers and names the control beside it." },

  { s: "Missing onboarding scope", c: "NOT-RENDERED", why: "The standalone onboarding MCP process reports this on stderr when launched without its required scope argument. It is not displayed in the app." },
  { s: "Missing status scope", c: "NOT-RENDERED", why: "The same shape one file down: the standalone status MCP process (`--status-mcp`, the front desk's read) reports this on stderr when launched without its required scope argument. A child of the running app, so `activation.rs`'s parent-pid condition is false by construction and no alert is armed. It is not displayed in the app." },
  { s: "Missing report scope", c: "NOT-RENDERED", why: "The same shape as `Missing status scope`: the standalone operator report MCP process (`--operator-mcp`, operator back-end spec r2 (c)) reports this on stderr when launched without its scope argument. Only an operator lead on an install whose operator.json passed the gate is ever given this server; it is a child process, so no alert is armed, and it is not displayed in the app." },
  { s: "operator report server: {error}", c: "NOT-RENDERED", why: "The operator's `reason` in `~/Library/Logs/RichOS/startup.log` for a report-server failure, the same machinery half as `status tool server:` beside it. It never reaches the window." },
  { s: "status tool server: {error}", c: "NOT-RENDERED", why: "The operator's `reason` in `~/Library/Logs/RichOS/startup.log` for a status-server failure, alongside `assignment tool server:` and `onboarding tool server:` beside it. It is the machinery half of that call and never reaches the window. The CEO-facing half beside it — the sentence about the helper that looks at work already running — is not in this inventory either, and neither are its two siblings: the Rust scrape does not reach a `startup_alert::cannot_start` argument, which is a pre-existing blind spot of the scrape rather than something this row covers." },
  { s: "The company changed. Please use the offer for the company now open.", c: "INFORMATIONAL", why: "An obsolete company-specific action was refused. The onboarding context guard refreshes the current offer and retains its controls." },
  {
    s: "Open a conversation first.",
    c: "ACTIONABLE",
    control: "#rail-new-thread",
    fixture: null,
    why:
      "`send_prompt`'s refusal at main.rs:518, three lines above its neighbour and reached " +
      "the other way: `spine.active_thread()` is None, so there is no conversation to file " +
      "the message under. ACTIONABLE and the control is `#rail-new-thread`, the rail's own " +
      "new-conversation button — one press makes the thread the message needed. NO FIXTURE, " +
      "and the reason is a real one rather than an omission: every path a browser can drive " +
      "reaches the composer through a thread that already exists, so the mock bridge has no " +
      "way to present a live composer with no active thread. The control claim is held " +
      "statically here and `#rail-new-thread` is asserted present on every shell walk.",
  },
  { s: "Waiting for its saved messages", c: "INFORMATIONAL", why: "The selected conversation has not finished loading." },
  { s: "No messages in this conversation yet.", c: "INFORMATIONAL", why: "An empty cached destination while its ordered activation is pending." },
  { s: "invalid P-256 private key encoding", c: "NOT-RENDERED", why: "Internal PhoneError::Crypto detail; phone commands map it through ceo_sentence before returning to the webview." },
  { s: "This conversation is still working. Press Stop to stop that work.", c: "ACTIONABLE", control: "#stop", fixture: "returning-conversation", why: "Returning to the working thread preserves its Stop while activation is queued." },
  { s: "I couldn't stop this conversation. Press Stop again.", c: "ACTIONABLE", control: "#stop", fixture: "returning-stop-failed", why: "A failed Stop remains retryable when returning to the working thread." },
  { s: "Stopping work in this conversation", c: "INFORMATIONAL", why: "A durable Stop receipt targets the selected working thread." },
  { s: "The previous conversation is still working. Press Stop to stop that work.", c: "ACTIONABLE", control: "#stop", fixture: "opening-conversation", why: "The previous live model keeps its actual Stop control while navigation waits for its lock." },
  { s: "I couldn't stop the previous conversation. Press Stop again.", c: "ACTIONABLE", control: "#stop", fixture: "opening-stop-failed", why: "A failed stop remains visible in the opening band beside the retryable Stop control." },

  { s: "Stopping work in the previous conversation", c: "INFORMATIONAL", why: "A durable Stop receipt disables repeat Stop while awaiting its terminal event." },

  // Shipped repository, permission, account and saved-work surfaces.
  {
    "s": "<div class=\"overlay-panel overlay-panel--compact\"> <h2 id=\"repositories-title\" class=\"overlay-title\">Connected repositories</h2> <p class=\"overlay-note\">Connect the repositories Rich may use for this company's assignments. Existing files and local changes stay in place.</p> <label class=\"entity-add-label\" for=\"repository-company\">Company</label> <select id=\"repository-company\" class=\"entity-add-input\"></select> <ul id=\"repository-list\"></ul> <label class=\"entity-add-label\" for=\"repository-folder\">Repository folder</label> <input id=\"repository-folder\" class=\"entity-add-input\" type=\"text\" placeholder=\"/Users/you/Projects/project\" autocomplete=\"off\" spellcheck=\"false\"> <label class=\"overlay-note\"><input id=\"repository-initialize\" type=\"checkbox\"> Initialize Git if this folder is empty</label> <p id=\"repository-message\" class=\"overlay-note\" role=\"status\"></p> <div class=\"desk-card-actions\"><button id=\"repository-connect\" class=\"desk-btn desk-btn--confirm\" type=\"button\">Connect repository</button> <button id=\"repository-close\" class=\"desk-btn\" type=\"button\">Close</button></div></div>",
    "c": "FRAGMENT",
    "why": "Composite HTML for the repository connection dialog. Its interactive controls and visible wording are exercised by the dedicated browser suite; this literal is parsed as markup rather than rendered as one sentence."
  },
  {
    "s": "<div class=\"overlay-panel overlay-panel--compact\"><h2 id=\"permission-title\" class=\"overlay-title\">Allow this action?</h2> <p id=\"permission-description\" class=\"overlay-note\"></p><p id=\"permission-scope\" class=\"overlay-note\"></p> <button id=\"permission-detail\" class=\"desk-btn desk-btn--plain\" type=\"button\" aria-expanded=\"false\" aria-controls=\"permission-input\">Show the technical detail</button> <pre id=\"permission-input\" class=\"desk-preview\" style=\"max-height:45vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere\" hidden></pre> <p id=\"permission-status\" class=\"overlay-note\" role=\"status\">This permission applies only to this action.</p> <div class=\"desk-card-actions\"><button id=\"permission-deny\" class=\"desk-btn\" type=\"button\">Decline</button> <button id=\"permission-allow\" class=\"desk-btn desk-btn--confirm\" type=\"button\">Allow action</button></div></div>",
    "c": "FRAGMENT",
    "why": "Composite HTML for the native permission dialog. Its interactive controls and visible wording are exercised by the dedicated browser suite; this literal is parsed as markup rather than rendered as one sentence."
  },
  // The disclosure over the raw request (audit-9 row 5). Two labels, one control: each says
  // what the press does, and both survive being spoken aloud. The state they report is also
  // on the element as `aria-expanded`, so a screen reader is not relying on the wording.
  {
    "s": "Show the technical detail",
    "c": "CONTROL",
    "why": "The label of #permission-detail while the exact request is closed. It is an affordance, not a state: pressing it opens the `<pre>` beside it and nothing else. `tests/permissions.js` check 4 drives it by keyboard."
  },
  {
    "s": "Hide the technical detail",
    "c": "CONTROL",
    "why": "The same control's label once the exact request is open. Both halves are asserted in `tests/permissions.js` check 4, so a label that stopped matching the state would fail there."
  },
  // ---------------------------------------------------------------------------------------
  // THE QUIT QUESTION — the background-work spec §2.5/§2.5a, and the CEO's row 5.
  //
  // Closing the window no longer quits, so this sheet is what he meets when he chooses Quit
  // with work running. By the time any of it renders the exit has ALREADY been prevented,
  // which is why "Keep working" changes nothing at all and is the focused answer.
  // ---------------------------------------------------------------------------------------
  {
    "s": "<div class=\"overlay-panel overlay-panel--compact\"> <h2 id=\"quit-question-title\" class=\"overlay-title\">Quit while work is running?</h2> <p id=\"quit-question-say\" class=\"overlay-note\"></p> <div class=\"desk-card-actions\"> <button id=\"quit-question-stay\" class=\"desk-btn\" type=\"button\">Keep working</button> <button id=\"quit-question-quit\" class=\"desk-btn desk-btn--confirm\" type=\"button\">Quit and stop the work</button> </div> </div>",
    "c": "FRAGMENT",
    "why": "Composite HTML for the quit question. Its interactive controls and visible wording are exercised by the dedicated browser suite (ui/tests/quit-question.js), in both themes; this literal is parsed as markup rather than rendered as one sentence."
  },
  {
    "s": "Quit and stop the work",
    "c": "CONTROL",
    "why": "The destructive answer on the quit question, named for what it does rather than OK - it is the one control in this app that ends running background work on purpose. Its words are the shell's (lifecycle.rs's QUIT_AND_STOP), so what the button says and what the process does cannot drift apart. It is never the focused control."
  },
  {
    "s": "Something is still running in the background.",
    "c": "ACTIONABLE",
    "why": "The quit question's fallback sentence, used only if the shell's own wording did not arrive with the event. He is being asked to choose, and both answers are on the same sheet: Keep working (the focused, safe one) and Quit and stop the work.",
    "control": "#quit-question-stay"
  },
  {
    "s": "That could not be done:",
    "c": "FRAGMENT",
    "why": "The prefix of a refusal on the quit question, with the backend's own reason appended. It never renders alone, and it is said rather than swallowed: he pressed something, and a sheet that silently did nothing would be worse than a refusal he can read."
  },
  {
    "s": "Account connection could not be verified. Try again.",
    "c": "ACTIONABLE",
    "why": "The failed account check offers the same sign-in button for another attempt.",
    "control": "#provider-connect",
    "fixture": "provider-poll-error"
  },
  {
    "s": "Add a company before connecting repositories.",
    "c": "ACTIONABLE",
    "why": "Close the repository sheet to reach company creation in the main company picker; a repository cannot be attached until a company exists.",
    "control": "#repository-close"
  },
  {
    "s": "Another conversation is working. Saved work will refresh when it settles.",
    "c": "INFORMATIONAL",
    "why": "The refresh waits for the other conversation to release its lock."
  },
  {
    "s": "Anthropic Console (API billing)",
    "c": "CONTROL",
    "why": "An account-kind option in the sign-in selector."
  },
  {
    "s": "Checking this repository…",
    "c": "INFORMATIONAL",
    "why": "The native repository validation is in progress."
  },
  {
    "s": "Checking your account connection.",
    "c": "INFORMATIONAL",
    "why": "Account status is being loaded."
  },
  {
    "s": "Choose a company",
    "c": "CONTROL",
    "why": "The unselected option asks for an explicit company choice."
  },
  {
    "s": "Git initialized and repository connected.",
    "c": "INFORMATIONAL",
    "why": "Confirms the completed repository connection."
  },
  {
    "s": "No repositories connected.",
    "c": "ACTIONABLE",
    "why": "The company selector begins the explicit connection flow; repositories.js checks selection, folder entry and connection.",
    "control": "#repository-company",
    "fixture": "repository-empty"
  },
  {
    "s": "Rich needs permission to run the action shown below.",
    "c": "ACTIONABLE",
    "why": "The request can be declined or explicitly approved through its two scoped action buttons.",
    "control": "#permission-deny",
    "fixture": "permission-pending"
  },
  {
    "s": "Saved work is unavailable:",
    "c": "FRAGMENT",
    "why": "Prefix joined to the native error describing why saved receipts cannot be read."
  },
  {
    "s": "Saved work unavailable",
    "c": "INFORMATIONAL",
    "why": "Labels an unavailable saved-work observation without claiming a successful read."
  },
  {
    "s": "Sign-in could not be canceled. Try again.",
    "c": "ACTIONABLE",
    "why": "Cancellation remains available while the provider is still connecting.",
    "control": "#provider-cancel",
    "fixture": "provider-cancel-error"
  },
  {
    "s": "Sign-in could not start. Try again.",
    "c": "ACTIONABLE",
    "why": "A failed sign-in start re-enables the initiating button.",
    "control": "#provider-connect",
    "fixture": "provider-start-error"
  },
  {
    "s": "The action's state could not be verified. Approval is unavailable.",
    "c": "INFORMATIONAL",
    "why": "Approval is disabled until a subsequent poll can establish the current action state."
  },
  {
    "s": "The software is installed.",
    "c": "INFORMATIONAL",
    "why": "Confirms software installation separately from the account sign-in that follows.",
    "fixture": "setup-finished"
  },
  {
    "s": "This conversation has no company binding.",
    "c": "INFORMATIONAL",
    "why": "Explains why a saved-work query cannot select a company."
  },
  {
    "s": "This permission applies only to this action.",
    "c": "INFORMATIONAL",
    "why": "Describes the scope of the visible action decision.",
    "fixture": "permission-pending"
  },
  {
    "s": "Work status is changing. Please try again.",
    "c": "ACTIONABLE",
    "why": "Reopening the saved-work disclosure retries the same native status request after the concurrent update.",
    "control": ".drill-chip"
  },
  {
    "s": "Worker state is not settled.",
    "c": "INFORMATIONAL",
    "why": "The native stop/exit fence reports an unsettled worker observation."
  },
  {
    "s": "You need your own Anthropic account. You can sign in through your browser after setup; I never see your password.",
    "c": "INFORMATIONAL",
    "why": "Explains the separate account requirement before installation; the subsequent account sheet supplies the sign-in control.",
    "fixture": "setup-missing-both"
  },
  {
    "s": "Your Anthropic account",
    "c": "CONTROL",
    "why": "The heading naming the account connection dialog."
  },
  {
    "s": "button, input, select",
    "c": "NOT-RENDERED",
    "why": "A CSS selector used to trap keyboard focus, never displayed as prose."
  },
  {
    "s": "more saved records. Ask Rich about the assignment you want to continue.",
    "c": "ACTIONABLE",
    "why": "The saved-record limit directs the user to the normal message composer for a specific assignment.",
    "control": "#input"
  },
  {
    "s": "saved work records",
    "c": "FRAGMENT",
    "why": "A numeric record-count suffix in the saved-work disclosure."
  },
  {
    "s": "saved work record",
    "c": "FRAGMENT",
    "why": "The same suffix at a count of one. Ray candidate-.11 \u00a71.2 read \"1 saved work records\"; the chip now picks its noun from its count."
  },
  // -------------------------------------------------------------------------------------
  // GETTING THE SPEECH MODEL (2026-09-17)
  //
  // `.github/README.md` said "Voice does not work yet … Speech needs a model this build does
  // not download for you." It downloads it now, and these are every sentence that says so.
  //
  // THE SHAPE OF THE WHOLE BLOCK IS ONE RULE: a state RichOS can close by downloading
  // something is ACTIONABLE and names the control that starts or restarts the download; a gap
  // RichOS cannot close is NEEDS-SOMEONE-ELSE and names the party. Nothing here is
  // INFORMATIONAL unless there is genuinely nothing to press — the two progress lines and the
  // browser preview's refusal are the only three that qualify.
  // -------------------------------------------------------------------------------------
  {
    "s": "I can hear you once I download my speech model. It's",
    "c": "ACTIONABLE",
    "control": "#voice-model-get",
    "fixture": "voice-model-offer",
    "why":
      "THE OFFER, and the head of the sentence the size is appended to. He presses  because he " +
      "wants to talk; this is the honest answer and the button under it is the whole of what he " +
      "has to do. The size is never typed in the UI — it arrives from model-costs.json via Rust.",
  },
  {
    "s": ", and it's a one-time download.",
    "c": "FRAGMENT",
    "why": "Tail of the offer sentence above, after the size label is spliced in.",
  },
  {
    "s": "Right now this disk has",
    "c": "FRAGMENT",
    "why":
      "Opens the short-disk clause of the same offer sentence. The button STAYS in that case: " +
      "free space is something he can change while the sentence is on screen, and the download " +
      "re-reads the disk when pressed, so removing the control would leave him a state he can " +
      "fix and nothing to press once he has.",
  },
  {
    "s": "free and it needs about",
    "c": "FRAGMENT",
    "why": "Middle of the same short-disk clause, between the free figure and the needed one.",
  },
  {
    "s": "an unknown amount",
    "c": "FRAGMENT",
    "why":
      "What a size reads as when the platform declined to report free space. Deliberately not a " +
      "refusal: unknown free space is not 'no room', so the offer still stands.",
  },
  {
    "s": "Part of it is already here, so this picks up where it left off.",
    "c": "FRAGMENT",
    "why":
      "Appended to the offer when a .part file survives an earlier attempt. It is the resume " +
      "promise the fetch layer actually keeps, not reassurance.",
  },
  {
    "s": "Getting my speech model ready…",
    "c": "INFORMATIONAL",
    "why":
      "The instant between the press and the first byte. Nothing to do, and the Stop control is " +
      "on the same row for the moment there is.",
  },
  {
    "s": "Downloading my speech model —",
    "c": "FRAGMENT",
    "why": "Head of the progress line; the percentage and the total are appended per event.",
  },
  {
    "s": "Checking my speech model is the one I expected…",
    "c": "INFORMATIONAL",
    "why":
      "The verification pass: the transfer is done and the sha256 is being taken, which costs " +
      "about a second per 500 MB. Its own sentence because a bar frozen at 100% under the " +
      "download's words is where somebody decides the app has hung. Nothing to do; Stop is " +
      "disabled here because there is no longer a transfer to stop.",
  },
  {
    "s": "My ears are installed. Start listening whenever you're ready.",
    "c": "ACTIONABLE",
    "control": "#voice-model-listen",
    "fixture": "voice-model-installed",
    "why":
      "The finish. The microphone is NOT opened for him: he pressed  minutes and half a " +
      "gigabyte ago, and acting on that consent now would be acting on consent that has gone " +
      "stale. One press, with the sentence in front of him.",
  },
  {
    "s": "I couldn't set up my hearing just now. Ask me again in a moment.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "The fallback sentence for a failed event that carried no message of its own. No fixture: " +
      "every real failure path supplies its own sentence (Finding::ceo_message), so driving this " +
      "one would mean faking an event the backend does not emit — and the registry would then be " +
      "vouching for a fixture rather than for the product.",
  },
  {
    "s": "Downloading my speech model needs the desktop app — here in the preview, type to me.",
    "c": "INFORMATIONAL",
    "why":
      "Browser-preview only: reachable solely when Bridge.isMock, exactly like the voice-mode " +
      "line above it. Never renders in the shipped app, and the composer it points at is on screen.",
  },
  {
    "s": "I've stopped the download. What arrived is saved, so asking me again picks up where it left off rather than starting over.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "fixture": "voice-model-failed",
    "why":
      "HE stopped it, so this is not a failure and must not wear one — but it renders in the " +
      "failed row, and it says what it cost him (nothing) and what happens next. The control is " +
      "there because the sentence invites him back.",
  },
  {
    "s": "There isn't enough room on this disk for my speech model — it needs about {} free, and there's {}. Free up some space and ask me again. Nothing was downloaded.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "Rust format string; the two holes are sizes. Refused BEFORE a byte is requested, because " +
      "finding out at 95% of 487.6 MB is the worst possible moment. 'Ask me again' is answered " +
      "by the retry control, which re-reads the disk.",
  },
  {
    "s": "The network sent me a sign-in page instead of my speech model — that's what hotel, airport and conference wifi does. Sign in to the network, then ask me again. Nothing was installed.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "The captive portal, named as a captive portal. THIS ROW IS WHY `worth_asking_again` EXISTS " +
      "SEPARATELY FROM `retryable`: the automatic loop must not retry a portal (it would fetch " +
      "the same login page) and the CEO absolutely must be able to, once he has signed in. One " +
      "flag for both questions put this instruction on screen with no button under it.",
  },
  {
    "s": "The server sent back an error instead of my speech model. Ask me again in a moment. Nothing was installed.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why": "An HTTP error or a plain-text body where a model was expected. Transient; asking again is the move.",
  },
  {
    "s": "What came back isn't my speech model, so I didn't install it. Ask me again when you're on a network you trust.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "An archive, a non-GGML body, or a file longer than the pin. Shared by three failure kinds " +
      "because they are one event to him: those were not the bytes we meant.",
  },
  {
    "s": "What arrived isn't the speech model I was expecting, so I threw it away rather than listen to you through it. Ask me again when you're on a network you trust.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "The sha256 mismatch — right size, right magic, wrong bytes, which is the case the pin " +
      "table exists for. Deleted rather than quarantined. Never retried automatically, and still " +
      "his to ask for again on a network he trusts.",
  },
  {
    "s": "The download stopped partway. I kept what arrived, so asking me again picks up where it left off rather than starting over.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why": "A truncated transfer with a usable prefix. The resume is real: the next attempt sends a Range header.",
  },
  {
    "s": "The download stopped before anything useful arrived. Ask me again when the connection is steadier.",
    "c": "ACTIONABLE",
    "control": "#voice-model-retry",
    "why":
      "A transfer that died with nothing worth keeping, or with a prefix that was not a model " +
      "prefix. Nothing is kept, and it says so rather than promising a resume it cannot perform.",
  },
  {
    "s": "I don't have a speech model on this machine yet.",
    "c": "INFORMATIONAL",
    "why":
      "Failure::Absent's sentence. Reached only if the finished file vanishes between the last " +
      "write and the hash — a statement of fact with no instruction in it, and not a state he " +
      "caused or can act on differently from the retry the row beside it already offers.",
  },
  {
    "s": "I can't set up my hearing on this machine — whoever set RichOS up adds that. I can still read what you type.",
    "c": "NEEDS-SOMEONE-ELSE",
    "why":
      "No decoder, or weights that are not the pinned weights. RichOS fetches pinned MODELS; " +
      "whisper-cli is not pinned and cannot be, because a Homebrew binary's sha256 is a property " +
      "of an arch and a bottle revision (model-pins.json says so). So there is nothing to offer " +
      "and the sentence names who can do it instead.",
  },
  {
    "s": "I can't prove the speech model this machine needs is the genuine one, so I won't download it — whoever set RichOS up can put that right. I can still read what you type.",
    "c": "NEEDS-SOMEONE-ELSE",
    "why":
      "The resolver asked for a model with no row in model-pins.json. RichOS will not download " +
      "what it cannot verify, and adding a pin is a commit — so it is somebody else's move, not his.",
  },
  {
    "s": "I can't tell where to put my speech model on this machine — whoever set RichOS up can put that right. I can still read what you type.",
    "c": "NEEDS-SOMEONE-ELSE",
    "why":
      "HOME is unset, which no double-click produces. A machine somebody configured, so the " +
      "sentence names that somebody.",
  },
  {
    "s": "I don't have a way to check that this speech model is genuine, so I won't install it — whoever set RichOS up can put that right. I can still read what you type.",
    "c": "NEEDS-SOMEONE-ELSE",
    "why":
      "Failure::Unpinned's own sentence. It used to share the 'ask me again on a network you " +
      "trust' line, and no network has anything to do with it — a pin table is a source file. " +
      "Split out precisely so it does not invite him back to a refusal that cannot change.",
  },
  {
    "s": "Download my speech model",
    "c": "CONTROL",
    "why": "The offer row's button. Survives being spoken aloud on its own, which every option in this app must.",
  },
  {
    "s": "Stop the download",
    "c": "CONTROL",
    "why": "The in-flight row's button. Stops the transfer and keeps the prefix.",
  },
  {
    "s": "Try the download again",
    "c": "CONTROL",
    "why": "The failed row's button, shown only when the backend says asking again could help.",
  },
  // -------------------------------------------------------------------------------------
  // BACKGROUND WORK — the assignment surface (the background-work spec, revision 5, in the
  // private richos-hq record; §1, §4.2 and §0 row 7), as the CEO's ruling §52 leaves it.
  //
  // WHAT §52 CHANGED HERE (2026-09-18): *"There's nothing that ever not lands on its own
  // here in the terminal … So, yes, always land on its own."* Both rows below used to open
  // with "Ready for you to approve", because the one thing that could stop a background job
  // was the step that would change his repository. A job lands on its own now, so `blocked`
  // means a decision of his is outstanding on SOME step — and the row no longer claims his
  // repository is untouched, because a job may reach such a step after landing something.
  //
  // THE GAP THIS BLOCK ONCE CARRIED IS STILL CLOSED, and by the same mechanism: the desk
  // holds his decision while he is away (§5.2/§5.5/§5.7), so the sentence names Approve and
  // Decline controls that are on the same surface — driven against the real DOM by the
  // `assignment-waiting` fixture rather than asserted here.
  //
  // THE SECOND SENTENCE IS NOT A DUPLICATE AND IT IS NOT A HEDGE. The queue lives in the
  // running process: an assignment that stopped at his decision before a relaunch is still
  // `blocked` and has nothing left to press, because §6's recovery is the next slice. That
  // state keeps the composer, which is a real path, rather than naming a control that is not
  // there.
  // -------------------------------------------------------------------------------------
  {
    "s": "What you have asked for",
    "c": "INFORMATIONAL",
    "why":
      "The assignments block's heading in the saved-work pane. It labels the list below it " +
      "and asks nothing of him.",
  },
  {
    "s": "Written down. Nothing has been prepared yet.",
    "c": "INFORMATIONAL",
    "why":
      "The registered state. The assignment is on disk and the work lease picks it up at the " +
      "turn boundary without him doing anything, so there is nothing here for him to act on.",
  },
  {
    "s": "Getting a workspace ready.",
    "c": "INFORMATIONAL",
    "why": "The preparing state: the work lease is inside the spawn preparer. Nothing is asked of him.",
  },
  {
    "s": "Waiting for your decision before it can go on.",
    "c": "ACTIONABLE",
    "why":
      "The job ran and stopped at a step the permission desk would have asked him about in a " +
      "visible turn and could not, because there is no turn — a command, a write outside its " +
      "workspace. The request is held at the desk until he answers it (§5.2/§5.7), so the row " +
      "carries Approve and Decline beside this sentence, and the 'Waiting on you:' line names " +
      "the step in the backend's own words. It says nothing about his repository: since the " +
      "CEO's ruling §52 a job lands on its own, so it may reach a step like this AFTER landing " +
      "something, and the old promise that nothing had changed there would be false.",
    "control": ".assignment-approve",
    "fixture": "assignment-waiting",
  },
  {
    "s": "Waiting for your decision. Ask Rich to continue it when you are ready.",
    "c": "ACTIONABLE",
    "why":
      "The same stop, with no question left on the desk — the queue lives in the running " +
      "process, so an assignment that stopped at his decision before a relaunch has nothing " +
      "to press. Recovery is §6 and is not built, so this sentence names the path that does " +
      "exist: asking Rich to continue it, through the composer.",
    "control": "#input",
  },
  {
    "s": "Waiting for the screen to unlock — I'll carry on the moment it's back.",
    "c": "INFORMATIONAL",
    "why":
      "The CEO's ruling §56 (2026-09-18): a background job that needs the Mac's screen, found " +
      "on a locked screen, waits for the unlock and carries on by itself. It is the one " +
      "waiting sentence in the assignment rows that is NOT waiting on him — it is waiting on " +
      "the Mac — so it correctly names no control and there is no control that could exist " +
      "for it. Classifying it ACTIONABLE would be a claim that something on his screen " +
      "resolves it; pointing him at his own lock screen would be the nag §56 was given to " +
      "avoid. He unlocks his Mac when he unlocks his Mac, and the app says nothing about it " +
      "and asks nothing of him. The state resolves itself with no press anywhere, which is " +
      "exactly what INFORMATIONAL is for.",
  },
  {
    "s": "a step it cannot take without you",
    "c": "FRAGMENT",
    "why":
      "The tail of 'Waiting on you: …' when the backend sent no plain phrase for the step — " +
      "an action this build has no wording for. It never renders alone, and it deliberately " +
      "describes nothing: inventing a description of an action he is about to authorize " +
      "would be worse than saying only that it needs him.",
  },
  {
    "s": "waiting for you",
    "c": "FRAGMENT",
    "why":
      "The tail of the work chip's own count — '1 waiting for you' — which is how an " +
      "assignment stopped at his decision becomes reachable at all: every other part of that " +
      "chip comes from `get_worker_status`, which is empty whenever no turn is open. The " +
      "count and its control are the chip itself, classified below with the rest of it.",
  },
  {
    "s": "waiting for the screen",
    "c": "FRAGMENT",
    "why":
      "The tail of the work chip's own count for CEO §56's state — '1 assignment waiting for " +
      "the screen' — classified beside `waiting for you` directly above it and for the same " +
      "reason: it never renders alone, and the count IS the affordance, because the chip is " +
      "the only way to open the pane the assignments live in. It is deliberately NOT the same " +
      "words as `waiting for you`: `AssignmentState::waits_for_the_world` is not " +
      "`awaits_his_word`, the wait clears itself when the Mac is unlocked, and telling him a " +
      "self-resolving wait is his to act on is the nag §56 was given to avoid. Before it had a " +
      "count of its own, an assignment in that state as his only open work left the chip empty " +
      "and hidden — no chip, no pane, no way to see the work (esc-20260918T114550Z-64ae379a).",
  },
  {
    "s": "Waiting on you:",
    "c": "FRAGMENT",
    "why":
      "The prefix of the one-line question on a blocked assignment: 'Waiting on you: ' plus " +
      "the step itself, in the backend's own plain phrase for it (`work_host.rs`'s " +
      "`plain_action`, which the blocked receipt uses too). It never renders alone, and the " +
      "sentence it belongs to is the ACTIONABLE row above, with the same controls.",
  },
  {
    "s": "Stopped before it finished. Ask Rich what it needs.",
    "c": "ACTIONABLE",
    "why":
      "A job that did not finish. Its own recorded reason is appended beside this sentence — " +
      "and since the CEO's ruling §52 that includes a FAILED LAND: the reviewer asked for " +
      "changes, the land did not go through, or the work landed and the assignment was never " +
      "closed. The reason is read off the land record the engine wrote, never softened, and " +
      "continuing or abandoning it is a decision he makes through the composer.",
    "control": "#input",
  },
  {
    "s": "Its state could not be read.",
    "c": "INFORMATIONAL",
    "why":
      "A record written by a newer RichOS, or a state this build does not know. It is the " +
      "honest 'I cannot tell' — it never reads as finished, and there is nothing he can do " +
      "about a record this build cannot parse.",
  },

  // -------------------------------------------------------------------------------------
  // A QUESTION HE ASKED, rather than work he asked for — the CEO's ruling §58, 2026-09-18
  // -------------------------------------------------------------------------------------
  //
  // *"The answer arrives on the timeline as an answer, never as 'done'."* The eight rows
  // below are the same three surfaces as the work rows above, said about a question: the
  // saved-work pane's six states (`work-summary.js`'s `QUESTION_STATES`) and the timeline
  // timer's two accessible descriptions (`timeline.js`'s `questionRow`).
  //
  // WHY A SECOND SET AT ALL, rather than reusing the work sentences. Two of them would have
  // been outright wrong about a question: "Getting a workspace ready." describes something
  // done for work and nothing he needs to hear about a question of his, and "Finished." is
  // the one framing §58 names and refuses. The other four would merely have read like
  // machinery. The kind is on the record (`assignment.rs`'s `AssignmentKind`), so the pane
  // does not have to guess which set to use.
  //
  // CONTRAST is unchanged by any of them: every sentence here renders in the same
  // `.overlay-note` on `--card` as the work rows above (5.78:1 dark, 6.38:1 light at 16px,
  // measured by `background-work.js`), and the two timer descriptions are the row's
  // `aria-label` and `title` — read on focus and on hover, never painted as text.
  {
    "s": "Written down. Rich hasn't started looking yet.",
    "c": "INFORMATIONAL",
    "why":
      "A question of his, written down, before the back end has been asked. It covers BOTH " +
      "`registered` and `preparing`, which are two sentences for work and one here: the " +
      "workspace the preparing state describes is a thing done for work, and telling him " +
      "about it would be describing machinery in answer to a question he asked.",
  },
  {
    "s": "Rich is looking into this.",
    "c": "INFORMATIONAL",
    "why":
      "The running state for a question. The row carries its own Stop control, but the state " +
      "asks nothing of him: the answer arrives on the conversation when it arrives.",
  },
  {
    "s": "Waiting for your decision before Rich can go on.",
    "c": "ACTIONABLE",
    "why":
      "Answering a question reached a step the permission desk would have asked him about in " +
      "a visible turn and could not — a command, a write outside its workspace. Identical to " +
      "the work row above in every respect except the wording, and it carries the same " +
      "Approve and Decline beside it; the `assignment-question-waiting` fixture proves the " +
      "control is really on screen for a question and not only for a task.",
    "control": ".assignment-approve",
    "fixture": "assignment-question-waiting",
  },
  {
    "s": "Waiting for your decision. Ask Rich to continue when you are ready.",
    "c": "ACTIONABLE",
    "why":
      "The same stop with no question left on the desk — the queue lives in the running " +
      "process, so a question that stopped at his decision before a relaunch has nothing to " +
      "press. The path that does exist is asking Rich, through the composer.",
    "control": "#input",
  },
  {
    "s": "Waiting for the screen to unlock — Rich will carry on the moment it's back.",
    "c": "INFORMATIONAL",
    "why":
      "§56's state in a question's words, and it arrived because the §58 slice rebased onto " +
      "§56's: without a row here a question waiting on the screen falls through to 'Its state " +
      "could not be read.' It names no control for the same reason the work version does not — " +
      "it is waiting on the Mac, it resolves itself, and the app never tells him to go and " +
      "unlock anything.",
  },
  {
    "s": "Answered — it's in your conversation.",
    "c": "INFORMATIONAL",
    "why":
      "**The row §58 exists for on this surface.** A question that has been answered is not " +
      "'Finished.' — the answer itself is on the timeline, said as an answer, which is where " +
      "he reads it. This sentence says where it went and asks nothing. It deliberately does " +
      "NOT repeat the answer: the pane would then be a second copy of it, able to disagree.",
  },
  {
    "s": "Rich couldn't get you an answer. Ask him again and he'll try it a different way.",
    "c": "ACTIONABLE",
    "why":
      "A question that got no answer — the back end never answered, or the connection failed. " +
      "It is said as that rather than as a job that 'stopped before it finished', which would " +
      "invite the wrong question about something that was never half-answered. Asking again " +
      "is the thing to do and the composer is where he does it.",
    "control": "#input",
  },
  {
    "s": "Rich is checking this for you. You'll get the answer here.",
    "c": "INFORMATIONAL",
    "why":
      "The accessible description of the 'Checking for {duration}' timer beside his reply " +
      "(§6.4: the timer's live updates are not announced every second, and this name is read " +
      "on focus). It claims only what is known — the question is with the other Rich and " +
      "nothing is finished — and names where the answer will appear. Nothing to act on: he " +
      "has already been told it is being checked.",
  },
  {
    "s": "Rich is looking into this for you. You'll get the answer here.",
    "c": "INFORMATIONAL",
    "why":
      "The same, for 'Investigating for {duration}' — either because he was told 'I'll " +
      "investigate.' or because a check has been running for a minute and flipped its own " +
      "label (§58: *\"a check still running at one minute flips its label to 'investigating' " +
      "on its own\"*).",
  },
  {
    "s": "Your assignments are unavailable:",
    "c": "FRAGMENT",
    "why":
      "Prefix joined to the backend's own reason, exactly as 'Saved work is unavailable:' " +
      "above it. The sentence he reads is the join.",
  },
  {
    "s": "Another conversation is working. Your assignments will refresh when it settles.",
    "c": "INFORMATIONAL",
    "why":
      "A turn is live on a different thread, so this thread's company binding cannot be read " +
      "without waiting on it. It resolves itself and says so; nothing is asked of him.",
  },
  {
    "s": "Your assignments are changing. They will refresh in a moment.",
    "c": "INFORMATIONAL",
    "why":
      "The spine's lock is held for the length of a turn, so this read is deferred. The " +
      "surface re-reads every three seconds, which is why this does NOT tell him to try " +
      "again: an instruction over a state that resolves itself is the thing this rule exists " +
      "to catch.",
  },
  {
    "s": "Missing assignment scope",
    "c": "NOT-RENDERED",
    "why":
      "The diagnostic first argument to `startup_alert::cannot_start` in the " +
      "`--assignments-mcp` child, which reaches stderr and the startup log. The sentence a " +
      "person reads for the same failure is the second argument beside it.",
  },
  {
    "s": "assignment tool server: {error}",
    "c": "NOT-RENDERED",
    "why":
      "The same diagnostic argument, with the child's own error interpolated. A child of the " +
      "running app can never arm the alert — `activation.rs`'s parent-pid condition is false " +
      "by construction — so this is operator log text and nothing else.",
  },
  {
    "s": "stopped on request",
    "c": "NOT-RENDERED",
    "why":
      "An engineer's detail passed to PartFile::interrupted. It reaches Finding::describe on " +
      "stderr and never Finding::ceo_message, so it cannot appear on his screen. What he reads " +
      "for the same event is the STOPPED_BY_REQUEST sentence above.",
  },
  {
    s: "That folder is there and I couldn't use it. Everything else works as it does now — our conversations are kept somewhere else and are untouched — and there's nothing for you to fix.",
    c: "INFORMATIONAL",
    why:
      "`MemoryStatus.state === \"unusable\"`, reached from the settings menu's `Memory folder` " +
      "row (audit-7 row 13). NOT actionable and NOT needs-someone-else, and both halves of that " +
      "are deliberate. He cannot clear it — the corpus resolved and something refused, and " +
      "`MemoryStatus.detail` carries the machine-facing half which never reaches this screen by " +
      "that field's own contract. And it names no party, for the same reason MEMORY_NO_READER " +
      "stopped naming one on 2026-09-04: on a customer's Mac the person who set RichOS up IS " +
      "him, so pointing him at a third party who does not exist is worse than saying nothing. " +
      "It says what is off, what is still on, and that nothing is required of him — the three " +
      "things that shape is for. Provisioning is not offered, because a corpus already exists.",
  },
  {
    s: "I couldn't read where your memory is kept just now. Nothing has changed.",
    c: "INFORMATIONAL",
    why:
      "`memory_status` itself would not answer when he pressed the `Memory folder` row. Nothing " +
      "was attempted and nothing was changed, and the row is still there to press again — so " +
      "this is a statement rather than a request, and it deliberately offers no control: a " +
      "`Try again` button here would be a second name for the row he just used.",
  },

  // -------------------------------------------------------------------------------------
  // THE PHONE CHANNEL (2026-09-18) — `ui/phone.js`, `ui/qr.js` and `src-tauri/src/phone/`.
  //
  // THIRTY OF THESE ROWS EXIST BECAUSE THIS GATE CHANGED THE PRODUCT. The pairing command
  // handed `PhoneError::to_string()` straight to the screen, so thirty internal sentences —
  // `add-generic-password for tls-leaf-key exited 51` — arrived here as user-visible states.
  // The honest answer was not to classify them as product copy. It was to stop showing them:
  // `PhoneError::ceo_sentence` now gives him one sentence he can read, the detail goes to the
  // log, and the rows below say NOT-RENDERED and mean it.
  // -------------------------------------------------------------------------------------
  {
    "s": "This code lasts",
    "c": "FRAGMENT",
    "why": "The first half of the countdown sentence — the seconds and the full stop are appended at run time. It never renders on its own."
  },
  {
    "s": "It can reach you with a notification when Rich has something for you.",
    "c": "INFORMATIONAL",
    "why": "The paired phone can be pushed to. Nothing to do — this is the state he wanted, said out loud so its absence is legible."
  },
  {
    "s": "It cannot send you notifications yet. On your phone, open the Share menu in Safari and choose “Add to Home Screen”, then allow notifications when Rich asks.",
    "c": "ACTIONABLE",
    "control": "#phone-forget",
    "why": "One of the three sentences the paired card shows while the phone cannot be pushed to yet, chosen by the `platform` on the device record. It was ONE sentence — \"Add Rich to your phone's Home Screen and allow notifications when it asks\" — and Chrome on the CEO's HONOR X6b offers \"Install and create shortcut\" with no item by the other name at all, so the Mac named a control the device does not have (Ray's candidate .11 walk, defect 4.5, verified on the device). The menu and item names are exactly the phone page's own (`web/web-app/app.js`, `installControlName`), so the two surfaces cannot give one control two names. ACTIONABLE, and the control is the same one the old row named: this is the state he fixes ON THE PHONE, and the only thing this view can offer is the way back out. `ui/tests/phone.js` check 9d walks all three. iOS Safari, which genuinely cannot take a push until the app is on the Home Screen."
  },
  {
    "s": "It cannot send you notifications yet. Allow notifications on your phone when Rich asks — Chrome on Android does not need Rich installed first.",
    "c": "ACTIONABLE",
    "control": "#phone-forget",
    "why": "One of the three sentences the paired card shows while the phone cannot be pushed to yet, chosen by the `platform` on the device record. It was ONE sentence — \"Add Rich to your phone's Home Screen and allow notifications when it asks\" — and Chrome on the CEO's HONOR X6b offers \"Install and create shortcut\" with no item by the other name at all, so the Mac named a control the device does not have (Ray's candidate .11 walk, defect 4.5, verified on the device). The menu and item names are exactly the phone page's own (`web/web-app/app.js`, `installControlName`), so the two surfaces cannot give one control two names. ACTIONABLE, and the control is the same one the old row named: this is the state he fixes ON THE PHONE, and the only thing this view can offer is the way back out. `ui/tests/phone.js` check 9d walks all three. Chrome on Android, where the old instruction was WRONG rather than misnamed: Chrome subscribes to push from a tab, so nothing has to be installed first. The phone page records the same division and, for the same reason, shows no install sentence there."
  },
  {
    "s": "It cannot send you notifications yet. Allow notifications on your phone when Rich asks. On an iPhone you have to add Rich to the Home Screen first, from Safari’s Share menu.",
    "c": "ACTIONABLE",
    "control": "#phone-forget",
    "why": "One of the three sentences the paired card shows while the phone cannot be pushed to yet, chosen by the `platform` on the device record. It was ONE sentence — \"Add Rich to your phone's Home Screen and allow notifications when it asks\" — and Chrome on the CEO's HONOR X6b offers \"Install and create shortcut\" with no item by the other name at all, so the Mac named a control the device does not have (Ray's candidate .11 walk, defect 4.5, verified on the device). The menu and item names are exactly the phone page's own (`web/web-app/app.js`, `installControlName`), so the two surfaces cannot give one control two names. ACTIONABLE, and the control is the same one the old row named: this is the state he fixes ON THE PHONE, and the only thing this view can offer is the way back out. `ui/tests/phone.js` check 9d walks all three. A phone this Mac cannot name: it says what is true whatever the phone is and names no menu as the one to use — the phone page's own \"null means say nothing\" rule, because a wrong menu name sends him looking for something that is not there."
  },
  {
    "s": "Your phone said the six words did not match, so I stopped answering, forgot the phone, and deleted the certificate this Mac was serving.",
    "c": "ACTIONABLE",
    "control": "#phone-rejected-again",
    "why": "THE MAC'S ANSWER TO THE ALARM BUTTON — Ray's nightly `.8` walk in the test VM, defect 1 (HIGH). He pressed `They do not match` on the phone; the credential really was dropped, and the sheet in front of him did not change at all — the pairing card stayed up with the six words under it, and the Mac went on answering `curl` on 8443 at t+10, 20, 30, 40, 50 and 60 s and two minutes later. *\"He has no way to know the Mac heard him.\"* One sentence, and it is a report rather than a request: what the phone said, and then the three things this Mac did about it. ACTIONABLE because he CAN change it and the control is on the screen with it: `PhoneStatus.rejected` is cleared by `phone_begin_pairing` and by nothing else, so a screen without `Set my phone up again` would be one he could not leave — Close would only put it back on the next open. The socket half is proved over real TLS by `phone::listen::tests::they_do_not_match_over_the_wire_stops_the_listener` (the port stopped answering 1 ms after the rejection went out); this half by `ui/tests/phone.js` check 9f, which also computes the sentence's contrast in both themes (5.78:1 dark, 6.38:1 light at 16px, against a 4.5:1 floor)."
  },
  {
    "s": "You said the six words did not match, so I stopped answering, forgot the phone, and deleted the certificate this Mac was serving.",
    "c": "ACTIONABLE",
    "control": "#phone-rejected-again",
    "why": "The same screen as the phone's alarm button (the row above), reached from the Mac's own `They do not match` (Sage's pairing review F1): `PhoneRuntime::reject_on_mac` runs the one rejection teardown and records `StoppedBy::MAC`, so the sentence says it was him, here. One sentence, a report; `Set my phone up again` is the control that leaves it. ui/tests/phone.js check 9g presses the button and reads this sentence."
  },
  {
    "s": "A second phone used the same code, which means someone else may have seen it, so I stopped answering, forgot the phone that used it first, and deleted the certificate this Mac was serving.",
    "c": "ACTIONABLE",
    "control": "#phone-rejected-again",
    "why": "Sage's spent-code alarm (F1 fix item 4): the pairing code was used correctly by a second device while the first was still unconfirmed, so two devices had it. The Mac forgets the first rather than guess which is his (`StoppedBy::CODE_USED_TWICE`), stops serving and says so in the same one-sentence shape as the other refusals. `Set my phone up again` issues a fresh code. ui/tests/phone.js check 9g."
  },
  {
    "s": "Nobody pressed They match on this Mac within five minutes, so I stopped answering, forgot the phone, and deleted the certificate this Mac was serving.",
    "c": "ACTIONABLE",
    "control": "#phone-rejected-again",
    "why": "Sage's pairing review 3.1 step 6: the window's timer keeps running after a phone redeems the code, and an unconfirmed device at expiry is forgotten so an abandoned pairing never leaves a key behind (`StoppedBy::EXPIRED`). Said on the screen it happened on rather than falling back in silence (Ray's defect 3.3 was that silence); `Set my phone up again` issues a fresh code. ui/tests/phone.js check 9g."
  },
  {
    "s": "This Mac accepted your phone, but the phone never finished pairing, so I stopped answering, forgot the phone, and deleted the certificate this Mac was serving.",
    "c": "ACTIONABLE",
    "control": "#phone-rejected-again",
    "why": "Sage's pair-v2 hypotheses review §2: this Mac pressed They match and the phone never used the pairing within `UNFINISHED_GRACE_MS` after the window, so the key its phone gave up on is forgotten (`StoppedBy::UNFINISHED`) rather than listed as a paired phone that can never connect, which also freed the one pairing slot. Same one-sentence shape as the other refusals; `Set my phone up again` issues a fresh code. ui/tests/phone.js check 9g reads it."
  },
  {
    "s": "A code for your phone's camera. The address is written out beside it.",
    "c": "INFORMATIONAL",
    "why": "The accessible name of a QR canvas, for a reader who cannot see it. It says the address is written out beside the code, which it is."
  },
  {
    "s": "Use Rich from your phone",
    "c": "CONTROL",
    "why": "#set-phone-open — the settings-menu row that opens the pairing screen."
  },
  {
    "s": "qr: bytes does not fit in a version 1-6 level-M symbol (106 bytes is the ceiling). Shorten the URL or extend the version table — do not silently truncate.",
    "c": "NOT-RENDERED",
    "why": "A `throw` inside the QR encoder. Two of the three are internal invariants that can only fire on a table typo; the length ceiling is caught by `paint()` and replaced with the message it carries, which is for whoever is reading the log rather than for him — a URL too long to encode is a bug in the Mac's own address, not something he can act on."
  },
  {
    "s": "qr: interleaved codewords, the symbol holds",
    "c": "NOT-RENDERED",
    "why": "A `throw` inside the QR encoder. Two of the three are internal invariants that can only fire on a table typo; the length ceiling is caught by `paint()` and replaced with the message it carries, which is for whoever is reading the log rather than for him — a URL too long to encode is a bug in the Mac's own address, not something he can act on."
  },
  {
    "s": "qr: internal error — the payload overran the version chosen for it",
    "c": "NOT-RENDERED",
    "why": "A `throw` inside the QR encoder. Two of the three are internal invariants that can only fire on a table typo; the length ceiling is caught by `paint()` and replaced with the message it carries, which is for whoever is reading the log rather than for him — a URL too long to encode is a bug in the Mac's own address, not something he can act on."
  },
  {
    "s": ": re-snapshot {missed}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/listen.rs:429)"
  },
  {
    "s": "AES-128-GCM rejected the content key",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:264)"
  },
  {
    "s": "AES-128-GCM sealing failed",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:271)"
  },
  {
    "s": "HKDF expand refused the requested length",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:213)"
  },
  {
    "s": "HKDF fill failed",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:215)"
  },
  {
    "s": "Rich is working. Your conversation will appear when he finishes.",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/bridge.rs:161)"
  },
  {
    "s": "VAPID signing failed",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:173)"
  },
  {
    "s": "a P-256 JWK's x and y are 32 bytes each, got {} and {}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:595)"
  },
  {
    "s": "a device key must be a 65-byte uncompressed P-256 point or its 91-byte SPKI wrapper, got {} bytes",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:615)"
  },
  {
    "s": "a device key must be an EC P-256 JWK, got kty={kty:?} crv={crv:?}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:578)"
  },
  {
    "s": "a malformed endpoint",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:331)"
  },
  {
    "s": "a path is not valid UTF-8",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/ca.rs:273)"
  },
  {
    "s": "a phone is already paired — forget it first, which also closes the listener",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:301)"
  },
  {
    "s": "a push endpoint has no host",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:190)"
  },
  {
    "s": "a push endpoint must be https",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:187)"
  },
  {
    "s": "a subscription auth secret must be 16 bytes, got {}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:238)"
  },
  {
    "s": "a subscription p256dh must be a 65-byte uncompressed point, got {} bytes",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:232)"
  },
  {
    "s": "add-generic-password for {account} exited {}: {}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/secrets.rs:153)"
  },
  {
    "s": "could not derive the ephemeral public key",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:295)"
  },
  {
    "s": "could not generate a VAPID key",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:118)"
  },
  {
    "s": "could not generate an ephemeral key",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:292)"
  },
  {
    "s": "delete-generic-password for {account} exited {}: {}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/secrets.rs:173)"
  },
  {
    "s": "find-generic-password for {account} exited {code}: {}",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/secrets.rs:116)"
  },
  {
    "s": "no {label} block",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/ca.rs:454)"
  },
  {
    "s": "the JWK has no x",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:585)"
  },
  {
    "s": "the JWK has no y",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/device.rs:591)"
  },
  {
    "s": "the content-encoding salt must be 16 bytes",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:243)"
  },
  {
    "s": "the derived nonce was not 12 bytes",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:269)"
  },
  {
    "s": "the stored authority key is not text",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/ca.rs:104)"
  },
  {
    "s": "the stored leaf key is not text",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/ca.rs:127)"
  },
  {
    "s": "the subscription's public key is not a valid P-256 point",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/push.rs:301)"
  },
  {
    "s": "the system random source refused",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/mod.rs:249)"
  },
  {
    "s": "this Mac has no address the phone could reach, so there is nothing to listen on",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/listen.rs:149)"
  },
  {
    "s": "this Mac has no conversation to add to yet",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/bridge.rs:96)"
  },
  {
    "s": "this Mac has no conversation yet",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/bridge.rs:146)"
  },
  {
    "s": "this Mac publishes no local host name, so there is no address the phone could use",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/names.rs:109)"
  },

  {
    "s": "unterminated {label} block",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/ca.rs:457)"
  },
  {
    "s": "{address} is every interface at once, which this channel never binds — give it the addresses this Mac actually answers on",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/listen.rs:155)"
  },
  {
    "s": "{address} is not an address a server binds",
    "c": "NOT-RENDERED",
    "why": "An internal `PhoneError` string. It is the Display form, which goes to the Mac's own log (`eprintln!`) and never to the webview: every refusal on the network is a flat 404 with an empty body, and the two commands that can surface a failure at all — `phone_begin_pairing` and `phone_forget` — map it through `PhoneError::ceo_sentence` first. This scrape sees it because it sits beside `Err(` in the command layer's crate, which is the one shape RUST_CEO_CONTEXT cannot tell apart from CEO copy. (richos/app/src-tauri/src/phone/listen.rs:160)"
  },
  // -------------------------------------------------------------------------------------
  // THE TAILSCALE PATH AND THE IDENTITY TRAP (CEO §61 / §61.1, 2026-09-19) — `ui/phone.js`,
  // `src-tauri/src/phone/tailnet.rs` and `src-tauri/src/opener.rs`.
  //
  // THE SHAPE OF THIS BLOCK IS THE SHAPE OF THE SCREENS. Most of it is FRAGMENTs, and that
  // is the point rather than an evasion: every sentence §61.1 required is composed at run
  // time around a string the Mac read off `tailscale status --json` — the provider and the
  // login name — because *"use the same account"* is advice nobody can follow when the one
  // thing they do not know is which account they used. A literal that ends mid-sentence is
  // what naming the account looks like in source.
  //
  // THE INSTRUCTIONS ARE ACTIONABLE AND THEY POINT AT `#phone-ts-open`, the control that
  // opens the exact thing the sentence names. Before 2026-09-19 the app could not open a
  // URL at all, so these sentences were instructions with nothing beside them but an
  // address to retype.
  // -------------------------------------------------------------------------------------
  {
    "s": ") is on this network but Tailscale is switched off on it. Turn it on in the Tailscale app.",
    "c": "FRAGMENT",
    "why": "Part of the sentence that says where the phone is (CEO §61.1 detection half). Composed at run time from the device name the daemon reports, so it never renders on its own. The whole sentence is one of three — on this network; on this network but switched off; not here yet, sign in with <account> — and `ui/tests/phone.js` checks 14 and 15 assert all three."
  },
  {
    "s": ") is on this network.",
    "c": "FRAGMENT",
    "why": "Part of the sentence that says where the phone is (CEO §61.1 detection half). Composed at run time from the device name the daemon reports, so it never renders on its own. The whole sentence is one of three — on this network; on this network but switched off; not here yet, sign in with <account> — and `ui/tests/phone.js` checks 14 and 15 assert all three."
  },
  {
    "s": ", then come back here. Reinstalling the app will not help — the identity is the only thing that decides it.",
    "c": "FRAGMENT",
    "why": "Part of the sentence that says where the phone is (CEO §61.1 detection half). Composed at run time from the device name the daemon reports, so it never renders on its own. The whole sentence is one of three — on this network; on this network but switched off; not here yet, sign in with <account> — and `ui/tests/phone.js` checks 14 and 15 assert all three."
  },
  {
    "s": "</strong> — exactly what this Mac used — even if you would normally keep your phone and your Mac apart. Nothing else connects them.",
    "c": "FRAGMENT",
    "why": "The tail of the phone step's why-line, joined to the account phrase the Mac read off `status --json`. It never renders on its own; `ui/tests/phone.js` check 13 asserts the whole sentence names the provider and login name."
  },
  {
    "s": "</strong> — the same one this Mac is signed in to. A different provider makes a different network, and then the two will never see each other.",
    "c": "FRAGMENT",
    "why": "The tail of step 2 of the phone steps, joined to the account phrase. It never renders on its own — the sentence it belongs to is the one that tells the user WHICH identity to use, which is the whole of §61.1."
  },
  {
    "s": "Your phone reaches this Mac over your own Tailscale network, from anywhere it has a signal. The connection to this Mac is encrypted, your conversations stay here, and it costs one free Tailscale account signed in on both devices.",
    "c": "INFORMATIONAL",
    "why": "One of the three leads the phone sheet opens with, chosen by the option he picked — and once a phone is paired, by `paired_via` on the device record rather than by the sheet's forgotten route. It was ONE fixed sentence describing the home-network option, and it stayed on screen word for word after he pressed \"Anywhere\", which is not the home network and does involve making an account: every screen of the path §61 exists for opened by telling him the opposite of the path he was on (Ray's candidate .11 walk, defect 3.1, screenshots 13, 14, 15 and 17). INFORMATIONAL: it is the standing description of the arrangement, and the controls that change the arrangement are the route buttons on the screen below it. `ui/tests/phone.js` check 9c walks all three. This is the Anywhere path. It deliberately does NOT repeat the home path's \"nothing of what you say goes anywhere else\": on the tailnet the packets are encrypted end to end between the two devices but can be relayed by Tailscale's own servers when a direct connection cannot be made, so the claim is about what is encrypted and where the conversation is kept, both of which this Mac can stand behind."
  },
  {
    "s": "Pairing codes run out on purpose, so one left on a screen cannot be used later. Nothing is wrong and nothing was lost. Press Show me another code and a fresh one appears here.",
    "c": "ACTIONABLE",
    "control": "#phone-refresh",
    "why": "The expiry block on the pairing screen (`#phone-expired`), and the fix for Ray's candidate .11 defect 3.3. A code used to run out in silence: the Mac dropped the window, the next poll came back without one, and the dialog fell back to an earlier screen with the QR, the code and the six words gone and nothing said — \"he comes back to a screen that looks like he imagined the whole thing\". It is ACTIONABLE and the control is the button immediately below it, which is the one thing on that screen. The state is derived from the Mac rather than from this sheet: serving, nothing paired, no live code means the window ran out, and that survives the sheet being closed and reopened. `ui/tests/phone.js` check 8 asserts the screen does not move, shows no code, says what happened and offers another."
  },
  {
    "s": "That code has run out. Ask for another one.",
    "c": "ACTIONABLE",
    "control": "#phone-refresh",
    "why": "The countdown's own last frame, one second before the expiry block above takes over. It read \"That code has expired.\" and now reads \"run out\", which is the word the block beside it uses — one event should not have two names on one screen. Same control: the button that issues a fresh code."
  },
  {
    "s": "Forgetting it here stops this Mac answering it, deletes the keys, and stops this Mac answering at its Tailscale name. There is nothing to remove from your phone.",
    "c": "ACTIONABLE",
    "control": "#phone-forget",
    "why": "One of the five answers the paired card picks between, and the reason it picks rather than defaults: the copy is derived from `paired_via` and `platform` on the device record (`src-tauri/src/phone/device.rs`), recorded once at pairing. It used to be two paragraphs in the markup chosen by the sheet's own route variable, which `open()` resets on every open — so reopening the card for a paired Android phone on the Tailscale path printed iOS profile-removal steps for a certificate that path never installs (Ray's candidate .11 walk, defect 3.2, reproduced twice). `ui/tests/phone.js` check 9b walks all five and asserts the second open says exactly what the first did. It is ACTIONABLE for the same reason the sixteen home-path taps are: the thing acted on is his phone, and the one control the whole block is about is the button that forgets it. This is the Tailscale path, on any phone: no profile is ever installed on it."
  },
  {
    "s": "Download it, install it, then come back here. This screen moves on by itself when it sees it.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 2, the second half: what to do and that the screen will move on by itself. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "I can only open the pages these screens name.",
    "c": "NOT-RENDERED",
    "why": "`src-tauri/src/opener.rs`'s own refusal. It does NOT reach the screen: `openExternal` in `phone.js` discards the error and shows its own sentence, because a Mac that would not open a page needs to be told to read the address printed above it rather than told which table the address was not in. The string exists for the Mac's log."
  },
  {
    "s": "I cannot tell which identity this Mac is signed in to. Whichever it is, sign in with exactly the same one on your phone.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-start",
    "why": "The honest answer when the daemon reports a name but no identity for it: the screen cannot say WHICH account to reuse, so it says so and still says what to do. §61.1's whole point is that \"use the same account\" is advice nobody can follow — this is the one case where that is all there is, and it is said plainly rather than dressed up."
  },
  {
    "s": "I could not find Tailscale on this Mac to open it.",
    "c": "NOT-RENDERED",
    "why": "`src-tauri/src/opener.rs`'s own refusal. It does NOT reach the screen: `openExternal` in `phone.js` discards the error and shows its own sentence, because a Mac that would not open a page needs to be told to read the address printed above it rather than told which table the address was not in. The string exists for the Mac's log."
  },
  {
    "s": "I could not open that on this Mac. The address is written out above — type it into your browser.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "What the screen says when the Mac would not open the address. The control is the one that just failed — trying again is the first thing to do — and the sentence points at the address printed above it, which is why it is printed: Urban's §2, a control that opens somewhere the user cannot see first is asking for trust it has not earned."
  },
  {
    "s": "Install Tailscale on this Mac",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 2's heading. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "Open the Tailscale console",
    "c": "CONTROL",
    "why": "#phone-ts-open's label on Screen 7. It opens `console.tailscale.com/admin/dns`, which is one of five addresses `src-tauri/src/opener.rs` will open and the only one that screen names."
  },
  {
    "s": "Sign in to Tailscale on this Mac",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 3's heading. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "Sign in with <strong>",
    "c": "FRAGMENT",
    "why": "The head of step 2 of the phone steps, joined to the account phrase. Never rendered alone."
  },
  {
    "s": "Sign in with the <strong>same</strong> identity you used on this Mac. A different provider makes a different network, and then the two will never see each other.",
    "c": "ACTIONABLE",
    "control": "#phone-refresh",
    "why": "Step 2 of the phone steps when the Mac cannot name its own account — the generic form of the sentence §61.1 exists for. One of the phone-side steps on the Tailscale route (CEO §61 / §61.1). It is an instruction and therefore not INFORMATIONAL — but the thing the user acts on is their phone, not this window, so the control named is the one control the whole block is about: the button that issues a fresh code. Same reasoning, and the same control, as the sixteen home-path taps above. `ui/tests/phone.js` check 13 asserts this block opens with the why and names the account the Mac signed in with."
  },
  {
    "s": "Tailscale gives each machine a name on your network, and this Mac does not have one I can use. In Tailscale's own admin console, turn on MagicDNS and HTTPS certificates for your network, then come back.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 7: signed in, and the tailnet has not been told to issue certificates. MagicDNS is named because it is Tailscale's own label for the switch and the only string that will let somebody find it. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "Tailscale is installed here but not signed in. Open it and sign in. Any of the sign-in choices it offers is fine, and the free plan is enough. I cannot do this part for you.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 3's first note. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "Tailscale is not running.",
    "c": "NOT-RENDERED",
    "why": "The `tailscale` command line's OWN stderr sentence, quoted in `tailnet.rs` only so `Diagnostic::classify` can recognize it. The raw text never leaves that module — it can carry a `tskey-…` — and what the screen shows is the state's own sentence instead."
  },
  {
    "s": "Tailscale is signed in, but this Mac has no name yet",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "Screen 7's heading. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "Tailscale is somebody else's app, and it is free for one person. It gives this Mac a name your phone can reach from anywhere, and it is the whole reason this path has no certificate in it.",
    "c": "INFORMATIONAL",
    "why": "What Tailscale is and why this path uses somebody else's app, said once before the user installs it. Nothing to do in this sentence — the doing is in the note under it and in `#phone-ts-open` beside it, which is where the instruction lives."
  },
  {
    "s": "Waiting for your phone to join…",
    "c": "INFORMATIONAL",
    "why": "The phone-watch line before the grace window elapses. Genuinely nothing to do: the phone is being installed and signed in to somewhere else, and calling that a mistake before a measured wait would be the screen guessing — which is the failure §61.1 is about, in the other direction."
  },
  {
    "s": "Whichever you pick, you will sign in to the SAME one on your phone — your Tailscale account is your private network, and devices signed in to it are what can reach each other. Nothing else connects them.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-open",
    "why": "The identity warning in its short form, on the screen where the account is actually created — §61.1's \"before a RichOS user creates any Tailscale account\". Telling somebody afterwards is telling them after they have already chosen, and the fix by then is a sign-out. One of Urban's three \"something is happening in somebody else's software\" screens (§3 rows 2, 3 and 5). Detection moves the screen on by itself; `#phone-ts-open` is the control that opens the exact thing the sentence names — the download page, the Tailscale app, or the admin console — and the address stays written out beside it. `ui/tests/phone.js` check 16 asserts both, on all three screens."
  },
  {
    "s": "You signed in with <strong>",
    "c": "FRAGMENT",
    "why": "The head of the sentence that names the identity the Mac signed in with; the account phrase and the instruction are appended at run time. It gained its `<strong>` for Urban's G14 — this is the screen that names the account FIRST and it was the one screen that gave it no weight, while the two screens after it set the same account in bold. `ui/tests/phone.js` check 12 asserts the whole of it and check 26 asserts the weight and the position."
  },
  {
    "s": "</strong>. Use exactly this on your phone.",
    "c": "FRAGMENT",
    "why": "The tail of that same sentence, after the account phrase. It never renders on its own, and it exists as a separate literal only because Urban's G14 put the account in `<strong>` — before that the line was one `textContent` assignment. `ui/tests/phone.js` check 26."
  },
  {
    "s": "Your Tailscale account <strong>is</strong> your private network. Devices signed in to it can reach each other. So on your phone, sign in with <strong>",
    "c": "FRAGMENT",
    "why": "The head of the phone step's why-line when the Mac CAN name its account; the account phrase and the tail are appended. Never rendered alone."
  },
  {
    "s": "Your Tailscale account <strong>is</strong> your private network. Devices signed in to it can reach each other. So sign in on your phone with the same account you used on your Mac, even if you normally keep them separate. Nothing else connects them.",
    "c": "ACTIONABLE",
    "control": "#phone-refresh",
    "why": "The phone step's why-line when the Mac cannot name its account. It comes before the steps deliberately: it is asking the user to break a habit — *\"I would normally absolutely NEVER use the same identity on the Mac and on the phone\"* — and an instruction without its reason is one they will follow correctly and wrongly. One of the phone-side steps on the Tailscale route (CEO §61 / §61.1). It is an instruction and therefore not INFORMATIONAL — but the thing the user acts on is their phone, not this window, so the control named is the one control the whole block is about: the button that issues a fresh code. Same reasoning, and the same control, as the sixteen home-path taps above. `ui/tests/phone.js` check 13 asserts this block opens with the why and names the account the Mac signed in with."
  },
  {
    "s": "Your phone (",
    "c": "FRAGMENT",
    "why": "Part of the sentence that says where the phone is (CEO §61.1 detection half). Composed at run time from the device name the daemon reports, so it never renders on its own. The whole sentence is one of three — on this network; on this network but switched off; not here yet, sign in with <account> — and `ui/tests/phone.js` checks 14 and 15 assert all three."
  },
  {
    "s": "Your phone is not on this network yet. On the phone, sign in with",
    "c": "FRAGMENT",
    "why": "Part of the sentence that says where the phone is (CEO §61.1 detection half). Composed at run time from the device name the daemon reports, so it never renders on its own. The whole sentence is one of three — on this network; on this network but switched off; not here yet, sign in with <account> — and `ui/tests/phone.js` checks 14 and 15 assert all three."
  },
  {
    "s": "Your phone is not on this network yet. On the phone, sign in with the same account this Mac uses, then come back here. Reinstalling the app will not help — the identity is the only thing that decides it.",
    "c": "ACTIONABLE",
    "control": "#phone-ts-start",
    "why": "The mismatch, named, when the Mac cannot name its own account. A phone signed in to a different identity is in a different tailnet and appears nowhere at all, so its absence is the evidence — and the sentence also closes the loop the CEO actually ran: reinstalling the app three times. The control is the one on the screen this renders on."
  },
  {
    "s": "a certificate chain with nothing in it",
    "c": "NOT-RENDERED",
    "why": "`listen.rs`'s own refusal when a certificate chain arrives empty. It becomes `PhoneError::Crypto`, and every phone error the screen can reach goes through `ceo_sentence()` — the detail goes to the log, exactly as the thirty rows above this block record."
  },
  {
    "s": "this Mac would not open it.",
    "c": "NOT-RENDERED",
    "why": "`src-tauri/src/opener.rs`'s own refusal. It does NOT reach the screen: `openExternal` in `phone.js` discards the error and shows its own sentence, because a Mac that would not open a page needs to be told to read the address printed above it rather than told which table the address was not in. The string exists for the Mac's log."
  },
  {
    "s": "A code is live for",
    "c": "FRAGMENT",
    "why": "The head of the Settings row's second line (`phone.js` `settingsLine`), completed by `remaining()` — the SAME helper the sheet's countdown is built from, so the row and the sheet can never state different amounts of time. Rendered as one sentence: \"A code is live for 4 more minutes\". Ray's candidate-.16 defect D2: with port 8443 open and a code live, `#set-phone-open` read `Use Rich from your phone >` and nothing else, byte-for-byte the row it is with nothing happening. The whole sentence is ACTIONABLE and its control is the row it sits in — `#set-phone-open` opens the sheet with `Stop and go back` on it — and `ui/tests/settings-fit.js` (two D2 checks) asserts the words, the 16px floor and the absence of a line when there is nothing to say."
  },
  {
    "s": "<div class=\"overlay-panel\"> <!-- THE BOX THAT SCROLLS, AND IT IS NOT THE PANEL ANY MORE. The panel is a flex column of exactly two children: this, which scrolls, and the action row below, which does not. See .phone-scroll and .phone-actions in style.css for the measurements that forced the split and for why a sticky footer over one scrollport was tried first and rejected. Everything the sheet says lives in here; the way out lives underneath it and never moves. --> <div id=\"phone-scroll\" class=\"phone-scroll\"> <h2 id=\"phone-title\" class=\"overlay-title\">Use Rich from your phone</h2> <!-- ONE LEAD, TRUE OF THE ONE PATH. It was a fixed sentence describing the option he had not chosen: it stayed on screen unchanged after he chose the other one, so every screen opened by telling him the opposite of where he was (Ray's candidate .11 defect 3.1, screenshots 13, 14, 15 and 17). The fix then was to key it off the route; CEO 61 removed the route, so the key went with it. Filled from LEAD below. --> <p class=\"overlay-note\" id=\"phone-lead\"></p> <div id=\"phone-route-choice\" hidden class=\"desk-card-actions\"> <button id=\"phone-use-connect\" type=\"button\" class=\"desk-btn\">RichOS Connect</button> <button id=\"phone-use-tailnet\" type=\"button\" class=\"desk-btn\">Use Tailscale</button> </div> <div id=\"phone-connect\" hidden> <h3 class=\"phone-step-title\">RichOS Connect</h3> <p class=\"overlay-note\">Reach this Mac from your phone without setting up a VPN. Your Mac must stay awake with RichOS running.</p> <p class=\"overlay-note\">Connections are encrypted through Cloudflare. Cloudflare can process the traffic; conversations are stored on your devices.</p> <p id=\"phone-connect-status\" class=\"overlay-note\" role=\"status\"></p> <p id=\"phone-connect-host\" class=\"overlay-note\"></p> <div class=\"desk-card-actions\"> <button id=\"phone-connect-start\" type=\"button\" class=\"desk-btn\">Set up RichOS Connect</button> <button id=\"phone-connect-disable\" type=\"button\" class=\"desk-btn\" hidden>Turn off RichOS Connect</button> </div> </div> <!-- SCREEN 6 — THE PAIRED CARD, AND IT NOW HAS A TOP — Urban's G8. *\"Paired card has no heading and one text color for all five paragraphs — the actionable line reads like housekeeping.\"* Every line on it was --ink-soft at one size and one weight, labels and paragraphs alike: he measured \"Forget this phone\" and \"Close\" at 5.78:1, identical to the four paragraphs above them (Ray's frames 21 and 22). A card where nothing is the top and nothing is the point. So the phone's own name is the heading — it is what the card is ABOUT, and it is the one string on it that changes — and the push line, which is the only line that asks the reader to go and do something, is the one that takes --ink. --> <div id=\"phone-paired\" hidden> <h3 class=\"phone-step-title\" id=\"phone-device-name\"></h3> <!-- THE MAC DOES NOT SETTLE A QUESTION THE PERSON HAS NOT ANSWERED YET. This line was the fixed string \"It is paired. Open Rich on it and keep talking.\" and it was on screen while the phone, beside it, was still asking \"They match — pair this phone\" / \"They do not match\" (Ray's nightly .7, defect 2, his frame 13). The six words exist so a person can detect that something other than his Mac answered; a Mac that announces the answer first teaches him the check is ceremonial. It is filled from status.fingerprintConfirmed — the Mac's own record, never anything this sheet remembers. NO BACKTICK IN THIS FILE'S MARKUP, EVER: it is one template literal, so a backtick in a comment ends the string and takes the whole sheet with it. --> <p class=\"overlay-note\" id=\"phone-paired-state\"></p> <!-- AND THE WORDS THEMSELVES, WHILE HE IS BEING ASKED ABOUT THEM. The pairing screen that carries them is hidden the instant \"paired\" flips, which is the same instant the phone starts asking him to compare — so the Mac took its half of the comparison off the screen at exactly the moment he needed it. They go away once he has answered: a fingerprint nobody is checking is chrome. --> <p class=\"phone-words\" id=\"phone-paired-words\" hidden></p> <!-- THE PRESS ON THIS MAC, AND IT IS THE ONLY THING THAT LETS THE PHONE IN — Sage's pairing review F1 (High), richos-hq docs/research/2026-09-24-richconnect-pairing-protocol-review.md. The phone's own \"They match\" was the only confirmation the Mac ever recorded, and the device being judged performed the judgment: anybody who saw the code on this screen could pair first and confirm themselves. Until one of these two is pressed the phone's key can answer the six words and do nothing else. \"They do not match\" is the same teardown the phone's own answer runs. Both are kept out of the sheet's first focus (data-no-autofocus): a pairing is not something a reflexive Return may settle. --> <div class=\"desk-card-actions\" id=\"phone-mac-answer\" hidden> <button id=\"phone-mac-match\" class=\"desk-btn desk-btn--confirm\" type=\"button\" data-no-autofocus>They match</button> <button id=\"phone-mac-mismatch\" class=\"desk-btn\" type=\"button\" data-no-autofocus>They do not match</button> </div> <!-- THE SPENT-CODE ALARM, AFTER HE HAD ALREADY CONFIRMED (Sage F1 item 4, \"keep it and warn\"): the phone stays, and he is told somebody else used its code. --> <p class=\"overlay-note\" id=\"phone-code-reused\" role=\"status\" hidden></p> <!-- THE ONE LINE ON THIS CARD WITH AN ERRAND IN IT. Either it says the phone can reach him — which is the finish — or it names the thing on the phone that has not been done yet, in that phone's own menu names. Both are the point of the card, and both were set in the same ink as the sentence about removing a certificate. --> <p class=\"overlay-note phone-push-line\" id=\"phone-push-state\"></p> <!-- SCREEN 6's LIMIT, on the one screen where they live with it. The route chooser used to carry it too, on the option it was a condition of; that screen is gone (CEO 61), so this is the one place it is said — and it is not repeated on the screens in between, because a limitation on every screen is nagging. --> <p class=\"overlay-note\" id=\"phone-ts-limit\" hidden></p> <!-- ONE FORGET NOTE, FILLED FROM THE DEVICE RECORD. It was two paragraphs, one shown and one hidden, chosen by the sheet's own route variable — which is forgotten on every open by design, so reopening this card for a paired phone redrew the other path's iOS profile-removal steps. Ray's candidate .11 defect 3.2 caught it on an ANDROID phone that had paired over Tailscale and had nothing installed on it at all. One node, filled from status.pairedVia, is the only shape in which the two cannot disagree — see forgetNoteFor below. --> <p class=\"overlay-note\" id=\"phone-forget-note\"></p> <div class=\"desk-card-actions\"> <button id=\"phone-forget\" class=\"desk-btn\" type=\"button\">Forget this phone</button> </div> </div> <!-- SCREEN 5 — THE CODE, AND THEN THE FOUR THINGS TO DO ON THE PHONE. There is no second version of this screen any more. It used to carry, below the code, two unverified-certificate warnings, a trust QR and sixteen numbered taps through Apple's settings — the home path's half — hidden on the Tailscale route and shown on the other one. CEO §61 leaves one route, so those are gone from the product rather than hidden behind a condition, and with them the whole class of defect where the wrong half was drawn (Urban's blocker \"esc-20260919T041857Z-640acd39\", Ray's candidate .11 defect 3.1). THE CODE IS FIRST — Urban's G3 and G4. At 1024x700, the app's own minimum and the size it restores itself to, this screen is about three viewport heights tall, and pressing \"Set my phone up\" used to land on a wall of instruction with the QR, the six words, the countdown and the only Close all out of sight (his frames 04 and 05). *\"The four phone steps are preparation for a person who has not started; the code is what a person who is standing there with their phone needs. Order the screen for the second person.\"* IT IS THE MARKUP'S OWN ORDER NOW, not a node moved at render time. The mover existed because the other path numbered its headings 1, 2, 3 and the numbers were load-bearing — the certificate at step 1 was what made the address at step 2 open at all — so the code could not go above it there. With one path there is no sequence to contradict, and a subtree that is re-inserted on every two-second poll is a subtree that can take the focus out of itself. --> <div id=\"phone-pairing\" hidden> <!-- Sage's F9: Android has its own RichOS app now (CEO 76), so the line no longer sends Android to the web app. --> <p id=\"phone-connect-pair-help\" class=\"overlay-note\" hidden>In the RichOS app on your phone, scan this code. Then compare the six words on both screens.</p> <!-- IT IS HIDDEN AS A WHOLE WHEN THERE IS NO CODE. Every one of its children was already emptied on expiry (Ray's defect 3.3, and his defect B for the last of them); with the block at the top of the screen an empty wrapper is a gap where the thing he came for used to be, so the container goes with its contents. --> <div id=\"phone-code-block\"> <h3 class=\"phone-step-title\" id=\"phone-code-title\">Point your phone's camera at this</h3> <div class=\"phone-qr-row\"> <canvas id=\"phone-qr-pair\" class=\"phone-qr\" width=\"1\" height=\"1\" role=\"img\"></canvas> <div> <p class=\"overlay-note phone-url\" id=\"phone-pair-url\"></p> <p class=\"overlay-note\" id=\"phone-countdown\" role=\"status\"></p> </div> </div> <h3 class=\"phone-step-title\" id=\"phone-words-title\">Check the six words match</h3> <!-- IT GOES WITH THE CODE, AND IT NAMES A CONTROL THAT IS ON THE SCREEN. Ray's candidate-.12 defect B: after the code ran out this paragraph stayed, telling him to compare against \"these six\" with no six words under it and to \"tap Cancel\" with no Cancel button anywhere in the sheet (frame 19). Two things a person is asked to do that are not there. The heading above it and the words below it were already cleared with the code; this one was missed, so it is now hidden by the same live test they are — and the control it names is Close, which is the button this sheet actually has (id phone-close, and the sheet's own data-dismiss). --> <!-- AND THE WORDS ARE NOT HERE ANY MORE — Sage's review 3.1 steps 1 and 4. They used to be printed beside the code before any phone had arrived, which made them carry nothing the code itself does not: anybody who could see the code could see the words. They are now derived over the key the phone actually registered, so they can only exist once a phone has reached this Mac, and they appear on the paired card beside the two buttons that answer them. --> <p class=\"overlay-note\" id=\"phone-words-note\">Once your phone opens this code, six words appear on it and on this Mac. If they are the same six, press They match here. If they are not, press They do not match.</p> </div> <!-- THESE FOUR STEPS ARE THE CEO'S OWN, AND THEY OVERRIDE URBAN'S THREE. He installed and uninstalled Tailscale on Android THREE TIMES looking for a \"connect to Mac\" step that does not exist. Urban's Screen 5 had three steps and stopped at \"sign in\", which is where that hunt begins: the app is signed in, nothing says it is finished, and the user goes looking for the pairing screen Tailscale does not have. So the two missing steps — the VPN permission prompt, and the switch reading Connected — are what end the hunt, and the sentence below says outright that the thing he was hunting for is not there. Recorded in docs/verification/tailscale-path-2026-09-18.md. NOTHING ABOUT TAILNETS, MagicDNS OR MACHINE NAMES ON THIS SCREEN, by the same ruling. Those words belong on the Mac's own screens; here they are vocabulary for a thing the user does not have to think about. --> <div id=\"phone-ts-steps\"> <h3 class=\"phone-step-title\">On your phone, four things</h3> <!-- THE WHY COMES BEFORE THE STEPS, and it is here because the CEO said it is not obvious: *\"in hindsight this sounds obvious, but it's absolutely NOT obvious at all. Especially given that I would normally absolutely NEVER use the same identity on the Mac and on the phone.\"* A person whose habit is to keep two identities apart will follow a step that says \"sign in\" and use the WRONG one, correctly by their own lights, and the result is two networks that never see each other with nothing on either screen saying why. So the reason is given before the instruction, and it names the habit it is asking them to break. --> <p class=\"overlay-note\" id=\"phone-ts-why\"></p> <ol class=\"phone-steps\"> <li class=\"overlay-note\">Install Tailscale from the store.</li> <li class=\"overlay-note\" id=\"phone-ts-step2\">Sign in with the <strong>same</strong> identity you used on this Mac. A different provider makes a different network, and then the two will never see each other.</li> <li class=\"overlay-note\">Allow the VPN connection your phone asks about.</li> <li class=\"overlay-note\">The switch says Connected.</li> </ol> <p class=\"overlay-note phone-url\" id=\"phone-ts-store\"></p> <p class=\"overlay-note\"><strong>There is no pairing step in Tailscale.</strong> Sign in with the same account on both devices and they are connected.</p> <!-- THE MISMATCH IS DETECTED, NOT ONLY DESCRIBED — the CEO puts it at 9 in 10 users. A phone on the SAME account shows up in the daemon's own Peer list; one on a different provider's account is in a different tailnet and shows up nowhere. So this line is evidence rather than advice, and it names the account to use. --> <p class=\"overlay-note\" id=\"phone-ts-peer\" role=\"status\"></p> <!-- THE TRIPWIRE, AND IT IS NOW THE ONLY SENTENCE IN THE PRODUCT ABOUT INSTALLING ANYTHING ON A PHONE. Nothing this Mac serves asks for a profile any more, so a phone that is asked for one is on an origin that is not this Mac's — and the only person who can notice that is the person holding the phone. --> <p class=\"overlay-note\">Nothing has to be installed on your phone for this. If your phone asks you to install a profile, something is wrong — tell me.</p> </div> <!-- THE ONE FAILURE THIS PATH ACTUALLY DIES OF, named where it happens. Sage's §2.3 failure mode is that the name simply stops resolving; from the phone that looks like \"cannot connect\" with nothing saying why, and two different Tailscale accounts produce exactly that, silently. --> <p class=\"overlay-note\" id=\"phone-ts-failure\" hidden>If the code opens to a page that cannot connect, your phone is signed in to a different Tailscale account than this Mac.</p> <!-- WHAT HAPPENS WHEN THE CODE RUNS OUT, ON THE SCREEN IT RAN OUT ON. It used to happen in silence: the Mac dropped the window, the next poll returned no code, and the dialog fell back to an earlier screen with the QR, the code and the six words simply gone. Ray's candidate .11 defect 3.3 — \"he comes back to a screen that looks like he imagined the whole thing\". The screen stays; the code is replaced by this. --> <div id=\"phone-expired\" hidden> <h3 class=\"phone-step-title\">That code ran out</h3> <p class=\"overlay-note\" id=\"phone-expired-note\" role=\"status\"></p> </div> <!-- THE WAY BACK OUT, ON THE ONE SCREEN THAT DID NOT HAVE ONE — Urban's G2. *\"Once Set my phone up is pressed, the route chooser is unreachable for the life of the app process\"* — the expired state sets \"pairing\" as well, so waiting did not give it back either, and he could not re-reach \"This Mac is ready\" in dark at all after his walk. **THE CONTROL SURVIVES ITS OWN NAME.** It used to read \"Pick a different way\", which named the chooser it returned to; with one path there is no different way to pick, and the half of this button that was never about the chooser is the half that matters — it STOPS SERVING. It undoes a socket and a live code, which is why it calls phone_stop_pairing rather than only redrawing, and the screen it returns to is \"This Mac is ready\". See PhoneRuntime::stop_pairing for why that is not phone_forget. The four plain copies of this control — on the identity screen, on the two waiting screens and on \"This Mac is ready\" — are gone with the chooser they led to. Nothing was behind them to put down, and a button that returns to the screen you are already on is a button that does nothing. Close is on every screen and always was. **AND THE TWO OF THEM NOW LIVE IN THE FOOTER, NOT HERE** — Ray's candidate-.16 new defect. Measured in this harness at 1024x700, dark, with a code live: the panel is 592px tall in a 700px window and its content is 1196px, so on a REOPENED sheet the three controls sat at window y 1040..1116 — \"Show me another code\", \"Stop and go back\" and \"Close\", none of them on screen, under sixteen steps of how-to. Ray read the same thing off AX on the real app: y=1175..1364 against a window bottom of y=792. See .phone-actions in style.css for the pin. --> </div> <!-- SCREEN 0 — THE IDENTITY TRAP, AND IT COMES BEFORE THE DOWNLOAD. CEO §61.1, his ruling in his own words: *\"this barrier or I would call it stupidity would need to be made ABSOLUTELY UBER MEGA SUPER CRYSTAL-CLEAR to ever user of RichOS\"*. What he hit: Tailscale has no email-and-password sign-in, only \"Sign in with Apple / Google / Microsoft / GitHub\"; the account IS the network; he signed in with Apple on the Mac and Google on the Android, got two networks that cannot see each other, and REINSTALLED Tailscale on the Android three times looking for a \"connect to Mac\" step that does not exist. Nothing on Tailscale's screens says any of this. **WHY IT IS ITS OWN SCREEN AND NOT A LINE ON THE DOWNLOAD SCREEN.** By the time somebody is on the download screen the next thing they do is create the account, and the choice of identity is made inside somebody else's sign-in sheet where nothing of ours can reach them. A warning that arrives after that choice is a warning that costs a sign-out. His own sentence is the reason it cannot be a footnote: *\"in hindsight this sounds obvious, but it's absolutely NOT obvious at all. Especially given that I would normally absolutely NEVER use the same identity on the Mac and on the phone.\"* It is shown while the Mac has no Tailscale account yet — which is exactly the window in which the choice can still be made freely — and never again after detection can name one, because from then on the screens say WHICH account rather than warning about the choice. --> <div id=\"phone-identity\" hidden> <h3 class=\"phone-step-title\">First: Tailscale has no password</h3> <p class=\"overlay-note\">Tailscale has no username and password. It only offers <strong>Sign in with Google</strong>, <strong>Apple</strong>, <strong>Microsoft</strong> or <strong>GitHub</strong> — and whichever one you pick, that identity <strong>is</strong> your private network.</p> <p class=\"overlay-note\">So this Mac and your phone have to sign in with the <strong>same</strong> one. Two different identities make two separate networks that cannot see each other, and neither device says so — the phone simply never finds this Mac.</p> <p class=\"overlay-note\">There is no \"connect to my Mac\" step in Tailscale, on either device. Signing in on both with the same identity is the whole connection. If the phone cannot find this Mac, reinstalling Tailscale will not help — the identity is the only thing that decides it.</p> <p class=\"overlay-note\">If you would rather not use a personal identity on both devices, make one that is only for this — a new Google account, which costs nothing — and sign in with that one here and on the phone.</p> <div class=\"desk-card-actions\"> <button id=\"phone-identity-ok\" class=\"desk-btn desk-btn--confirm\" type=\"button\">I understand — show me what to do</button> </div> </div> <!-- SCREENS 2, 3 and 7 — the three \"something is happening elsewhere\" states. One block, because they differ only in their words and their one address: each is a thing the user does in somebody else's software, and detection is what moves the screen on. --> <div id=\"phone-ts-wait\" hidden> <h3 class=\"phone-step-title\" id=\"phone-ts-heading\"></h3> <p class=\"overlay-note\" id=\"phone-ts-note1\"></p> <p class=\"overlay-note\" id=\"phone-ts-note2\"></p> <p class=\"overlay-note phone-url\" id=\"phone-ts-url\"></p> <div class=\"desk-card-actions\"> <button id=\"phone-ts-open\" class=\"desk-btn desk-btn--confirm\" type=\"button\"></button> <button id=\"phone-ts-recheck\" class=\"desk-btn\" type=\"button\">Check again</button> </div> </div> <!-- SCREEN 4 — THIS MAC IS READY. No separate \"turn serving on\": once the name is known there is no decision left, so \"Set my phone up\" does both, under the label the product already uses. --> <div id=\"phone-ts-ready\" hidden> <h3 class=\"phone-step-title\">This Mac is ready</h3> <!-- WHICH IDENTITY IT SIGNED IN WITH, READ OFF THE MAC (§61.1). \"Use the same account\" is advice nobody can follow, because the one thing the user does not know is which one they used — that is the CEO's own account of the evening. This names it. **FIRST, AND IN BOLD** — Urban's G14. It was the third paragraph, under the machine name, set in --ink-soft with the account given no weight at all, and visually identical to the paragraphs either side of it (his frame 02). Two screens later the same account IS set in <strong> (his frame 04). *\"That asymmetry is backwards: the screen that names the account first is the one that whispers it ... it is the thing that decides whether this works, and the machine name is not.\"* AND THE PARAGRAPH BELOW STILL READS RIGHT, which is why the account went ABOVE the name rather than the name below it: \"That is this Mac's name on your own Tailscale network\" points at the line before it, so the name has to stay immediately in front of it. Heading, account, name, what the name is — each sentence next to the thing it is about. --> <p class=\"overlay-note\" id=\"phone-ts-account\"></p> <p class=\"phone-tailnet-name\" id=\"phone-ts-name\"></p> <p class=\"overlay-note\">That is this Mac's name on your own Tailscale network. Only devices signed in to your Tailscale account can reach it, and no port on this Mac is open to the internet.</p> <!-- AND THE WATCH LIVES HERE TOO, not only on the phone step. MEASURED: the pairing window is 60 s (PAIRING_WINDOW_MS) and the join grace is 60 s, and the watch starts strictly AFTER the window opens — so on the phone step alone the mismatch sentence could never be reached at all: by the time it was due, the code had expired and the block was hidden. Installing Tailscale on a phone and signing in takes minutes, not seconds, so this screen — the one the user is returned to when the code runs out — is where the sentence has to be able to appear. --> <p class=\"overlay-note\" id=\"phone-ts-peer-ready\" role=\"status\"></p> <div class=\"desk-card-actions\"> <button id=\"phone-ts-start\" class=\"desk-btn desk-btn--confirm\" type=\"button\">Set my phone up</button> </div> </div> <!-- SCREEN 8 — THE ALARM BUTTON, ANSWERED. Ray's nightly .8 walk in the test VM, defect 1 (HIGH): pressing \"They do not match\" on the phone dropped the credential, and the sheet in front of the person did not change at all. The Mac went on showing the pairing card, with the six words under it, while it had already forgotten the phone — and, until the commit this screen arrives in, while it was still answering on 8443. *\"He has no way to know the Mac heard him.\"* THE SIX WORDS EXIST FOR EXACTLY ONE SCENARIO: something other than his Mac on the other end. A Mac that says nothing when the alarm is pressed teaches him the check is ceremonial, which is worse than not asking at all. IT OUTRANKS EVERY OTHER SCREEN while it is true — see render(). What is true at that moment is not \"This Mac is ready\", even though the tailnet is; the ready screen would be the sheet forgetting the thing that just happened. AND IT HAS THE ONE CONTROL THAT LEAVES IT, which is also the only thing left to do: start again, from a Mac he now trusts. Close is in the footer as it is on every screen. The Mac cannot clear this by itself — nothing else changes it, so nothing else may. --> <div id=\"phone-rejected\" hidden> <h3 class=\"phone-step-title\">I stopped</h3> <p class=\"overlay-note\" id=\"phone-rejected-note\" role=\"status\"></p> <div class=\"desk-card-actions\"> <button id=\"phone-rejected-again\" class=\"desk-btn desk-btn--confirm\" type=\"button\">Set my phone up again</button> </div> </div> <!-- WHAT THE MAC IS DOING, OR WHY IT COULD NOT — OUTSIDE EVERY STATE BLOCK, WHICH IS A MOVE THIS CHANGE FORCED. It lived inside \"#phone-pairing\", which is hidden on five of the six screens. That was survivable while \"Set my phone up\" was pressed on a screen whose own failure mode was a certificate this Mac makes for itself and can hardly fail to make. It is not survivable now: with one path, \"phone_begin_pairing\" fails whenever Tailscale will not issue a certificate for this Mac, and that failure is read on \"This Mac is ready\" — a screen that would have shown the sentence to nobody. \"Making a certificate for your phone…\" had the same problem pointing the other way, and so did the sentence \"Get Tailscale\" shows when the Mac cannot open a link. The SOCKET DUMP that used to sit beside it is still gone — Urban's G5, *\"the one thing on this flow that looks like a debug log that shipped ... deletion is the change I want most on this screen\"*. The addresses are still printed to the log at every start, which is where a diagnosis is read from. --> <p class=\"overlay-note\" id=\"phone-message\" role=\"status\"></p> </div> <!-- ONE CLOSE, OUTSIDE THE THREE STATES AND ALWAYS VISIBLE. The first version of this sheet had three, one inside each state block, and ui/tests/escape.js refused it on the spot: data-dismiss names ONE control, the document-level Escape handler clicks it, and a button hidden with its block does nothing at all. Two of the three states could not be dismissed from the keyboard. One button that is always on screen is both the simpler markup and the only shape that can satisfy the contract. **\"ALWAYS VISIBLE\" WAS A CLAIM ABOUT THE MARKUP AND NOT ABOUT THE SCREEN, AND A PERSON FOUND THE DIFFERENCE.** One Close outside the three states is what makes it always RENDERED; it is .phone-actions below that makes it always SEEN. With a code live at 1024x700 the panel's content is 1196px in a 590px scrollport, and this row sat 445px below the window's bottom edge while the six-words note three screens above it read *\"press Close and tell me\"*. The row is now pinned to the bottom of the scrollport with position:sticky, so the how-to scrolls under it and the way out does not leave. AND THE PAIRING SCREEN'S TWO CONTROLS JOIN IT, for the same reason and in one row: two separately-pinned rows would overlap. They are hidden with the screen they belong to — by their own hidden attribute, set in render() from the same condition that shows the pairing block, because a display:none button contributes no flex gap and the row collapses to Close alone. Close stays LAST, which is where the copy points. --> <div class=\"desk-card-actions phone-actions\"> <button id=\"phone-refresh\" class=\"desk-btn desk-btn--confirm\" type=\"button\" hidden>Show me another code</button> <button id=\"phone-pairing-back\" class=\"desk-btn\" type=\"button\" hidden>Stop and go back</button> <button id=\"phone-close\" class=\"desk-btn\" type=\"button\">Close</button> </div> </div>",
    "c": "FRAGMENT",
    "why": "Composite markup for the phone sheet, including managed Connect and the optional Tailscale flow. This literal is parsed as HTML, never rendered as one sentence. Connect setup has #phone-connect-start in the same view; enabled and reconnecting states have #phone-connect-disable, and a saved paired phone has #phone-forget. A phone that reached this Mac and waits for the press (Sage's pairing review F1) has #phone-mac-match and #phone-mac-mismatch beside its six words; the pairing screen's note names both, and they are the controls on the card the phone reaches. The persistent #phone-close dismisses every state. ui/tests/phone.js and affordances.js exercise these controls through the visible sheet; contrast.js separately opens managed setup, pairing and recovery alongside the Tailscale surfaces."
  },
  {
    "s": "Forgetting it here stops this Mac answering it, and deletes the keys. This phone was paired by an older version of RichOS, which connected a way this one does not use — pair it again to keep using it. If that older version put a RichOS profile on the phone, you can remove it in the phone's own settings; nothing RichOS does now needs one.",
    "c": "INFORMATIONAL",
    "why": "The paired card's forget note for a record an older build wrote, when RichOS had a second way to pair (CEO §61 removed it). It says what to do — pair the phone again — and, because a cleanup the user has to know about is a cleanup that does not happen, that the older build may have left a profile on the phone. It is INFORMATIONAL rather than ACTIONABLE because the thing to act on is the phone, not this window; the control in the same view is `#phone-forget`, which the card is about. `ui/tests/phone.js` check 9b walks it against the record, on the first open and on a reopen, which is where the defect it replaced lived."
  },
  {
    "s": "Getting this Mac ready…",
    "c": "INFORMATIONAL",
    "why": "What `Set my phone up` says while the Mac mints its keys and asks Tailscale for a certificate. It replaced *\"Making a certificate for your phone…\"*, which described work the removed path did — nothing is made FOR the phone on this one. There is nothing to act on while it is on screen; the controls that produced it are disabled for its lifetime."
  },
  {
    "s": "You can use this anywhere your phone has a signal. Both devices have to be signed in to Tailscale for it to connect, wherever you are.",
    "c": "INFORMATIONAL",
    "why": "The paired card's one condition: both devices signed in to Tailscale. It used to end *\"— at home too\"*, which read as a carve-out from a second path that no longer exists (CEO §61); the condition is not about where the user is standing. Shown only for a phone the record says paired over the tailnet, which is `ui/tests/phone.js` check 9b's `limit` column."
  },
  // Managed Connect states and the bounded backend failures they can surface.
  {
    "s": "Connect identity generation failed",
    "c": "NOT-RENDERED",
    "why": "Internal Crypto detail. The Connect commands call PhoneError::ceo_sentence(), which replaces this text with the already-classified key-generation sentence. It is never copied to the webview."
  },
  {
    "s": "Connect identity is unreadable",
    "c": "NOT-RENDERED",
    "why": "Internal Crypto detail. The Connect commands call PhoneError::ceo_sentence(), which replaces this text with the already-classified key-generation sentence. It is never copied to the webview."
  },
  {
    "s": "Connect is off on this Mac. Its remote address is being removed.",
    "c": "INFORMATIONAL",
    "why": "Durable local disable has completed and remote cleanup is automatic; no additional user action is requested."
  },
  {
    "s": "Connect signing failed",
    "c": "NOT-RENDERED",
    "why": "Internal Crypto detail. The Connect commands call PhoneError::ceo_sentence(), which replaces this text with the already-classified key-generation sentence. It is never copied to the webview."
  },
  {
    "s": "Connecting this Mac…",
    "c": "INFORMATIONAL",
    "why": "Progress of the supervised connector, not a request to configure a vendor account."
  },
  {
    "s": "Forgetting this phone removes its access immediately. You can pair it again with a new code.",
    "c": "INFORMATIONAL",
    "why": "Explains the effect of the adjacent Forget this phone control, without asking for revocation."
  },
  {
    "s": "Keep talking to Rich when you are away from your Mac.",
    "c": "INFORMATIONAL",
    "why": "Describes the phone feature; setup and paired state controls are separately classified and tested."
  },
  {
    "s": "Pilot setup reference:",
    "c": "FRAGMENT",
    "why": "Label completed by the public host ID. It identifies the installation for pilot admission; it never contains the private identity or token."
  },
  {
    "s": "Reconnecting this Mac. Your phone keeps unsent messages until it can reach RichOS again.",
    "c": "INFORMATIONAL",
    "why": "Automatic retry progress and retained-work reassurance. Disable and Forget remain available but are not required to recover."
  },
  {
    "s": "RichOS Connect could not be reached. Your conversations are kept on your devices. Try again shortly.",
    "c": "ACTIONABLE",
    "control": "#phone-connect-start",
    "fixture": "connect-unavailable",
    "why": "Setup failed; the same-view Set up RichOS Connect button is re-enabled for retry after the request completes. The fixture drives the rejection through the real button handler."
  },
  {
    "s": "RichOS Connect is in a private pilot. An operator must admit this Mac before setup can continue.",
    "c": "NEEDS-SOMEONE-ELSE",
    "party": true,
    "fixture": "connect-admission",
    "why": "Names the person who can perform this repair or pilot admission. The UI does not offer destructive credential/history resets or pretend retry alone repairs it. The real Connect error renderer is exercised with a rejected command."
  },
  {
    "s": "RichOS Connect returned an invalid Mac address. Try again later.",
    "c": "ACTIONABLE",
    "control": "#phone-connect-start",
    "fixture": "connect-address-invalid",
    "why": "Setup failed; the same-view Set up RichOS Connect button is re-enabled for retry after the request completes. The fixture drives the rejection through the real button handler."
  },
  {
    "s": "RichOS Connect returned an invalid connection credential.",
    "c": "ACTIONABLE",
    "control": "#phone-connect-start",
    "fixture": "connect-credential-invalid",
    "why": "Setup failed; the same-view Set up RichOS Connect button is re-enabled for retry after the request completes. The fixture drives the rejection through the real button handler."
  },
  {
    "s": "RichOS Connect's saved setup is unreadable. Whoever set RichOS up needs to recover it.",
    "c": "NEEDS-SOMEONE-ELSE",
    "party": true,
    "fixture": "connect-setup-unreadable",
    "why": "Names the person who can perform this repair or pilot admission. The UI does not offer destructive credential/history resets or pretend retry alone repairs it. The real Connect error renderer is exercised with a rejected command."
  },
  {
    "s": "Set up this Mac, then pair your phone with its code.",
    "c": "ACTIONABLE",
    "control": "#phone-connect-start",
    "fixture": "connect-setup",
    "why": "The setup instruction and the actual setup control are in the same Connect panel."
  },
  {
    "s": "This Mac already has a phone paired through Tailscale. Forget that phone before changing its connection.",
    "c": "ACTIONABLE",
    "control": "#phone-forget",
    "fixture": null,
    "why": "Protects the existing phone from implicit replacement. The paired phone card offers Forget this phone in the same view; phone.js tests exercise its revocation flow. This backend guard also handles a pairing that raced setup."
  },
  {
    "s": "This Mac is connected.",
    "c": "INFORMATIONAL",
    "why": "Reports connector readiness. No human step is missing from this state."
  },
  {
    "s": "This RichOS build is missing its Connect helper. Whoever set RichOS up needs to install a complete build.",
    "c": "NEEDS-SOMEONE-ELSE",
    "party": true,
    "fixture": "connect-helper-missing",
    "why": "Names the person who can perform this repair or pilot admission. The UI does not offer destructive credential/history resets or pretend retry alone repairs it. The real Connect error renderer is exercised with a rejected command."
  },
  {
    "s": "Unknown Connect action",
    "c": "UNREACHABLE",
    "why": "Developer guard on the hard-coded signed control route table. No UI command supplies a method or path; all shipped callers use one of the accepted routes."
  },
  {
    "s": "{\"awaiting_mac_confirmation\":true,\"reason\":\"Press They match on your Mac.\"}",
    "c": "NOT-RENDERED",
    "why": "The phone channel's 409 body for an authenticated device nobody has confirmed on this Mac yet (Sage's pairing review F1; `routes::AWAITING_MAC_BODY`). It is bytes on the wire to the phone, never drawn in this Mac's webview: the phone reads the flag and shows its own waiting screen, and the Mac's sheet carries its own sentence and the two buttons (#phone-mac-match, #phone-mac-mismatch)."
  },
  {
    "s": "Your Mac could not save the delivery receipt. Your text is still on your phone.",
    "c": "INFORMATIONAL",
    "why": "The authenticated phone API reports a retryable storage failure. The existing phone queue retains the message and retries; this does not ask the person to resend it."
  },
  {
    "s": "Your Mac's message recovery history exceeds its safe limit. Whoever set RichOS up needs to recover it.",
    "c": "NEEDS-SOMEONE-ELSE",
    "party": true,
    "fixture": "connect-history-full",
    "why": "Names the person who can perform this repair or pilot admission. The UI does not offer destructive credential/history resets or pretend retry alone repairs it. The real Connect error renderer is exercised with a rejected command."
  },
  {
    "s": "Your Mac's message recovery history is unreadable. Whoever set RichOS up needs to recover it.",
    "c": "NEEDS-SOMEONE-ELSE",
    "party": true,
    "fixture": "connect-history-unreadable",
    "why": "Names the person who can perform this repair or pilot admission. The UI does not offer destructive credential/history resets or pretend retry alone repairs it. The real Connect error renderer is exercised with a rejected command."
  },
  {
    "s": "Your phone's pairing is saved. RichOS is trying to restore its connection.",
    "c": "INFORMATIONAL",
    "why": "The recovery monitor retries the stopped listener without replacing identity; the saved-pairing card retains its Forget control."
  },
];
