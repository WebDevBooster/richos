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

// ---------------------------------------------------------------------------------------
// WHO IS ALLOWED TO DECIDE WHICH THREAD IS ON SCREEN
// ---------------------------------------------------------------------------------------
//
// THE RAIL IS PRESSABLE BEFORE `init()` HAS FINISHED, AND THAT IS CORRECT. `refreshNavigation()`
// paints real `.nav-thread` buttons wired to real handlers, and from that instant pressing one
// does exactly what it says. What was NOT correct is what came after: `init()` made five more
// bridge calls and then opened the thread the LAST session had ended on, over the top of the
// one the CEO had just asked for, with no error and no sign that anything had been refused.
//
// MEASURED 2026-09-06 on this file at `041eee8`, WebKit, mock bridge, one uniform latency per
// bridge call. `init()` reaches the rail on its 7th call and its landing branch 5 calls later;
// a press is overwritten when its own two-call chain (`switch_thread`, `active_context`) cannot
// land before that branch — i.e. between 3 and 5 call-times after the row appears:
//
//     lag    predicted wrong window     measured wrong (click N ms after the row exists)
//     120ms  [3x120, 5x120) = 360-600   350, 400, 450, 500, 550     (ok at 300 and 600)
//     400ms  [3x400, 5x400) = 1200-2000 1200, 1600                  (ok at 800 and 2000)
//
// At 120 ms — an ordinary machine, not a pathological one — pressing "hiring" landed the CEO on
// "general": Harbor Analytics, "Running", zero turns, under a rail row he never pressed.
//
// THE FIX IS NOT A SHORTER WINDOW, IT IS NO WINDOW. Two counters, both taken synchronously, so
// no interleaving of the awaits can produce a different answer:
//
//   * `handNavigations` — a thread the CEO ASKED for. `init()`'s landing branch is a RESTORE of
//     where the last session ended, and a restore is lower authority than a live instruction:
//     if he has chosen, the restore does not run at all, so nothing is opened over his choice
//     and no `switch_thread` for the old thread is issued behind it either.
//   * `navTicket` — every `openThread` takes one before its first `await` and abandons itself
//     after every `await` if a newer one has started. This is what stops "whichever chain
//     finishes last wins", which is the same defect between two presses as it is between a
//     press and the boot.
//
// WHY HONOR THE PRESS RATHER THAN DISARM THE ROW UNTIL BOOT ENDS. A row that is painted, named,
// and carrying a handler which works is not a placeholder — disarming it would be a control that
// looks pressable and is not, which is the same family of defect one level along, and it would
// cost the CEO the fastest path into his own work on every launch. §21's rule is the argument
// as well: a REMEMBERED selection must never overwrite a CHOSEN one.
let openingThread = null;
let navTicket = 0; // every openThread takes one, synchronously, before its first await
let handNavigations = 0; // how many threads the CEO has asked for himself this launch

/// The backend's activation, ISSUED IN THE ORDER IT WAS ASKED FOR.
///
/// Two `switch_thread` invokes in flight at once can be applied by the Rust side in either
/// order, and the loser is what the next launch restores — so a race here does not end when the
/// window is repainted, it is remembered. Chaining them costs the second press one round trip
/// and buys an ordering that does not depend on how long either takes.
let switchChain = Promise.resolve();
function switchThreadInOrder(threadId) {
  const next = switchChain.then(
    () => Bridge.invoke("switch_thread", { threadId }),
    () => Bridge.invoke("switch_thread", { threadId })
  );
  switchChain = next.then(
    () => {},
    () => {}
  );
  return next;
}

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
  if ((mainView === "conversation" || mainView === "opening") && activeThreadId) put(activeThreadId, inputEl.value);
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
  if (view !== "opening") openingThread = null;
  conversationEl.hidden = view !== "conversation";
  entityViewEl.hidden = view !== "entity";
  unboundViewEl.hidden = view !== "unbound";
  // The waiting band is a conversation surface. It never sits over the entity screen or the
  // §21 unbound screen, where there is no turn on screen for it to describe.
  hideWaitBandOffConversation();
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
  if ((mainView === "conversation" || mainView === "opening") && activeThreadId) {
    drafts.set(activeThreadId, inputEl.value);
    if (mainView === "conversation") scrollTops.set(activeThreadId, conversationEl.scrollTop);
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

/// `opts.restore` marks the ONE caller that is not the CEO asking: `init()`'s "put him back
/// where he was". See the block over `navTicket` — it yields to a press, and every other caller
/// counts as a press.
async function openThread(threadId, opts) {
  opts = opts || {};
  const row = threadRow(threadId);
  if (!row) return;
  // THE RESTORE NEVER OVERWRITES A CHOICE, and it is checked here as well as at the call site
  // so that a future second caller of the restore path inherits the rule rather than having to
  // remember it.
  if (opts.restore && handNavigations > 0) return;
  // Counted BEFORE the "already there" return below: pressing the row you are on is still a
  // statement of where you want to be, and the restore has nothing to add to it.
  if (!opts.restore) handNavigations++;
  if (threadId === activeThreadId && mainView === "conversation") return;

  // Taken before the first await. `stale()` is true from the instant a newer openThread has run
  // its own synchronous head, so an older chain resuming later paints nothing.
  const ticket = ++navTicket;
  const stale = () => ticket !== navTicket;

  const previousModel = openingThread ? openingThread.previousModel : timelineModel;
  stashThreadViewState();
  clearLiveMark(threadId);
  activeThreadId = threadId;
  // The previous company's offer must not remain clickable while activation is pending.
  el("first-run").hidden = true;
  firstRunState = null;
  ++firstRunRead;
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

  openingThread = { threadId, previousModel, startedAt: Date.now(), quietAnnounced: false };
  inputEl.value = drafts.get(threadId) || "";
  inputEl.disabled = false;
  autoGrow();
  composerBlockedEl.hidden = true;
  composerScopeEl.hidden = true;
  setMainView("opening");
  syncComposerMode();
  renderRail();
  startOrStopWaitTimer();
  announce("Opening conversation.");
  try {
    await switchThreadInOrder(threadId);
  } catch (e) {
    if (stale()) return;
    showUnboundView(row, String(e));
    renderRail();
    return;
  }
  // A NEWER PRESS HAS TAKEN THE SCREEN. Everything below paints, so this chain stops here
  // rather than painting an older thread over a newer one — and the newer chain's own
  // `switch_thread` is queued behind ours, so the backend ends on the newer one too.
  if (stale()) return;

  await refreshActiveContext();
  if (stale()) return;
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
  if (stale()) return;
  await loadTimeline();
  if (stale()) return;
  if (mainView !== "opening") return; // loadTimeline fell into the unbound state
  drafts.set(threadId, inputEl.value); // typing while opening belongs to this destination
  showConversationView();
  renderRail();
  restoreThreadViewState(threadId);
  resetWaitBandForThread();
  scheduleRender();
  // WHERE ONBOARDING STANDS FOR THIS THREAD'S COMPANY. Re-derived on every thread open
  // rather than once at boot, because a thread's company is immutable and moving between
  // threads can move between companies — a notice left over from the last one would be a
  // claim about a company it was not derived for.
  await renderFirstRunNotice();
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
  // The band belongs to the thread ON SCREEN, so a reload or a thread switch re-derives it
  // from the model that was just applied rather than carrying the previous thread's across.
  resetWaitBandForThread();
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
  const loadedModel = timelineModel;
  const loadedThread = activeThreadId;
  const stale = () => loadedModel !== timelineModel || loadedThread !== activeThreadId;
  const techy = techyOn();
  let snapshot;
  try {
    if (techy) {
      const machinery = await Bridge.invoke("get_machinery", { threadId: activeThreadId });
      if (stale()) return;
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
    if (stale()) return;
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
  if (stale()) return;
  window.RichTimeline.applySnapshot(timelineModel, snapshot);
  reviveLiveTurns();
  scheduleRender();
}

// ---------------------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------------------
// Correlate an invocation with the accepted turn, rather than any live turn on screen.
const pendingSends = new Map();

function visiblePendingSend() {
  return [...pendingSends.values()].find((request) => !request.turnId &&
    (request.model === timelineModel || request.threadId && request.threadId === activeThreadId));
}

function restoreUnsentText(text, threadId) {
  const current = threadId === activeThreadId;
  const draft = current ? inputEl.value : drafts.get(threadId) || "";
  const restored = draft.trim() && draft !== text ? text + "\n\n" + draft : text;
  if (threadId) drafts.set(threadId, restored);
  if (current) {
    inputEl.value = restored;
    autoGrow();
  }
  parkViewStateNow();
}

async function send(explicitText) {
  if (mainView === "opening") return;
  // Start/Resume sends its own acceptance without silently submitting or deleting a draft.
  const preserveDraft = typeof explicitText === "string";
  const text = preserveDraft ? explicitText.trim() : inputEl.value.trim();
  if (!text) return;
  // §9.2: "The composer remains enabled. This is essential. Long work should not trap the
  // CEO in a passive state." Until this slice the line here read `if (anyLiveTurn()) return;`
  // — an honest refusal, because the spine's mutex is held for the whole turn and there was
  // nowhere durable to put the words. There is now (`steering.rs`), so they go there.
  if (anyLiveTurn()) return steer(text, preserveDraft);
  // §21 "Entity binding failure": BLOCK SEND and state why. Never quietly file the CEO's
  // words somewhere Rich guessed.
  if (sendBlockedReason) {
    composerBlockedEl.textContent = sendBlockedReason;
    composerBlockedEl.hidden = false;
    return;
  }
  const keptDraft = preserveDraft ? inputEl.value : "";
  if (!preserveDraft) inputEl.value = "";
  autoGrow();
  // THE SENT WORDS STOP BEING A DRAFT, on disk as well as in the box. Without this the
  // parked copy outlives the send and a crash would put a sentence he has already sent back
  // into his composer — the one restore that would be worse than no restore at all.
  if (activeThreadId && !preserveDraft) drafts.delete(activeThreadId);
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
    pendingSends.set(optimisticId, { model: timelineModel, threadId: null, turnId: null, startedAt: Date.now() });
    startOrStopWaitTimer();
    renderWaitBand();
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
      pendingSends.delete(optimisticId);
      startOrStopWaitTimer();
      removeWaitBand();
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
    if (preserveDraft && keptDraft) drafts.set(newId, keptDraft);
    pendingSends.get(optimisticId).threadId = newId;
    draftEntityId = null;
    await refreshNavigation();
    await openThread(newId);
    pendingSends.delete(optimisticId);
  }

  // §25: "The submitted message renders immediately on the right in a quiet highlighted
  // surface." It carries a synthetic id until `rich://turn-status` names the turn, then it
  // is RE-KEYED onto `{turnId}:user` — the same id the ledger derives — so the CEO's one
  // sentence is never drawn twice.
  const sentModel = timelineModel;
  const sentThreadId = activeThreadId;
  const pendingId = window.RichTimeline.addPendingUserMessage(sentModel, text, Date.now());
  const request = { model: sentModel, threadId: sentThreadId, turnId: null, startedAt: Date.now() };
  pendingSends.set(pendingId, request);
  startOrStopWaitTimer();
  renderWaitBand();
  followBottom = true;
  scheduleRender();

  try {
    await Bridge.invoke("send_message", { text, threadId: sentThreadId });
  } catch (e) {
    // A terminal event already explains this attempt. If the command rejected without
    // one, end only this invocation's local live state. A queued turn is not proof that
    // the operation survived its rejection, nor is another thread's live turn relevant.
    if (request.turnId) {
      const turn = sentModel.turns.get(request.turnId);
      if (turn && !turn.live) return;
      window.RichTimeline.markSendRejected(sentModel, request.turnId);
      sessionLiveTurns.delete(request.turnId);
      waitHistory.delete(request.turnId);
      if (timelineModel === sentModel) {
        syncWaitBand({ turnId: request.turnId, status: "failed" });
        syncComposerMode();
        scheduleRender();
        announce("Rich stopped before finishing.");
      }
      return;
    }
    window.RichTimeline.dropPendingUserMessage(sentModel, pendingId);
    restoreUnsentText(text, sentThreadId);
    if (timelineModel !== sentModel) return;

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
    // IS THE SETTING UP THE REASON? Asked of the disk, at the moment it is acted on — the
    // same discipline `send_message`'s own gate follows, and for the same reason: this answer
    // changes inside a session the moment `run_setup` finishes.
    //
    // WHY THE WINDOW ASKS AT ALL, rather than matching the sentence it was handed. A refusal
    // is a string; matching on its text is a second copy of a decision the backend already
    // made, and the two would drift the first time a word changed. `setup_status` is the same
    // question `init` asks at boot, so there is one answer and one place it comes from.
    const setupNow = await refreshSetup();
    const setupPending = !!(setupNow && setupNow.ask && setupNow.ask.items.length);
    window.RichTimeline.addLocalNotice(
      timelineModel,
      (reason || "I couldn't get that to my desk just now, and nothing is running.") +
        (setupPending
          ? " Your words are back in the box below, word for word — they'll be there when the" +
            " setting up is done."
          : " Your words are back in the box below, word for word — press Send when you want" +
            " me to try again."),
      Date.now()
    );
    syncComposerMode();
    scheduleRender();
    // THE OFFER, ACTUALLY ON SCREEN — and this line is what makes the backend's sentence
    // true rather than a claim. `setup_view::SETUP_INCOMPLETE_*` says "I've put the setting
    // up back on your screen: press Set it up"; a notice that named a sheet nobody reopened
    // would be the same defect as "quit and reopen" on a machine with no engine, one layer
    // up. `#setup-go` is the control the affordance rule requires that sentence to name.
    //
    // WHY THIS STATE IS REACHABLE AT ALL after the backdrop no longer dismisses the sheet:
    // "Not now" is a real answer and he is entitled to give it. Deferring the setting up and
    // then trying to send is a legitimate path, not a mistake — so it gets an offer rather
    // than a refusal, every time, for as long as the pieces are missing.
    if (setupPending) maybeAskAboutSetup();
  } finally {
    pendingSends.delete(pendingId);
    startOrStopWaitTimer();
    renderWaitBand();
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
async function steer(text, preserveDraft) {
  if (!preserveDraft) inputEl.value = "";
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
  const stoppedOpening = openingThread;
  const stoppedModel = stoppedOpening ? stoppedOpening.previousModel : timelineModel;
  try {
    const live = [...stoppedModel.turns.entries()].filter(([, turn]) => turn.live);
    const target = live.find(([, turn]) => turn.status !== "queued") || live[0];
    if (!target) return;
    const report = await Bridge.invoke("stop_turn", { expectedTurnId: target[0] });
    if (!report || !report.stopped) return;
    if (openingThread === stoppedOpening && stoppedOpening) openingThread.stopError = null;
    if (window.RichTimeline.markStopping(stoppedModel, report.turnId)) scheduleRender();
    markWaitStopping(report.turnId);
    announce("Stopping.");
    // REPORTED, NOT HIDDEN. The request is durable and the turn will be recorded as
    // stopped either way, but nothing was there to interrupt it — so the work may still run
    // to its natural end, and saying "stopped" flatly would be a claim about the lease that
    // this app cannot make.
    if (report.reachedLease === false) {
      window.RichTimeline.addLocalNotice(
        stoppedModel,
        "I've noted that you stopped this. I couldn't interrupt the work already in flight, " +
          "so it may finish on its own — nothing new will start.",
        Date.now()
      );
      scheduleRender();
    }
  } catch (e) {
    if (openingThread === stoppedOpening && stoppedOpening) {
      openingThread.stopError = "I couldn't stop the previous conversation. Press Stop again.";
      renderWaitBand();
      announce(openingThread.stopError);
    }
    // NAMES THE CONTROL. The old sentence stopped at "so I haven't acted on it" — true,
    // and it left the CEO with a fact and no instruction while the button that would fix
    // it sat three inches below, unmentioned. `syncComposerMode()` in the `finally` below
    // re-enables Stop before this is read, and Stop is visible for as long as the turn is
    // live, so the sentence names something that is on screen at the moment it is read.
    window.RichTimeline.addLocalNotice(
      stoppedModel,
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
  if (mainView === "opening" && openingThread) {
    const turns = [...openingThread.previousModel.turns.values()];
    const working = turns.some(t => t.live);
    const stopping = turns.some(t => t.live && t.status === "stopping");
    inputEl.placeholder = idlePlaceholder;
    stopBtn.hidden = !working;
    stopBtn.disabled = stopping;
    sendBtn.hidden = false;
    sendBtn.disabled = true;
    el("composer-row").dataset.mode = "opening";
    return;
  }
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

// ---------------------------------------------------------------------------------------
// THE WAITING STATE — what the CEO sees while a turn runs and nothing has come back
// (the first outside user's report, 2026-09-06)
// ---------------------------------------------------------------------------------------
//
// HIS WORDS: *"it takes a lot of time to get a reply, a lot of spinning wheels waiting …
// no interaction of feedback, so it looks like a crashed application."*
//
// MEASURED FIRST, WRITTEN SECOND. A 60-second turn was driven under WebKit against this
// renderer with `send_message` never returning and the spine's own `queued -> working`
// events on the wire; the driver, the frames and the frame-by-frame reading are committed
// at `docs/verification/waiting-state-2026-09-06/`. At 2s, 10s, 30s and 60s the only thing
// on the entire screen saying the app was alive was the timeline's duration row —
// `Working for 58s`, 14px, in the top-left corner of an otherwise empty 400px region — plus
// a 5px dot beside it. The four frames were otherwise identical.
//
// So the app was never silent by design. It was quiet in a place nobody was looking, and
// its one moving mark failed the 3:1 non-text floor for part of its cycle in dark mode and
// for ALL of it in light (`.tl-pulse`; the arithmetic is beside the fix in style.css).
//
// THE RULE THIS BAND IS BUILT ON: EVERY MOVING THING IN IT IS A FACT
// =================================================================
// The clock moves because time passes. The mark flashes because a signal arrived. Nothing
// loops on a timer pretending to be work — a spinner that keeps spinning after the process
// dies is precisely the lie that produced the report above, and this band is incapable of
// it: with no events arriving the mark goes STILL and the band starts counting the silence
// out loud.
//
// Three inputs, all observed rather than inferred:
//
//   1. `status` and `startedAt`, from `rich://turn-status` — which the spine emits from the
//      ledger's own transitions and reads back OUT of the ledger before emitting
//      (`spine.rs` `turn_status_event`), so the wire cannot report a span the ledger does
//      not hold.
//   2. THE LAST SIGNAL and its wall-clock instant. A "signal" is any §13 event the TIMELINE
//      ITSELF ACCEPTED for the thread on screen — the fence has already refused everything
//      else, so this can never count another thread's traffic as this turn's progress.
//   3. What that signal WAS. An activity row contributes the backend's own `summary`,
//      relayed verbatim and never composed here. Text contributes the fact that text is
//      arriving, and nothing beyond it.
//
// NO PERCENTAGE, NO STEP COUNT, NO ESTIMATE, NO INVENTED STEP NAME. There is no source for
// any of them — `docs/verification/acp-emission-probe-2026-08-28.md` §4-5 records the
// complete union of what the adapter emits, and nothing in it says how much of a turn is
// done. When the app does not know what is happening it says how long it has been waiting,
// which is true.
//
// THE LONGEST SILENCE HAS A NAME NOW, AND IT IS STILL INPUT 3
// ==========================================================
// A second cause of the report was measured on 2026-09-06: the child pauses mid-turn to
// compact its own context, for 38.1 to 62.0 seconds (16 boundaries), and the calm surface was
// told nothing at all — every `system` frame fell to `Visibility::Technical`. It is now an
// ordinary CEO activity row, authored in Rust and relayed here VERBATIM like every other one:
// *"Making room to keep going"* while it runs, *"Made room to keep going"* when it ends
// (`timeline.rs` `semantic_summary`, `docs/verification/compaction-notice-2026-09-06/`).
//
// Nothing in this file knows what a compaction is, and that is the point — the sentence
// arrives on `rich://activity-upserted` with a state and an instant, exactly as "Read the Q3
// board pack" does, so the rule above still holds without an exception written into it. It
// is named from the frame that ANNOUNCES it (`system/status: "compacting"`, 13ms into the
// turn) and never from the length of a silence.
//
// WHY THIS MANY SECONDS, AND WHERE THE NUMBER COMES FROM
// ======================================================
// `QUIET_AFTER_MS` is where the band stops describing the last thing it saw and starts
// naming the silence. Derived from the five committed real `claude-agent-acp` runs in
// `docs/verification/acp-emission-probe-2026-08-28/run{1..5}.raw.jsonl`, which carry an
// `atMs` on every inbound message. Gaps between consecutive inbound messages during the
// prompt phase, plus each run's `session/prompt` -> first-inbound gap, n=192:
//
//     p50 62ms   p90 894ms   p95 1119ms   p99 7090ms   max 20741ms
//     over 5s: 4     over 10s: 1     over 20s: 1
//
// A HEALTHY turn has therefore gone 20.7s with nothing observable arriving, and a threshold
// under that would call working quiet. It is a PRESENTATION threshold only: "Nothing new for
// 41s" is true at every value this constant could take, so no number here can make the band
// say something false — only something differently emphasized.
//
// Re-derive: `node docs/verification/waiting-state-2026-09-06/gaps.js`.
//
// RAISED 25000 -> 35000 ON 2026-09-06, AND THE SAMPLE ABOVE IS WHY IT HAD TO BE
// ============================================================================
// Those five runs are ACP-adapter runs of ordinary turns. They contain no compaction and no
// long tool call, so they could not see the one thing that decides this number: **the native
// wire has a 30-SECOND HEARTBEAT, and it has two of them.**
//
//   * `tool_progress`, while a tool call runs. Re-derived from the committed timings rather
//     than read off a comment (`docs/verification/native-claude-tool-status-2026-08-31/raw/`,
//     `*.timings.tsv`): run13 fires at 35.443s and 65.445s -> 30.002s; run16 at 32.962s and
//     62.963s -> 30.001s.
//   * `system/status: "compacting"`, while the child compacts its own context. Measured
//     2026-09-06 (`docs/verification/compaction-notice-2026-09-06/`): turn 3 at 5190ms and
//     35190ms, turn 4 at 52086ms and 82086ms — 30000ms exactly, twice.
//
// Both reach this band as accepted signals, so at 25000ms a perfectly healthy compaction or
// long tool call spent 5 seconds of every 30 in the ATTENTION tone saying "Nothing new for
// 25s", then snapped back when the heartbeat landed — an alarm twice a minute for work that
// was going fine, which is the same class of lie as a spinner that keeps spinning.
//
//     max known heartbeat interval 30002ms  ->  35000ms clears it by 4998ms (1.17x).
//     The previous pair was 20741ms -> 25000ms (4259ms, 1.21x), so the margin is the one
//     this band was already built with.
//
// WHAT IT COSTS, stated rather than buried: a genuinely hung turn is named 10 seconds later
// than before. It is named — the count is the same count and it never stops being true — and
// the elapsed clock beside the headline was ticking the whole time.
// ---------------------------------------------------------------------------------------

const QUIET_AFTER_MS = 35000;

// ---------------------------------------------------------------------------------------
// THE PACED BAR — a bar over a wait whose length nobody knows, and why it is not a lie
//
// The CEO asked, 2026-09-06, whether the compaction row could show a bar like the splash
// screen's. He was told a bar would have to fabricate progress, because the duration is
// unknown. He rejected that and specified the design himself:
//
//   *"It doesn't need to know. It just needs to move to almost full with the expected minimum
//    time and then stay at 'almost full' until all finished etc."*
//
// He is right, and the reason is worth stating because it is the whole honesty of the thing:
// THE BAR NEVER CLAIMS A COMPLETION IT DOES NOT HAVE. It climbs over the SHORTEST wait of its
// kind ever measured and then it stops. Reaching almost-full and holding is itself a true
// signal — this one is taking longer than the fastest case — where a bar that stalls mid-way
// looks broken and a bar that completes early lies.
//
// NOTHING IN THIS FILE KNOWS WHAT A COMPACTION IS, and that stays true. An activity row may
// arrive carrying `measuredMinMs`, the shortest wait of its kind ever measured
// (`machinery.rs` `COMPACTION_MEASURED_MIN_MS` = 38138 ms, re-derived there from 16 committed
// `compact_boundary` frames). A row that carries one gets a bar; a row that does not, does
// not. The band pieces together three observed things and invents none of them:
//
//   * WHERE IT STARTED — the row's own `startedAt`, which is the LEDGER's instant for the
//     frame that announced the wait, not this window's. So a bar drawn on a compaction the
//     window joined late is drawn where it truly is.
//   * HOW FAST — `measuredMinMs`, a measured span, used as a RATE and never shown.
//   * WHEN IT ENDED — the row's own `completed`/`failed` state, off the wire. Never a timer,
//     never an inference from the clock running out.
//
// THE THREE THINGS IT REFUSES TO DO
// =================================
//   1. IT NEVER COMPLETES ON TIME PASSING. At `measuredMinMs` it stops at PACE_ALMOST and
//      holds, still, for as long as the wait lasts — 24 more seconds at the longest boundary
//      ever measured (62029 ms). Only a frame off the wire fills it.
//   2. IT NEVER OUTLIVES WHAT IT IS PACING. The bar is drawn only while the band is
//      DESCRIBING that row: the instant another signal takes over the sentence, or the band
//      goes quiet (QUIET_AFTER_MS with nothing arriving — a child that dies mid-compaction),
//      the bar goes with the description. `compaction-notice.js` fixed the truth for the
//      sentence; the bar obeys that one rather than a second one of its own. A bar left
//      sitting at almost-full over a dead child would be exactly the spinner-that-keeps-
//      spinning this whole band exists to remove.
//   3. IT NEVER PUBLISHES A NUMBER. No percentage, no countdown, no `aria-valuenow` — the
//      element is `aria-hidden`, like the mark. A `role="progressbar"` owes a value, and any
//      value it could carry would be a proportion of a span that is not this wait's.
//
// THE CURVE is the splash bar's, because the CEO named the splash bar: mostly linear with one
// gentle surge early that fades out (`splash.js` BAR_SURGE = 0.12), and deliberately NOT an
// ease-out, since the classic "stuck at 95%" feeling IS an ease-out. What was NOT borrowed is
// the mechanism: the splash bar knows its own hold and lands at 100% exactly when the curtain
// lifts. This one does not know when it ends, which is the entire problem, and is why it
// holds instead of landing.
// ---------------------------------------------------------------------------------------

/// WHERE THE BAR STOPS AND WAITS. 0.92 of a 604px-wide bar at the band's capped reading width
/// (680px, less 28px of padding each side, less the 10px mark and its 10px gap) leaves
/// 604 x 0.08 = 48.3px of empty track — a gap the eye reads as "not finished" across the
/// room, where 0.95 leaves 30px and starts to read as a rounding error.
const PACE_ALMOST = 0.92;

/// The splash bar's early surge, verbatim (`splash.js` BAR_SURGE). `u + 0.12 sin(2 pi u)(1-u)`
/// is monotonic on [0,1] and is exactly 0 and 1 at the ends, so the bar never stalls, never
/// goes backwards, and arrives at PACE_ALMOST exactly at `measuredMinMs`.
const PACE_SURGE = 0.12;

/// ONE BAR-LENGTH OF CATCH-UP, in ms — the case the CEO did not name, and the one that decides
/// whether this is honest: a wait that ends FASTER than the shortest ever measured.
///
/// The bar is then somewhere short of almost-full and the ending is a fact. Snapping from a
/// third to full is the jump that makes a person distrust every bar they meet afterwards, so
/// the paint CATCHES UP at a fixed speed of one bar-length per 700ms — bounded below by
/// PACE_LAND_MIN_MS, and never longer than the wait it is drawing (see `paceLandingMs`).
///
/// The SPEED is fixed rather than the duration, so how far it had to come is legible in how
/// long the sweep takes. It is 59x the climbing rate (one bar-length per ~41s) and does not
/// pretend to be work: the work is already over, and this is the paint arriving after it.
const PACE_LAND_FULL_MS = 700;

/// The floor on that catch-up. 180ms is the settle transition's own duration, inside §17.4's
/// allowed 150–220ms band; below it a movement stops being read as a movement and becomes a
/// jump. It is what the ordinary case gets — from PACE_ALMOST there are only 8 points to
/// travel, which at full speed would be 56ms.
const PACE_LAND_MIN_MS = 180;

/// The splash strike's easing, so the landing belongs to the same family as the screen the
/// CEO pointed at (`splash.css` `splash-strike-fill`).
const PACE_LAND_EASE = "cubic-bezier(0.25, 0.6, 0.35, 1)";

/// THE BAND'S REPAINT INTERVAL, and the climbing bar's transition duration, which have to be
/// THE SAME NUMBER or the interpolation is wrong: each repaint asks the bar to travel to the
/// position it will hold when the next repaint arrives, so a transition shorter than the tick
/// stops early and one longer than it never gets there. It was written twice before it was
/// named once, which is the kind of pair that drifts.
const WAIT_TICK_MS = 1000;

/// The id of the span whose position was last PAINTED, so the first paint of a span can land
/// at its true position with no transition. Without it, a bar on a compaction this window
/// joined 20s late would sweep up from zero — animating through positions it was never at.
let pacePaintedId = null;

/// One record for the live turn of the thread ON SCREEN. Cleared at the turn's terminal
/// status, so nothing here outlives the turn it describes.
///
///   startedAt   the LEDGER's, via `rich://turn-status`. Null while `queued`.
///   acceptedAt  when this window first saw the turn. The only clock available while
///               `startedAt` is null, and the copy says whose clock it is.
///   lastAt      the instant of the last accepted signal — or of the moment this window
///               started watching, on a turn it joined late.
///   lastWhat    a description of that signal, or null. An activity row's is the BACKEND's,
///               verbatim.
///   signals     accepted signals observed for this turn. Zero is a real state, not a gap.
///   fromStart   false when the CEO opened a thread whose turn was already running, so the
///               band never says "nothing has come back yet" about work it simply did not
///               watch.
let waitTurn = null;
// Evidence belongs to the turn, including while its thread is off screen.
const waitHistory = new Map();
let waitBandEl = null;
let waitTimer = null;
let waitLastPaintAt = 0;
/// One announcement per quiet stretch. §18 forbids announcing a ticking timer; this is a
/// single state change, said once.
// The acknowledgement lives on each wait record, so reloading cannot announce it again.

/// Record a signal against the live turn. Called ONLY where the timeline ACCEPTED the event
/// (`!r.rejected`) — the fence has already decided whether the payload belongs to the
/// thread on screen and this never second-guesses it.
function noteTurnSignal(turnId, what) {
  if (!waitTurn || waitTurn.turnId !== turnId) return;
  const now = Date.now();
  // Whether the SENTENCE is about to change, decided before the value is overwritten.
  const described = !!what && what !== waitTurn.lastWhat;
  waitTurn.lastAt = now;
  waitTurn.signals += 1;
  if (what) {
    waitTurn.lastWhat = what;
    waitTurn.whatAt = now;
  }
  // THE BAR CANNOT OUTLIVE THE SENTENCE IT PACES. The moment a different signal takes over
  // the description, whatever the bar was drawing is no longer what the band is talking
  // about, so it goes. A signal that carries no description (a worker row, arriving text)
  // leaves the sentence alone and therefore leaves the bar alone. `notePacedActivity` runs
  // FIRST on an activity row and has already refreshed `summary` for the row's own ending,
  // so "Making room" -> "Made room" is a continuation and not a replacement.
  if (what && waitTurn.pace && what !== waitTurn.pace.summary) waitTurn.pace = null;
  if (waitTurn) waitTurn.quietAnnounced = false;
  flashWaitMark();
  // A streaming reply delivers a delta every few tens of milliseconds (measured p50 62ms,
  // above), so the ticker owns the once-a-second repaint and this forces only the frames
  // where the sentence actually changes: the first signal, a new description, or leaving
  // the quiet state. Without the `described` clause the band went on showing the previous
  // activity for up to a second after Rich had started writing.
  if (waitTurn.signals === 1 || described || now - waitLastPaintAt > 400) renderWaitBand();
}

/// Take the pace off an activity row, or drop the one being drawn.
///
/// Called for EVERY activity row and before `noteTurnSignal`, so the band repaints once with
/// both the new sentence and the bar that belongs to it.
///
/// A row without a `measuredMinMs` is not paceable and takes the bar down with it — it is
/// about to replace the sentence anyway. A row WITH one either opens a new span or continues
/// the one already being drawn, and the two are told apart by the row's id, which is stable
/// across a whole compaction (`machinery.rs` `merge_into` keeps the OPENING record's
/// `machinery_id`, which is what makes the announcement, its 30-second heartbeats and its
/// ending one row rather than four).
function notePacedActivity(p) {
  if (!waitTurn || waitTurn.turnId !== p.turnId) return;
  const minMs = typeof p.measuredMinMs === "number" && p.measuredMinMs > 0 ? p.measuredMinMs : null;
  const startedAt = typeof p.startedAt === "number" ? p.startedAt : null;
  const summary = typeof p.summary === "string" && p.summary.trim() ? p.summary.trim() : null;
  if (!minMs || !startedAt || !p.id || !summary) {
    waitTurn.pace = null;
    return;
  }
  // The wire's word for "the wait is over", and the ONLY thing that fills the bar. Both
  // endings count: `timeline.rs` gives the CEO one `completed` state for a compaction that
  // succeeded and one that was abandoned, because what ended is the PAUSE, and the two are
  // told apart in the sentence rather than in the state.
  const ended = p.state === "completed" || p.state === "failed";
  const pace = waitTurn.pace && waitTurn.pace.id === p.id ? waitTurn.pace : null;
  if (!pace) {
    const opened = { id: p.id, minMs, startedAt, summary, doneAt: null, landMs: PACE_LAND_MIN_MS };
    if (ended) {
      const from = pacePosition(opened, Date.now());
      opened.doneAt = Date.now();
      opened.landMs = paceLandingMs(opened, from);
    }
    waitTurn.pace = opened;
    return;
  }
  pace.summary = summary;
  if (ended && pace.doneAt === null) {
    // Read WHERE IT HAD GOT TO before the ending is recorded, because from here on the
    // position is 1 and the distance still to travel would be unrecoverable.
    const from = pacePosition(pace, Date.now());
    pace.doneAt = Date.now();
    pace.landMs = paceLandingMs(pace, from);
  }
}

/// WHERE THE BAR IS, 0 to 1, as a pure function of two instants and one measured span.
///
/// Before `measuredMinMs` has elapsed it is climbing. After it, it is exactly PACE_ALMOST and
/// stays there — there is no branch that lets time alone carry it past that point. Only
/// `doneAt`, which is a frame off the wire, returns 1.
function pacePosition(pace, nowMs) {
  if (!pace) return null;
  if (pace.doneAt !== null) return 1;
  const u = Math.max(0, Math.min(1, (nowMs - pace.startedAt) / pace.minMs));
  const eased = u + PACE_SURGE * Math.sin(2 * Math.PI * u) * (1 - u);
  return PACE_ALMOST * Math.max(0, Math.min(1, eased));
}

/// How long the catch-up to full may take, from wherever the bar had got to.
///
/// One bar-length per PACE_LAND_FULL_MS, floored at PACE_LAND_MIN_MS so it reads as a
/// movement, and CAPPED AT THE WAIT ITSELF: a catch-up may never take longer than the thing
/// it is drawing. That last clause is what disposes of the abandoned attempt — `cellT1` holds
/// two compactions that ended 1ms after they began (`too_few_groups`, what a 2% threshold
/// override does to a conversation with nothing to summarize), and a 644ms gold sweep over a
/// 1ms event would make a non-wait look like a wait. It gets the 180ms floor instead.
function paceLandingMs(pace, from) {
  const remaining = Math.max(0, 1 - (from || 0));
  const waited = Math.max(0, (pace.doneAt || Date.now()) - pace.startedAt);
  return Math.max(PACE_LAND_MIN_MS, Math.min(remaining * PACE_LAND_FULL_MS, waited));
}

/// The mark's ONE animation, played once per arriving signal and never on a loop. The class
/// is removed, a reflow forced and the class re-added, so consecutive signals each get
/// their own flash instead of being coalesced into one.
function flashWaitMark() {
  if (!waitBandEl) return;
  const mark = waitBandEl.querySelector(".wait-mark");
  if (!mark) return;
  mark.classList.remove("wait-mark--flash");
  void mark.offsetWidth;
  mark.classList.add("wait-mark--flash");
}

/// The band sits at the top of the composer zone rather than in the timeline, for one
/// reason the reproduction made obvious: the duration row scrolls with the conversation, so
/// a CEO who scrolls up to re-read his own question takes the app's only sign of life off
/// the screen with it. This is where his eyes already are — directly over the box he types
/// in — and it is there at every scroll position.
function ensureWaitBand() {
  if (waitBandEl && waitBandEl.isConnected) return waitBandEl;
  const zone = el("composer-zone");
  if (!zone) return null;
  const band = document.createElement("div");
  band.id = "turn-wait";
  band.className = "turn-wait";
  // `role="status"` with `aria-live="off"`, for the same reason `#conversation` carries the
  // pair: the elapsed line rewrites itself every second, and a polite live region wrapped
  // around a ticking clock is what §18's "do not announce every timer tick" forbids. The one
  // thing worth saying aloud — the turn going quiet — is announced once, below.
  band.setAttribute("role", "status");
  band.setAttribute("aria-live", "off");
  // `data-contrast-role="indicator"` puts the mark under the SHIPPING contrast gate
  // (`tests/contrast.js`, which holds every declared indicator to 3:1 in both themes)
  // rather than only under this feature's own suite. The mark is the one non-text thing in
  // the band that carries meaning, and `.tl-pulse` reaching 1.40:1 unnoticed is precisely
  // what happens to an indicator no gate is walking.
  band.innerHTML =
    '<span class="wait-mark" data-contrast-role="indicator" aria-hidden="true"></span>' +
    '<span class="wait-head"></span>' +
    '<span class="wait-time"></span>' +
    '<span class="wait-detail"></span>' +
    // `aria-hidden` and no `role="progressbar"`: see THE PACED BAR above. Both elements are
    // declared indicators so the SHIPPING contrast gate walks them — the track's border
    // carries the bar's extent and the fill carries how far along it is, and an indicator no
    // gate walks is how `.tl-pulse` reached 1.40:1 unnoticed.
    '<span class="wait-pace" data-contrast-role="indicator" aria-hidden="true" hidden>' +
    '<span class="wait-pace-fill" data-contrast-role="indicator"></span>' +
    "</span>";
  zone.insertBefore(band, zone.firstChild);
  waitBandEl = band;
  return band;
}

function removeWaitBand() {
  if (waitBandEl && waitBandEl.isConnected) waitBandEl.remove();
  waitBandEl = null;
}

/// WHAT THE BAND SAYS, as a pure function of what has been observed — separate from the DOM
/// so a suite can assert on the sentence rather than on a picture of it.
///
/// The headlines are the live `rich://turn-status` values and nothing else. There is no
/// "thinking", no "almost done", no phase: `phase` is `unknown` on every message this
/// runtime emits (live.rs, "THE MESSAGE PHASE, STATED LOUDLY"), so a band that named one
/// would be inventing it.
function waitBandCopy(t, nowMs) {
  const quietMs = nowMs - t.lastAt;
  const quiet = quietMs >= QUIET_AFTER_MS;

  let head;
  if (t.status === "queued") head = "Rich has your message";
  else if (t.status === "recovering") head = "Rich is picking this back up";
  else if (t.status === "stopping") head = "Rich is letting go of this turn";
  else head = "Rich is working";

  // The elapsed number is the DURATION ROW'S OWN, straight out of
  // `RichTimeline.durationRow` — one derivation, so the band and the row can never show two
  // different ages for one turn. While `queued` the ledger holds no `started_at` at all, so
  // the only honest clock is the one this window watched, and the headline says whose.
  const modelTurn = timelineModel.turns.get(t.turnId);
  const rowDuration = modelTurn ? window.RichTimeline.durationRow(modelTurn, nowMs).duration : null;
  const time = t.status === "queued" ? window.RichTimeline.formatDuration(nowMs - t.acceptedAt) : rowDuration;
  const gap = window.RichTimeline.formatDuration(quietMs);

  let detail;
  if (quiet) detail = "Nothing new for " + gap;
  else if (t.status === "queued") detail = "Waiting to start";
  else if (t.signals === 0 && t.fromStart) detail = "Nothing has come back yet";
  else if (t.signals === 0) detail = "Nothing new for " + (gap || "a moment");
  else if (t.lastWhat) {
    const age = window.RichTimeline.formatDuration(nowMs - t.whatAt);
    detail = t.lastWhat + (age ? " · " + age + " ago" : "");
  }
  else detail = "Last update " + (gap ? gap + " ago" : "just now");

  // THE BAR IS PART OF THE SENTENCE, not a second opinion beside it. It is drawn only while
  // the band is describing the row it paces and is in the working tone:
  //
  //   * `quiet` — nothing has arrived for QUIET_AFTER_MS. The band has just stopped saying
  //     what it last saw and started naming the silence, which is what a child dying
  //     mid-compaction produces, and the bar stops with the sentence rather than a moment
  //     later. Two missed 30-second heartbeats is not "still making room".
  //   * `stopping` — the CEO asked for this turn to end. Whatever the child is still doing
  //     inside it, pacing it toward a finish is not what he is waiting to see.
  //   * `queued` — nothing has started, so there is nothing to pace.
  const paceable = !quiet && t.status !== "queued" && t.status !== "stopping";
  const pace =
    t.pace && paceable
      ? { id: t.pace.id, done: t.pace.doneAt !== null, position: pacePosition(t.pace, nowMs), landMs: t.pace.landMs }
      : null;

  return {
    head,
    time: time || "",
    detail,
    pace,
    tone: quiet ? "quiet" : t.status === "queued" ? "queued" : "working",
  };
}

/// Paint the bar, or take it off the screen. The ONE writer of the fill's width and of its
/// transition, so what the bar is doing and how it is allowed to move are decided together.
function renderWaitPace(band, copy) {
  const track = band.querySelector(".wait-pace");
  const fill = band.querySelector(".wait-pace-fill");
  if (!track || !fill) return;
  if (!copy.pace) {
    track.hidden = true;
    fill.style.transition = "none";
    fill.style.width = "0%";
    pacePaintedId = null;
    return;
  }
  track.hidden = false;
  const first = pacePaintedId !== copy.pace.id;
  // §18: no motion for anyone who has asked for none. The bar still ADVANCES under reduced
  // motion — it steps once a second with the band's own tick, which is the same evidence
  // arriving at the same rate, just not interpolated. A loading bar that does not move is a
  // broken loading bar (`splash.js` makes the same call for the same reason).
  const still = first || window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Two durations and two easings, ONE expression. While it climbs the tick owns the clock,
  // so the transition is exactly WAIT_TICK_MS of linear interpolation between two true
  // positions — the span the next repaint will replace. When it lands, the catch-up is a
  // measured distance at a fixed speed (`paceLandingMs`) on the splash strike's own easing.
  const ms = copy.pace.done ? Math.round(copy.pace.landMs) : WAIT_TICK_MS;
  fill.style.transition = still ? "none" : "width " + ms + "ms " + (copy.pace.done ? PACE_LAND_EASE : "linear");
  fill.style.width = (copy.pace.position * 100).toFixed(3) + "%";
  pacePaintedId = copy.pace.id;
}

function renderWaitBand() {
  const pending = visiblePendingSend();
  const opening = mainView === "opening" && openingThread;
  if ((!opening && mainView !== "conversation") || (!opening && !waitTurn && !pending)) {
    removeWaitBand();
    return;
  }
  const band = ensureWaitBand();
  if (!band) return;
  waitLastPaintAt = Date.now();
  const pendingMs = pending ? waitLastPaintAt - pending.startedAt : 0;
  const copy = opening ? {
    head: "Opening conversation",
    time: window.RichTimeline.formatDuration(waitLastPaintAt - opening.startedAt) || "",
    detail: opening.stopError || ([...opening.previousModel.turns.values()].some(t => t.live && t.status === "stopping")
      ? "Stopping work in the previous conversation"
      : [...opening.previousModel.turns.values()].some(t => t.live)
      ? "The previous conversation is still working. Press Stop to stop that work."
      : "Waiting for its saved messages"),
    tone: waitLastPaintAt - opening.startedAt >= QUIET_AFTER_MS ? "quiet" : "queued",
    pace: null,
  } : waitTurn ? waitBandCopy(waitTurn, waitLastPaintAt) : {
    head: "Sending your message",
    time: window.RichTimeline.formatDuration(pendingMs) || "",
    detail: "Waiting for Rich to accept it",
    tone: pendingMs >= QUIET_AFTER_MS ? "quiet" : "queued",
    pace: null,
  };
  band.dataset.tone = copy.tone;
  band.querySelector(".wait-head").textContent = copy.head;
  band.querySelector(".wait-time").textContent = copy.time;
  band.querySelector(".wait-detail").textContent = copy.detail;
  renderWaitPace(band, copy);
  if (copy.tone === "quiet" && !(opening || waitTurn || pending).quietAnnounced) {
    (opening || waitTurn || pending).quietAnnounced = true;
    announce(copy.head + ". " + copy.detail + ".");
  }
}

/// Once a second while a turn is live, and dead stopped while the window is hidden — the
/// same rule and the same reason as the timeline's own timer (§6.2: recompute from
/// timestamps on return, never accumulate).
function startOrStopWaitTimer() {
  const active = openingThread || waitTurn || visiblePendingSend();
  if (active && !waitTimer && !document.hidden) {
    waitTimer = window.setInterval(renderWaitBand, WAIT_TICK_MS);
  } else if ((!active || document.hidden) && waitTimer) {
    window.clearInterval(waitTimer);
    waitTimer = null;
  }
}

/// Drive the band from a `rich://turn-status` the timeline accepted.
///
/// A TERMINAL STATUS ENDS IT, and that is the half of this feature the report is really
/// about: the turn's own outcome — the completed duration row, or §21's failure card — is
/// what the CEO reads next, and a band still saying "Rich is working" over a failure card
/// would be the reassurance-after-death this whole change exists to remove.
function syncWaitBand(payload, opts) {
  const live = payload.status === "queued" || payload.status === "working" || payload.status === "recovering";
  if (!live) {
    waitHistory.delete(payload.turnId);
    if (waitTurn && waitTurn.turnId !== payload.turnId) return;
    waitTurn = null;
    startOrStopWaitTimer();
    renderWaitBand();
    return;
  }
  const now = Date.now();
  const restored = opts && opts.joinedLate && waitHistory.get(payload.turnId);
  if (restored) {
    waitTurn = restored;
    waitTurn.status = payload.status;
    if (typeof payload.startedAt === "number") waitTurn.startedAt = payload.startedAt;
  } else if (!waitTurn || waitTurn.turnId !== payload.turnId) {
    waitTurn = {
      turnId: payload.turnId,
      status: payload.status,
      startedAt: typeof payload.startedAt === "number" ? payload.startedAt : null,
      acceptedAt: now,
      lastAt: now,
      lastWhat: null,
      whatAt: now,
      activityAnnouncements: new Set(),
      signals: 0,
      // Nothing is being paced yet, and nothing is carried over from the previous turn — a
      // bar belongs to the row that declared it, and that row belongs to one turn.
      pace: null,
      fromStart: !(opts && opts.joinedLate),
    };
    if (waitTurn) waitTurn.quietAnnounced = false;
  } else {
    // A status TRANSITION is evidence of life and moves the silence clock, but it is not
    // something coming back from Rich — `signals` counts content only, so `queued` ->
    // `working` can never turn "Nothing has come back yet" into a claim that something did.
    waitTurn.status = payload.status;
    if (typeof payload.startedAt === "number") waitTurn.startedAt = payload.startedAt;
    waitTurn.lastAt = now;
    if (waitTurn) waitTurn.quietAnnounced = false;
  }
  waitHistory.set(payload.turnId, waitTurn);
  startOrStopWaitTimer();
  renderWaitBand();
  if (!(opts && opts.joinedLate)) flashWaitMark();
}

/// The CEO's own stop, from `stop_turn`'s durable answer rather than from an event — the
/// same one status `timeline.js` sets from a command return, and for the same reason: the
/// request is fsync'd before the call returns, so "you asked me to stop" is already a fact.
function markWaitStopping(turnId) {
  if (!waitTurn || (turnId && waitTurn.turnId !== turnId)) return;
  waitTurn.status = "stopping";
  waitTurn.lastAt = Date.now();
  if (waitTurn) waitTurn.quietAnnounced = false;
  renderWaitBand();
}

/// A thread switch, or a snapshot reload. The band belongs to the thread on screen, so it is
/// dropped and re-established from the reloaded model — never carried across, which would
/// attribute one thread's work to another. A turn found this way is marked `joinedLate`: the
/// window did not watch its first seconds and must not report on them.
function resetWaitBandForThread() {
  waitTurn = null;
  removeWaitBand();
  for (const [turnId, t] of timelineModel.turns) {
    if (!t.live) continue;
    const hadEvidence = waitHistory.has(turnId);
    syncWaitBand({ turnId, status: t.status, startedAt: t.startedAt }, { joinedLate: true });
    // A snapshot carries the actual latest activity instant. Restoring it must not make
    // a 25-second-old heartbeat look as though it arrived when the window opened.
    const items = [...timelineModel.items.values()].filter((item) =>
      item.turnId === turnId && item.slot === "stream" && item.visibility === "ceo");
    const instant = (item) => item.updatedAt ?? item.at ?? item.completedAt ?? item.createdAt;
    items.sort((a, b) => instant(a) - instant(b));
    const last = items[items.length - 1];
    if (last && typeof instant(last) === "number" && (!hadEvidence || instant(last) > waitTurn.lastAt)) {
      waitTurn.lastAt = instant(last);
      waitTurn.signals = Math.max(1, waitTurn.signals);
      const described = [...items].reverse().find((item) => item.summary || item.kind === "rich_message");
      waitTurn.lastWhat = described ? described.summary || "Writing the reply" : null;
      waitTurn.whatAt = described ? instant(described) : waitTurn.lastAt;
      if (described && described.kind === "activity") notePacedActivity(described);
      else waitTurn.pace = null;
    }
    renderWaitBand();
    return;
  }
  startOrStopWaitTimer();
}

/// The band is a live-turn surface and belongs only to the conversation. Leaving that view
/// (the entity screen, the unbound screen) takes it with it.
function hideWaitBandOffConversation() {
  if (mainView !== "conversation" && mainView !== "opening") removeWaitBand();
  else renderWaitBand();
}

/// READ-ONLY, for the acceptance harness: the sentence the band is showing and the evidence
/// it was derived from. It exposes nothing the DOM does not already carry.
window.__RICHOS_WAIT__ = () =>
  waitTurn
    ? Object.assign({}, waitTurn, {
        copy: waitBandCopy(waitTurn, Date.now()),
        quietAfterMs: QUIET_AFTER_MS,
        // The bar's own constants, so a suite asserts the PROPERTY ("it stops short of full
        // and holds") against the value the product actually runs, instead of retyping it.
        paceAlmost: PACE_ALMOST,
        paceLandFullMs: PACE_LAND_FULL_MS,
        paceLandMinMs: PACE_LAND_MIN_MS,
      })
    : null;

/// A READ-ONLY handle on the timeline model, for the acceptance harness and for anyone
/// debugging a render against a live shell. It exposes nothing the DOM does not already
/// carry — the model IS the CEO view, gated in Rust before it ever reached this file — so
/// it cannot be a leak path. It is a getter, not the object, so nothing can be swapped
/// underneath the renderer through it.
window.__RICHOS_TIMELINE__ = () => timelineModel;

/// RE-READ WHAT DID NOT LOAD. The notice is rendered once, at boot, because that is when a
/// ledger is replayed — there is no second load for it to react to. So a harness driving
/// the not-clean states needs a way to ask for the render again after it has set them, and
/// this is it. It takes no arguments and invents no state: it calls the same command the
/// boot path calls and renders whatever comes back, so a suite can never paint a notice the
/// backend did not produce.
window.__RICHOS_HISTORY_NOTICE__ = () => renderHistoryNotice();

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

  // A user may leave the thread before its acceptance/rejection comes back. Keep the
  // invocation's own model current as well, so a background accepted turn never becomes
  // an "unsent" draft merely because its event was fenced out of the visible thread.
  for (const request of pendingSends.values()) {
    if (request.model === timelineModel || !window.RichTimeline.accepts(request.model, payload)) continue;
    if (!request.turnId && payload.status === "queued" && !payload.supersedesTurnId) {
      request.turnId = payload.turnId;
    }
    if (request.turnId === payload.turnId || request.turnId === payload.supersedesTurnId) {
      window.RichTimeline.onTurnStatus(request.model, payload);
      if (payload.supersedesTurnId) request.turnId = payload.turnId;
      break;
    }
  }
  if (!["queued", "working", "recovering"].includes(payload.status)) waitHistory.delete(payload.turnId);

  if (openingThread && window.RichTimeline.accepts(openingThread.previousModel, payload)) {
    window.RichTimeline.onTurnStatus(openingThread.previousModel, payload);
    if (![...openingThread.previousModel.turns.values()].some(t => t.live)) openingThread.stopError = null;
    syncComposerMode();
    renderWaitBand();
  }
  const pendingId = timelineModel.pendingUser[0];
  const r = window.RichTimeline.onTurnStatus(timelineModel, payload);
  if (r.rejected) return;
  const request = pendingSends.get(pendingId);
  if (request && (payload.status === "queued" || payload.status === "working") &&
      !timelineModel.pendingUser.includes(pendingId)) request.turnId = payload.turnId;
  if (payload.supersedesTurnId) {
    for (const pending of pendingSends.values()) {
      if (pending.turnId === payload.supersedesTurnId) pending.turnId = payload.turnId;
    }
    waitHistory.delete(payload.supersedesTurnId);
  }

  // The waiting state (see THE WAITING STATE above). Placed after the fence, so the band on
  // screen can only ever describe the turn of the thread on screen.
  const previousWaitStatus = waitTurn && waitTurn.status;
  syncWaitBand(payload);
  if (payload.status === "recovering" && previousWaitStatus !== "recovering") {
    announce("Rich is picking this back up.");
  }

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
  if (r.rejected) return;
  // "Writing the reply" is the ONLY thing this event licenses. `phase` is `unknown` on every
  // message this runtime emits, so naming a kind of writing would be inventing one.
  noteTurnSignal(payload.turnId, "Writing the reply");
  if (r.structural) scheduleRender();
});

Bridge.listen("rich://message-delta", ({ payload }) => {
  const r = window.RichTimeline.onMessageDelta(timelineModel, payload);
  if (r.rejected) return;
  noteTurnSignal(payload.turnId, "Writing the reply");
  if (r.structural) scheduleRender();
  else if (r.textOnly) scheduleProse(r.textOnly);
});

Bridge.listen("rich://message-completed", ({ payload }) => {
  const r = window.RichTimeline.onMessageCompleted(timelineModel, payload);
  if (r.rejected) return;
  // A signal with NO new description: this closes one run of prose, and whether more
  // writing follows is not knowable from here, so the band keeps the last thing it could
  // honestly say and only moves its clock.
  noteTurnSignal(payload.turnId, null);
  if (r.structural) scheduleRender();
  else if (r.textOnly) scheduleProse(r.textOnly);
  // §18: "announce meaningful commentary when it completes, not every token." Every run is
  // "meaningful" here because none of them can be told apart — see timeline.js's header.
  if (payload.text) announce(payload.text);
});

Bridge.listen("rich://activity-upserted", ({ payload }) => {
  const r = window.RichTimeline.onActivityUpserted(timelineModel, payload);
  if (r.rejected) return;
  // `summary` is written in Rust (`machinery.rs`) and relayed VERBATIM. Nothing here
  // composes, shortens or interprets it, and an activity row without one contributes its
  // instant only — a signal the band can time but not describe.
  //
  // The pace is read FIRST (see THE PACED BAR) so the single repaint below carries the
  // sentence and the bar that belongs to it together, rather than a bar one frame behind.
  notePacedActivity(payload);
  if (waitTurn && payload.measuredMinMs && payload.summary) {
    const key = JSON.stringify([payload.id, payload.state, payload.summary]);
    if (!waitTurn.activityAnnouncements.has(key)) {
      waitTurn.activityAnnouncements.add(key);
      announce(payload.summary);
    }
  }
  noteTurnSignal(payload.turnId, typeof payload.summary === "string" && payload.summary.trim() ? payload.summary.trim() : null);
  scheduleRender();
});

// §7 — a delegated AI worker, live. Until 2026-08-29 this event was deferred in the emitter
// and had no listener here, so a delegation reached the screen only through a `get_timeline`
// snapshot and read as a nameless "Worked" row for the rest of the turn. The payload is the
// same `worker_activity` item a reload projects, under the same id, so this upsert and the
// snapshot cannot disagree.
Bridge.listen("rich://worker-upserted", ({ payload }) => {
  const r = window.RichTimeline.onWorkerUpserted(timelineModel, payload);
  if (r.rejected) return;
  // Timed, not described. A worker row carries a NAME, and "Sage" on its own says nothing a
  // CEO can use, while any sentence built around it would be composed here rather than
  // observed. The chip below the composer is where a delegation gets its words.
  noteTurnSignal(payload.turnId, null);
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
//           rich://voice-notice     { message, at }   voice WORKS, and chose something for him
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

/// Voice is WORKING, and something about how it is working is worth him knowing — today, that
/// this machine could not carry the more accurate recognizer (`hardware.rs`). Sent once, at
/// voice-mode start, and only when the product has quietly made a choice on his behalf.
///
/// SAME RENDER PATH AS voice-error, DIFFERENT CHANNEL, and the difference is not cosmetic: the
/// handler above is for voice STOPPING, and a degradation is not that. It introduces no new
/// style — `richVoiceSays` adds a local notice, which renders as one of Rich's own messages
/// (`.tl-prose`, `var(--ink)` on `var(--ground)`: 14.55:1 in dark and 14.90:1 in light, both
/// computed, both far above the 4.5:1 floor).
///
/// NOT SUPPRESSED WHEN THE PANEL IS CLOSED, unlike its neighbors. The other three handlers bail
/// on `!voiceMode` because they drive the live panel and a stale one is worse than none. This one
/// is a sentence in the thread explaining a decision that has already been made and will hold for
/// the whole session — dropping it because a panel closed would lose the one thing this work
/// exists to say out loud.
Bridge.listen("rich://voice-notice", ({ payload }) => {
  if (!payload || !payload.message) return;
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
// A TURN THAT DIED SAYS SO OUT LOUD (open-items row 3.30, answer 1).
//
// WAS: `voice_speak_end` + `voice_turn_ended`, the same pair `turn-completed` uses above.
// `speak_end` FLUSHES the sentence chunker's tail, and on a turn that died mid-sentence the
// tail is half a sentence that will never be completed — so Rich spoke half a sentence,
// trailed off, and said nothing else. In voice mode the CEO is listening rather than
// reading, and trailing off is exactly what a person does while thinking, so he waits for
// the rest of an answer that is not coming. That is the row's own words: "the CEO is
// speaking to a system that has stopped listening and does not know it."
//
// `voice_turn_cut_off` drops the fragment, SPEAKS the cut-off notice, and ends the turn —
// all three, in that order (`richos_voice::controller::CutOffDesk`). It replaces BOTH calls
// rather than joining them: `turn_ended` is inside it, because a caller who could forget the
// second half is a caller who will.
//
// `payload.reason` is relayed as it stands. For an upstream failure it is the sentence
// `richos-core`'s `upstream.rs` authored; for anything else it is whatever the backend said.
// Nothing here parses it — one classifier owns that decision and it is not this file.
Bridge.listen("rich://turn-error", ({ payload }) => {
  if (!voiceMode) return;
  Bridge.invoke("voice_turn_cut_off", { reason: (payload && payload.reason) || null }).catch(() => {});
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
  // `openThread` renders it when there was a thread to open. When there was not — which is
  // every launch that resolved no thread — this is the only call that reaches it, and a
  // company he just chose is exactly the company the notice is about.
  await renderFirstRunNotice();
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
  // The first company a first-run user adds is the one this notice exists for, and it is
  // added AFTER boot — so the boot-time read found no binding and said nothing.
  await renderFirstRunNotice();
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
// THE BACKDROP DOES NOT DISMISS THIS ONE, and it is the only overlay in the window that
// refuses to. Every other sheet here closes on a click outside it, which is the right
// default for a search box or a picker: nothing is lost by closing one.
//
// THE DEFECT THIS CLOSES (ray-opus-a2, published v1.0.1, 2026-09-04). This handler read
// `if (e.target === setupSheetEl) closeSetupSheet()`, and `#setup-sheet` IS the full-screen
// backdrop — the panel inside it is `.overlay-panel`. So every pixel around a compact
// centered panel dismissed the ONE step that puts an engine on the machine, and
// `closeSetupSheet` then handed straight off to the memory question. Measured under WebKit
// on both `missing-engine` and `missing-both`: sheet hidden=true, `run_setup` called=false,
// memory question showing=true. The app then looked set up and was not, and every send was
// refused for the rest of that install.
//
// A click that misses "Set it up" by sixty pixels is not consent to skip it. Neither is a
// click aimed at getting a window out of the way — a stranger dismisses dialogs by clicking
// beside them, and this is the first thing he ever sees. There is always a NAMED way out:
// "Not now" when there is something to install, "Close" when there is not, "Close" again
// once the run has finished. The only moment neither is on screen is during the install
// itself, and dismissing mid-download is precisely what must not happen either.
//
// Escape is already inert here — the global handler (further down this file) lists the
// overlays it closes and this sheet is deliberately not among them. `setup.js` case 14 holds
// both halves so neither can be reinstated by accident.
// (No backdrop listener at all. An empty one is a handler a later reader deletes as dead
// code; the absence, with this note above it, is the invariant.)

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

/// WHAT DID NOT LOAD, AND WHY — the read half of `Ledger::history_health`.
///
/// A record written by a NEWER RichOS is one an older build cannot name, and the three
/// published builds (v1.0.0-v1.0.2) are still downloadable with no rollback in the
/// updater. The reader survives such a record now instead of failing the whole history on
/// it, and this is the half that makes surviving it honest: the app says how many records
/// it could not read and why, in the CEO's own words, at the top of the conversation the
/// statement is about.
///
/// EVERY STRING RENDERED HERE IS COMPOSED IN RUST (`Ledger::history_health`). Nothing is
/// assembled from a count on this side, for the same reason `machinery_view.rs` owns its
/// four sentences: "I could not read some of this" and "there was nothing to read" are
/// different statements and a renderer must never be in a position to substitute one for
/// the other.
///
/// `skipped === 0` hides it entirely. There is no reassuring "history loaded cleanly"
/// state and there should not be — a green tick over a check that found nothing to say is
/// the failure mode this whole change exists to avoid, not a smaller version of success.
async function renderHistoryNotice() {
  const box = el("history-notice");
  if (!box) return;
  const health = await invokeQuiet("history_health");
  if (!health || !health.skipped) {
    box.hidden = true;
    return;
  }
  el("history-notice-headline").textContent = health.headline;
  el("history-notice-detail").textContent = health.detail;
  box.hidden = false;
}

// ---------------------------------------------------------------------------------------
// THE FIRST-RUN NOTICE — the visible half of the onboarding offer
// (`onboarding.rs`, `main.rs::onboarding_view`, `docs/plans/richos-first-run-notice-2026-09-06.md`)
//
// THE GAP THIS CLOSES, in the words of the engineer who left it: "The first-run sheet is not
// built. Rich makes the offer in conversation; a CEO who does not read the first reply never
// sees it." Measured (`docs/verification/onboarding-honesty-2026-09-06/`, cell D1), the offer
// arrives inside a REPLY — so it requires him to type something first, and to read what comes
// back. A person who opens RichOS and looks at the screen is told nothing, and what he is
// looking at is an empty conversation.
//
// WHY IT IS NOT A FOURTH FIRST-RUN DIALOG. The design call and its reasoning are in the plan
// above; the short version is that a modal has only two exits, and the third exit — "leave it
// there, I will decide later" — is the honest answer at the one moment he has seen nothing.
//
// IT NEVER CONTRADICTS RICH, because it is not a second opinion. Both this and the priming
// block are derived from `Spine::onboarding_state`, which is derived from the two facts on
// disk. And the two controls each move that state BEFORE Rich's first turn: Start sends the
// acceptance as an ordinary message, so his first turn is the yes; "Not now" records the
// declination, so the next prime carries `DECLINED_BLOCK` and he is not offered again.
// ---------------------------------------------------------------------------------------

/// What is on screen right now, so a press can be answered without asking the backend twice.
/// `null` until the first read. This is NOT a record of whether the notice was shown — it does
/// not survive the launch, nothing reads it to decide anything, and `onboarding.rs`'s module
/// doc bans the durable version of that idea by name.
let firstRunState = null;
let firstRunRead = 0;
let firstRunViewContext = null;
const firstRunActions = new Map();
function firstRunContext() {
  return JSON.stringify([activeThreadId, activeContext && activeContext.entity_id, draftEntityId, mainView]);
}
function firstRunButtons(disabled) {
  el("first-run-start").disabled = disabled;
  el("first-run-later").disabled = disabled;
}

/// THE HEADLINE, and the word it deliberately does not contain is "anything".
///
/// It read "I don't know anything about your business yet." until it was put on screen
/// directly after the company picker, where the CEO has just typed his company's name. RichOS
/// therefore knows exactly one thing about his business, and a headline claiming it knows
/// nothing is a small untruth in the first sentence of the product — which is a strange place
/// to spend the trust this whole surface exists to build. Knowing a name is not knowing a
/// business; the body below enumerates what is actually missing.
const FIRST_RUN_HEADLINE = "I don't know your business yet.";

/// THE OFFER, in the register the rest of the app uses: what is missing, what it would take,
/// and what it buys. Every clause is here for a reason and none of them is decoration.
///
///   * "There's nothing on file" — a fact about this install, not a failure of his.
///   * "about twenty minutes" — the same words `OFFER_BLOCK` gives Rich, so the screen and
///     the conversation quote one number.
///   * "write your answers down, so I use them from then on" — the whole and only promise.
///     It deliberately says NOTHING about the home screen: what is there is a worked example,
///     his own corpus compiles to zero on a new install, and any copy implying "answer these
///     and watch your company appear" is a lie the product cannot cover.
///   * "You can stop partway, and 'not sure yet' is a real answer" — said before he can
///     wonder. Alone, nobody is there to tell him deferral is honest, and an unanswered
///     question otherwise reads as a failure to answer.
///
/// IT SURVIVES BEING SPOKEN. "I" is Rich throughout and "you" is the CEO throughout; the
/// pronouns never trade places, which is the one thing that breaks when copy written for a
/// screen is read aloud.
const FIRST_RUN_BODY =
  "There's nothing on file about what this company does, who it's for, or how you want to " +
  "work. I can ask you about it — about twenty minutes — and write your answers down, so I " +
  "use them from then on. You can stop partway, and \"not sure yet\" is a real answer to any " +
  "of it.";

/// WHAT THE SECOND BUTTON DOES, stated beside the button rather than crammed into its label.
/// The write is durable and it stops Rich offering, which "Not now" cannot carry in two
/// syllables and stay speakable. Both halves are here because either alone is misleading:
/// the first without the second reads as a permanent door closing, and the second without the
/// first reads as a button that does nothing.
const FIRST_RUN_CONSEQUENCE =
  '"Not now" means I\'ll stop offering. You can start it any time by asking.';

/// THE RECEIPT, and it is deliberately not a celebration. He pressed a button that wrote
/// something down; a panel that simply vanished would leave him no way to know whether it
/// did. It names the way back in the same breath, and it is gone at the next launch — the
/// state is `declined` by then, so nothing renders.
const FIRST_RUN_DECLINED_RECEIPT =
  "Left with you. Ask me any time and we'll go through it.";

/// THE ACCEPTANCE, sent as an ordinary message on the ordinary path.
///
/// It goes through `send()` — the same function the composer uses — so the turn in the record
/// is a message the CEO sent, because he did send it: he pressed a button that says exactly
/// this. Nothing here talks to the interview directly. `OFFER_BLOCK` already tells Rich what
/// to do when the answer is yes, and a second, private route into the same skill would be a
/// second thing to keep in step with it.
const FIRST_RUN_ACCEPT_MESSAGE = "Let's do the twenty minutes of questions about my business.";
const FIRST_RUN_RESUME_MESSAGE = "Let's pick up the questions about my business where we stopped.";
const FIRST_RUN_PARTIAL_HEADLINE = "Your business notes are started.";
const FIRST_RUN_PARTIAL_BODY = "Your saved answers are kept. We can pick up the remaining questions where we stopped. Press Resume the questions when you're ready.";

/// Read where onboarding stands and paint it — or paint nothing, which is the answer in three
/// of the five states.
///
/// `described` and `no-central-folder` render nothing, for different reasons that are worth
/// keeping apart. `described` is the finished state. `no-central-folder` is "nothing has
/// looked" — there is nowhere for his answers to go yet, and offering to write down twenty
/// minutes of answers that have no home is the one thing this notice must never do. The
/// memory question earlier in the first-run chain is the surface that owns that condition.
async function renderFirstRunNotice() {
  const box = el("first-run");
  if (!box) return;
  const context = firstRunContext();
  const ticket = ++firstRunRead;
  const view = await invokeQuiet("onboarding_view");
  if (ticket !== firstRunRead || context !== firstRunContext()) return;
  const entityId = draftEntityId || activeContext && activeContext.entity_id;
  if (view && view.entityId && entityId && view.entityId !== entityId) {
    box.hidden = true;
    return;
  }
  firstRunState = view || null;
  firstRunViewContext = context;
  const pending = view && firstRunActions.get(view.entityId);
  if (pending) {
    firstRunButtons(true);
    if (pending.kind === "start") box.hidden = true;
    return;
  }
  firstRunButtons(false);
  const state = view && view.state;
  if (state !== "not-yet" && state !== "partial" && state !== "unusable") {
    box.hidden = true;
    return;
  }
  box.dataset.state = state;
  el("first-run-error").hidden = true;
  if (state === "unusable") {
    // THE ONE STATE THAT NEEDS A PERSON, and the only one that draws no button — there is
    // nothing here he could press that would fix it, and a control for a thing no control can
    // do teaches him the controls are decorative. BOTH sentences are composed in Rust and
    // rendered as they stand: "I could not read your notes" and "you have no notes" are
    // different statements and this surface is never in a position to substitute one for the
    // other.
    el("first-run-headline").textContent = view.headline || "";
    el("first-run-body").textContent = view.message || "";
    el("first-run-consequence").hidden = true;
    el("first-run-actions").hidden = true;
  } else {
    el("first-run-headline").textContent = state === "partial" ? FIRST_RUN_PARTIAL_HEADLINE : FIRST_RUN_HEADLINE;
    el("first-run-body").textContent = state === "partial" ? FIRST_RUN_PARTIAL_BODY : FIRST_RUN_BODY;
    el("first-run-start").textContent = state === "partial" ? "Resume the questions" : "Start the questions";
    el("first-run-consequence").textContent = FIRST_RUN_CONSEQUENCE;
    el("first-run-consequence").hidden = false;
    el("first-run-actions").hidden = false;
  }
  box.hidden = false;
}

/// HE ACCEPTS. The notice closes because the conversation now carries the question, and a
/// panel offering what is already happening is clutter.
async function startFirstRunInterview() {
  const view = firstRunState;
  if (!view || !view.entityId || firstRunViewContext !== firstRunContext() || firstRunActions.has(view.entityId)) return;
  const action = { kind: "start", context: firstRunContext() };
  firstRunActions.set(view.entityId, action);
  ++firstRunRead; // a read begun before this press cannot re-open the offer
  firstRunButtons(true);
  el("first-run").hidden = true;
  inputEl.focus();
  try {
    await send(view.state === "partial" ? FIRST_RUN_RESUME_MESSAGE : FIRST_RUN_ACCEPT_MESSAGE);
  } finally {
    firstRunActions.delete(view.entityId);
    if (action.context === firstRunContext()) firstRunButtons(false);
  }
}

/// HE SAYS NOT NOW. The write happens FIRST and the panel only changes if it succeeded.
///
/// A refusal keeps the notice open and says so. Closing it on a failed write would put him
/// back in the offered-forever state behind a screen that told him he had settled it, which
/// is the shape of failure this whole line of work exists to remove — reporting success over
/// work that did not happen.
async function declineFirstRunInterview() {
  const view = firstRunState;
  if (!view || !view.entityId || firstRunViewContext !== firstRunContext() || firstRunActions.has(view.entityId)) return;
  const action = { kind: "decline", context: firstRunContext() };
  firstRunActions.set(view.entityId, action);
  ++firstRunRead;
  firstRunButtons(true);
  const err = el("first-run-error");
  err.hidden = true;
  try {
    const answer = await Bridge.invoke("decline_onboarding", { entityId: view.entityId });
    if (action.context !== firstRunContext()) return;
    firstRunState = answer;
    el("first-run").dataset.state = "declined";
    el("first-run-headline").textContent = FIRST_RUN_DECLINED_RECEIPT;
    el("first-run-body").textContent = "";
    el("first-run-consequence").hidden = true;
    el("first-run-actions").hidden = true;
    inputEl.focus();
  } catch (e) {
    if (action.context !== firstRunContext()) return;
    err.textContent = String(e);
    err.hidden = false;
  } finally {
    firstRunActions.delete(view.entityId);
    if (action.context === firstRunContext()) firstRunButtons(false);
  }
}

el("first-run-start").addEventListener("click", startFirstRunInterview);
el("first-run-later").addEventListener("click", declineFirstRunInterview);

/// RE-READ WHERE ONBOARDING STANDS. Same contract as `__RICHOS_HISTORY_NOTICE__`: no
/// arguments, no invented state, calls the same command the boot path calls and paints
/// whatever comes back — so a suite can never put a notice on screen the backend did not
/// produce.
window.__RICHOS_FIRST_RUN__ = () => renderFirstRunNotice();

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
  // WHETHER ANY OF HIS HISTORY DID NOT LOAD. Read before the conversation is opened, so
  // the sentence explaining why part of it is missing is on screen with the part that
  // survived, rather than arriving after he has already read what is there.
  await renderHistoryNotice();
  // WHERE ONBOARDING STANDS, read at the same moment and for the same reason: it is a
  // statement about the conversation below it, so it is on screen with what it is about
  // rather than arriving after he has already read what is there. It paints nothing until a
  // company is bound, which on a true first run is after the picker is answered — and
  // `chooseCompany`/`addCompany` call it again there.
  await renderFirstRunNotice();
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

  // HAS HE ALREADY CHOSEN? Read synchronously, right here — see the block over `navTicket` for
  // the measurement this comes from.
  //
  // The first and third arms below are decisions about WHERE TO LAND, and a decision about
  // where to land is void once he has landed somewhere himself. The second arm is not: "which
  // company is this copy of RichOS for" is a question about what happens when he TYPES, and it
  // has to be asked whatever is on screen — skipping it would hand him an armed composer over
  // a company he never chose, which is the §21 leak that gate exists for. So it still runs, and
  // it is the same question he would have been asked had he pressed the row a second later.
  const chose = handNavigations > 0;
  const active = chose ? null : activeContext ? activeContext.thread_id : await invokeQuiet("active_thread");
  if (active && threadRow(active)) {
    // `restore: true` — see `openThread`. It carries the same rule a second time, on purpose.
    await openThread(active, { restore: true });
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
  } else if (!chose && navTree.groups.length) {
    // No active context — the launch could not resolve an entity (the shell fails closed
    // rather than guessing one), or every thread on disk is unbound.
    //
    // `!chose`: this arm's whole premise is "there is nothing on screen, so ask". Once he has
    // opened a thread himself the premise is false, and a picker over his own conversation is
    // the same override as the wrong thread was.
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
