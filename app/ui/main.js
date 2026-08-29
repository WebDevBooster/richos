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
const talkToggleBtn = el("talk-toggle");
const voicePanelEl = el("voice-panel");
const voiceListeningEl = el("voice-state-listening");
const voiceNoAudioEl = el("voice-state-no-audio");
const voiceSpeakingEl = el("voice-state-speaking");
const bargeInBtn = el("voice-barge-in");
const slideoverEl = el("slideover");
const slideoverBackdrop = el("slideover-backdrop");
const slideoverBody = el("slideover-body");
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
const expandedEntities = new Set(); // entity ids whose "Show more" has been used
const drafts = new Map(); // threadId -> unsent composer text (§3.1)
const scrollTops = new Map(); // threadId -> conversation scrollTop (§3.1)
// threadId -> "working" | "unseen" | "failed". LIVE, per-thread, and only ever written
// from a positive `rich://` event — never inferred from silence, never from a timer.
const liveStatus = new Map();
// threadId -> { turnId, text } for a turn streaming in a thread that may not be on screen.
// This is what lets the CEO leave a working thread and come back to its live state (§2).
const liveByThread = new Map();
let activeThreadId = null;
let messages = []; // full history for the active thread, oldest first
let liveTurnId = null; // the turn currently streaming into the last-rendered slot, or null
let liveText = "";
let working = false;
let voiceMode = false;
let sessionAvatarShown = false; // Rich Hand mark shows on his first message THIS SESSION only
let renderedCount = 0; // how many of `messages` are currently mounted (virtualized window)
const RENDER_WINDOW = 40; // initial/incremental render chunk — infinite scroll, no pagination
let drillItems = []; // populated from the real `get_worker_status` command (see the
// rich://turn-started listener below) — honest-empty until the engine has ever
// completed a task since boot (richos-core's worker_status.rs).

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
  inputEl.placeholder = "Talk to Rich…";
  sendBtn.disabled = false;
  setMainView("conversation");
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
  el("unbound-view-detail").textContent =
    (navTree.unbound_explanation || rawError || "") +
    " Binding it is an explicit operator decision and there is no control for it in the app yet.";
  sendBlockedReason = "This thread has no entity home, so I can't take a message in it.";
  composerBlockedEl.textContent = sendBlockedReason;
  composerBlockedEl.hidden = false;
  composerScopeEl.hidden = true;
  inputEl.disabled = true;
  // The placeholder is part of the block: an inviting "Talk to Rich…" above a dead field
  // is the composer telling a small lie about what it will do.
  inputEl.placeholder = "Send is off for this thread";
  sendBtn.disabled = true;
  setMainView("unbound");
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
  el("entity-view-note").textContent =
    "Priorities and entity editing aren't wired yet — this area is defined in code, not settings.";

  composerScopeEl.textContent =
    (mode === "new" ? "New thread in " : "Talk to Rich about ") + entity.display_name;
  composerScopeEl.hidden = false;
  inputEl.placeholder = "Talk to Rich about " + entity.display_name + "…";

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

function stashThreadViewState() {
  if (mainView !== "conversation" || !activeThreadId) return;
  drafts.set(activeThreadId, inputEl.value);
  scrollTops.set(activeThreadId, conversationEl.scrollTop);
}

function restoreThreadViewState(threadId) {
  inputEl.value = drafts.get(threadId) || "";
  autoGrow();
  const top = scrollTops.get(threadId);
  // A thread that has never been opened lands at the bottom — the newest turn — which is
  // what `renderMessages` already did. Only a REMEMBERED position overrides that.
  if (typeof top === "number") conversationEl.scrollTop = top;
}

// ---- opening a thread ------------------------------------------------------------------

async function openThread(threadId) {
  const row = threadRow(threadId);
  if (!row) return;
  if (threadId === activeThreadId && mainView === "conversation") return;

  stashThreadViewState();
  clearLiveMark(threadId);
  activeThreadId = threadId;
  liveTurnId = null;
  liveText = "";
  drillItems = [];
  setWorking(false);
  closeSlideOver();
  closeThreadMenu();
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
  await loadMessages();
  if (mainView !== "conversation") return; // loadMessages fell into the unbound state
  restoreThreadViewState(threadId);

  // Returning to a thread whose turn is still streaming picks its live state back up
  // (§2: "return to a running thread without losing its live state").
  const live = liveByThread.get(threadId);
  if (live) {
    liveTurnId = live.turnId;
    liveText = live.text;
    setWorking(true);
    if (live.text) updateWorkingText();
  }
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
// Conversation rendering
// ---------------------------------------------------------------------------------------
function isProactive(msg, prevMsg) {
  // "Arrives with no CEO prompt above it" (§5.3) — today's backend always interleaves
  // user/assistant pairs from the same turn, so this stays dormant until a real proactive
  // seam (not yet built) emits an assistant-only turn. Forward-wired, not faked.
  if (msg.role !== "assistant") return false;
  if (!prevMsg) return true;
  return prevMsg.role !== "user" || prevMsg.turn_id !== msg.turn_id;
}

function speakerLabel(msg) {
  return msg.role === "assistant" ? "Rich" : "you";
}

function buildMessageEl(msg, prevMsg, opts) {
  opts = opts || {};
  const row = document.createElement("div");
  const proactive = isProactive(msg, prevMsg) && !opts.isFirstRun;
  row.className = "turn turn--" + msg.role + (proactive ? " turn--proactive" : "");

  const meta = document.createElement("div");
  meta.className = "turn-meta";

  if (msg.role === "assistant" && !sessionAvatarShown) {
    const avatar = document.createElement("img");
    avatar.className = "turn-avatar";
    avatar.src = "assets/rich-hand.png";
    avatar.alt = "";
    meta.appendChild(avatar);
    sessionAvatarShown = true;
  }

  const who = document.createElement("span");
  who.className = "turn-who";
  who.textContent = speakerLabel(msg);
  meta.appendChild(who);

  const time = document.createElement("span");
  time.className = "turn-time";
  time.textContent = formatTime(msg.at);
  meta.appendChild(time);

  if (proactive) {
    const whisper = document.createElement("span");
    whisper.className = "turn-whisper";
    whisper.textContent = "reached out";
    meta.appendChild(whisper);
  }

  row.appendChild(meta);

  const text = document.createElement("div");
  text.className = "turn-text";
  text.textContent = msg.text; // textContent only — no HTML injection, clean output
  row.appendChild(text);

  return row;
}

function renderFirstRun() {
  messagesEl.innerHTML = "";
  // Authored, in Rich's voice — never a blank screen. Client-side only: no backend command
  // seeds this yet (a real seeded intro is a small follow-up once the ledger supports it),
  // but the rendered result is identical to the acceptance bar in §6.1.
  const intro = {
    role: "assistant",
    text: "I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from there. You can type, or tap ◉ to talk to me.",
    turn_id: "intro",
    at: Date.now(),
  };
  const row = buildMessageEl(intro, null, { isFirstRun: true });
  row.querySelector(".turn-time").textContent = "now";
  messagesEl.appendChild(row);
  sessionAvatarShown = true;
}

function renderMessages() {
  if (messages.length === 0 && !working) {
    renderFirstRun();
    return;
  }
  messagesEl.innerHTML = "";
  const startIdx = Math.max(0, messages.length - renderedCount);
  for (let i = startIdx; i < messages.length; i++) {
    const row = buildMessageEl(messages[i], messages[i - 1]);
    messagesEl.appendChild(row);
  }
  if (working) {
    messagesEl.appendChild(buildWorkingRow());
  }
  scrollToBottom();
}

function scrollToBottom() {
  conversationEl.scrollTop = conversationEl.scrollHeight;
}

// Infinite-scroll-behind-the-scenes: load more of the already-fetched history as the CEO
// scrolls up. No pagination controls, no "load more" button — standing rule.
conversationEl.addEventListener("scroll", () => {
  if (conversationEl.scrollTop < 80 && renderedCount < messages.length) {
    const prevHeight = conversationEl.scrollHeight;
    renderedCount = Math.min(messages.length, renderedCount + RENDER_WINDOW);
    renderMessages();
    conversationEl.scrollTop = conversationEl.scrollHeight - prevHeight;
  }
});

// ---------------------------------------------------------------------------------------
// Working state + streaming (§3.1)
// ---------------------------------------------------------------------------------------
function buildWorkingRow() {
  const row = document.createElement("div");
  row.className = "turn turn--assistant turn--working";
  row.id = "working-row";

  const meta = document.createElement("div");
  meta.className = "turn-meta";
  const who = document.createElement("span");
  who.className = "turn-who";
  who.textContent = "Rich";
  meta.appendChild(who);
  row.appendChild(meta);

  const text = document.createElement("div");
  text.className = "turn-text turn-text--working";
  text.id = "working-text";
  if (liveTurnId && liveText) {
    // Streaming resolve: the working line already holds the growing reply — no jarring
    // swap from indicator to message (§3.1).
    text.textContent = liveText;
    text.classList.add("is-streaming");
  } else {
    text.innerHTML = 'Rich is working<span class="working-ellipsis"><i></i><i></i><i></i></span>';
  }
  row.appendChild(text);

  if (drillItems.length > 0) {
    row.appendChild(buildDrillChip());
  }

  return row;
}

function buildDrillChip() {
  const active = drillItems.filter((i) => i.state === "active").length;
  const needsYou = drillItems.filter((i) => i.state === "needs_you").length;
  const parts = [];
  if (active) parts.push(`${active} working`);
  if (needsYou) parts.push(`${needsYou} needs you`);

  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = "drill-chip";
  chip.textContent = "⋯ " + parts.join(" · ");
  chip.addEventListener("click", openSlideOver);
  return chip;
}

function setWorking(on) {
  working = on;
  const existing = document.getElementById("working-row");
  if (!on) {
    if (existing) existing.remove();
    liveTurnId = null;
    liveText = "";
    drillItems = [];
    return;
  }
  if (existing) return; // already showing
  messagesEl.appendChild(buildWorkingRow());
  scrollToBottom();
}

function updateWorkingText() {
  const textEl = document.getElementById("working-text");
  if (!textEl) return;
  textEl.textContent = liveText;
  textEl.classList.add("is-streaming");
  scrollToBottom();
}

async function loadMessages() {
  // SCOPED READ, AND IT CAN REFUSE. `get_messages` became fallible when threads gained an
  // entity home: a thread written before entity scoping existed returns
  // `LedgerError::UnboundThread` rather than an empty list, because "I will not serve
  // this" and "there is nothing here" are different statements. Before this catch existed
  // the rejection was unhandled and opening such a thread simply broke the shell.
  try {
    messages = await Bridge.invoke("get_messages", { threadId: activeThreadId });
  } catch (e) {
    messages = [];
    showUnboundView(threadRow(activeThreadId), String(e));
    return;
  }
  renderedCount = Math.min(messages.length, RENDER_WINDOW);
  renderMessages();
}

// ---------------------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------------------
async function send() {
  const text = inputEl.value.trim();
  if (!text || working) return;
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
  // new-thread screen ("no pre-created thread record until the CEO sends the first
  // message"). The record is created here, with its immutable entity_id, before the
  // message goes anywhere — step 1 then step 2 of §3.3, in that order.
  if (draftEntityId) {
    const entityId = draftEntityId;
    let newId;
    try {
      newId = await Bridge.invoke("create_thread_in", { entityId, title: provisionalTitle(text) });
    } catch (e) {
      composerBlockedEl.textContent = typeof e === "string" ? e : String(e);
      composerBlockedEl.hidden = false;
      inputEl.value = text; // never swallow the CEO's words
      autoGrow();
      return;
    }
    draftEntityId = null;
    await refreshNavigation();
    await openThread(newId);
  }

  // Optimistic append so the CEO's line appears immediately.
  messages.push({ role: "user", text, turn_id: "pending", at: Date.now() });
  renderedCount = Math.min(messages.length, renderedCount + 1);
  renderMessages();
  setWorking(true);

  // `send_message` resolves with the reconciled snapshot, but per STREAMING.md's ordering
  // guarantee the UI always gets exactly one terminal event (`rich://turn-completed` or
  // `rich://turn-error`) for the turn — those listeners (below) are the ONE place that
  // clears the working state and finalizes the render. This call is only responsible for
  // the outright-rejection case: an invoke that fails before any turn ever started (e.g.
  // "not connected" — no lease, so no stream events will ever fire for this attempt).
  try {
    await Bridge.invoke("send_message", { text });
  } catch (e) {
    if (!working) return; // a terminal stream event already resolved this turn
    setWorking(false);
    messages.push({
      role: "assistant",
      text: typeof e === "string" ? e : "Something went sideways on my end — one moment, I'll sort it.",
      turn_id: "error_" + Date.now(),
      at: Date.now(),
    });
    renderedCount += 1;
    renderMessages();
  }
}

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

// Auto-growing single field (§2.3) — a few lines, then it scrolls; never dominates.
function autoGrow() {
  inputEl.style.height = "auto";
  const max = 5 * 22; // ~5 lines
  inputEl.style.height = Math.min(inputEl.scrollHeight, max) + "px";
}
inputEl.addEventListener("input", autoGrow);

el("rail-new-thread").addEventListener("click", startNewThreadFlow);
el("nav-search").addEventListener("click", openSearch);

// ---------------------------------------------------------------------------------------
// Streaming event wiring (app/STREAMING.md)
// ---------------------------------------------------------------------------------------
Bridge.listen("rich://turn-started", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  liveTurnId = payload.turnId;
  liveText = "";
  setWorking(true);
  pollWorkerStatus();
});

Bridge.listen("rich://chunk", ({ payload }) => {
  if (payload.threadId !== activeThreadId || payload.turnId !== liveTurnId) return;
  liveText += payload.textDelta; // seq order is guaranteed by the spine (0-based, strictly increasing)
  updateWorkingText();
});

Bridge.listen("rich://turn-completed", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  setWorking(false);
  loadMessages(); // pulls the reconciled ledger snapshot as the durable record
});

Bridge.listen("rich://turn-error", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  setWorking(false);
  messages.push({
    role: "assistant",
    text: "I hit a snag mid-thought and had to stop — say the word and I'll pick it back up.",
    turn_id: "error_" + payload.turnId,
    at: payload.at || Date.now(),
  });
  renderedCount += 1;
  renderMessages();
});

// The real proactive-attention seam (§5, architecture §2.3/§4.2): Rich raised a Tier 1/2
// message via the backend seam (`raise_proactive_message`, spine.rs `raise_proactive`).
// The event only ever fires for Tier 1/2 (Tier 3/Silent never notifies, per §5.1) — the
// UI's job is just to reload the reconciled ledger; the "reached out" whisper-cue render
// (isProactive(), above) already fires correctly because a proactive turn has no paired
// user message ahead of it.
Bridge.listen("rich://proactive-message", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  loadMessages();
});
// The mock harness's manual test hooks (window.__RICHOS_MOCK__.simulateProactiveDigest /
// simulateProactiveInterrupt) fire this separate event name directly (mock.js predates
// the real backend seam and isn't wired to `raise_proactive_message`) — kept so design
// and QA can still exercise both proactive tiers without a live attention-seam trigger.
Bridge.listen("rich://mock-proactive", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  loadMessages();
});

// The real worker-status drill-down (§3.2 / architecture P3.2), backed by
// `get_worker_status` (main.rs -> richos-core's worker_status.rs, reading the engine's
// task-events.jsonl). Polled on turn-started (above) rather than continuously — the
// chip is a courtesy, not a live dashboard, and this is a read-only snapshot pull, not a
// subscription. Honest-empty (drillItems stays []) when nothing has completed since boot.
async function pollWorkerStatus() {
  try {
    const status = await Bridge.invoke("get_worker_status");
    drillItems = status.items || [];
  } catch (_e) {
    // Unwired (mock harness) or a genuine read failure — never fabricate activity;
    // just leave the chip absent.
    drillItems = [];
  }
  if (working) renderMessages();
}

// Dev-mock-only drill-down signal (§3.2) — the mock harness's manual test hook
// (window.__RICHOS_MOCK__.simulateDrillChip) still uses this event directly, since
// `get_worker_status` is one of the commands the mock harness deliberately leaves
// unwired (see mock.js's default-reject comment) so design and QA can drive the
// drill-down chip's states without a live engine event log to fake.
Bridge.listen("rich://mock-worker-status", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  drillItems = payload.items || [];
  if (working) renderMessages();
});

// ---------------------------------------------------------------------------------------
// Slide-over — read-only, summoned, never resident (§3.2)
// ---------------------------------------------------------------------------------------
function openSlideOver() {
  slideoverBody.innerHTML = "";
  for (const item of drillItems) {
    const row = document.createElement("div");
    row.className = "slide-item slide-item--" + item.state;
    const marker = { active: "●", done: "○", needs_you: "⚑" }[item.state] || "●";
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

function richVoiceSays(text) {
  messages.push({ role: "assistant", text, turn_id: "voice_" + Date.now(), at: Date.now() });
  renderedCount += 1;
  renderMessages();
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
  messages.push({ role: "user", text: payload.text, turn_id: "pending", at: payload.at || Date.now() });
  renderedCount = Math.min(messages.length, renderedCount + 1);
  renderMessages();
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
  liveByThread.set(payload.threadId, { turnId: payload.turnId, text: "" });
  renderRail();
});

Bridge.listen("rich://chunk", ({ payload }) => {
  const live = liveByThread.get(payload.threadId);
  if (live && live.turnId === payload.turnId) live.text += payload.textDelta;
});

Bridge.listen("rich://turn-completed", ({ payload }) => {
  liveByThread.delete(payload.threadId);
  // §3.2 "Completed while away: small completion mark UNTIL OPENED". If the CEO is looking
  // at the thread, there is nothing to flag — he just watched it finish.
  if (payload.threadId === activeThreadId) liveStatus.delete(payload.threadId);
  else liveStatus.set(payload.threadId, "unseen");
  refreshNavigation();
});

Bridge.listen("rich://turn-error", ({ payload }) => {
  liveByThread.delete(payload.threadId);
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
  if (!navPrefs) navPrefs = { sidebar_width: RAIL_DEFAULT, sidebar_collapsed: false, collapsed_entities: [], pinned_threads: [], archived_threads: [], renamed_threads: {} };
  applyRailWidth(navPrefs.sidebar_width || RAIL_DEFAULT);
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
  renderRail();
  inputEl.focus();
}

init();
