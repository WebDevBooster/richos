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
  // The four dogfood entity areas, mirroring `EntityRegistry::dogfood()` (entity.rs) —
  // same ids, same display names, same roots — so the rail's grouping is exercised against
  // the real registry's shape rather than an invented one.
  const entities = [
    { id: "femcboost", display_name: "FemcBoost", status: "active", roots: ["/Users/alex/ab/femcboost"] },
    { id: "deeply", display_name: "Deeply", status: "active", roots: ["/Users/alex/ab/deeply"] },
    { id: "prospects", display_name: "Prospects", status: "active", roots: ["/Users/alex/ab/prospects"] },
    { id: "richos", display_name: "RichOS", status: "active", roots: ["/Users/alex/ab/richos"] },
  ];

  // `entity_id: null` is the LEGACY-THREAD case slice 1 introduced (`ThreadEntity::Unbound`):
  // a record written before entity scoping existed. It is LISTED — an operator has to be
  // able to see it — but every scoped read against it refuses. `legacy` below reproduces
  // that exactly, including the ledger's own refusal message, so the binding-failure state
  // (§21) can be exercised without a pre-entity ledger on disk.
  const threads = [
    { id: "general", title: "Running", entity_id: "richos", created_at: now() - 1000 * 60 * 60 * 24 * 3, message_count: 0, last_activity: now(), last_turn_state: null, has_pending_turn: false },
    { id: "acme", title: "Acme deal", entity_id: "femcboost", created_at: now() - 1000 * 60 * 60 * 20, message_count: 4, last_activity: now() - 1000 * 60 * 30, last_turn_state: "completed", has_pending_turn: false },
    { id: "hiring", title: "Q4 hiring", entity_id: "femcboost", created_at: now() - 1000 * 60 * 60 * 40, message_count: 2, last_activity: now() - 1000 * 60 * 60 * 5, last_turn_state: "completed", has_pending_turn: false },
    { id: "partner", title: "Partner book review", entity_id: "deeply", created_at: now() - 1000 * 60 * 60 * 30, message_count: 2, last_activity: now() - 1000 * 60 * 60 * 9, last_turn_state: "interrupted", has_pending_turn: false },
    { id: "ecs", title: "ECS architecture", entity_id: "richos", created_at: now() - 1000 * 60 * 60 * 50, message_count: 0, last_activity: now() - 1000 * 60 * 60 * 12, last_turn_state: "in_flight", has_pending_turn: true },
    { id: "legacy", title: "Notes from before", entity_id: null, created_at: now() - 1000 * 60 * 60 * 24 * 40, message_count: 0, last_activity: now() - 1000 * 60 * 60 * 24 * 40, last_turn_state: null, has_pending_turn: false },
  ];
  let activeThreadId = "general";

  // Verbatim from `LedgerError::UnboundThread` (ledger.rs). Copied rather than paraphrased
  // so the harness cannot drift from the sentence the real backend raises.
  const UNBOUND_ERR = (id) =>
    "thread " + id + " has no entity binding: it predates entity scoping, and Rich will not guess " +
    "which entity this work belongs to. An operator must bind it explicitly.";

  const navPrefs = {
    sidebar_width: 300,
    sidebar_collapsed: false,
    collapsed_entities: [],
    pinned_threads: [],
    archived_threads: [],
    renamed_threads: {},
  };

  function displayTitleOf(t) {
    return navPrefs.renamed_threads[t.id] || t.title;
  }

  function threadRowOf(t) {
    return {
      id: t.id,
      title: t.title,
      display_title: displayTitleOf(t),
      entity_id: t.entity_id,
      binding_revision: t.entity_id ? 1 : 0,
      created_at: t.created_at,
      last_activity: t.last_activity,
      message_count: (messagesByThread[t.id] || []).length,
      pinned: navPrefs.pinned_threads.includes(t.id),
      archived: navPrefs.archived_threads.includes(t.id),
      // An unbound thread's turns are NOT read (the scoped accessor refuses), so it
      // reports no state at all — matching `thread_turn_facts` in main.rs.
      last_turn_state: t.entity_id ? t.last_turn_state : null,
      has_pending_turn: t.entity_id ? !!t.has_pending_turn : false,
    };
  }

  function setMembership(list, id, member) {
    const at = list.indexOf(id);
    if (member && at < 0) list.push(id);
    if (!member && at >= 0) list.splice(at, 1);
  }

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
  const partnerTurn1 = uid("t");
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
    partner: [
      { role: "user", text: "how did the partner book review land?", turn_id: partnerTurn1, at: now() - 1000 * 60 * 60 * 9 },
      {
        role: "assistant",
        text: "Two partners pushed back on the carry split. I have the numbers but I stopped short of a recommendation — I want your read on the Hensley relationship first.",
        turn_id: partnerTurn1,
        at: now() - 1000 * 60 * 60 * 9 + 3000,
      },
    ],
    ecs: [],
    legacy: [],
  };

  function activeContextOf() {
    const t = threads.find((x) => x.id === activeThreadId);
    if (!t || !t.entity_id) return null;
    return { thread_id: t.id, entity_id: t.entity_id, binding_revision: 1 };
  }

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
        case "navigation_tree": {
          // Grouping happens HERE, not in the renderer — same division of labour as the
          // real `navigation_tree` command, so main.js exercises the identical shape.
          const groups = entities.map((entity) => ({
            entity,
            threads: threads
              .filter((t) => t.entity_id === entity.id)
              .map(threadRowOf)
              .sort((a, b) => b.last_activity - a.last_activity),
          }));
          return {
            groups,
            unbound: threads.filter((t) => !t.entity_id).map(threadRowOf),
            active: activeContextOf(),
            unbound_explanation:
              "This thread has no entity home: it predates entity scoping, and Rich will not guess " +
              "which entity this work belongs to. An operator must bind it explicitly.",
          };
        }
        case "active_context":
          return activeContextOf();
        case "thread_scope": {
          const id = args.threadId ?? args.thread_id;
          const t = threads.find((x) => x.id === id);
          if (!t) return Promise.reject("unknown thread: " + id);
          if (!t.entity_id) return Promise.reject(UNBOUND_ERR(id));
          return { thread_id: id, entity_id: t.entity_id, binding_revision: 1 };
        }
        case "create_thread_in": {
          const entityId = args.entityId ?? args.entity_id;
          if (!entities.some((e) => e.id === entityId)) return Promise.reject("unknown entity: " + entityId);
          const id = uid("thread");
          threads.push({
            id,
            title: (args.title || "New thread").trim() || "New thread",
            entity_id: entityId,
            created_at: now(),
            message_count: 0,
            last_activity: now(),
            last_turn_state: null,
            has_pending_turn: false,
          });
          messagesByThread[id] = [];
          activeThreadId = id;
          return id;
        }
        case "search_nav": {
          const q = String(args.query || "").trim().toLowerCase();
          if (!q) return [];
          const labelOf = (eid) => (entities.find((e) => e.id === eid) || {}).display_name || "No entity";
          const hits = [];
          for (const e of entities) {
            if (e.display_name.toLowerCase().includes(q) || e.id.includes(q)) {
              hits.push({ kind: "entity", entity_id: e.id, entity_label: e.display_name, thread_id: null, thread_title: null, excerpt: e.display_name, at: 0 });
            }
          }
          for (const t of threads) {
            if (displayTitleOf(t).toLowerCase().includes(q) || t.title.toLowerCase().includes(q)) {
              hits.push({ kind: "thread", entity_id: t.entity_id, entity_label: labelOf(t.entity_id), thread_id: t.id, thread_title: displayTitleOf(t), excerpt: "", at: t.last_activity });
            }
          }
          for (const t of threads) {
            // An unbound thread's BODY is never searched — the scoped read refuses, so the
            // real command skips it, and so does this.
            if (!t.entity_id) continue;
            let perThread = 0;
            for (const m of (messagesByThread[t.id] || []).slice().reverse()) {
              if (perThread >= 3) break;
              const at = m.text.toLowerCase().indexOf(q);
              if (at < 0) continue;
              const start = Math.max(0, at - 60);
              const end = Math.min(m.text.length, at + q.length + 60);
              const excerpt = (start > 0 ? "…" : "") + m.text.slice(start, end) + (end < m.text.length ? "…" : "");
              // Same one-match-one-row rule the real `search_nav` applies.
              if (excerpt === displayTitleOf(t)) continue;
              hits.push({
                kind: "message",
                entity_id: t.entity_id,
                entity_label: labelOf(t.entity_id),
                thread_id: t.id,
                thread_title: displayTitleOf(t),
                excerpt,
                at: m.at,
              });
              perThread += 1;
            }
          }
          return hits.slice(0, args.limit || 40);
        }
        case "nav_state":
          return JSON.parse(JSON.stringify(navPrefs));
        case "set_sidebar_width":
          navPrefs.sidebar_width = Math.max(224, Math.min(420, Number(args.width) || 300));
          return navPrefs.sidebar_width;
        case "set_sidebar_collapsed":
          navPrefs.sidebar_collapsed = !!args.collapsed;
          return null;
        case "set_entity_collapsed":
          setMembership(navPrefs.collapsed_entities, args.entityId ?? args.entity_id, !!args.collapsed);
          return null;
        case "set_thread_pinned":
          setMembership(navPrefs.pinned_threads, args.threadId ?? args.thread_id, !!args.pinned);
          return null;
        case "set_thread_archived":
          setMembership(navPrefs.archived_threads, args.threadId ?? args.thread_id, !!args.archived);
          return null;
        case "rename_thread": {
          const id = args.threadId ?? args.thread_id;
          const title = String(args.title || "").trim().slice(0, 200);
          if (title) navPrefs.renamed_threads[id] = title;
          else delete navPrefs.renamed_threads[id];
          return null;
        }
        case "create_thread": {
          const id = uid("thread");
          const title = (args.title || "New thread").trim() || "New thread";
          threads.push({ id, title, created_at: now(), message_count: 0, last_activity: now() });
          messagesByThread[id] = [];
          return id;
        }
        case "switch_thread": {
          const id = args.threadId ?? args.thread_id;
          const t = threads.find((x) => x.id === id);
          // An unbound thread cannot become the active context — activation re-reads the
          // entity from the durable record and there isn't one. Mirrors `Spine::activate`.
          if (t && !t.entity_id) return Promise.reject(UNBOUND_ERR(id));
          activeThreadId = id;
          return null;
        }
        case "get_messages":
          // A DEFENSIVE COPY — real Tauri IPC always deep-serializes a command's return
          // value, so main.js can never end up holding a live reference into the Rust
          // ledger's own storage. Returning the live array here (an earlier bug) let
          // main.js's `messages.push(...)` optimistic-append silently mutate the mock's
          // canonical store, permanently leaking the optimistic placeholder into history
          // — a class of bug that is IMPOSSIBLE against the real backend, so the mock must
          // not manufacture it either.
          {
            const id = args.threadId ?? args.thread_id;
            const t = threads.find((x) => x.id === id);
            // THE REJECTION THAT USED TO BREAK THE SHELL. `get_messages` became fallible
            // when threads gained an entity home: an unbound thread refuses rather than
            // returning an empty list. Reproduced here so the calm §21 binding-failure
            // state is exercised in the browser harness, not only against a real ledger.
            if (t && !t.entity_id) return Promise.reject(UNBOUND_ERR(id));
            return (messagesByThread[id] || []).map((m) => ({ ...m }));
          }
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
    /// Start a turn in a thread OTHER than the selected one, so §25's "a working thread
    /// remains visibly active while another thread is selected" can be exercised without a
    /// live compute lease. It runs the SAME `simulateTurn` a real send runs — the rail's
    /// mark comes from the ordinary `rich://turn-started` event, not from a special path.
    simulateBackgroundTurn(threadId = "hiring", text = "run the numbers again") {
      simulateTurn(threadId, text);
    },
    setNotConnected(v) {
      window.__RICHOS_MOCK__._notConnected = v;
    },
    _notConnected: false,
  };
})();
