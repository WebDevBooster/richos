"use strict";
// Saved receipts are evidence of work, separate from the live worker count.
(function () {
  function render(summary, parent) {
    if (summary.error) {
      const note = document.createElement("p"); note.className = "overlay-note";
      note.textContent = "Saved work is unavailable: " + summary.error;
      parent.appendChild(note); return;
    }
    for (const item of summary.items || []) {
      const row = document.createElement("section"); row.className = "slide-item";
      const title = document.createElement("strong"); title.textContent = item.title;
      const detail = document.createElement("p"); detail.textContent = item.detail;
      const repository = document.createElement("p"); repository.className = "overlay-note";
      repository.textContent = item.role + " · " + item.repository;
      repository.style.overflowWrap = "anywhere";
      row.append(title, detail, repository); parent.appendChild(row);
    }
    if (summary.omitted) {
      const note = document.createElement("p"); note.className = "overlay-note";
      note.textContent = `${summary.omitted} more saved records. Ask Rich about the assignment you want to continue.`;
      parent.appendChild(note);
    }
  }
  // =====================================================================================
  // THE ASSIGNMENTS HE GAVE — background-work spec §1, §4.2 and §0 row 7
  // =====================================================================================
  //
  // A different thing from the receipts above, and the difference is the point: a receipt
  // describes what a worker did, and an assignment describes what the CEO ASKED FOR. It
  // exists from the moment he speaks, before a workspace does.
  //
  // **This is also the only surface that can show background work at all.** The live worker
  // chip is fed by `get_worker_status`, which returns an empty view whenever no turn is open
  // on the thread — and that window is where background work lives.
  //
  // WORDING IS THE FEATURE, not a detail of it. `blocked` reads "Ready for you to approve",
  // never "done": the work ran to the step that would change his repository and stopped
  // there, because that step is not on the list of things a worker may do without asking
  // (spec §0 row 7, §5.4, §7.8).
  //
  // CONTRAST, computed rather than eyeballed, both themes:
  //   title      `--ink` on `--card`        12.06:1 dark   18.07:1 light   (needs 4.5:1)
  //   detail     `--ink-soft` on `--card`    5.78:1 dark    6.36:1 light   (needs 4.5:1)
  //   stop control, 16px, same `--ink-soft`  5.78:1 dark    6.36:1 light   (needs 4.5:1)
  // `--ink-soft` is `rgba(223,228,238,0.64)` over `#182440` and `rgba(12,19,34,0.68)` over
  // `#fdfcf8`; both were composited before the ratio was taken. Nothing here is exempt.
  const STATES = {
    registered: "Written down. Nothing has been prepared yet.",
    preparing: "Getting a workspace ready.",
    running: "Running.",
    // §0 row 7's mandated phrase, plus the affordance that actually exists TODAY. The
    // approval desk that would hold his decision while he is away is §5.2/§5.7 and is not
    // built, so a sentence implying a button here would be a claim about a control that is
    // not on this surface. Asking Rich to continue it is a real path and the composer is a
    // real control, which is the same answer the saved-record limit gives one screen over.
    blocked: "Ready for you to approve. Ask Rich to continue it when you are ready.",
    settled: "Finished.",
    failed: "Stopped before it finished. Ask Rich what it needs.",
    interrupted: "Stopped.",
  };

  function renderAssignments(view, parent, onStop) {
    if (view.error) {
      const note = document.createElement("p");
      note.className = "overlay-note";
      note.textContent = "Your assignments are unavailable: " + view.error;
      parent.appendChild(note);
      return;
    }
    const rows = view.rows || [];
    if (!rows.length) return;
    const heading = document.createElement("h3");
    heading.className = "assignment-heading";
    heading.textContent = "What you have asked for";
    parent.appendChild(heading);
    for (const row of rows) {
      const item = document.createElement("section");
      item.className = "slide-item";
      const title = document.createElement("strong");
      title.className = "assignment-title";
      title.textContent = row.title;
      const detail = document.createElement("p");
      detail.className = "overlay-note";
      // The state's own sentence, then whatever the backend recorded about it. Two plain
      // sentences rather than a code and a label.
      detail.textContent = STATES[row.state] || "Its state could not be read.";
      if (row.detail) detail.textContent += " " + row.detail;
      item.append(title, detail);
      if (row.canStop) {
        const stop = document.createElement("button");
        stop.type = "button";
        stop.className = "slideover-close assignment-stop";
        // **Per assignment, and it says which one.** Stop stays the conversation's Stop
        // (the CEO, 2026-09-17: "OK, go with recommended"), so this control is the only way
        // to stop one piece of running work, and a control labeled just "Stop" beside three
        // of them would be a control he cannot use without counting rows.
        stop.textContent = "Stop this";
        stop.setAttribute("aria-label", "Stop " + row.title);
        stop.addEventListener("click", () => onStop(row.id));
        item.appendChild(stop);
      }
      parent.appendChild(item);
    }
  }

  window.RichWorkSummary = {render, renderAssignments};
})();
