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
  { s: "Show it when RichOS starts", c: "CONTROL", why: "The opening screen's off switch — a checkbox label, and the control IS the state." },
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
    s: "That's the setting up done.",
    c: "INFORMATIONAL",
    fixture: "setup-finished",
    why:
      "The heading after a run the backend agrees is complete. It exists because the title " +
      "used to keep COUNTING WHAT WAS MISSING after the run: a finished install showed " +
      "\"There's one thing I need on this Mac.\" over \"That's everything. I'm ready.\", two " +
      "sentences contradicting each other on screen at once. Both are set from the same " +
      "`next.complete`, so they cannot come apart again. Nothing to do — it is the " +
      "confirmation that the question is over.",
  },
  {
    s: "I couldn't finish the setting up.",
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
      "You'll still need your own Anthropic account, and to sign in to it once. I can't do " +
      "that part for you, and I never see your password.",
    c: "INFORMATIONAL",
    fixture: "setup-missing-both",
    why:
      "`open-items.md` row 3.14's second condition, on the sheet and above the button: " +
      "\"D removes one setup step of two, not all of them — RichOS is BYO-Anthropic, so the " +
      "customer still needs an account and a login, and D must not be sold to him as " +
      "zero-touch.\" " +
      "CLASSIFIED INFORMATIONAL DELIBERATELY, AND HERE IS THE ARGUMENT, because it is the " +
      "one row on this sheet where the bucket is arguable. It is a statement of SCOPE — what " +
      "this press does not cover — and not a state of the app. The act it describes happens " +
      "entirely outside RichOS: there is no login flow inside RichOS at all (§19), so no " +
      "control in this view or any other could perform it, which rules ACTIONABLE out; and " +
      "the person is HIM, which rules NEEDS-SOMEONE-ELSE out, since that bucket exists to " +
      "point him at somebody who is not him. Calling it INFORMATIONAL is not a claim that " +
      "there is nothing for him to do — it is a claim that there is nothing for him to do " +
      "HERE, which is exactly why the sentence is on the sheet before the button rather " +
      "than after it.",
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
    s: "That's everything. I'm ready.",
    c: "INFORMATIONAL",
    fixture: "setup-finished",
    why:
      "What he sees when the run finished AND the backend, re-reading the disk, agrees " +
      "nothing is missing. Nothing to do; it is the confirmation that the question is over.",
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
    s: "Technical view is on for this conversation. Turn it off.",
    c: "CONTROL",
    why: "#techy-chip's accessible name in the pinned case — the label plus what pressing it does.",
  },
  {
    s: "Technical view is on for every conversation. Turn it off here.",
    c: "CONTROL",
    why: "#techy-chip's accessible name in the global case. 'here' because the switch it undoes is in Settings.",
  },
  { s: "Show the technical view", c: "CONTROL", why: "Settings popover title over #techy-default." },
  { s: "In every conversation", c: "CONTROL", why: "#techy-default's checkbox label — §3.1's one switch for 'all'." },
  {
    s: "This conversation is set on its own. changes just this one.",
    c: "CONTROL",
    why:
      "#techy-hint under the Settings switch, with the `${key}` shortcut hole folded out by " +
      "the scraper — it renders as 'This conversation is set on its own. ⌘⇧T changes just " +
      "this one.' It describes the KEYBOARD affordance and distinguishes it from the switch " +
      "beside it, so it is a control's description rather than a state: there is no fault " +
      "here and nothing has gone wrong.",
  },
  {
    s: "shows it for one conversation only.",
    c: "CONTROL",
    why: "The other branch of #techy-hint, for a thread that is following the global default. Same hole, same job.",
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
];
