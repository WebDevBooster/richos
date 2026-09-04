// THE UPDATE SURFACE — what the CEO sees when RichOS updates itself.
//
// RICH-TODOs row 12: before this there was no updater of any kind, so "automatically
// download and install whatever the user needs" rested on zero infrastructure. The Rust
// half is `app/src-tauri/src/updates.rs`; this is the half a person looks at.
//
// A SILENT UPDATER IS NOT ACCEPTABLE, and that is a constraint rather than a preference. An
// updater nobody can see is one that can be broken for three months without anyone learning
// it. So:
//
//   * RichOS checks by itself, three seconds after launch. This row always says WHEN it last
//     looked and WHAT it found — "never checked" is a state, and it is a different state
//     from "checked, and you are current".
//   * Every failure names WHICH failure it is in a sentence a non-technical CEO can act on,
//     with the vendor's own error text one click behind it. An error that hides its cause
//     turns a five-minute diagnosis into a week.
//   * A REFUSED SIGNATURE IS NOT OFFERED A RETRY. Every other failure gets "Try again",
//     because every other failure is plausibly transient. A signature failure means the
//     bytes on the wire are not the bytes we signed; retrying produces the same refusal, and
//     a button that invites someone to keep pressing until a security check passes is the
//     wrong shape of button. It gets an explanation instead.
//
// WHERE IT ANNOUNCES ITSELF (CEO ruling §26, placement paragraph, 2026-09-04). The row below
// was, until that ruling, the whole surface — and it lives inside a menu, so a waiting update
// reached only a CEO who happened to open one. His words: *"the user can't be bothered to
// hunt for some update button somewhere."* So there is now a CUE — see the block above
// `cue()` for the whole reasoning — a single small element that APPEARS beside the universal
// settings button when, and only when, something is waiting, and is absent from the document
// entirely the rest of the time. It announces and leads; the row still decides.
//
// WHERE THE ROW LIVES, AND WHY NOT IN THE RAIL'S PREFERENCES POPOVER. It renders into a row of
// the UNIVERSAL settings menu — the button §15 says is "ALWAYS EVERYWHERE ON EVERY PAGE" —
// through `RichSettings.registerUpdates`, the same optional-capability seam Techy Mode and
// the opening-screen switch use. The rail popover was tried first and MEASURED: it went from
// 581px to 761px, and at 761px it covers eight more rail rows, which turned `techy.js`
// check 9 red because a click meant for a thread landed on the popover. That popover is
// full. The universal menu is 160px in a 900px window, and it is on every screen — which is
// also the better home for a thing whose entire point is that the CEO can see it.
//
// TALKS ONLY TO `window.RichBridge`, never to `window.__TAURI__` — the same rule main.js
// follows, and the reason `mock.js` can drive all nine states in a plain browser.
//
// CONTRAST: every pair this file switches between is listed with its computed ratio, both
// themes, in `style.css`'s `.update-*` block. Nothing here is exempt from the floor and
// nothing here claims to be.
"use strict";

window.RichUpdates = (function () {
  var host = null; // the container `settings-button.js` hands us, or null before first paint
  var nodes = null; // refs into that container
  var view = null; // the last UpdateView we were given
  var busy = false;

  // ---- formatting ------------------------------------------------------------------------

  /// Bytes as a person reads them. No unit is ever printed for a number that has not been
  /// divided into it.
  function bytes(n) {
    if (typeof n !== "number" || !isFinite(n) || n < 0) return "";
    if (n >= 1048576) return (n / 1048576).toFixed(1) + " MB";
    if (n >= 1024) return Math.round(n / 1024) + " KB";
    return n + " bytes";
  }

  /// "just now" / "8 minutes ago" / a date. The point of this phrase is that the CEO can see
  /// the check HAPPENED, so an unusable timestamp says nothing rather than rendering a lie.
  function when(ms) {
    if (typeof ms !== "number" || !isFinite(ms) || ms <= 0) return "";
    var delta = Date.now() - ms;
    if (delta < 60000) return "just now";
    if (delta < 3600000) {
      var mins = Math.round(delta / 60000);
      return mins === 1 ? "1 minute ago" : mins + " minutes ago";
    }
    if (delta < 86400000) {
      var hrs = Math.round(delta / 3600000);
      return hrs === 1 ? "1 hour ago" : hrs + " hours ago";
    }
    try {
      return "on " + new Date(ms).toLocaleDateString();
    } catch (e) {
      return "";
    }
  }

  /// Everything the row says, in one place, so a state cannot exist with no sentence
  /// attached to it. Ten arms for nine states plus the unknown one, and the unknown one
  /// reports itself as unknown — falling back to "up to date" would be the single worst
  /// answer this file could give.
  function sentences(v) {
    var current = "RichOS " + (v.currentVersion || "");
    switch (v.state) {
      case "unconfigured":
        return {
          headline: current,
          sub:
            "There is no update server yet, so RichOS cannot check for new versions. " +
            "Where updates are published has not been decided.",
        };
      case "idle":
        return { headline: current, sub: "RichOS has not checked for updates yet." };
      case "checking":
        return { headline: current, sub: "Checking for updates…" };
      case "upToDate":
        return {
          headline: current + " is up to date.",
          sub: "Checked " + (when(v.checkedAt) || "just now") + ".",
        };
      case "available":
        return {
          headline: "RichOS " + v.availableVersion + " is available.",
          sub: v.notes ? String(v.notes) : "You are running " + (v.currentVersion || "") + ".",
        };
      case "downloading":
        return {
          headline: "Downloading RichOS " + v.availableVersion + "…",
          // No denominator, no percentage. A bar with an invented total is a lie that looks
          // like a measurement, so a server that sent no Content-Length gets a byte count.
          sub:
            typeof v.percent === "number" && v.totalBytes
              ? bytes(v.downloadedBytes) + " of " + bytes(v.totalBytes)
              : bytes(v.downloadedBytes) + " so far",
        };
      case "installing":
        return {
          headline: "Checking the download and installing…",
          sub: "RichOS is confirming this update was signed by us before it puts it in place.",
        };
      case "ready":
        return {
          headline: "RichOS " + v.availableVersion + " is installed.",
          sub: "Restart when you are ready — nothing is lost.",
        };
      case "failed":
        return {
          headline: v.failure ? v.failure.headline : "The update did not complete.",
          sub: "You are still running RichOS " + (v.currentVersion || "") + ".",
        };
      default:
        return { headline: current, sub: "RichOS cannot tell what state the update is in." };
    }
  }

  function isSignature(v) {
    return !!(v && v.failure && v.failure.kind === "signature");
  }

  // ---- the row ------------------------------------------------------------------------------

  function el(tag, cls, attrs) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    for (var k in attrs || {}) n.setAttribute(k, attrs[k]);
    return n;
  }

  /// Build the row's DOM once per container. `settings-button.js` throws the menu away and
  /// rebuilds it on a forced-dark flip, so "once" is per container, not once ever.
  function build(container) {
    container.textContent = "";

    // `.set-name` is the menu's own row-label class, and carrying it is not cosmetic:
    // `appearance.js`'s `menuRows` reads `.set-name` to assert the menu's order, so a row
    // without it would report its whole body as its name. It also inherits the menu's
    // typography instead of restating it.
    var title = el("p", "set-name update-title");
    title.textContent = "Updates";

    var line = el("p", "update-line", { id: "update-line", role: "status", "aria-live": "polite" });
    var sub = el("p", "update-sub", { id: "update-sub" });

    var progress = el("div", "update-progress", {
      id: "update-progress",
      role: "progressbar",
      "aria-valuemin": "0",
      "aria-valuemax": "100",
      "aria-label": "Downloading the update",
    });
    progress.hidden = true;
    var fill = el("div", "update-progress-fill", { id: "update-progress-fill" });
    progress.appendChild(fill);

    var actions = el("div", "update-actions");
    var check = el("button", "update-btn", { id: "update-check", type: "button" });
    var install = el("button", "update-btn update-btn--go", { id: "update-install", type: "button" });
    install.hidden = true;
    install.textContent = "Download and install";
    var relaunch = el("button", "update-btn update-btn--go", { id: "update-relaunch", type: "button" });
    relaunch.hidden = true;
    relaunch.textContent = "Restart to finish";
    actions.appendChild(check);
    actions.appendChild(install);
    actions.appendChild(relaunch);

    var why = el("button", "update-why", {
      id: "update-why",
      type: "button",
      "aria-expanded": "false",
      "aria-controls": "update-detail",
    });
    why.hidden = true;
    why.textContent = "Show the technical reason";
    var detail = el("pre", "update-detail", { id: "update-detail" });
    detail.hidden = true;
    var endpoint = el("p", "update-endpoint", { id: "update-endpoint" });
    endpoint.hidden = true;

    container.appendChild(title);
    container.appendChild(line);
    container.appendChild(sub);
    container.appendChild(progress);
    container.appendChild(actions);
    container.appendChild(why);
    container.appendChild(detail);
    container.appendChild(endpoint);

    check.addEventListener("click", function () {
      call("update_check");
    });
    install.addEventListener("click", function () {
      call("update_install");
    });
    relaunch.addEventListener("click", function () {
      // Never returns on the real shell — the process is replaced.
      call("update_relaunch");
    });
    why.addEventListener("click", function () {
      var open = detail.hidden === false;
      detail.hidden = open;
      why.setAttribute("aria-expanded", String(!open));
      why.textContent = open ? "Show the technical reason" : "Hide the technical reason";
    });

    nodes = {
      container: container,
      line: line,
      sub: sub,
      progress: progress,
      fill: fill,
      check: check,
      install: install,
      relaunch: relaunch,
      why: why,
      detail: detail,
      endpoint: endpoint,
    };
  }

  function paint() {
    if (!nodes || !view) return;
    var v = view;
    var s = sentences(v);

    nodes.container.setAttribute("data-update-state", v.state);
    // The failure KIND is on the container too, so a stylesheet or a test can tell a refused
    // signature from a dropped connection without parsing prose.
    if (v.state === "failed" && v.failure) {
      nodes.container.setAttribute("data-update-failure", v.failure.kind);
    } else {
      nodes.container.removeAttribute("data-update-failure");
    }

    nodes.line.textContent = s.headline;
    nodes.sub.textContent = s.sub;
    nodes.sub.hidden = !s.sub;

    var downloading = v.state === "downloading" || v.state === "installing";
    nodes.progress.hidden = !downloading;
    if (downloading) {
      var pct = typeof v.percent === "number" ? Math.max(0, Math.min(100, v.percent)) : null;
      if (pct === null) {
        // Indeterminate: the fill sweeps rather than claiming a position, and the accessible
        // value is REMOVED rather than guessed.
        nodes.progress.setAttribute("data-indeterminate", "true");
        nodes.progress.removeAttribute("aria-valuenow");
        nodes.fill.style.width = "100%";
      } else {
        nodes.progress.removeAttribute("data-indeterminate");
        nodes.progress.setAttribute("aria-valuenow", String(pct));
        nodes.fill.style.width = pct + "%";
      }
    }

    var canAct = !busy && v.state !== "checking" && !downloading;
    // "Check" disappears where it would be the wrong thing to press: with an update waiting
    // or installed, the next act is not another check.
    nodes.check.hidden = v.state === "available" || v.state === "ready";
    nodes.check.disabled = !canAct || v.state === "unconfigured";
    nodes.check.textContent = v.state === "failed" && !isSignature(v) ? "Try again" : "Check for updates";

    nodes.install.hidden = v.state !== "available";
    nodes.install.disabled = !canAct;

    nodes.relaunch.hidden = v.state !== "ready";
    nodes.relaunch.disabled = !canAct;

    var detail = v.failure ? v.failure.detail : "";
    nodes.why.hidden = !detail;
    if (!detail) {
      nodes.detail.hidden = true;
      nodes.why.setAttribute("aria-expanded", "false");
      nodes.why.textContent = "Show the technical reason";
    } else {
      nodes.detail.textContent = detail;
    }

    // Shown whenever it is NOT the shipped default, so a build pointed at a staging manifest
    // or at a test server says so on screen instead of in a log nobody opens.
    if (v.endpoint && !v.endpointIsPlaceholder) {
      nodes.endpoint.hidden = false;
      nodes.endpoint.textContent = "Update server: " + v.endpoint;
    } else {
      nodes.endpoint.hidden = true;
    }

    marker(v);
    cue(v);
  }

  /// The mark on the settings button. It exists for exactly two states, something to install
  /// and something to restart into, and for nothing else: a button that is permanently marked
  /// is a button nobody reads. It is never the ONLY signal; the row says the same thing in
  /// words, and since 2026-09-04 the CUE below says it in words WITHOUT the menu being opened.
  ///
  /// The mark is kept rather than retired now that the cue exists, and the redundancy is
  /// deliberate: the mark is painted ON the settings button, so it survives anything that
  /// suppresses a sibling element, and it is the signal that says "the thing you want is
  /// inside THIS menu" once the cue has been pressed and the menu is open over it.
  function marker(v) {
    var btn = document.getElementById("set-btn");
    if (!btn) return;
    var want = v.state === "available" ? "available" : v.state === "ready" ? "ready" : "";
    var dot = btn.querySelector(".update-mark");
    if (!want) {
      if (dot) dot.remove();
      btn.removeAttribute("data-update-mark");
      return;
    }
    if (!dot) {
      dot = el("span", "update-mark", { "aria-hidden": "true", id: "update-mark" });
      btn.appendChild(dot);
    }
    btn.setAttribute("data-update-mark", want);
  }

  // ---- the cue -------------------------------------------------------------------------
  //
  // THE ANNOUNCEMENT, IN CHROME THE CEO IS ALREADY LOOKING AT.
  //
  // CEO ruling §26, the placement paragraph added 2026-09-04, in his words: *"the user can't
  // be bothered to hunt for some update button somewhere."* Everything above this line
  // renders into a row of the universal settings menu, which means a waiting update was
  // discoverable only by someone who opened that menu — and nothing gave them a reason to.
  // An update nobody discovers is the same as no updater at all, and worse than none,
  // because the machinery reports itself healthy.
  //
  // THE PROPERTY THAT MATTERS IS THAT IT IS TRANSIENT, NOT THAT IT IS VISIBLE. With nothing
  // to install there is NO CONTROL AT ALL here — not a dimmed one, not an "up to date" state,
  // not a placeholder. The element is removed from the document. The signal is the
  // APPEARANCE of something that was not there a moment ago; a permanent control that
  // occasionally changes color is one an eye learns to stop seeing. (The reference the CEO
  // supplied is Codex, captured 2026-09-04 and kept privately in richos-hq: with no update
  // pending that slot in its bottom bar holds an ordinary help control, and the blue download
  // circle exists only while an update is waiting.)
  //
  // WHERE IT SITS, AND WHY THERE. Inside `.settings` — the wrapper of the universal settings
  // button, which §15 puts "ALWAYS EVERYWHERE ON EVERY PAGE" and which `settings-button.js`
  // mounts against `document.body` at a fixed position above every overlay. That single
  // choice buys every surface at once: the shell, an open thread, the home screen, the
  // opening screen, and anything added later. The rail's footer was the closer analogue to
  // the reference's bottom bar and was rejected on two measurements rather than on taste:
  // the rail is `display: none` under `body.rail-closed`, which is reachable at any width
  // below 1180px, so the affordance would be behind a toggle — the one thing the ruling
  // forbids — and the rail's default width is 300px, which cannot hold a label that names a
  // version without truncating it.
  //
  // THIS FILE DOES NOT FORK THE FLOW. The cue carries no state of its own, issues no command,
  // and writes no sentence: its label is `sentences(v).headline`, the SAME string the row
  // renders, so the two can never disagree. Pressing it opens the menu the row lives in and
  // puts the hand on the row's own control. Everything that decides anything — the install,
  // the restart, the refused signature that is never offered a retry — stays in the row.
  //
  // WHICH STATES, AND WHY NOT THE OTHERS. Exactly `available` and `ready`: the two states
  // where something is waiting on the CEO, which is the same pair `marker()` has always used
  // and is therefore one rule rather than two that agree most of the time.
  //   * `downloading` / `installing` — the operation is under way and nothing is waiting on
  //     him. It can only have been started from the row, which is open in front of him and
  //     which owns the progress bar. A second progress readout in the chrome would be the
  //     fork this file exists not to make.
  //   * `failed` — deliberately NOT announced here, and this is the one gap worth naming
  //     rather than hiding. The failure headlines `updates.rs` writes are whole sentences
  //     ("This download was not signed by RichOS, so it was not installed."); a pill wide
  //     enough to carry one is a banner, and §26 asks for the opposite of a banner. A failure
  //     is still stated in full in the row, exactly as it was before this cue existed, so
  //     nothing regressed — but a failure that happens with the menu shut is still quiet, and
  //     what failure should look like in chrome is one of the things the CEO's reference does
  //     not answer.
  //
  // MODE 1 (install with no click at all) IS NOT PRESUPPOSED ANYWHERE HERE. §26 makes it the
  // default and the CEO ruled on 2026-09-04 that hands-free updating waits for a design
  // session of its own. The cue announces and leads; it never starts anything.

  var SVG_NS = "http://www.w3.org/2000/svg";

  /// A stroked glyph in the pill. `stroke: currentColor` so it is the label's own ink and
  /// cannot drift from it — one value to prove, not two.
  function glyph(paths) {
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", "update-cue-glyph");
    for (var i = 0; i < paths.length; i++) {
      var p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", paths[i]);
      svg.appendChild(p);
    }
    return svg;
  }

  // An arrow coming down into a tray, and the restart arc. Two glyphs because the two states
  // ask for two different things — but the WORDS carry the difference as well, so a
  // monochrome display or a reader who does not parse iconography loses nothing.
  var GLYPH = {
    available: ["M12 3.5v10.5", "M7.5 10 12 14.5 16.5 10", "M4.5 19.5h15"],
    ready: ["M20 12a8 8 0 1 1-2.35-5.66", "M20 3.5v5h-5"],
  };

  function cue(v) {
    var host = document.getElementById("settings");
    if (!host) return;
    var node = document.getElementById("update-cue");
    var want = v && (v.state === "available" || v.state === "ready") ? v.state : "";

    // NO UPDATE, NO ELEMENT. Removed from the document, not hidden and not disabled.
    if (!want) {
      if (node) node.remove();
      return;
    }

    if (!node) {
      node = el("button", "update-cue", {
        id: "update-cue",
        type: "button",
        "aria-haspopup": "true",
      });
      node.addEventListener("click", openTheRow);
      // FIRST child, so the pill grows leftward and the settings button never moves. The
      // right edge of this cluster is fixed chrome; a control that shifts under the pointer
      // when an update arrives is a control that gets mis-clicked.
      host.insertBefore(node, host.firstChild);
    }

    if (node.getAttribute("data-update-cue") !== want) {
      node.textContent = "";
      node.appendChild(glyph(GLYPH[want]));
      node.appendChild(el("span", "update-cue-label", { id: "update-cue-label" }));
      node.setAttribute("data-update-cue", want);
    }
    // The ROW's own sentence, not a second one. "RichOS 0.1.2 is available." — the version is
    // named, which is the one place this is deliberately better than the reference, whose
    // button says only "Update" and never says which.
    var said = sentences(v).headline;
    node.lastChild.textContent = said;
    // A BUTTON'S NAME SHOULD SAY WHAT PRESSING IT DOES, and the visible label is a statement
    // rather than an act — so the accessible name is the statement PLUS the act. It starts
    // with the visible text verbatim, which is what WCAG 2.5.3 "Label in Name" asks for: a
    // voice user who says the words on the screen still reaches this control.
    node.setAttribute("aria-label", said + " Open the update settings.");
  }

  /// Press the cue: open the menu the row lives in, and put the hand on the row's control.
  ///
  /// The focus is DEFERRED by design. `RichSettings.open()` calls our own `onOpen()`, which
  /// re-reads `update_state` and marks the surface busy while it is in flight — so for the
  /// length of that read the row's button is disabled and cannot take focus. One turn of the
  /// task queue later the answer has landed and the button is live. A synchronous focus here
  /// would silently do nothing.
  function openTheRow() {
    var s = window.RichSettings;
    if (!s || !s.openMenu) return;
    s.openMenu();
    setTimeout(function () {
      var go = document.getElementById("update-install");
      if (!go || go.hidden) go = document.getElementById("update-relaunch");
      if (go && !go.hidden) go.focus();
    }, 0);
  }

  // ---- talking to the shell --------------------------------------------------------------

  function apply(next) {
    if (!next || typeof next !== "object") return;
    view = next;
    paint();
  }

  async function call(cmd) {
    var b = window.RichBridge;
    if (!b) return null;
    busy = true;
    paint();
    try {
      var out = await b.invoke(cmd);
      apply(out);
      return out;
    } catch (e) {
      // A command that throws is itself a failure state, reported as one rather than leaving
      // the row frozen on "Checking…".
      apply({
        state: "failed",
        currentVersion: view ? view.currentVersion : "",
        availableVersion: view ? view.availableVersion : null,
        notes: null,
        pubDate: null,
        downloadedBytes: 0,
        totalBytes: null,
        percent: null,
        endpoint: view ? view.endpoint : "",
        endpointIsPlaceholder: view ? view.endpointIsPlaceholder : true,
        checkedAt: view ? view.checkedAt : null,
        failure: {
          kind: "other",
          headline: "The update did not complete.",
          detail: String((e && e.message) || e),
        },
      });
      return null;
    } finally {
      busy = false;
      paint();
    }
  }

  // ---- registration --------------------------------------------------------------------------

  var api = {
    /// Fill the row `settings-button.js` built for us. Called on every paint, so it is cheap
    /// on the common path and rebuilds only when the menu itself was rebuilt.
    render: function (container) {
      if (!nodes || nodes.container !== container) build(container);
      paint();
    },
    /// The menu was opened: re-read, because the automatic launch check may have completed
    /// while it was closed.
    onOpen: function () {
      if (window.RichBridge) call("update_state");
    },
    /// The current view, for the browser suites.
    state: function () {
      return view;
    },
  };

  function start() {
    var b = window.RichBridge;
    // NO BRIDGE, NO ROW. On a page with no shell behind it (the opening screen before boot,
    // or a design mock opened on its own) there is nothing that could answer, and a dead
    // update panel that says "not checked" forever is worse than no panel. The capability is
    // simply never registered, and `buildMenu` leaves the row out.
    if (!b) return;
    if (window.RichSettings && window.RichSettings.registerUpdates) {
      window.RichSettings.registerUpdates(api);
    }
    // Every transition the Rust side makes, including the automatic launch check, arrives
    // here — so the mark on the button appears whether or not the menu was ever opened.
    if (b.listen) {
      b.listen("rich://update", function (e) {
        apply(e.payload);
        if (window.RichSettings && window.RichSettings.repaintUpdates) {
          window.RichSettings.repaintUpdates();
        }
      });
    }
    call("update_state");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }

  return api;
})();
