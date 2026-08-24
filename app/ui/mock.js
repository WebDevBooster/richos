// RichOS UI — dev mock harness. ONLY active when `window.__TAURI__` is absent (i.e. this
// page is opened directly in a browser, not inside the Tauri shell). Lets design and QA
// exercise every state in the v1 front-end UX direction §6 — first-run,
// streaming, working, thread switching, voice, proactive, drill-down — with NO live Claude
// and NO Tauri window. Simulates the exact `rich://*` payload shapes from app/STREAMING.md
// and the exact command return shapes from app/src-tauri/src/main.rs, so main.js never
// branches on "am I mocked" — it only ever talks to `window.RichBridge`.
//
// Never shipped-live behavior: in the real Tauri build this file loads but no-ops (guarded
// by the `window.__TAURI__` check below), so it is inert in production.
(function () {
  if (window.__TAURI__) return; // real shell present — this harness stays dormant.

  const now = () => Date.now();
  const uid = (p) => `${p}_${Math.random().toString(36).slice(2, 10)}`;

  // --- fixture state -------------------------------------------------------
  const threads = [
    // Deliberately titled "General" + earliest created_at — mirrors the real spine's
    // `ensure_active_thread` default (spine.rs:112) so the client-side "Running" relabel
    // (main.js `displayTitle`) is exercised exactly as it will be against the live backend.
    { id: "general", title: "General", created_at: now() - 1000 * 60 * 60 * 24 * 3, message_count: 0, last_activity: now() },
    { id: "acme", title: "Acme deal", created_at: now() - 1000 * 60 * 60 * 20, message_count: 4, last_activity: now() - 1000 * 60 * 30 },
    { id: "hiring", title: "Q4 hiring", created_at: now() - 1000 * 60 * 60 * 40, message_count: 2, last_activity: now() - 1000 * 60 * 60 * 5 },
  ];
  let activeThreadId = "general";

  /** thread_id -> Message[] ({ role, text, turn_id, at }) — matches ledger::Message field
   * names verbatim (snake_case, no serde rename in the Rust struct). */
  // IMPORTANT: each user+assistant pair below shares ONE turn_id (a fresh `uid("t")` per
  // turn, reused for both lines) — exactly like the real ledger (ledger.rs `messages()`:
  // both the user and assistant Message for a turn are stamped `t.id.clone()` from the
  // SAME Turn). Giving each line its own id (an earlier bug here) made every ordinary
  // reply misfire the proactive "reached out" heuristic in main.js — a good example of why
  // the fixture shape has to mirror the real data model exactly, not just look plausible.
  const acmeTurn1 = uid("t");
  const acmeTurn2 = uid("t");
  const hiringTurn1 = uid("t");
  const messagesByThread = {
    general: [],
    acme: [
      { role: "user", text: "what's the status on Acme?", turn_id: acmeTurn1, at: now() - 1000 * 60 * 60 * 20 },
      {
        role: "assistant",
        text: "Their counter came in this morning — 8% below list. I've pulled comparables and it's within range. Want me to draft a response or do you want to see the comps first?",
        turn_id: acmeTurn1,
        at: now() - 1000 * 60 * 60 * 20 + 4000,
      },
      { role: "user", text: "draft it, keep it firm", turn_id: acmeTurn2, at: now() - 1000 * 60 * 30 },
      {
        role: "assistant",
        text: "Done — firm counter drafted, holding at list minus 3%. Sitting in your review queue.",
        turn_id: acmeTurn2,
        at: now() - 1000 * 60 * 30 + 3000,
      },
    ],
    hiring: [
      { role: "user", text: "where are we on the Q4 reqs?", turn_id: hiringTurn1, at: now() - 1000 * 60 * 60 * 5 },
      {
        role: "assistant",
        text: "Three of five roles have candidates in final round. The platform-eng req is still thin — I've asked the recruiter for a wider pass.",
        turn_id: hiringTurn1,
        at: now() - 1000 * 60 * 60 * 5 + 2500,
      },
    ],
  };

  const listeners = {}; // eventName -> Set<fn>
  function emit(eventName, payload) {
    const set = listeners[eventName];
    if (!set) return;
    for (const fn of set) fn({ event: eventName, payload });
  }

  // Canned reply text the mock "streams" back, chunked by word so seq-ordering is
  // exercised exactly like the real spine (see app/STREAMING.md ordering guarantees).
  const CANNED_REPLIES = [
    "Got it — I'll take it from here. Give me a moment to pull what I need.",
    "Understood. I've made a note and I'll follow up once I have something concrete.",
    "On it. I'll check with the relevant thread and come back to you shortly.",
  ];

  function simulateTurn(threadId, userText) {
    const turnId = uid("turn");
    const userAt = now();
    messagesByThread[threadId] = messagesByThread[threadId] || [];
    messagesByThread[threadId].push({ role: "user", text: userText, turn_id: turnId, at: userAt });

    emit("rich://turn-started", { threadId, turnId, at: now() });

    const reply = CANNED_REPLIES[Math.floor(Math.random() * CANNED_REPLIES.length)];
    const words = reply.split(" ");
    let seq = 0;
    let acc = "";
    let i = 0;

    function next() {
      if (i >= words.length) {
        messagesByThread[threadId].push({ role: "assistant", text: acc.trim(), turn_id: turnId, at: now() });
        emit("rich://turn-completed", { threadId, turnId, stopReason: "end_turn", at: now() });
        return;
      }
      const delta = (i === 0 ? "" : " ") + words[i];
      acc += delta;
      emit("rich://chunk", { threadId, turnId, seq: seq++, textDelta: delta, at: now() });
      i += 1;
      setTimeout(next, 60 + Math.random() * 90);
    }
    // Small "thinking" delay before the first chunk so the working state is visibly exercised.
    setTimeout(next, 500 + Math.random() * 400);
  }

  window.RichBridge = {
    isMock: true,

    async invoke(cmd, args) {
      args = args || {};
      switch (cmd) {
        case "list_threads":
          return threads.map((t) => ({ ...t, message_count: (messagesByThread[t.id] || []).length }));
        case "active_thread":
          return activeThreadId;
        case "create_thread": {
          const id = uid("thread");
          const title = (args.title || "New thread").trim() || "New thread";
          threads.push({ id, title, created_at: now(), message_count: 0, last_activity: now() });
          messagesByThread[id] = [];
          return id;
        }
        case "switch_thread":
          activeThreadId = args.threadId ?? args.thread_id;
          return null;
        case "get_messages":
          // A DEFENSIVE COPY — real Tauri IPC always deep-serializes a command's return
          // value, so main.js can never end up holding a live reference into the Rust
          // ledger's own storage. Returning the live array here (an earlier bug) let
          // main.js's `messages.push(...)` optimistic-append silently mutate the mock's
          // canonical store, permanently leaking the optimistic placeholder into history
          // — a class of bug that is IMPOSSIBLE against the real backend, so the mock must
          // not manufacture it either.
          return (messagesByThread[args.threadId ?? args.thread_id] || []).map((m) => ({ ...m }));
        case "send_message": {
          if (window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__._notConnected) {
            // Mirrors main.rs's `lease_ready == false` path: rejects before any turn
            // starts, so NO rich:// events ever fire for this attempt.
            return Promise.reject(
              "I'm not connected to my thinking right now — check that the Claude CLI is signed in, then restart me."
            );
          }
          simulateTurn(activeThreadId, args.text);
          return messagesByThread[activeThreadId];
        }
        default:
          // Unwired-yet commands (voice capture, worker status, assertiveness persistence)
          // reject exactly like a real Tauri call to an unregistered command would — main.js
          // must degrade gracefully rather than assume these exist.
          return Promise.reject(`mock: no such command "${cmd}"`);
      }
    },

    async listen(eventName, cb) {
      listeners[eventName] = listeners[eventName] || new Set();
      listeners[eventName].add(cb);
      return () => listeners[eventName].delete(cb);
    },
  };

  // --- dev-only test hooks, exercised by a headless check, never by real users ----------
  window.__RICHOS_MOCK__ = {
    simulateProactiveDigest(threadId = "general") {
      const turnId = uid("turn");
      const msg = {
        role: "assistant",
        text: "Morning. Three things when you have a moment —\n  • Launch plan's ready for your sign-off.\n  • Finance found a gap in the Q4 forecast; I've got them digging.\n  • Partnerships wants a call on the Acme economics.\nNo rush on any of these. Say the word and I'll take each one.",
        turn_id: turnId,
        at: now(),
      };
      messagesByThread[threadId].push(msg);
      emit("rich://mock-proactive", { threadId, message: msg, tier: "digest" });
    },
    simulateProactiveInterrupt(threadId = "acme") {
      const turnId = uid("turn");
      const msg = {
        role: "assistant",
        text: "The Acme counter-offer expires at noon and I need your walk-away number before I respond. What's the floor?",
        turn_id: turnId,
        at: now(),
      };
      messagesByThread[threadId].push(msg);
      emit("rich://mock-proactive", { threadId, message: msg, tier: "interrupt" });
    },
    simulateDrillChip(threadId = "acme") {
      emit("rich://mock-worker-status", {
        threadId,
        items: [
          { label: "pulling comparables", state: "active" },
          { label: "drafting the counter", state: "active" },
          { label: "pulled Q3 economics", state: "done" },
          { label: "walk-away price", state: "needs_you" },
        ],
      });
    },
    clearDrillChip(threadId = "acme") {
      emit("rich://mock-worker-status", { threadId, items: [] });
    },
    setNotConnected(v) {
      window.__RICHOS_MOCK__._notConnected = v;
    },
    _notConnected: false,
  };
})();
