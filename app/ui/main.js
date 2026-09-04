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
const railIdentityEl = el("rail-identity");
const railInitialsEl = el("rail-initials");
const railUserNameEl = el("rail-user-name");
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
const entityPickerTitleEl = el("entity-picker-title");
const entityPickerNoteEl = el("entity-picker-note");
const entityAddEl = el("entity-add");
const entityAddLeadEl = el("entity-add-lead");
const entityAddNameEl = el("entity-add-name");
const entityAddFolderEl = el("entity-add-folder");
const entityAddErrorEl = el("entity-add-error");
const entityAddGoEl = el("entity-add-go");
const chooseCompanyRowEl = el("composer-choose-company");
const chooseCompanyBtnEl = el("choose-company-btn");
const memorySetupEl = el("memory-setup");
const memorySetupTitleEl = el("memory-setup-title");
const memorySetupNoteEl = el("memory-setup-note");
const memorySetupLocationEl = el("memory-setup-location");
const memorySetupGoEl = el("memory-setup-go");
const memorySetupLaterEl = el("memory-setup-later");
const memorySetupCloseEl = el("memory-setup-close");
const setupSheetEl = el("setup-sheet");
const setupTitleEl = el("setup-title");
const setupNoteEl = el("setup-note");
const setupItemsEl = el("setup-items");
const setupAccountEl = el("setup-account");
const setupProgressEl = el("setup-progress");
const setupErrorEl = el("setup-error");
const setupGoEl = el("setup-go");
const setupLaterEl = el("setup-later");
const setupCloseEl = el("setup-close");
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
/// WHICH COMPANY THIS COPY OF RICH WORKS FOR — the shape `entity_choice` returns.
/// `chosen: null` is the state that makes the app ask, and it is the ONLY signal the boot
/// path needs. `null` here (rather than an object with a null `chosen`) means the command
/// itself did not answer, which is the browser preview and is treated as "not asking".
let entityChoice = null;

let mainView = "conversation"; // "conversation" | "entity" | "unbound"
let viewEntityId = null; // the entity whose overview / new-thread screen is showing
let draftEntityId = null; // §3.3: a draft thread bound to this entity, with NO record yet
let sendBlockedReason = null; // §21: non-null means send is refused, with this reason
/// What the composer says when NOTHING is running (§9.1). Held as state because §9.2
/// replaces it with "Add context or steer Rich…" while Rich works, and the idle text is
/// view-dependent ("Talk to Rich about a named company…" on an entity overview) — so it has to be
/// restored, not re-derived.
let idlePlaceholder = "Talk to Rich…";
const expandedEntities = new Set(); // entity ids whose "Show more" has been used
const drafts = new Map(); // threadId -> unsent composer text (§3.1)
const scrollTops = new Map(); // threadId -> conversation scrollTop (§3.1)

// ---- and they survive a crash, which they did not until 2026-08-31 ----------------------
//
// THE GAP THIS CLOSES. The CEO's ruling on the splash carried a second requirement in its
// own right: "a crash-restart returns the user to exactly where they were." Most of that
// already worked and is guarded by `app/ui/tests/restart-scope.js` — the turn ledger knows
// an in-flight turn is unknown rather than finished, a mid-turn crash draws his prompt
// exactly once, the durable snapshot recovers missed stream events. But the two maps above
// were `new Map()` and nothing else. A half-written sentence in the composer, and the place
// in the conversation he had scrolled back to, survived a THREAD SWITCH and died with the
// process. That is the difference between "restart" and "crash-restart specifically", and
// it is the part he would actually notice.
//
// WRITTEN CONTINUOUSLY, NEVER ON THE WAY OUT. A crash is precisely the case where no exit
// handler runs, so `beforeunload` would save exactly the sessions that do not need saving.
// Every write below is debounced by `PARK_DEBOUNCE_MS` and happens while he types.
//
// LOCAL, and the same storage the splash switch already uses — this window's own origin, on
// his own disk, read by nothing else. `launch_no_outbound_tests.rs` covers this file.
//
// THE ENTITY BOUNDARY IS PRESERVED VERBATIM. `stashThreadViewState`'s comment explains why
// a draft may never follow him out of its entity: one Enter files the CEO's words in the
// wrong company. Persisting the maps changes nothing about that — the keys are unchanged,
// so a restored draft lands in exactly the thread it was written to and nowhere else.
const KEY_DRAFTS = "richos.view.drafts";
const KEY_SCROLL = "richos.view.scroll";

/// How long to wait after a keystroke before parking the draft. Long enough that a fast
/// typist is not writing to disk on every character, short enough that the most a crash can
/// cost him is the last few words rather than the paragraph.
const PARK_DEBOUNCE_MS = 400;

/// A ceiling on what is kept, so a pasted document cannot fill the origin's storage quota
/// and take the splash preference down with it. Drafts are parked newest-first and the
/// overflow is dropped; the ACTIVE thread's draft is written first, so the one he is
/// looking at is the one that is never the casualty.
const PARKED_DRAFT_MAX_CHARS = 64 * 1024;

function readJsonLocal(key) {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch (_e) {
    // Storage denied, or a value some other version wrote. Either way the app opens with
    // empty maps, which is exactly today's behaviour and never a broken composer.
    return null;
  }
}

function writeJsonLocal(key, value) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch (_e) {
    /* A quota or a denied store costs the restore, never the session. */
  }
}

/// Refill the maps from the last run. Called once, at parse time, so the first `openThread`
/// of the launch already has them.
function loadParkedViewState() {
  const savedDrafts = readJsonLocal(KEY_DRAFTS);
  if (savedDrafts) {
    for (const [key, text] of Object.entries(savedDrafts)) {
      if (typeof text === "string" && text) drafts.set(key, text);
    }
  }
  const savedScroll = readJsonLocal(KEY_SCROLL);
  if (savedScroll) {
    for (const [key, top] of Object.entries(savedScroll)) {
      if (typeof top === "number" && isFinite(top) && top >= 0) scrollTops.set(key, top);
    }
  }
}

let parkTimer = null;

/// Write both maps out. The ACTIVE thread's live composer text is folded in first, because
/// `drafts` only receives it when he navigates away and a crash is not a navigation.
function parkViewStateNow() {
  const out = {};
  let budget = PARKED_DRAFT_MAX_CHARS;
  const put = (key, text) => {
    if (!key || typeof text !== "string" || !text) return;
    if (text.length > budget) return;
    budget -= text.length;
    out[key] = text;
  };
  if (mainView === "conversation" && activeThreadId) put(activeThreadId, inputEl.value);
  else if (mainView === "entity" && viewEntityId) put(ENTITY_DRAFT_PREFIX + viewEntityId, inputEl.value);
  for (const [key, text] of drafts) if (!(key in out)) put(key, text);
  writeJsonLocal(KEY_DRAFTS, out);

  const tops = {};
  for (const [key, top] of scrollTops) tops[key] = top;
  if (mainView === "conversation" && activeThreadId) tops[activeThreadId] = conversationEl.scrollTop;
  writeJsonLocal(KEY_SCROLL, tops);
}

/// Park soon. Every caller uses this rather than `parkViewStateNow`, so no path can turn
/// typing into a write per character.
function parkViewStateSoon() {
  if (parkTimer !== null) return;
  parkTimer = setTimeout(() => {
    parkTimer = null;
    parkViewStateNow();
  }, PARK_DEBOUNCE_MS);
}

loadParkedViewState();
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
/// **CAN THIS MACHINE TURN SPEECH INTO WORDS?** Read once at launch from `voice_readiness`.
///
/// FALSE UNTIL PROVEN, and the direction is the whole point. A command that is missing, a
/// backend that errors, a preview that does not implement it — every unknown resolves to
/// "do not offer voice", because the failure this exists to prevent is an affordance that
/// is offered and cannot work. The opposite failure (voice quietly unoffered on a machine
/// that could have run it) costs a feature nobody was promised.
let voiceAvailable = false;
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
  // Shape first, color second: §18 requires status never rely on color alone, and the
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
  // app, and editing an entity after it exists is not built.
  //
  // THE SECOND HALF OF THIS NOTE WAS TRUE AND IS NOT ANY MORE. It read "the entity registry
  // is `EntityRegistry::dogfood()` — hard-coded on purpose so a missing or edited config
  // file cannot silently move a privacy boundary". That argument was reasoning about one
  // machine: on every other machine the hard-coded table published its author's company
  // list and left the app with no company the person could actually use. The registry is
  // his own file now (`docs/entity-registry.md`) and ADDING one is built — `register_entity`,
  // in the picker. What is still absent is EDITING one that exists, which is what this note
  // now says. Saying so is better than an empty panel that implies the data is merely
  // missing today.
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
  // A navigation is a settled moment and cheap to write, so it is written at once rather
  // than debounced — the debounce exists for keystrokes, not for this.
  parkViewStateNow();
}

/// Namespace for a draft that belongs to an ENTITY's new-thread composer rather than to a
/// thread. Prefixed so it can never collide with a thread id.
const ENTITY_DRAFT_PREFIX = "entity:";

/// A scroll position waiting for the DOM it belongs to. `{ threadId, top }`, or `top: null`
/// for "land at the newest turn". Consumed by `flushRender` — see below for why it cannot
/// be applied where it is set.
let pendingScrollRestore = null;

function restoreThreadViewState(threadId) {
  inputEl.value = drafts.get(threadId) || "";
  autoGrow();
  const top = scrollTops.get(threadId);
  // §15: "preserve each thread's scroll position during thread switching". A thread that
  // has never been opened lands at the bottom — the newest turn.
  //
  // THE POSITION IS QUEUED, NOT APPLIED. This function runs at the end of `openThread`,
  // where `loadTimeline` has updated the MODEL but the render is still one animation frame
  // away (§15: "at most once per animation frame") — so the pane on screen is still the
  // PREVIOUS thread's DOM, at the previous thread's height. Writing the position here wrote
  // it against the wrong document twice over: the browser clamped it to the old content's
  // range, and then `flushRender`'s height anchor — which exists to hold content still when
  // something ABOVE it changes height — added the difference between the two threads'
  // heights on top.
  //
  // Measured before the fix, at 1200x420 with the seeded acme thread: parked at 0, restored
  // to 121; parked at 50, restored to 171; parked at 200, restored to 250 (the bottom).
  // A constant +121px = acme's scrollHeight minus the thread that was on screen when the
  // position was written. `app/ui/tests/restart-scope.js` is the check that fails on it.
  pendingScrollRestore = { threadId, top: typeof top === "number" ? top : null };
  followBottom = typeof top === "number" ? false : true;
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
  // THIS thread's techy answer, read before the load that depends on it. A per-thread
  // override is per thread, so it is never carried over from the one being left.
  await refreshTechy(threadId);
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
  // And where he scrolled TO outlives the process. Debounced: a scroll fires per frame.
  parkViewStateSoon();
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
    // TECHY MODE (§3.4). All three are passed unconditionally: the renderer draws a
    // technical row only for an item that CARRIES `detail`, which only the technical view
    // supplies, so with the mode off these are never reached. Gating them on `techyOn()`
    // would put the same decision in two places and let them disagree.
    isMachineryExpanded: (id) => window.RichTimeline.isMachineryExpanded(timelineModel, id),
    toggleMachinery: (id) => {
      window.RichTimeline.toggleMachinery(timelineModel, id);
      scheduleRender();
    },
    machineryRaw: fillMachineryRaw,
  });
  // The DOM was just rebuilt; re-mark the open worker's chip.
  markSelectedChip();
  if (turns.some((t) => t.stream.some((i) => i.kind === "rich_message"))) sessionAvatarShown = true;

  if (timelineModel.items.size === 0 && timelineModel.turnOrder.length === 0) renderFirstRun();

  if (focusId) {
    const again = messagesEl.querySelector('[id="' + focusId.replace(/(["\\])/g, "\\$1") + '"]');
    if (again) again.focus({ preventScroll: true });
  }

  if (pendingScrollRestore && pendingScrollRestore.threadId === timelineModel.threadId) {
    // §15, applied to the thread's OWN rendered DOM. The height anchor below is deliberately
    // skipped here: it measures a change in THIS thread's content, and across a thread
    // switch the two heights belong to two different conversations.
    const want = pendingScrollRestore.top;
    pendingScrollRestore = null;
    conversationEl.scrollTop = want === null ? conversationEl.scrollHeight : want;
    followBottom = atBottom();
  } else if (followBottom) {
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

/// The first thing Rich says, in two pieces because the second one is a PROMISE about a
/// control. Kept apart so the promise can be withheld without rewriting the greeting.
const GREETING =
  "I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from there.";
const GREETING_VOICE_INVITE = "You can type, or tap ◉ to talk to me.";

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
  // THE GREETING NEVER INVITES A CONTROL THAT IS NOT THERE.
  //
  // It was one sentence ending "You can type, or tap ◉ to talk to me." — and on a
  // customer's fresh Mac there is no speech model, so ◉ opened a hot microphone, said
  // "listening…", and never transcribed and never said it could not (ray-opus-a1,
  // published v1.0.0, 2026-09-04). An app that names a control in its first sentence has
  // promised that control works.
  //
  // So the invitation is a SECOND sentence, appended only when `voice_readiness` says this
  // machine can actually turn speech into words — the same answer that decides whether the
  // button exists at all. Where voice is off, nothing here mentions it: a stranger cannot
  // miss a feature he was never offered, and he can very much notice one that pretends.
  body.textContent = voiceAvailable ? GREETING + " " + GREETING_VOICE_INVITE : GREETING;
  art.appendChild(body);
  messagesEl.appendChild(art);
  sessionAvatarShown = true;
}

/// The reload path. Fails closed exactly like `get_messages` did: an unbound thread refuses
/// rather than returning an empty conversation, and the calm §21 screen takes over.
///
/// TWO COMMANDS, ONE MODEL. With techy mode off this is `get_timeline`, byte for byte what
/// it always was. With techy mode on for this thread it is `get_machinery`, whose payload
/// wraps the SAME timeline projected at `ViewMode::Technical` — same items, same ids, same
/// `(turn, slot, sequence)` order — plus the state line. The renderer is not told which one
/// it got; it draws a technical row for any item that carries `detail`, and only the
/// technical view supplies one (§3.3: the calm view is untouched because it cannot match).
async function loadTimeline() {
  const techy = techyOn();
  let snapshot;
  try {
    if (techy) {
      const machinery = await Bridge.invoke("get_machinery", { threadId: activeThreadId });
      renderTechyState(machinery);
      renderBetweenTurns(machinery);
      snapshot = machinery.timeline;
    } else {
      renderTechyState(null);
      // §1.5's lane is techy-mode-only. `null` HIDES the section and EMPTIES its rows —
      // both, because `hidden` alone would leave the previous thread's rows sitting in the
      // document, one CSS mistake from being readable. The heading and lede are static
      // markup and stay where they are; `hidden` is what keeps them out of `innerText`,
      // which is what §3.3's "no affordance at all when off" is measured on (techy.js 18).
      renderBetweenTurns(null);
      snapshot = await Bridge.invoke("get_timeline", { threadId: activeThreadId });
    }
  } catch (e) {
    const msg = String(e);
    // The mock harness leaves some commands unwired; a genuine scope refusal is a different
    // statement and gets the §21 screen.
    window.RichTimeline.applySnapshot(timelineModel, { items: [] });
    // The read failed, so there is nothing to say about the lane. Emptied rather than left
    // showing the PREVIOUS thread's rows, which would be the worst of the three states: a
    // section that looks answered and is answering about somewhere else.
    renderBetweenTurns(null);
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
  // THE SENT WORDS STOP BEING A DRAFT, on disk as well as in the box. Without this the
  // parked copy outlives the send and a crash would put a sentence he has already sent back
  // into his composer — the one restore that would be worse than no restore at all.
  if (activeThreadId) drafts.delete(activeThreadId);
  parkViewStateNow();

  // §3.3 first send in a draft thread: NOTHING was persisted when the CEO opened the
  // new-thread screen. The record is created here, with its immutable entity_id, before the
  // message goes anywhere — step 1 then step 2 of §3.3, in that order.
  if (draftEntityId) {
    const entityId = draftEntityId;

    // HIS WORDS GO UP BEFORE THE THREAD EXISTS, AND THIS IS THE FIRST MESSAGE ANYONE EVER
    // SENDS. Measured on the published build under WebKit, with every bridge call delayed
    // to model a cold first run: the composer emptied at 161ms (`inputEl.value = ""` above
    // is synchronous, before any await) and then, for the whole ten seconds that were
    // sampled, `#messages` held zero user bubbles and the screen still read the greeting.
    // His sentence left the box and NOTHING took its place — which is what makes a person
    // press Send a second time, and two messages is a worse defect than a slow one.
    //
    // The cause is the await chain below: `create_thread_in`, then `refreshNavigation`,
    // then `openThread` (itself `switch_thread` + `active_context` + `get_timeline`), and
    // only after all of it did the §25 bubble get added. It could not simply be moved
    // earlier for two reasons, and this block answers both:
    //
    //   1. THE SURFACE IS WRONG. Until `openThread` runs he is looking at the entity's
    //      new-thread screen; `#messages` is hidden, so a bubble put there is invisible.
    //      So the conversation surface is shown FIRST, which is where the sentence is
    //      about to live anyway.
    //   2. THE MODEL IS REPLACED. `openThread` builds a fresh model (one thread, one
    //      model) and `applySnapshot` clears `items` and `pendingUser` wholesale, so any
    //      bubble added before it is destroyed by it. This one is therefore deliberately
    //      DISPOSABLE — it lives in a throwaway model for the seconds before the thread
    //      exists, and the real §25 bubble is added to the real model below, exactly as it
    //      always was. Nothing here changes what a live turn renders.
    //
    // The throwaway model is UNBOUND, and that is what makes it inert: `accepts()` refuses
    // every payload while `model.threadId == null`, so no `rich://` event for any other
    // thread can reach it, adopt it or write into it.
    //
    // The one guard this moves past: `openThread` returns early when the thread asked for
    // is already active AND the view is already `conversation`. The view is now
    // `conversation` when it reaches there, so only the first half is left holding it —
    // and `newId` is a thread `create_thread_in` has just minted, so it cannot be the
    // active one. The early return stays unreachable on this path.
    timelineModel = window.RichTimeline.createModel();
    showConversationView(); // clears `draftEntityId`; `entityId` is captured above
    const optimisticId = window.RichTimeline.addPendingUserMessage(timelineModel, text, Date.now());
    followBottom = true;
    scheduleRender();

    let newId;
    try {
      newId = await Bridge.invoke("create_thread_in", { entityId, title: provisionalTitle(text) });
    } catch (e) {
      // THE BUBBLE IS WITHDRAWN BEFORE ANYTHING ELSE. No thread was created, so nothing was
      // sent; a sentence left on screen looking delivered would be a worse lie than the
      // blank wait this block exists to fix. Then back to the screen he was on, with his
      // words in the box — `showEntityView` re-arms `draftEntityId`, so pressing Send again
      // takes the same path rather than filing the message somewhere he did not choose.
      window.RichTimeline.dropPendingUserMessage(timelineModel, optimisticId);
      scheduleRender();
      showEntityView(entityId, "new");
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
/// join the running turn — the agent runs one turn at a time, and the continuity
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
  // The half-written sentence outlives the process. Debounced — see PARK_DEBOUNCE_MS.
  parkViewStateSoon();
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

/// Ask the backend whether voice can work here, and shape the surface to the answer.
///
/// ONE READ, AT LAUNCH. Nothing installs a speech model while the app is running — the
/// first-run setup sheet installs Claude Code and the engine and neither is whisper — so
/// re-asking would be a round trip that cannot change its answer.
async function refreshVoiceReadiness() {
  const r = await invokeQuiet("voice_readiness");
  voiceAvailable = !!(r && r.available === true);
  // NOT OFFERED, rather than offered-and-inert. A dimmed control at a demo invites a press
  // and then a refusal in front of an audience; a control that is not there costs nothing.
  // `start_voice_capture` still refuses with Rich's own sentence for anything that reaches
  // it another way, so this is the affordance half of the fix and not the whole of it.
  talkToggleBtn.hidden = !voiceAvailable;
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
  // What the CEO said appears in the thread the moment it is recognized — voice and text are
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
/// Open the preferences popover, from the gear or from the unset identity row. Named
/// because there are now two entrances and an inline listener cannot be one of them.
function openAssertivenessPopover() {
  if (assertivenessPopover.hidden === false) return;
  assertivenessPopover.hidden = false;
  settingsBtn.setAttribute("aria-expanded", "true");
  syncRetentionFromBackend();
  const name = el("user-name-input");
  if (name) name.focus();
}
settingsBtn.addEventListener("click", () => {
  const open = assertivenessPopover.hidden === false;
  assertivenessPopover.hidden = open;
  settingsBtn.setAttribute("aria-expanded", String(!open));
  // Re-read the retention window every time the popover OPENS, not just at boot. It is the
  // one preference in here that a person can also change by editing `config.json`, and the
  // popover is the only screen that claims to say what it is — a stale claim about a setting
  // that deletes is worse than no claim. The read is one command over a file of a few
  // hundred bytes, off any hot path, on an explicit click.
  if (!open) syncRetentionFromBackend();
});
document.addEventListener("click", (e) => {
  if (railIdentityEl && railIdentityEl.contains(e.target)) return;
  if (!assertivenessPopover.hidden && !assertivenessPopover.contains(e.target) && e.target !== settingsBtn) {
    assertivenessPopover.hidden = true;
    settingsBtn.setAttribute("aria-expanded", "false");
  }
});

// ---------------------------------------------------------------------------------------
// The opening screen's off switch — the same shape as the dial above, for the same reason.
//
// `splash.js` has to know whether to draw BEFORE anything can be awaited, so it reads
// `localStorage` synchronously; the Rust `ConfigStore` is the durable source of truth and
// is reconciled here, after boot, exactly as `syncAssertivenessFromBackend` does. The two
// sides agree on what an absent value means — ON — so a first launch cannot disagree with
// itself (`config.rs`'s `splash_default`, and `splash.js`'s `enabled()`).
//
// The keys are read off `window.RichSplash` rather than retyped, so there is one place the
// strings live.
// ---------------------------------------------------------------------------------------
const splashToggle = el("splash-enabled");
function splashKey(name) {
  return window.RichSplash ? window.RichSplash[name] : null;
}
function readSplashEnabled() {
  const key = splashKey("KEY_ENABLED");
  if (!key) return true;
  return window.localStorage.getItem(key) !== "false";
}
function writeSplashEnabled(on) {
  const key = splashKey("KEY_ENABLED");
  if (key) window.localStorage.setItem(key, on ? "true" : "false");
}
/// Both entrances to the splash's off switch, moved through one function.
///
/// The CEO restated on 2026-08-31 that turning the opening screen off FROM SETTINGS is a
/// requirement. It already existed behind the rail's gear and it still does — nothing was
/// moved — but "settings" now also means the button on every screen, so that carries the
/// same switch. Two doors, one state, and this is the only place that writes it.
///
/// It writes the local mirror FIRST and the durable store second, deliberately: splash.js
/// reads the mirror synchronously before the app has a bridge, so the mirror is what decides
/// the next launch. A failed durable write costs the preference at reinstall, not tonight.
function setSplashEnabled(on) {
  writeSplashEnabled(on);
  if (splashToggle) splashToggle.checked = on;
  window.RichSettings.paint();
  return Bridge.invoke("set_splash_enabled", { enabled: on }).catch(() => {
    // Unwired (the mock harness) or a genuine write failure. The local mirror already
    // carries his choice and the next launch honours it; there is nothing here worth
    // interrupting him about.
  });
}

window.RichSettings.registerSplash({
  read: () => readSplashEnabled(),
  write: (on) => setSplashEnabled(on),
});

if (splashToggle) {
  splashToggle.checked = readSplashEnabled();
  splashToggle.addEventListener("change", () => {
    const on = splashToggle.checked;
    setSplashEnabled(on);
  });
}
async function syncSplashFromBackend() {
  try {
    const backendValue = (await Bridge.invoke("splash_enabled")) !== false;
    writeSplashEnabled(backendValue);
    if (splashToggle) splashToggle.checked = backendValue;
  } catch (_e) {
    // Unwired (the mock harness): the localStorage-only value already painted correctly.
  }
}
/// Tell the durable store the surface has been seen. Idempotent on the Rust side — only the
/// first call in a store's life touches the disk — and it is the zero point time-to-disable
/// is measured from. MEASUREMENT, never display: nothing reads it back to the CEO.
///
/// It also pushes the id that was drawn onto the launch record's RECENCY RING (CEO,
/// 2026-08-31): remembering only the last one prevents an immediate repeat and nothing else,
/// so a draw can show the same three all week and still never repeat back-to-back. The id
/// comes from `state.variationId`, which is set where the node is inserted, so the ring
/// holds what was ON SCREEN rather than what was chosen — `splash.js` has three paths that
/// choose and then decline to render, and all three leave `shown` false.
function noteSplashShown() {
  if (!window.RichSplash || !window.RichSplash.state.shown) return;
  Bridge.invoke("splash_note_shown").catch(() => {});
  const id = window.RichSplash.state.variationId;
  if (id) Bridge.invoke("launch_note_splash_shown", { id }).catch(() => {});
}

/// THE LAUNCH RECORD, read once at boot and put where the reward logic will find it.
///
/// **The offset is computed HERE and passed in**, because this is the only layer in the
/// process that knows what "local" means. The CEO ruled that every timestamp is stored as
/// UTC epoch millis and every bucket — today, this week, month, year — is computed against
/// his LOCAL calendar at read time: the market is US founder-CEOs whose evening is already
/// tomorrow in UTC, so UTC bucketing would mis-date the commonest usage moment every day.
/// `getTimezoneOffset()` is minutes to ADD to local to get UTC, i.e. +420 in California, so
/// it is negated into the offset-from-UTC-positive-east that `launch.rs` takes.
///
/// **NOTHING RENDERS THIS.** §5 of the splash design bans every counter, streak and score
/// from the CEO's screen, and this changes nothing he can see. It is the record the reward
/// selection will read, wired ahead of that logic existing — which is the same shape the
/// company-name plumbing landed in.
async function readLaunchRecord() {
  const utcOffsetMinutes = -new Date().getTimezoneOffset();
  const record = await invokeQuiet("launch_state", { utcOffsetMinutes });
  window.RichLaunch = record || { kind: null, counts: null, readable: false };
}

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

/// THE TITLE FOR EACH OF THE PICKER'S TWO JOBS, and they are two jobs rather than one.
///
/// `THREAD` is what "+ New thread" has always asked: which company is THIS conversation
/// for. `COMPANY` is the launch-time question that had no surface at all until this pass —
/// which company is this COPY of Rich for — and it is the one a double-clicked bundle is
/// always in, because a Finder launch has working directory `/`, which owns no entity.
const PICKER_TITLE_THREAD = "Which entity is this work in?";
const PICKER_TITLE_COMPANY = "Which company is this copy of Rich for?";
const PICKER_NOTE_COMPANY =
  "I'll keep everything you tell me under the company you pick, and I'll remember it — " +
  "you won't be asked again. You can change it later in Settings.";

/// The lead line above the add-a-company form, in its two states.
///
/// TWO, because the condition has two causes and they are not the same question. An install
/// with companies already listed is being offered "and one more"; an install with NO
/// companies has nothing to choose between, and the honest opening is that RichOS has not
/// been told about any of his businesses yet — not a silent, empty dialog, which is what a
/// registry-driven picker renders when the registry is empty.
const ADD_COMPANY_LEAD_FIRST =
  "I don't know about any of your companies yet. Tell me one and I'll start keeping its " +
  "work together — you can add the rest whenever you like.";
const ADD_COMPANY_LEAD_MORE = "Not one of these? Add it here.";

/// What he is told when the registry file exists and could not be read.
///
/// A DIFFERENT SENTENCE from the empty one, deliberately. "You haven't told me yet" and "you
/// told me and I can't read it" call for opposite responses, and answering the second with
/// the first would invite him to re-enter a list that is already on disk one typo away from
/// working — while quietly implying the one he wrote is gone.
function registryUnreadableLine(path) {
  return (
    "Your list of companies is saved at " + path + ", and I couldn't read it just now, so " +
    "I'm not showing any — rather than showing you a wrong list. That file is fixed by " +
    "whoever set RichOS up. You can also add a company here in the meantime."
  );
}

function openEntityPicker(onPick, opts) {
  const forCompany = !!(opts && opts.forCompany);
  entityPickerResolve = onPick;
  entityPickerTitleEl.textContent = forCompany ? PICKER_TITLE_COMPANY : PICKER_TITLE_THREAD;
  entityPickerNoteEl.textContent = forCompany ? PICKER_NOTE_COMPANY : "";
  entityPickerNoteEl.hidden = !forCompany;
  // THE ADD FORM, and only for the question where "none of these" is a true answer.
  // Choosing which company ONE thread is for is a choice among companies he has; being
  // asked which company this COPY of Rich is for is the question a first launch asks, and
  // before 2026-09-04 it had no answer at all for anyone but the app's author.
  entityAddEl.hidden = !forCompany;
  if (forCompany) {
    const unreadable = entityChoice && entityChoice.registrySource === "unreadable";
    const path = (entityChoice && entityChoice.registryPath) || "";
    entityAddLeadEl.textContent = unreadable
      ? registryUnreadableLine(path)
      : navTree.groups.length
        ? ADD_COMPANY_LEAD_MORE
        : ADD_COMPANY_LEAD_FIRST;
    entityAddErrorEl.hidden = true;
    entityAddErrorEl.textContent = "";
  }
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
  // FOCUS GOES WHERE THE ANSWER IS. With companies listed that is the first row; with none
  // listed the first row does not exist, and focusing nothing would leave a person looking
  // at a dialog with no obvious way in — which is the same class of defect as the composer
  // that held focus UNDER this dialog on 2026-09-01.
  const first = entityPickerListEl.querySelector(".picker-item");
  if (first) first.focus();
  else if (!entityAddEl.hidden) entityAddNameEl.focus();
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
// WHICH COMPANY THIS COPY OF RICH WORKS FOR (slice 4 — `entity_choice` / `choose_entity`)
//
// THE DEFECT THIS CLOSES, measured on 2026-09-01 against an installed bundle launched the
// way the CEO launches it: `open` hands the process to launchd with working directory `/`,
// `EntityRegistry::resolve_root("/")` correctly refuses to guess, and the first sentence
// typed into the window came back as "no active thread, and no entity was named — Rich
// will not guess which entity area this belongs to." Zero lines reached the ledger.
//
// The picker WAS already opening on that launch. It did not help, for a reason nothing but
// a real launch would have shown: `init()` ends with `inputEl.focus()`, which took focus
// straight back off the picker's first row, so the composer was focused UNDER an open
// dialog and every keystroke went into a box that could not send. Both halves are fixed
// here — the answer is now durable, and focus stays where the question is.
// ---------------------------------------------------------------------------------------

/// What the composer says while no company is known. Same register as every other blocked
/// line: what will not happen, why, and — because this one is HIS to fix — the control is
/// rendered directly beneath it rather than described.
const COMPANY_UNCHOSEN_BLOCK =
  "I don't know which company this work is for yet, so I won't file it anywhere. Pick one " +
  "and I'll take it from there.";

function showCompanyBlock() {
  const line = companyBlockLine();
  sendBlockedReason = line;
  composerBlockedEl.textContent = line;
  composerBlockedEl.hidden = false;
  chooseCompanyRowEl.hidden = false;
}

function clearCompanyBlock() {
  if (sendBlockedReason === COMPANY_UNCHOSEN_BLOCK || sendBlockedReason === COMPANY_NONE_KNOWN_BLOCK) {
    sendBlockedReason = null;
  }
  composerBlockedEl.hidden = true;
  chooseCompanyRowEl.hidden = true;
}

/// The boot path for a launch that resolved no company. Blocks send, renders the control,
/// and opens the picker on top — so the answer is one click away and dismissing the dialog
/// leaves a way back rather than a dead composer.
/// The same condition, when `RICHOS_ENTITY` was set outside the window. Nothing here can
/// change it, so the app does NOT open a picker whose every answer would be refused — it
/// says what happened and names who owns it (§21's rule for a state he cannot fix).
const COMPANY_PINNED_BLOCK =
  "This copy of me was told which company it works for when it was started up, from " +
  "outside this window, and I can't make sense of what it was told — so I won't file " +
  "anything until whoever set RichOS up has sorted it out.";

/// What the composer says on a first launch, when there is no company to pick yet.
///
/// SEPARATE FROM `COMPANY_UNCHOSEN_BLOCK`, because "pick one" is not an instruction a person
/// with an empty list can follow. Before 2026-09-04 this state was unreachable — the picker
/// always had six companies in it, they belonged to the app's author, and for anybody else
/// they were all wrong answers.
const COMPANY_NONE_KNOWN_BLOCK =
  "I don't know about any of your companies yet, so I've nothing to file this under. Tell " +
  "me one and I'll take it from there.";

function requireCompanyChoice() {
  if (entityChoice && entityChoice.pinnedByEnvironment) {
    sendBlockedReason = COMPANY_PINNED_BLOCK;
    composerBlockedEl.textContent = COMPANY_PINNED_BLOCK;
    composerBlockedEl.hidden = false;
    chooseCompanyRowEl.hidden = true;
    return;
  }
  showCompanyBlock();
  openEntityPicker(chooseCompany, { forCompany: true });
}

/// The composer's blocked line, in whichever of its two shapes is true right now.
function companyBlockLine() {
  const noneKnown = !!(entityChoice && Array.isArray(entityChoice.options) && entityChoice.options.length === 0);
  return noneKnown ? COMPANY_NONE_KNOWN_BLOCK : COMPANY_UNCHOSEN_BLOCK;
}

/// The CEO answers. Durable on the Rust side before anything else happens, so he is asked
/// exactly once.
async function chooseCompany(entityId) {
  let next;
  try {
    next = await Bridge.invoke("choose_entity", { entityId });
  } catch (e) {
    // Whatever the command refused with is written FOR HIM (an unregistered company, or
    // an install pinned from outside the app), so unlike `create_thread_in`'s machinery
    // errors it is shown as it stands.
    composerBlockedEl.textContent = String(e);
    composerBlockedEl.hidden = false;
    return;
  }
  entityChoice = next;
  clearCompanyBlock();
  refreshCompanySetting();
  await refreshNavigation();
  const activeId = next && next.active ? next.active.thread_id : null;
  if (activeId && threadRow(activeId)) await openThread(activeId);
  syncComposerMode();
  inputEl.focus();
}

/// HE ADDS ONE OF HIS OWN COMPANIES.
///
/// `register_entity` writes the file BEFORE it moves anything in memory, and — when nothing
/// has been chosen yet — makes the new company the one in force and opens a thread in it. So
/// the first company a first-run user adds takes him straight from a blocked composer to a
/// working conversation, with no relaunch, exactly as `chooseCompany` does for an existing
/// one. This function is the same sequence as that one from `entityChoice = next` on, and
/// that is on purpose: two paths to one state that refreshed different things would be two
/// states.
async function addCompany() {
  const displayName = entityAddNameEl.value.trim();
  const folder = entityAddFolderEl.value.trim();
  entityAddErrorEl.hidden = true;
  entityAddGoEl.disabled = true;
  let next;
  try {
    next = await Bridge.invoke("register_entity", { displayName, folder: folder || null });
  } catch (e) {
    // Whatever the command refused with is written FOR HIM — a blank name, a folder that
    // isn't there, a folder shared with a company he already has — so it is shown as it
    // stands rather than replaced with a generic failure.
    entityAddErrorEl.textContent = String(e);
    entityAddErrorEl.hidden = false;
    entityAddGoEl.disabled = false;
    entityAddNameEl.focus();
    return;
  }
  entityAddGoEl.disabled = false;
  entityAddNameEl.value = "";
  entityAddFolderEl.value = "";
  entityChoice = next;
  closeEntityPicker();
  if (next && next.chosen) clearCompanyBlock();
  refreshCompanySetting();
  await refreshNavigation();
  const activeId = next && next.active ? next.active.thread_id : null;
  if (activeId && threadRow(activeId)) await openThread(activeId);
  syncComposerMode();
  inputEl.focus();
}

entityAddGoEl.addEventListener("click", addCompany);
// Enter in either field submits, because a two-field form whose only commit is a button is
// a form people press Enter in and nothing happens.
for (const field of [entityAddNameEl, entityAddFolderEl]) {
  field.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      addCompany();
    }
  });
}

chooseCompanyBtnEl.addEventListener("click", () => openEntityPicker(chooseCompany, { forCompany: true }));

/// The same answer, as a durable SETTING — one state, two doors, the same arrangement
/// Techy Mode and the opening screen already use.
///
/// The door is the UNIVERSAL settings menu (§15: "that little settings button is ALWAYS
/// EVERYWHERE ON EVERY PAGE"), registered as a capability exactly as those two are, so
/// `settings-button.js` keeps its standalone contract and never learns what a Bridge is.
/// Why that menu and not the rail's preferences popover is measured and is written down in
/// `buildCompanyRow`.
///
/// It governs NEW conversations. A thread's company is immutable after creation (ECS §3.2),
/// so nothing here can move a conversation that already exists.
function registerCompanySetting() {
  if (!window.RichSettings || !window.RichSettings.registerCompany) return;
  window.RichSettings.registerCompany({
    read: () => entityChoice,
    write: (id) => chooseCompany(id),
  });
}

function refreshCompanySetting() {
  if (window.RichSettings && window.RichSettings.refreshCompany) window.RichSettings.refreshCompany();
}

async function refreshEntityChoice() {
  entityChoice = await invokeQuiet("entity_choice");
  registerCompanySetting();
  return entityChoice;
}

// ---------------------------------------------------------------------------------------
// FIRST-RUN SETUP — OPTION D (`setup.rs`, `setup_view.rs`)
//
// THE LAUNCH BLOCKER THIS CLOSES, in the record's own words (`ceo-decisions.md` §19): "today
// RichOS runs on his Mac and would not run on anyone else's". A customer needs Claude Code
// AND the engine directory, and the engine "ships in no payload and has no route onto
// another machine at all". This is the sheet that offers to fix both.
//
// IT IS ASKED BEFORE THE MEMORY QUESTION AND BEFORE THE COMPANY QUESTION, and the order is
// not cosmetic: without a `claude` binary and an engine directory there is nothing for a
// corpus to be read BY and nothing for a company to be chosen FOR. One dialog at a time —
// answering this one asks the next, exactly as `closeMemorySetup` already asks the company
// question.
//
// NO TERMINAL, NO PATH, NO VERSION NUMBER. Every string on this sheet comes from the
// backend (`Component::display_name`, `Component::why`, `SETUP_ACCOUNT_NOTE`, and each
// `SetupError`'s own Display), and the tests on both sides assert what they must not
// contain. Nothing is composed here.
// ---------------------------------------------------------------------------------------

let setupState = null;
/// Set when the setup sheet opened ahead of the memory question, so that question is asked
/// the moment this one closes rather than being stacked on top of it.
let memoryQuestionDeferred = false;

async function refreshSetup() {
  setupState = await invokeQuiet("setup_status");
  return setupState;
}

/// Ask, or explain, or say nothing at all. Returns true when the sheet opened, so `init` can
/// hold the memory question back instead of stacking a second dialog on this one.
function maybeAskAboutSetup() {
  if (!setupState || !setupState.ask) return false;
  const { ask } = setupState;
  if (!ask.items.length) return false;
  openSetupSheet(ask, { canInstall: ask.can_install });
  return true;
}

function openSetupSheet(ask, opts) {
  // THE TITLE COUNTS WHAT IS MISSING, in words, because "1 item" is a package manager's
  // sentence and this is a conversation.
  const several = ask.items.length > 1;
  setupTitleEl.textContent = several
    ? "There are a couple of things I need on this Mac."
    : "There's one thing I need on this Mac.";
  // AND THE SENTENCE UNDER IT COUNTS THE SAME WAY. It said "I can get them myself" under
  // both titles, so a machine missing only the engine read "There's one thing I need on this
  // Mac. I can get them myself" — the first screen a customer ever sees, disagreeing with
  // itself in the second sentence (ray-opus-a1, finding 7, 2026-09-04).
  setupNoteEl.textContent = opts.canInstall
    ? several
      ? "I can get them myself — you just have to say so."
      : "I can get it myself — you just have to say so."
    : "";
  setupNoteEl.hidden = !setupNoteEl.textContent;

  setupItemsEl.replaceChildren();
  for (const item of ask.items) {
    const li = document.createElement("li");
    const name = document.createElement("span");
    name.className = "setup-item-name";
    name.textContent = item.name;
    const why = document.createElement("span");
    why.className = "setup-item-why";
    why.textContent = item.why;
    li.append(name, why);
    setupItemsEl.append(li);
  }

  // THE BYO-ANTHROPIC SENTENCE, above the button and not after it. Row 3.14's second
  // condition: D removes one setup step of two, and must not be sold as zero-touch.
  setupAccountEl.textContent = ask.account_note || "";
  setupAccountEl.hidden = !setupAccountEl.textContent;

  // A BUILD THAT CANNOT INSTALL SAYS SO INSTEAD OF OFFERING A BUTTON THAT WILL FAIL. The
  // backend's own sentence, verbatim — it names the party who can fix it, which he cannot.
  setupErrorEl.textContent = opts.canInstall ? "" : ask.cannot_install_reason || "";
  setupErrorEl.hidden = !setupErrorEl.textContent;
  setupProgressEl.hidden = true;
  setupProgressEl.textContent = "";

  setupGoEl.hidden = !opts.canInstall;
  setupGoEl.disabled = false;
  setupLaterEl.hidden = !opts.canInstall;
  setupCloseEl.hidden = opts.canInstall;
  setupSheetEl.hidden = false;
  (opts.canInstall ? setupGoEl : setupCloseEl).focus();
}

function closeSetupSheet() {
  setupSheetEl.hidden = true;
  // The question that was held back, asked now rather than never — the same handoff
  // `closeMemorySetup` performs for the company question. Without this line a fresh install
  // would answer setup and silently drop both of the others.
  if (memoryQuestionDeferred) {
    memoryQuestionDeferred = false;
    const memoryAsked = maybeAskAboutMemory();
    if (!memoryAsked && companyQuestionDeferred) {
      companyQuestionDeferred = false;
      requireCompanyChoice();
    }
  } else {
    inputEl.focus();
  }
}

/// **HE PRESSES "Set it up".** The button is disabled for the whole run — a second press
/// while Anthropic's installer is running would start a second installer.
async function runSetup() {
  setupGoEl.disabled = true;
  setupLaterEl.hidden = true;
  setupErrorEl.hidden = true;
  setupErrorEl.textContent = "";
  setupProgressEl.hidden = false;
  setupProgressEl.textContent = "Starting.";
  let next;
  try {
    next = await Bridge.invoke("run_setup");
  } catch (e) {
    // THE BACKEND'S SENTENCE, AS IT STANDS. Each `SetupError`'s Display says what happened
    // and whether his Mac was changed; rewriting it here would lose the instruction.
    setupProgressEl.hidden = true;
    setupErrorEl.textContent = String(e);
    setupErrorEl.hidden = false;
    setupGoEl.disabled = false;
    setupGoEl.textContent = "Try again";
    setupLaterEl.hidden = false;
    return;
  }
  setupState = next;
  setupProgressEl.hidden = true;
  setupGoEl.hidden = true;
  setupLaterEl.hidden = true;
  setupCloseEl.hidden = false;
  setupNoteEl.hidden = false;
  // `complete` is the BACKEND'S answer, re-read from disk after the run rather than inferred
  // from "no step threw". A run whose steps all returned Ok and whose disk still says
  // something is missing must not say "I'm ready".
  // THE HEADING MOVES WITH THE STATE. It kept counting what was missing after the run
  // finished, so a successful install showed "There's one thing I need on this Mac." over
  // "That's everything. I'm ready." — two sentences contradicting each other on screen at the
  // same time (ray-opus-a1, finding 7, 2026-09-04). It is set from the same `next.complete`
  // the note is, so the two cannot come apart again.
  setupTitleEl.textContent = next && next.complete
    ? "That's the setting up done."
    : "I couldn't finish the setting up.";
  setupNoteEl.textContent = next && next.complete
    ? "That's everything. I'm ready."
    : "That's everything I could do — something is still missing. That part is for whoever set RichOS up to look at.";
  setupItemsEl.replaceChildren();
  setupAccountEl.hidden = false;
  setupCloseEl.focus();
}

setupGoEl.addEventListener("click", runSetup);
setupLaterEl.addEventListener("click", closeSetupSheet);
setupCloseEl.addEventListener("click", closeSetupSheet);
setupSheetEl.addEventListener("click", (e) => {
  if (e.target === setupSheetEl) closeSetupSheet();
});

// LIVE PROGRESS. Anthropic's installer downloads the `claude` binary — 197,220,928 B on a
// Mac with no `zstd`, which macOS 15.6 does not ship (§19 finding 3) — so a sheet that said
// nothing until it finished would look hung for minutes.
Bridge.listen("richos://setup", (payload) => {
  const p = payload && payload.payload ? payload.payload : payload;
  if (!p) return;
  if (p.state === "failed") {
    setupProgressEl.hidden = true;
    setupErrorEl.textContent = p.detail || p.what;
    setupErrorEl.hidden = false;
    return;
  }
  setupProgressEl.hidden = false;
  setupProgressEl.textContent = p.what;
});

// ---------------------------------------------------------------------------------------
// FIRST-RUN MEMORY SETUP (`provision.rs`, `memory.rs`)
//
// THE DEFECT THIS CLOSES: the installed, signed RichOS reaches the CEO's memory only
// because an engineer typed a symlink by hand on 2026-09-01 and wrote it down as a gap
// rather than a feature. Delete it and the boot log says "no corpus configured" on four
// lines — measured, pointer removed and restored, in
// `docs/verification/first-run-provisioning-2026-09-01/`. Nothing in the product created
// it, and nothing offered to. This is the offer.
//
// HIS PART IS ONE CLICK. The location is SHOWN, never typed, and it comes from the backend
// (`memory_status.offered_location`) rather than being composed here — so the string on
// screen is the string the command was given, and there is no second opinion about where
// his record goes.
// ---------------------------------------------------------------------------------------

let memoryState = null;
/// Set when the memory question opened ahead of the company question, so the company
/// question is asked the moment this one is answered rather than being stacked on top of
/// it. Two modal dialogs at once is not a calm instrument.
let companyQuestionDeferred = false;

const MEMORY_ASK =
  "I'll keep your decisions, your companies and how you work in a folder on this Mac, and " +
  "nothing in it leaves this Mac. If this looks right, I'll set it up now.";
const MEMORY_DONE =
  "That's set up. From now on I'll keep what you tell me in that folder and read it back " +
  "when it matters.";
/// ONE string for two moments — the boot that finds a corpus it cannot read, and the setup
/// that finishes without the reader.
///
/// IT NAMES NO PARTY, AND THAT IS THE FIX. Until 2026-09-04 it said *"It needs whoever set
/// RichOS up to add it"*, which is the standard §21 shape for a state the CEO cannot clear —
/// and it was written on this machine, where somebody else did set RichOS up. On a customer's
/// Mac that person IS the reader: Andreas installs RichOS in his lunch break, accepts the
/// memory folder, and the product's headline promise dead-ends on an instruction to fetch a
/// third party who does not exist. Pointing a man at himself is worse than saying nothing.
///
/// WHY NOTHING IS OFFERED INSTEAD. The missing piece is the loro compiler — `loro-context.mjs`
/// and `loro-write.mjs`, the read half and the write half. The setup sheet two screens earlier
/// installs Claude Code and the engine because both have a route onto another machine; this
/// one has none. `git ls-files` in the public product repo returns zero `loro/` files, the
/// signed bundle's `Contents/Resources` holds `icon.icns` and nothing else, and the engine
/// release asset is built from `engine/`, which contains no compiler either. The bytes exist
/// only in the private `richos-hq` checkout. Publishing them is a decision about what ships
/// publicly, and it belongs to the CEO — not to a sentence in the window.
///
/// SO THE SENTENCE TELLS HIM THREE THINGS, in his own frame: what does not work (this folder
/// is not read or written), what still does (everything else — the conversations RichOS keeps
/// in its own store, which is where the thread history, the ledger and the journal live and is
/// untouched by any of this), and what he can do (nothing, and nothing is required of him).
/// The last clause is a statement about the app's behavior and not a promise about a date:
/// `resolve_tools` searches the install directory and the bundle's resources at every launch,
/// so a compiler that appears is picked up with no action from him.
const MEMORY_NO_READER =
  "Your memory folder is on this Mac, and I can't read or write it yet — the part of me that " +
  "does isn't in this version. Nothing else is affected: our conversations stay on this Mac " +
  "and I pick them up when you come back. There's nothing for you to install and nothing for " +
  "you to fix — I'll start using the folder on my own as soon as that part arrives.";

async function refreshMemory() {
  memoryState = await invokeQuiet("memory_status");
  return memoryState;
}

/// Ask, or say what is wrong, or do nothing at all. Returns true when a dialog opened, so
/// `init` can hold the company question back rather than stacking it.
function maybeAskAboutMemory() {
  if (!memoryState) return false;
  if (memoryState.state === "none") {
    openMemorySetup(MEMORY_ASK, memoryState.offered_location, { canProvision: true });
    return true;
  }
  // `no-compiler` — SAID ONCE, WHEN HE ASKS FOR IT, AND NEVER AS A NAG.
  //
  // This branch used to open the dialog at every launch. On a provisioned machine with no
  // compiler that is EVERY launch forever, so ray-opus-a1's first run found a permanent
  // interruption rather than a one-time notice (finding 4, 2026-09-04) — and now that the
  // sentence honestly ends "there's nothing for you to install and nothing for you to fix",
  // repeating it every time he opens the app is the exact opposite of what it says.
  //
  // It is still shown at the moment it is the ANSWER TO SOMETHING HE DID: `provisionMemory`
  // renders it the instant he presses "Set it up" and the corpus comes back unreadable. What
  // is gone is the unprompted repeat.
  //
  // The same reasoning `unusable` has always had, and `ready`'s: an operator's problem with
  // its own boot line and no sentence worth interrupting him with, since nothing in the
  // window can act on it.
  return false;
}

function openMemorySetup(note, location, opts) {
  memorySetupNoteEl.textContent = note;
  memorySetupLocationEl.textContent = location || "";
  memorySetupLocationEl.hidden = !location;
  memorySetupGoEl.hidden = !opts.canProvision;
  memorySetupLaterEl.hidden = !opts.canProvision;
  memorySetupCloseEl.hidden = opts.canProvision;
  memorySetupEl.hidden = false;
  const first = opts.canProvision ? memorySetupGoEl : memorySetupCloseEl;
  first.focus();
}

function closeMemorySetup() {
  memorySetupEl.hidden = true;
  // The question that was held back, asked now rather than never. Without this line a
  // launch with no memory AND no company would answer one and silently drop the other.
  if (companyQuestionDeferred) {
    companyQuestionDeferred = false;
    requireCompanyChoice();
  } else {
    inputEl.focus();
  }
}

/// HE SAYS YES. The location goes to the backend EXACTLY as it was shown to him, and a
/// refusal is rendered as it stands — `provision`'s messages are written for a human and
/// name the thing to do ("that folder already has things in it", "that is inside the
/// product checkout"), so paraphrasing one would lose the instruction.
async function provisionMemory() {
  memorySetupGoEl.disabled = true;
  let next;
  // THE PATH HE WAS ASKED ABOUT, HELD ONCE. It is the argument the command is given and the
  // string the next screen shows — one variable, not two reads that happen to agree.
  //
  // THE DEFECT THIS CLOSES (ray-opus-a1, first run of the installed v1.0.0, 2026-09-04): the
  // sheet asked about the folder in his home directory, he pressed the button, and the result
  // named the pointer in Application Support instead — a different location from the one he
  // agreed to, on the one screen that is explicitly about trusting this app with his data.
  // Nothing had moved: provision writes a symlink beside the corpus and the re-resolution
  // finds that symlink first, so the answer comes back under the alias's name. The folder is
  // right and the SENTENCE was wrong, and a careful person reading it concludes he was
  // overruled about where his record lives.
  //
  // (No path is spelled out in this file. The suite forbids a corpus path in the surface at
  // all — the location comes from the backend or not at all — and a path in a COMMENT is a
  // second opinion waiting to drift from the one on screen.)
  const consented = memoryState.offered_location;
  try {
    next = await Bridge.invoke("provision_memory", { location: consented });
  } catch (e) {
    memorySetupNoteEl.textContent = String(e);
    memorySetupGoEl.disabled = false;
    return;
  }
  memoryState = next;
  memorySetupGoEl.disabled = false;
  // THE DESK STATE IS RE-READ, because `loro_available` was answered at boot and the answer
  // has just changed. `provision_memory` now installs the correction desk into the running
  // app (`main.rs::install_correction_desk`) instead of asking him to relaunch, so the
  // backend says `true` from this moment on — and a cached `false` in `deskState` would put
  // "this install has no company memory it can write to" in front of a man who has just
  // watched it be created. `refreshDesk` is idempotent and this is the one moment the fact
  // it caches is known to be stale.
  await refreshDesk();
  const readable = next.state === "ready";
  // AND THE HEADING STOPS ASKING A QUESTION HE HAS ANSWERED. It is the dialog's accessible
  // name and it stayed on "Where should I keep what you tell me?" over both endings, so the
  // screen he actually reaches read as a question above its own answer — the same defect the
  // setup sheet's heading had two screens earlier (ray-opus-a1, finding 7). One heading for
  // both endings, because what follows it is about the folder in either case.
  memorySetupTitleEl.textContent = "Your memory folder.";
  // `consented`, and deliberately NOT `next.root`: the two name one directory, and the one he
  // is owed is the one he answered a question about.
  openMemorySetup(readable ? MEMORY_DONE : MEMORY_NO_READER, consented, { canProvision: false });
}

memorySetupGoEl.addEventListener("click", provisionMemory);
memorySetupLaterEl.addEventListener("click", closeMemorySetup);
memorySetupCloseEl.addEventListener("click", closeMemorySetup);
memorySetupEl.addEventListener("click", (e) => {
  if (e.target === memorySetupEl) closeMemorySetup();
});

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
// Rail width, collapse and responsive behavior (§2.1, §20)
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
// THE CORRECTION DESK — §7 "ask, never infer", made clickable
//
// `ceo-decisions.md` §7 governs both families absolutely: *"Nothing is ever learned
// silently."* The Rust side has enforced that since 2026-08-29 (`correction.rs`) and
// 2026-08-30 (`staging.rs`) — `confirm` is the only path to a write in either desk, and
// there is no argument a caller could pass to skip the ask. Fourteen Tauri commands
// implement it and, until this file changed, `app/ui/` invoked none of them: RICH-TODOs
// row 5b, and `loro-writer.md`'s own words — *"nothing in `app/ui/` renders it, so the CEO
// cannot yet click it."*
//
// THIS LAYER DECIDES NOTHING. Every sentence of judgement on this surface comes from the
// backend: the loro preview is the WRITER'S own `--dry-run` bytes (`correction.rs:366-369`
// — "a preview generated by anything other than the writer would be a description of a
// write rather than the write"), the spoken prompt is `staging.rs`'s `prompt_for`, and
// every refusal is relayed verbatim. What this file adds is the three buttons §7 names and
// an honest account of which of the two desks is actually running.
//
// WHAT IS DELIBERATELY NOT HERE: a form for composing a correction.
// `loro_propose_correction` is mocked and reachable, and nothing on this surface calls it —
// nothing SHOULD. Since 2026-08-30 the proposals arrive on their own: `belief.rs` files one
// when the CEO says a record is wrong, inside `Spine::submit_prompt`, and this surface hears
// about it on `rich://loro-proposed`. The CEO corrects loro by TALKING, not by filling in a
// form.
// `loro-structure.md` is explicit about why — the pane's job is *inspection*, its primary
// action is "this is wrong", *"which opens a conversation, not a form"*, and *"a browsable,
// editable database invites the CEO to become a librarian"*. Detection (something noticing
// a correction and filing a proposal) is named as unbuilt in `correction.rs`'s module doc,
// and inventing a compose box here would be building the librarian instead of the desk.
// ---------------------------------------------------------------------------------------

const correctionsOverlayEl = el("corrections-overlay");
const correctionsNoticeEl = el("corrections-notice");
const correctionsBtn = el("nav-corrections");
const correctionsCountEl = el("nav-corrections-count");

/// The two desks, each with its own commands. A single map rather than two code paths,
/// because §7's state machine is the same in both and a second copy of it would be the
/// place they drift.
const DESKS = {
  loro: {
    available: "loro_available",
    pending: "loro_pending_corrections",
    suppressed: "loro_suppressed_records",
    confirm: "loro_confirm_correction",
    decline: "loro_decline_correction",
    unsuppress: "loro_unsuppress_record",
  },
  spoken: {
    available: "spoken_corrections_available",
    pending: "spoken_pending_corrections",
    suppressed: "spoken_suppressed_terms",
    confirm: "spoken_confirm_correction",
    decline: "spoken_decline_correction",
    unsuppress: "spoken_unsuppress_term",
  },
};

/// `available` and `readFailed` are DIFFERENT FACTS and are never collapsed into one.
/// `available: false` is a statement about this install — no corpus, no service — and
/// nobody in this app can change it. `readFailed` is a desk that should be there and did
/// not answer, which is transient and has a retry. Rendering either one as an empty list
/// would say "nothing to correct", which is the one thing neither of them means.
const deskState = {
  loro: { available: null, readFailed: null, pending: [], suppressed: [] },
  spoken: { available: null, readFailed: null, pending: [], suppressed: [] },
};

let deskReturnFocus = null;

/// The party who owns an unavailable desk. Appended to the BACKEND's own sentence rather
/// than replacing it: the backend says what is missing, this says who can do something
/// about it, and neither is guessed by the other.
const DESK_OWNER_LINE =
  " Switching that on is a job for whoever set RichOS up — there is no control for it in here.";

function deskNotice(text, tone) {
  correctionsNoticeEl.textContent = text;
  correctionsNoticeEl.classList.toggle("desk-notice--attention", tone === "attention");
  correctionsNoticeEl.hidden = !text;
}

/// Read one desk. THREE reads, and a refusal from any of them is kept rather than logged —
/// `affordances.js` enforces that an actionable state renders its control and that a
/// refusal never dies in a console, and this surface is in its scope.
async function refreshDeskFamily(family) {
  const cmd = DESKS[family];
  const st = deskState[family];
  st.readFailed = null;
  try {
    st.available = (await Bridge.invoke(cmd.available)) === true;
  } catch (e) {
    // An unregistered command (an older shell) is indistinguishable from a desk that is
    // not there, and both mean the same thing to the CEO: this half is not running.
    st.available = false;
    st.readFailed = null;
    st.offReason = String(e);
    st.pending = [];
    st.suppressed = [];
    return;
  }
  try {
    st.pending = (await Bridge.invoke(cmd.pending)) || [];
    st.suppressed = (await Bridge.invoke(cmd.suppressed)) || [];
    st.offReason = null;
  } catch (e) {
    st.pending = [];
    st.suppressed = [];
    // The desk said it was there and then refused to answer. If it said it was NOT there,
    // the refusal IS the reason — the backend's own sentence about this install.
    if (st.available) st.readFailed = String(e);
    else st.offReason = String(e);
  }
}

async function refreshDesk() {
  await Promise.all([refreshDeskFamily("loro"), refreshDeskFamily("spoken")]);
  renderDeskCount();
  if (!correctionsOverlayEl.hidden) renderDesk();
}

/// The rail badge. Absent — not zero — when there is nothing waiting: a permanent "0"
/// trains him to stop reading it.
function renderDeskCount() {
  const n = deskState.loro.pending.length + deskState.spoken.pending.length;
  correctionsCountEl.textContent = n ? String(n) : "";
  correctionsCountEl.hidden = n === 0;
}

// ---- rendering -------------------------------------------------------------------------

function deskButton(label, kind) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "desk-btn" + (kind ? " desk-btn--" + kind : "");
  b.textContent = label;
  return b;
}

function deskLine(cls, text) {
  const p = document.createElement("p");
  p.className = cls;
  p.textContent = text;
  return p;
}

/// One loro proposal. The CEO reads three things and then decides: his OWN stated reason,
/// what record it touches, and the exact bytes that would land.
function renderProposalCard(p) {
  const card = document.createElement("article");
  card.className = "desk-card";
  card.dataset.proposalId = p.id;

  const targetRef = p.write && (p.write.recordRef || p.write.record_ref);
  card.appendChild(deskLine("desk-card-target", (p.write ? p.write.op : "") + (targetRef ? " · " + targetRef : "")));
  card.appendChild(deskLine("desk-label", "Because you said:"));
  card.appendChild(deskLine("desk-card-quote", p.why));
  card.appendChild(deskLine("desk-label", "What would be written, exactly:"));

  // A `<pre>`, and the writer's bytes untouched. This is the artefact he is approving.
  const pre = document.createElement("pre");
  pre.className = "desk-preview";
  pre.textContent = p.preview;
  card.appendChild(pre);

  const actions = document.createElement("div");
  actions.className = "desk-card-actions";

  const yes = deskButton("Yes, that's right", "confirm");
  yes.addEventListener("click", () => answerLoro(p.id, "confirm"));
  const notNow = deskButton("Not now");
  notNow.addEventListener("click", () => answerLoro(p.id, "decline"));
  const never = deskButton("Never ask about this record", "never");
  never.addEventListener("click", () => answerLoro(p.id, "permanent"));
  actions.appendChild(yes);
  actions.appendChild(notNow);
  actions.appendChild(never);

  // "What does loro actually believe?" — the answer is a file, and reading is not
  // correcting (`correction.rs:592-595`), so this needs no proposal and no confirmation.
  // Absent for an append: there is no prior record to show, and a button that fetched
  // nothing would be the surface inventing a belief.
  if (targetRef) {
    const showRecord = document.createElement("pre");
    showRecord.className = "desk-record";
    showRecord.hidden = true;
    const show = deskButton("Show me what's on record now", "show");
    show.addEventListener("click", async () => {
      deskNotice("");
      try {
        const out = await Bridge.invoke("loro_show_record", { recordRef: targetRef });
        showRecord.textContent = (out && out.text) || (out && out.file) || "";
        showRecord.hidden = false;
      } catch (e) {
        deskNotice(String(e), "attention");
      }
    });
    actions.appendChild(show);
    card.appendChild(actions);
    card.appendChild(showRecord);
  } else {
    card.appendChild(actions);
  }
  return card;
}

/// One spoken candidate. The ask sentence is `staging.rs`'s, including its
/// "(you corrected this before)" clause — §7 requires a second ask to say so, "or it reads
/// as the system having forgotten", and rebuilding that sentence here is how the two
/// surfaces start asking it differently.
///
/// TWO TRIGGERS FILE INTO THIS DESK AND THEY DO NOT GET THE SAME CARD. `spoken.rs` fires on
/// a sentence he SAID ("It's Kestrel, not Kestral"), so the evidence is a quotation and
/// "Because you said:" is true. `heard.rs` fires on a dictation he SILENTLY EDITED before
/// pressing send — he said nothing at all — so the same heading over the same layout would
/// put words in his mouth, and the evidence he actually needs is the CHANGE: what the
/// recognizer heard, against what he sent. `ask.frame` is what tells them apart
/// (`spoken.rs`'s `Frame`, kebab-cased over the wire), and it is read rather than guessed
/// from the shape of the payload.
function renderCandidateCard(c) {
  const card = document.createElement("article");
  card.className = "desk-card";
  card.dataset.key = c.key;
  const silentEdit = !!(c.ask && c.ask.frame === "silent-edit");
  card.dataset.frame = (c.ask && c.ask.frame) || "";

  card.appendChild(deskLine("desk-card-prompt", c.prompt));
  if (silentEdit) {
    // No quotation, because there is nothing he said. The two lines ARE the evidence, and
    // they are shown in the order they happened: heard first, sent second.
    card.appendChild(deskLine("desk-label", "I heard:"));
    card.appendChild(deskLine("desk-card-quote", (c.ask && c.ask.anchor) || ""));
    card.appendChild(deskLine("desk-label", "You sent:"));
    card.appendChild(deskLine("desk-card-quote", c.utterance));
  } else {
    card.appendChild(deskLine("desk-label", "Because you said:"));
    card.appendChild(deskLine("desk-card-quote", c.utterance));
  }
  if (c.ask) card.appendChild(deskLine("desk-card-pair", c.ask.from + " → " + c.ask.to));
  // EVIDENCE, not a gate (`spoken.rs:374-376`): `anchor` is where the rejected form was
  // found in the recent record. Absent means the pair is still asked and there is simply
  // nothing to quote, so the line is omitted rather than filled in. For a silent edit the
  // anchor IS the heard sentence and is already rendered above, so it is not repeated.
  if (!silentEdit && c.ask && c.ask.anchor) card.appendChild(deskLine("desk-card-anchor", c.ask.anchor));

  const actions = document.createElement("div");
  actions.className = "desk-card-actions";
  const yes = deskButton("Yes, learn it", "confirm");
  yes.addEventListener("click", () => answerSpoken(c.key, "confirm"));
  const notNow = deskButton("Not now");
  notNow.addEventListener("click", () => answerSpoken(c.key, "decline"));
  const never = deskButton("Never ask about this term", "never");
  never.addEventListener("click", () => answerSpoken(c.key, "permanent"));
  actions.appendChild(yes);
  actions.appendChild(notNow);
  actions.appendChild(never);
  card.appendChild(actions);
  return card;
}

/// A permanent decline, and the way back out of it. §7 requires the suppression list to be
/// inspectable "or a term silently refuses to learn with no way to see why" — and a list
/// you can see and cannot clear is only half of that (`correction.rs:583-590`).
function renderSuppressedRow(family, id) {
  const row = document.createElement("div");
  row.className = "desk-suppressed-row";
  const code = document.createElement("code");
  code.className = "desk-suppressed-id";
  code.textContent = id;
  row.appendChild(code);
  const lift = deskButton("Ask about this again", "lift");
  lift.addEventListener("click", () => liftSuppression(family, id));
  row.appendChild(lift);
  return row;
}

function renderDeskFamily(family, render) {
  const st = deskState[family];
  const off = el("desk-" + family + "-off");
  const broke = el("desk-" + family + "-broke");
  const empty = el("desk-" + family + "-empty");
  const list = el("desk-" + family + "-list");
  const supBlock = el("desk-" + family + "-suppressed");
  const supList = el("desk-" + family + "-suppressed-list");

  list.textContent = "";
  supList.textContent = "";

  // NOT THERE. The backend's own sentence about this install, plus who owns it. Never an
  // empty list: "no corpus is configured" and "nothing is waiting on you" are different
  // facts and only one of them is good news.
  off.hidden = st.available !== false;
  if (st.available === false) {
    off.textContent = (st.offReason || "") + DESK_OWNER_LINE;
  }

  // THERE, AND IT DID NOT ANSWER. Transient, and the control that changes it is right here.
  broke.hidden = !st.readFailed;
  if (st.readFailed) el("desk-" + family + "-broke-reason").textContent = st.readFailed;

  const readable = st.available === true && !st.readFailed;
  empty.hidden = !(readable && st.pending.length === 0);
  if (readable) for (const item of st.pending) list.appendChild(render(item));

  // An empty "Never ask again" heading is noise; the block appears the moment there is
  // something under it, which is what a permanent decline puts there.
  supBlock.hidden = !(readable && st.suppressed.length > 0);
  if (readable) for (const id of st.suppressed) supList.appendChild(renderSuppressedRow(family, id));
}

function renderDesk() {
  renderDeskFamily("loro", renderProposalCard);
  renderDeskFamily("spoken", renderCandidateCard);
}

// ---- answering -------------------------------------------------------------------------

/// §7's three outcomes, and the sentence each one earns. A decline is NOT permanent and
/// says so, because a decline is ambiguous — not a record / not now / misclicked — while a
/// repeat is the evidence (`correction.rs:563-565`).
async function answerLoro(id, outcome) {
  deskNotice("");
  try {
    if (outcome === "confirm") {
      const done = await Bridge.invoke("loro_confirm_correction", { id });
      if (done && done.state === "written") {
        deskNotice("Done. That's what I have on record now.");
      } else {
        // He said yes and the write did not land. The desk keeps the reason
        // (`correction.rs:350-353`) precisely so this cannot be silent: a failed write that
        // disappears is indistinguishable from one that never happened.
        deskNotice(
          "I said yes to that and the write didn't land, so nothing changed. Here is exactly what my writer said:\n" +
            ((done && done.failure) || ""),
          "attention"
        );
      }
    } else {
      await Bridge.invoke("loro_decline_correction", { id, permanent: outcome === "permanent" });
      deskNotice(
        outcome === "permanent"
          ? "I won't ask about that record again. It's in the list below if you change your mind."
          : "Left it alone. I'll ask again if it comes up."
      );
    }
  } catch (e) {
    deskNotice(String(e), "attention");
  }
  await refreshDesk();
}

async function answerSpoken(key, outcome) {
  deskNotice("");
  try {
    if (outcome === "confirm") {
      const learned = await Bridge.invoke("spoken_confirm_correction", { key });
      // `changed: false` means the vocabulary already knew the pair, which is a different
      // fact from a refusal, and `staging.rs:141-144` says the CEO is entitled to both.
      deskNotice(
        learned && learned.changed
          ? "Learned. I'll write it that way from now on."
          : "I already had that one, so nothing changed."
      );
    } else {
      await Bridge.invoke("spoken_decline_correction", { key, permanent: outcome === "permanent" });
      deskNotice(
        outcome === "permanent"
          ? "I won't ask about that word again. It's in the list below if you change your mind."
          : "Left it alone. I'll ask again the next time you say it."
      );
    }
  } catch (e) {
    deskNotice(String(e), "attention");
  }
  await refreshDesk();
}

async function liftSuppression(family, id) {
  deskNotice("");
  try {
    await Bridge.invoke(DESKS[family].unsuppress, family === "loro" ? { recordRef: id } : { key: id });
    deskNotice("Back on the table. I'll ask about it if it comes up again.");
  } catch (e) {
    deskNotice(String(e), "attention");
  }
  await refreshDesk();
}

// ---- opening and closing -----------------------------------------------------------------

async function openCorrections() {
  deskReturnFocus = document.activeElement;
  deskNotice("");
  correctionsOverlayEl.hidden = false;
  correctionsBtn.setAttribute("aria-expanded", "true");
  // Rendered from what was already read, then re-read. The panel must never open blank
  // while a command is in flight — an empty desk reads as "nothing to correct".
  renderDesk();
  await refreshDesk();
  renderDesk();
  const first = correctionsOverlayEl.querySelector(".desk-btn, #corrections-close");
  if (first) first.focus();
}

function closeCorrections() {
  correctionsOverlayEl.hidden = true;
  correctionsBtn.setAttribute("aria-expanded", "false");
  if (deskReturnFocus && document.contains(deskReturnFocus)) deskReturnFocus.focus();
  deskReturnFocus = null;
}

correctionsBtn.addEventListener("click", openCorrections);
el("corrections-close").addEventListener("click", closeCorrections);
correctionsOverlayEl.addEventListener("click", (e) => {
  if (e.target === correctionsOverlayEl) closeCorrections();
});
el("desk-loro-retry").addEventListener("click", () => refreshDesk().then(renderDesk));
el("desk-spoken-retry").addEventListener("click", () => refreshDesk().then(renderDesk));

/// The staging trigger fired inside a turn (`staging.rs` -> `TauriCorrectionEmitter`). The
/// question is ALREADY durable on disk before this event exists, so a webview that missed
/// it loses a prompt and never a record — but the badge would otherwise not move until the
/// next open, and an ask nobody can see is an ask that never happened.
Bridge.listen("rich://correction-staged", () => {
  refreshDesk();
});

/// The BELIEF trigger fired inside a turn (`belief.rs` -> `correction.rs` ->
/// `TauriProposalEmitter`). Same contract as the line above and a separate event because
/// the payload is a `Proposal` rather than a `Staged`: the proposal is already durable on
/// the desk's own log before this exists, so a webview that missed it loses a badge move
/// and never a record.
Bridge.listen("rich://loro-proposed", () => {
  refreshDesk();
});

// ---------------------------------------------------------------------------------------
// THE FEEDBACK CHANNEL — `feedback.rs`'s local half, made reachable (RICH-TODOs row 5)
//
// The row read as if nothing existed. At `aa364ed` that was wrong in one direction and
// right in the other: the module was complete — the CEO's wording in constants, the four
// keys, `Rating::invites_report`, the versioned taxonomy, the store, the disclosure, and
// four tests asserting no way off this machine — and `grep -rn feedback app/ui/main.js`
// returned nothing. There was no way for him to reach any of it.
//
// WHEN THIS SURFACE APPEARS, AND WHY THAT IS THE ANSWER
// ----------------------------------------------------
// When he opens it. There is no trigger, no timer, no end-of-session prompt, and no badge.
//
// That is not timidity, it is the module's own measurement: in the reference case all five
// moments of real annoyance were volunteered MID-WORK and unprompted, and none arrived at
// session end. A prompt fired at a moment of RichOS's choosing would have caught none of
// them at the moment they were felt. And the cost of firing one anyway is not zero — a
// prompt that arrives during the work he is annoyed about is one more unprepared task
// handed to him, which is the first term in this feature's own vocabulary. It also teaches
// dismissal, and a fallback he has learned to dismiss catches less than no fallback at all.
//
// What WOULD beat zero is catching what is already being said, mid-work, unprompted — which
// `feedback.rs` names as "a later, larger piece of work" and which this surface does not
// pretend to be. So: reachable when he wants it, and honest about being the fallback half.
//
// THIS LAYER AUTHORS NO WORDING. The question, the four keys, the offer, the disclosure
// heading and every term's sentence come from `feedback_wording` and `feedback_taxonomy`,
// which project `feedback.rs`'s constants. The module holds them in one place so the UI
// cannot paraphrase them; retyping one here would be the paraphrase it exists to prevent.
//
// NOTHING HERE SENDS ANYTHING. There is no transport in this file, and
// `feedback_no_outbound_tests.rs` asserts that of this file rather than trusting this
// sentence.
// ---------------------------------------------------------------------------------------

const feedbackOverlayEl = el("feedback-overlay");
const feedbackNoticeEl = el("feedback-notice");
const feedbackBtn = el("nav-feedback");

/// Everything the surface knows, and each fact kept apart from the others.
///
/// `available: false` is a store that would not open — nobody in this app can change it,
/// and no answer can be kept. `historyFailed` is a store that IS there and refused a read,
/// which is transient and has a retry. An empty `history` is a store that opened and holds
/// nothing. Rendering any of the three as one empty list would say "there is nothing here",
/// which is the one thing only the third of them means.
const feedback = {
  available: null,
  offReason: null,
  historyFailed: null,
  history: [],
  wording: null,
  taxonomy: null,
  /// Where he is in the one answer he is giving right now: "asking" (nothing pressed),
  /// "offered", "choosing", "previewing", "answered". Never persisted — this is a moment,
  /// not a record, and the record is the file.
  phase: "asking",
  key: null,
  selection: null,
  /// The EXACT block he was shown, held verbatim as the backend rendered it. It is sent
  /// back with the approval and checked there, so an approval can never be recorded for
  /// text he did not read.
  shown: null,
};

let feedbackReturnFocus = null;

function feedbackNotice(text, tone) {
  feedbackNoticeEl.textContent = text;
  feedbackNoticeEl.classList.toggle("desk-notice--attention", tone === "attention");
  feedbackNoticeEl.hidden = !text;
}

/// The three outcomes a recorded answer earns, and nothing about any of them promises a
/// destination. The disclosure heading has already told him where it goes; these say what
/// happened, in the same register.
const FEEDBACK_KEPT = "Taken down. It stays on this machine.";
const FEEDBACK_KEPT_WITH_REPORT =
  "Taken down, word for word as you read it — and it stays on this machine.";
const FEEDBACK_KEPT_WITHOUT_REPORT = "Taken down, with no report attached.";

// ---- reading ----------------------------------------------------------------------------

/// Read the surface. FOUR reads, and a refusal from any of them is kept and rendered rather
/// than logged — `affordances.js` enforces that a refusal never dies in a console.
async function refreshFeedback() {
  feedback.historyFailed = null;
  try {
    feedback.available = (await Bridge.invoke("feedback_available")) === true;
  } catch (e) {
    // An unregistered command (an older shell) and a store that will not open mean the same
    // thing to the CEO: no answer he gives here can be kept.
    feedback.available = false;
    feedback.offReason = String(e);
    feedback.history = [];
    return;
  }
  try {
    // The wording and the vocabulary are read even when the store is shut, so the panel can
    // still say what it would have asked. They are facts about this BUILD, not this file.
    feedback.wording = await Bridge.invoke("feedback_wording");
    feedback.taxonomy = await Bridge.invoke("feedback_taxonomy");
  } catch (e) {
    feedback.wording = null;
    feedback.taxonomy = null;
    feedback.offReason = String(e);
    feedback.available = false;
    feedback.history = [];
    return;
  }
  feedback.history = [];
  try {
    feedback.history = (await Bridge.invoke("feedback_history")) || [];
    feedback.offReason = null;
  } catch (e) {
    // A read that refused is TWO different conditions, and which one it is has already been
    // answered by `feedback_available` above. If the store is shut, this refusal IS the
    // reason — the backend's own sentence about this install, which names who owns it. If
    // the store said it was open, the same refusal is transient and gets a retry instead.
    if (feedback.available) feedback.historyFailed = String(e);
    else feedback.offReason = String(e);
  }
}

// ---- the ask ------------------------------------------------------------------------------

function feedbackButton(label, kind) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "desk-btn" + (kind ? " desk-btn--" + kind : "");
  b.textContent = label;
  return b;
}

/// The four keys, built from the backend's own list. `invitesReport` travels WITH each
/// rating rather than being re-derived from its digit — `Rating::invites_report` is the one
/// place that rule is written down, and a `key === "1" || key === "2"` here would be a
/// second place for it to be written differently.
function renderFeedbackKeys() {
  const zone = el("feedback-keys");
  zone.textContent = "";
  if (!feedback.wording) return;
  const answered = feedback.phase === "answered";
  for (const r of feedback.wording.ratings) {
    // NO KEY IS STYLED AS THE PRIMARY ONE. A filled `3: Good` reads as the selected answer,
    // and the first screenshot of the preview state caught it doing exactly that: the block
    // on screen said `rating: 1` while the Good button sat highlighted above it. There is no
    // recommended answer to this question.
    const b = feedbackButton(r.key + ": " + r.label);
    b.dataset.key = r.key;
    b.disabled = answered;
    b.addEventListener("click", () => answerFeedback(r.key, r.invitesReport === true));
    zone.appendChild(b);
  }
  const d = feedback.wording.dismiss;
  const dismiss = feedbackButton(d.key + ": " + d.label);
  dismiss.dataset.key = d.key;
  dismiss.disabled = answered;
  // A dismissal IS an answer and is recorded as one — `PromptOutcome::Dismissed`. Closing
  // the panel is NOT: he opened it himself, and recording a dismissal because he shut a
  // window he chose to open would put an answer in the file that nobody gave.
  dismiss.addEventListener("click", () => answerFeedback(d.key, false));
  zone.appendChild(dismiss);
}

/// One term type's choices. `single` builds radios (a payload carries exactly one failure
/// class and one occurrence count); the other two build checkboxes over lists.
function renderFeedbackGroup(legend, name, terms, single) {
  const group = document.createElement("fieldset");
  group.className = "feedback-group";
  group.dataset.group = name;
  const cap = document.createElement("legend");
  cap.className = "feedback-group-legend";
  cap.textContent = legend;
  group.appendChild(cap);
  for (const t of terms) {
    const row = document.createElement("label");
    row.className = "feedback-option";
    const input = document.createElement("input");
    input.type = single ? "radio" : "checkbox";
    input.name = name;
    input.value = t.wire;
    input.addEventListener("change", syncFeedbackChoice);
    const text = document.createElement("span");
    // `label` on the closed lists, `sentence` on the two that compose the report — the
    // backend hands over whichever this term type has, and this reads it rather than
    // guessing from the shape.
    text.textContent = t.sentence || t.label;
    row.appendChild(input);
    row.appendChild(text);
    group.appendChild(row);
  }
  return group;
}

function chosen(name) {
  return Array.from(
    el("feedback-choose").querySelectorAll('input[name="' + name + '"]:checked')
  ).map((i) => i.value);
}

/// The selection, in the payload's OWN field names — the same four keys the preview shows
/// him. Nothing is renamed on the way across.
function feedbackSelection() {
  const cls = chosen("failure_class");
  const occ = chosen("occurrences_this_session");
  return {
    failure_class: cls[0] || null,
    occurrences_this_session: occ[0] || null,
    generic_diagnosis: chosen("generic_diagnosis"),
    contributing_condition: chosen("contributing_condition"),
  };
}

/// A report with no diagnosis says nothing, and a payload with no class or count cannot be
/// assembled at all — the backend refuses each of those by name. The button is disabled
/// until the choice is complete rather than offered and then refused: a control that
/// appears and then says no teaches him the surface is unreliable.
function syncFeedbackChoice() {
  const btn = el("feedback-show-preview");
  if (!btn) return;
  const s = feedbackSelection();
  btn.disabled = !(s.failure_class && s.occurrences_this_session && s.generic_diagnosis.length > 0);
}

function renderFeedbackChoose() {
  const zone = el("feedback-choose");
  zone.textContent = "";
  if (!feedback.taxonomy) return;
  const t = feedback.taxonomy;
  zone.appendChild(renderFeedbackGroup("What kind of failure was it?", "failure_class", t.failureClass, true));
  zone.appendChild(renderFeedbackGroup("How many times this session?", "occurrences_this_session", t.occurrences, true));
  zone.appendChild(renderFeedbackGroup("What went wrong", "generic_diagnosis", t.diagnosis, false));
  zone.appendChild(renderFeedbackGroup("What let it happen", "contributing_condition", t.conditions, false));

  const actions = document.createElement("div");
  actions.className = "desk-card-actions";
  const show = feedbackButton("Show me exactly what you'd say", "confirm");
  show.id = "feedback-show-preview";
  show.disabled = true;
  show.addEventListener("click", showFeedbackPreview);
  actions.appendChild(show);
  zone.appendChild(actions);
}

// ---- the history --------------------------------------------------------------------------

function feedbackRatingLabel(outcome) {
  if (!outcome || outcome.kind !== "rated") return null;
  // Matched on the value serde ACTUALLY wrote, which the backend hands over as `wire`.
  // Deriving it here — lower-casing the label and hyphenating it — would be this file
  // guessing at a serialization format, and it would go on working right up until a variant
  // was renamed.
  const found = (feedback.wording ? feedback.wording.ratings : []).find((r) => r.wire === outcome.value);
  return found || null;
}

function renderFeedbackEntry(row) {
  const entry = row.entry || {};
  const card = document.createElement("article");
  card.className = "feedback-entry";
  card.dataset.decision = (entry.report && entry.report.decision) || "not_offered";

  const head = document.createElement("div");
  head.className = "feedback-entry-head";
  const rating = feedbackRatingLabel(entry.outcome);
  const key = document.createElement("span");
  key.className = "feedback-entry-key";
  key.textContent = rating ? rating.key : "0";
  head.appendChild(key);
  const label = document.createElement("span");
  label.className = "feedback-entry-label";
  label.textContent = rating ? rating.label : "Dismissed";
  head.appendChild(label);
  card.appendChild(head);
  card.dataset.rating = rating ? rating.key : "0";

  const decision = entry.report && entry.report.decision;
  if (decision === "declined") {
    const p = document.createElement("p");
    p.className = "feedback-entry-note";
    p.textContent = "You were offered a report and said no.";
    card.appendChild(p);
  } else if (decision === "approved") {
    const p = document.createElement("p");
    p.className = "feedback-entry-note";
    p.textContent = "You approved this report:";
    card.appendChild(p);
    // Re-rendered by the backend from the STORED payload — the same bytes he approved, and
    // the reason the record does not have to keep a second free-text copy of them.
    const pre = document.createElement("pre");
    pre.className = "desk-preview";
    pre.textContent = row.shown || "";
    card.appendChild(pre);
  }
  return card;
}

// ---- rendering the whole panel ------------------------------------------------------------

function renderFeedback() {
  const question = el("feedback-question");
  question.textContent = feedback.wording ? feedback.wording.question : "";

  const off = el("feedback-unavailable");
  const historyOff = el("feedback-history-off");
  const shut = feedback.available === false;
  off.hidden = !shut;
  historyOff.hidden = !shut;
  if (shut) {
    // The backend's own sentence, relayed verbatim. It names who owns the fix; this file
    // adds nothing to it, because this file diagnosed nothing.
    off.textContent = feedback.offReason || "";
    historyOff.textContent = feedback.offReason || "";
  }

  // The four keys are not offered when nothing could be kept. An answer that cannot be
  // recorded is a lost answer, and asking for one anyway is worse than not asking.
  el("feedback-keys").hidden = shut;
  renderFeedbackKeys();

  const offer = el("feedback-offer");
  offer.hidden = shut || !(feedback.phase === "offered");
  const choose = el("feedback-choose");
  choose.hidden = shut || !(feedback.phase === "choosing");
  const preview = el("feedback-preview-block");
  preview.hidden = shut || !(feedback.phase === "previewing");

  const broke = el("feedback-history-broke");
  broke.hidden = shut || !feedback.historyFailed;
  if (feedback.historyFailed) el("feedback-history-broke-reason").textContent = feedback.historyFailed;

  const readable = feedback.available === true && !feedback.historyFailed;
  el("feedback-history-empty").hidden = !(readable && feedback.history.length === 0);
  const list = el("feedback-history-list");
  list.textContent = "";
  if (readable) for (const row of feedback.history) list.appendChild(renderFeedbackEntry(row));
}

// ---- answering ------------------------------------------------------------------------------

/// He pressed one of the four keys.
///
/// `invitesReport` is the backend's answer about THAT rating, carried through untouched.
/// On a `3` or a dismissal the answer is recorded immediately and the offer is never made —
/// `FeedbackEntry::with_report` would refuse a report attached to either, and a surface that
/// offered one anyway would be inviting him into a refusal.
async function answerFeedback(key, invitesReport) {
  feedbackNotice("");
  feedback.key = key;
  if (invitesReport) {
    feedback.phase = "offered";
    el("feedback-offer-text").textContent = feedback.wording.reportOffer;
    const actions = el("feedback-offer-actions");
    actions.textContent = "";
    const yes = feedbackButton("Yes", "confirm");
    yes.id = "feedback-offer-yes";
    yes.addEventListener("click", () => {
      feedback.phase = "choosing";
      renderFeedbackChoose();
      renderFeedback();
      syncFeedbackChoice();
    });
    const no = feedbackButton("No thanks");
    no.id = "feedback-offer-no";
    no.addEventListener("click", () => recordFeedback({ decision: "declined" }, FEEDBACK_KEPT_WITHOUT_REPORT));
    actions.appendChild(yes);
    actions.appendChild(no);
    renderFeedback();
    return;
  }
  await recordFeedback({ decision: "not_offered" }, FEEDBACK_KEPT);
}

/// THE PREVIEW. Nothing is stored by this and nothing is consented to by pressing it — it
/// exists so he reads the report before he is asked to approve it.
///
/// The block he is shown is `full`: the heading and the report as one string, exactly as the
/// backend composed them. The two halves are laid out separately on screen, and `full` is
/// what travels back with the approval, so the composition on screen cannot drift from the
/// bytes that are checked.
async function showFeedbackPreview() {
  feedbackNotice("");
  const selection = feedbackSelection();
  try {
    const rendered = await Bridge.invoke("feedback_preview", { key: feedback.key, selection });
    feedback.selection = selection;
    feedback.shown = rendered.full;
    el("feedback-disclosure-heading").textContent = rendered.heading;
    el("feedback-preview").textContent = rendered.text;
    const actions = el("feedback-preview-actions");
    actions.textContent = "";
    const yes = feedbackButton("Yes, report that", "confirm");
    yes.id = "feedback-approve";
    yes.addEventListener("click", () =>
      recordFeedback(
        { decision: "approved", selection: feedback.selection, shown: feedback.shown },
        FEEDBACK_KEPT_WITH_REPORT
      )
    );
    const no = feedbackButton("No, don't report that", "never");
    no.id = "feedback-refuse";
    // A declined report is not a report: the payload is dropped and nothing about it is
    // recorded — `Disclosure::decline`'s own posture, kept on this side of the bridge too.
    no.addEventListener("click", () => recordFeedback({ decision: "declined" }, FEEDBACK_KEPT_WITHOUT_REPORT));
    actions.appendChild(yes);
    actions.appendChild(no);
    feedback.phase = "previewing";
    renderFeedback();
  } catch (e) {
    feedbackNotice(String(e), "attention");
  }
}

/// One line appended to one file, and that is the whole effect.
async function recordFeedback(report, said) {
  try {
    await Bridge.invoke("feedback_record", { key: feedback.key, report });
    feedback.phase = "answered";
    feedbackNotice(said);
  } catch (e) {
    feedbackNotice(String(e), "attention");
  }
  await refreshFeedback();
  renderFeedback();
}

// ---- opening and closing -----------------------------------------------------------------

async function openFeedback() {
  feedbackReturnFocus = document.activeElement;
  feedbackNotice("");
  // A fresh question every time the panel is opened. The record is the file; the phase is a
  // moment, and carrying the last answer's state back onto the screen would show him a
  // question he has already answered as though it were still open.
  feedback.phase = "asking";
  feedback.key = null;
  feedback.selection = null;
  feedback.shown = null;
  feedbackOverlayEl.hidden = false;
  feedbackBtn.setAttribute("aria-expanded", "true");
  await refreshFeedback();
  renderFeedback();
  const first = feedbackOverlayEl.querySelector(".desk-btn, #feedback-close");
  if (first) first.focus();
}

function closeFeedback() {
  feedbackOverlayEl.hidden = true;
  feedbackBtn.setAttribute("aria-expanded", "false");
  if (feedbackReturnFocus && document.contains(feedbackReturnFocus)) feedbackReturnFocus.focus();
  feedbackReturnFocus = null;
}

feedbackBtn.addEventListener("click", openFeedback);
el("feedback-close").addEventListener("click", closeFeedback);
feedbackOverlayEl.addEventListener("click", (e) => {
  if (e.target === feedbackOverlayEl) closeFeedback();
});
el("feedback-history-retry").addEventListener("click", () => refreshFeedback().then(renderFeedback));

// ---------------------------------------------------------------------------------------
// TECHY MODE (techy-mode design §3.1/§3.3/§3.4) — the opt-in technical view
//
// Phase 1 (richos `48561e4`) routed every non-text agent frame into `rich://machinery` and
// retained it in a per-thread day-sharded journal. **Retention runs ALWAYS and has no
// setting** (§3.2) — that unconditional write is the only reason "show me the technical
// view for a conversation I already had" is possible at all, and the toggle below controls
// RENDERING and nothing else. Turning it off does not stop anything being written; turning
// it on does not reach back before 2026-08-28.
//
// §3.3'S CONSTRAINT, AND HOW IT IS HELD. "With techy mode off the conversation surface is
// byte-identical to today." So: `loadTimeline` calls the same `get_timeline` it always
// did, `renderTechyState(null)` leaves `#techy-state` hidden and empty, `#techy-chip` stays
// `hidden`, and the technical row in `timeline.js` cannot match because a CEO-view item
// carries no `detail`. There is no chip, no chevron and no "show technical details" hint in
// the conversation when the mode is off — a visible affordance IS a change to the default.
//
// FOUR OF THE CEO'S QUESTIONS ARE OPEN (§7 / open-items 1.4) AND NONE OF THEM IS ANSWERED
// HERE. Each is left as a setting somebody chooses:
//
//   §7.1 global default vs per-thread — BOTH exist and both are reversible. The checkbox in
//        Settings is the global switch; the shortcut pins ONE thread and leaves the switch
//        alone; a pinned thread can be handed back with `set_techy_mode(enabled: null)`.
//   §7.2 the raw-payload window — nothing on this surface knows it. An expanded pane shows
//        the payload or says it is no longer kept, and it says so WITHOUT naming a
//        duration: "14 days" in copy would answer the question in copy.
//   §7.3 whether customers can find it — the v1 answer here is §3.3's: a shortcut and one
//        Settings line, and NO conversation-surface affordance while it is off. Saying yes
//        later costs one element; taking calm back once given away costs a lot.
//   §7.4 whether deleting a thread deletes its machinery — no delete-thread command exists
//        and this surface does not add one. Both halves of either answer are primitives
//        already (`MachineryJournal::delete_thread`, `ConfigStore::forget_techy_thread`).
//
// WHAT THIS IS NOT: a cockpit. There is no interrupt, no approve/deny, no re-run anywhere
// below. §5/§9 — techy mode is a window — and R2 business-action governance is deferred to
// V2 by CEO decision for v1 and all 1.x.
//
// ONE LIMIT, NAMED RATHER THAN HIDDEN: this is a RELOAD path, not a live technical stream.
// The `rich://machinery` event carries records the instant they happen, but the calm live
// family (`rich://activity-upserted`) is CEO-shaped by construction, so while a turn is
// running its rows appear WITHOUT their technical half and gain it when the turn ends —
// `loadTimeline` already runs on `rich://turn-completed`. Subscribing to `rich://machinery`
// here would give a live technical stream and would also make "the calm view does not
// subscribe to this event" (STREAMING.md, §3.3's test (a)) a runtime branch instead of a
// structural fact. That trade is not this slice's to make.
// ---------------------------------------------------------------------------------------

const techyChipEl = el("techy-chip");
const techyChipLabelEl = el("techy-chip-label");
const techyStateEl = el("techy-state");
const techyDefaultInput = el("techy-default");
const techyHintEl = el("techy-hint");

/// The ACTIVE thread's resolved answer, from `techy_mode`. `null` before the first read and
/// on an unwired bridge — treated as OFF, which is the only safe default: a wrong "on"
/// changes the calm surface, a wrong "off" changes nothing.
let techy = null;

function techyOn() {
  return !!(techy && techy.enabled);
}

/// Read this thread's answer from the backend. Never inferred from the previous thread's:
/// a per-thread override is per thread.
async function refreshTechy(threadId) {
  const mode = await invokeQuiet("techy_mode", { threadId });
  techy = mode || null;
  renderTechyChip();
  renderTechySettings();
}

/// §3.3's affordance rule, in one function: the chip exists only while the mode is ON.
function renderTechyChip() {
  const on = techyOn();
  techyChipEl.hidden = !on;
  if (!on) return;
  // Which of the CEO's two switches is holding this thread on — so turning it off from
  // here is a predictable act rather than a guess. §7.1 is open; this sentence is what
  // makes both halves legible while it is.
  techyChipLabelEl.textContent =
    techy.source === "thread" ? "Technical view · this conversation" : "Technical view · everywhere";
  techyChipEl.setAttribute(
    "aria-label",
    techy.source === "thread"
      ? "Technical view is on for this conversation. Turn it off."
      : "Technical view is on for every conversation. Turn it off here."
  );
}

function renderTechySettings() {
  // §15 puts a Techy Mode toggle in the settings menu, "directly under" Text size. That is
  // a SECOND ENTRANCE TO ONE STATE, not a second state: it reads `techy.default` and writes
  // through `setTechyDefault`, exactly as the rail's own preference row does. Repainting it
  // here — inside the one function that renders the other entrance — is what keeps the two
  // from ever showing different answers, because there is no path that updates one without
  // running this.
  window.RichSettings.paint();
  if (!techyDefaultInput) return;
  techyDefaultInput.checked = !!(techy && techy.default);
  if (!techyHintEl) return;
  const key = /Mac|iPhone|iPad/.test(navigator.platform || "") ? "\u2318\u21e7T" : "Ctrl+Shift+T";
  techyHintEl.textContent =
    techy && techy.source === "thread"
      ? `This conversation is set on its own. ${key} changes just this one.`
      : `${key} shows it for one conversation only.`;
}

/// The four states from `get_machinery`, rendered as the three sentences Rust wrote
/// (`src-tauri/src/machinery_view.rs`). Nothing is composed here — "no machinery was
/// recorded for this conversation" and "I can't read it" are different statements, and a
/// surface that picked between them locally would eventually pick wrong.
function renderTechyState(payload) {
  if (!payload || !payload.sentence) {
    techyStateEl.hidden = true;
    techyStateEl.textContent = "";
    techyStateEl.removeAttribute("data-state");
    return;
  }
  techyStateEl.textContent = payload.sentence;
  techyStateEl.dataset.state = payload.state;
  if (payload.reason) {
    // The operator-facing reason, kept out of the sentence and visible anyway: the CEO is
    // told plainly that it is not his to fix, and whoever set RichOS up gets the path.
    const why = document.createElement("span");
    why.className = "techy-reason";
    why.textContent = payload.reason;
    techyStateEl.appendChild(why);
  }
  techyStateEl.hidden = false;
}

const betweenTurnsEl = el("between-turns");
const betweenTurnsRowsEl = el("between-turns-rows");
const betweenTurnsQuietEl = el("between-turns-quiet");

/// §1.5's between-turn lane: what the session said with no turn in flight.
///
/// Reads `payload.timeline.betweenTurns` — the gated `TimelineView`'s own field, so what is
/// drawn here is what `Timeline::view` decided may be seen, not a second opinion formed in
/// the renderer. `payload` is `null` whenever techy mode is off, and then this section is
/// hidden and EMPTIED: §3.3's rule is that the conversation surface is byte-identical with
/// the mode off, and a section that merely had `hidden` set would still be in the document.
///
/// THREE STATES, and the third is the one worth building:
///
///   1. rows -> draw them, in the order the projection gave them (journal append order,
///      never re-sorted here — the lane's `sequence` is per-lease and restarts on a
///      rotation, which is why `machinery::project_between_turns` does not sort by it);
///   2. no rows, and Rust supplied a sentence -> say the sentence. An empty box under a
///      heading reads as "broken"; the sentence says the lane is quiet AND that an older
///      conversation's silence means the record was never written;
///   3. no rows and NO sentence -> the store was unreadable, and the state line above
///      already said so. A second sentence here would be a claim the store never supported.
function renderBetweenTurns(payload) {
  betweenTurnsRowsEl.textContent = "";
  betweenTurnsQuietEl.textContent = "";
  betweenTurnsQuietEl.hidden = true;
  const rows = payload && payload.timeline && Array.isArray(payload.timeline.betweenTurns)
    ? payload.timeline.betweenTurns
    : [];
  const sentence = payload ? payload.betweenTurnsSentence : null;
  if (!payload || (!rows.length && !sentence)) {
    betweenTurnsEl.hidden = true;
    return;
  }
  for (const row of rows) {
    // Deliberately the SAME `.tl-tech` shape a technical activity row uses: this is the
    // same kind of information, and giving it a second visual language would suggest it is
    // a different kind of fact. What it does NOT get is a status word — a session update
    // has no lifecycle, and `ACTIVITY_STATE_LABEL`'s "outcome not recorded" would invent
    // one for something that never had an outcome to record.
    const wrap = document.createElement("div");
    wrap.className = "tl-tech bt-row";
    wrap.dataset.vendor = row.vendorKind || "";
    const head = document.createElement("div");
    head.className = "tl-tech-head";
    const mark = document.createElement("span");
    mark.className = "tl-activity-mark";
    mark.setAttribute("aria-hidden", "true");
    mark.textContent = "\u00b7";
    head.appendChild(mark);
    const title = document.createElement("span");
    title.className = "tl-tech-title";
    title.textContent = row.vendorKind || "";
    head.appendChild(title);
    wrap.appendChild(head);
    const detail = row.detail || {};
    if (detail.summary) {
      const sum = document.createElement("div");
      sum.className = "tl-tech-summary";
      sum.textContent = detail.summary;
      wrap.appendChild(sum);
    }
    if (Array.isArray(detail.locations) && detail.locations.length) {
      const paths = document.createElement("div");
      paths.className = "tl-tech-paths";
      for (const p of detail.locations) {
        const one = document.createElement("span");
        one.className = "tl-tech-path";
        one.textContent = p;
        paths.appendChild(one);
      }
      wrap.appendChild(paths);
    }
    betweenTurnsRowsEl.appendChild(wrap);
  }
  if (!rows.length && sentence) {
    betweenTurnsQuietEl.textContent = sentence;
    betweenTurnsQuietEl.hidden = false;
  }
  betweenTurnsEl.hidden = false;
}

/// §2.4's raw pane, filled after the node is mounted. Three answers, and every one of them
/// is a sentence rather than a blank: the bytes, "not kept this long", or "I can't read
/// it". `pane` is the element `timeline.js` created and is already in the document.
async function fillMachineryRaw(machineryId, pane) {
  let res;
  try {
    res = await Bridge.invoke("get_machinery_raw", { threadId: activeThreadId, machineryId });
  } catch (e) {
    pane.dataset.note = "unwired";
    pane.textContent = String(e).startsWith("mock: no such command")
      ? "The stored output isn't reachable in this build."
      : String(e);
    return;
  }
  if (res.state === "retained") {
    delete pane.dataset.note;
    pane.textContent = typeof res.payload === "string" ? res.payload : JSON.stringify(res.payload, null, 2);
    if (res.note) {
      // A truncated payload is a PREFIX. It is shown, and it is labelled, because a prefix
      // that looks whole is worse than one that says it is not.
      const note = document.createElement("div");
      note.className = "tl-tech-note";
      note.textContent = res.note;
      pane.appendChild(note);
    }
    return;
  }
  pane.dataset.note = res.state;
  pane.textContent = res.note || "";
}

// ---------------------------------------------------------------------------------------
// THE RAW-RETENTION WINDOW (§7.2 — open-items 1.4), the surface half.
//
// §7.2 IS THE CEO'S QUESTION AND NOTHING HERE ANSWERS IT. This is the control that makes
// each of his answers cost the same: three named choices, backed by `raw_retention` /
// `set_raw_retention` (main.rs -> config.rs), durable, applied the moment he picks one.
//
// UNLIKE THE TWO PREFERENCES ABOVE, THIS ONE HAS NO `localStorage` MIRROR. The dial and the
// splash switch cache locally because something has to paint before the async round trip
// resolves. This control governs a DELETE, and a local cache of a delete setting is a second
// answer that can disagree with the store — so there is exactly one source of truth, and
// until it answers the surface shows nothing selected rather than a guess. On an unwired
// bridge (the mock harness with these commands absent) the group stays empty and says so,
// which is the honest state for a control whose backend is not there.
// ---------------------------------------------------------------------------------------

const retentionHintEl = el("retention-hint");
const RETENTION_UNWIRED = "This build can't reach the retention setting.";

/// Bytes, in the roundest unit that is still true. Deliberately decimal (MB = 1,000,000):
/// the CEO reads this against what Finder tells him about his disk, and Finder is decimal.
function formatBytes(n) {
  if (typeof n !== "number" || !isFinite(n) || n < 0) return null;
  if (n < 1000) return n + " bytes";
  const units = ["KB", "MB", "GB", "TB"];
  let v = n / 1000;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + units[i];
}

/// The window in the CEO's words, from the two axes the backend reports — never from the
/// choice name, so a hand-edited `config.json` describes itself instead of borrowing the
/// nearest button's sentence.
function retentionWindowSentence(view) {
  const days = view.ageDays;
  const bytes = view.totalBytes;
  const age = days === "forever" ? null : days === 1 ? "1 day" : days + " days";
  const cap = bytes === "forever" ? null : formatBytes(bytes);
  if (!age && !cap) return "Nothing is ever removed.";
  if (age && cap) return "Kept for " + age + ", or " + cap + " of output — whichever comes first.";
  if (age) return "Kept for " + age + ". No size limit.";
  return "Kept until it reaches " + cap + ", oldest first.";
}

/// What the popover says under the three choices: the window, what it costs today, and — on
/// the one call that just deleted something — what it removed.
///
/// THE EVICTION SENTENCE IS THE POINT. `evict_raw` is an `unlink` and nothing else in this
/// product would ever mention it. A CEO who tightens the window and is told "removed the
/// stored output from 3 earlier days" has been told; one who is told nothing finds out by
/// opening a row that is empty, weeks later, and cannot connect it to anything he did.
function renderRetention(view) {
  const inputs = assertivenessPopover.querySelectorAll('input[name="raw-retention"]');
  if (!view) {
    for (const input of inputs) input.checked = false;
    if (retentionHintEl) retentionHintEl.textContent = RETENTION_UNWIRED;
    return;
  }
  for (const input of inputs) input.checked = input.value === view.choice;
  if (!retentionHintEl) return;
  const parts = [retentionWindowSentence(view)];
  const used = formatBytes(view.retainedBytes);
  if (used) parts.push("Using " + used + " now.");
  if (view.evicted > 0) {
    parts.push(
      "Removed the stored output from " +
        (view.evicted === 1 ? "1 earlier day" : view.evicted + " earlier days") +
        ". The records are still there; their output is not."
    );
  }
  if (view.choice === "custom") {
    parts.push("Set by hand in config.json, so none of the three is selected.");
  }
  retentionHintEl.textContent = parts.join(" ");
}

async function syncRetentionFromBackend() {
  renderRetention(await invokeQuiet("raw_retention"));
}

/// Pick a window. Applied at once — the backend evicts against the new setting on this call
/// rather than at the next launch — and the answer it returns is what gets rendered, so the
/// surface never claims a window the store did not take.
async function setRetentionChoice(choice) {
  const view = await invokeQuiet("set_raw_retention", { choice });
  // A refusal (an unknown choice, a write failure, an unwired bridge) must not leave the
  // radio showing a setting nothing accepted. Re-read instead of assuming.
  if (!view) return syncRetentionFromBackend();
  renderRetention(view);
}

/// Flip THIS conversation, and pin it — `set_techy_mode` writes a per-thread override, so
/// the global switch can move afterwards without dragging this thread with it (§3.1).
async function toggleTechyThread() {
  if (!activeThreadId) return;
  const next = !techyOn();
  const mode = await invokeQuiet("set_techy_mode", { threadId: activeThreadId, enabled: next });
  // An unwired bridge must not leave the surface claiming a state the backend does not
  // have: no answer, no change. (`invokeQuiet` returns null on rejection.)
  if (!mode) return;
  techy = mode;
  renderTechyChip();
  renderTechySettings();
  // §3.4: "Toggling re-renders the thread in place, from the journal. No reload, no
  // navigation." The scroll position is the CEO's and is preserved across the swap.
  const top = conversationEl.scrollTop;
  await loadTimeline();
  conversationEl.scrollTop = top;
}

/// The global switch (§3.1: "all" must be one switch, not N toggles). Threads the CEO
/// pinned individually keep their own answer — that is what makes a pin mean anything, and
/// it is the half of §7.1 a global-only build would lose.
async function setTechyDefault(on) {
  await invokeQuiet("set_techy_default", { enabled: on });
  await refreshTechy(activeThreadId);
  const top = conversationEl.scrollTop;
  await loadTimeline();
  conversationEl.scrollTop = top;
}

if (techyChipEl) techyChipEl.addEventListener("click", toggleTechyThread);
if (techyDefaultInput) {
  techyDefaultInput.addEventListener("change", () => setTechyDefault(techyDefaultInput.checked));
}

// The settings menu's Techy row, registered with the SAME read and the SAME write the rail
// preference uses. Registering the capability is also what makes the row appear at all —
// settings-button.js omits it until a host provides one, so the component still works on a
// page with no shell behind it and carries no dead toggle there.
window.RichSettings.registerTechy({
  read: () => !!(techy && techy.default),
  write: (on) => setTechyDefault(on),
});
for (const input of assertivenessPopover.querySelectorAll('input[name="raw-retention"]')) {
  input.addEventListener("change", () => setRetentionChoice(input.value));
}

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
  // §3.3: "v1 access = a keyboard shortcut, plus one line in Settings." This is the
  // shortcut, and it flips ONE conversation — the CEO's daily path. Shift is what keeps it
  // clear of the new-thread binding above, which is deliberately `mod` WITHOUT shift.
  if (mod && e.shiftKey && (e.key === "t" || e.key === "T")) {
    e.preventDefault();
    toggleTechyThread();
    return;
  }
  if (e.key === "Escape") {
    // §18: "Escape closes overlays and inspector detail."
    if (!threadMenuEl.hidden) return closeThreadMenu();
    if (!searchOverlayEl.hidden) return closeSearch();
    if (!entityPickerEl.hidden) return closeEntityPicker();
    if (!correctionsOverlayEl.hidden) return closeCorrections();
    if (!feedbackOverlayEl.hidden) return closeFeedback();
    if (!slideoverEl.hidden) return closeSlideOver();
    if (!inspectorEl.hidden) return closeWorkerInspector();
    if (isNarrow() && railOpen) return setRailOpen(false);
  }
});

// ---------------------------------------------------------------------------------------
// APPEARANCE AND IDENTITY (CEO ruling §15, and his correction to round 10.1)
// ---------------------------------------------------------------------------------------

/// Reconcile the pre-paint mirror against the durable truth in config.rs.
///
/// `theme-boot.js` painted the first frame from `localStorage` because an async round trip
/// cannot decide frame one. That mirror can be stale (a preference set on another launch)
/// or absent (a webview that lost its storage). This is where the two are made to agree,
/// and the direction is fixed: THE BACKEND WINS. A mirror that could overwrite the store
/// would be a second place the decision is made, which is how a preference starts flipping
/// between launches for no reason the CEO can see.
async function syncAppearanceFromBackend() {
  const durable = await invokeQuiet("get_appearance");
  if (durable) window.RichTheme.sync(durable);
  // Register the durable half only NOW, after the sync — registering earlier would let a
  // keystroke during boot write the mirror's value back over the store's.
  window.RichSettings.registerDurable({
    saveTheme: (pref) => invokeQuiet("set_theme", { theme: pref }),
    saveScale: (pct) => invokeQuiet("set_font_scale", { scale: pct }),
  });
  window.RichSettings.paint();
}

/// The foot of the rail: HIS initials, then HIS name.
///
/// THE UNSET STATE IS THE COMMON ONE and it is rendered honestly. There was no user-name
/// preference in this product until today, so most installs have nothing here. The circle
/// stays empty — no letters, because inventing two is the thing the correction forbids and
/// "??" is a placeholder pretending to be a value — and the label says what is true. In
/// that state the row is an OFFER (it opens the preferences popover, where the field is)
/// rather than a dead end; once he has a name it is a nameplate and not a control.
async function renderUserIdentity() {
  if (!railIdentityEl) return;
  const who = (await invokeQuiet("get_user_identity")) || { name: null, initials: null };
  const field = el("user-name-input");
  // Never clobber what he is mid-way through typing.
  if (field && document.activeElement !== field) field.value = who.name || "";
  const named = !!(who.name && who.name.trim());
  railIdentityEl.classList.toggle("is-unset", !named);
  railInitialsEl.textContent = named ? who.initials || "" : "";
  railUserNameEl.textContent = named ? who.name : "Set your name";
  railIdentityEl.setAttribute(
    "aria-label",
    named ? who.name : "No name is set. Open preferences to add yours."
  );
  // A nameplate is not a button. Only the unset state is actionable, so only the unset
  // state advertises itself as one.
  if (named) railIdentityEl.removeAttribute("aria-haspopup");
  else railIdentityEl.setAttribute("aria-haspopup", "true");
}

const userNameInput = el("user-name-input");
if (userNameInput) {
  // Written on `change` (blur or Enter), not on every keystroke: the store rewrites the
  // whole file on every set, and a per-keystroke write would put "A", "Al", "Ale" on disk
  // on the way to "Alex".
  userNameInput.addEventListener("change", async () => {
    await invokeQuiet("set_user_name", { name: userNameInput.value });
    await renderUserIdentity();
  });
  userNameInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") userNameInput.blur();
  });
}

if (railIdentityEl) {
  railIdentityEl.addEventListener("click", () => {
    if (railIdentityEl.classList.contains("is-unset")) openAssertivenessPopover();
  });
}

// ---------------------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------------------
async function init() {
  // The rail header is the WORDMARK now (§15), inlined in index.html — the company is a
  // `rail-group` in the sidebar below. `get_company_name` and its store are untouched and
  // still the source for anything that needs the company; this element is kept, hidden, so
  // the name is still queryable rather than deleted from the surface entirely.
  try {
    railCompanyEl.textContent = await Bridge.invoke("get_company_name");
  } catch (_e) {
    railCompanyEl.textContent = COMPANY_LABEL_FALLBACK;
  }

  // APPEARANCE (§15). `theme-boot.js` already painted the first frame from its synchronous
  // mirror; this is the reconciliation, and config.rs wins. `RichTheme.sync` corrects the
  // mirror when the two disagree — never the other way round — so a preference set on
  // another launch, or a webview that lost its storage, lands on the durable answer.
  await syncAppearanceFromBackend();
  await renderUserIdentity();
  syncAssertivenessFromBackend();
  // The GLOBAL techy default at launch, so the Settings line is honest before any thread is
  // opened. The per-thread answer arrives with the thread (`openThread`).
  await refreshTechy("");

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
  // WHICH COMPANY THIS COPY OF RICH IS FOR, read before the branch below, because the
  // branch below is where a launch that resolved none used to fall into the wrong arm.
  await refreshEntityChoice();
  // WHERE HIS MEMORY IS, read before the branch below for the same reason the company
  // choice is: this question comes FIRST when both are open, and the branch below must know
  // that so it holds the company question back instead of stacking a second dialog on it.
  await refreshMemory();
  // WHETHER VOICE IS EVEN OFFERED, read before anything renders the greeting or the
  // composer row. It sits beside the setup read below because it answers the same kind of
  // question — what this machine does and does not have — and it costs the same kind of
  // work: path lookups and one `command -v`, no device and no permission prompt.
  await refreshVoiceReadiness();
  // WHAT THIS MACHINE IS MISSING, read and asked FIRST when it is missing anything. The
  // order is not cosmetic: without a `claude` binary and an engine directory there is
  // nothing for a corpus to be read by and nothing for a company to be chosen for. One
  // dialog at a time — `closeSetupSheet` hands off to the memory question, which hands off
  // to the company question, so a fresh install answers all three, in order.
  await refreshSetup();
  const setupAsked = maybeAskAboutSetup();
  // The memory question is HELD, not skipped, when the setup sheet took the screen —
  // `closeSetupSheet` asks it the moment this one is answered.
  if (setupAsked) memoryQuestionDeferred = true;
  const memoryAsked = !setupAsked && maybeAskAboutMemory();

  const active = activeContext ? activeContext.thread_id : await invokeQuiet("active_thread");
  if (active && threadRow(active)) {
    await openThread(active);
  } else if (entityChoice && !entityChoice.chosen) {
    // NO COMPANY IS SET — the state every double-clicked launch is in until he answers
    // once. Block the composer, render the control, and ask. `startNewThreadFlow()` below
    // is deliberately NOT this: it asks which company one THREAD is for and remembers
    // nothing, so on this launch it produced a dialog he would have been shown again every
    // time he opened the app, over a composer that could not send.
    //
    // Unless the memory question is already on screen: `closeMemorySetup` asks this one the
    // moment that one is answered, so a fresh install answers both, in order, one dialog at
    // a time.
    if (setupAsked || memoryAsked) companyQuestionDeferred = true;
    else requireCompanyChoice();
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
  // FOCUS GOES TO THE COMPOSER UNLESS SOMETHING IS ASKING HIM A QUESTION.
  //
  // This line was unconditional, and it is half of why the entity picker did not save the
  // double-clicked launch: `startNewThreadFlow()` opens the dialog and focuses its first
  // row, and then this ran and took focus straight back. Measured on a real Finder launch
  // of the f44f89a bundle — the picker was open on screen, `AXFocusedUIElement` was the
  // composer behind it, and the sentence typed into it was refused.
  // The memory dialog is in this condition for exactly the reason the picker is: it is a
  // question, and taking focus off a question to put it on a composer behind that question
  // is the measured defect this line already carries the scar of.
  if (entityPickerEl.hidden && memorySetupEl.hidden) inputEl.focus();
  // THE OPENING SCREEN GETS OUT OF THE WAY, HERE AND NOWHERE ELSE.
  //
  // This is the line below which the CEO can work: the rail is drawn, the thread is open,
  // the composer is armed and focused. Everything after it - the correction badge, the
  // splash's own durable bookkeeping - happens with the app already usable, which is why
  // the comment three lines down says so about the desk. The curtain leaves at exactly
  // that point, mid-ceremony if the launch was quick, because a doorway that holds him
  // back from his work has inverted the product.
  //
  // ONE CALL, NOT AWAITED. `yieldNow` starts a fade on an inert, click-through layer and
  // returns; nothing in this boot path ever waits on the splash.
  if (window.RichSplash) window.RichSplash.yieldNow("app-ready");
  // The correction badge, read at launch and LAST. A proposal the CEO has not answered
  // survives a crash, a rotation and a relaunch by design (`correction.rs`'s fsync'd log),
  // so the count is re-read on the way up rather than inferred from this session's events —
  // but six commands' worth of reads must not stand between him and a focused composer, so
  // it happens after the app is usable.
  await refreshDesk();
  // The splash's durable bookkeeping, dead last on purpose: neither call affects anything
  // the CEO can see this launch, and neither may stand between him and a focused composer.
  syncSplashFromBackend();
  noteSplashShown();
  // The launch record, beside them and dead last for the same reason: it changes nothing
  // the CEO can see this launch.
  readLaunchRecord();
  // The retention window, beside them and for the same reason: it changes nothing the CEO
  // can see this launch, and it must not stand between him and a focused composer. Read
  // rather than cached — see the block comment over `renderRetention`.
  syncRetentionFromBackend();
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
