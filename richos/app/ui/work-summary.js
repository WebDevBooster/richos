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
  window.RichWorkSummary = {render};
})();
