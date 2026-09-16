"use strict";
// The app registry owns connections. Rendering never infers them from folder names.
(function () {
  const bridge = window.RichBridge;
  const sheet = document.createElement("div");
  sheet.id = "repositories-sheet"; sheet.className = "overlay"; sheet.hidden = true;
  sheet.setAttribute("role", "dialog"); sheet.setAttribute("aria-modal", "true"); sheet.setAttribute("aria-labelledby", "repositories-title");
  sheet.innerHTML = `<div class="overlay-panel overlay-panel--compact">
    <h2 id="repositories-title" class="overlay-title">Connected repositories</h2>
    <p class="overlay-note">Connect the repositories Rich may use for this company's assignments. Existing files and local changes stay in place.</p>
    <label class="entity-add-label" for="repository-company">Company</label>
    <select id="repository-company" class="entity-add-input"></select>
    <ul id="repository-list"></ul>
    <label class="entity-add-label" for="repository-folder">Repository folder</label>
    <input id="repository-folder" class="entity-add-input" type="text" placeholder="/Users/you/Projects/project" autocomplete="off" spellcheck="false">
    <label class="overlay-note"><input id="repository-initialize" type="checkbox"> Initialize Git if this folder is empty</label>
    <p id="repository-message" class="overlay-note" role="status"></p>
    <div class="desk-card-actions"><button id="repository-connect" class="desk-btn desk-btn--confirm" type="button">Connect repository</button>
    <button id="repository-close" class="desk-btn" type="button">Close</button></div></div>`;
  document.body.appendChild(sheet);
  const field = id => sheet.querySelector("#" + id);
  let companies = [], busy = false, returnFocus;
  function renderList() {
    const company = companies.find(c => c.id === field("repository-company").value);
    const list = field("repository-list"); list.replaceChildren();
    for (const path of company?.repositories || []) {
      const row = document.createElement("li"); row.textContent = path; row.style.overflowWrap = "anywhere"; list.appendChild(row);
    }
    if (!list.children.length) { const row = document.createElement("li"); row.textContent = "No repositories connected."; list.appendChild(row); }
    field("repository-connect").disabled = busy || !company;
  }
  async function refresh(preferred) {
    const result = await bridge.invoke("repository_connections");
    companies = result.companies;
    const select = field("repository-company"); select.replaceChildren();
    const blank = document.createElement("option"); blank.value = ""; blank.textContent = "Choose a company"; select.appendChild(blank);
    for (const company of companies) { const option = document.createElement("option"); option.value = company.id; option.textContent = company.name; select.appendChild(option); }
    if (preferred && companies.some(c => c.id === preferred)) select.value = preferred;
    renderList();
  }
  async function open() {
    returnFocus = document.activeElement; sheet.hidden = false;
    field("repository-message").textContent = "Loading connections…";
    try { await refresh(); field("repository-message").textContent = companies.length ? "" : "Add a company before connecting repositories."; }
    catch (error) { companies = []; renderList(); field("repository-message").textContent = String(error); }
    field("repository-company").focus();
  }
  function close() { if (busy) return; sheet.hidden = true; returnFocus?.focus(); }
  field("repository-company").addEventListener("change", renderList);
  field("repository-close").addEventListener("click", close);
  sheet.addEventListener("keydown", event => {
    if (event.key === "Escape") { event.stopPropagation(); close(); }
    if (event.key === "Tab") {
      const targets = [...sheet.querySelectorAll("button, input, select")].filter(node => !node.disabled);
      if (event.shiftKey && document.activeElement === targets[0]) { event.preventDefault(); targets.at(-1).focus(); }
      else if (!event.shiftKey && document.activeElement === targets.at(-1)) { event.preventDefault(); targets[0].focus(); }
    }
  });
  field("repository-connect").addEventListener("click", async () => {
    const entityId = field("repository-company").value;
    if (busy || !entityId) return;
    busy = true; renderList(); field("repository-close").disabled = true;
    field("repository-message").textContent = "Checking this repository…";
    try {
      const result = await bridge.invoke("connect_repository", {entityId, folder:field("repository-folder").value.trim(), initializeEmpty:field("repository-initialize").checked});
      await refresh(entityId);
      field("repository-message").textContent = result.repository.initialized ? "Git initialized and repository connected." : "Repository connected.";
      field("repository-folder").value = ""; field("repository-initialize").checked = false;
    } catch (error) { field("repository-message").textContent = String(error); }
    finally { busy = false; renderList(); field("repository-close").disabled = false; }
  });
  window.RichSettings.registerRepositories({open});
})();
