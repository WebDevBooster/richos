// RichOS web UI — the v1 "talk to Rich" chat surface.
//
// Built to the design lead's v1 front-end UX direction.
// Consumes the streaming contract in app/STREAMING.md and the Tauri commands in
// app/src-tauri/src/main.rs. Deliberately dependency-free (no build step, no framework) —
// mirrors the runtime spine's own "thin surface" philosophy.
//
// Talks ONLY to `window.RichBridge` (never `window.__TAURI__` directly), so the exact same
// code path runs against the real Tauri shell and against `mock.js`'s dev harness.
"use strict";

// ---------------------------------------------------------------------------------------
// Bridge — real Tauri if present, else the mock harness already installed by mock.js.
// ---------------------------------------------------------------------------------------
if (!window.RichBridge) {
  const invoke = window.__TAURI__.core.invoke;
  const listen = window.__TAURI__.event.listen;
  window.RichBridge = {
    isMock: false,
    invoke: (cmd, args) => invoke(cmd, args),
    listen: (name, cb) => listen(name, cb),
  };
}
const Bridge = window.RichBridge;

// ---------------------------------------------------------------------------------------
// DOM refs
// ---------------------------------------------------------------------------------------
const el = (id) => document.getElementById(id);
const railEl = el("rail");
const railNavEl = el("rail-nav");
const railScrimEl = el("rail-scrim");
const railToggleBtn = el("rail-toggle");
const railDrawerCloseBtn = el("rail-drawer-close");
const railResizerEl = el("rail-resizer");
const railCompanyEl = el("rail-company");
const scopeEntityEl = el("scope-entity");
const scopeSepEl = el("scope-sep");
const scopeThreadEl = el("scope-thread");
const entityViewEl = el("entity-view");
const unboundViewEl = el("unbound-view");
const composerScopeEl = el("composer-scope");
const composerBlockedEl = el("composer-blocked");
const searchOverlayEl = el("search-overlay");
const searchInputEl = el("search-input");
const searchResultsEl = el("search-results");
const searchEmptyEl = el("search-empty");
const entityPickerEl = el("entity-picker");
const entityPickerListEl = el("entity-picker-list");
const threadMenuEl = el("thread-menu");
const messagesEl = el("messages");
const conversationEl = el("conversation");
const composerEl = el("composer");
const inputEl = el("input");
const sendBtn = el("send");
const stopBtn = el("stop");
const talkToggleBtn = el("talk-toggle");
const voicePanelEl = el("voice-panel");
const voiceListeningEl = el("voice-state-listening");
const voiceNoAudioEl = el("voice-state-no-audio");
const voiceSpeakingEl = el("voice-state-speaking");
const bargeInBtn = el("voice-barge-in");
const voiceRetryBtn = el("voice-retry");
const slideoverEl = el("slideover");
const slideoverBackdrop = el("slideover-backdrop");
const slideoverBody = el("slideover-body");
const jumpLatestBtn = el("jump-latest");
const liveRegionEl = el("live-region");
const drillChipEl = el("drill-chip-zone");
const settingsBtn = el("rail-settings");
const assertivenessPopover = el("assertiveness-popover");

// ---------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------
// NAVIGATION STATE (UX §3). `navTree` is the shape `navigation_tree` returns: entity
// groups whose threads were already placed by the ledger's immutable binding, plus a
// separate `unbound` list. The renderer NEVER re-buckets threads by entity id — that
// decision belongs to the authority that owns the binding, not to this file.
let navTree = { groups: [], unbound: [], active: null, unbound_explanation: "" };
// The AUTHORITATIVE scope, straight from `active_context` (person+entity+thread+revision).
// The header renders from this and not from `activeThreadId`, so a renderer bug can show
// the wrong thread but can never mislabel which entity the CEO is talking to.
let activeContext = null;
let navPrefs = null; // durable rail prefs (nav.rs): width, collapsed sets, pins, renames
let mainView = "conversation"; // "conversation" | "entity" | "unbound"
let viewEntityId = null; // the entity whose overview / new-thread screen is showing
let draftEntityId = null; // §3.3: a draft thread bound to this entity, with NO record yet
let sendBlockedReason = null; // §21: non-null means send is refused, with this reason
/// What the composer says when NOTHING is running (§9.1). Held as state because §9.2
/// replaces it with "Add context or steer Rich…" while Rich works, and the idle text is
/// view-dependent ("Talk to Rich about FemcBoost…" on an entity overview) — so it has to be
/// restored, not re-derived.
let idlePlaceholder = "Talk to Rich…";
const expandedEntities = new Set(); // entity ids whose "Show more" has been used
const drafts = new Map(); // threadId -> unsent composer text (§3.1)
const scrollTops = new Map(); // threadId -> conversation scrollTop (§3.1)
// threadId -> "working" | "unseen" | "failed". LIVE, per-thread, and only ever written
// from a positive `rich://` event — never inferred from silence, never from a timer.
const liveStatus = new Map();
// threadId -> "working" | "unseen" | "failed" for the RAIL only (see the live-status block
// at the bottom of this file). The conversation's own live state moved to the typed timeline
// model in `timeline.js` — one model, fed by the seven §13 events and the `get_timeline`
// snapshot, with `sessionLiveTurns` carrying what is running in threads that are not on
// screen.
let activeThreadId = null;
let voiceMode = false;
let drillItems = []; // populated from the real `get_worker_status` command — honest-empty
// until the engine has ever completed a task since boot (richos-core's worker_status.rs).
// The view's OWN authoritative counts (§7.3). Never re-derived from `drillItems`, and
// `needs_you` is deliberately absent: it is structurally 0 and there is no signal for it.
let workerCounts = { active: 0, livenessUnknown: 0 };

// COMPANY IDENTITY — the rail header per the UX direction §2.1 is "the company/CEO identity, not
// RichOS." Backed by `get_company_name` (main.rs, wired in init() below). This constant
// is now ONLY the client-side safety fallback if that invoke ever fails/rejects (e.g. the
// mock harness, which doesn't wire this command) — richos-core's config.rs carries the
// real, matching default ("My Company") for the live Tauri path, so the two can't drift.
const COMPANY_LABEL_FALLBACK = "My Company";

// ---------------------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------------------
function formatTime(ms) {
  return new Date(ms).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function timeGapMinutes(aMs, bMs) {
  return Math.abs(aMs - bMs) / 60000;
}

// ---------------------------------------------------------------------------------------
// LEFT NAVIGATION (UX §3)
//
// The rail is a stable hierarchy — entity areas, then their threads — not a flat list of
// every conversation (§3.1). Two rules shape everything below:
//
//   1. GROUPING IS NOT DONE HERE. `navigation_tree` (src-tauri/src/main.rs) returns threads
//      already inside their entity's group, resolved through `Ledger::thread_binding` — the
//      accessor that reads the immutable durable record. This file renders the groups it is
//      given. It never sorts a flat list into buckets by an entity id, because an entity is
//      a privacy boundary (§1) and a bucketing bug here would be a boundary violation with
//      nothing to catch it.
//
//   2. A STATUS GLYPH REQUIRES A LIVE SIGNAL. §22 names active worker count, worker waiting
//      state and completion state as things that must not be faked. Every mark this rail
//      can draw is listed in STATUS_MARKS below with the exact signal that produces it; the
//      §3.2 states with no signal in the build today (Queued, Waiting for CEO) are absent
//      rather than approximated.
// ---------------------------------------------------------------------------------------

/// How many threads an entity shows before "Show more" (§3.1: "An entity initially shows
/// only a bounded set of recent threads"). Revealing more happens IN PLACE — it never
/// navigates away or changes the selected thread.
const THREADS_SHOWN_INITIALLY = 6;

// EVERY mark the rail can draw, and the signal that earns it. Nothing is drawn from a
// timer, a heuristic, or the absence of activity.
//
//   working      rich://turn-started for this thread, until its terminal event.  LIVE
//   unseen       rich://turn-completed arrived while another thread was selected. LIVE
//   failed       rich://turn-error arrived while another thread was selected.     LIVE
//   interrupted  durable ledger: the thread's last CEO-visible turn is `interrupted`.
//   unknown      durable ledger: a turn is still `received`/`in_flight` on disk and no
//                live turn is running for it in this session — nobody knows how it ended.
//   unbound      the thread has no entity home at all (slice 1's quarantine state).
//
// NOT PRESENT, deliberately: §3.2's "Queued" hollow dot (the spine has a queue depth but
// no per-thread enqueue event, so a queued thread cannot be identified) and §3.2's
// "Waiting for CEO" attention mark (no waiting signal exists anywhere in the build yet —
// see §22 "worker waiting state" under Must not be faked).
const STATUS_MARKS = {
  working: { glyph: "◐", label: "working" },
  unseen: { glyph: "◆", label: "new result ready" },
  failed: { glyph: "△", label: "ended with an error" },
  interrupted: { glyph: "△", label: "last turn ended without finishing" },
  unknown: { glyph: "?", label: "outcome unknown — a turn never finished" },
  unbound: { glyph: "⊘", label: "no entity home" },
};

function allRows() {
  const rows = [];
  for (const g of navTree.groups) for (const t of g.threads) rows.push(t);
  for (const t of navTree.unbound) rows.push(t);
  return rows;
}

function threadRow(threadId) {
  return allRows().find((t) => t.id === threadId) || null;
}

function entityOf(entityId) {
  const g = navTree.groups.find((g) => g.entity.id === entityId);
  return g ? g.entity : null;
}

function entityLabel(entityId) {
  const e = entityOf(entityId);
  return e ? e.display_name : "No entity";
}

/// Status precedence: what is happening now beats what happened, which beats what is
/// merely unknown. Exactly one mark per row — §3.2 forbids stacking status with badges.
function statusFor(row) {
  const live = liveStatus.get(row.id);
  if (live) return live;
  if (!row.entity_id) return "unbound";
  if (row.last_turn_state === "interrupted") return "interrupted";
  if (row.has_pending_turn) return "unknown";
  return null;
}

function clearLiveMark(threadId) {
  const mark = liveStatus.get(threadId);
  // "working" is a fact about right now and is NOT cleared by looking at the thread; the
  // away-markers are, because they exist only to say "you haven't seen this yet".
  if (mark === "unseen" || mark === "failed") liveStatus.delete(threadId);
}

function isCollapsed(entityId) {
  return !!(navPrefs && navPrefs.collapsed_entities.includes(entityId));
}

function buildStatusMark(row) {
  const key = statusFor(row);
  if (!key) return null;
  const spec = STATUS_MARKS[key];
  const mark = document.createElement("span");
  mark.className = "nav-status nav-status--" + key;
  // Shape first, colour second: §18 requires status never rely on colour alone, and the
  // six glyphs above are visually distinct without it.
  mark.setAttribute("aria-hidden", "true");
  mark.textContent = spec.glyph;
  return { mark, label: spec.label };
}

function buildThreadRow(row, opts) {
  opts = opts || {};
  const li = document.createElement("li");
  li.className = "nav-thread-item";

  const wrap = document.createElement("div");
  wrap.className = "nav-thread-row" + (row.id === activeThreadId ? " is-active" : "");

  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "nav-thread";
  btn.dataset.threadId = row.id;

  const title = document.createElement("span");
  title.className = "nav-thread-title";
  title.textContent = row.display_title;
  btn.appendChild(title);

  // The accessible name carries entity, state and (in the Pinned group) which entity the
  // thread lives in — §18: "worker chips: buttons with name, role and state in accessible
  // label", and the same standard applies to a thread row.
  const parts = [row.display_title];
  if (opts.showEntity) parts.push("in " + entityLabel(row.entity_id));
  const status = buildStatusMark(row);
  if (status) {
    btn.appendChild(status.mark);
    parts.push(status.label);
  }
  if (row.archived) parts.push("archived");
  btn.setAttribute("aria-label", parts.join(", "));
  btn.title = row.display_title; // §3.1: full title in a tooltip when truncated
  if (row.id === activeThreadId) btn.setAttribute("aria-current", "true");

  if (opts.showEntity) {
    const tag = document.createElement("span");
    tag.className = "nav-thread-entity";
    tag.textContent = entityLabel(row.entity_id);
    tag.setAttribute("aria-hidden", "true");
    btn.appendChild(tag);
  }

  btn.addEventListener("click", () => openThread(row.id));
  wrap.appendChild(btn);

  const more = document.createElement("button");
  more.type = "button";
  more.className = "nav-thread-more";
  more.textContent = "⋯";
  more.setAttribute("aria-haspopup", "menu");
  more.setAttribute("aria-label", "Actions for " + row.display_title);
  more.addEventListener("click", (e) => {
    e.stopPropagation();
    openThreadMenu(row, more);
  });
  wrap.appendChild(more);

  // Keyboard parity with the pointer affordance (§18: all functions work by keyboard).
  wrap.addEventListener("keydown", (e) => {
    if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10")) {
      e.preventDefault();
      openThreadMenu(row, more);
    }
  });

  li.appendChild(wrap);
  return li;
}

function buildGroupShell(id, label, opts) {
  opts = opts || {};
  const section = document.createElement("section");
  section.className = "nav-group";
  section.setAttribute("role", "group");

  const head = document.createElement("div");
  head.className = "nav-group-head";

  const listId = "nav-list-" + id;
  const collapsed = opts.collapsible ? isCollapsed(id) : false;

  if (opts.collapsible) {
    const disc = document.createElement("button");
    disc.type = "button";
    disc.className = "nav-disclosure" + (collapsed ? " is-collapsed" : "");
    disc.textContent = "▾";
    disc.setAttribute("aria-expanded", String(!collapsed));
    disc.setAttribute("aria-controls", listId);
    disc.setAttribute("aria-label", (collapsed ? "Expand " : "Collapse ") + label);
    disc.addEventListener("click", () => toggleEntityCollapsed(id));
    head.appendChild(disc);
  }

  const labelEl = document.createElement(opts.onSelect ? "button" : "span");
  labelEl.className = "nav-group-label" + (opts.onSelect ? " is-selectable" : "");
  labelEl.id = "nav-label-" + id;
  labelEl.textContent = label;
  if (opts.onSelect) {
    labelEl.type = "button";
    // §3.1: selecting an entity LABEL opens its overview. It must not change the current
    // thread's scope, so this only changes what the main pane shows — `active_context`
    // is untouched until a thread is opened or a new one is started.
    labelEl.addEventListener("click", opts.onSelect);
    labelEl.setAttribute("aria-label", opts.selectLabel || label);
  }
  head.appendChild(labelEl);
  section.setAttribute("aria-labelledby", labelEl.id);

  if (typeof opts.count === "number") {
    const count = document.createElement("span");
    count.className = "nav-group-count";
    count.textContent = String(opts.count);
    count.setAttribute("aria-hidden", "true");
    head.appendChild(count);
  }

  if (opts.onAdd) {
    const add = document.createElement("button");
    add.type = "button";
    add.className = "nav-group-add";
    add.textContent = "+";
    add.setAttribute("aria-label", "New thread in " + label);
    add.addEventListener("click", opts.onAdd);
    head.appendChild(add);
  }

  section.appendChild(head);

  const list = document.createElement("ul");
  list.className = "nav-threads";
  list.id = listId;
  if (collapsed) list.hidden = true;
  section.appendChild(list);

  return { section, list };
}

function buildEntityGroup(group) {
  const entity = group.entity;
  const visible = group.threads.filter((t) => !t.archived && !t.pinned);
  const { section, list } = buildGroupShell(entity.id, entity.display_name, {
    collapsible: true,
    count: visible.length,
    onSelect: () => showEntityView(entity.id, "overview"),
    selectLabel: entity.display_name + " overview",
    onAdd: () => showEntityView(entity.id, "new"),
  });

  const expanded = expandedEntities.has(entity.id);
  const shown = expanded ? visible : visible.slice(0, THREADS_SHOWN_INITIALLY);
  for (const row of shown) list.appendChild(buildThreadRow(row));

  if (visible.length > shown.length) {
    const li = document.createElement("li");
    const more = document.createElement("button");
    more.type = "button";
    more.className = "nav-show-more";
    more.textContent = "Show more";
    more.setAttribute("aria-label", "Show " + (visible.length - shown.length) + " more threads in " + entity.display_name);
    // §3.1: reveals older threads IN PLACE, without navigating away or losing the
    // selected thread — so this only re-renders the rail.
    more.addEventListener("click", () => {
      expandedEntities.add(entity.id);
      renderRail();
    });
    li.appendChild(more);
    list.appendChild(li);
  }
  return section;
}

function buildPinnedGroup(rows) {
  const { section, list } = buildGroupShell("pinned", "Pinned", { count: rows.length });
  for (const row of rows) list.appendChild(buildThreadRow(row, { showEntity: true }));
  return section;
}

/// The pre-entity quarantine (slice 1's `ThreadEntity::Unbound`). Its own top-level group,
/// never folded into an entity: putting it under one would be exactly the guess slice 1
/// refused to make. The heading says what is wrong in the product's own vocabulary.
function buildUnboundGroup(rows) {
  const { section, list } = buildGroupShell("unbound", "Needs an entity", { count: rows.length });
  section.classList.add("nav-group--unbound");
  for (const row of rows) list.appendChild(buildThreadRow(row));
  return section;
}

function buildArchivedGroup(rows) {
  const { section, list } = buildGroupShell("archived", "Archived", {
    collapsible: true,
    count: rows.length,
  });
  section.classList.add("nav-group--archived");
  if (!isCollapsed("archived")) {
    for (const row of rows) list.appendChild(buildThreadRow(row, { showEntity: true }));
  }
  return section;
}

function renderRail() {
  railNavEl.innerHTML = "";

  const pinned = allRows().filter((t) => t.pinned && !t.archived);
  if (pinned.length) railNavEl.appendChild(buildPinnedGroup(pinned));

  // Every registered entity gets a row, INCLUDING one with zero threads — §3.1's
  // structure sketch shows `Prospects` as a bare row, and §21's "Empty entity" state only
  // exists if an empty entity is reachable.
  for (const group of navTree.groups) railNavEl.appendChild(buildEntityGroup(group));

  if (navTree.unbound.length) railNavEl.appendChild(buildUnboundGroup(navTree.unbound));

  const archived = allRows().filter((t) => t.archived);
  if (archived.length) railNavEl.appendChild(buildArchivedGroup(archived));
}

// ---- view switching --------------------------------------------------------------------

function setMainView(view) {
  mainView = view;
  conversationEl.hidden = view !== "conversation";
  entityViewEl.hidden = view !== "entity";
  unboundViewEl.hidden = view !== "unbound";
}

function showConversationView() {
  viewEntityId = null;
  draftEntityId = null;
  sendBlockedReason = null;
  composerBlockedEl.hidden = true;
  composerScopeEl.hidden = true;
  inputEl.disabled = false;
  idlePlaceholder = "Talk to Rich…";
  inputEl.placeholder = idlePlaceholder;
  sendBtn.disabled = false;
  setMainView("conversation");
  syncComposerMode();
  renderScopeHeader();
}

/// §21 "Entity binding failure", and the first UI anyone has built for it. Calm, in Rich's
/// register, send blocked, no stack trace. The explanation shown is the CORE's own wording
/// (`LedgerError::UnboundThread`, surfaced verbatim through `navigation_tree`), so the
/// screen and the guard that produced it can never drift apart.
function showUnboundView(row, rawError) {
  const title = row ? row.display_title : "This thread";
  el("unbound-view-title").textContent = title;
  el("unbound-view-body").textContent =
    "I can't open this one. It has no entity home — it predates entity scoping, and I won't guess " +
    "which entity this work belongs to. Filing it under the wrong one would mix up two companies' " +
    "records, and that's not a mistake worth risking to save you a question.";
  // WHO CHANGES THIS, AND WHAT HAPPENS NEXT. The old sentence ended at "Binding it is an
  // explicit operator decision and there is no control for it in the app yet" — true, and
  // useless to the man reading it: it named no party, offered no next step, and left him
  // on the one screen in the app with nothing to press. A state he cannot fix has to say
  // who can. "Operator" is not a word he uses, so it says who that is in his terms.
  el("unbound-view-detail").textContent =
    (navTree.unbound_explanation || rawError || "") +
    " Filing it under a company is a job for whoever set RichOS up — there is no control for" +
    " it in the app yet, so it will not sort itself out. Meanwhile the button above starts a" +
    " fresh thread wherever you say, and I'll carry on there.";
  sendBlockedReason = "This thread has no entity home, so I can't take a message in it.";
  composerBlockedEl.textContent = sendBlockedReason;
  composerBlockedEl.hidden = false;
  composerScopeEl.hidden = true;
  inputEl.disabled = true;
  // The placeholder is part of the block: an inviting "Talk to Rich…" above a dead field
  // is the composer telling a small lie about what it will do.
  idlePlaceholder = "Send is off for this thread";
  inputEl.placeholder = idlePlaceholder;
  sendBtn.disabled = true;
  setMainView("unbound");
  syncComposerMode();
  renderScopeHeader();
}

/// §3.5 entity overview, and §21's empty-entity and new-thread screens — one surface with
/// three honest variants, because they differ only in how much there is to show.
function showEntityView(entityId, mode) {
  const entity = entityOf(entityId);
  if (!entity) return;
  stashThreadViewState();
  viewEntityId = entityId;
  // A draft thread bound to this entity, with NO record persisted (§3.3). The record is
  // created on first send, inside `send()`.
  draftEntityId = entityId;
  sendBlockedReason = null;
  composerBlockedEl.hidden = true;
  inputEl.disabled = false;
  sendBtn.disabled = false;

  const group = navTree.groups.find((g) => g.entity.id === entityId);
  const threads = group ? group.threads.filter((t) => !t.archived) : [];

  el("entity-view-name").textContent = entity.display_name;
  el("entity-view-line").textContent =
    threads.length === 0
      ? "Nothing here yet. I'll keep work for " + entity.display_name + " in this area."
      : "Everything I'm holding for " + entity.display_name + " lives here.";

  const facts = el("entity-view-facts");
  facts.innerHTML = "";
  const addFact = (k, v) => {
    const dt = document.createElement("dt");
    dt.textContent = k;
    const dd = document.createElement("dd");
    dd.textContent = v;
    facts.appendChild(dt);
    facts.appendChild(dd);
  };
  addFact("Threads", String(threads.length));
  if (entity.roots && entity.roots.length) addFact("Source root", entity.roots.join(", "));

  // "Threads needing attention" — ONLY rows that carry a real mark. If nothing has a
  // signal, the block is absent rather than reassuringly empty.
  const attention = threads.filter((t) => statusFor(t));
  const attentionBlock = el("entity-view-attention");
  const attentionList = el("entity-view-attention-list");
  attentionList.innerHTML = "";
  attentionBlock.hidden = attention.length === 0;
  for (const row of attention) attentionList.appendChild(buildThreadRow(row));

  const threadBlock = el("entity-view-threads");
  const threadList = el("entity-view-thread-list");
  threadList.innerHTML = "";
  threadBlock.hidden = threads.length === 0 || mode === "new";
  for (const row of threads.slice(0, 8)) threadList.appendChild(buildThreadRow(row));

  // §3.5 also lists "current priorities from ECS" and §3.1's entity overflow lists
  // "Edit entity". Neither is rendered: there is no ECS priorities source wired into this
  // app, and the entity registry is `EntityRegistry::dogfood()` — hard-coded on purpose so
  // a missing or edited config file cannot silently move a privacy boundary. Saying so is
  // better than an empty panel that implies the data is merely missing today.
  // NAMES THE PARTY. It used to read "Priorities and entity editing aren't wired yet —
  // this area is defined in code, not settings." Every clause is true and every clause is
  // addressed to an engineer: "wired", "defined in code" and "settings" all describe a
  // place the CEO cannot go, and no sentence said whose job it was, so the note read as a
  // thing he might be expected to fix. This is a NEEDS-SOMEONE-ELSE state and it now says
  // who, and that there is nothing here for him.
  el("entity-view-note").textContent =
    "I can't show priorities for this area yet, and the area itself is set up inside RichOS " +
    "rather than in settings — whoever set RichOS up is the one who changes it. Nothing here " +
    "needs you.";

  composerScopeEl.textContent =
    (mode === "new" ? "New thread in " : "Talk to Rich about ") + entity.display_name;
  composerScopeEl.hidden = false;
  idlePlaceholder = "Talk to Rich about " + entity.display_name + "…";
  inputEl.placeholder = idlePlaceholder;
  inputEl.value = drafts.get(ENTITY_DRAFT_PREFIX + entityId) || "";
  autoGrow();

  setMainView("entity");
  renderScopeHeader();
  renderRail();
  inputEl.focus();
}

/// The sticky scope header (§4): the entity and thread every subsequent send runs under.
/// Read from `activeContext` (the binding) whenever one exists, so the header states what
/// the SPINE thinks the scope is rather than what this file believes it selected.
function renderScopeHeader() {
  if (mainView === "entity" && viewEntityId) {
    scopeEntityEl.textContent = entityLabel(viewEntityId);
    scopeSepEl.hidden = false;
    scopeThreadEl.textContent = "New thread";
    return;
  }
  if (mainView === "unbound") {
    const row = threadRow(activeThreadId);
    scopeEntityEl.textContent = "No entity";
    scopeSepEl.hidden = false;
    scopeThreadEl.textContent = row ? row.display_title : "";
    return;
  }
  if (!activeContext) {
    scopeEntityEl.textContent = "";
    scopeSepEl.hidden = true;
    scopeThreadEl.textContent = "";
    return;
  }
  const row = threadRow(activeContext.thread_id);
  scopeEntityEl.textContent = entityLabel(activeContext.entity_id);
  scopeSepEl.hidden = false;
  scopeThreadEl.textContent = row ? row.display_title : "";
}

// ---- per-thread draft and scroll (§3.1) -------------------------------------------------

/// Park whatever is in the composer against the thing it was being written TO, then the
/// caller is free to load something else into it.
///
/// The entity case is not a nicety. An entity is a privacy boundary (§1), and leaving a
/// half-written sentence from one entity's thread sitting in another entity's composer
/// means one Enter files it in the wrong company. So the composer is emptied on every
/// move and only ever re-filled from the draft belonging to what is now on screen.
function stashThreadViewState() {
  if (mainView === "conversation" && activeThreadId) {
    drafts.set(activeThreadId, inputEl.value);
    scrollTops.set(activeThreadId, conversationEl.scrollTop);
  } else if (mainView === "entity" && viewEntityId) {
    drafts.set(ENTITY_DRAFT_PREFIX + viewEntityId, inputEl.value);
  }
  inputEl.value = "";
  autoGrow();
}

/// Namespace for a draft that belongs to an ENTITY's new-thread composer rather than to a
/// thread. Prefixed so it can never collide with a thread id.
const ENTITY_DRAFT_PREFIX = "entity:";

function restoreThreadViewState(threadId) {
  inputEl.value = drafts.get(threadId) || "";
  autoGrow();
  const top = scrollTops.get(threadId);
  // §15: "preserve each thread's scroll position during thread switching". A thread that
  // has never been opened lands at the bottom — the newest turn.
  if (typeof top === "number") {
    conversationEl.scrollTop = top;
    followBottom = atBottom();
  } else {
    followBottom = true;
  }
  updateJumpButton();
}

// ---- opening a thread ------------------------------------------------------------------

async function openThread(threadId) {
  const row = threadRow(threadId);
  if (!row) return;
  if (threadId === activeThreadId && mainView === "conversation") return;

  stashThreadViewState();
  clearLiveMark(threadId);
  activeThreadId = threadId;
  drillItems = [];
  // A fresh model per thread. `sessionLiveTurns` (not this model) remembers what is running
  // where, so nothing about the previous thread's live turn leaks into this one and nothing
  // about THIS thread's live turn is forgotten by having left it.
  timelineModel = window.RichTimeline.createModel();
  renderDrillChip();
  closeSlideOver();
  closeThreadMenu();
  // The pane is about a worker in the thread being LEFT. Carrying it across would put one
  // entity's worker beside another entity's conversation — the exact shape of leak every
  // guard in this build exists to stop.
  closeWorkerInspector();
  if (isNarrow()) setRailOpen(false);

  if (!row.entity_id) {
    // A pre-entity thread is never activated: `Spine::switch_thread` would refuse it
    // anyway (an unbound thread cannot become the active context), and asking would put
    // an error in the log for a state we can already see. Render the calm state instead.
    activeContext = null;
    showUnboundView(row);
    renderRail();
    return;
  }

  try {
    await Bridge.invoke("switch_thread", { threadId });
  } catch (e) {
    showUnboundView(row, String(e));
    renderRail();
    return;
  }

  await refreshActiveContext();
  showConversationView();
  inputEl.placeholder = "Talk to Rich…";
  renderRail();
  // The fence comes from the AUTHORITATIVE binding, not from this file's idea of what is
  // selected: `bindingRevision` is the activation revision, and every live event is measured
  // against it as a STALENESS floor (never an equality key — see `accepts()` in timeline.js).
  window.RichTimeline.bind(
    timelineModel,
    activeContext ? activeContext.entity_id : row.entity_id,
    threadId,
    activeContext ? activeContext.binding_revision : row.binding_revision
  );
  await loadTimeline();
  if (mainView !== "conversation") return; // loadTimeline fell into the unbound state
  restoreThreadViewState(threadId);
  // Returning to a thread whose turn is still streaming picks its live state back up (§2:
  // "return to a running thread without losing its live state") — `loadTimeline` already
  // called `reviveLiveTurns()`, so the duration row resumes ticking from the real
  // `startedAt` rather than restarting or reading `Status unavailable`.
}

/// §3.3 global entry point. The picker ALWAYS opens, even when an entity is already in
/// view: §21 says "Never default to the last entity", and one keystroke is a cheap price
/// for never filing the CEO's first sentence somewhere he did not choose.
function startNewThreadFlow() {
  openEntityPicker((entityId) => showEntityView(entityId, "new"));
}

/// §3.3 step 4: a provisional title from the first message, replaced later by a concise
/// outcome title when Rich supplies one (no such backend signal exists yet — when one
/// lands, it replaces this, and the ledger title is the thing it should replace).
function provisionalTitle(text) {
  const firstLine = text.split("\n")[0].trim();
  return firstLine.length > 48 ? firstLine.slice(0, 47).trimEnd() + "…" : firstLine || "New thread";
}

async function refreshNavigation() {
  try {
    navTree = await Bridge.invoke("navigation_tree");
  } catch (_e) {
    navTree = { groups: [], unbound: [], active: null, unbound_explanation: "" };
  }
  if (navTree.active) activeContext = navTree.active;
  renderRail();
  renderScopeHeader();
}

async function refreshActiveContext() {
  try {
    activeContext = await Bridge.invoke("active_context");
  } catch (_e) {
    activeContext = null;
  }
  renderScopeHeader();
}

// ---------------------------------------------------------------------------------------
// THE CONVERSATION TIMELINE (§5, §6, §15) — slice 5 of §24
//
// The render moved out of this file into `timeline.js`, which owns the model and the DOM.
// What stays here is the WIRING: the two sources that feed the model, and the four
// non-timeline concerns (rail marks, voice, drill chip, proactive) that were already here.
//
// TWO SOURCES, ONE MODEL, SAME ITEM IDS:
//
//   1. `get_timeline` — the durable snapshot (§14 step 2). Gated in Rust by
//      `Timeline::view(ViewMode::Ceo)`, which REMOVES technical items and technical detail
//      rather than masking them, so this file is never handed a raw command to leak.
//   2. the seven additive `rich://` events (app/STREAMING.md). Every payload carries the ECS
//      fence and a `visibility` that is always `"ceo"` on this family.
//
// The four original events (`turn-started` / `chunk` / `turn-completed` / `turn-error`) are
// STILL SUBSCRIBED but no longer render the conversation. They keep exactly the two jobs
// the typed family does not cover: the rail's per-thread live marks (§3.2's `unseen` needs
// a "completed while you were elsewhere" signal that `thread-summary-updated` deliberately
// does not emit) and the reconciliation reload at turn end. Rendering from both families
// would draw Rich's reply twice.
// ---------------------------------------------------------------------------------------

/// The model for the SELECTED thread. One thread, one model: a background thread's live
/// state is tracked in `sessionLiveTurns` below and revived when it is opened.
let timelineModel = window.RichTimeline.createModel();
/// CEO messages the CEO has expanded past §5.1's line clamp. Survives re-render.
const expandedMessages = new Set();
let sessionAvatarShown = false; // the Rich Hand mark shows once per session, on his first line
let renderPending = false; // rAF coalescing (§15: "at most once per animation frame")
const proseDirty = new Set(); // message ids whose text changed since the last flush
let timerHandle = null;

/// TURNS THAT ARE LIVE IN THIS SESSION, across every thread.
///
/// This is the only thing that distinguishes "a turn that is running right now" from "a
/// turn that was `in_flight` on disk when RichOS last closed" — the durable record looks
/// identical for both, and §14 forbids guessing ("Never infer that a turn completed because
/// the app was closed"). Written ONLY from a positive `rich://turn-status` event; nothing
/// here is started, cleared or aged by a timer.
const sessionLiveTurns = new Map(); // turnId -> { threadId, startedAt }

/// Re-apply this session's knowledge of what is running on top of a fresh snapshot.
/// Without it, switching away from a working thread and back would show its live turn as
/// `Status unavailable` — technically the honest read of the durable record alone, but a
/// lie in a session that is watching the turn stream.
function reviveLiveTurns() {
  for (const [turnId, live] of sessionLiveTurns) {
    if (live.threadId !== timelineModel.threadId) continue;
    const t = timelineModel.turns.get(turnId);
    if (!t) continue;
    if (t.status === "completed" || t.status === "interrupted") continue;
    t.live = true;
    if (typeof live.startedAt === "number") t.startedAt = live.startedAt;
  }
}

// ---- scroll (§15) ----------------------------------------------------------------------

const STUCK_TO_BOTTOM_PX = 48;
let followBottom = true;

function atBottom() {
  return conversationEl.scrollHeight - conversationEl.scrollTop - conversationEl.clientHeight <= STUCK_TO_BOTTOM_PX;
}

function scrollToBottom() {
  conversationEl.scrollTop = conversationEl.scrollHeight;
  followBottom = true;
  updateJumpButton();
}

/// §15: "Render `Jump to latest` as a small circular down-arrow centered just above the
/// composer. Keep it visible while the viewport is detached from the bottom." Activating it
/// scrolls to the latest MEANINGFUL item, not merely the last pixel — so it lands on the
/// last turn's top edge when that turn is taller than the viewport, and on the bottom
/// otherwise.
function updateJumpButton() {
  jumpLatestBtn.hidden = followBottom || atBottom();
}

function jumpToLatest() {
  const sections = messagesEl.querySelectorAll(".tl-turn");
  const last = sections[sections.length - 1];
  followBottom = true;
  if (last && last.offsetHeight > conversationEl.clientHeight) {
    conversationEl.scrollTop = last.offsetTop - 24;
  } else {
    conversationEl.scrollTop = conversationEl.scrollHeight;
  }
  updateJumpButton();
}

conversationEl.addEventListener("scroll", () => {
  // §15: "while the user is at the bottom, follow streaming content; when the user scrolls
  // up, stop auto-following."
  followBottom = atBottom();
  updateJumpButton();
});

// ---- announcements (§18) ----------------------------------------------------------------
//
// The timeline itself is `aria-live="off"`. §18 requires CONTROLLED announcements — "do not
// announce every timer tick", "announce meaningful commentary when it COMPLETES, not every
// token" — and a live region wrapped around streaming text does the opposite of all of
// them. So announcements go through this one polite region, deliberately and one at a time.
function announce(text) {
  if (!text) return;
  liveRegionEl.textContent = "";
  // A same-text write is not re-announced by every screen reader; the reflow forces it.
  window.requestAnimationFrame(() => {
    liveRegionEl.textContent = text;
  });
}

// ---- the render loop ---------------------------------------------------------------------

/// A STRUCTURAL change: a new item, a snapshot, a collapse toggle. Coalesced to one frame.
function scheduleRender() {
  if (renderPending) return;
  renderPending = true;
  window.requestAnimationFrame(flushRender);
}

/// A TEXT-ONLY change: one streamed message grew. Never rebuilds, never moves focus.
let proseFlushPending = false;
function scheduleProse(messageId) {
  proseDirty.add(messageId);
  if (proseFlushPending || renderPending) return;
  proseFlushPending = true;
  window.requestAnimationFrame(() => {
    proseFlushPending = false;
    for (const id of proseDirty) {
      const item = timelineModel.items.get(id);
      if (!item) continue;
      // If the node is not mounted yet, fall back to a full render — which will pick the
      // accumulated text up, because the model already holds it.
      if (!window.RichTimeline.updateProse(messagesEl, id, item.text, item.closed)) {
        scheduleRender();
        break;
      }
    }
    proseDirty.clear();
    if (followBottom) conversationEl.scrollTop = conversationEl.scrollHeight;
  });
}

function flushRender() {
  renderPending = false;
  proseDirty.clear();
  if (mainView !== "conversation") return;

  // §15: "preserve viewport position when activity above collapses", and §18: "focus
  // remains stable during streaming and collapse transitions".
  const focusId = document.activeElement && document.activeElement.id;
  const anchorTop = conversationEl.scrollTop;
  const anchorHeight = conversationEl.scrollHeight;

  const turns = window.RichTimeline.render(timelineModel, messagesEl, {
    now: Date.now(),
    expandedMessages,
    avatarAlreadyShown: sessionAvatarShown,
    // §6.4 has TWO defaults for this control — expanded while the turn is active,
    // collapsed after it settles — and the CEO's own choice overrules both. All three
    // live in `RichTimeline.isTurnExpanded`, never in a set lookup here.
    isExpanded: (turnId) => window.RichTimeline.isTurnExpanded(timelineModel, turnId),
    toggle: toggleWorkTranscript,
    rerender: scheduleRender,
    copy: copyToClipboard,
    retry: retryTurn,
    // §7.2: selecting a chip opens the read-only inspector. The renderer only makes the
    // chip a button when this exists, so a build without the pane never draws a control
    // that does nothing.
    openWorker: openWorkerInspector,
  });
  // The DOM was just rebuilt; re-mark the open worker's chip.
  markSelectedChip();
  if (turns.some((t) => t.stream.some((i) => i.kind === "rich_message"))) sessionAvatarShown = true;

  if (timelineModel.items.size === 0 && timelineModel.turnOrder.length === 0) renderFirstRun();

  if (focusId) {
    const again = messagesEl.querySelector('[id="' + focusId.replace(/(["\\])/g, "\\$1") + '"]');
    if (again) again.focus({ preventScroll: true });
  }

  if (followBottom) {
    conversationEl.scrollTop = conversationEl.scrollHeight;
  } else {
    // Keep the same content under the CEO's eye when something above changed height.
    conversationEl.scrollTop = anchorTop + (conversationEl.scrollHeight - anchorHeight);
  }
  updateJumpButton();
  startOrStopTimer();
}

/// §6.2: "The active label updates once per second… When the window is backgrounded, stop
/// animation ticks. Recompute from timestamps when it becomes visible again."
///
/// One interval for the whole timeline, and it exists ONLY while something is live — an
/// idle thread runs no timer at all.
function startOrStopTimer() {
  let anyLive = false;
  for (const t of timelineModel.turns.values()) if (t.live) anyLive = true;
  if (anyLive && !timerHandle && !document.hidden) {
    timerHandle = window.setInterval(() => {
      window.RichTimeline.updateTimers(timelineModel, messagesEl, Date.now());
    }, 1000);
  } else if ((!anyLive || document.hidden) && timerHandle) {
    window.clearInterval(timerHandle);
    timerHandle = null;
  }
}

document.addEventListener("visibilitychange", () => {
  // Recompute from timestamps the instant we are visible again — the display was DERIVED
  // from `startedAt`, never accumulated, so nothing was lost by not ticking.
  if (!document.hidden) window.RichTimeline.updateTimers(timelineModel, messagesEl, Date.now());
  startOrStopTimer();
});

function toggleWorkTranscript(turnId) {
  // Both directions are recorded EXPLICITLY (`expanded` / `collapsed`) rather than as the
  // presence or absence of one flag, because §6.4's default is different while the turn is
  // running: without a positive record of "the CEO closed this", a mid-turn collapse would
  // be re-opened by the live default on the very next render. `toggleTurn` also marks the
  // turn settled, so a deliberate open survives the post-completion collapse.
  window.RichTimeline.toggleTurn(timelineModel, turnId);
  scheduleRender();
}

async function copyToClipboard(text, button) {
  try {
    await navigator.clipboard.writeText(text);
    const was = button.textContent;
    button.textContent = "Copied";
    window.setTimeout(() => {
      button.textContent = was;
    }, 1200);
  } catch (_e) {
    /* a refused clipboard is not worth an error state */
  }
}

/// §21 "Turn failure": "Start a new turn with the existing context". The CEO's original
/// words are put back in the composer rather than resent silently — resending is an action
/// with side effects, and it is his to take.
function retryTurn(turn) {
  if (turn.user && turn.user.text) {
    inputEl.value = turn.user.text;
    autoGrow();
  }
  inputEl.focus();
}

function renderFirstRun() {
  // Authored, in Rich's voice — never a blank screen. Client-side only.
  messagesEl.innerHTML = "";
  const art = document.createElement("article");
  art.className = "tl-rich";
  const sr = document.createElement("span");
  sr.className = "sr-only";
  sr.textContent = "Rich said";
  art.appendChild(sr);
  const meta = document.createElement("div");
  meta.className = "tl-rich-meta";
  const avatar = document.createElement("img");
  avatar.className = "tl-avatar";
  avatar.src = "assets/rich-hand.png";
  avatar.alt = "";
  meta.appendChild(avatar);
  const who = document.createElement("span");
  who.className = "tl-who";
  who.textContent = "Rich";
  meta.appendChild(who);
  art.appendChild(meta);
  const body = document.createElement("div");
  body.className = "tl-prose";
  body.textContent =
    "I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from there. You can type, or tap ◉ to talk to me.";
  art.appendChild(body);
  messagesEl.appendChild(art);
  sessionAvatarShown = true;
}

/// The reload path. Fails closed exactly like `get_messages` did: an unbound thread refuses
/// rather than returning an empty conversation, and the calm §21 screen takes over.
async function loadTimeline() {
  let snapshot;
  try {
    snapshot = await Bridge.invoke("get_timeline", { threadId: activeThreadId });
  } catch (e) {
    const msg = String(e);
    // The mock harness leaves some commands unwired; a genuine scope refusal is a different
    // statement and gets the §21 screen.
    window.RichTimeline.applySnapshot(timelineModel, { items: [] });
    if (msg.startsWith("mock: no such command")) {
      scheduleRender();
      return;
    }
    showUnboundView(threadRow(activeThreadId), msg);
    return;
  }
  window.RichTimeline.applySnapshot(timelineModel, snapshot);
  reviveLiveTurns();
  scheduleRender();
}

// ---------------------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------------------
async function send() {
  const text = inputEl.value.trim();
  if (!text) return;
  // §9.2: "The composer remains enabled. This is essential. Long work should not trap the
  // CEO in a passive state." Until this slice the line here read `if (anyLiveTurn()) return;`
  // — an honest refusal, because the spine's mutex is held for the whole turn and there was
  // nowhere durable to put the words. There is now (`steering.rs`), so they go there.
  if (anyLiveTurn()) return steer(text);
  // §21 "Entity binding failure": BLOCK SEND and state why. Never quietly file the CEO's
  // words somewhere Rich guessed.
  if (sendBlockedReason) {
    composerBlockedEl.textContent = sendBlockedReason;
    composerBlockedEl.hidden = false;
    return;
  }
  inputEl.value = "";
  autoGrow();

  // §3.3 first send in a draft thread: NOTHING was persisted when the CEO opened the
  // new-thread screen. The record is created here, with its immutable entity_id, before the
  // message goes anywhere — step 1 then step 2 of §3.3, in that order.
  if (draftEntityId) {
    const entityId = draftEntityId;
    let newId;
    try {
      newId = await Bridge.invoke("create_thread_in", { entityId, title: provisionalTitle(text) });
    } catch (e) {
      // WAS: `composerBlockedEl.textContent = String(e)` — a raw Rust error string dropped
      // straight under the composer. Whatever `create_thread_in` refused with is machinery
      // ("scope mismatch on thread …", "stale binding on thread …"), and §21's own rule for
      // this class is that the reason is not shown (timeline.js `renderFailureCard`:
      // "`cognition io: broken pipe` is implementation machinery"). The words were already
      // put back in the box, which was the right half; the sentence never said so, and never
      // named the control that sends them.
      composerBlockedEl.textContent =
        "I couldn't start that thread just now. Your words are still in the box below —" +
        " press Send to try again.";
      composerBlockedEl.hidden = false;
      inputEl.value = text; // never swallow the CEO's words
      autoGrow();
      return;
    }
    drafts.delete(ENTITY_DRAFT_PREFIX + entityId);
    draftEntityId = null;
    await refreshNavigation();
    await openThread(newId);
  }

  // §25: "The submitted message renders immediately on the right in a quiet highlighted
  // surface." It carries a synthetic id until `rich://turn-status` names the turn, then it
  // is RE-KEYED onto `{turnId}:user` — the same id the ledger derives — so the CEO's one
  // sentence is never drawn twice.
  const pendingId = window.RichTimeline.addPendingUserMessage(timelineModel, text, Date.now());
  followBottom = true;
  scheduleRender();

  try {
    await Bridge.invoke("send_message", { text });
  } catch (e) {
    // An outright rejection BEFORE any turn started (no lease ⇒ no stream events will ever
    // fire for this attempt). A turn that started and then failed is resolved by
    // `rich://turn-status: failed`, not here.
    if (anyLiveTurn()) return;

    // WHAT THIS USED TO DO, AND WHY IT WAS THE WORST STATE IN THE APP. It said
    // "Something went sideways on my end — one moment, I'll sort it." and then left the
    // optimistic bubble on screen. Two lies in one row: nothing was going to sort it (no
    // turn exists, so no retry, no timer, no event will ever fire for this attempt), and
    // the bubble sat there looking exactly like a message that had gone. The CEO's only
    // correct move — send it again — was the one thing neither the copy nor the screen
    // offered, and his words were no longer in the box to send.
    //
    // So the bubble is WITHDRAWN, the words go back where he can see and edit them, and
    // the sentence names the control: Send. This is the same shape `steer()` below has
    // used since §9.2 landed; there is no reason the two paths should differ.
    //
    // THE BACKEND'S OWN SENTENCE IS KEPT WHERE THERE IS ONE, and kept FIRST. `send_message`
    // has exactly one authored refusal today — "I'm not connected to my thinking right now"
    // (main.rs:199) — and it is a different statement from a generic failure, with a
    // different thing for the CEO to do about it. Swallowing it for one house sentence
    // would delete the only diagnosis the app has. What is added is the half it never
    // carried: what happened to his words, and which control sends them again.
    window.RichTimeline.dropPendingUserMessage(timelineModel, pendingId);
    const reason = typeof e === "string" && e.trim() ? e.trim().replace(/\s*$/, "") : null;
    window.RichTimeline.addLocalNotice(
      timelineModel,
      (reason || "I couldn't get that to my desk just now, and nothing is running.") +
        " Your words are back in the box below, word for word — press Send when you want me" +
        " to try again.",
      Date.now()
    );
    inputEl.value = text; // never swallow the CEO's words
    autoGrow();
    syncComposerMode();
    scheduleRender();
  }
}

/// §9.2 — the CEO added words while Rich was working.
///
/// WHAT THIS DOES AND DOES NOT DO, because the difference is the whole honesty of the
/// feature. §25 asks that "a steering message joins the active turn in durable order".
/// What actually happens: the words are fsync'd to the intake log before this call returns,
/// they are ordered by that log, and they reach Rich at the next turn boundary. They do NOT
/// join the running ACP turn — ACP runs one `session/prompt` at a time, and the continuity
/// design's turn-boundary controller is queue-not-interrupt by construction (§3.1).
///
/// So the UI never implies the message landed mid-thought. The bubble goes up with the
/// §9.2 cue and nothing else is claimed: no "Rich is reading this", no re-ordering of the
/// running turn's rows.
async function steer(text) {
  inputEl.value = "";
  autoGrow();
  window.RichTimeline.addPendingUserMessage(timelineModel, text, Date.now());
  followBottom = true;
  scheduleRender();
  try {
    await Bridge.invoke("steer_message", { text });
  } catch (e) {
    // The words are NEVER swallowed. If the intake refused them they go back in the
    // composer, where the CEO can see them and decide.
    window.RichTimeline.addLocalNotice(
      timelineModel,
      "I couldn't take that down while I was working — it's back in the box below, nothing lost.",
      Date.now()
    );
    inputEl.value = text;
    autoGrow();
    scheduleRender();
  }
}

/// §9.3 — stop.
///
/// The command persists the request and then interrupts, in that order, and does not answer
/// until the request is on disk. So setting `stopping` from its RETURN is a statement of
/// durable fact, not an optimistic guess: by then "you asked me to stop" is true whatever
/// happens next. The authoritative terminal arrives as `rich://turn-status: stopped`.
///
/// `stopped: false` means nothing was running. Nothing is said and nothing changes — a
/// button that announces it did something when it did not is worse than one that stays
/// quiet.
async function stopTurn() {
  if (stopBtn.disabled) return;
  stopBtn.disabled = true;
  try {
    const report = await Bridge.invoke("stop_turn");
    if (!report || !report.stopped) return;
    if (window.RichTimeline.markStopping(timelineModel, report.turnId)) scheduleRender();
    announce("Stopping.");
    // REPORTED, NOT HIDDEN. The request is durable and the turn will be recorded as
    // stopped either way, but nothing was there to interrupt it — so the work may still run
    // to its natural end, and saying "stopped" flatly would be a claim about the lease that
    // this app cannot make.
    if (report.reachedLease === false) {
      window.RichTimeline.addLocalNotice(
        timelineModel,
        "I've noted that you stopped this. I couldn't interrupt the work already in flight, " +
          "so it may finish on its own — nothing new will start.",
        Date.now()
      );
      scheduleRender();
    }
  } catch (e) {
    // NAMES THE CONTROL. The old sentence stopped at "so I haven't acted on it" — true,
    // and it left the CEO with a fact and no instruction while the button that would fix
    // it sat three inches below, unmentioned. `syncComposerMode()` in the `finally` below
    // re-enables Stop before this is read, and Stop is visible for as long as the turn is
    // live, so the sentence names something that is on screen at the moment it is read.
    window.RichTimeline.addLocalNotice(
      timelineModel,
      typeof e === "string"
        ? e + " Press Stop again and I'll have another go."
        : "I couldn't record that stop, so I haven't acted on it. Press Stop again and I'll have another go.",
      Date.now()
    );
    scheduleRender();
  } finally {
    syncComposerMode();
  }
}

function anyLiveTurn() {
  for (const t of timelineModel.turns.values()) if (t.live) return true;
  return false;
}

function anyStoppingTurn() {
  for (const t of timelineModel.turns.values()) if (t.status === "stopping") return true;
  return false;
}

/// §9.1 vs §9.2 — the composer has two modes and this is the only place that decides which.
///
/// Idle:     placeholder "Talk to Rich…", send visible, no stop.
/// Working:  placeholder "Add context or steer Rich…", and per §9.2 "a stop button replaces
///           or sits beside send when the composer is empty" — empty composer shows stop in
///           place of send, a composer with words in it shows both, so the CEO never has to
///           choose between sending what he typed and stopping.
/// Stopping: §11 says "Composer disabled briefly". Only the CONTROLS are disabled; the text
///           field stays editable, because taking the keyboard away mid-sentence would lose
///           whatever he was in the middle of typing.
function syncComposerMode() {
  if (mainView !== "conversation" || sendBlockedReason) {
    stopBtn.hidden = true;
    return;
  }
  const working = anyLiveTurn();
  const stopping = anyStoppingTurn();
  const empty = inputEl.value.trim().length === 0;

  inputEl.placeholder = working ? "Add context or steer Rich…" : idlePlaceholder;

  stopBtn.hidden = !working;
  stopBtn.disabled = stopping;
  sendBtn.hidden = working && empty;
  sendBtn.disabled = stopping;
  el("composer-row").dataset.mode = stopping ? "stopping" : working ? "working" : "idle";
}

/// A READ-ONLY handle on the timeline model, for the acceptance harness and for anyone
/// debugging a render against a live shell. It exposes nothing the DOM does not already
/// carry — the model IS the CEO view, gated in Rust before it ever reached this file — so
/// it cannot be a leak path. It is a getter, not the object, so nothing can be swapped
/// underneath the renderer through it.
window.__RICHOS_TIMELINE__ = () => timelineModel;

composerEl.addEventListener("submit", (e) => {
  e.preventDefault();
  send();
});
inputEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});

// Auto-growing single field — a few lines, then it scrolls; never dominates.
function autoGrow() {
  inputEl.style.height = "auto";
  const max = 5 * 22; // ~5 lines
  inputEl.style.height = Math.min(inputEl.scrollHeight, max) + "px";
}
inputEl.addEventListener("input", () => {
  autoGrow();
  // §9.2's "replaces or sits beside send when the composer is empty" is a function of what
  // is in the box, so it is re-evaluated as he types.
  syncComposerMode();
});

stopBtn.addEventListener("click", (e) => {
  e.preventDefault();
  stopTurn();
});

el("rail-new-thread").addEventListener("click", startNewThreadFlow);
// §21's way out of the unbound screen — the SAME §3.3 flow the rail's button runs, not a
// second one. The picker always opens, so this never guesses an entity either.
el("unbound-new-thread").addEventListener("click", startNewThreadFlow);
el("nav-search").addEventListener("click", openSearch);
jumpLatestBtn.addEventListener("click", jumpToLatest);

// ---------------------------------------------------------------------------------------
// THE ADDITIVE §13 FAMILY — the seven events that drive the timeline
// (app/STREAMING.md "The additive live-work family")
//
// Every handler returns `{ structural, rejected, textOnly }`; this layer only decides
// whether to rebuild, to write one text node, or to do nothing. The fence, the visibility
// gate, the idempotent upsert and the supersession merge all live in `timeline.js`.
// ---------------------------------------------------------------------------------------
Bridge.listen("rich://turn-status", ({ payload }) => {
  // Session-wide first, so a BACKGROUND thread's live turn is remembered and revived when
  // the CEO opens it (§2: "return to a running thread without losing its live state").
  if (payload.status === "queued" || payload.status === "working" || payload.status === "recovering") {
    const prev = sessionLiveTurns.get(payload.turnId);
    sessionLiveTurns.set(payload.turnId, {
      threadId: payload.threadId,
      startedAt: typeof payload.startedAt === "number" ? payload.startedAt : prev && prev.startedAt,
    });
  } else {
    sessionLiveTurns.delete(payload.turnId);
  }
  // The MERGE INSTRUCTION also has to reach the session registry, or a crashed turn would
  // stay "live" forever in a thread nobody is looking at.
  if (payload.supersedesTurnId) sessionLiveTurns.delete(payload.supersedesTurnId);

  const r = window.RichTimeline.onTurnStatus(timelineModel, payload);
  if (r.rejected) return;

  // The composer has two modes (§9.1/§9.2) and this is the authoritative signal for which
  // one it is in — not a timer, not the absence of events.
  syncComposerMode();

  // §18: "announce `Rich started working` once".
  if (payload.status === "working" && !timelineModel.announcedWorking.has(payload.turnId)) {
    timelineModel.announcedWorking.add(payload.turnId);
    announce("Rich started working");
  }
  if (payload.status === "completed" || payload.status === "failed" || payload.status === "stopped") {
    // §6.4: "Collapse the working transcript after a short settling transition."
    // 180ms — inside §17.4's allowed 150–220ms band — and skipped entirely under reduced
    // motion, where the collapse is immediate rather than transitioned.
    const settle = window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 180;
    window.setTimeout(() => {
      // Only if the CEO has not opened it himself in the meantime.
      if (!timelineModel.settled.has(payload.turnId)) {
        timelineModel.settled.add(payload.turnId);
        timelineModel.expanded.delete(payload.turnId);
        scheduleRender();
      }
    }, settle);
    const t = timelineModel.turns.get(payload.turnId);
    const row = t ? window.RichTimeline.durationRow(t, Date.now()) : null;
    announce(
      payload.status === "completed"
        ? "Rich finished. " + (row ? row.label : "")
        : payload.status === "stopped"
          ? // The row's own words, so the announcement and the screen say the same thing —
            // including the attribution. "Rich stopped before finishing" would be wrong
            // here: he did not, the CEO did.
            row
            ? row.label
            : "You stopped it."
          : "Rich stopped before finishing."
    );
  }
  syncComposerMode();
  scheduleRender();
});

Bridge.listen("rich://message-started", ({ payload }) => {
  const r = window.RichTimeline.onMessageStarted(timelineModel, payload);
  if (!r.rejected && r.structural) scheduleRender();
});

Bridge.listen("rich://message-delta", ({ payload }) => {
  const r = window.RichTimeline.onMessageDelta(timelineModel, payload);
  if (r.rejected) return;
  if (r.structural) scheduleRender();
  else if (r.textOnly) scheduleProse(r.textOnly);
});

Bridge.listen("rich://message-completed", ({ payload }) => {
  const r = window.RichTimeline.onMessageCompleted(timelineModel, payload);
  if (r.rejected) return;
  if (r.structural) scheduleRender();
  else if (r.textOnly) scheduleProse(r.textOnly);
  // §18: "announce meaningful commentary when it completes, not every token." Every run is
  // "meaningful" here because none of them can be told apart — see timeline.js's header.
  if (payload.text) announce(payload.text);
});

Bridge.listen("rich://activity-upserted", ({ payload }) => {
  const r = window.RichTimeline.onActivityUpserted(timelineModel, payload);
  if (!r.rejected) scheduleRender();
});

// §7 — a delegated AI worker, live. Until 2026-08-29 this event was deferred in the emitter
// and had no listener here, so a delegation reached the screen only through a `get_timeline`
// snapshot and read as a nameless "Worked" row for the rest of the turn. The payload is the
// same `worker_activity` item a reload projects, under the same id, so this upsert and the
// snapshot cannot disagree.
Bridge.listen("rich://worker-upserted", ({ payload }) => {
  const r = window.RichTimeline.onWorkerUpserted(timelineModel, payload);
  if (r.rejected) return;
  scheduleRender();
  // §7.2's inspector is open on a worker whose state just moved — repaint it from the row
  // that just arrived, or it would keep showing the state it was opened at.
  refreshOpenWorkerInspector(payload);
});

Bridge.listen("rich://thread-summary-updated", ({ payload }) => {
  // The sidebar's own row. Computed by the spine exactly as `thread::summaries` computes
  // it, so a live row and a re-listed row cannot disagree — which is why this refreshes the
  // rail rather than patching one label in place.
  if (payload.threadId) refreshNavigation();
});

// ---------------------------------------------------------------------------------------
// The four ORIGINAL events (app/STREAMING.md). Unchanged on the wire, and no longer the
// render path — see the block header above. `turn-completed` still triggers the
// reconciliation reload, which is what makes a missed live event self-heal (§13: "missed
// stream events recover from the durable snapshot").
// ---------------------------------------------------------------------------------------
Bridge.listen("rich://turn-started", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  pollWorkerStatus();
});

Bridge.listen("rich://turn-completed", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  drillItems = [];
  renderDrillChip();
  loadTimeline();
});

Bridge.listen("rich://turn-error", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  drillItems = [];
  renderDrillChip();
  // The typed family already carried `turn-status: failed`, which is what draws the failure
  // treatment. This reload reconciles the partial text that streamed before the failure —
  // already durable in the ledger.
  loadTimeline();
});

// The real proactive-attention seam: Rich raised a Tier 1/2 message via the backend seam
// (`raise_proactive_message`, spine.rs `raise_proactive`). A proactive turn is written
// atomically and is the ONE phase that is real — `phase: "proactive"` — so a reload is all
// this needs; `timeline.js` renders the "reached out" treatment from the phase itself.
Bridge.listen("rich://proactive-message", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  loadTimeline();
});
Bridge.listen("rich://mock-proactive", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  loadTimeline();
});

// §7.3 THE BACKGROUND WORK SUMMARY — "3 working · 1 done".
//
// §7.3 was explicit that this could not be built honestly: *"The current `worker_status.rs`
// cannot support this honestly because it only sees completion events. The engine and task
// graph must emit full lifecycle events first."* The engine landed those events at
// `d14bc54` and `worker_status.rs` consumes them, so `active` is now
//
//     open runs (a created/started with no LATER run_ended, per agent_id)
//     reconciled against each row's recorded host_pid via a REAL signal-0 probe
//
// — arithmetic over observations plus one syscall. That is the literal §23 Phase 4 exit
// gate: "no active or completed status is inferred from idle logs or filesystem activity."
// Nothing in that chain reads `idle-events.jsonl`, an mtime, a file size or a directory
// listing as a signal.
//
// THREE NUMBERS ARE READ AND THE FOURTH IS REFUSED:
//   `active`            REAL — the count above.
//   done                REAL — but TASK-grain, from `TaskCompleted`, never from a worker's
//                       `run_ended` (which is the honest superset of completed, interrupted
//                       and failed and would be a completion claim nobody made).
//   `liveness_unknown`  REAL — an open run whose host liveness could not be established.
//                       Shown rather than folded in either direction: counting it as active
//                       asserts it is running, hiding it asserts it is gone.
//   `needs_you`         NEVER SHOWN. It is structurally 0 — no hook payload asks the CEO
//                       for anything — and §22 lists "worker waiting state" under must not
//                       be faked. The branch is gone rather than dormant: a branch that can
//                       never fire is a claim waiting for someone to make it fire.
//
// Polled on turn-started rather than continuously — a courtesy line, not a live dashboard.
async function pollWorkerStatus() {
  try {
    const status = await Bridge.invoke("get_worker_status");
    drillItems = status.items || [];
    workerCounts = {
      active: typeof status.active === "number" ? status.active : 0,
      livenessUnknown: typeof status.liveness_unknown === "number" ? status.liveness_unknown : 0,
    };
  } catch (_e) {
    drillItems = [];
    workerCounts = { active: 0, livenessUnknown: 0 };
  }
  renderDrillChip();
}

function renderDrillChip() {
  drillChipEl.innerHTML = "";
  // `active` comes from the view's own authoritative field, not from counting item labels:
  // the count is the thing that was derived and probed, and re-deriving it here would be a
  // second implementation of the one number that must not be wrong.
  const active = workerCounts.active;
  const unknown = workerCounts.livenessUnknown;
  const done = drillItems.filter((i) => i.state === "done").length;
  const parts = [];
  if (active) parts.push(`${active} working`);
  if (done) parts.push(`${done} done`);
  // Plain language for the state the design calls `not_found`. "1 unknown" reads like an
  // error code; this says what actually happened.
  if (unknown) parts.push(`${unknown} I can't see`);
  if (!parts.length) {
    drillChipEl.hidden = true;
    return;
  }
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = "drill-chip";
  chip.textContent = "⋯ " + parts.join(" · ");
  chip.setAttribute("aria-label", parts.join(", ") + ". Open the work summary.");
  chip.addEventListener("click", openSlideOver);
  drillChipEl.appendChild(chip);
  drillChipEl.hidden = false;
}

Bridge.listen("rich://mock-worker-status", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  drillItems = payload.items || [];
  renderDrillChip();
});

// ---------------------------------------------------------------------------------------
// Slide-over — read-only, summoned, never resident (§3.2)
// ---------------------------------------------------------------------------------------
function openSlideOver() {
  // Two panes never own the screen at once (§7.2's pane is a sibling, not a second modal).
  closeWorkerInspector();
  slideoverBody.innerHTML = "";
  for (const item of drillItems) {
    const row = document.createElement("div");
    row.className = "slide-item slide-item--" + item.state;
    // `unknown` is a real state from `worker_status.rs` (an open run whose host liveness
    // could not be established) and had no marker here at all, so it fell through to the
    // same filled dot as `active` — reading as "running". `needs_you` is gone: nothing can
    // produce it.
    const marker = { active: "●", done: "○", unknown: "◇" }[item.state] || "·";
    row.textContent = `${marker} ${item.label}`;
    slideoverBody.appendChild(row);
  }
  slideoverEl.hidden = false;
  slideoverBackdrop.hidden = false;
}
function closeSlideOver() {
  slideoverEl.hidden = true;
  slideoverBackdrop.hidden = true;
}
el("slideover-close").addEventListener("click", closeSlideOver);
slideoverBackdrop.addEventListener("click", closeSlideOver);

// ---------------------------------------------------------------------------------------
// THE WORKER INSPECTOR (§7.2) — a sibling pane, read-only, with a durable width
//
// It is NOT the "Under the hood" slide-over above. That one is a summoned overlay over the
// engine's task log; this is a docked pane about ONE delegated worker, opened from a chip in
// the timeline. They coexist deliberately and never both own the screen: opening either
// closes the other.
//
// READ-ONLY IS THE BOUNDARY. Every control §7.2 forbids is a business action, and R2
// business-action governance is deferred to V2 by CEO decision for v1 and all 1.x. The only
// interactive elements in this pane are Close and the one chronology disclosure.
// ---------------------------------------------------------------------------------------

const inspectorEl = el("inspector");
const inspectorScrim = el("inspector-scrim");
const inspectorBody = el("inspector-body");
const inspectorTitle = el("inspector-title");
const inspectorResizer = el("inspector-resizer");

let openWorker = null; // the WorkerActivityItem payload currently shown, or null
let inspectorChronOpen = false;
let inspectorReturnFocus = null;

const INSPECTOR_MIN = 280;
const INSPECTOR_MAX = 520;
const INSPECTOR_DEFAULT = 336;
let inspectorWidth = INSPECTOR_DEFAULT;

function applyInspectorWidth(px) {
  inspectorWidth = Math.max(INSPECTOR_MIN, Math.min(INSPECTOR_MAX, Math.round(px)));
  document.documentElement.style.setProperty("--inspector-width", inspectorWidth + "px");
  inspectorResizer.setAttribute("aria-valuenow", String(inspectorWidth));
}

async function persistInspectorWidth() {
  // The store returns the width it ACCEPTED (clamped in Rust, nav.rs). Render that, so the
  // pane and the durable file can never disagree — the same contract the rail has.
  const accepted = await invokeQuiet("set_inspector_width", { width: inspectorWidth });
  if (typeof accepted === "number") applyInspectorWidth(accepted);
}

function renderInspector() {
  inspectorBody.innerHTML = "";
  if (!openWorker) return;
  inspectorTitle.textContent = window.RichTimeline.workerDisplayName(openWorker);
  inspectorBody.appendChild(
    window.RichTimeline.renderWorkerInspector(openWorker, {
      chronologyOpen: inspectorChronOpen,
      toggleChronology: () => {
        inspectorChronOpen = !inspectorChronOpen;
        renderInspector();
        const again = el("insp-chron-toggle");
        if (again) again.focus({ preventScroll: true });
      },
    })
  );
}

/// A live `rich://worker-upserted` arrived for the worker whose pane is OPEN — repaint it.
///
/// Without this the pane keeps rendering the `WorkerActivityItem` it was opened with, so a
/// run that ends while the CEO is reading its detail still reads `Working` in the pane and
/// `Ended` on the chip behind it. Keyed on `agentId`, which is the join key everywhere else
/// too; a row for any other worker is ignored rather than swapped in.
function refreshOpenWorkerInspector(payload) {
  if (!openWorker || !payload || !payload.worker) return;
  if (payload.worker.agentId !== openWorker.agentId) return;
  openWorker = payload.worker;
  renderInspector();
}

function openWorkerInspector(worker) {
  closeSlideOver();
  // The chip that OWNS this worker, derived from the worker itself rather than read off
  // `document.activeElement`. Measured, not assumed: clicking a button on macOS/WebKit does
  // not focus it, so activeElement at this moment is `body` and the id is the empty string —
  // and Escape would have dropped focus to the top of the document instead of returning it.
  inspectorReturnFocus = "chip:" + worker.agentId;
  openWorker = worker;
  inspectorEl.hidden = false;
  inspectorScrim.hidden = isWide(); // a scrim only where the pane OVERLAYS (§20)
  document.body.classList.add("inspector-open");
  renderInspector();
  markSelectedChip();
  // §18: focus moves into the pane so a keyboard user is not left behind the timeline.
  inspectorBody.focus({ preventScroll: true });
  announce(
    window.RichTimeline.workerDisplayName(worker) +
      " details, " +
      window.RichTimeline.workerStateSpec(worker.state).label
  );
}

function closeWorkerInspector() {
  if (inspectorEl.hidden) return;
  openWorker = null;
  inspectorEl.hidden = true;
  inspectorScrim.hidden = true;
  document.body.classList.remove("inspector-open");
  inspectorBody.innerHTML = "";
  markSelectedChip();
  // §18: "Escape closes overlays and inspector detail" — and focus returns where it was.
  const back = inspectorReturnFocus && messagesEl.querySelector('[id="' + inspectorReturnFocus.replace(/(["\\])/g, "\\$1") + '"]');
  // The chip may legitimately be gone — a reload, a collapse, a thread switch. Falling back
  // to the conversation keeps focus inside the reading region rather than at the document
  // top (§18: "focus remains stable during streaming and collapse transitions").
  if (back) back.focus({ preventScroll: true });
  else conversationEl.focus({ preventScroll: true });
  inspectorReturnFocus = null;
}

/// The open chip carries `is-selected` — §18 requires the current item be identifiable
/// without relying on the pane alone.
function markSelectedChip() {
  for (const chip of messagesEl.querySelectorAll(".tl-chip")) {
    const on = !!openWorker && chip.dataset.agentId === openWorker.agentId;
    chip.classList.toggle("is-selected", on);
    if (on) chip.setAttribute("aria-current", "true");
    else chip.removeAttribute("aria-current");
  }
}

el("inspector-close").addEventListener("click", closeWorkerInspector);
inspectorScrim.addEventListener("click", closeWorkerInspector);

// The draggable divider (§7.2, §2.1). Keyboard-operable too — §18 requires every function
// to work without a pointer, and a divider that only responds to a mouse is a function that
// does not.
inspectorResizer.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  const startX = e.clientX;
  const startW = inspectorWidth;
  const onMove = (ev) => applyInspectorWidth(startW - (ev.clientX - startX));
  const onUp = () => {
    window.removeEventListener("pointermove", onMove);
    window.removeEventListener("pointerup", onUp);
    persistInspectorWidth();
  };
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp);
});

inspectorResizer.addEventListener("keydown", (e) => {
  const step = e.shiftKey ? 32 : 8;
  if (e.key === "ArrowLeft") applyInspectorWidth(inspectorWidth + step);
  else if (e.key === "ArrowRight") applyInspectorWidth(inspectorWidth - step);
  else return;
  e.preventDefault();
  persistInspectorWidth();
});

// ---------------------------------------------------------------------------------------
// Voice mode — a mode of the same conversation, never a separate call screen (§4)
//
// Wired to the real pipeline in app/crates/richos-voice (2026-08-24). Contract:
//   INVOKE  start_voice_capture / stop_voice_capture / voice_barge_in
//           voice_turn_started / voice_speak_delta / voice_speak_end / voice_turn_ended
//   LISTEN  rich://voice-state      { state, level, bargeInArmed, noAudio, at }
//           rich://voice-transcript { text, durationMs, latencyMs, at }
//           rich://voice-error      { message, at }
//
// The panel's state is driven ONLY by rich://voice-state — never optimistically. The UX direction §4.1:
// "the CEO always knows whether the mic is hot ... the single most important voice-UX
// requirement" while AEC is missing. So the listening dot appears when the microphone is
// genuinely open and at no other moment; if the mic fails to open, the toggle stays OFF and
// Rich says so in his own words.
//
// Rich's reply is spoken by relaying the SAME rich:// stream the transcript renders from —
// additional listeners, registered here, so the render path above is untouched and TTS
// inherits the clean-output guarantee rather than re-deriving it.
// ---------------------------------------------------------------------------------------
const voiceLevelBars = voiceListeningEl ? voiceListeningEl.querySelectorAll(".voice-level i") : [];
const VOICE_BAR_HEIGHTS = [5, 10, 14, 8, 6]; // the resting profile already in style.css

function renderVoiceLevel(level) {
  const v = Math.max(0, Math.min(1, Number(level) || 0));
  for (let i = 0; i < voiceLevelBars.length; i++) {
    const bar = voiceLevelBars[i];
    // Real audio drives the meter, so the idle CSS pulse must stop — a meter that moves
    // when nothing is being said is the same lie as a fake listening dot.
    bar.style.animation = "none";
    bar.style.height = Math.round(VOICE_BAR_HEIGHTS[i] * (0.28 + 0.72 * v)) + "px";
    bar.style.opacity = (0.3 + 0.6 * v).toFixed(2);
  }
}

function renderVoiceState(state, noAudio) {
  // "hearing" and "thinking" both mean the mic is open and Rich is not talking, so both
  // render as listening — which is the truth the CEO needs.
  const speaking = state === "speaking";
  // The mic is open and healthy but nothing has arrived for 3.008 s (noaudio.rs). It
  // REPLACES the listening row: "listening…" next to "I can't hear anything" is two claims
  // at once, and the level meter it sits beside is pinned at zero by definition. Rich
  // speaking always wins — he is never interrupted by this.
  const silent = !speaking && noAudio === true;
  voiceListeningEl.hidden = speaking || silent;
  voiceNoAudioEl.hidden = !silent;
  voiceSpeakingEl.hidden = !speaking;
}

/// A line Rich says LOCALLY — a voice-mode failure he explains himself. Not a turn and not
/// evidence: it carries a synthetic turn id with no turn record, so it can never grow a
/// duration row claiming work that never happened, and the next snapshot drops it.
function richVoiceSays(text) {
  window.RichTimeline.addLocalNotice(timelineModel, text, Date.now());
  followBottom = true;
  scheduleRender();
}

async function enterVoiceMode() {
  try {
    await Bridge.invoke("start_voice_capture", { threadId: activeThreadId });
  } catch (e) {
    // The mic did not open. Do NOT show a listening state — that would be a lie about a hot
    // mic. Stay in text and let Rich explain in one calm line.
    richVoiceSays(
      Bridge.isMock || String(e).startsWith("mock:")
        ? "Talking out loud needs the desktop app — here in the preview, type to me."
        : String(e)
    );
    return;
  }
  voiceMode = true;
  talkToggleBtn.setAttribute("aria-pressed", "true");
  composerEl.hidden = true;
  voicePanelEl.hidden = false;
  renderVoiceState("listening", false);
  renderVoiceLevel(0);
}

async function exitVoiceMode() {
  voiceMode = false;
  talkToggleBtn.setAttribute("aria-pressed", "false");
  voicePanelEl.hidden = true;
  composerEl.hidden = false;
  inputEl.focus();
  try {
    await Bridge.invoke("stop_voice_capture", { threadId: activeThreadId });
  } catch (_e) {
    /* already down */
  }
}

talkToggleBtn.addEventListener("click", () => {
  if (voiceMode) exitVoiceMode();
  else enterVoiceMode();
});

bargeInBtn.addEventListener("click", () => {
  // The instant override while AEC is interim (the UX direction §4.1). The panel is NOT flipped here —
  // rich://voice-state reports what actually happened to the audio.
  Bridge.invoke("voice_barge_in").catch(() => {});
});

/// The no-audio row's CONTROL. `#voice-state-no-audio` says "check your mic isn't muted",
/// which is a state the CEO can change — and until this handler existed the app then gave
/// him nothing to press once he had changed it. A state the user could change that renders
/// without the control that changes it is not a status, it is a request.
///
/// Re-opening capture is the only recovery this app can actually perform (a muted mic, or a
/// device another app grabbed and released, are both fixed by a fresh `start_voice_capture`),
/// so it is the only thing offered. Nothing here claims to unmute anything.
///
/// THE HOT-MIC INVARIANT IS PRESERVED. `renderVoiceState("listening", false)` runs only
/// AFTER `start_voice_capture` resolves, exactly as `enterVoiceMode` does it; if the mic
/// still refuses to open, voice mode is torn down rather than left showing a listening dot
/// over a dead device.
voiceRetryBtn.addEventListener("click", async () => {
  if (voiceRetryBtn.disabled) return;
  voiceRetryBtn.disabled = true;
  try {
    try {
      await Bridge.invoke("stop_voice_capture", { threadId: activeThreadId });
    } catch (_e) {
      /* already down — the restart below is what matters */
    }
    await Bridge.invoke("start_voice_capture", { threadId: activeThreadId });
    renderVoiceState("listening", false);
    renderVoiceLevel(0);
  } catch (e) {
    exitVoiceMode();
    richVoiceSays(
      Bridge.isMock || String(e).startsWith("mock:")
        ? "Talking out loud needs the desktop app — here in the preview, type to me."
        : "The mic still won't open. I've switched us back to typing — tap ◉ when you want to try voice again."
    );
  } finally {
    voiceRetryBtn.disabled = false;
  }
});

Bridge.listen("rich://voice-state", ({ payload }) => {
  if (!voiceMode) return;
  if (payload.state === "off") {
    // The pipeline stopped on its own (device lost, mode torn down). Never leave a stale
    // "listening" on screen claiming a hot mic.
    exitVoiceMode();
    return;
  }
  renderVoiceState(payload.state, payload.noAudio);
  renderVoiceLevel(payload.level);
});

Bridge.listen("rich://voice-transcript", ({ payload }) => {
  if (!voiceMode) return;
  // What the CEO said appears in the thread the moment it is recognised — voice and text are
  // one conversation, so this is an ordinary user turn, not a call artefact. The reconciled
  // ledger snapshot replaces it when the turn completes.
  // The same optimistic path a typed send takes: a synthetic id, re-keyed onto the real
  // turn the moment `rich://turn-status` names one. Voice and text are one conversation.
  window.RichTimeline.addPendingUserMessage(timelineModel, payload.text, payload.at || Date.now());
  followBottom = true;
  scheduleRender();
});

Bridge.listen("rich://voice-error", ({ payload }) => {
  if (!voiceMode) return;
  richVoiceSays(payload.message);
});

// Relay the reply stream to the speaker. Separate listeners so the render path above is
// untouched; each is a no-op unless voice mode is on.
Bridge.listen("rich://turn-started", () => {
  if (voiceMode) Bridge.invoke("voice_turn_started").catch(() => {});
});
Bridge.listen("rich://chunk", ({ payload }) => {
  if (voiceMode) Bridge.invoke("voice_speak_delta", { text: payload.textDelta }).catch(() => {});
});
Bridge.listen("rich://turn-completed", () => {
  if (!voiceMode) return;
  Bridge.invoke("voice_speak_end").catch(() => {});
  Bridge.invoke("voice_turn_ended").catch(() => {});
});
Bridge.listen("rich://turn-error", () => {
  if (!voiceMode) return;
  Bridge.invoke("voice_speak_end").catch(() => {});
  Bridge.invoke("voice_turn_ended").catch(() => {});
});

// ---------------------------------------------------------------------------------------
// Assertiveness dial (§5.2) — one plain 3-way preference, default Quiet. Backed by the
// real `get_assertiveness`/`set_assertiveness` commands (main.rs -> richos-core's
// config.rs — durable, survives restart, default Quiet). `localStorage` stays as an
// INSTANT local cache only (so the popover paints correctly before the async backend
// round-trip resolves, and so the mock harness — which doesn't wire these commands —
// still behaves exactly as before): every write goes to both; the backend is the
// source of truth and wins on the next launch's `syncAssertivenessFromBackend()`.
// ---------------------------------------------------------------------------------------
const ASSERTIVENESS_KEY = "richos.assertiveness";
function getAssertiveness() {
  return window.localStorage.getItem(ASSERTIVENESS_KEY) || "quiet";
}
function setAssertiveness(v) {
  window.localStorage.setItem(ASSERTIVENESS_KEY, v);
  Bridge.invoke("set_assertiveness", { level: v }).catch(() => {
    // Unwired (mock harness) or a genuine write failure — the local cache already
    // reflects the CEO's choice for this session; nothing to show the CEO for this.
  });
}
function checkAssertivenessRadio(value) {
  for (const input of assertivenessPopover.querySelectorAll('input[name="assertiveness"]')) {
    input.checked = input.value === value;
  }
}
(function initAssertivenessControl() {
  checkAssertivenessRadio(getAssertiveness());
  for (const input of assertivenessPopover.querySelectorAll('input[name="assertiveness"]')) {
    input.addEventListener("change", () => setAssertiveness(input.value));
  }
})();
async function syncAssertivenessFromBackend() {
  try {
    const backendValue = await Bridge.invoke("get_assertiveness");
    window.localStorage.setItem(ASSERTIVENESS_KEY, backendValue);
    checkAssertivenessRadio(backendValue);
  } catch (_e) {
    // Unwired (mock harness): the localStorage-only value already painted correctly.
  }
}
settingsBtn.addEventListener("click", () => {
  const open = assertivenessPopover.hidden === false;
  assertivenessPopover.hidden = open;
  settingsBtn.setAttribute("aria-expanded", String(!open));
});
document.addEventListener("click", (e) => {
  if (!assertivenessPopover.hidden && !assertivenessPopover.contains(e.target) && e.target !== settingsBtn) {
    assertivenessPopover.hidden = true;
    settingsBtn.setAttribute("aria-expanded", "false");
  }
});

// ---------------------------------------------------------------------------------------
// PER-THREAD LIVE STATUS (§3.2)
//
// Appended listeners, registered ALONGSIDE the render listeners above rather than folded
// into them: those return early when the event is not for the selected thread (correct —
// they drive the visible conversation), which is exactly why background threads need their
// own bookkeeping. Keeping them separate also means the timeline work landing in the
// listeners above does not have to reason about the rail.
//
// Every write below is driven by a POSITIVE event from the spine. Nothing here starts,
// clears or ages a status on a timer, and nothing infers a state from silence.
// ---------------------------------------------------------------------------------------
Bridge.listen("rich://turn-started", ({ payload }) => {
  liveStatus.set(payload.threadId, "working");
  renderRail();
});

// The per-thread live TEXT buffer this block used to keep is gone. It existed so that
// returning to a background thread could re-show its half-streamed reply from memory;
// `sessionLiveTurns` plus `get_timeline` now do that from the DURABLE record instead —
// deltas are persisted before they are emitted (STREAMING.md), so the snapshot on reopen is
// at least as complete as anything this file could have accumulated, and it survives a
// reload that the buffer did not.

Bridge.listen("rich://turn-completed", ({ payload }) => {
  // §3.2 "Completed while away: small completion mark UNTIL OPENED". If the CEO is looking
  // at the thread, there is nothing to flag — he just watched it finish.
  if (payload.threadId === activeThreadId) liveStatus.delete(payload.threadId);
  else liveStatus.set(payload.threadId, "unseen");
  refreshNavigation();
});

Bridge.listen("rich://turn-error", ({ payload }) => {
  if (payload.threadId === activeThreadId) liveStatus.delete(payload.threadId);
  else liveStatus.set(payload.threadId, "failed");
  refreshNavigation();
});

// ---------------------------------------------------------------------------------------
// Thread context menu — rename, pin, archive (§3.1)
//
// All three are SHELL state (src-tauri/src/nav.rs), not ledger events: §25 requires them to
// "work without changing context authority", and the ledger is evidence. A rename is a
// display override; the thread's title in the durable record is untouched and still shown
// as the original when renaming. An archived thread keeps the exact entity home it always
// had — archive changes which list it appears in, nothing else.
// ---------------------------------------------------------------------------------------
function closeThreadMenu() {
  threadMenuEl.hidden = true;
  threadMenuEl.innerHTML = "";
}

function openThreadMenu(row, anchor) {
  closeThreadMenu();
  const add = (label, onClick) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "menu-item";
    b.setAttribute("role", "menuitem");
    b.textContent = label;
    b.addEventListener("click", async () => {
      closeThreadMenu();
      await onClick();
    });
    threadMenuEl.appendChild(b);
  };

  add("Rename…", async () => {
    // The ORIGINAL ledger title is offered as the starting value when no override exists,
    // so "rename back to what Rich called it" is always one step away.
    const next = window.prompt("Rename this thread", row.display_title);
    if (next === null) return;
    await invokeQuiet("rename_thread", { threadId: row.id, title: next });
    await refreshNavigation();
    renderScopeHeader();
  });
  add(row.pinned ? "Unpin" : "Pin", async () => {
    await invokeQuiet("set_thread_pinned", { threadId: row.id, pinned: !row.pinned });
    await refreshNavigation();
  });
  add(row.archived ? "Restore from archive" : "Archive", async () => {
    await invokeQuiet("set_thread_archived", { threadId: row.id, archived: !row.archived });
    await refreshNavigation();
  });

  const r = anchor.getBoundingClientRect();
  threadMenuEl.hidden = false;
  threadMenuEl.style.top = Math.round(r.bottom + 4) + "px";
  threadMenuEl.style.left = Math.round(Math.min(r.left, window.innerWidth - 200)) + "px";
  const first = threadMenuEl.querySelector(".menu-item");
  if (first) first.focus();
}

document.addEventListener("click", (e) => {
  if (!threadMenuEl.hidden && !threadMenuEl.contains(e.target)) closeThreadMenu();
});

async function invokeQuiet(cmd, args) {
  try {
    return await Bridge.invoke(cmd, args);
  } catch (_e) {
    // Unwired (the mock harness) or a genuine write failure. Never fabricate success —
    // the next `navigation_tree` refresh renders whatever actually persisted.
    return null;
  }
}

async function toggleEntityCollapsed(entityId) {
  const collapsed = !isCollapsed(entityId);
  if (navPrefs) {
    const list = navPrefs.collapsed_entities.filter((x) => x !== entityId);
    if (collapsed) list.push(entityId);
    navPrefs.collapsed_entities = list;
  }
  renderRail();
  await invokeQuiet("set_entity_collapsed", { entityId, collapsed });
}

// ---------------------------------------------------------------------------------------
// Entity picker (§3.3) — asked BEFORE the first message, never defaulted (§21).
// ---------------------------------------------------------------------------------------
let entityPickerResolve = null;

function openEntityPicker(onPick) {
  entityPickerResolve = onPick;
  entityPickerListEl.innerHTML = "";
  for (const group of navTree.groups) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "picker-item";
    b.setAttribute("role", "option");
    b.setAttribute("aria-selected", "false");
    const name = document.createElement("span");
    name.className = "picker-name";
    name.textContent = group.entity.display_name;
    b.appendChild(name);
    const meta = document.createElement("span");
    meta.className = "picker-meta";
    meta.textContent = group.threads.length === 1 ? "1 thread" : group.threads.length + " threads";
    b.appendChild(meta);
    b.addEventListener("click", () => {
      const pick = entityPickerResolve;
      closeEntityPicker();
      if (pick) pick(group.entity.id);
    });
    entityPickerListEl.appendChild(b);
  }
  entityPickerEl.hidden = false;
  const first = entityPickerListEl.querySelector(".picker-item");
  if (first) first.focus();
}

function closeEntityPicker() {
  entityPickerEl.hidden = true;
  entityPickerResolve = null;
}

entityPickerEl.addEventListener("click", (e) => {
  if (e.target === entityPickerEl) closeEntityPicker();
});
entityPickerListEl.addEventListener("keydown", (e) => moveListFocus(e, ".picker-item"));

// ---------------------------------------------------------------------------------------
// Search (§3.4) — a command-palette overlay, grouped by entity, fully keyboard-driven.
// The MATCH runs in Rust (`search_nav`); only bounded excerpts cross the IPC boundary, so
// this never loads thread bodies into the renderer.
// ---------------------------------------------------------------------------------------
let searchHits = [];
let searchIndex = -1;
let searchTimer = null;

function openSearch() {
  searchOverlayEl.hidden = false;
  searchInputEl.value = "";
  searchResultsEl.innerHTML = "";
  searchEmptyEl.hidden = true;
  searchHits = [];
  searchIndex = -1;
  searchInputEl.setAttribute("aria-expanded", "false");
  searchInputEl.focus();
}

function closeSearch() {
  searchOverlayEl.hidden = true;
  searchInputEl.setAttribute("aria-expanded", "false");
}

function relativeDate(ms) {
  if (!ms) return "";
  const mins = Math.floor((Date.now() - ms) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return mins + "m ago";
  const hours = Math.floor(mins / 60);
  if (hours < 24) return hours + "h ago";
  return Math.floor(hours / 24) + "d ago";
}

function renderSearchResults() {
  searchResultsEl.innerHTML = "";
  searchIndex = searchHits.length ? 0 : -1;
  searchEmptyEl.hidden = searchHits.length > 0 || !searchInputEl.value.trim();
  if (searchEmptyEl.hidden === false) searchEmptyEl.textContent = "Nothing matches that.";
  searchInputEl.setAttribute("aria-expanded", String(searchHits.length > 0));

  // §3.4: "Results group by entity."
  const order = [];
  const byEntity = new Map();
  for (const hit of searchHits) {
    const key = hit.entity_label;
    if (!byEntity.has(key)) {
      byEntity.set(key, []);
      order.push(key);
    }
    byEntity.get(key).push(hit);
  }

  let flat = 0;
  for (const label of order) {
    const head = document.createElement("div");
    head.className = "result-group";
    head.textContent = label;
    searchResultsEl.appendChild(head);
    for (const hit of byEntity.get(label)) {
      const idx = flat++;
      const b = document.createElement("button");
      b.type = "button";
      b.className = "result-item";
      b.id = "search-result-" + idx;
      b.setAttribute("role", "option");
      b.dataset.index = String(idx);

      const title = document.createElement("span");
      title.className = "result-title";
      title.textContent = hit.kind === "entity" ? hit.entity_label : hit.thread_title || "";
      b.appendChild(title);

      const meta = document.createElement("span");
      meta.className = "result-meta";
      meta.textContent = [hit.entity_label, relativeDate(hit.at)].filter(Boolean).join(" · ");
      b.appendChild(meta);

      if (hit.excerpt && hit.kind === "message") {
        const ex = document.createElement("span");
        ex.className = "result-excerpt";
        ex.textContent = hit.excerpt;
        b.appendChild(ex);
      }

      b.setAttribute(
        "aria-label",
        [title.textContent, "in " + hit.entity_label, hit.excerpt].filter(Boolean).join(", ")
      );
      b.addEventListener("click", () => activateSearchHit(idx));
      searchResultsEl.appendChild(b);
    }
  }
  highlightSearchIndex();
}

function highlightSearchIndex() {
  const items = searchResultsEl.querySelectorAll(".result-item");
  items.forEach((node, i) => {
    const on = i === searchIndex;
    node.classList.toggle("is-active", on);
    node.setAttribute("aria-selected", String(on));
    if (on) {
      searchInputEl.setAttribute("aria-activedescendant", node.id);
      node.scrollIntoView({ block: "nearest" });
    }
  });
  if (searchIndex < 0) searchInputEl.removeAttribute("aria-activedescendant");
}

async function activateSearchHit(index) {
  const hit = searchHits[index];
  if (!hit) return;
  closeSearch();
  if (hit.kind === "entity" && hit.entity_id) {
    showEntityView(hit.entity_id, "overview");
    return;
  }
  if (hit.thread_id) await openThread(hit.thread_id);
}

searchInputEl.addEventListener("input", () => {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const q = searchInputEl.value.trim();
    if (!q) {
      searchHits = [];
      renderSearchResults();
      return;
    }
    try {
      searchHits = await Bridge.invoke("search_nav", { query: q, limit: 40 });
    } catch (_e) {
      searchHits = [];
    }
    renderSearchResults();
  }, 120);
});

searchInputEl.addEventListener("keydown", (e) => {
  if (e.key === "ArrowDown") {
    e.preventDefault();
    if (searchHits.length) searchIndex = (searchIndex + 1) % searchHits.length;
    highlightSearchIndex();
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    if (searchHits.length) searchIndex = (searchIndex - 1 + searchHits.length) % searchHits.length;
    highlightSearchIndex();
  } else if (e.key === "Enter") {
    e.preventDefault();
    activateSearchHit(searchIndex);
  }
});

searchOverlayEl.addEventListener("click", (e) => {
  if (e.target === searchOverlayEl) closeSearch();
});

// ---------------------------------------------------------------------------------------
// Rail width, collapse and responsive behaviour (§2.1, §20)
//
// Bounds are UX §2.1's: 300px default, 224px minimum, 420px maximum. They are enforced in
// RUST as well (nav.rs `clamp_width`) and `set_sidebar_width` returns the value the store
// ACCEPTED, so the rendered width and the durable file cannot disagree.
// ---------------------------------------------------------------------------------------
const RAIL_MIN = 224;
const RAIL_MAX = 420;
const RAIL_DEFAULT = 300;
const BREAK_WIDE = 1180; // §20: sidebar persistent at and above this
const BREAK_NARROW = 820; // §20: below this, one visible pane at a time

let railWidth = RAIL_DEFAULT;
let railOpen = true;
let widthCommitTimer = null;

function isNarrow() {
  return window.innerWidth < BREAK_NARROW;
}
function isWide() {
  return window.innerWidth >= BREAK_WIDE;
}

function applyRailWidth(px) {
  railWidth = Math.max(RAIL_MIN, Math.min(RAIL_MAX, Math.round(px)));
  document.documentElement.style.setProperty("--rail-width", railWidth + "px");
  railResizerEl.setAttribute("aria-valuenow", String(railWidth));
}

function commitRailWidth() {
  if (widthCommitTimer) clearTimeout(widthCommitTimer);
  widthCommitTimer = setTimeout(async () => {
    const accepted = await invokeQuiet("set_sidebar_width", { width: railWidth });
    if (typeof accepted === "number") applyRailWidth(accepted);
  }, 150);
}

function setRailOpen(open) {
  railOpen = open;
  document.body.classList.toggle("rail-closed", !open);
  railToggleBtn.setAttribute("aria-expanded", String(open));
  railToggleBtn.setAttribute("aria-label", open ? "Hide navigation" : "Show navigation");
  railScrimEl.hidden = !(open && isNarrow());
  railEl.setAttribute("aria-hidden", String(!open && isNarrow()));
  if (!isWide()) invokeQuiet("set_sidebar_collapsed", { collapsed: !open });
}

function applyBreakpoint() {
  const wide = isWide();
  const narrow = isNarrow();
  document.body.classList.toggle("bp-wide", wide);
  document.body.classList.toggle("bp-mid", !wide && !narrow);
  document.body.classList.toggle("bp-narrow", narrow);
  // §20: at 1180px and wider the sidebar is persistent, so there is nothing to toggle.
  railToggleBtn.hidden = wide;
  railDrawerCloseBtn.hidden = !narrow;
  if (wide && !railOpen) setRailOpen(true);
  railScrimEl.hidden = !(railOpen && narrow);
  railEl.setAttribute("aria-hidden", String(!railOpen && narrow));
}

railResizerEl.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  railResizerEl.setPointerCapture(e.pointerId);
  const startX = e.clientX;
  const startW = railWidth;
  const onMove = (ev) => applyRailWidth(startW + (ev.clientX - startX));
  const onUp = (ev) => {
    railResizerEl.releasePointerCapture(ev.pointerId);
    railResizerEl.removeEventListener("pointermove", onMove);
    railResizerEl.removeEventListener("pointerup", onUp);
    commitRailWidth();
  };
  railResizerEl.addEventListener("pointermove", onMove);
  railResizerEl.addEventListener("pointerup", onUp);
});

// §18: "All functions work by keyboard" — including dragging a divider.
railResizerEl.addEventListener("keydown", (e) => {
  const step = e.shiftKey ? 48 : 16;
  if (e.key === "ArrowLeft") applyRailWidth(railWidth - step);
  else if (e.key === "ArrowRight") applyRailWidth(railWidth + step);
  else if (e.key === "Home") applyRailWidth(RAIL_MIN);
  else if (e.key === "End") applyRailWidth(RAIL_MAX);
  else return;
  e.preventDefault();
  commitRailWidth();
});

railToggleBtn.addEventListener("click", () => setRailOpen(!railOpen));
railDrawerCloseBtn.addEventListener("click", () => setRailOpen(false));
railScrimEl.addEventListener("click", () => setRailOpen(false));
window.addEventListener("resize", applyBreakpoint);

// ---------------------------------------------------------------------------------------
// Keyboard (§18)
// ---------------------------------------------------------------------------------------
/// Arrow-key movement inside a list of buttons. Every control in the rail is a real
/// `<button>`, so Tab already reaches all of them; this is the faster path §3.4 calls
/// "keyboard navigation is mandatory", not a substitute for tab order.
function moveListFocus(e, selector) {
  if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
  const items = Array.from(e.currentTarget.querySelectorAll(selector));
  if (!items.length) return;
  const at = items.indexOf(document.activeElement);
  const next = e.key === "ArrowDown" ? (at + 1) % items.length : (at - 1 + items.length) % items.length;
  items[next].focus();
  e.preventDefault();
}

railNavEl.addEventListener("keydown", (e) =>
  moveListFocus(e, ".nav-group-label.is-selectable, .nav-thread, .nav-show-more")
);

document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (e.key === "k" || e.key === "K")) {
    e.preventDefault();
    openSearch();
    return;
  }
  // §18 asks for a CONFIGURABLE new-thread shortcut. It is fixed here — there is no
  // shortcut-preferences surface in the app, and inventing one is not this slice's work.
  if (mod && !e.shiftKey && (e.key === "n" || e.key === "N")) {
    e.preventDefault();
    startNewThreadFlow();
    return;
  }
  if (e.key === "Escape") {
    // §18: "Escape closes overlays and inspector detail."
    if (!threadMenuEl.hidden) return closeThreadMenu();
    if (!searchOverlayEl.hidden) return closeSearch();
    if (!entityPickerEl.hidden) return closeEntityPicker();
    if (!slideoverEl.hidden) return closeSlideOver();
    if (!inspectorEl.hidden) return closeWorkerInspector();
    if (isNarrow() && railOpen) return setRailOpen(false);
  }
});

// ---------------------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------------------
async function init() {
  // Company identity header (UX §2.1) — backed by `get_company_name`; the backend
  // itself already carries a matching fallback ("My Company"), this catch only covers
  // an unwired command (the mock harness) or a genuine invoke failure.
  try {
    railCompanyEl.textContent = await Bridge.invoke("get_company_name");
  } catch (_e) {
    railCompanyEl.textContent = COMPANY_LABEL_FALLBACK;
  }
  syncAssertivenessFromBackend();

  if (!/Mac|iPhone|iPad/.test(navigator.platform || "")) el("nav-search-kbd").textContent = "Ctrl+K";

  // Durable rail preferences (nav.rs): width, collapsed entity set, pins, renames.
  navPrefs = await invokeQuiet("nav_state");
  if (!navPrefs)
    navPrefs = {
      sidebar_width: RAIL_DEFAULT,
      inspector_width: INSPECTOR_DEFAULT,
      sidebar_collapsed: false,
      collapsed_entities: [],
      pinned_threads: [],
      archived_threads: [],
      renamed_threads: {},
    };
  applyRailWidth(navPrefs.sidebar_width || RAIL_DEFAULT);
  // §25: "Worker-pane width can be changed directly and survives relaunch."
  applyInspectorWidth(navPrefs.inspector_width || INSPECTOR_DEFAULT);
  applyBreakpoint();
  setRailOpen(isWide() ? true : !navPrefs.sidebar_collapsed);

  await refreshNavigation();

  const active = activeContext ? activeContext.thread_id : await invokeQuiet("active_thread");
  if (active && threadRow(active)) {
    await openThread(active);
  } else if (navTree.groups.length) {
    // No active context — the launch could not resolve an entity (the shell fails closed
    // rather than guessing one), or every thread on disk is unbound.
    //
    // Opening the first entity's overview here was WRONG and is deliberately not what
    // happens: that overview arms the composer for that entity, so the CEO's first
    // sentence would have been filed under an entity he never chose — the exact silent
    // default §21 forbids ("Never default to the last entity"). §3.3 already prescribes
    // the right move: "opens an entity picker before the first message if no entity is
    // selected". No entity is selected, so the picker opens.
    startNewThreadFlow();
  }
  // WHAT IS RUNNING RIGHT NOW, read from the backend rather than assumed from the absence
  // of events. A webview reload does not restart the Rust side, so a turn can be mid-flight
  // with this script one second old; without this the row renders "Status unavailable" and
  // the stop control never arms. `running_turn` is the control's mirror of the spine's own
  // `turn_in_progress`, written at the same durable points — not an inference from silence.
  await hydrateRunningTurn();
  renderRail();
  syncComposerMode();
  inputEl.focus();
}

async function hydrateRunningTurn() {
  const running = await invokeQuiet("running_turn");
  if (!running || !running.turnId) return;
  sessionLiveTurns.set(running.turnId, {
    threadId: running.threadId,
    startedAt: typeof running.startedAt === "number" ? running.startedAt : null,
  });
  if (running.threadId === activeThreadId) {
    const t = timelineModel.turns.get(running.turnId);
    if (t) {
      t.live = true;
      if (typeof running.startedAt === "number") t.startedAt = running.startedAt;
      scheduleRender();
    }
  }
}

init();
