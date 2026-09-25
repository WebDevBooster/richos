"use strict";
// Desktop technical settings. Figures and pause evidence are independent reads.
(function () {
  const bridge = window.RichBridge;
  const sheet = document.createElement("div");
  sheet.id = "quota-sheet"; sheet.className = "overlay"; sheet.hidden = true;
  sheet.setAttribute("role", "dialog"); sheet.setAttribute("aria-modal", "true");
  sheet.setAttribute("aria-labelledby", "quota-title"); sheet.setAttribute("data-dismiss", "control:#quota-close");
  sheet.innerHTML = `<section class="overlay-panel quota-panel">
    <header class="quota-heading"><div><p class="quota-eyebrow">Settings · Technical view</p>
      <h2 id="quota-title">Claude Code quota</h2>
      <p class="quota-lede">Your Claude Code allowance, shared across apps and sessions.</p></div>
      <button id="quota-close" type="button" aria-label="Close Claude Code quota">×</button></header>
    <div class="quota-body"><div class="quota-windows-col">
      <div class="quota-toolbar"><span id="quota-freshness">Loading quota…</span>
        <button id="quota-refresh" class="quota-btn" type="button">Refresh</button></div>
      <p id="quota-message" class="quota-message" role="status" hidden></p>
      <div id="quota-windows" aria-label="Claude Code quota windows"></div>
      <div id="quota-empty" hidden><h3>No reading yet.</h3><p>Claude Code has not reported an allowance. There is no usage figure to show yet.</p></div>
      <p class="quota-legend">Gold is what you have <b>used</b>. The tick is where the clock is <b>now</b>. Bar past the tick means you are spending faster than the window is passing.</p>
    </div><form id="quota-policy" class="quota-policy" novalidate>
      <h3>Automatic pause</h3>
      <div class="quota-switch-row"><button id="quota-enabled" class="quota-switch" type="button" role="switch" aria-checked="false" aria-label="Automatically pause Rich’s agents"></button>
        <div class="quota-switch-label">Pause Rich’s agents when the five-hour window reaches
          <label class="quota-threshold"><span class="sr-only">Pause threshold, percent used</span><input id="quota-threshold" inputmode="numeric" type="text" maxlength="3" value="93" aria-describedby="quota-validation">% used</label>,
          <span class="quota-muted">unless the reset is less than 20 minutes away.</span>
          <div id="quota-draft-actions" hidden><button id="quota-save" class="quota-btn quota-btn-primary" type="submit">Save</button>
            <button id="quota-keep" class="quota-btn" type="button">Keep 93%</button></div>
          <p id="quota-validation" role="status" hidden></p>
        </div></div>
      <p id="quota-save-status" role="status" aria-live="polite" hidden></p>
      <div id="quota-status-card" class="quota-status-card">
        <h4 id="quota-hold-status">Loading pause status…</h4>
        <p id="quota-hold-detail"></p><ul id="quota-held" aria-label="Observed pauses"></ul>
        <div class="quota-status-actions"><button id="quota-hold-refresh" type="button" class="quota-btn" hidden>Refresh</button>
          <button id="quota-release" type="button" class="quota-btn" hidden>Let them continue now</button></div>
      </div>
      <div class="quota-boundary"><p><b>A pause keeps their place.</b> Each agent finishes its current step, then waits before the next, keeping everything it knows.</p>
        <p>They continue automatically when the allowance permits it. You can keep talking to Rich.</p>
        <p>Checks every 30 minutes below 70% used and every 5 minutes from 70% onwards.</p></div>
    </form></div></section>`;
  document.body.appendChild(sheet);
  const field = id => sheet.querySelector("#" + id);
  let view = null, activity = null, busy = false, saving = false, dirty = false, generation = 0;
  let timer = null, lastPoll = 0, lastActivity = 0, activityBusy = false;
  const duration = ms => {
    const m = Math.max(1, Math.ceil(ms / 60000));
    return m >= 1440 ? `${Math.floor(m / 1440)}d ${Math.floor(m % 1440 / 60)}h` : m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
  };
  const clock = t => new Date(t).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const stamp = (t, weekly) => new Date(t).toLocaleString(undefined, { ...(weekly ? { weekday: "short" } : {}), hour: "numeric", minute: "2-digit" });
  function node(tag, cls, text = "") { const n = document.createElement(tag); n.className = cls; n.textContent = text; return n; }
  function stale(now = Date.now()) { return !view || view.state !== "fresh" || !view.checkedAt || now < view.checkedAt || now - view.checkedAt >= view.refreshIntervalMs || view.windows.some(w => w.resetsAt && w.resetsAt <= now); }
  function validDraft() { return /^[0-9]{1,2}$/.test(field("quota-threshold").value) && Number(field("quota-threshold").value) >= 1; }
  function say(text) { field("quota-save-status").textContent = text; field("quota-save-status").hidden = !text; }
  function ruler(window, hero, old) {
    const chart = node("div", "quota-chart" + (hero ? "" : " quota-chart-small"));
    const bar = node("div", "quota-bar");
    bar.setAttribute("role", "meter"); bar.setAttribute("aria-label", window.label + (old ? " last known usage" : " usage"));
    bar.setAttribute("aria-valuemin", "0"); bar.setAttribute("aria-valuemax", "100"); bar.setAttribute("aria-valuenow", String(window.usedPercent));
    bar.appendChild(node("span", "quota-track"));
    const fill = node("span", "quota-fill"); fill.style.width = window.usedPercent + "%"; bar.appendChild(fill);
    const now = Date.now();
    if (window.resetsAt > now && window.durationMs > 0 && window.resetsAt - window.durationMs <= now) {
      const elapsed = Math.max(0, Math.min(100, (1 - (window.resetsAt - now) / window.durationMs) * 100));
      const marker = node("span", "quota-marker"); marker.style.left = elapsed + "%"; marker.setAttribute("aria-hidden", "true");
      marker.appendChild(node("i", ""));
      if (elapsed > 16 && elapsed < 84) marker.appendChild(node("span", "", "now"));
      bar.appendChild(marker);
    }
    if (hero) {
      const threshold = node("span", "quota-pause-line" + (view.policy.enabled ? "" : " is-off"));
      threshold.style.left = view.policy.pausePercent + "%";
      if (view.policy.pausePercent < 35) threshold.classList.add("is-left");
      threshold.append(node("i", ""), node("span", "", `${view.policy.enabled ? "pause at" : "pause off ·"} ${view.policy.pausePercent}%`));
      bar.appendChild(threshold);
    }
    chart.appendChild(bar);
    if (window.resetsAt && window.durationMs > 0) {
      const ends = node("div", "quota-ends");
      ends.append(node("span", "", "began " + stamp(window.resetsAt - window.durationMs, !hero)), node("span", "", "resets " + stamp(window.resetsAt, !hero)));
      chart.appendChild(ends);
    }
    return chart;
  }
  function renderWindows() {
    const list = field("quota-windows"); list.replaceChildren();
    const windows = view.windows || [], hero = windows.find(w => w.id === "five_hour");
    const ordered = hero ? [hero, ...windows.filter(w => w !== hero)] : windows;
    for (const window of ordered) {
      const primary = window === hero, old = stale() || !!window.resetsAt && window.resetsAt <= Date.now();
      const row = node("section", "quota-window " + (primary ? "quota-hero" : "quota-weekly") + (old ? " quota-window--stale" : ""));
      const heading = node("div", "quota-window-summary");
      const title = node("h3", "quota-window-label", window.label);
      if (primary) title.appendChild(node("span", "quota-muted", "the one the pause watches"));
      heading.appendChild(title);
      const value = node("div", "quota-used", String(Math.round(window.usedPercent)));
      value.append(node("span", "quota-percent", "%"), node("span", "quota-unit", "used"));
      if (old) value.appendChild(node("span", "quota-tag", "stale"));
      heading.appendChild(value);
      const reset = window.resetsAt <= Date.now() && window.resetsAt ? "Window ended · awaiting refresh" : window.resetsAt ? `Resets in ${duration(window.resetsAt - Date.now())}${primary ? " · " + clock(window.resetsAt) : ""}` : "Reset time unavailable";
      heading.appendChild(node("div", "quota-reset", reset));
      row.append(heading, ruler(window, primary, old)); list.appendChild(row);
    }
    if (windows.length) {
      if (!hero) list.prepend(node("p", "quota-absent", "Five-hour allowance not reported by Claude Code."));
      if (!windows.some(w => w.id === "seven_day")) list.appendChild(node("p", "quota-absent", "Weekly allowance not reported by Claude Code."));
      if (!windows.some(w => w.id !== "five_hour" && w.id !== "seven_day")) list.appendChild(node("p", "quota-absent", "Model-specific weekly limits not reported for this account."));
    }
    field("quota-empty").hidden = !!windows.length;
    sheet.querySelector(".quota-legend").hidden = !windows.length;
  }
  function renderStatus() {
    const held = activity?.held || [], released = activity?.released || [];
    const enabled = view?.policy.enabled, state = view?.admission?.state;
    const title = field("quota-hold-status"), detail = field("quota-hold-detail"), list = field("quota-held");
    const agents = held.filter(r => r.kind === "agent").length;
    const assignments = held.filter(r => r.kind === "assignment").length;
    field("quota-status-card").classList.toggle("is-holding", !!held.length);
    field("quota-hold-refresh").hidden = state !== "unknown";
    field("quota-hold-refresh").disabled = busy || saving || view?.retryAt > Date.now();
    field("quota-release").hidden = !enabled || !(held.length || state === "unknown");
    field("quota-release").disabled = saving;
    field("quota-release").textContent = held.length ? "Let them continue now" : "Turn pause off";
    if (held.length) {
      title.textContent = !enabled || state === "ready" ? "Releasing the pause…" : agents ? `${agents} ${agents === 1 ? "agent is" : "agents are"} paused` : assignments ? `${assignments} ${assignments === 1 ? "assignment is" : "assignments are"} paused` : "Waiting to start an agent";
      detail.textContent = !enabled || state === "ready" ? "The allowance permits work. Waiting for each pause to clear." : activity.resumesAt ? `Can continue just after ${clock(activity.resumesAt)} when the reset is under 20 minutes away, or sooner if a fresh reading permits it.` : "Waiting for a current five-hour reading. Their work is saved.";
      if (enabled) detail.textContent += " Letting them continue now turns automatic pause off.";
    } else if (released.length && (!enabled || state === "ready")) {
      title.textContent = "Pause released"; detail.textContent = "These waits have cleared. Work can continue from its saved place.";
    } else if (!enabled) {
      title.textContent = "Automatic pause is off"; detail.textContent = "Rich’s agents can use the available allowance. Turn it on to keep a reserve in the five-hour window.";
    } else if (state === "unknown") {
      title.textContent = "Waiting for a current reading"; detail.textContent = "New background work will wait until the five-hour allowance is known. Refresh the reading or turn pause off.";
    } else if (state === "held") {
      title.textContent = "Ready to pause"; detail.textContent = `The five-hour allowance has reached ${view.policy.pausePercent}%. Agents will pause when they finish their current step. No pauses observed yet.`;
    } else {
      title.textContent = "Automatic pause is on"; detail.textContent = "The allowance permits work. No pauses observed.";
    }
    if (!activity || activity.error) detail.textContent += " Live pause details are unavailable.";
    list.replaceChildren();
    for (const row of (held.length ? held : !enabled || state === "ready" ? released : [])) {
      const item = node("li", ""), description = node("span", "quota-held-description");
      description.appendChild(node("strong", "", row.name));
      if (row.task) description.appendChild(node("span", "quota-muted", row.task));
      if (row.kind !== "agent") description.appendChild(node("span", "quota-muted", row.kind === "assignment" ? "Assignment" : "Agent dispatch"));
      item.append(description, node("span", "quota-held-time", (held.length ? "since " : "released ") + clock(held.length ? row.sinceAt : row.releasedAt)));
      list.appendChild(item);
    }
    list.hidden = !list.children.length;
  }
  function paintMenu() {
    const row = document.getElementById("set-quota-open"), text = document.getElementById("set-quota-state");
    if (!row || !text) return;
    const five = view?.windows?.find(w => w.id === "five_hour"), n = activity?.held?.filter(r => r.kind === "agent").length || 0;
    text.textContent = n ? `holding ${n} ${n === 1 ? "agent" : "agents"}` : five ? `${Math.round(five.usedPercent)}% used${stale() ? " · stale" : ""}` : "No current reading";
    let mini = row.querySelector(".quota-mini");
    if (!mini) { mini = node("span", "quota-mini"); mini.setAttribute("aria-hidden", "true"); mini.appendChild(node("i", "")); row.insertBefore(mini, row.lastChild); }
    mini.hidden = !five;
    mini.classList.toggle("is-stale", stale()); mini.firstChild.style.width = (five?.usedPercent || 0) + "%";
  }
  function render() {
    paintMenu();
    field("quota-refresh").disabled = busy || saving || !!(view?.retryAt > Date.now());
    field("quota-refresh").textContent = busy ? "Refreshing…" : "Refresh";
    if (!view) return;
    const now = Date.now(), age = view.checkedAt ? now - view.checkedAt < 60000 ? "just now" : duration(now - view.checkedAt) + " ago" : null;
    field("quota-freshness").textContent = age ? `${stale() ? "Stale · last reading" : "Checked"} ${age} · every ${view.refreshIntervalMs / 60000} min` : "No current reading";
    field("quota-message").textContent = (view.message || "") + (view.retryAt > now ? ` Next refresh available in ${duration(view.retryAt - now)}.` : "");
    field("quota-message").hidden = !field("quota-message").textContent;
    renderWindows();
    field("quota-enabled").setAttribute("aria-checked", String(view.policy.enabled));
    field("quota-enabled").disabled = saving || !!view.policyUnavailable;
    if (!dirty) field("quota-threshold").value = view.policy.pausePercent;
    field("quota-threshold").disabled = !view.policy.enabled || saving || !!view.policyUnavailable;
    field("quota-threshold").setAttribute("aria-invalid", String(dirty && !validDraft()));
    field("quota-draft-actions").hidden = !dirty;
    field("quota-save").disabled = saving || !validDraft();
    field("quota-save").textContent = `Save ${field("quota-threshold").value}%`;
    field("quota-keep").textContent = `Keep ${view.policy.pausePercent}%`;
    field("quota-keep").disabled = saving;
    field("quota-validation").hidden = !dirty || validDraft();
    field("quota-validation").textContent = `Pick a whole number from 1 to 99. It is still ${view.policy.pausePercent}% until you save.`;
    renderStatus();
  }
  async function readActivity() {
    if (activityBusy) return;
    activityBusy = true;
    try { activity = await bridge.invoke("claude_quota_activity", { threadId: null }); }
    catch (_) { activity = { held: [], released: [], error: true }; }
    finally { activityBusy = false; lastActivity = Date.now(); if (!sheet.hidden) renderStatus(); paintMenu(); }
  }
  async function refresh(force) {
    if (busy || saving) return;
    const request = generation; busy = true; if (!sheet.hidden) render();
    try {
      const next = await bridge.invoke("claude_quota", { refresh: force });
      if (request === generation) view = next;
    } catch (_) {
      if (request !== generation) return;
      view = { ...(view || { windows: [], checkedAt: null, refreshIntervalMs: 1800000, policyUnavailable: true, policy: { enabled: false, pausePercent: 93 } }), state: "unavailable", message: "Could not read Claude Code quota. Try refreshing again." };
    } finally {
      if (request === generation) { busy = false; lastPoll = Date.now(); if (!sheet.hidden) render(); paintMenu(); }
    }
  }
  async function save(policy) {
    if (saving || !view || view.policyUnavailable) return;
    const request = ++generation; busy = false; saving = true; say(""); render();
    try {
      const next = await bridge.invoke("set_claude_quota_policy", { policy });
      if (request !== generation) return;
      view = next; dirty = false; say("Saved."); readActivity();
    } catch (_) { if (request === generation) say("Could not save. Your previous setting is still active."); }
    finally { saving = false; if (!sheet.hidden) render(); paintMenu(); }
  }
  function keep() { dirty = false; say(""); render(); }
  function close() {
    sheet.hidden = true; generation++; busy = false; clearInterval(timer); timer = null;
    queueMicrotask(() => { if (sheet.hidden) document.getElementById("set-btn")?.focus(); });
  }
  async function open() {
    clearInterval(timer); generation++; busy = false; sheet.hidden = false; dirty = false; say("");
    field("quota-close").focus(); render(); readActivity();
    timer = setInterval(() => {
      if (document.getElementById("set-quota-open")?.hidden) { close(); return; }
      if (Date.now() - lastPoll >= 30000) refresh(false); else render();
      if (Date.now() - lastActivity >= 3000) readActivity();
    }, 1000);
    await refresh(false);
  }
  field("quota-close").addEventListener("click", close);
  for (const id of ["quota-refresh", "quota-hold-refresh"]) field(id).addEventListener("click", () => refresh(true));
  field("quota-enabled").addEventListener("click", () => view && save({ ...view.policy, enabled: !view.policy.enabled }));
  field("quota-release").addEventListener("click", () => view && save({ ...view.policy, enabled: false }));
  field("quota-threshold").addEventListener("input", () => { dirty = field("quota-threshold").value !== String(view.policy.pausePercent); say(""); render(); });
  field("quota-keep").addEventListener("click", keep);
  field("quota-policy").addEventListener("submit", event => { event.preventDefault(); if (validDraft() && dirty) save({ ...view.policy, pausePercent: Number(field("quota-threshold").value) }); });
  sheet.addEventListener("keydown", event => {
    if (event.key === "Escape") { event.stopPropagation(); event.preventDefault(); if (dirty && !saving) keep(); else close(); }
    if (event.key === "Tab") {
      const controls = [...sheet.querySelectorAll("button, input")].filter(n => !n.disabled && n.getClientRects().length);
      if (event.shiftKey && document.activeElement === controls[0]) { event.preventDefault(); controls.at(-1)?.focus(); }
      else if (!event.shiftKey && document.activeElement === controls.at(-1)) { event.preventDefault(); controls[0]?.focus(); }
    }
  });
  window.RichSettings.registerQuota({ open, paint: paintMenu });
  // The settings preview stays current while visible. These reads use the same
  // provider cache/backoff as the sheet; pause reads never contact Claude.
  setInterval(() => {
    if (document.hidden || !sheet.hidden) return;
    const row = document.getElementById("set-quota-open");
    if (!row || !row.getClientRects().length) return;
    if (!view || Date.now() - lastPoll >= 30000) refresh(false);
    if (Date.now() - lastActivity >= 3000) readActivity();
  }, 1000);
})();
