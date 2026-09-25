"use strict";
// Desktop-only technical settings. Values come from the Claude control reader.
(function () {
  const bridge = window.RichBridge;
  const sheet = document.createElement("div");
  sheet.id = "quota-sheet";
  sheet.className = "overlay";
  sheet.hidden = true;
  sheet.setAttribute("role", "dialog");
  sheet.setAttribute("aria-modal", "true");
  sheet.setAttribute("aria-labelledby", "quota-title");
  sheet.setAttribute("data-dismiss", "control:#quota-close");
  sheet.innerHTML = `<section class="overlay-panel quota-panel">
    <div class="quota-heading"><div><p class="quota-eyebrow">Advanced settings</p>
      <h2 id="quota-title" class="overlay-title">Claude Code quota</h2></div>
      <button id="quota-close" class="desk-btn" type="button" aria-label="Close Claude Code quota">Close</button></div>
    <p class="overlay-note">Your Claude Code subscription allowance, shared across apps and sessions.</p>
    <div class="quota-toolbar"><span id="quota-freshness" class="quota-muted">Loading quota…</span>
      <button id="quota-refresh" class="desk-btn" type="button">Refresh</button></div>
    <p id="quota-message" class="quota-message" role="status" aria-live="polite" hidden></p>
    <div id="quota-windows" aria-label="Claude Code quota windows"></div>
    <p id="quota-empty" class="overlay-note" hidden>No quota windows have been reported.</p>
    <p class="quota-legend">The marker shows time left in the window. A shorter bar means you are using your allowance faster than time is passing.</p>
    <form id="quota-policy" class="quota-policy">
      <h3>Automatic pause and resume</h3>
      <label class="quota-toggle"><input id="quota-enabled" type="checkbox"> Pause background work before the five-hour limit</label>
      <div class="quota-threshold"><label for="quota-threshold">Pause at</label>
        <input id="quota-threshold" type="number" min="1" max="99" step="1" value="93" required>
        <span>% used</span><button id="quota-save" class="desk-btn desk-btn--confirm" type="submit">Save</button></div>
      <p class="quota-muted">Pause at this threshold unless the reset is less than 20 minutes away. Usage can rise between checks. Current tool actions finish safely; subagents wait before their next tool call. Work resumes automatically with its context intact.</p><p class="quota-muted">Checks every 30 minutes below 70% used and every 5 minutes from 70% onwards.</p>
      <p class="quota-muted">Conversation stays available. If a current reading is unavailable, background work waits. Turn this setting off to release the hold.</p>
      <p id="quota-hold-status" class="quota-hold-status"></p>
      <p id="quota-save-status" role="status" aria-live="polite"></p>
    </form>
  </section>`;
  document.body.appendChild(sheet);
  const field = id => sheet.querySelector("#" + id);
  let view = null, busy = false, saving = false, dirty = false, generation = 0, timer = null, lastPoll = 0;
  const duration = millis => {
    const minutes = Math.max(1, Math.ceil(millis / 60000));
    if (minutes >= 1440) return Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
    if (minutes >= 60) return Math.floor(minutes / 60) + "h " + minutes % 60 + "m";
    return minutes + "m";
  };
  function label(tag, className, text) {
    const node = document.createElement(tag); node.className = className; node.textContent = text; return node;
  }
  function render() {
    field("quota-refresh").disabled = busy || !!(view?.retryAt > Date.now());
    field("quota-refresh").textContent = busy ? "Refreshing…" : "Refresh";
    if (!view) return;
    const now = Date.now();
    const stale = view.state !== "fresh" || !view.checkedAt || now - view.checkedAt >= view.refreshIntervalMs;
    const age = view.checkedAt ? (now - view.checkedAt < 60000 ? "just now" : duration(now - view.checkedAt) + " ago") : null;
    field("quota-freshness").textContent = age ? (stale ? "Last reading " : "Updated ") + age + (stale ? " · Stale" : "") : "No current reading";
    field("quota-message").textContent = (view.message || "") + (view.retryAt > now ? " Try again in " + duration(view.retryAt - now) + "." : "");
    field("quota-message").hidden = !field("quota-message").textContent;
    const list = field("quota-windows"); list.replaceChildren();
    for (const window of view.windows || []) {
      const remaining = Math.max(0, Math.min(100, Math.round(100 - window.usedPercent)));
      const expired = !!window.resetsAt && window.resetsAt <= now;
      const row = label("section", "quota-window" + (stale || expired ? " quota-window--stale" : ""), "");
      const summary = label("div", "quota-window-summary", "");
      summary.appendChild(label("h3", "quota-window-label", window.label));
      const value = label("div", "quota-remaining", remaining + "%");
      value.appendChild(label("span", "quota-muted", " left")); summary.appendChild(value);
      summary.appendChild(label("span", "quota-reset", expired ? "Window ended · awaiting refresh" : window.resetsAt ? "Resets in " + duration(window.resetsAt - now) : "Reset time unavailable"));
      row.appendChild(summary);
      const chart = label("div", "quota-chart", "");
      const bar = label("div", "quota-bar", "");
      bar.setAttribute("role", "meter"); bar.setAttribute("aria-label", window.label + (stale || expired ? " last known quota remaining" : " quota remaining"));
      bar.setAttribute("aria-valuemin", "0"); bar.setAttribute("aria-valuemax", "100"); bar.setAttribute("aria-valuenow", String(remaining));
      const fill = label("div", "quota-fill", ""); fill.style.width = remaining + "%"; bar.appendChild(fill);
      if (window.resetsAt && window.durationMs > 0 && !expired) {
        const timeLeft = Math.max(0, Math.min(100, (window.resetsAt - now) / window.durationMs * 100));
        const marker = label("span", "quota-marker", ""); marker.style.left = timeLeft + "%"; marker.setAttribute("aria-hidden", "true"); bar.appendChild(marker);
      }
      chart.appendChild(bar);
      chart.appendChild(label("div", "quota-date quota-muted", window.resetsAt ? new Date(window.resetsAt).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : ""));
      row.appendChild(chart); list.appendChild(row);
    }
    field("quota-empty").hidden = !!view.windows?.length;
    sheet.querySelector(".quota-legend").hidden = !view.windows?.length;
    if (!dirty && !saving) {
      field("quota-enabled").checked = view.policy.enabled;
      field("quota-threshold").value = view.policy.pausePercent;
    }
    field("quota-threshold").disabled = !field("quota-enabled").checked || saving;
    field("quota-save").disabled = saving || !dirty;
    field("quota-enabled").disabled = saving;
    const state = view.admission?.state;
    field("quota-hold-status").textContent = state === "disabled" ? "Automatic hold is off." : state === "ready" ? "Background work may continue." : state === "held" ? "Holding background work until the reset is less than 20 minutes away or fresh quota is available." : "Waiting for a current five-hour reading before starting background turns.";
  }
  async function refresh(force) {
    if (busy || saving) return;
    const request = generation; busy = true; render();
    try {
      const next = await bridge.invoke("claude_quota", { refresh: force });
      if (request !== generation) return;
      view = next;
    } catch (_) {
      if (request !== generation) return;
      if (view) view = { ...view, state: "stale", message: "Could not read Claude Code quota. Try refreshing again." };
      else { field("quota-message").hidden = false; field("quota-message").textContent = "Could not read Claude Code quota. Try refreshing again."; field("quota-freshness").textContent = "Quota unavailable"; }
    } finally { if (request === generation) { busy = false; lastPoll = Date.now(); render(); } }
  }
  function close() {
    sheet.hidden = true; generation++; busy = false;
    clearInterval(timer); timer = null;
    queueMicrotask(() => { if (sheet.hidden) document.getElementById("set-btn")?.focus(); });
  }
  async function open() {
    clearInterval(timer);
    generation++; busy = false; sheet.hidden = false; dirty = false;
    field("quota-save-status").textContent = "";
    field("quota-close").focus();
    timer = setInterval(() => {
      if (document.getElementById("set-quota-open")?.hidden) { close(); return; }
      if (Date.now() - lastPoll >= 30000) refresh(false);
      else render();
    }, 1000);
    await refresh(false);
  }
  field("quota-close").addEventListener("click", close);
  field("quota-refresh").addEventListener("click", () => refresh(true));
  field("quota-policy").addEventListener("input", () => { dirty = true; field("quota-save-status").textContent = ""; render(); });
  field("quota-policy").addEventListener("submit", async event => {
    event.preventDefault(); if (saving || !view) return;
    const pausePercent = Number(field("quota-threshold").value);
    if (!Number.isInteger(pausePercent) || pausePercent < 1 || pausePercent > 99) {
      field("quota-save-status").textContent = "Choose a pause threshold from 1% to 99% used."; return;
    }
    const policy = { enabled: field("quota-enabled").checked, pausePercent };
    const request = ++generation;
    busy = false; saving = true; render();
    try {
      const next = await bridge.invoke("set_claude_quota_policy", { policy });
      if (request !== generation) return;
      view = next;
      dirty = false; field("quota-save-status").textContent = "Saved.";
    } catch (_) { if (request !== generation) return; field("quota-save-status").textContent = "Could not save the setting. Your previous setting is still active."; }
    finally { saving = false; render(); }
  });
  sheet.addEventListener("keydown", event => {
    if (event.key === "Escape") { event.stopPropagation(); close(); }
    if (event.key === "Tab") {
      const controls = [...sheet.querySelectorAll("button, input")].filter(node => !node.disabled);
      if (event.shiftKey && document.activeElement === controls[0]) { event.preventDefault(); controls.at(-1).focus(); }
      else if (!event.shiftKey && document.activeElement === controls.at(-1)) { event.preventDefault(); controls[0].focus(); }
    }
  });
  window.RichSettings.registerQuota({ open });
})();
