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
// annotates it. `affordances.js` asserts the two sets are EQUAL — a string added to
// index.html, main.js, timeline.js, the Tauri command layer or a `ceo_message()` and not
// classified here fails the suite, and a row here whose string no longer exists in the
// product fails it too. There is no way to add a state and quietly skip the question.
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
    s: "I hit a snag mid-thought and had to stop — say the word and I'll pick it back up.",
    c: "ACTIONABLE",
    control: ".tl-intervention button.tl-intervention-action",
    fixture: "failed-turn",
    why: "§5.5 failure card. 'Say the word' is answered by the button directly beneath it.",
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
    s: "My ears aren't installed on this machine yet — whoever set RichOS up adds those. I can still read what you type.",
    c: "NEEDS-SOMEONE-ELSE",
    party: true,
    fixture: null,
    why:
      "Needs a real SttError::BinaryNotFound from a live pipeline; the mock bridge does not " +
      "reach richos-voice. The fallback it names (typing) is the composer, always present.",
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
      "'Pick it back up' that picks up nothing is worse than none.",
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
  {
    s: "You stopped this before it started running, so there is no time to report.",
    c: "INFORMATIONAL",
    why: "Explains an absent duration.",
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
    why: "The unrecognised-state fallback. Nothing for the CEO to do about a protocol surprise.",
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
    s: "I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from there. You can type, or tap ◉ to talk to me.",
    c: "INFORMATIONAL",
    why:
      "First-run greeting. An invitation, not a state he could change — and it names both " +
      "controls anyway (#input and #talk-toggle).",
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

  // -------------------------------------------------------------------------------------
  // CONTROL — the string is an affordance, not a state that needs one
  // -------------------------------------------------------------------------------------
  { s: "+ New thread", c: "CONTROL", why: "#rail-new-thread." },
  { s: "Start a new thread instead", c: "CONTROL", why: "#unbound-new-thread — §21's way out." },
  { s: "Pick it back up", c: "CONTROL", why: "The retry button on both intervention cards." },
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
  { s: "Which entity is this work in?", c: "CONTROL", why: "Entity picker title over its list." },
  { s: "Search entities, threads and conversations…", c: "CONTROL", why: "#search-input placeholder." },
  { s: "Talk to Rich", c: "CONTROL", why: "#talk-toggle title." },
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
  // UNREACHABLE / NOT-RENDERED
  // -------------------------------------------------------------------------------------
  {
    s: "I can't safely tell which entity area this belongs to, so I won't guess. Set RICHOS_ENTITY to one of femcboost, deeply, prospects or richos, or launch me from that entity's repository root.",
    c: "UNREACHABLE",
    why:
      "A terminal instruction, and NOT reachable from the shipped UI: the only commands that " +
      "raise it are `create_thread` and the three `loro_*` drill-downs, none of which main.js " +
      "invokes (checked by enumerating every `Bridge.invoke(\"…\")` in main.js). Its live " +
      "audience is the eprintln! at boot — the operator, for whom RICHOS_ENTITY is exactly the " +
      "right instruction. A doc comment at main.rs:246 records what must change the day a " +
      "slice wires one of those commands to a button.",
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
    s: "mock: no such command",
    c: "NOT-RENDERED",
    why:
      "A comparison string (`msg.startsWith(...)` at main.js:1057), never written to the DOM. " +
      "A genuine false positive of the prose filter, kept visible rather than special-cased " +
      "away — a filter with a hidden exception list is the next drift.",
  },
];
