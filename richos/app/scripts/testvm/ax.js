// ax.js — the guest's accessibility tree, and the press that drives it.
//
// Run INSIDE the guest, by ax.sh, as:
//
//     <the AX_PARAMS block> + this file  |  osascript -l JavaScript -
//
// ax.js never parses arguments. ax.sh prepends one line — `var AX_PARAMS =
// {...};` — and the whole text travels on stdin, so nothing here is ever
// interpolated into a remote command line.
//
// It prints ONE JSON OBJECT PER LINE. The first is `{"meta":true,...}`; every
// line after it is a node, a `{"clicked":...}` or an `{"error":...}`. The host
// renders them; the guest decides nothing about formatting.
//
// ===========================================================================
// WHY JAVASCRIPT AND NOT APPLESCRIPT — THE GEOMETRY IS THE WHOLE REASON
// ===========================================================================
// AppleScript renders a list as a string by CONCATENATING its items. MEASURED
// on this Mac (macOS 15.6), 2026-09-20:
//
//     $ osascript -e 'set sz to {1024, 700}' -e 'return (sz as string)'
//     1024700
//
// A 1024x700 window and a 102x4700 one are the same six characters. A tree that
// prints geometry that way is WORSE than one that prints none, because it
// prints a number that looks right — and the app derives a 1024x700 window in
// this very guest (docs/testvm.md), so that is not a hypothetical pair.
//
// AppleScript can be made to punctuate the items by hand (`item 1 of sz`, which
// is what ax.sh's own --windows does), and every walk that forgot to got a
// fused number. JavaScript for Automation returns a REAL ARRAY from position()
// and size(), and ships JSON.stringify, so the four numbers are never adjacent
// in the first place. Measured the same day, same Mac:
//
//     $ osascript -l JavaScript /tmp/t.js        // return JSON.stringify([1024,700])
//     [1024,700]
//
// The host renderer still REFUSES a fused token if one ever reaches it. A
// structural fix plus a check for the fix having held is the shape this harness
// uses everywhere else.
//
// ===========================================================================
// WHY A PRESS AND NOT A CLICK AT COORDINATES
// ===========================================================================
// `el.actions["AXPress"].perform()` sends the press to the ELEMENT. It does not
// care where the element is, whether the window moved, whether the app is
// frontmost, or whether something is drawn over it. A coordinate click cares
// about all four, and three of them change between one run and the next.
// `--at x,y` exists for the controls that expose no AXPress, and it refuses
// unless the target process is frontmost — the same discipline ax.sh's --key
// has carried since a synthetic key landed in the wrong process on 2026-09-19.
//
// ===========================================================================
// EVERY AX CALL IS WRAPPED, BECAUSE EVERY AX CALL THROWS
// ===========================================================================
// An accessibility attribute an element does not implement raises rather than
// returning empty, and a tree walk that lets one of those escape stops at the
// first unusual node — which on a Tauri window is roughly immediately. Each
// read is its own try/catch with its own default.

// ---------------------------------------------------------------------------
// THE MATCHER — top level, and exported, so it is TESTED and not just asserted
// ---------------------------------------------------------------------------
// TEXT MATCHES TITLE **OR** DESCRIPTION. An aria-label on a web view's control
// surfaces as AXDescription and not as AXTitle, which is why the THIRD rewrite
// of the same press script was the one that finally found the theme buttons:
// `axpress.js` matched the title, `axpress2.js` added a role filter and still
// reported NOTFOUND on buttons that were plainly on the screen, and
// `axpress3.js` added the description. Matching the title alone is the defect,
// not a simplification.
//
// These two are outside run() because run() needs System Events and a guest,
// and this rule needs neither: the test suite loads this file in node and drives
// them directly. A rule that cost three rewrites is worth a test rather than a
// comment.
function axTextHit(P, hay, want) {
  if (!hay) return false;
  return P.contains ? (hay.indexOf(want) >= 0) : (hay === want);
}

function axMatches(P, n) {
  if (P.role && n.role !== P.role) return false;
  if (P.sub && n.sub !== P.sub) return false;
  if (P.text !== null && P.text !== undefined) {
    if (!axTextHit(P, n.title, P.text) && !axTextHit(P, n.desc, P.text)) return false;
  }
  if (P.value !== null && P.value !== undefined) {
    if (!axTextHit(P, n.value, P.value)) return false;
  }
  return true;
}

function run() {
  var P = (typeof AX_PARAMS !== "undefined") ? AX_PARAMS : {};
  var out = [];
  var se = Application("System Events");

  function emit(o) { out.push(JSON.stringify(o)); }
  function fail(code, detail, extra) {
    var o = { error: code, detail: String(detail || "") };
    if (extra) { for (var k in extra) { o[k] = extra[k]; } }
    emit(o);
    return out.join("\n");
  }

  // --- the target process ---------------------------------------------------
  var proc = null, procName = "", procPid = 0;
  try {
    if (P.app) {
      proc = se.processes.byName(P.app);
      procName = proc.name();               // forces the lookup to fail HERE
    } else {
      proc = se.processes.whose({ unixId: P.pid })[0];
      procName = proc.name();
    }
    procPid = proc.unixId();
  } catch (e) {
    return fail("noprocess",
                P.app ? ("no process named " + P.app) : ("no process with pid " + P.pid),
                { app: P.app || "", pid: P.pid || 0 });
  }

  // --- the roots: every window, or one -------------------------------------
  // A menu, a sheet or a system dialog is a window of its own, so the default
  // is EVERY window rather than window 1 — which is what each throwaway that
  // only looked at window 1 had to be rewritten for.
  var wins = [];
  try { wins = proc.windows(); } catch (e) { wins = []; }
  var roots = [];
  if (P.window) {
    if (wins.length < P.window) {
      return fail("nowindow", "process " + procName + " has " + wins.length + " window(s)",
                  { windows: wins.length });
    }
    roots = [wins[P.window - 1]];
  } else {
    roots = wins;
  }

  // --- reading one node -----------------------------------------------------
  function readNode(el, depth) {
    var n = { d: depth, role: "", sub: "", title: "", desc: "", value: "",
              enabled: null, x: null, y: null, w: null, h: null };
    try { n.role = String(el.role() || ""); } catch (e) {}
    try { n.sub = String(el.subrole() || ""); } catch (e) {}
    try { n.title = String(el.title() || ""); } catch (e) {}
    try { n.desc = String(el.description() || ""); } catch (e) {}
    try {
      var v = el.value();
      if (v !== null && v !== undefined) {
        n.value = String(v);
        if (n.value.length > 200) { n.value = n.value.slice(0, 200) + "..."; }
      }
    } catch (e) {}
    try { n.enabled = !!el.enabled(); } catch (e) {}
    // position() and size() are ARRAYS here. This is the whole reason the file
    // is JavaScript; see the header.
    try { var p = el.position(); if (p) { n.x = p[0]; n.y = p[1]; } } catch (e) {}
    try { var s = el.size();     if (s) { n.w = s[0]; n.h = s[1]; } } catch (e) {}
    return n;
  }

  // --- matching -------------------------------------------------------------
  // axMatches lives at the top of this file, and is tested there; see its
  // header for why the description is matched as well as the title.
  function matches(n) { return axMatches(P, n); }

  // --- the walk -------------------------------------------------------------
  var maxDepth = P.depth || 16;
  var maxNodes = P.max || 4000;
  var count = 0, truncated = false;
  var hits = [];          // elements, for click
  var hitNodes = [];      // their read form, for the report
  var selecting = (P.mode === "find" || P.mode === "click");

  function walk(el, depth) {
    if (truncated) return;
    if (count >= maxNodes) { truncated = true; return; }
    var n = readNode(el, depth);
    count++;
    if (selecting) {
      if (matches(n)) { hits.push(el); hitNodes.push(n); }
    } else {
      emit(n);
    }
    if (depth >= maxDepth) return;
    var kids = [];
    try { kids = el.uiElements(); } catch (e) { return; }
    for (var i = 0; i < kids.length; i++) {
      walk(kids[i], depth + 1);
      if (truncated) return;
    }
  }

  // --- the coordinate fallback, which refuses unless it can be sure ---------
  if (P.mode === "clickat") {
    var frontPid = -1;
    try { frontPid = se.processes.whose({ frontmost: true })[0].unixId(); } catch (e) {}
    if (frontPid !== procPid) {
      return fail("notfrontmost",
                  "frontmost pid is " + frontPid + ", the target (" + procName + ") is " +
                  procPid + " — a click at a point would land in another process",
                  { frontmost: frontPid, target: procPid });
    }
    try {
      se.click({ at: [P.atx, P.aty] });
    } catch (e) {
      return fail("clickfailed", e, { x: P.atx, y: P.aty });
    }
    emit({ meta: true, app: procName, pid: procPid, windows: wins.length, nodes: 0,
           truncated: false, mode: P.mode, matches: null });
    emit({ clicked: true, at: true, x: P.atx, y: P.aty });
    return out.join("\n");
  }

  for (var r = 0; r < roots.length; r++) {
    walk(roots[r], 0);
    if (truncated) break;
  }

  // The meta line is built AFTER the walk — it carries the counts — and is put
  // FIRST in the stream, because a reader that has to reach the end of a 4000
  // line dump to learn what it is reading is a reader that will not.
  var meta = JSON.stringify({ meta: true, app: procName, pid: procPid,
                              windows: wins.length, nodes: count,
                              truncated: truncated, mode: P.mode,
                              matches: selecting ? hits.length : null });

  if (P.mode === "find") {
    var found = [];
    for (var f = 0; f < hitNodes.length; f++) { found.push(JSON.stringify(hitNodes[f])); }
    return meta + (found.length ? "\n" + found.join("\n") : "");
  }

  if (P.mode === "click") {
    var nth = P.nth || 0;
    if (hits.length <= nth) {
      return meta + "\n" + JSON.stringify({
        error: "notfound",
        detail: "nothing matched" + (hits.length ? " at index " + nth : ""),
        matches: hits.length
      });
    }
    var target = hits[nth], node = hitNodes[nth];
    var names = [];
    try {
      var acts = target.actions();
      for (var a = 0; a < acts.length; a++) { try { names.push(acts[a].name()); } catch (e) {} }
    } catch (e) {}
    if (names.indexOf("AXPress") < 0) {
      // Named rather than swallowed: "it did not press" and "it cannot be
      // pressed, and here is what it CAN do" are different findings, and only
      // the second one tells the caller what to do next.
      return meta + "\n" + JSON.stringify({
        error: "noaction", detail: "the matched element has no AXPress",
        actions: names, matches: hits.length, node: node
      });
    }
    try {
      target.actions["AXPress"].perform();
    } catch (e) {
      return meta + "\n" + JSON.stringify({
        error: "pressfailed", detail: String(e), matches: hits.length, node: node
      });
    }
    return meta + "\n" + JSON.stringify({ clicked: true, action: "AXPress",
                                          matches: hits.length, node: node });
  }

  return meta + (out.length ? "\n" + out.join("\n") : "");
}

// Under osascript there is no module system and this is a no-op; under node,
// which is where test/run-tests.sh drives the matcher, it is the entry point.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { axMatches: axMatches, axTextHit: axTextHit };
}
