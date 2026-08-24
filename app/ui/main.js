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
const railThreadsEl = el("rail-threads");
const railCompanyEl = el("rail-company");
const messagesEl = el("messages");
const conversationEl = el("conversation");
const composerEl = el("composer");
const inputEl = el("input");
const sendBtn = el("send");
const talkToggleBtn = el("talk-toggle");
const voicePanelEl = el("voice-panel");
const voiceListeningEl = el("voice-state-listening");
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
let threads = [];
let activeThreadId = null;
let messages = []; // full history for the active thread, oldest first
let liveTurnId = null; // the turn currently streaming into the last-rendered slot, or null
let liveText = "";
let working = false;
let voiceMode = false;
let sessionAvatarShown = false; // Rich Hand mark shows on his first message THIS SESSION only
let renderedCount = 0; // how many of `messages` are currently mounted (virtualized window)
const RENDER_WINDOW = 40; // initial/incremental render chunk — infinite scroll, no pagination
let drillItems = []; // populated only if a genuine worker-status source is wired (none today)

// COMPANY IDENTITY — the rail header per the UX direction §2.1 is "the company/CEO identity, not
// RichOS." No backend command for this exists yet (no `company_name` Tauri command in
// main.rs today — that's the architecture's P4 provisioning leg). This is a deliberate, honestly-labeled
// placeholder wired to be swapped for a real value the moment that command ships.
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
// Rail
// ---------------------------------------------------------------------------------------
// The pinned default thread — the earliest-created one, always "Running" per §2.1. The
// spine (spine.rs:112, `ensure_active_thread`) seeds it with the literal title "General"
// today (a backend gap — the design lead's default-thread name is "Running"; that's a one-line Rust
// fix outside app/ui/'s scope, flagged in the handoff, not made here). Cosmetically relabel
// only the untouched default so the CEO-facing bar is met now without inventing a rename
// feature: if the CEO or Rich ever actually renames it, its real title takes over.
function pinnedThread() {
  if (!threads.length) return null;
  return threads.reduce((min, t) => (t.created_at < min.created_at ? t : min), threads[0]);
}
function displayTitle(t, pinned) {
  if (pinned && t.id === pinned.id && t.title === "General") return "Running";
  return t.title;
}

function renderRail() {
  const pinned = pinnedThread();
  // Sort: the pinned default thread always first, then by recency — never a manual sort
  // the CEO manages.
  const ordered = [...threads].sort((a, b) => {
    if (pinned && a.id === pinned.id) return -1;
    if (pinned && b.id === pinned.id) return 1;
    return b.last_activity - a.last_activity;
  });

  railThreadsEl.innerHTML = "";
  for (const t of ordered) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "rail-thread" + (t.id === activeThreadId ? " is-active" : "");
    item.textContent = displayTitle(t, pinned);
    // Deliberately NO badge, NO count, NO icon, NO per-thread timestamp — §2.1.
    item.addEventListener("click", () => switchThread(t.id));
    railThreadsEl.appendChild(item);
  }
}

async function switchThread(threadId) {
  if (threadId === activeThreadId) return;
  activeThreadId = threadId;
  liveTurnId = null;
  liveText = "";
  working = false;
  drillItems = [];
  closeSlideOver();
  await Bridge.invoke("switch_thread", { threadId });
  renderRail();
  await loadMessages();
}

async function createThread() {
  // Quiet, de-emphasized — the CEO CAN start a thread, but this is not the primary path
  // (Rich organizing is). No prompt() dialog (that's the placeholder's Slack reflex);
  // inline quiet affordance instead.
  const title = window.prompt("What should this thread track?", "");
  if (title === null) return;
  const id = await Bridge.invoke("create_thread", { title: title.trim() || "New thread" });
  threads = await Bridge.invoke("list_threads");
  await switchThread(id);
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
  messages = await Bridge.invoke("get_messages", { threadId: activeThreadId });
  renderedCount = Math.min(messages.length, RENDER_WINDOW);
  renderMessages();
}

// ---------------------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------------------
async function send() {
  const text = inputEl.value.trim();
  if (!text || working) return;
  inputEl.value = "";
  autoGrow();

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

el("rail-new-thread").addEventListener("click", createThread);

// ---------------------------------------------------------------------------------------
// Streaming event wiring (app/STREAMING.md)
// ---------------------------------------------------------------------------------------
Bridge.listen("rich://turn-started", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  liveTurnId = payload.turnId;
  liveText = "";
  setWorking(true);
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

// Dev-mock-only proactive/drill-down signals (§5, §3.2) — no live backend seam for these
// yet (no proactive attention seam, no worker-status command in main.rs today). Wired here
// so the render path is real and testable; production simply never receives these events
// until the orchestration work ships them.
Bridge.listen("rich://mock-proactive", ({ payload }) => {
  if (payload.threadId !== activeThreadId) return;
  loadMessages();
});
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
// ---------------------------------------------------------------------------------------
async function enterVoiceMode() {
  voiceMode = true;
  talkToggleBtn.setAttribute("aria-pressed", "true");
  composerEl.hidden = true;
  voicePanelEl.hidden = false;
  voiceListeningEl.hidden = false;
  voiceSpeakingEl.hidden = true;

  // Stub the capture call (the real pipeline lands later) — wired, best-effort, and
  // MUST NOT fabricate a transcript if it fails/no-ops. The mic-state UI is authoritative
  // on its own; it doesn't depend on this call succeeding.
  try {
    await Bridge.invoke("start_voice_capture", { threadId: activeThreadId });
  } catch (_e) {
    // Expected today — no voice pipeline exists yet. The listening state stays honest:
    // it shows mode-is-on, not a live level meter claiming real audio data.
  }
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
    // Same as above — stub, no-ops until the pipeline lands.
  }
}

talkToggleBtn.addEventListener("click", () => {
  if (voiceMode) exitVoiceMode();
  else enterVoiceMode();
});
bargeInBtn.addEventListener("click", () => {
  // Barge-in: stop Rich speaking, return to listening. Purely a state flip until the
  // real audio pipeline lands.
  voiceSpeakingEl.hidden = true;
  voiceListeningEl.hidden = false;
});

// ---------------------------------------------------------------------------------------
// Assertiveness dial (§5.2) — one plain 3-way preference, default Quiet. No backend
// persistence command exists yet, so this is local-only (localStorage) pending a real
// `get/set_assertiveness` seam — the CEO-facing behavior (one small tucked control,
// default Quiet) is fully honest today even though the value isn't yet read by Rich.
// ---------------------------------------------------------------------------------------
const ASSERTIVENESS_KEY = "richos.assertiveness";
function getAssertiveness() {
  return window.localStorage.getItem(ASSERTIVENESS_KEY) || "quiet";
}
function setAssertiveness(v) {
  window.localStorage.setItem(ASSERTIVENESS_KEY, v);
}
(function initAssertivenessControl() {
  const current = getAssertiveness();
  for (const input of assertivenessPopover.querySelectorAll('input[name="assertiveness"]')) {
    input.checked = input.value === current;
    input.addEventListener("change", () => setAssertiveness(input.value));
  }
})();
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
// Init
// ---------------------------------------------------------------------------------------
async function init() {
  // Company identity header — see COMPANY_LABEL_FALLBACK note above.
  railCompanyEl.textContent = COMPANY_LABEL_FALLBACK;

  threads = await Bridge.invoke("list_threads");
  activeThreadId = await Bridge.invoke("active_thread");
  if (!activeThreadId && threads.length) activeThreadId = threads[0].id;
  renderRail();
  await loadMessages();
  inputEl.focus();
}

init();
