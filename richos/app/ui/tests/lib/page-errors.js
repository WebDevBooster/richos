// Uncaught page errors and console errors, collected for the WHOLE life of a page.
//
// Extracted from `appearance.js` (part-2 hunt section 42, 2026-09-29) so the collection can be
// proven without a browser. That suite kept a listener per page but copied the page's error
// array into its suite-wide aggregate once, right after the page opened; an error raised by any
// later click or shortcut landed in the page's array and never in the aggregate, so its "no
// page errors anywhere" check could not see the walks it names. The tracker here holds the
// PAGES and reads their live arrays when asked.

"use strict";

/// Install the listeners on `page` and expose the live array as `page.__errors`.
function collectPageErrors(page) {
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  return errors;
}

/// A suite-wide aggregate. `track(page)` returns the page; `all()` reads every tracked page's
/// errors AS OF THAT CALL, including ones raised after the page was tracked.
function createErrorTracker() {
  const pages = [];
  return {
    track(page) {
      pages.push(page);
      return page;
    },
    all() {
      return pages.flatMap((p) => p.__errors || []);
    },
    pageCount() {
      return pages.length;
    },
  };
}

module.exports = { collectPageErrors, createErrorTracker };
