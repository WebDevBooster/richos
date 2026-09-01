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

  // §15 appearance state, and the person. `theme` starts DARK because that is the ruling's
  // default for a fresh install, and `user_name` starts NULL because "nobody has said who
  // this is" is the state the product actually ships in.
  //
  // IT IS DURABLE, because the thing it stands in for is. `config.rs` survives a relaunch,
  // so a harness whose "stored preference" evaporated on reload would model the one
  // property these settings exist to have — and would make the whole reconciliation path
  // (`get_appearance` -> `RichTheme.sync`, backend wins) untestable in a browser, since the
  // backend would answer with the shipped default every single time. One key, its own
  // namespace, and never the mirror's keys: this is the STORE, not the cache of it.
  const MOCK_CONFIG_KEY = "richos-mock-config";
  const mockConfig = (function () {
    const fresh = { theme: "dark", font_scale: 100, user_name: null };
    try {
      const raw = window.localStorage.getItem(MOCK_CONFIG_KEY);
      if (!raw) return fresh;
      const parsed = JSON.parse(raw);
      return {
        theme: ["dark", "light", "system"].includes(parsed.theme) ? parsed.theme : fresh.theme,
        font_scale: Number.isFinite(parsed.font_scale) ? parsed.font_scale : fresh.font_scale,
        user_name: typeof parsed.user_name === "string" && parsed.user_name.trim() ? parsed.user_name : null,
      };
    } catch (e) {
      // A corrupt or unavailable store degrades to the shipped defaults rather than
      // failing the harness — the same posture `ConfigStore::open` takes.
      return fresh;
    }
  })();
  const persistMockConfig = () => {
    try {
      window.localStorage.setItem(MOCK_CONFIG_KEY, JSON.stringify(mockConfig));
    } catch (e) {
      /* storage unavailable; the in-memory value still serves this session */
    }
  };
  // `initials_from` in config.rs, mirrored: first and last, two letters at most, one
  // letter for one token, and null rather than a guess when there is nothing to derive.
  const mockInitials = (name) => {
    if (!name) return null;
    const t = String(name).split(/\s+/).filter(Boolean);
    if (!t.length) return null;
    const first = [...t[0]][0].toUpperCase();
    if (t.length === 1) return first;
    return first + [...t[t.length - 1]][0].toUpperCase();
  };
  const uid = (p) => `${p}_${Math.random().toString(36).slice(2, 10)}`;

  // --- fixture state -------------------------------------------------------
  // The four dogfood entity areas, mirroring `EntityRegistry::dogfood()` (entity.rs) —
  // same ids, same display names, same roots — so the rail's grouping is exercised against
  // the real registry's shape rather than an invented one.
  // THE CEO'S OWN SIX, mirroring `EntityRegistry::ceos_companies()` in richos-core's
  // entity.rs:227-238 — id, display name and roots, in registry order. It was four here and
  // six there; `gpt-exporter` and `webinar-booster` were added to the registry and this
  // harness was not updated, which is drift of the exact kind a mock exists to avoid.
  //
  // `richos` HAS TWO ROOTS AND IS ONE ENTITY. That is the property the home screen's company
  // row would get wrong if anything ever built its list from directories instead of from the
  // registry, so the harness carries it rather than flattening it.
  const entities = [
    { id: "femcboost", display_name: "FemcBoost", status: "active", roots: ["/Users/alex/ab/femcboost"] },
    { id: "deeply", display_name: "Deeply", status: "active", roots: ["/Users/alex/ab/deeply"] },
    { id: "prospects", display_name: "Prospects", status: "active", roots: ["/Users/alex/ab/prospects"] },
    { id: "richos", display_name: "RichOS", status: "active", roots: ["/Users/alex/ab/richos", "/Users/alex/ab/richos-hq"] },
    { id: "gpt-exporter", display_name: "GPT Exporter", status: "active", roots: ["/Users/alex/ab/gpt-exporter"] },
    { id: "webinar-booster", display_name: "Webinar Booster", status: "active", roots: ["/Users/alex/ab/webinar-booster"] },
  ];

  // THE HOME SCREEN'S COMPANY BUTTONS (CEO, 2026-09-01) — his two preferences, mirroring
  // `home_entity_labels` and `home_entity_hidden` in config.rs. Durable there; in-memory here,
  // which is enough: every test that needs them drives both ends in one page.
  //
  // Both start EMPTY, because that is the state every install is in until he opens the panel:
  // no label overrides, nothing hidden. `homeEntityRowOf` resolves them the way the Rust
  // command does — an absent label means the registry's display name, an absent hidden flag
  // means visible — so a surface can never be tested against a resolution the app does not do.
  const homeEntityLabels = {};
  const homeEntityHidden = {};

  function homeEntityRowOf() {
    return entities.map((e) => {
      const custom = typeof homeEntityLabels[e.id] === "string" && homeEntityLabels[e.id].trim()
        ? homeEntityLabels[e.id].trim()
        : null;
      return {
        id: e.id,
        display_name: e.display_name,
        label: custom || e.display_name,
        custom_label: custom,
        visible: homeEntityHidden[e.id] !== true,
      };
    });
  }

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
    // §10.1's thread, EMPTY until the §26 fixture is driven. It exists at load so the
    // scenario starts from "before send" (§10.1) rather than conjuring a thread as its
    // first act — the CEO's first observable moment is his own message landing in a thread
    // that was already there.
    { id: "memory", title: "Design RichOS memory strategy", entity_id: "femcboost", created_at: now() - 1000 * 60 * 5, message_count: 0, last_activity: now() - 1000 * 60 * 5, last_turn_state: null, has_pending_turn: false },
  ];
  // A PRE-BOOT SWITCH, and the only one in this file. The launch state it drives — no
  // company chosen, so the app asks — is decided BEFORE `main.js` runs its `init()`, so a
  // setter called afterwards cannot reach it: by then the shell has already branched on
  // whether a thread was active. The browser harness sets this with `addInitScript`, which
  // runs before any of the page's own scripts.
  //
  //   window.__RICHOS_MOCK_PRESET__ = { chosenEntity: null }          // never answered
  //   window.__RICHOS_MOCK_PRESET__ = { pinnedByEnvironment: true }   // RICHOS_ENTITY set
  //   window.__RICHOS_MOCK_PRESET__ = { memory: "none" }              // fresh install, no corpus
  //   window.__RICHOS_MOCK_PRESET__ = { memory: "no-compiler" }       // a corpus it cannot read
  const preset = (typeof window !== "undefined" && window.__RICHOS_MOCK_PRESET__) || {};
  let activeThreadId = "chosenEntity" in preset && !preset.chosenEntity ? null : "general";

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
    memory: [], // §26's fixture thread — filled only when the scenario is driven.
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
  function projectTimeline(threadId, mode) {
    const technical = mode === "technical" || mode === "technical-empty";
    // `technical-empty` is the TECHNICAL view of a thread whose journal gave nothing back —
    // unreadable, or never written. The mode on the wire is still `technical`; what is
    // absent is the rows, exactly as `Spine::timeline` produces them from an empty read.
    const noMachinery = mode === "technical-empty";
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
        // `Timeline::view` REMOVES the technical half from a CEO view rather than masking
        // it, and drops `Visibility::Technical` items outright. Reproduced here — a mock
        // that merely hid them would let a renderer bug through that the real backend makes
        // structurally impossible.
        if (noMachinery) continue;
        if (!technical && a.visibility === "technical") continue;
        const item = Object.assign({}, a, { turnId, bindingRevision: rev });
        if (!technical) delete item.detail;
        items.push(item);
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
    return {
      entityId: t ? t.entity_id : null,
      threadId,
      mode: technical ? "technical" : "ceo",
      items,
      // §1.5's lane travels inside the gated view, beside the items — never as a second
      // command. `technical-empty` (an unreadable or never-written store) gives nothing
      // back here for the same reason it gives no activity rows: the journal answered with
      // nothing, and this is a projection of the journal.
      betweenTurns: noMachinery ? [] : betweenTurnsFor(threadId, technical ? "technical" : "ceo"),
    };
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
  //
  // EVERY ROW ALSO CARRIES ITS `detail`, which is what `ViewMode::Technical` keeps and
  // `ViewMode::Ceo` REMOVES — `projectTimeline` strips it for the calm view, exactly as
  // `TimelineItem::redacted` does. The titles, summaries and paths below are the shapes the
  // 2026-08-28 emission probe actually recorded and the `machinery-payload.json` fixture
  // holds: a MERGED title that is the real command (never the opening event's placeholder
  // "Terminal"), an 84-char bounded summary, and `locations` from `[{path}]`.
  turnsById.get(acmeTurn1).activities = [
    { kind: "activity", id: "mach_a1", slot: "stream", sequence: 1, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1000,
      activityType: "read", state: "completed", summary: "Read a file", detailRef: "mach_a1",
      detail: { title: "Read comparables/q3-acme.csv", summary: "18 rows, 4 columns",
                locations: ["/Users/alex/ab/acme/comparables/q3-acme.csv"] } },
    { kind: "activity", id: "mach_a2", slot: "stream", sequence: 2, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1100,
      activityType: "read", state: "completed", summary: "Read a file", detailRef: "mach_a2",
      detail: { title: "Read comparables/q3-market.csv", summary: "31 rows, 4 columns",
                locations: ["/Users/alex/ab/acme/comparables/q3-market.csv"] } },
    { kind: "activity", id: "mach_a3", slot: "stream", sequence: 3, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1200,
      activityType: "read", state: "completed", summary: "Read a file", detailRef: "mach_a3",
      detail: { title: "Read notes/hensley-relationship.md", summary: "9 lines",
                locations: ["/Users/alex/ab/acme/notes/hensley-relationship.md"] } },
    // NO STATUS EVER ARRIVED for this one — 34 of the 58 measured tool events carried none.
    // It must read "outcome not recorded" and must NEVER be folded into done.
    { kind: "activity", id: "mach_a4", slot: "stream", sequence: 4, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1400,
      activityType: "command", state: "unknown", summary: "Ran a command", detailRef: "mach_a4",
      detail: { title: "python3 scripts/counter-model.py --list 4200000 --offer 3864000",
                summary: "spread 8.0% \u00b7 within comparable range", locations: [] } },
    { kind: "activity", id: "mach_a5", slot: "stream", sequence: 5, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1600,
      activityType: "search", state: "completed", summary: "Searched", detailRef: "mach_a5",
      detail: { title: "grep -rn \"carry split\" notes/", summary: "4 matches", locations: [] } },
    // A FAILED call. The status dot's other terminal value, and the row the CEO most wants
    // to be able to see the output of.
    { kind: "activity", id: "mach_a6", slot: "stream", sequence: 6, visibility: "ceo",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1700,
      activityType: "command", state: "failed", summary: "Ran a command", detailRef: "mach_a6",
      detail: { title: "cat comparables/q4-acme.csv", summary: "Exit code 1", locations: [] } },
    // TECHNICAL-ONLY, and therefore ABSENT from the calm view entirely: an untyped vendor
    // frame. `stream_event:message_delta` carries the token accounting the rotation
    // watermark reads, and it is not something Rich DID, so it renders as one dim line here
    // and as nothing at all in the conversation. Slice 3 fixed a live 6:1 noise defect by
    // moving exactly this row out of the CEO view.
    { kind: "activity", id: "mach_a7", slot: "stream", sequence: 7, visibility: "technical",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1800,
      activityType: "other", state: "unknown", summary: "Worked", detailRef: "mach_a7",
      detail: { title: "stream_event:message_delta", locations: [],
                vendorKind: "stream_event:message_delta" } },
    // A PERMISSION REQUEST, also technical-only. Auto-approved by the client and
    // recorded as a FACT — never a decision awaiting the CEO. It rendered as a CEO row
    // reading "Requested approval 7 times" until 2026-08-29, which manufactured demand for
    // an approval queue that does not exist.
    { kind: "activity", id: "mach_a8", slot: "stream", sequence: 8, visibility: "technical",
      entityId: "femcboost", threadId: "acme", createdAt: now() - 1000 * 60 * 60 * 20 + 1850,
      activityType: "approval", state: "completed", summary: "Requested approval", detailRef: "mach_a8",
      detail: { title: "python3 scripts/counter-model.py", summary: "auto-approved: allow", locations: [] } },
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

  // WHICH COMPANY THIS COPY OF RICH WORKS FOR (`entity_choice` / `choose_entity`).
  //
  // The preview's default is CHOSEN, and deliberately so: every fixture in this harness
  // starts with a rail full of threads that already have a company, which is what a machine
  // that has been answered once looks like. `setCompanyChosen(null)` drives the launch
  // state — the one a double-clicked bundle is always in until the CEO answers — so the
  // picker, the composer block and its control can be exercised without a real Finder
  // launch, and `setCompanyPinnedByEnvironment` drives the operator's variant where the
  // answer came from outside the window and there is nothing here to press.
  let chosenEntityId = "chosenEntity" in preset ? preset.chosenEntity : "richos";
  let chosenEntitySource = chosenEntityId
    ? preset.pinnedByEnvironment
      ? "environment"
      : "saved-choice"
    : null;
  let entityPinnedByEnvironment = preset.pinnedByEnvironment === true;

  // WHERE HIS MEMORY IS. `ready` by default for the reason the company answer is CHOSEN by
  // default: every other fixture in this harness is a machine that has been set up once.
  // `memory: "none"` is the fresh install — no corpus anywhere, which is the state the
  // installed bundle was measurably in the moment its hand-made pointer was removed.
  let memoryState = preset.memory || "ready";
  let memoryRoot = memoryState === "none" ? null : "/Users/alex/RichOS/corpus";
  // Whether provisioning here ends `ready` or `no-compiler`. False drives the honest
  // degrade: a corpus is created and the program that reads it is not installed.
  const memoryCompilerPresent = preset.memoryCompiler !== false;

  function memoryStatusOf() {
    return {
      state: memoryState,
      root: memoryRoot,
      source: memoryState === "ready" ? "~/RichOS/corpus" : null,
      compiler: memoryState === "ready" ? "/Users/alex/Library/Application Support/RichOS/loro-tools" : null,
      tried: [],
      detail: null,
      // The location the CEO is OFFERED, pre-filled — the whole reason his part is a click
      // and not a path. It comes from the backend in the real app and from here in the
      // preview, and it is the same string in both.
      offered_location: "/Users/alex/RichOS/corpus",
      provisioned_now: false,
    };
  }

  function entityChoiceOf() {
    return {
      chosen: chosenEntityId,
      source: chosenEntityId ? chosenEntitySource : null,
      pinnedByEnvironment: entityPinnedByEnvironment,
      options: entities.map((e) => ({
        id: e.id,
        display_name: e.display_name,
        roots: e.roots || [],
        thread_count: threads.filter((t) => t.entity_id === e.id).length,
      })),
      active: activeContextOf(),
    };
  }

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

  // =======================================================================================
  // THE TWO CORRECTION DESKS (§7 "ask, never infer") — `correction.rs` and `staging.rs`
  // =======================================================================================
  //
  // Fourteen Tauri commands, mocked with the SAME state machine the Rust desks enforce,
  // because a preview harness that let `confirm` succeed twice, or let a proposal be
  // confirmed while suppressed, would rehearse a product that does not exist.
  //
  //   * `confirm` is the only path to a write, and refuses anything not awaiting an answer
  //     (`correction.rs:541`) — a double click must not write twice.
  //   * a decline is NOT permanent and the item stays re-askable (§7).
  //   * a permanent decline suppresses by REF/KEY, on a list that reads back and lifts.
  //   * `propose` refuses an empty `why` before anything is started, and refuses a
  //     suppressed target.
  //
  // THE TWO "NOT HERE" SENTENCES ARE COPIED VERBATIM from `app/src-tauri/src/main.rs`
  // (`desk()` and `spoken_desk()`), the way `_notConnected` copies
  // `LEASE_UNAVAILABLE_MESSAGE`. `corrections.js` asserts each is byte-identical to the
  // Rust const, so this preview can never rehearse a sentence the product no longer says.
  const LORO_DESK_ABSENT =
    "This install has no company memory it can write to, so there is nothing to read " +
    "or correct here. That is a statement about this install, not about what is recorded.";
  const SPOKEN_DESK_ABSENT =
    "I can't record corrections right now — my correction log could not be opened. " +
    "Nothing you say is being lost from the conversation itself.";

  // Written the way `loro-write --dry-run --json` writes it: front matter plus body, byte
  // for byte, because that IS what the CEO approves (`correction.rs:366-369`).
  const LORO_RECORD_NOW =
    "---\nid: decision-ship-thursday\nkind: decision\nscope: ceo-private\n---\n\n" +
    "We ship on Thursday.\n";
  const LORO_PREVIEW =
    "---\nid: decision-ship-date\nkind: decision\nscope: ceo-private\nsupersedes: rec:ceo/records/decision-ship-thursday\n---\n\n" +
    "No ship date is decided. Thursday was floated and never agreed.\n";

  let loroDeskOn = true;
  let spokenDeskOn = true;
  // A desk that IS there and refuses to answer — the transient half, which the surface
  // must render differently from "not installed" because only one of them has a retry.
  let loroReadFailure = null;
  let spokenReadFailure = null;

  let proposalSeq = 2;
  const proposals = [
    {
      id: "prop-1",
      at: now() - 1000 * 60 * 12,
      entity_id: "femcboost",
      thread_id: "acme",
      write: {
        op: "supersede",
        recordRef: "rec:ceo/records/decision-ship-thursday",
        newId: "decision-ship-date",
        kind: "decision",
        scope: "ceo-private",
        body: "No ship date is decided. Thursday was floated and never agreed.",
      },
      why: "we never decided Thursday, that was Sara thinking out loud",
      preview: LORO_PREVIEW,
      state: "awaiting-ceo",
      outcome: null,
      failure: null,
    },
  ];
  const loroSuppressed = [];

  const candidates = [
    {
      key: "deep gram|Deepgram",
      at: now() - 1000 * 60 * 4,
      threadId: "acme",
      turnId: "turn_mock_spoken",
      utterance: "it's Deepgram, not deep gram",
      ask: {
        from: "deep gram",
        to: "Deepgram",
        key: "deep gram|Deepgram",
        frame: "pivot-first",
        orthographic: 0.89,
        phonetic: 1,
        leg: "both",
        anchor: "I'll get deep gram to transcribe the call",
      },
      declinedBefore: 0,
      // Verbatim from `staging.rs`'s `prompt_for` — the sentence §7 asks for, built in one
      // place so every surface asks it the same way.
      prompt: 'Add "Deepgram" to your vocabulary?',
    },
  ];
  const spokenSuppressed = [];
  /// How many times each pair has been plainly declined. §7: the next ask must say so,
  /// "or it reads as the system having forgotten".
  const declinedCounts = {};


  // ---- the feedback channel (`feedback.rs`) ---------------------------------------------
  //
  // A REAL STATE MACHINE, not a table of answers — the same standard the two correction
  // desks are held to here, and for the same reason. `feedback.rs` refuses a report on a
  // `3`, refuses one with no diagnosis term, refuses one whose rating disagrees with the
  // rating given, sorts and de-duplicates a selection so the same terms always render the
  // same bytes, and refuses an approval whose text is not what this build would say. A
  // harness that answered `{}` to every command would let a browser suite pass over a
  // surface that records consent for text nobody was shown.
  //
  // EVERY STRING BELOW IS A COPY, AND `feedback.js` CHECKS EACH ONE against
  // `tests/fixtures/feedback-vocabulary.json`, which a cargo test regenerates from the live
  // Rust constants on every run. A preview harness that rehearses wording the product no
  // longer uses is a fixture certifying the fixture.

  /// Verbatim from `FEEDBACK_STORE_UNAVAILABLE`, app/src-tauri/src/main.rs.
  const FEEDBACK_STORE_ABSENT =
    "I can't keep an answer right now — the file I record them in wouldn't open, and I'm not going to ask you what you think and then lose it. That one is for whoever set RichOS up to look at; it isn't yours to fix.";
  /// Verbatim from `FEEDBACK_PREVIEW_MISMATCH`, app/src-tauri/src/main.rs.
  const FEEDBACK_PREVIEW_MISMATCH =
    "I won't record that. What you were shown isn't what I would say now, so approving it would be approving something you haven't read. Ask me to show it again.";

  /// `PROMPT_QUESTION`, `PROMPT_OPTIONS`, `REPORT_OFFER`, `DISCLOSURE_HEADING`.
  const FEEDBACK_QUESTION = "How is RichOS doing this session?";
  const FEEDBACK_OPTIONS = "1: Bad | 2: OK, but could be better | 3: Good | 0: Dismiss";
  const FEEDBACK_REPORT_OFFER =
    "Will you let your Rich tell the RichOS developers — fully anonymized and generically — what annoyed you and why it happened?";
  const FEEDBACK_DISCLOSURE_HEADING =
    "This is exactly what your Rich would report. In this version it is written to this machine and nowhere else; nothing in RichOS can carry it any further.";

  /// `Rating` — three variants, and `0` deliberately not one of them.
  const FEEDBACK_RATINGS = [
    { key: "1", label: "Bad", wire: "bad", invitesReport: true },
    { key: "2", label: "OK, but could be better", wire: "ok-but-could-be-better", invitesReport: true },
    { key: "3", label: "Good", wire: "good", invitesReport: false },
  ];

  /// The vocabulary, in DECLARATION ORDER — which is also the order `assemble` sorts a
  /// selection into, so the index in these arrays is the sort key.
  const FEEDBACK_FAILURE_CLASS = [
    { wire: "unprepared-task-handed-to-user", label: "The assistant handed the user a task it had not prepared." },
    { wire: "checking-handed-to-user", label: "The assistant left the user to notice a failure that machinery should have caught." },
    { wire: "assurance-handed-to-user", label: "The assistant left the user to ask whether a class of failure would recur." },
    { wire: "decision-handed-to-user", label: "The assistant asked the user a question whose answer was already determined." },
    { wire: "scheduling-handed-to-user", label: "The assistant left the user to sequence work it should have sequenced itself." },
  ];
  const FEEDBACK_OCCURRENCES = [
    { wire: "1", label: "once" },
    { wire: "2", label: "twice" },
    { wire: "3", label: "three times" },
    { wire: "4", label: "four times" },
    { wire: "5", label: "five times" },
    { wire: "more-than-5", label: "more than five times" },
  ];
  const FEEDBACK_DIAGNOSIS = [
    {
      wire: "request-repeated-without-preparation",
      sentence:
        "The assistant asked the user to carry out a manual verification task more than once in a single session without preparing the artifact the task required.",
    },
    { wire: "no-input-artifact-named", sentence: "No input file was named." },
    { wire: "no-location-within-input-specified", sentence: "No locations within it were specified." },
    { wire: "no-method-given", sentence: "No method was given." },
    { wire: "no-acceptance-criterion-stated", sentence: "No acceptance criterion was stated." },
    {
      wire: "automated-executors-received-self-contained-briefs",
      sentence:
        "In the same session the assistant produced detailed, self-contained briefs for its automated sub-agents.",
    },
    {
      wire: "human-executor-received-the-least-prepared-instruction",
      sentence: "The asymmetry is the defect: the human executor received the least prepared instruction.",
    },
  ];
  const FEEDBACK_CONDITIONS = [
    {
      wire: "record-section-for-items-awaiting-the-user",
      sentence:
        "The durable task record contained a section for items awaiting the user, which made relaying an item feel equivalent to preparing it.",
    },
    {
      wire: "no-user-facing-item-carried-an-acceptance-criterion",
      sentence: "No user-facing item carried an acceptance criterion.",
    },
    {
      wire: "rule-enforced-by-attention-rather-than-machinery",
      sentence: "The rule that would have prevented this was enforced by attention rather than by machinery.",
    },
  ];

  let feedbackStoreOpen = true;
  let feedbackReadFailure = null;
  /// The one file, as an array. Every entry is the shape `FeedbackEntry` serializes to.
  const feedbackEntries = [];

  /// `feedback.rs`'s `WRAP_COLUMNS`.
  const FEEDBACK_WRAP_COLUMNS = 76;

  /// `fold` — greedy word wrap into a two-space-indented folded block. Words are never
  /// split, so every token in the output is a token from the vocabulary.
  function feedbackFold(text) {
    let out = "";
    let line = "  ";
    for (const word of text.split(/\s+/).filter(Boolean)) {
      if (line.length > 2 && line.length + 1 + word.length > FEEDBACK_WRAP_COLUMNS) {
        out += line + "\n";
        line = "  ";
      }
      if (line.length > 2) line += " ";
      line += word;
    }
    if (line.length > 2) out += line + "\n";
    return out;
  }

  const feedbackTermIndex = (list, wire) => list.findIndex((t) => t.wire === wire);

  /// `FeedbackPayload::assemble` — sorted into vocabulary order and de-duplicated, so the
  /// same set of terms always produces the same payload and the same rendered text.
  function feedbackAssemble(rating, sel) {
    if (!rating.invitesReport)
      throw "rating '" + rating.key + "' does not invite a report — the offer is made on 1 and 2 only";
    const diagnosis = (sel.generic_diagnosis || []).slice();
    if (diagnosis.length === 0) throw "a report needs at least one diagnosis term";
    const order = (list) => (a, b) => feedbackTermIndex(list, a) - feedbackTermIndex(list, b);
    const uniq = (xs) => xs.filter((x, i) => xs.indexOf(x) === i);
    return {
      taxonomy_version: "v1",
      rating: rating.wire,
      failure_class: sel.failure_class,
      occurrences_this_session: sel.occurrences_this_session,
      generic_diagnosis: uniq(diagnosis.sort(order(FEEDBACK_DIAGNOSIS))),
      contributing_condition: uniq((sel.contributing_condition || []).slice().sort(order(FEEDBACK_CONDITIONS))),
    };
  }

  const feedbackSentence = (list, wire) => (list.find((t) => t.wire === wire) || {}).sentence;

  /// `render_disclosure` — deterministic and total, and the empty condition list is OMITTED
  /// rather than shown as a key with nothing under it.
  function feedbackRender(payload) {
    const ratingKey = (FEEDBACK_RATINGS.find((r) => r.wire === payload.rating) || {}).key;
    let out = "";
    out += "taxonomy_version: " + payload.taxonomy_version + "\n";
    out += "rating: " + ratingKey + "\n";
    out += "failure_class: " + payload.failure_class + "\n";
    out += "occurrences_this_session: " + payload.occurrences_this_session + "\n";
    out += "generic_diagnosis: >\n";
    out += feedbackFold(payload.generic_diagnosis.map((w) => feedbackSentence(FEEDBACK_DIAGNOSIS, w)).join(" "));
    if (payload.contributing_condition.length > 0) {
      out += "contributing_condition: >\n";
      out += feedbackFold(payload.contributing_condition.map((w) => feedbackSentence(FEEDBACK_CONDITIONS, w)).join(" "));
    }
    return out;
  }

  const feedbackFullText = (payload) => FEEDBACK_DISCLOSURE_HEADING + "\n\n" + feedbackRender(payload);

  /// `PromptOutcome::from_key` — anything that is not one of the four keys is not an answer
  /// at all, and is never silently recorded as a dismissal.
  function feedbackOutcome(key) {
    const rating = FEEDBACK_RATINGS.find((r) => r.key === key);
    if (rating) return { kind: "rated", value: rating.wire };
    if (key === "0") return { kind: "dismissed" };
    return null;
  }

  // ---- techy mode (techy-mode design §3.1) ---------------------------------------------
  //
  // The THREE sentences below are `machinery_view.rs`'s consts, verbatim. `techy.js` check 2
  // compares them to the Rust source, so a reworded sentence reaches this file through a
  // failing check rather than through a stale copy nobody looked at.
  const TECHY_NOTHING_RECORDED =
    "No machinery was recorded for this conversation. Retention started on 2026-08-28, and " +
    "anything Rich did before that was never written down — so this is a gap in the record, " +
    "not a quiet conversation.";
  const TECHY_NOT_RETAINED =
    "Nothing has been recorded on this machine yet. The technical view reads a store that " +
    "hasn't been written to — it fills up as Rich works.";
  const TECHY_UNREADABLE =
    "I can't read the technical record for this conversation. It's on this machine and I " +
    "haven't lost it — something is refusing to open it, and whoever set RichOS up needs to " +
    "look.";
  // §1.5's between-turn lane, when it is empty. Verbatim from `machinery_view.rs`'s
  // `BETWEEN_TURNS_QUIET`; `techy.js` check 2 compares them.
  const TECHY_BETWEEN_TURNS_QUIET =
    "Nothing was recorded between turns in this conversation. Rich started keeping this on " +
    "2026-08-30 — so in an older conversation that is a gap in the record, not proof the " +
    "session was quiet.";
  const TECHY_RAW_NOT_RETAINED =
    "The full output isn't kept this long — what's above is the whole record that was.";
  const TECHY_RAW_TRUNCATED = "This output was longer than RichOS keeps; you're seeing the start of it.";
  const TECHY_RAW_UNREADABLE =
    "I can't read the stored output for this one. It's on this machine and I haven't lost it " +
    "— whoever set RichOS up needs to look.";

  let techyDefault = false;
  const techyThreads = new Map(); // threadId -> bool  (ABSENT means "follows the default")

  // ---- §7.2: the raw-retention window, modelled rather than stubbed ---------------------
  //
  // The window is a SETTING (`config.rs`'s `raw_retention`, `journal.rs`'s `RawRetention`),
  // so the mock has to hold one — and it has to EVICT, because the sentence the surface says
  // after a change ("removed the stored output from N earlier days") is the whole reason the
  // control does not delete silently, and a mock that always returned 0 would let that
  // sentence rot untested.
  //
  // A stand-in journal: one raw day-shard per entry, of a known age and size. `evicted`
  // counts shards whose age is past the window, which is exactly what `evict_raw_within`
  // does with `unlink` — and NOTHING here touches the records, because Tier A is never
  // evicted at any setting.
  const RETENTION_WINDOWS = {
    "two-weeks": { ageDays: 14, totalBytes: 2147483648 },
    "three-months": { ageDays: 90, totalBytes: 2147483648 },
    forever: { ageDays: "forever", totalBytes: "forever" },
  };
  // STARTS AT `forever` DELIBERATELY, and this is the one place the mock is not a fresh
  // install. A fresh install is `two-weeks` (`config.rs`, proven there), and under a
  // two-week window a 120-day-old raw shard cannot exist — boot eviction removed it. So a
  // `two-weeks` mock holding an aged store would be a state the product cannot produce, and
  // the interesting state for a control that DELETES is the one where there is something to
  // delete: a CEO who opened the window up and later tightens it.
  let retentionChoice = "forever";
  let rawShards = [
    { ageDays: 120, bytes: 41_000_000 },
    { ageDays: 60, bytes: 12_500_000 },
    { ageDays: 20, bytes: 8_100_000 },
    { ageDays: 9, bytes: 3_300_000 },
    { ageDays: 0, bytes: 900_000 },
  ];
  /// The view the two commands return, in the shape `RetentionView` puts on the wire.
  function retentionView(evicted) {
    const w = RETENTION_WINDOWS[retentionChoice] || RETENTION_WINDOWS["two-weeks"];
    return {
      choice: retentionChoice,
      ageDays: w.ageDays,
      totalBytes: w.totalBytes,
      retainedBytes: rawShards.reduce((n, s) => n + s.bytes, 0),
      evicted: evicted || 0,
    };
  }
  /// Thread ids the OS would refuse to read. Not "empty" — a different state entirely.
  const machineryUnreadable = new Set();

  /// §2.4's Tier-B raw payloads, per machinery id. A row ABSENT from this map is one whose
  /// raw window has passed: the normalized record still renders and the pane says so.
  /// `mach_a5` is deliberately missing for exactly that reason, and `mach_a6` is over the
  /// 32 KB cap and comes back as a truncated PREFIX.
  const machineryRaw = new Map([
    ["mach_a1", { payload: { command: "cat comparables/q3-acme.csv", stdout: "list,offer,spread\n4200000,3864000,0.08\n" }, truncated: false }],
    ["mach_a2", { payload: { command: "cat comparables/q3-market.csv", stdout: "31 rows" }, truncated: false }],
    ["mach_a3", { payload: { command: "cat notes/hensley-relationship.md", stdout: "Hensley has carried the relationship since 2019." }, truncated: false }],
    ["mach_a4", { payload: { command: "python3 scripts/counter-model.py --list 4200000 --offer 3864000", stdout: "spread 8.0% · within comparable range" }, truncated: false }],
    ["mach_a6", { payload: "{\"command\":\"cat comparables/q4-acme.csv\",\"stderr\":\"cat: comparables/q4-acme.csv: No such file or directory", truncated: true }],
    ["mach_a7", { payload: { type: "stream_event", event: { type: "message_delta",
        usage: { input_tokens: 2, cache_read_input_tokens: 41991, cache_creation_input_tokens: 3603 } } },
      truncated: false }],
    ["mach_a8", { payload: { chosen: "allow", auto: true, options: ["allow", "reject"] }, truncated: false }],
  ]);

  /// §1.5's BETWEEN-TURN LANE, per thread — what the session said with no turn in flight.
  ///
  /// `acme` has traffic; `hiring` deliberately has none, so the honest empty state is a
  /// screen this harness can actually open rather than a branch nobody drives. The shape is
  /// `timeline::BetweenTurnItem` — note what is NOT here: `turnId` (these records have
  /// none, §1.4 G4) and `sessionId` (never on the wire, because a lane whose rows arrive at
  /// session boundaries is where a session id would become a rotation tell).
  const betweenTurnsByThread = new Map([
    [
      "acme",
      [
        {
          id: "mach_bt1",
          bindingRevision: 1,
          sequence: 0,
          at: now() - 1000 * 60 * 60 * 21,
          visibility: "technical",
          vendorKind: "system:init",
          detailRef: "mach_bt1",
          // NO `summary`, and that is the fixture speaking rather than a gap. A SessionMeta
          // frame has no typed route (`MachineryKind::Unknown`), so `from_native_event`
          // produces no bounded preview for it — the live fixture at
          // `fixtures/machinery-payload.json` has none either. One dim line carrying its
          // vendor frame name is exactly what §1.4 G5 asks for.
          detail: {
            title: "system:init",
            locations: [],
            vendorKind: "system:init",
          },
        },
        {
          id: "mach_bt2",
          bindingRevision: 1,
          sequence: 1,
          at: now() - 1000 * 60 * 29,
          visibility: "technical",
          vendorKind: "system:status",
          detailRef: "mach_bt2",
          detail: {
            title: "system:status",
            locations: [],
            vendorKind: "system:status",
          },
        },
      ],
    ],
  ]);

  /// The lane as `Timeline::view` hands it over: rows in TECHNICAL mode, nothing in CEO
  /// mode. Every row is `Visibility::Technical`, so the calm view is handed an empty lane
  /// by construction — reproduced here rather than filtered in the renderer, because that
  /// is where the real gate is.
  function betweenTurnsFor(threadId, mode) {
    if (mode !== "technical") return [];
    const t = threads.find((x) => x.id === threadId);
    const rows = betweenTurnsByThread.get(threadId) || [];
    return rows.map((r) => ({ ...r, entityId: t ? t.entity_id : null, threadId }));
  }

  function techyModeOf(threadId) {
    const pinned = techyThreads.has(threadId);
    return {
      enabled: pinned ? techyThreads.get(threadId) : techyDefault,
      source: pinned ? "thread" : "default",
      default: techyDefault,
    };
  }

  /// The FOUR states of `get_machinery`, kept apart exactly as `ThreadMachinery` keeps them.
  /// "There is nothing in it" and "I could not read it" are different answers and this mock
  /// refuses to collapse them, because collapsing them is the defect under test.
  function machineryStateOf(threadId) {
    if (machineryUnreadable.has(threadId)) {
      return { state: "unreadable", sentence: TECHY_UNREADABLE, reason: "machinery/" + threadId + ": Permission denied (os error 13)" };
    }
    const rows = [];
    for (const [, turn] of turnsById) {
      if (turn.threadId === threadId) for (const a of turn.activities) rows.push(a);
    }
    if (!rows.length) return { state: "nothing_recorded", sentence: TECHY_NOTHING_RECORDED, reason: null };
    return { state: "recorded", sentence: null, reason: null, rowCount: rows.length };
  }

  const loroGate = () => (loroDeskOn ? loroReadFailure : LORO_DESK_ABSENT);
  const spokenGate = () => (spokenDeskOn ? spokenReadFailure : SPOKEN_DESK_ABSENT);

  function refOf(write) {
    return write && (write.recordRef || write.record_ref) ? write.recordRef || write.record_ref : null;
  }

  // ---- the launch record, RECORDED and never reimplemented -----------------------------
  //
  // The shell's two launch commands are answered here so the browser suite can prove the
  // whole path — the id that was drawn reaching the recency ring, and the LOCAL offset
  // reaching the buckets. What this deliberately does NOT do is bucket anything: a second
  // implementation of "today / this week / this month" living in the mock is a second thing
  // that can disagree with `launch.rs`, and the arithmetic is already proven there over all
  // 292,194 days from 1600 to 2400. So the mock records the calls and returns a fixed
  // record; the numbers are Rust's job.
  const launchCalls = { splashShown: [], stateReads: [] };
  const LAUNCH_STATE = {
    kind: "fresh",
    counts: { today: 1, thisWeek: 3, thisMonth: 12, thisYear: 47, total: 47 },
    installedAt: 1788166800000,
    recentSplashes: [],
    readable: true,
    schemaVersion: 1,
  };

  // ---- the update path (RICH-TODOs row 12) ------------------------------------------------
  //
  // `unconfigured` is the OPENING state and that is deliberate: it is what the shipped
  // config actually produces today, because the endpoint is the RFC 2606 `.invalid`
  // placeholder and where RichOS updates are hosted has not been decided. A harness that
  // opened on "up to date" would be modelling a product we do not have.
  const mockUpdate = {
    view: {
      state: "unconfigured",
      currentVersion: "0.1.0",
      availableVersion: null,
      notes: null,
      pubDate: null,
      downloadedBytes: 0,
      totalBytes: null,
      percent: null,
      failure: null,
      endpoint: "https://updates.richos.invalid/{{target}}/{{arch}}/{{current_version}}",
      endpointIsPlaceholder: true,
      checkedAt: null,
    },
    script: [],
    calls: [],
  };
  /// Pop the next scripted view, or — with nothing scripted — leave the state alone. A
  /// harness that invented a transition would let a suite pass against a flow that never ran.
  function mockUpdateAdvance() {
    if (mockUpdate.script.length) mockUpdate.view = mockUpdate.script.shift();
    return { ...mockUpdate.view };
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
        // ---- techy mode (techy-mode design §3.1/§3.4) ------------------------------
        case "get_machinery": {
          const id = args.threadId ?? args.thread_id;
          const t = threads.find((x) => x.id === id);
          // Fails closed on an unbound thread exactly like `get_timeline` and the real one.
          if (t && !t.entity_id) return Promise.reject(UNBOUND_ERR(id));
          const st = machineryStateOf(id);
          // The SAME projection the payload carries, so the sentence is computed from what
          // will actually be on screen rather than from a second read. `machinery_view.rs`
          // does exactly this — it asks `view.between_turns()`, the gated lane — and the
          // difference matters: an unreadable store projects NO lane rows, so a sentence
          // derived from the raw fixture instead of from the projection would be answering
          // about rows the CEO cannot see.
          const projected = projectTimeline(id, st.state === "recorded" ? "technical" : "technical-empty");
          return {
            threadId: id,
            state: st.state,
            rowCount: st.rowCount || 0,
            sentence: st.sentence,
            reason: st.reason,
            // §1.5: WHY the lane is empty when it is empty — and `null` when the store was
            // UNREADABLE, because "nothing was recorded between turns" is a claim a store
            // that refused to open never supported. `machinery_view.rs` decides it exactly
            // this way.
            betweenTurnsSentence:
              st.state === "unreadable"
                ? null
                : projected.betweenTurns.length === 0
                  ? TECHY_BETWEEN_TURNS_QUIET
                  : null,
            // The conversation still renders in EVERY state — what changes is the sentence
            // over it. An unreadable store is not an empty thread.
            //
            // AND THE MACHINERY ROWS DO NOT. `Spine::timeline` reads the journal through
            // `read_thread`, which returns nothing for a directory the OS refused, so the
            // real backend serves prose and a duration row and NO activity rows in this
            // state. A mock that kept showing them would let the renderer be tested against
            // a screen the product cannot produce.
            timeline: projected,
          };
        }
        case "get_machinery_raw": {
          const threadId = args.threadId ?? args.thread_id;
          const machId = args.machineryId ?? args.machinery_id;
          if (machineryUnreadable.has(threadId)) {
            return { state: "unreadable", payload: null, truncated: false, note: TECHY_RAW_UNREADABLE, reason: "machinery/" + threadId + ": Permission denied (os error 13)" };
          }
          const hit = machineryRaw.get(machId);
          // ABSENT = the Tier-B window passed over it. The record still rendered above; this
          // says why the bytes are gone rather than showing a blank (§2.4's honest degrade).
          if (!hit) return { state: "not_retained", payload: null, truncated: false, note: TECHY_RAW_NOT_RETAINED };
          return {
            state: "retained",
            payload: hit.payload,
            truncated: hit.truncated,
            note: hit.truncated ? TECHY_RAW_TRUNCATED : null,
          };
        }
        case "techy_mode":
          return techyModeOf(args.threadId ?? args.thread_id ?? "");
        case "set_techy_mode": {
          const id = args.threadId ?? args.thread_id;
          // `enabled: null` CLEARS the override and hands the thread back to the global
          // default. That arm is what keeps §7.1 reversible; without it a pin is one-way.
          if (args.enabled === null || args.enabled === undefined) techyThreads.delete(id);
          else techyThreads.set(id, !!args.enabled);
          return techyModeOf(id);
        }
        case "set_techy_default":
          techyDefault = !!args.enabled;
          return techyDefault;

        // ---- §15: appearance, and the person at the foot of the rail ----------------
        // The real store is `config.rs`; this harness stands in for it with the same
        // shapes and the same honesty about the unset case. `user_name` starts as `null`
        // ON PURPOSE — the unset state is what almost every install actually has, and it
        // is the state the acceptance suite has to be able to reach without arranging
        // anything.
        case "get_appearance":
          return { theme: mockConfig.theme, font_scale: mockConfig.font_scale };
        case "set_theme": {
          const t = String(args.theme);
          // Refused, not coerced, exactly as the real command refuses it: quietly writing
          // "dark" over an unexpected string looks like the CEO changing his own mind.
          if (t !== "dark" && t !== "light" && t !== "system") {
            throw new Error(`unknown theme "${t}"`);
          }
          mockConfig.theme = t;
          persistMockConfig();
          return null;
        }
        case "set_font_scale": {
          const steps = [80, 90, 100, 110, 120, 135, 150];
          const want = Number(args.scale);
          // Snapped, not rejected — `snap_font_scale` in config.rs, mirrored.
          mockConfig.font_scale = steps.reduce((a, b) => (Math.abs(b - want) < Math.abs(a - want) ? b : a), 100);
          persistMockConfig();
          return null;
        }
        case "get_user_identity":
          return { name: mockConfig.user_name, initials: mockInitials(mockConfig.user_name) };
        case "set_user_name": {
          const n = String(args.name || "").trim();
          mockConfig.user_name = n === "" ? null : n;
          persistMockConfig();
          return null;
        }

        // ---- §7.2: the raw-retention window ----------------------------------------
        case "raw_retention":
          return retentionView(0);
        case "set_raw_retention": {
          const next = String(args.choice);
          // An unknown choice — `custom` included, which describes a hand-edited file and
          // never instructs one — is REFUSED, exactly as the real command refuses it.
          // Nothing set, nothing evicted: a bad argument to a command that deletes must do
          // nothing at all.
          if (!Object.prototype.hasOwnProperty.call(RETENTION_WINDOWS, next)) {
            return Promise.reject("unknown retention choice: " + next);
          }
          retentionChoice = next;
          const w = RETENTION_WINDOWS[next];
          const before = rawShards.length;
          if (w.ageDays !== "forever") rawShards = rawShards.filter((sh) => sh.ageDays <= w.ageDays);
          return retentionView(before - rawShards.length);
        }

        // WHERE HIS MEMORY IS (`memory.rs`). The preview's default is `ready`, because a
        // machine that has been set up once is what every other fixture assumes; `memory:
        // "none"` drives the fresh install, which is the state the real defect lived in.
        case "memory_status":
          return memoryStatusOf();
        // The answer. It provisions nothing here — the point of the mock is the SURFACE —
        // but it returns the shape the real command returns, including the honest
        // `no-compiler` outcome, which is what a machine with no compiler actually gets.
        case "provision_memory": {
          const given = args && args.location;
          if (!given)
            return Promise.reject(
              "no location was given for the corpus. There is no default: a corpus root " +
                "nobody named would compile the wrong memory, or none, and report success " +
                "either way."
            );
          memoryState = memoryCompilerPresent ? "ready" : "no-compiler";
          memoryRoot = given;
          // AND THE DESK OPENS, in the same call, because the real one now does
          // (`main.rs::install_correction_desk`, called from `provision_memory`). Until
          // 2026-09-01 the field it writes to was fixed at boot, so a fresh user got a
          // readable memory and a shut desk until he relaunched. A mock that kept the old
          // shape would rehearse the SURFACE against behavior the backend no longer has,
          // which is worse than having no mock for it.
          //
          // It follows the compiler, not the corpus: a `no-compiler` outcome has no
          // `loro-write.mjs` either, so there is nothing for a desk to write with.
          if (memoryCompilerPresent) loroDeskOn = true;
          return { ...memoryStatusOf(), provisioned_now: true };
        }
        case "entity_choice":
          return entityChoiceOf();
        // --- the home screen's company buttons (2026-09-01) ---
        case "home_entity_row":
          return homeEntityRowOf();
        case "set_home_entity_label": {
          const id = args.entityId ?? args.entity_id;
          if (!entities.some((e) => e.id === id))
            return Promise.reject(
              'I don\'t have a company called "' + id + '" on file, so I won\'t file ' +
                "anything under it. Pick one of the companies I do have, or whoever set " +
                "RichOS up can add it."
            );
          const label = args.label == null ? "" : String(args.label).trim();
          // Empty CLEARS, exactly as `ConfigStore::set_home_entity_label` does — that is how
          // he un-anonymizes the screen, so the mock does it too rather than simplifying it
          // away into something the app does not actually do.
          if (label) homeEntityLabels[id] = label;
          else delete homeEntityLabels[id];
          return homeEntityRowOf();
        }
        case "set_home_entity_visible": {
          const id = args.entityId ?? args.entity_id;
          if (!entities.some((e) => e.id === id))
            return Promise.reject(
              'I don\'t have a company called "' + id + '" on file, so I won\'t file ' +
                "anything under it. Pick one of the companies I do have, or whoever set " +
                "RichOS up can add it."
            );
          if (args.visible === false) homeEntityHidden[id] = true;
          else delete homeEntityHidden[id];
          return homeEntityRowOf();
        }
        case "choose_entity": {
          const entityId = args.entityId ?? args.entity_id;
          if (entityPinnedByEnvironment)
            return Promise.reject(
              "This copy of me was told which company it works for when it was started up, " +
                "from outside this window, so I can't move it from in here. Whoever set " +
                "RichOS up is the one who changes that."
            );
          if (!entities.some((e) => e.id === entityId))
            return Promise.reject(
              'I don\'t have a company called "' + entityId + '" on file, so I won\'t file ' +
                "anything under it. Pick one of the companies I do have, or whoever set " +
                "RichOS up can add it."
            );
          chosenEntityId = entityId;
          chosenEntitySource = "saved-choice";
          // The real command activates a thread ONLY when nothing is open — it never
          // re-homes an existing conversation (ECS §3.2). Same rule here.
          if (!activeContextOf()) {
            const existing = threads
              .filter((t) => t.entity_id === entityId)
              .sort((a, b) => b.created_at - a.created_at)[0];
            if (existing) activeThreadId = existing.id;
          }
          return entityChoiceOf();
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
        // UX §7.3's background-work summary. Shaped exactly like `WorkerStatusView`
        // (worker_status.rs): a real `active` count, a real `liveness_unknown`, and
        // `needs_you` STRUCTURALLY ZERO — no decision-required signal exists anywhere in
        // the engine, so there is no honest non-zero value to mock either.
        case "get_worker_status":
          return {
            active: 1,
            needs_you: 0,
            liveness_unknown: 1,
            items: [
              { label: "Frank", state: "active", agent_id: "agt_frank_1" },
              { label: "Sage", state: "unknown", agent_id: "agt_sage_1" },
              { label: "mark-sonnet-f1: wire the tenantGuard fixture", state: "done" },
            ],
          };
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
            // VERBATIM from `LEASE_UNAVAILABLE_MESSAGE`, app/src-tauri/src/main.rs. The
            // affordance suite asserts the two are byte-identical, so the preview cannot
            // quietly rehearse a sentence the product no longer says.
            return Promise.reject(
              "I'm not connected to my thinking right now, so I can't take that on. Quit RichOS and open it again — that clears it most of the time. If it keeps happening, whoever set RichOS up has to sign me back in; that part isn't yours to fix."
            );
          }
          // §26's scenario is started BY THE CEO PRESSING ENTER, not by a side door. The
          // shell's ordinary send path runs first — the optimistic bubble goes up with a
          // synthetic id and `onTurnStatus`'s `adoptPendingUserMessage` re-keys it onto
          // `turn_memory_01:user` when `queued` arrives — so "just after send" is the state
          // the CEO actually sees, not one the fixture painted.
          if (activeThreadId === MEMORY_THREAD_ID && args.text === MEMORY_PROMPT) {
            memoryScenario = memoryStrategy({ anchor: memoryStrategyAnchor });
            memoryScenario.runTo(2);
            return messagesByThread[MEMORY_THREAD_ID];
          }
          simulateTurn(activeThreadId, args.text);
          return messagesByThread[activeThreadId];
        }

        // ---- the loro correction desk (`correction.rs`) -------------------------------
        case "loro_available":
          return loroDeskOn;
        case "loro_pending_corrections": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          return proposals.filter((p) => p.state === "awaiting-ceo");
        }
        case "loro_suppressed_records": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          return loroSuppressed.slice();
        }
        case "loro_show_record": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          const ref = args.recordRef ?? args.record_ref;
          if (ref !== "rec:ceo/records/decision-ship-thursday")
            return Promise.reject('loro write: no record with ref "' + ref + '"');
          return { op: "show", dryRun: false, ref, file: "loro/ceo/records/decision-ship-thursday.md", text: LORO_RECORD_NOW, changed: [] };
        }
        case "loro_propose_correction": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          const why = String(args.why || "").trim();
          // Refused before a process is started: a correction with no stated reason is the
          // shape an INFERRED one takes (`correction.rs:496-500`).
          if (!why) return Promise.reject("a correction needs the CEO's own words for what was wrong (--why)");
          const target = refOf(args.write);
          if (target && loroSuppressed.includes(target))
            return Promise.reject('"' + target + '" was permanently declined for correction — clear the suppression to propose again');
          const p = {
            id: "prop-" + proposalSeq++,
            at: now(),
            entity_id: "femcboost",
            thread_id: args.threadId ?? args.thread_id ?? "",
            write: args.write,
            why,
            preview: LORO_PREVIEW,
            state: "awaiting-ceo",
            outcome: null,
            failure: null,
          };
          proposals.push(p);
          return p;
        }
        case "loro_confirm_correction": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          const p = proposals.find((x) => x.id === args.id);
          if (!p) return Promise.reject("no proposal " + args.id);
          // A double click must not write twice (`correction.rs:541-543`).
          if (p.state !== "awaiting-ceo")
            return Promise.reject("proposal " + p.id + " is " + p.state + ", not awaiting the CEO — it cannot be confirmed twice");
          if (window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__._loroWriterRefusal) {
            p.state = "failed";
            p.failure = window.__RICHOS_MOCK__._loroWriterRefusal;
            return p;
          }
          p.state = "written";
          p.outcome = {
            op: "supersede",
            dryRun: false,
            ref: "rec:ceo/records/decision-ship-date",
            supersededRef: refOf(p.write),
            file: "loro/ceo/records/decision-ship-date.md",
            text: LORO_PREVIEW,
            changed: [],
          };
          return p;
        }
        case "loro_decline_correction": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          const p = proposals.find((x) => x.id === args.id);
          if (!p) return Promise.reject("no proposal " + args.id);
          if (p.state !== "awaiting-ceo")
            return Promise.reject("proposal " + p.id + " is " + p.state + ", not awaiting the CEO — it cannot be confirmed twice");
          p.state = "declined";
          const target = refOf(p.write);
          if (args.permanent && target && !loroSuppressed.includes(target)) loroSuppressed.push(target);
          return null;
        }
        case "loro_unsuppress_record": {
          const gate = loroGate();
          if (gate) return Promise.reject(gate);
          const ref = args.recordRef ?? args.record_ref;
          const at = loroSuppressed.indexOf(ref);
          if (at >= 0) loroSuppressed.splice(at, 1);
          return null;
        }

        // ---- the spoken correction desk (`staging.rs`) --------------------------------
        case "spoken_corrections_available":
          return spokenDeskOn;
        case "spoken_pending_corrections": {
          const gate = spokenGate();
          if (gate) return Promise.reject(gate);
          return candidates.slice();
        }
        case "spoken_suppressed_terms": {
          const gate = spokenGate();
          if (gate) return Promise.reject(gate);
          return spokenSuppressed.slice();
        }
        case "spoken_confirm_correction": {
          const gate = spokenGate();
          if (gate) return Promise.reject(gate);
          const at = candidates.findIndex((c) => c.key === args.key);
          if (at < 0) return Promise.reject("no correction " + args.key + " is awaiting an answer");
          if (window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__._noVocabulary) {
            // `staging.rs:74`: RichOS will not report a term as learned when nothing wrote
            // it, and the candidate stays answerable.
            return Promise.reject(
              "no vocabulary backend is attached — RichOS will not report a term as learned when nothing wrote it"
            );
          }
          const c = candidates.splice(at, 1)[0];
          const already = window.__RICHOS_MOCK__ && window.__RICHOS_MOCK__._vocabularyAlreadyKnew;
          return { file: "loro/entities.json", changed: !already, created: false, version: "2026-08-30T09:12:00Z" };
        }
        case "spoken_decline_correction": {
          const gate = spokenGate();
          if (gate) return Promise.reject(gate);
          const at = candidates.findIndex((c) => c.key === args.key);
          if (at < 0) return Promise.reject("no correction " + args.key + " is awaiting an answer");
          const c = candidates.splice(at, 1)[0];
          if (args.permanent) {
            if (!spokenSuppressed.includes(c.key)) spokenSuppressed.push(c.key);
          } else {
            // §7: a plain decline is re-asked on the very next repeat, and the second ask
            // has to SAY it was asked before. The count is kept, not the card.
            declinedCounts[c.key] = (declinedCounts[c.key] || 0) + 1;
          }
          return null;
        }
        case "spoken_unsuppress_term": {
          const gate = spokenGate();
          if (gate) return Promise.reject(gate);
          const at = spokenSuppressed.indexOf(args.key);
          if (at >= 0) spokenSuppressed.splice(at, 1);
          return null;
        }

        // ---- the feedback channel (`feedback.rs`) --------------------------------------
        //
        // NOTHING HERE SENDS ANYTHING, in the harness for the same reason as in the
        // product: there is no transport to mock, because there is none to run.
        case "feedback_available":
          return feedbackStoreOpen;
        case "feedback_wording":
          return {
            question: FEEDBACK_QUESTION,
            options: FEEDBACK_OPTIONS,
            reportOffer: FEEDBACK_REPORT_OFFER,
            disclosureHeading: FEEDBACK_DISCLOSURE_HEADING,
            taxonomyVersion: "v1",
            ratings: FEEDBACK_RATINGS.map((r) => ({ ...r })),
            dismiss: { key: "0", label: "Dismiss" },
          };
        case "feedback_taxonomy":
          return {
            version: "v1",
            failureClass: FEEDBACK_FAILURE_CLASS.map((t) => ({ ...t })),
            occurrences: FEEDBACK_OCCURRENCES.map((t) => ({ ...t })),
            diagnosis: FEEDBACK_DIAGNOSIS.map((t) => ({ ...t })),
            conditions: FEEDBACK_CONDITIONS.map((t) => ({ ...t })),
          };
        case "feedback_preview": {
          const rating = FEEDBACK_RATINGS.find((r) => r.key === args.key);
          if (!rating) return Promise.reject("That isn't one of the four answers, so I haven't written anything down.");
          try {
            const payload = feedbackAssemble(rating, args.selection || {});
            return {
              heading: FEEDBACK_DISCLOSURE_HEADING,
              text: feedbackRender(payload),
              full: feedbackFullText(payload),
            };
          } catch (e) {
            return Promise.reject(String(e));
          }
        }
        case "feedback_record": {
          const outcome = feedbackOutcome(args.key);
          if (!outcome)
            return Promise.reject("That isn't one of the four answers, so I haven't written anything down.");
          const rating = FEEDBACK_RATINGS.find((r) => r.key === args.key);
          const choice = args.report || { decision: "not_offered" };
          let report = { decision: "not_offered" };
          if (choice.decision !== "not_offered") {
            // `FeedbackEntry::with_report`: a `3` or a dismissal never invited an offer, so
            // a report attached to one is not a thing that happened.
            if (!rating || !rating.invitesReport)
              return Promise.reject(
                "rating '" + (rating ? rating.key : "0") + "' does not invite a report — the offer is made on 1 and 2 only"
              );
          }
          if (choice.decision === "declined") report = { decision: "declined" };
          if (choice.decision === "approved") {
            let payload;
            try {
              payload = feedbackAssemble(rating, choice.selection || {});
            } catch (e) {
              return Promise.reject(String(e));
            }
            // THE CHECK THAT MAKES "he saw exactly this" SURVIVE THE BRIDGE. In-process the
            // type system carries it (`ApprovedReport` has no public constructor); across
            // an IPC boundary it has to be re-rendered and compared.
            if (feedbackFullText(payload) !== choice.shown) return Promise.reject(FEEDBACK_PREVIEW_MISMATCH);
            report = { decision: "approved", report: payload };
          }
          if (!feedbackStoreOpen) return Promise.reject(FEEDBACK_STORE_ABSENT);
          const entry = { recorded_at_millis: now(), outcome, report };
          feedbackEntries.push(entry);
          return JSON.parse(JSON.stringify(entry));
        }
        case "feedback_history": {
          if (!feedbackStoreOpen) return Promise.reject(FEEDBACK_STORE_ABSENT);
          if (feedbackReadFailure) return Promise.reject(feedbackReadFailure);
          return feedbackEntries.map((e) => ({
            entry: JSON.parse(JSON.stringify(e)),
            // Re-rendered from the STORED payload, exactly as `ApprovedReport::as_shown`
            // does — no second copy of the text is kept anywhere.
            shown: e.report.decision === "approved" ? feedbackRender(e.report.report) : null,
          }));
        }

        case "launch_state":
          launchCalls.stateReads.push(args);
          return { ...LAUNCH_STATE, recentSplashes: launchCalls.splashShown.slice().reverse().slice(0, 5) };
        case "launch_note_splash_shown":
          launchCalls.splashShown.push(args.id);
          return null;

        // ---- the update path (RICH-TODOs row 12) ---------------------------------
        // Shapes are `UpdateView` from `src-tauri/src/updates.rs`, verbatim. The harness
        // does NOT simulate a download: `mockUpdate.script` is a queue of views a test
        // pushes, so a suite drives the panel through downloading -> installing -> ready,
        // or straight to a refused signature, without any timing to be flaky about.
        case "update_state":
          mockUpdate.calls.push("update_state");
          return { ...mockUpdate.view };
        case "update_check":
          mockUpdate.calls.push("update_check");
          return mockUpdateAdvance();
        case "update_install":
          mockUpdate.calls.push("update_install");
          return mockUpdateAdvance();
        case "update_relaunch":
          // The real command never returns — the process is replaced. Recording the call is
          // the only thing a browser can honestly do with it.
          mockUpdate.calls.push("update_relaunch");
          return null;

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

  // =======================================================================================
  // §26 — THE DETERMINISTIC `memory-strategy` FIXTURE
  // =======================================================================================
  //
  // §26 prescribes sixteen steps and calls the result the acceptance instrument for Phase
  // 3's exit gate. An acceptance instrument that emits signals the product cannot emit
  // certifies nothing — it certifies the fixture. So this scenario was built to what the
  // runtime can ACTUALLY produce, and every step §26 asks for that the runtime cannot
  // produce is recorded below as unrepresentable, with the file and line that makes it so.
  //
  // ---------------------------------------------------------------------------------------
  // THE THREE THINGS THIS FIXTURE REFUSES TO DO, AND WHY
  // ---------------------------------------------------------------------------------------
  //
  // 1. NO WORKER FAILURE (§26 step 10, §10.6, §7.4).
  //    `ObservedWorkerState` has exactly four variants — `Created`, `Started`, `Updated`,
  //    `RunEnded` (worker_events.rs:128-139) — and `RunEnded`'s own doc says "**The reason
  //    is not observable.** Never `Completed`." (worker_events.rs:137-138).
  //    `WorkerState::from_observed` maps it to `RUN_ENDED_WORKER_STATE`, a named constant
  //    equal to `WorkerState::Unknown` (timeline.rs:403, :413-421), and the renderer draws
  //    that as `Ended · outcome not recorded` (timeline.js:336-360). There is no payload
  //    anywhere in the worker path that carries an outcome. A fixture that emitted
  //    `state: "failed"` would light up a renderer branch production can never reach, and a
  //    green run over it would certify a state that cannot occur.
  //
  // 2. NO PLAN (§26 step 13, §8).
  //    `TimelineItem::Plan` is "MODELLED, NEVER PRODUCED" (timeline.rs:611-617) and the
  //    module's own source table says "**NO SOURCE.** `plan` updates are Phase-2 machinery"
  //    (timeline.rs:62). Those updates are retained verbatim as `MachineryKind::Unknown`
  //    (machinery.rs:556) with their entries living only inside the EVICTABLE raw payload,
  //    so a plan projected from them empties out after the Tier-B window (timeline.rs:466-469).
  //    `rich://plan-updated` is DEFERRED in the emitter (live.rs:27). Nothing constructs a
  //    `PlanItem`. `Step 2 of 5 -> Step 3 of 5` has no source at either end.
  //
  // 3. NO FAILURE CLAIM IN RICH'S OWN WORDS EITHER — the subtle half.
  //    §10.6 scripts Rich saying *"Sage stopped after writing most of the architecture."*
  //    Prose is the one channel where anything at all can be typed, so faking the failure
  //    through Rich's mouth would sail past every state check in this file while making
  //    exactly the claim the data cannot support. Rich's recovery commentary here says only
  //    what the runtime witnessed: the run ended and no outcome was recorded.
  //
  // ---------------------------------------------------------------------------------------
  // THE PATH — the same one a real turn takes, with ONE named divergence
  // ---------------------------------------------------------------------------------------
  //
  // Prose, activity, turn state AND WORKER ROWS all go out as §13 events the emitter
  // actually emits, and reach the renderer through `main.js`'s listeners — the real live
  // path, with no divergence left in this fixture.
  //
  // Worker rows were the one exception until 2026-08-29: `rich://worker-upserted` was
  // deferred in the emitter (live.rs:26) and had no listener in `main.js`, so their only
  // route to the screen was the durable snapshot and this fixture measured the consequence
  // — 0 chips live, 3 after a `get_timeline` read. The emitter now sends it (live.rs, "the
  // delegation the CEO sees while it happens"), so the fixture sends it too: every worker
  // row is written into the durable turn record AND emitted live, exactly as the backend
  // does. The payload shape is `TimelineItem::WorkerActivity` + `at`, which is what
  // `LiveEvent::WorkerUpserted::payload` puts on the wire.
  //
  // ---------------------------------------------------------------------------------------
  // THE CLOCK
  // ---------------------------------------------------------------------------------------
  //
  // Injected as `anchor` — the wall-clock instant virtual t=0 maps onto — and every event
  // timestamp is `anchor + offset`. Nothing sleeps and nothing polls: `runTo(n)` walks the
  // whole two-hour turn in under a millisecond. This is deliberately NOT a monkey-patched
  // `Date.now`, because §6.2 requires the display to be DERIVED from persisted timestamps
  // ("Persist timestamps and derive the display locally"), and driving the fixture through
  // real timestamps is what proves that derivation instead of bypassing it. A test wanting
  // `Working for 18s` anchors 18s + the lease handoff in the past and reads the real row.
  //
  // THE DURATION, DERIVED RATHER THAN ASSERTED (§26 step 16 = `2h 17m 50s`):
  //   2h 17m 50s = (2 x 3600) + (17 x 60) + 50 = 7200 + 1020 + 50 = 8270 s = 8_270_000 ms
  // and back through `RichTimeline.formatDuration(8270000)` (timeline.js:72-86):
  //   totalSec  = floor(8270000/1000) = 8270 ;  s = 8270 mod 60          = 50
  //   totalMin  = floor(8270/60)      =  137 ;  m =  137 mod 60          = 17
  //   totalHour = floor(137/60)       =    2 ;  h =    2 mod 24          =  2
  //   d = 0, totalHour >= 1           -> "2h 17m 50s"
  // The measured span is `endedAt - startedAt` (`ledger::Turn::active_ms`), so the fixture
  // sets `endedAt = startedAt + 8_270_000` and never writes `activeMs` by hand.
  //
  // ONE HONEST LIMIT OF ANCHORING RATHER THAN PATCHING. While a turn is LIVE the row is
  // `Date.now() - startedAt` (timeline.js:151), so mid-scenario it shows the REAL elapsed
  // time since the anchor — a few hundred milliseconds — not the virtual position. That is
  // the renderer being right, not the fixture being wrong: a live timer that read from
  // scripted timestamps would be a fixture-only code path. §26's two duration screenshots
  // are `Working for 18s` (anchored, live, real) and `Worked for 2h 17m 50s` (measured,
  // terminal), and both are exact. A live row reading `Working for 1h 6m 0s` would need an
  // anchor 1h06m in the past — one line in a test, and no step of §26 asks for it.
  // =======================================================================================

  /// The live scenario, if one has been started, and the wall-clock instant its virtual
  /// t=0 maps onto. A test sets the anchor BEFORE pressing Enter — that is the whole of
  /// the clock injection, and it is why a two-hour turn takes under a millisecond.
  let memoryScenario = null;
  let memoryStrategyAnchor;

  const MS_ACTIVE = 8270000; // see the arithmetic above
  const MS_LEASE_HANDOFF = 600; // t=0 accepted -> t=600 a lease has it and the clock starts
  const MS_TURN_END = MS_LEASE_HANDOFF + MS_ACTIVE;
  const MEMORY_TURN_ID = "turn_memory_01";
  const MEMORY_THREAD_ID = "memory";

  const MEMORY_PROMPT = [
    "Read all the linked material and design a proper replacement for Claude auto memory.",
    "",
    "Sources, in the order I want them read:",
    "",
    "  /Users/alex/ab/richos/docs/plans/richos-ecs-architecture-2026-08-27.md",
    "  /Users/alex/ab/richos/wiki/ceo-decisions.md",
    "  /Users/alex/ab/femcboost/CLAUDE.md",
    "  /Users/alex/.claude/projects/-Users-alex-ab-femcboost/memory/MEMORY.md",
    "  https://docs.anthropic.com/en/docs/claude-code/memory",
    "  https://code.claude.com/docs/en/memory",
    "",
    "What I actually want to know:",
    "",
    "  - what the Executive Continuity System has to hold, and what it must refuse to hold",
    "  - whether it is one store or several, and who is allowed to write to it",
    "  - how a correction reaches it, and what happens to the thing it corrects",
    "  - how any of it survives a restart, and what is lost when it does not",
    "  - what the cutover from Claude auto memory looks like on the day it happens",
    "",
    "Take the passes in parallel if that is faster. Do not build anything yet.",
    "Ask me 3 to 5 questions first, and make them the ones you actually cannot answer",
    "yourself — I would rather answer five hard questions than read five easy ones.",
  ].join("\n");

  /// §26's sixteen steps, each judged against the runtime rather than against the brief.
  ///
  /// `status` is one of:
  ///   `represented`    — the step is emitted and rendered, in full.
  ///   `partial`        — what the runtime witnesses is emitted; a named part of §26's
  ///                      wording has no source and is NOT drawn.
  ///   `unrepresentable`— nothing is emitted at all. The browser suite asserts these are
  ///                      ABSENT from the DOM, so "we did not fake it" is a test rather
  ///                      than a promise.
  ///
  /// This table is the deliverable as much as the pixels are. If a signal lands later, the
  /// negative assertions in `memory-strategy.js` fail loudly and point back at this row.
  const MEMORY_STRATEGY_STEPS = [
    { n: 1, spec: "Long CEO prompt with file paths and two URLs", status: "partial",
      have: "The full prompt renders, over §5.1's 18-line clamp, with Show more/Show less.",
      gap: "The two URLs are TEXT, not links. §10.2 wants them clickable; the CEO bubble is " +
           "built with textContent and nothing linkifies it (timeline.js:969).",
      source: "timeline.js:940,969" },
    { n: 2, spec: "Turn accepted", status: "represented",
      have: "rich://turn-status queued at t=0 with startedAt null -> §6.1's bare `Working`, " +
            "then working at t=600 -> `Working for {d}` once a second has passed.",
      source: "live.rs:107" },
    { n: 3, spec: "Rich commentary", status: "partial",
      have: "The commentary streams as a real message run and stays in the transcript.",
      gap: "phase is `unknown`, never `commentary`. STREAMED_MESSAGE_PHASE is a named " +
           "constant equal to RichMessagePhase::Unknown because no signal separates " +
           "commentary from the final answer on this wire.",
      source: "live.rs:120, live.rs:42-62" },
    { n: 4, spec: "Seven file reads grouped into one summary", status: "represented",
      have: "Seven `Read a file` rows, consecutive, rolled up by the renderer into " +
            "`Read 7 files` — the grouping §26 asks for, done where it is honest to do it.",
      source: "timeline.rs:1400-1417, timeline.js:290-308" },
    { n: 5, spec: "One web search", status: "partial",
      have: "One search activity row, rendered `Searched`.",
      gap: "§26/§5.3's `Searched the web for Claude Code memory` cannot be produced: " +
           "semantic_summary builds the line from the activity TYPE alone and deliberately " +
           "carries no query text, so the CEO default stays semantic and never leaks syntax.",
      source: "timeline.rs:1400-1417" },
    { n: 6, spec: "Sage, Frank and Clark start", status: "represented",
      have: "Three worker rows, `created` then `started` -> Starting/Working, grouped as " +
            "`Sage, Frank and Clark started working` — LIVE, during the turn. Was " +
            "snapshot-only until 2026-08-29, when rich://worker-upserted stopped being " +
            "deferred; this fixture measured that gap as 0 chips live and 3 after the read.",
      source: "live.rs:26, worker_events.rs:128-139" },
    { n: 7, spec: "Clark update", status: "represented",
      have: "`updated` -> Running, with the summary Clark actually authored, live and in " +
            "place — one run is one row however many lifecycle events it produced.",
      source: "worker_events.rs:134-136" },
    { n: 8, spec: "Frank completion", status: "partial",
      have: "Frank's run ENDS, and the row says so: `Ended · outcome not recorded`.",
      gap: "`completion` is not witnessed. run_ended is the honest superset of completed, " +
           "interrupted and failed; §7.1's verb `Frank finished` would claim the one thing " +
           "nobody observed.",
      source: "timeline.rs:394-403, worker_events.rs:147-153" },
    { n: 9, spec: "Sage partial update", status: "partial",
      have: "`updated` -> Running, with Sage's authored summary.",
      gap: "Snapshot-only, as step 6.",
      source: "worker_events.rs:134-136" },
    { n: 10, spec: "Sage failure", status: "unrepresentable",
      have: "Sage's run ends and is drawn `Ended · outcome not recorded` — which is what " +
            "was actually witnessed, and is emitted.",
      gap: "THE FAILURE ITSELF IS NOT EMITTED AND NOT DRAWN. No payload in the worker path " +
           "carries an outcome; WorkerState::Failed has no witness anywhere in the hook " +
           "set. A `failed` chip here would be a green test over a state production cannot " +
           "produce.",
      source: "worker_events.rs:137-138, timeline.rs:361, timeline.rs:413-421" },
    { n: 11, spec: "Rich recovery commentary", status: "partial",
      have: "Rich posts commentary about the ended run, in his own voice, saying only what " +
            "the runtime witnessed.",
      gap: "TWO parts have no source. phase is `unknown`, not `recovery` (live.rs:120) — " +
           "TimelineItem::Recovery is real but means a mid-turn CRASH REPLAY " +
           "(TurnSuperseded) and is Internal visibility, a different event entirely. And " +
           "§10.6's scripted line *\"Sage stopped after writing most of the architecture\"* " +
           "is a failure claim; putting it in Rich's mouth would fake step 10 through the " +
           "one channel that accepts any string.",
      source: "live.rs:120, timeline.rs:652-661" },
    { n: 12, spec: "Sage replacement start", status: "partial",
      have: "A SECOND Sage agent id opens a new run — `created` then `started` — in its own " +
            "group below the commentary, and the parent turn's clock never resets.",
      gap: "Nothing on the wire links the two runs. `replacement` is a relationship the " +
           "data model does not carry, so the UI shows two runs, not a retry.",
      source: "worker_events.rs:128-139" },
    { n: 13, spec: "Plan update from step 2 of 5 to step 3 of 5", status: "unrepresentable",
      have: "Nothing. No plan row is emitted at either step count.",
      gap: "TimelineItem::Plan is modelled and never produced; plan session updates are " +
           "retained as MachineryKind::Unknown with entries only in the EVICTABLE raw " +
           "payload, so a projected plan silently empties after the Tier-B window; and " +
           "rich://plan-updated is deferred in the emitter.",
      source: "timeline.rs:62, timeline.rs:466-469, timeline.rs:611-617, machinery.rs:556, live.rs:27" },
    { n: 14, spec: "Final Sage completion", status: "partial",
      have: "The replacement run ends: `Ended · outcome not recorded`.",
      gap: "As step 8 — no completion signal exists at worker grain.",
      source: "timeline.rs:394-403" },
    { n: 15, spec: "Final Rich response with five questions", status: "partial",
      have: "The five questions stream as Rich's last message run and sit below the " +
            "completed-duration divider, where §25 wants the final response.",
      gap: "It is not LABELLED final (phase `unknown`), so it gets no distinct treatment; " +
           "and TimelineItem::Question — the answerable card — has no source, because §11's " +
           "waiting_for_user state does not exist in this runtime.",
      source: "live.rs:120, timeline.rs:637-647, timeline.js:1416-1421" },
    { n: 16, spec: "Turn completion at a deterministic active duration of 2h 17m 50s", status: "represented",
      have: "endedAt - startedAt = 8_270_000ms exactly, measured not asserted, and the row " +
            "freezes at `Worked for 2h 17m 50s` with the transcript collapsed under it.",
      source: "timeline.js:72-86, timeline.rs:539-556" },
  ];

  /// The scenario. Deterministic by construction: fixed ids, fixed offsets, no Math.random,
  /// no setTimeout, no wall clock except the injected `anchor`.
  ///
  ///     const s = window.__RICHOS_MOCK__.memoryStrategy({ anchor: Date.now() - 18600 });
  ///     s.runTo(5);                      // through "one web search"
  ///     s.runTo(16);                     // the whole two-hour turn, instantly
  ///
  /// Constructing it RESETS the thread, so two runs produce byte-identical output for the
  /// same anchor.
  function memoryStrategy(options) {
    options = options || {};
    const anchor = typeof options.anchor === "number" ? options.anchor : Date.now();
    const startedAt = anchor + MS_LEASE_HANDOFF;
    const at = (offset) => anchor + offset;
    const fence = fenceOf(MEMORY_THREAD_ID, MEMORY_TURN_ID);

    // Reset — the same construction twice must not stack two turns in one thread.
    turnsById.delete(MEMORY_TURN_ID);
    messagesByThread[MEMORY_THREAD_ID] = [];

    const turn = {
      threadId: MEMORY_THREAD_ID,
      entityId: "femcboost",
      userText: MEMORY_PROMPT,
      runs: [],
      state: "queued",
      createdAt: anchor,
      startedAt: null,
      endedAt: null,
      activities: [],
    };
    turnsById.set(MEMORY_TURN_ID, turn);

    // ONE dense sequence across prose runs and work rows, exactly as the ledger keeps it
    // (`text_machinery_and_timeline_records_share_one_dense_per_turn_sequence`), so the
    // renderer's interleave is the real chronology and not this file's idea of one.
    let seq = 0;
    const nextSeq = () => seq++;

    function activityRow(id, offset, activityType, summary, state) {
      const row = {
        kind: "activity",
        id,
        entityId: fence.entityId,
        threadId: MEMORY_THREAD_ID,
        bindingRevision: fence.bindingRevision,
        createdAt: at(offset),
        sequence: nextSeq(),
        slot: "stream",
        visibility: "ceo",
        activityType,
        state,
        summary,
      };
      if (state === "completed") row.completedAt = at(offset);
      turn.activities.push(row);
      emit("rich://activity-upserted", Object.assign({ turnId: MEMORY_TURN_ID }, row, { at: at(offset) }));
      return row;
    }

    /// A worker row goes into the durable record AND onto the live wire, because the
    /// backend now does both. See the path note above for what changed and when.
    function workerRow(id, offset, worker) {
      const row = {
        kind: "worker_activity",
        id,
        entityId: fence.entityId,
        threadId: MEMORY_THREAD_ID,
        bindingRevision: fence.bindingRevision,
        createdAt: at(offset),
        sequence: nextSeq(),
        slot: "stream",
        visibility: "ceo",
        detailRef: id,
        worker,
      };
      turn.activities.push(row);
      emitWorker(row, at(offset));
      return row;
    }

    /// Update a worker row IN PLACE, by id — one run is one row however many events it
    /// produces, which is the invariant slice 5 landed and slice 7 tested. The live event
    /// carries the WHOLE row under the same id, which is why the renderer's upsert leaves
    /// one chip rather than two.
    function workerUpdate(id, patch, offset) {
      const row = turn.activities.find((a) => a.id === id);
      if (!row) return row;
      Object.assign(row.worker, patch);
      emitWorker(row, typeof offset === "number" ? at(offset) : now());
      return row;
    }

    /// One `rich://worker-upserted`, shaped exactly as `LiveEvent::WorkerUpserted::payload`
    /// shapes it: the flattened timeline item, the fence already inside it, plus `at`.
    function emitWorker(row, atMs) {
      emit("rich://worker-upserted", Object.assign({ turnId: MEMORY_TURN_ID }, row, { at: atMs }));
    }

    /// One contiguous run of Rich's prose, streamed sentence by sentence through the three
    /// real message events. The run index is the item id suffix, so the live item and the
    /// re-projected one are the SAME id and a reload re-states rather than duplicates.
    function prose(offset, text) {
      const index = turn.runs.length;
      const messageId = MEMORY_TURN_ID + ":text:" + index;
      const startSeq = nextSeq();
      turn.runs.push({ text, startSeq, at: at(offset) });
      emit("rich://message-started", Object.assign({}, fence, {
        messageId, phase: "unknown", seq: startSeq, visibility: "ceo", at: at(offset),
      }));
      // Deterministic chunking: split after each newline-terminated block, never randomly.
      const parts = text.split(/(?<=\n)/);
      let d = 0;
      for (const part of parts) {
        emit("rich://chunk", { threadId: MEMORY_THREAD_ID, turnId: MEMORY_TURN_ID, seq: startSeq, textDelta: part, at: at(offset + d) });
        emit("rich://message-delta", Object.assign({}, fence, {
          messageId, seq: startSeq, textDelta: part, visibility: "ceo", at: at(offset + d),
        }));
        d += 40;
      }
      emit("rich://message-completed", Object.assign({}, fence, {
        messageId, phase: "unknown", text, visibility: "ceo", at: at(offset + d),
      }));
      messagesByThread[MEMORY_THREAD_ID].push({ role: "assistant", text, turn_id: MEMORY_TURN_ID, at: at(offset) });
      return messageId;
    }

    // -- the sixteen steps, in order ------------------------------------------------------
    const actions = {
      1() {
        messagesByThread[MEMORY_THREAD_ID].push({ role: "user", text: MEMORY_PROMPT, turn_id: MEMORY_TURN_ID, at: anchor });
        return "the CEO's prompt, " + MEMORY_PROMPT.split("\n").length + " lines, 2 URLs, 4 file paths";
      },
      2() {
        emit("rich://turn-status", Object.assign({}, fence, {
          status: "queued", startedAt: null, activeDurationMs: null, visibility: "ceo", at: anchor,
        }));
        turn.state = "working";
        turn.startedAt = startedAt;
        emit("rich://turn-started", { threadId: MEMORY_THREAD_ID, turnId: MEMORY_TURN_ID, at: startedAt });
        emit("rich://turn-status", Object.assign({}, fence, {
          status: "working", startedAt, activeDurationMs: null, visibility: "ceo", at: startedAt,
        }));
        return "accepted at t=0 (`Working`), lease at t=" + MS_LEASE_HANDOFF + "ms (clock starts)";
      },
      3() {
        prose(2000,
          "I'm reading the full source set now — the ECS architecture package, your decisions " +
          "file, FemcBoost's own record and both vendor memory docs — and tracing where RichOS " +
          "actually reads and writes memory today rather than where the docs say it does.\n" +
          "Once I can see the seams I'll split the work so the passes run in parallel."
        );
        return "commentary run 0, phase `unknown` (no phase signal exists)";
      },
      4() {
        for (let i = 1; i <= 7; i++) activityRow("mach_ms_read_" + i, 6000 + (i - 1) * 900, "read", "Read a file", "completed");
        return "7 x `Read a file` -> the renderer rolls up to `Read 7 files`";
      },
      5() {
        activityRow("mach_ms_search_1", 13000, "search", "Searched", "completed");
        return "1 x `Searched` (the query text has no source — see step 5's gap)";
      },
      6() {
        workerRow("mach_ms_w_sage_1", 22000, {
          agentId: "agt_ms_sage_1", workerName: "Sage", agentType: "architecture",
          observedState: "started", state: "running", eventsObserved: 2,
          firstObservedAt: iso(at(22000)), lastObservedAt: iso(at(22400)),
        });
        workerRow("mach_ms_w_frank_1", 22100, {
          agentId: "agt_ms_frank_1", workerName: "Frank", agentType: "red team",
          observedState: "started", state: "running", eventsObserved: 2,
          firstObservedAt: iso(at(22100)), lastObservedAt: iso(at(22500)),
        });
        workerRow("mach_ms_w_clark_1", 22200, {
          agentId: "agt_ms_clark_1", workerName: "Clark", agentType: "research",
          observedState: "started", state: "running", eventsObserved: 2,
          firstObservedAt: iso(at(22200)), lastObservedAt: iso(at(22600)),
        });
        // All three `started`, which is what makes the group summary read §10.4's sentence
        // verbatim — `workerGroupSummary` only says "started working" when every member is
        // running, and says "Delegated to ..." for a mixed group. The `created` -> Starting
        // state is real and is exercised by the `hiring` fixture above; §26 step 6 asks for
        // the three-way START, so this is the three-way start.
        return "3 worker rows in ONE group -> `Sage, Frank and Clark started working`";
      },
      7() {
        workerUpdate("mach_ms_w_clark_1", {
          observedState: "updated", state: "running", eventsObserved: 4,
          latestUpdate: "Read both vendor memory docs and the FemcBoost record; three claims in CLAUDE.md contradict what is on disk",
          lastObservedAt: iso(at(1320000)),
        });
        return "Clark `updated` -> Working, with the summary he authored";
      },
      8() {
        workerUpdate("mach_ms_w_frank_1", {
          observedState: "run_ended", state: "unknown", eventsObserved: 6,
          latestUpdate: "Red-teamed the retention rules; the correction path is the one that loses data",
          lastObservedAt: iso(at(2460000)),
        });
        return "Frank's RUN ended -> `Ended · outcome not recorded` (not `finished`)";
      },
      9() {
        workerUpdate("mach_ms_w_sage_1", {
          observedState: "updated", state: "running", eventsObserved: 9,
          latestUpdate: "Four entities drafted; the write path and the restart proof are still open",
          lastObservedAt: iso(at(3300000)),
        });
        return "Sage `updated` -> Working, with a partial architecture summary";
      },
      10() {
        workerUpdate("mach_ms_w_sage_1", {
          observedState: "run_ended", state: "unknown", eventsObserved: 11,
          lastObservedAt: iso(at(3960000)),
        });
        // §26 asks for a FAILURE here. Nothing is emitted for it — see the header, and the
        // `unrepresentable` row for step 10. What IS emitted is the run ending, which is
        // the entirety of what the runtime witnessed.
        return "Sage's RUN ended. NO failure signal emitted — step 10 is unrepresentable";
      },
      11() {
        prose(4020000,
          "Sage's run ended and nothing recorded how — the runtime witnesses that a run " +
          "stopped, never why, so I'm not going to put a reason on it that I don't have.\n" +
          "What I can see is the work: four entities drafted, the write path and the restart " +
          "proof still open. That's intact and worth keeping, so I'm putting a second " +
          "architecture pass on just those two open pieces rather than starting the whole " +
          "thing again. Your clock keeps running; nothing resets."
        );
        return "recovery commentary — phrased to what was witnessed, no failure claim";
      },
      12() {
        workerRow("mach_ms_w_sage_2", 4140000, {
          agentId: "agt_ms_sage_2", workerName: "Sage", agentType: "architecture",
          observedState: "started", state: "running", eventsObserved: 2,
          firstObservedAt: iso(at(4140000)), lastObservedAt: iso(at(4140400)),
        });
        return "a SECOND Sage run opens, in its own group; the parent clock does not reset";
      },
      13() {
        // §26 step 13: "Plan update from step 2 of 5 to step 3 of 5."
        // NOTHING IS EMITTED. There is no plan at step 2 to update and no source for step 3.
        return "SKIPPED — no plan row emitted; step 13 is unrepresentable";
      },
      14() {
        workerUpdate("mach_ms_w_sage_2", {
          observedState: "run_ended", state: "unknown", eventsObserved: 8,
          latestUpdate: "Closed the write path and the restart proof; the package is on disk",
          lastObservedAt: iso(at(7920000)),
        });
        return "the replacement run ends -> `Ended · outcome not recorded`";
      },
      15() {
        prose(8100000,
          "I've read the full source set and had Sage, Frank and Clark work the architecture, " +
          "the threat model and the product research independently. The boundary is clear " +
          "enough to build against, and five things are genuinely yours to decide.\n" +
          "\n" +
          "1. What is the first deliverable — the typed store itself, or the correction path " +
          "into it? They can't both be first and the second one shapes the first.\n" +
          "2. One Rich or several? A shared store across sessions and a per-session store are " +
          "different products, and the answer changes the write path.\n" +
          "3. How far does Executive Continuity reach — decisions and their reversals only, or " +
          "the working context around them too?\n" +
          "4. When you correct me, does the old record stay visible with a supersession link, " +
          "or does it go? Frank's pass says this is where data gets lost.\n" +
          "5. On cutover day, does Claude auto memory go read-only, get exported, or stay live " +
          "beside the new store until you say otherwise?"
        );
        return "final run: five questions, below the completed divider";
      },
      16() {
        const endedAt = startedAt + MS_ACTIVE;
        turn.state = "completed";
        turn.endedAt = endedAt;
        emit("rich://turn-completed", { threadId: MEMORY_THREAD_ID, turnId: MEMORY_TURN_ID, stopReason: "end_turn", at: endedAt });
        emit("rich://turn-status", Object.assign({}, fence, {
          status: "completed", startedAt, activeDurationMs: endedAt - startedAt, visibility: "ceo", at: endedAt,
        }));
        emit("rich://thread-summary-updated", Object.assign({}, fence, {
          title: "Design RichOS memory strategy",
          messageCount: messagesByThread[MEMORY_THREAD_ID].length,
          lastActivity: endedAt, status: "idle", visibility: "ceo", at: endedAt,
        }));
        const t = threads.find((x) => x.id === MEMORY_THREAD_ID);
        if (t) { t.last_turn_state = "completed"; t.last_activity = endedAt; }
        return "completed; activeMs = " + (endedAt - startedAt) + " -> `Worked for 2h 17m 50s`";
      },
    };

    let cursor = 0;
    const driver = {
      anchor,
      startedAt,
      turnId: MEMORY_TURN_ID,
      threadId: MEMORY_THREAD_ID,
      activeMs: MS_ACTIVE,
      leaseHandoffMs: MS_LEASE_HANDOFF,
      steps: MEMORY_STRATEGY_STEPS,
      get cursor() { return cursor; },
      /// Apply the next step. Returns its manifest row plus what it actually did.
      step() {
        if (cursor >= 16) return null;
        cursor += 1;
        const did = actions[cursor]();
        return Object.assign({ did }, MEMORY_STRATEGY_STEPS[cursor - 1]);
      },
      /// Apply steps up to and including `n`. Instant — nothing here waits on a clock.
      runTo(n) {
        const out = [];
        while (cursor < n) out.push(driver.step());
        return out;
      },
    };
    return driver;
  }

  /// RFC-3339 with a `+00:00` offset — the shape the worker-lifecycle emitter writes and
  /// `WorkerActivityItem` carries verbatim (timeline.rs:455-461).
  function iso(ms) {
    return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "+00:00");
  }

  // --- dev-only test hooks, exercised by a headless check, never by real users ----------
  window.__RICHOS_MOCK__ = {
    // ---- the update path (RICH-TODOs row 12) ------------------------------------------
    /// Put the panel into a state, and optionally queue what the NEXT command returns.
    /// Emits `rich://update` as well as setting the value, because the real shell reaches
    /// the UI both ways and a suite must be able to prove the event path works on its own.
    updateSet(view, script) {
      mockUpdate.view = view;
      mockUpdate.script = Array.isArray(script) ? script.slice() : [];
      const subs = listeners["rich://update"];
      if (subs) subs.forEach((cb) => cb({ payload: { ...view } }));
      return { ...mockUpdate.view };
    },
    /// Which update commands the surface actually issued, in order. Asserting on this is
    /// how a suite proves the Restart button restarts rather than merely looking pressed.
    updateCalls() { return mockUpdate.calls.slice(); },
    /// Every `launch_state` read and every splash id handed to the recency ring, in order.
    /// The suite asserts against these rather than against a re-derived count — see the
    /// note over `launchCalls`.
    launchCalls() { return { splashShown: launchCalls.splashShown.slice(), stateReads: launchCalls.stateReads.slice() }; },
    // ---- techy mode, driven the way the CEO drives it and the way the OS breaks it -----
    /// Make one thread's machinery unreadable — a real `chmod 000` in the product, a set
    /// membership here. The point of the control is that "unreadable" must never be served
    /// as "empty", so a test needs to be able to produce it.
    breakMachinery(threadId) { machineryUnreadable.add(threadId); },
    healMachinery(threadId) { machineryUnreadable.delete(threadId); },
    /// Evict one row's Tier-B payload, the way `evict_raw` does — an unlink of the sibling.
    /// The normalized record is untouched, so the row still renders.
    evictRaw(machineryId) { machineryRaw.delete(machineryId); },
    techyState() { return { default: techyDefault, threads: Object.fromEntries(techyThreads) }; },
    TECHY_NOTHING_RECORDED,
    TECHY_NOT_RETAINED,
    TECHY_UNREADABLE,
    TECHY_RAW_NOT_RETAINED,
    TECHY_RAW_TRUNCATED,
    TECHY_BETWEEN_TURNS_QUIET,
    /// Empty ONE thread's between-turn lane, so a suite can drive the honest empty state on
    /// a thread that had traffic a moment ago — the state a CEO reaches by opening an older
    /// conversation, not a separate fixture pretending to be one.
    clearBetweenTurns(threadId) { betweenTurnsByThread.delete(threadId); },
    /// §26's `memory-strategy` scenario. See the block above it for what it refuses to do.
    memoryStrategy,
    /// Set the injected clock anchor BEFORE the CEO presses Enter. `Date.now() - 18600`
    /// puts the turn 18s past its lease handoff, so the row reads `Working for 18s` with
    /// no waiting and no patched `Date.now` — the renderer derives it from the timestamp,
    /// which is what §6.2 asks for.
    setMemoryStrategyAnchor(ms) { memoryStrategyAnchor = ms; },
    /// The driver for the scenario the CEO's send started, so a test can walk steps 3-16.
    activeMemoryStrategy() { return memoryScenario; },
    MEMORY_STRATEGY_STEPS,
    MEMORY_STRATEGY_ACTIVE_MS: MS_ACTIVE,
    MEMORY_STRATEGY_LEASE_MS: MS_LEASE_HANDOFF,
    MEMORY_STRATEGY_PROMPT: MEMORY_PROMPT,
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

    // ---- which company this copy of Rich works for ---------------------------------
    /// `null` is the LAUNCH STATE: no company chosen, so the app asks. It is what every
    /// double-clicked bundle is in until the CEO answers once, and it must be drivable
    /// here because a unit test could not produce it and a real Finder launch is not a
    /// browser fixture.
    setCompanyChosen(id) {
      chosenEntityId = id || null;
      chosenEntitySource = id ? "saved-choice" : null;
      if (!id) activeThreadId = null;
    },
    /// The operator's variant: `RICHOS_ENTITY` decided it, nothing in the window can move
    /// it, so the settings row renders a statement rather than a dead control.
    setCompanyPinnedByEnvironment(v) {
      entityPinnedByEnvironment = v !== false;
      if (entityPinnedByEnvironment) chosenEntitySource = "environment";
    },

    // ---- the two correction desks --------------------------------------------------
    /// `loro_available` / `spoken_corrections_available` are SEPARATE FACTS about one
    /// install, and each one false is an ordinary machine (no corpus, no service binary),
    /// not a fault. Driving them independently is how the surface's "state the reason"
    /// path gets exercised without deleting anything from disk.
    setLoroAvailable(v) { loroDeskOn = v !== false; },
    setSpokenCorrectionsAvailable(v) { spokenDeskOn = v !== false; },
    /// A desk that IS there and refuses to answer — a poisoned lock, an unreadable log.
    /// Different from the above and rendered differently, because this one has a retry.
    setLoroReadFailure(message) { loroReadFailure = message || null; },
    setSpokenReadFailure(message) { spokenReadFailure = message || null; },
    /// The writer refused the confirmed write (exit 5, "that is a PROSE section"). The
    /// proposal lands in `failed` with the reason kept, exactly as `correction.rs` does.
    setLoroWriterRefusal(message) { window.__RICHOS_MOCK__._loroWriterRefusal = message || null; },
    _loroWriterRefusal: null,
    /// `StagingError::NoVocabulary`: a confirm with no service configured, which must
    /// refuse loudly rather than report a term learned that nothing wrote.
    setNoVocabulary(v) { window.__RICHOS_MOCK__._noVocabulary = v === true; },
    _noVocabulary: false,
    /// `changed: false` — the vocabulary already knew the pair. A different fact from a
    /// refusal, and the CEO is entitled to both (`staging.rs:141-144`).
    setVocabularyAlreadyKnew(v) { window.__RICHOS_MOCK__._vocabularyAlreadyKnew = v === true; },
    _vocabularyAlreadyKnew: false,
    /// The staging trigger firing mid-turn — `TauriCorrectionEmitter` -> the webview.
    /// `withheld` carries the repeats that were NOT staged because the pair is suppressed;
    /// they are reported rather than dropped (`staging.rs`, `Withheld`).
    stageSpokenCorrection(candidate) {
      const c = Object.assign(
        {
          key: "loro|Loro",
          at: now(),
          threadId: activeThreadId,
          turnId: uid("turn"),
          utterance: "it's Loro, not loro",
          ask: { from: "loro", to: "Loro", key: "loro|Loro", frame: "pivot-first", orthographic: 0.8, phonetic: 1, leg: "both", anchor: null },
          declinedBefore: 0,
          prompt: 'Add "Loro" to your vocabulary?',
        },
        candidate || {}
      );
      if (spokenSuppressed.includes(c.key)) {
        emit("rich://correction-staged", { candidates: [], withheld: [{ key: c.key, from: c.ask.from, to: c.ask.to, reason: "permanently declined" }] });
        return null;
      }
      c.declinedBefore = declinedCounts[c.key] || 0;
      if (c.declinedBefore > 0) c.prompt = 'Add "' + c.ask.to + '" to your vocabulary? (you corrected this before)';
      candidates.push(c);
      emit("rich://correction-staged", { candidates: [c], withheld: [] });
      return c;
    },
    /// Replace the loro desk's proposals with EXACTLY these objects, byte for byte.
    ///
    /// The one seeding hook that does NOT compose anything, and that is the point: the
    /// browser suite feeds it `ui/tests/fixtures/loro-proposal.json`, which is the proposal
    /// `belief.rs` ACTUALLY files, checked against the Rust detector on every run by
    /// `belief_trigger_tests::the_ui_fixture_is_the_proposal_the_detector_really_files`. A
    /// hook that filled in its own `preview` — as `loro_propose_correction` does, because a
    /// composer would have to — would let the screenshot show a card the backend would
    /// never produce.
    seedLoroProposals(list) {
      proposals.length = 0;
      for (const p of list || []) proposals.push(p);
      proposalSeq = proposals.length + 1;
    },
    /// Read-only views, so a test can assert on the DESK rather than only on the DOM.
    correctionDeskState() {
      return {
        loroAvailable: loroDeskOn,
        spokenAvailable: spokenDeskOn,
        proposals: proposals.map((p) => ({ id: p.id, state: p.state })),
        candidates: candidates.map((c) => c.key),
        loroSuppressed: loroSuppressed.slice(),
        spokenSuppressed: spokenSuppressed.slice(),
        declinedCounts: Object.assign({}, declinedCounts),
      };
    },
    LORO_DESK_ABSENT,
    SPOKEN_DESK_ABSENT,

    // ---- the feedback channel --------------------------------------------------------
    /// The one file would not open. Every command then refuses with the backend's own
    /// sentence — a DIFFERENT fact from an empty history, and the surface must not collapse
    /// the two into one empty list.
    setFeedbackAvailable(v) { feedbackStoreOpen = v !== false; },
    /// The store IS there and a read refused. Transient, and it has a retry — the same
    /// distinction both correction desks draw.
    setFeedbackReadFailure(message) { feedbackReadFailure = message || null; },
    /// Answers already on this machine, byte for byte. Used by the browser suite to render
    /// entries that a cargo test wrote from the real types, so a screenshot cannot show a
    /// record shape the backend would never produce.
    seedFeedbackEntries(list) {
      feedbackEntries.length = 0;
      for (const e of list || []) feedbackEntries.push(e);
    },
    /// Read-only view, so a test can assert on the STORE rather than only on the DOM.
    feedbackStoreState() {
      return {
        available: feedbackStoreOpen,
        entries: feedbackEntries.map((e) => JSON.parse(JSON.stringify(e))),
      };
    },
    /// What this harness believes the product says. `feedback.js` joins every one of these
    /// to a fixture a cargo test regenerates from the live Rust constants.
    feedbackVocabulary() {
      return {
        question: FEEDBACK_QUESTION,
        options: FEEDBACK_OPTIONS,
        reportOffer: FEEDBACK_REPORT_OFFER,
        disclosureHeading: FEEDBACK_DISCLOSURE_HEADING,
        ratings: FEEDBACK_RATINGS.map((r) => ({ ...r })),
        failureClass: FEEDBACK_FAILURE_CLASS.map((t) => ({ ...t })),
        occurrences: FEEDBACK_OCCURRENCES.map((t) => ({ ...t })),
        diagnosis: FEEDBACK_DIAGNOSIS.map((t) => ({ ...t })),
        conditions: FEEDBACK_CONDITIONS.map((t) => ({ ...t })),
      };
    },
    FEEDBACK_STORE_ABSENT,
    FEEDBACK_PREVIEW_MISMATCH,
  };
})();
