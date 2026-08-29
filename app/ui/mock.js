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
    inspector_width: 336,
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

  // TURN RECORDS — the harness's stand-in for `ledger::Turn`, holding exactly the fields
  // `Timeline::project` reads to build a `work_duration` row. Without them the harness could
  // only fake a timeline; with them it PROJECTS one, from the same fields, using the same
  // derived item ids (`{turnId}:user`, `{turnId}:text:{n}`, `{turnId}:duration`).
  //
  // This is NOT §26's deterministic `memory-strategy` fixture — that is slice 8, with its own
  // scripted 16-step scenario and injectable clock. This is the existing canned turn, given
  // the shape the §13 contract actually has, so the browser harness is not dead against the
  // renderer that ships.
  const turnsById = new Map(); // turnId -> { threadId, entityId, userText, runs, state, createdAt, startedAt, endedAt }

  function seedTurn(threadId, turnId, userText, replyText, at, durationMs) {
    const t = threads.find((x) => x.id === threadId);
    turnsById.set(turnId, {
      threadId,
      entityId: t ? t.entity_id : null,
      userText,
      runs: replyText ? [{ text: replyText, startSeq: 0, at: at + 2000 }] : [],
      state: "completed",
      createdAt: at,
      startedAt: at,
      endedAt: at + durationMs,
      activities: [],
    });
  }

  /// The harness's `Timeline::project` + `view(ViewMode::Ceo)`, in the same ORDER and with
  /// the same derived ids as timeline.rs. Item order within a turn is
  /// `(slot, sequence)` — opening, then the stream in shared-counter order, then terminal —
  /// which is `TimelineBase::order_key`.
  function projectTimeline(threadId) {
    const t = threads.find((x) => x.id === threadId);
    const items = [];
    const rev = t && t.entity_id ? 1 : 0;
    const baseOf = (turn, id, seq, slot, at) => ({
      id,
      entityId: turn.entityId,
      threadId: turn.threadId,
      turnId: null, // set by the caller
      bindingRevision: rev,
      createdAt: at,
      sequence: seq,
      slot,
      visibility: "ceo",
    });
    for (const [turnId, turn] of turnsById) {
      if (turn.threadId !== threadId) continue;
      // A SUPERSEDED TURN CONTRIBUTES NOTHING. `Timeline::project` demotes it wholesale to
      // `Internal` (`turn.superseded_by.is_some()` -> `internal_turn`), and `view(Ceo)`
      // removes it — so the CEO sees ONE clean exchange rather than a duplicated prompt.
      // Reproduced here because without it the harness projects something the real backend
      // never would, and would hide exactly the defect this case exists to catch.
      if (turn.supersededBy) continue;
      if (turn.userText) {
        items.push(
          Object.assign(baseOf(turn, turnId + ":user", null, "opening", turn.createdAt), {
            kind: "user_message",
            turnId,
            text: turn.userText,
            source: "text",
          })
        );
      }
      turn.runs.forEach((run, idx) => {
        items.push(
          Object.assign(baseOf(turn, turnId + ":text:" + idx, run.startSeq, "stream", run.at), {
            kind: "rich_message",
            turnId,
            // ALWAYS "unknown" for a streamed reply — `STREAMED_MESSAGE_PHASE` (live.rs).
            phase: "unknown",
            text: run.text,
          })
        );
      });
      for (const a of turn.activities) {
        items.push(Object.assign({}, a, { turnId, bindingRevision: rev }));
      }
      // `active_ms` is MEASURED (`ended_at - started_at`) and is null whenever either
      // endpoint is missing — never `now() - startedAt` (§6.3).
      const activeMs =
        typeof turn.startedAt === "number" && typeof turn.endedAt === "number" && turn.endedAt >= turn.startedAt
          ? turn.endedAt - turn.startedAt
          : null;
      const dur = Object.assign(baseOf(turn, turnId + ":duration", null, "terminal", turn.createdAt), {
        kind: "work_duration",
        turnId,
        state: turn.state,
        startedAt: turn.startedAt,
        endedAt: turn.endedAt,
      });
      if (activeMs !== null) dur.activeMs = activeMs;
      items.push(dur);
    }
    return { entityId: t ? t.entity_id : null, threadId, mode: "ceo", items };
  }

  // The canned history above, as turn records. Durations are deliberately spread across
  // three of §6.2's four display bands so the format is exercised, not just the code path:
  //   acmeTurn1   4_207_000ms -> "1h 10m 7s"   (hour band)
  //   acmeTurn2     247_000ms -> "4m 7s"       (minute band)
  //   hiringTurn1    18_360ms -> "18s"         (second band)
  //   partnerTurn1  interrupted, endedAt absent -> no number at all
  seedTurn("acme", acmeTurn1, "what's the status on Acme?",
    "Their counter came in this morning — 8% below list. I've pulled comparables and it's within range. Want me to draft a response or do you want to see the comps first?",
    now() - 1000 * 60 * 60 * 20, 4207000);
  seedTurn("acme", acmeTurn2, "draft it, keep it firm",
    "Done — firm counter drafted, holding at list minus 3%. Sitting in your review queue.",
    now() - 1000 * 60 * 30, 247000);
  seedTurn("hiring", hiringTurn1, "where are we on the Q4 reqs?",
    "Three of five roles have candidates in final round. The platform-eng req is still thin — I've asked the recruiter for a wider pass.",
    now() - 1000 * 60 * 60 * 5, 18360);
  seedTurn("partner", partnerTurn1, "how did the partner book review land?",
    "Two partners pushed back on the carry split. I have the numbers but I stopped short of a recommendation — I want your read on the Hensley relationship first.",
    now() - 1000 * 60 * 60 * 9, 0);
  // A turn that ended without finishing and never wrote an end time: `active_ms` is None
  // FOREVER for it (ledger.rs), so the row must claim no number.
  {
    const p = turnsById.get(partnerTurn1);
    p.state = "interrupted";
    p.endedAt = null;
  }
  // Real semantic activity on the Acme turn, so §5.3's rollup and §6.4's collapse have
  // something to act on. Ids are machinery ids, as `activity_item` derives them.
  turnsById.get(acmeTurn1).activities = [
    { kind: "activity", id: "mach_a1", slot: "stream", sequence: 1, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1000,
      activityType: "read", state: "completed", summary: "Read a file" },
    { kind: "activity", id: "mach_a2", slot: "stream", sequence: 2, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1100,
      activityType: "read", state: "completed", summary: "Read a file" },
    { kind: "activity", id: "mach_a3", slot: "stream", sequence: 3, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1200,
      activityType: "read", state: "completed", summary: "Read a file" },
    { kind: "activity", id: "mach_a4", slot: "stream", sequence: 4, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1400,
      activityType: "command", state: "unknown", summary: "Ran a command" },
    { kind: "activity", id: "mach_a5", slot: "stream", sequence: 5, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1600,
      activityType: "search", state: "completed", summary: "Searched" },
  ];

  // THREE DELEGATED WORKERS on the Q4-hiring turn (UX §7.1, §26's multi-agent fixture).
  // The payload shape is `TimelineItem::WorkerActivity` verbatim: `kind: "worker_activity"`,
  // a flattened base, and a camelCase `worker` object.
  //
  // The three states are the three the ENGINE CAN ACTUALLY WITNESS, one each — `created`,
  // `started`, `run_ended` (`richos_core::worker_events::ObservedWorkerState`). There is
  // deliberately no `completed`, `failed`, `interrupted` or `waiting` worker in this
  // fixture, because none of those can occur: `WorkerState::from_observed` cannot produce
  // them and a mock that showed one would be teaching the design a state the product does
  // not have.
  turnsById.get(hiringTurn1).activities = [
    { kind: "worker_activity", id: "mach_w1", slot: "stream", sequence: 1, visibility: "ceo",
      entityId: "femcboost", threadId: "hiring", createdAt: now() - 1000 * 60 * 60 * 5 + 900,
      detailRef: "mach_w1",
      worker: { agentId: "agt_sage_1", workerName: "Sage", agentType: "architecture",
                observedState: "created", state: "pending_init", eventsObserved: 1,
                firstObservedAt: "2026-08-29T04:00:00+00:00", lastObservedAt: "2026-08-29T04:00:00+00:00" } },
    { kind: "worker_activity", id: "mach_w2", slot: "stream", sequence: 2, visibility: "ceo",
      entityId: "femcboost", threadId: "hiring", createdAt: now() - 1000 * 60 * 60 * 5 + 1000,
      detailRef: "mach_w2",
      worker: { agentId: "agt_frank_1", workerName: "Frank", agentType: "red team",
                observedState: "started", state: "running", eventsObserved: 2,
                firstObservedAt: "2026-08-29T04:00:01+00:00", lastObservedAt: "2026-08-29T04:01:44+00:00" } },
    { kind: "worker_activity", id: "mach_w3", slot: "stream", sequence: 3, visibility: "ceo",
      entityId: "femcboost", threadId: "hiring", createdAt: now() - 1000 * 60 * 60 * 5 + 1100,
      detailRef: "mach_w3",
      worker: { agentId: "agt_clark_1", workerName: "Clark", agentType: "research",
                observedState: "run_ended", state: "unknown", eventsObserved: 5,
                latestUpdate: "Pulled the platform-eng comparables from three sources",
                firstObservedAt: "2026-08-29T04:00:02+00:00", lastObservedAt: "2026-08-29T04:07:31+00:00" } },
  ];

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

  /// The fence every §13 payload carries. `bindingRevision` is the ACTIVATION revision —
  /// it advances on thread activation and is legitimately HIGHER than what a re-projection
  /// of the same thread reports, which is exactly why a renderer must treat it as a
  /// staleness floor and never as an equality key.
  function fenceOf(threadId, turnId) {
    const t = threads.find((x) => x.id === threadId);
    return { entityId: t ? t.entity_id : null, threadId, turnId, bindingRevision: t && t.entity_id ? 1 : 0 };
  }

  /// Both families for one turn: the four ORIGINAL events verbatim (byte-for-byte
  /// unchanged — a consumer of only those keeps working), and the six additive §13 events.
  ///
  /// `opts.crashAt` drives the mid-turn-crash replay: after that many deltas the turn emits
  /// `recovering`, and a REPLACEMENT turn's `queued` carries `supersedesTurnId`. The
  /// replacement re-streams from the beginning, exactly as a replay does — which is why a
  /// renderer that ignores the merge instruction draws the CEO's one prompt twice.
  function simulateTurn(threadId, userText, opts) {
    opts = opts || {};
    const turnId = uid("turn");
    const userAt = now();
    messagesByThread[threadId] = messagesByThread[threadId] || [];
    messagesByThread[threadId].push({ role: "user", text: userText, turn_id: turnId, at: userAt });
    turnsById.set(turnId, {
      threadId,
      entityId: (threads.find((x) => x.id === threadId) || {}).entity_id,
      userText,
      runs: [],
      state: "queued",
      createdAt: userAt,
      startedAt: null,
      endedAt: null,
      activities: [],
    });

    const fence = fenceOf(threadId, turnId);
    if (opts.supersedes && turnsById.has(opts.supersedes)) {
      // `Turn::superseded_by` — set on the CRASHED turn by the ledger before the replay is
      // journaled. It is what makes the crashed turn unrenderable, forever.
      turnsById.get(opts.supersedes).supersededBy = turnId;
    }
    emit("rich://turn-status", Object.assign({}, fence, {
      status: "queued", startedAt: null, activeDurationMs: null, visibility: "ceo", at: now(),
      supersedesTurnId: opts.supersedes,
    }));

    const startedAt = now();
    turnsById.get(turnId).startedAt = startedAt;
    turnsById.get(turnId).state = "working";
    emit("rich://turn-started", { threadId, turnId, at: startedAt });
    emit("rich://turn-status", Object.assign({}, fence, {
      status: "working", startedAt, activeDurationMs: null, visibility: "ceo", at: startedAt,
    }));

    const reply = opts.reply || CANNED_REPLIES[Math.floor(Math.random() * CANNED_REPLIES.length)];
    const words = reply.split(" ");
    const messageId = turnId + ":text:0";
    let seq = 0;
    let acc = "";
    let i = 0;
    let opened = false;
    let activityFired = false;

    function next() {
      if (opts.crashAt && i === opts.crashAt) {
        // A POSITIVE termination signal, mid-turn. The crashed turn emits `recovering` and
        // is about to be superseded — never `failed`, and a reload will not render it at all.
        turnsById.get(turnId).state = "interrupted";
        emit("rich://turn-status", Object.assign({}, fence, {
          status: "recovering", startedAt, activeDurationMs: null, visibility: "ceo", at: now(),
        }));
        setTimeout(function () {
          simulateTurn(threadId, userText, { supersedes: turnId, reply: opts.reply });
        }, 400);
        return;
      }
      if (i >= words.length) {
        const endedAt = now();
        const text = acc.trim();
        messagesByThread[threadId].push({ role: "assistant", text, turn_id: turnId, at: endedAt });
        const turn = turnsById.get(turnId);
        turn.runs = [{ text, startSeq: 0, at: startedAt }];
        turn.state = "completed";
        turn.endedAt = endedAt;
        emit("rich://message-completed", Object.assign({}, fence, {
          messageId, phase: "unknown", text, visibility: "ceo", at: endedAt,
        }));
        emit("rich://turn-completed", { threadId, turnId, stopReason: "end_turn", at: endedAt });
        emit("rich://turn-status", Object.assign({}, fence, {
          status: "completed", startedAt, activeDurationMs: endedAt - startedAt, visibility: "ceo", at: endedAt,
        }));
        emit("rich://thread-summary-updated", Object.assign({}, fence, {
          title: (threads.find((x) => x.id === threadId) || {}).title || "",
          messageCount: messagesByThread[threadId].length,
          lastActivity: endedAt, status: "idle", visibility: "ceo", at: endedAt,
        }));
        return;
      }
      if (!opened) {
        opened = true;
        emit("rich://message-started", Object.assign({}, fence, {
          messageId, phase: "unknown", seq: 0, visibility: "ceo", at: now(),
        }));
      }
      const delta = (i === 0 ? "" : " ") + words[i];
      acc += delta;
      emit("rich://chunk", { threadId, turnId, seq, textDelta: delta, at: now() });
      emit("rich://message-delta", Object.assign({}, fence, {
        messageId, seq, textDelta: delta, visibility: "ceo", at: now(),
      }));
      seq += 1;
      i += 1;
      // One real semantic activity row partway through, so the live activity lane and the
      // §6.4 collapse are exercised rather than only the reload path.
      if (!activityFired && i === Math.ceil(words.length / 2)) {
        activityFired = true;
        const act = {
          kind: "activity", id: "mach_" + turnId, entityId: fence.entityId, threadId,
          turnId, bindingRevision: fence.bindingRevision, createdAt: now(),
          sequence: seq, slot: "stream", visibility: "ceo",
          activityType: "command", state: "running", summary: "Ran a command",
        };
        turnsById.get(turnId).activities = [act];
        emit("rich://activity-upserted", Object.assign({}, act, { at: now() }));
        seq += 1;
        // The SAME row again as it reaches a terminal state — one tool call is ONE row that
        // arrives several times. A renderer that keyed on anything but `id` shows two.
        setTimeout(function () {
          const done = Object.assign({}, act, { state: "completed", completedAt: now(), updatedAt: now() });
          turnsById.get(turnId).activities = [done];
          emit("rich://activity-upserted", Object.assign({}, done, { at: now() }));
        }, 300);
      }
      setTimeout(next, 60 + Math.random() * 90);
    }
    // Small "thinking" delay before the first chunk so the `Working` state is visibly
    // exercised — including §6.1's under-one-second row, which has no number yet.
    setTimeout(next, 900 + Math.random() * 400);
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
        case "get_timeline": {
          const id = args.threadId ?? args.thread_id;
          const t = threads.find((x) => x.id === id);
          // Fails closed on an unbound thread exactly like the real command.
          if (t && !t.entity_id) return Promise.reject(UNBOUND_ERR(id));
          return projectTimeline(id);
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
        // Same clamp bounds as nav.rs's `clamp_inspector_width`, and it returns the width
        // the store ACCEPTED — so the harness cannot drift from the real contract.
        case "set_inspector_width":
          navPrefs.inspector_width = Math.max(280, Math.min(520, Number(args.width) || 336));
          return navPrefs.inspector_width;
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
    /// A turn with a REPLY LONG ENOUGH TO WATCH. The canned replies stream in about two
    /// seconds, which is shorter than the §25 working-state checks need — this exists so
    /// "updates once per second" and "survives navigation" can be observed against a live
    /// turn rather than asserted about one that already finished.
    simulateSlowTurn(threadId, text, words) {
      const n = words || 90;
      const reply = Array.from({ length: n }, function (_, i) {
        return ["pulling", "the", "comparables", "now", "and", "checking", "each", "line"][i % 8];
      }).join(" ");
      simulateTurn(threadId || activeThreadId, text || "run the numbers", { reply: reply });
    },
    /// A MID-TURN CRASH and its automatic replay. The crashed turn emits `recovering`; the
    /// replacement's `queued` carries `supersedesTurnId`. THE PROOF: the CEO's one prompt
    /// must appear exactly ONCE when this finishes.
    simulateMidTurnCrash(threadId, text) {
      simulateTurn(threadId || activeThreadId, text || "check the Acme numbers again", {
        crashAt: 3,
        reply: "Picked it straight back up — the comparables hold and the counter stands.",
      });
    },
    setNotConnected(v) {
      window.__RICHOS_MOCK__._notConnected = v;
    },
    _notConnected: false,
  };
})();
