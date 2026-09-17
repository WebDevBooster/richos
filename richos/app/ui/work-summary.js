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
  //   approve and decline, 16px, the same    5.78:1 dark    6.36:1 light   (needs 4.5:1)
  // `--ink-soft` is `rgba(223,228,238,0.64)` over `#182440` and `rgba(12,19,34,0.68)` over
  // `#fdfcf8`; both were composited before the ratio was taken. Nothing here is exempt —
  // every ratio above is re-measured under WebKit by `ui/tests/background-work.js` in both
  // themes rather than trusted from this comment.
  const STATES = {
    registered: "Written down. Nothing has been prepared yet.",
    preparing: "Getting a workspace ready.",
    running: "Running.",
    // §0 row 7's mandated phrase, with the control behind it at last: the desk holds his
    // decision while he is away (§5.2/§5.7), so the row carries Approve and Decline and
    // the sentence stops pointing him at the composer.
    blocked: "Ready for you to approve. Nothing in your repository has been changed yet.",
    // THE SAME STATE WITH NO QUESTION ON THE DESK, and it is a real case rather than a
    // defensive branch: the queue lives in the running process, so an assignment that
    // stopped at his decision before a relaunch is `blocked` with nothing left to press.
    // Naming a control that is not there would be the failure slice 1's affordance gate
    // caught; the composer is a real path and this sentence names it.
    blockedNoRequest: "Ready for you to approve. Ask Rich to continue it when you are ready.",
    settled: "Finished.",
    failed: "Stopped before it finished. Ask Rich what it needs.",
    interrupted: "Stopped.",
  };

  /// `onDecide(requestId, allow)` answers the ONE exact request this assignment is waiting
  /// on him for. It is a request id and not an assignment id on purpose: what he approves is
  /// one action, and the press has to carry which one (spec §5.2's *"one exact action"*
  /// survives the queue).
  function renderAssignments(view, parent, onStop, onDecide) {
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
      const waiting = row.awaitingYou || null;
      const key = row.state === "blocked" && !waiting ? "blockedNoRequest" : row.state;
      detail.textContent = STATES[key] || "Its state could not be read.";
      if (row.detail) detail.textContent += " " + row.detail;
      item.append(title, detail);
      if (waiting) {
        // WHAT HE IS BEING ASKED, in the backend's own words for it — one phrase, written
        // in one place (`work_host.rs`'s `plain_action`), so the receipt and this row can
        // never describe one step two ways.
        const asked = document.createElement("p");
        asked.className = "overlay-note assignment-asked";
        asked.textContent = "Waiting on you: " + (waiting.asked || "a step it cannot take without you") + ".";
        const decisions = document.createElement("div");
        decisions.className = "assignment-decisions";
        // **Each control names its own assignment.** The same reason the stop control does:
        // a button labeled only "Approve" beside three assignments is one he cannot use
        // without counting rows, and spoken aloud it would name nothing at all.
        const approve = document.createElement("button");
        approve.type = "button";
        approve.className = "slideover-close assignment-approve";
        approve.textContent = "Approve this";
        approve.setAttribute("aria-label", "Approve " + row.title);
        approve.addEventListener("click", () => onDecide && onDecide(waiting.requestId, true));
        const decline = document.createElement("button");
        decline.type = "button";
        decline.className = "slideover-close assignment-decline";
        decline.textContent = "Decline this";
        decline.setAttribute("aria-label", "Decline " + row.title);
        decline.addEventListener("click", () => onDecide && onDecide(waiting.requestId, false));
        decisions.append(approve, decline);
        item.append(asked, decisions);
      }
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
