// THE HOME SCREEN — the surface the CEO lands on, and the switch between it and the app UI.
//
// HIS WORDS, 2026-09-01, which are the specification for this file:
//
//   "round-11.1/v1 with the fixed logo is a GO for use in the app now. This start screen/home
//    screen (I'm going to refer to it as the home screen only from now) must be shown in the
//    app after the splash screen. Oh, and there needs to be some way for the user to switch
//    from the home screen to the regular app screen/UI. And in the regular app UI a click on
//    the logo (in the upper left corner) brings the user back to the home screen."
//
//   "At the very top there should be a slim row with buttons named after the user's
//    entities/companies. For RichOS v1 those buttons don't need to do anything."
//
// TERMINOLOGY IS HIS RULING, NOT A PREFERENCE. This surface is the HOME SCREEN, everywhere.
// `splash` stays the name of the curtain that comes before it, and the two are different
// things: the curtain is inert, click-through and gone in three seconds; this is where he
// arrives.
//
// -----------------------------------------------------------------------------------------
// THE ONE CONSTRAINT THIS FILE IS BUILT AROUND: IT MUST NOT SLOW THE LAUNCH DOWN.
//
// The picture is 7,500 objects on WebGL over a 4.9 MB dataset, and the standing rule is a
// logged-in cold start under 500 ms. Those two facts are reconciled by SPLITTING THE SCREEN
// IN TWO, and the split is the whole design:
//
//   * THE COMPOSITION is DOM and CSS and is built SYNCHRONOUSLY, here, at parse time — the
//     ground, the mark, the entity row, the switch. It costs what any other few dozen
//     elements cost and it is in the window's first paint.
//   * THE FIELD is four script tags injected LATER, on an idle callback, never on the boot
//     path. `main.js` is not awaited, not wrapped, not patched; nothing in this file is
//     between the CEO and a usable app. Until the field arrives the round's own "waking
//     loro…" state is what shows, which is the frozen design's own answer to not-ready-yet.
//
// Measured on this machine, WebKit, 1440x900 — see the commit message for the method:
// the four field scripts parse and the picture settles inside the curtain's 3 s hold, and
// app-ready does not move.
//
// LEAVING AND RETURNING ARE CHEAP BY CONSTRUCTION. Nothing is torn down and nothing is
// rebuilt. Switching to the app UI calls the ported engine's `pause()`, which cancels the
// frame loop and leaves every typed array, GL buffer and camera value exactly where it was;
// coming back calls `resume()`, which is one `requestAnimationFrame`. The 4.9 MB is parsed
// once per launch, not once per toggle.
//
// -----------------------------------------------------------------------------------------
// THE GLOBALS THE PORTED FIELD OWNS, named here rather than discovered later:
// `window.VARIANT` (its tuning constants, verbatim from round-11.1/v1), `window.RICHOS_USER`,
// `window.MATURE_LORO` (the synthetic dataset), `window.REF` (the traced picture) and
// `window.__loro` (the engine's own handle, which is also the pause/resume seam). They are
// the round's names and they are kept so the port stays a port.

"use strict";

window.RichHome = (function () {
  // The four files of the ported field, in dependency order. Injected, never in index.html:
  // a `<script src>` in the document is on the parser's critical path and this must not be.
  var FIELD = ["home/field-data.js", "home/field-ref.js", "home/field-prep.js", "home/field-engine.js"];

  // Tuning constants for the picture — VERBATIM from `round-11.1/v1/index.html`, which took
  // them verbatim from `round-6.4/v5`. Not tuned here, and not to be tuned here: this is a
  // port of a design the CEO signed off, and the numbers are part of what he signed off.
  var VARIANT = {
    name: "v1 Constellation",
    constellation: true,
    nodeScale: 1.75,
    leafWhite: 0.7,
    fibreGain: 0.55,
    hairGain: 0.8,
    glow: 0.7,
    packetShare: 0.03,
    riverPackets: 180,
    twinkle: 0.18,
    clickZoom: 1.45,
  };

  // How long after first paint the field is allowed to start loading. `requestIdleCallback`
  // does the right thing on its own — it fires when the main thread is free, which during a
  // launch means after the boot's synchronous work — and the timeout is the floor under it so
  // a busy boot cannot postpone the picture past the curtain. 1200 ms against the curtain's
  // 3000 ms hold leaves 1800 ms for a settle that measures ~850 ms.
  var FIELD_IDLE_TIMEOUT_MS = 1200;

  // The crossfade between the two surfaces. Compositor-only (opacity), and deliberately the
  // least opinionated transition there is: the CEO is choosing the real switch affordance from
  // six designs, and a fade constrains none of them.
  var FADE_MS = 200;

  // THE FIRST-RUN BANNER'S SENTENCE, and it is the CEO's own with one tightening.
  //
  // His words, 2026-09-01, which are the whole specification for it: *"On first launch, the
  // home screen draws synthetic data, yes. Show a small banner in the top right corner saying
  // something like: 'This is what your home screen could look like once Rich gets enough
  // information about you and your business.'"*
  //
  // "Something like" is his own permission to tighten, and exactly one thing is tightened:
  // `gets enough information about` -> `knows enough about`. Five words to three, the same
  // claim, the same plain register. BOTH HALVES OF THE MEANING ARE INTACT and neither is
  // negotiable: what is on the screen is a DEMONSTRATION, and it BECOMES HIS as Rich learns
  // about him and his business.
  //
  // What it deliberately does not say: "sample data", "demo mode", "placeholder", "preview",
  // or anything carrying an asterisk. On an open-source launch this is the first sentence a
  // stranger reads inside RichOS, and it has to sound like Rich rather than like a EULA.
  var NOTE =
    "This is what your home screen could look like once Rich knows enough about you and your business.";

  // The default selection in the entity row. Not the absence of a selection — the CEO was
  // explicit that "all companies" is a STATE and it is the one showing: "switch their loro
  // visual from all companies (which is default) to display the loro for just one".
  var ALL_COMPANIES = "";

  // WHAT THAT BUTTON SAYS, and the word that is gone is the point. CEO, 2026-09-02:
  // *"Note: I removed the word 'companies' from the 'All companies' button."*
  var ALL_LABEL = "All";

  var root = null;
  var appEl = null;
  var fieldStarted = false;
  var fadeTimer = null;

  /// What this surface knows about itself. Read by the acceptance suite; never by the CEO.
  var state = {
    /// `true` while the home screen is the surface in front.
    open: false,
    /// `"loading" | "live" | "degraded"` — the picture's own state, which is not the
    /// screen's: the screen is up and usable in all three.
    field: "loading",
    /// Why the picture is not live, in one sentence, or `null`. Never swallowed.
    fieldError: null,
    /// The entity id selected in the top row, or `""` for the default "All companies".
    entity: ALL_COMPANIES,
    /// Where the entity names came from: `"registry"` once the backend has answered,
    /// `"unanswered"` before that, `"unavailable"` if the call failed. A hardcoded list is
    /// not one of the options, which is the point.
    entitySource: "unanswered",
    /// How many company buttons the row is carrying, the default NOT included.
    entityCount: 0,
    /// Is the picture being drawn from the CUSTOMER'S OWN loro? `false` until a dataset
    /// positively says otherwise — see `fieldDataIsCustomers()`.
    dataIsCustomers: false,
    /// Is the first-run banner up? Exactly `!dataIsCustomers`, kept separately so a test can
    /// catch the two drifting apart rather than assume they cannot.
    noteShown: false,
    /// What the answer was derived FROM, in one word: `"synthetic"` (the dataset says it is),
    /// `"unknown"` (no dataset has loaded, or it does not say), `"customer"` (it says it is
    /// his). Never a guess with no name on it.
    dataSource: "unknown",
  };

  // =========================================================================================
  // BUILDING THE COMPOSITION — synchronous, no I/O, no awaits.
  // =========================================================================================

  function elem(tag, cls, attrs) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (attrs) {
      for (var k in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, k)) e.setAttribute(k, attrs[k]);
      }
    }
    return e;
  }

  /// The v3.5 wordmark, path data verbatim from
  /// `assets/logo-wordmark/RichOS-logo-wordmark_v3.5_black-and-white.svg`, carrying the
  /// APPROVED treatment from `round-8.1/v0`: `rel r-ink p-ink` on the letterforms and
  /// `rel r-signal p-signal` on the arrow inside the R. The file is authored black-on-white,
  /// so the treatment is what makes it a mark on a midnight ground rather than an inversion.
  ///
  /// `<title>` is not decoration here and must not be removed: it is the accessible name AND
  /// the thing the field renderer's quiet-rectangle pass looks for, because it finds the
  /// chrome it has to hush by text content and an `<svg>` has none without it.
  var MARK_SVG =
    '<svg viewBox="0 0 3299.1 754.5" role="img" aria-labelledby="home-mark-title">' +
    '<title id="home-mark-title">RichOS</title>' +
    '<path class="rel r-ink p-ink" d="M517,744h227l-85.2-120.4c-41.7-58.7-83.3-117.5-124.9-176.2c-0.7-0.9-1.3-1.9-2.3-3.4c2.6-1.3,5.1-2.5,7.6-3.7c26.2-12.9,50.3-28.8,70.8-49.7c29.9-30.6,47-67.6,53.7-109.4c8.3-52.1,2.1-102.4-22.8-149.2C601.2,57.3,539.1,13.7,455.2,1.8c-4.1-0.6-8.1-1.2-12.2-1.8C295.3,0,147.7,0,0,0c0,133.5,0,266.7,0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4c0,3.7,0,9.3,0,13c1-1.6,2.3-5.2,2.9-6.9c19.5-54,47.4-103.2,86.8-145.2c59.3-63.2,132.4-100.6,217.6-115.2c6.4-1.1,9.7,0.4,13.6,5.5"/>' +
    '<path class="rel r-signal p-signal" d="M0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4C0,620.7,0,510.3,0,400z"/>' +
    '<path class="rel r-ink p-ink" d="M809.5,58.3H946v124.2H809.5V58.3z M945.1,744H811.4V241.7h133.7V744z"/>' +
    '<path class="rel r-ink p-ink" d="M1275.5,641.8c55.4,0,88.8-38.2,101.2-89.8l115.6,51.6c-22.9,82.1-101.2,150.9-217.7,150.9c-146.1,0-249.3-106-249.3-261.7c0-154.7,103.1-260.7,249.3-260.7c115.6,0,192,66.8,215.8,148l-113.6,53.5c-12.4-51.6-45.8-89.8-101.2-89.8c-70.7,0-117.5,55.4-117.5,149C1158,587.4,1204.8,641.8,1275.5,641.8z"/>' +
    '<path class="rel r-ink p-ink" d="M1556.3,58.3H1690v234.9c27.7-32.5,73.5-61.1,137.5-61.1c105.1,0,169,71.6,169,180.5V744h-133.7V450.8c0-56.3-22.9-96.5-80.2-96.5c-46.8,0-92.6,33.4-92.6,99.3V744h-133.7V58.3z"/>' +
    '<path class="rel r-ink p-ink" d="M2398.6,47.8c188.1,0,323.7,146.1,323.7,353.4s-135.6,353.4-323.7,353.4c-189.1,0-324.7-146.1-324.7-353.4S2209.5,47.8,2398.6,47.8z M2398.6,171c-107.9,0-183.4,89.8-183.4,230.2c0,140.4,75.4,230.2,183.4,230.2c107,0,182.4-89.8,182.4-230.2C2581,260.8,2505.5,171,2398.6,171z"/>' +
    '<path class="rel r-ink p-ink" d="M2836,525.3c50.6,71.6,124.2,111.7,199.6,111.7c71.6,0,124.2-31.5,124.2-89.8c0-63-64.9-71.6-168.1-94.5c-102.2-23.9-213-56.3-213-192c0-130.8,112.7-213,255-213c118.4,0,211.1,52.5,258.8,121.3l-92.6,90.7c-40.1-56.3-93.6-94.5-170-94.5c-66.9,0-112.7,32.5-112.7,82.1c0,53.5,49.7,64,139.4,84c108.9,23.9,242.6,51.6,242.6,201.5c0,138.5-122.2,221.6-268.4,221.6c-115.6,0-235.9-52.5-291.3-135.6L2836,525.3z"/>' +
    "</svg>";

  function build() {
    var r = elem("div", null, { id: "home" });

    r.appendChild(elem("div", null, { id: "home-bg" }));

    var stage = elem("div", null, { id: "home-stage" });
    stage.appendChild(elem("canvas", null, { id: "home-bokeh" }));
    stage.appendChild(elem("canvas", null, { id: "home-gl" }));
    stage.appendChild(elem("canvas", null, { id: "home-overlay" }));
    r.appendChild(stage);

    r.appendChild(elem("div", null, { id: "home-grain" }));

    r.appendChild(buildEntities());

    // The top-left block. The engine fills `#home-owner`, `#home-brand-line` and
    // `#home-signals`; the mark is ours because it is static.
    var brand = elem("header", null, { id: "home-brand" });
    var mark = elem("div", "mark");
    mark.innerHTML = MARK_SVG;
    brand.appendChild(mark);
    brand.appendChild(elem("div", "owner", { id: "home-owner" }));
    brand.appendChild(elem("div", "sub", { id: "home-brand-line" }));
    r.appendChild(brand);
    r.appendChild(elem("section", null, { id: "home-signals" }));

    // APP: the first-run banner, at the top of the right column and therefore before the
    // aside in the DOM. Neither overlaps the other — see `--home-note-inset` — so this is
    // reading order rather than paint order.
    r.appendChild(buildNote());

    var live = elem("aside", null, { id: "home-live" });
    var cap = elem("div", "cap");
    cap.textContent = "Working now";
    live.appendChild(cap);
    live.appendChild(elem("ul", null, { id: "home-working" }));
    live.appendChild(elem("div", "ticker", { id: "home-ticker" }));
    r.appendChild(live);

    r.appendChild(buildSwitch());

    r.appendChild(elem("div", null, { id: "home-debug" }));

    var loading = elem("div", null, { id: "home-loading" });
    loading.appendChild(elem("div", "pulse"));
    var txt = elem("div", "txt");
    txt.textContent = "waking loro…";
    loading.appendChild(txt);
    r.appendChild(loading);

    return r;
  }

  // -----------------------------------------------------------------------------------------
  // APP: THE FIRST-RUN BANNER — and the condition is the important half of it.
  //
  // THE CONDITION IS DERIVED FROM THE DATA THAT IS BEING DRAWN. Not a launch counter, not a
  // "first run" flag somebody sets, not a preference: those all drift away from the truth the
  // moment anything else changes, and the failure they produce is the one that matters here —
  // a screen telling a customer that a picture is his when it is not.
  //
  // The dataset says so itself. `home/field-data.js` opens with
  // `window.MATURE_LORO = {"meta":{"name":"RichOS synthetic mature loro","version":1,
  // "synthetic":true, ...`, and `home/field-engine.js:99` is `const loro = window.MATURE_LORO;`
  // — so the object this reads IS the object the picture is drawn from, not a proxy for it.
  //
  // POSITIVE SIGNAL ONLY, which is the same discipline the continuity design requires of crash
  // detection (`docs/plans/richos-session-continuity-2026-08-24.md` §5.2: a positive
  // termination signal, never an inference from silence). The answer is "his" only when a
  // dataset SAYS it is his. No dataset yet — which is the state at first paint, because the
  // field loads on an idle callback — is not "his". A dataset that simply omits the flag is
  // not "his" either. The banner stays up through every uncertainty, and only a positive
  // `"synthetic": false` takes it down.
  //
  // THE SEAM THAT DOES NOT EXIST YET, NAMED PRECISELY BECAUSE IT IS NOT BUILT.
  //
  // Nothing in this product compiles a customer's own loro corpus into the shape the field
  // consumes, so today this function returns `false` on every launch on every machine — the
  // CEO's included — and the banner is always up. That is honest rather than convenient: the
  // picture on his screen right now IS the synthetic corpus.
  //
  // What would close it: the Rust side already HAS the corpus. `richos_core::loro::
  // CliContextCompiler` is wired in `app/src-tauri/src/memory.rs:87` (`wire_company_memory`)
  // and `memory_status` (`app/src-tauri/src/main.rs:2010`) already reports whether one is
  // provisioned. What is missing is a command — call it `home_field_data` — that compiles that
  // corpus into the `{meta, nodes, links, sources, ...}` structure `home/field-*.js` reads,
  // and stamps its `meta` with `"synthetic": false` plus the corpus root it came from.
  // `startField()` would prefer its answer over the baked `field-data.js`, and this function
  // would go from `false` to `true` with no other change anywhere: the banner would take
  // itself down, `--home-note-inset` would go to `0px`, and the composition would be the
  // frozen round's again.
  //
  // NOTE WHAT IS NOT PROPOSED: gating on `memory_status`. A provisioned corpus is not the same
  // fact as a drawn picture, and a banner that vanished the moment a customer created a folder
  // would be claiming his data was on screen while 7,500 synthetic objects were still on it.
  // That is precisely the lie this element exists to prevent.
  // -----------------------------------------------------------------------------------------

  function buildNote() {
    // `role="status"` and not `role="alert"`: it is a standing statement about what is on the
    // screen, not an interruption. `aria-live` is deliberately absent for the same reason —
    // the sentence is there when the screen is, so there is no change to announce.
    var box = elem("aside", null, { id: "home-note", role: "status" });
    var line = elem("p", null, { id: "home-note-line" });
    line.textContent = NOTE;
    box.appendChild(line);
    return box;
  }

  /// Is the picture being drawn from the CUSTOMER'S OWN loro, or from a demonstration?
  /// See the section header above for why this is positive-signal-only and what the missing
  /// seam is. Returns `false` for "not his, or nobody has said".
  function fieldDataIsCustomers() {
    var d = window.MATURE_LORO;
    var meta = d && d.meta;
    if (!meta) return false;
    // `=== false` rather than `!== true`: a dataset that forgets to say is not evidence.
    return meta.synthetic === false;
  }

  /// Raise or drop the banner from the dataset that is actually loaded, and reserve the space
  /// the top-right column needs for it. Safe to call at any time and as often as wanted.
  function refreshNote() {
    if (!root) return;
    var box = root.querySelector("#home-note");
    if (!box) return;

    var meta = window.MATURE_LORO && window.MATURE_LORO.meta;
    state.dataIsCustomers = fieldDataIsCustomers();
    state.dataSource = state.dataIsCustomers ? "customer" : meta && meta.synthetic === true ? "synthetic" : "unknown";
    box.hidden = state.dataIsCustomers;
    state.noteShown = !box.hidden;

    reserveNoteInset();
  }

  /// Push the top-right aside down by exactly the height the banner turned out to need.
  ///
  /// MEASURED, never a constant: the sentence wraps, and how many lines it wraps to depends on
  /// the window width and on the face that ended up loading. The measurement is the TEXT's own
  /// box (`#home-note-line`), not the banner's, because the banner's box carries 14px of
  /// padding on each side that the wash needs and the layout must not pay for twice.
  ///
  /// 26px is the clear space between the sentence's last line and the aside's "Working now"
  /// cap — one line of the aside's own 16px/1.75 leading, rounded to the composition's rhythm.
  function reserveNoteInset() {
    if (!root) return;
    var box = root.querySelector("#home-note");
    var line = root.querySelector("#home-note-line");
    // FROM THE SENTENCE'S REAL BOTTOM EDGE, not from its height. `#home-note`'s `top` is a
    // `max()` — it is normally the aside's own line, but on a one-line entity row that line is
    // 1px under the settings button, so the clamp pushes it down. A reservation computed from
    // the height alone would not know that had happened and the aside would ride up into the
    // banner by exactly the clamp's distance.
    //
    // `#home` is `position: fixed; inset: 0`, so its box and the viewport's are the same and
    // the rect below needs no conversion. 32px is `#home-live`'s own offset, declared six rules
    // above the banner in `home.css`; 26px is the clear space under the sentence.
    var h = box && !box.hidden && line ? line.getBoundingClientRect().height : 0;
    var next = "0px";
    if (h > 0) {
      var base = 32 + (parseFloat(getComputedStyle(root).getPropertyValue("--home-top-inset")) || 0);
      next = Math.max(0, Math.round(line.getBoundingClientRect().bottom + 26 - base)) + "px";
    }

    // IT ONLY SPEAKS WHEN SOMETHING MOVED, and that is not an optimization — it is the
    // termination condition. This function both LISTENS for `resize` (the sentence re-wraps
    // when the window changes width) and DISPATCHES one (the aside moved, so the field's
    // quiet-rectangle pass has to re-read the layout, which is how `reserveTopInset()` tells
    // it). Dispatching unconditionally made those two the same edge of a cycle: measured, the
    // first launch after that landed the picture at 10402 ms instead of 464 ms and the shell
    // reported `RangeError: Maximum call stack size exceeded`. Comparing first is what makes
    // the recursion depth two — change, notify, re-measure, agree, stop.
    if (root.style.getPropertyValue("--home-note-inset") === next) return;
    root.style.setProperty("--home-note-inset", next);
    try {
      window.dispatchEvent(new Event("resize"));
    } catch (e) {
      /* a webview with no Event constructor would have failed long before here */
    }
  }

  // -----------------------------------------------------------------------------------------
  // THE ENTITY ROW
  //
  // The names come from the REGISTRY (`EntityRegistry::ceos_companies`, reached through the
  // `entity_choice` command the company picker already uses), never from a list typed here.
  // That is the requirement and it is the one with a history: a hardcoded copy is wrong the
  // day he adds a company, and `richos` is ONE entity with two roots, which only the registry
  // knows.
  //
  // The row is built EMPTY-BUT-PRESENT at parse time and filled when the backend answers, so
  // the surface never depends on an async call to exist. Until it answers, the default chip is
  // there on its own and says what is true: he has not been told about any companies yet.
  // -----------------------------------------------------------------------------------------

  function buildEntities() {
    var box = elem("div", null, { id: "home-entities", role: "group", "aria-labelledby": "home-entities-label" });
    var label = elem("span", null, { id: "home-entities-label" });
    label.textContent = "Which company this picture is of";
    box.appendChild(label);
    box.hidden = true; // ...until the backend says he has more than one. See renderEntities().

    // A NAME COMING OUT MAKES THE ROW WIDER, AND THE COMPOSITION SITS ON THE ROW'S HEIGHT.
    // Measured, his longest name leaves the row on one line — but a customer's could not, and
    // a row that silently wrapped would leave the picture 33px too high until the next resize.
    // `transitionend` bubbles from the pill that grew, so this is the moment the new width is
    // real rather than a guess at when the animation ended.
    box.addEventListener("transitionend", function (e) {
      if (e.propertyName === "width") reserveTopInset();
    });
    return box;
  }

  /// A company's button: TWO labels in one pill, and only one of them showing.
  ///
  /// `rest` is what it says out of the box — its number, or the label the customer typed for
  /// it. `name` is the company's own name, which is what a click brings out. Both are in the
  /// DOM at all times; the pill is only as wide as one of them and clips the other, which is
  /// what makes the reveal a slide rather than a swap.
  ///
  /// THE TRACK'S ORDER IS THE DIRECTION HE ASKED FOR. `[name][number]`, parked one name-width
  /// to the left, so revealing the name means moving the track back toward zero and the name
  /// travels from the pill's left edge to the right — *"the company name slide out (from left
  /// to right) and replace the number on the button"*. The reverse order would run the same
  /// motion backwards.
  function chip(id, rest, name, pressed) {
    var b = elem("button", "home-chip", {
      type: "button",
      "data-entity": id,
      "aria-pressed": pressed ? "true" : "false",
      // BOTH LABELS IN THE ACCESSIBLE NAME. A screen reader announcing "1, button" tells its
      // user nothing about which company that is; announcing only "FemcBoost" would leave the
      // visible label out of the name, which is what SC 2.5.3 is about. `1 FemcBoost` is both.
      "aria-label": rest === name ? name : rest + " " + name,
    });
    var track = elem("span", "home-chip-track");
    var nm = elem("span", "home-chip-name");
    nm.textContent = name;
    var num = elem("span", "home-chip-rest");
    num.textContent = rest;
    track.appendChild(nm);
    track.appendChild(num);
    b.appendChild(track);
    b.addEventListener("click", function () {
      select(id);
    });
    return b;
  }

  /// `All` — one label, nothing to reveal, and therefore no track to move. A separate builder
  /// rather than a branch inside `chip()`, because a chip carrying its own label twice so the
  /// slide has something to slide would put the same string in the accessibility tree twice.
  function plainChip(id, label, pressed) {
    var b = elem("button", "home-chip plain", {
      type: "button",
      "data-entity": id,
      "aria-pressed": pressed ? "true" : "false",
    });
    var track = elem("span", "home-chip-track");
    var num = elem("span", "home-chip-rest");
    num.textContent = label;
    track.appendChild(num);
    b.appendChild(track);
    b.addEventListener("click", function () {
      select(id);
    });
    return b;
  }

  /// MEASURE THE TWO LABELS, because the pill's width is one of them and the slide's distance
  /// is the other, and neither can be guessed: they depend on the string, on the vendored face
  /// and on whether that face has finished loading.
  ///
  /// The spans are `flex: 0 0 auto` inside a track the pill clips, so each one reports its own
  /// natural width whatever the pill is currently set to — which is what makes this measurable
  /// at all rather than a chicken-and-egg.
  function measureChips() {
    if (!root) return;
    var chips = root.querySelectorAll(".home-chip");
    for (var i = 0; i < chips.length; i++) {
      var rest = chips[i].querySelector(".home-chip-rest");
      var name = chips[i].querySelector(".home-chip-name");
      if (rest) chips[i].style.setProperty("--sw-rest", rest.getBoundingClientRect().width.toFixed(2) + "px");
      if (name) chips[i].style.setProperty("--sw-name", name.getBoundingClientRect().width.toFixed(2) + "px");
    }
  }

  /// Set the selection, WHICH IS ALSO THE REVEAL.
  ///
  /// This function does not touch a label, a width or a transition. `aria-pressed` is the only
  /// thing it moves, and `home.css` hangs the whole slide off that one attribute — so the rule
  /// "the company whose name is out is the company that is picked" is not a rule anybody has
  /// to maintain, it is the same fact written once. `iris-opus-row1` is designing what this
  /// should really be; whatever she lands, it changes that selector and this function and
  /// nothing else.
  ///
  /// THE EFFECT ON THE PICTURE IS DELIBERATELY ABSENT (CEO: "For RichOS v1 those buttons don't
  /// need to do anything") — but everything else about the control is real: it carries its
  /// entity id, it presses, it is a single-select group, and it reports on `RichHome.state`.
  /// Filtering the field by entity drops in HERE and changes nothing else.
  function select(id) {
    if (!root) return;
    state.entity = id;
    var chips = root.querySelectorAll(".home-chip");
    for (var i = 0; i < chips.length; i++) {
      chips[i].setAttribute("aria-pressed", chips[i].getAttribute("data-entity") === id ? "true" : "false");
    }
  }

  /// Read the row from the backend. One command, `home_entity_row`, which resolves the
  /// REGISTRY against his two preferences (the label he chose, and whether the company shows)
  /// and hands back the answer already resolved — so no surface has to know that an absent
  /// override means the registry's name.
  function loadEntities() {
    var bridge = window.RichBridge;
    if (!bridge || typeof bridge.invoke !== "function") {
      state.entitySource = "unavailable";
      renderEntities([]);
      return Promise.resolve([]);
    }
    return bridge
      .invoke("home_entity_row")
      .then(function (rows) {
        state.entitySource = "registry";
        renderEntities(rows || []);
        return rows || [];
      })
      .catch(function (e) {
        // A row that cannot name his companies says nothing rather than inventing them.
        state.entitySource = "unavailable";
        state.entityError = (e && e.message) || String(e);
        renderEntities([]);
        return [];
      });
  }

  /// Draw the row — or DO NOT DRAW IT AT ALL.
  ///
  /// CEO, 2026-09-01: *"the company buttons should only appear if the user has more than one
  /// company. Not if there's only one."* So the test is on how many companies are VISIBLE to
  /// him, and the answer when it is fewer than two is that the row is ABSENT — not disabled,
  /// not a single lonely button. A row of one is noise, and with the row gone the composition
  /// is exactly the frozen round's, which is a layout somebody already made look deliberate.
  function renderEntities(rows) {
    if (!root) return;
    var box = root.querySelector("#home-entities");
    if (!box) return;

    var visible = [];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].id && rows[i].visible !== false) visible.push(rows[i]);
    }
    state.entityCount = visible.length;
    state.entityTotal = rows.length;

    var old = box.querySelectorAll(".home-chip");
    for (var j = 0; j < old.length; j++) old[j].remove();

    if (visible.length < 2) {
      box.hidden = true;
      state.entityRowShown = false;
      // A selection that pointed at a company he has just hidden would leave the picture
      // filtered to something with no control on screen. Back to the default.
      state.entity = ALL_COMPANIES;
      reserveTopInset();
      return;
    }

    box.hidden = false;
    state.entityRowShown = true;
    // THE DEFAULT IS A STATE, NOT AN ABSENCE (CEO: "all companies (which is default)").
    box.appendChild(plainChip(ALL_COMPANIES, ALL_LABEL, state.entity === ALL_COMPANIES));
    state.entityLabels = [];
    for (var k = 0; k < visible.length; k++) {
      var id = String(visible[k].id);
      // WHAT IT SAYS AT REST is the number it is in the row — his ruled default for everyone —
      // unless the customer has typed a label for it, in which case that is what he wanted the
      // button to say and it is what it says. The numbering follows the row, so it is over the
      // companies that are SHOWN and not over the registry: hide one and the rest close up.
      var custom = visible[k].custom_label ? String(visible[k].custom_label).trim() : "";
      var rest = custom || String(k + 1);
      // WHAT A CLICK REVEALS is the company's own name from the registry. Not `label`, which
      // the backend has already resolved to the override when there is one — that would make
      // the reveal a no-op for exactly the customer who told us what to call it.
      var name = String(visible[k].display_name || visible[k].label || id);
      state.entityLabels.push(rest);
      box.appendChild(chip(id, rest, name, state.entity === id));
    }
    measureChips();
    // If his selection was a company that is no longer in the row, fall back to the default
    // rather than leaving a selection with nothing pressed.
    if (state.entity !== ALL_COMPANIES && !box.querySelector('.home-chip[aria-pressed="true"]')) {
      select(ALL_COMPANIES);
    }
    reserveTopInset();
  }

  /// Push the round's composition down by exactly the height the entity row turned out to
  /// need. MEASURED, not a constant times a guessed row count: the row wraps, and how many
  /// lines it wraps to depends on the window width, on how many companies he shows, and on
  /// how long he has made their labels.
  ///
  /// With the row absent — one company, or none — the inset is ZERO and the composition is
  /// the frozen round's, pixel for pixel.
  function reserveTopInset() {
    if (!root) return;
    var box = root.querySelector("#home-entities");
    var h = box && !box.hidden ? box.getBoundingClientRect().height : 0;
    // 22px is the row's own top offset; 16px is the clear space under it; 30px is where the
    // round already puts the mark, which the inset is measured relative to.
    var inset = h > 0 ? Math.round(22 + h + 16 - 30) : 0;
    root.style.setProperty("--home-top-inset", Math.max(0, inset) + "px");
    // The field hushes itself under the chrome by reading those elements' rectangles. They
    // just moved, so tell it — `resize` is the engine's own "re-read the layout" signal and
    // using it keeps this file from reaching into the engine's internals.
    try {
      window.dispatchEvent(new Event("resize"));
    } catch (e) {
      /* a webview with no Event constructor would already have failed long before here */
    }
  }

  // -----------------------------------------------------------------------------------------
  // THE DOOR — `round-11.2/v1`'s sill, in the left column. RULED, no longer provisional.
  //
  // Ruled by the owner, 2026-09-02, in three parts: NOTHING may cover the spectacle of the home
  // screen — every door that did was rejected on that ground alone; the `round-11.2/v1` button
  // goes in the LEFT COLUMN under "your attention saved", with the label "Talk to Rich"; and
  // directly under it sits the word "Enter", in V1's own type, because the key must work as well
  // as the button. A later clarification scoped "nothing can cover it" to the company buttons
  // and the door. The ruling's own wording is in the private record (`wiki/ceo-decisions.md`).
  //
  // THE CAPTION IS A PROMISE, NOT A DECORATION. `Enter` under the button says the key works, so
  // the key has to work from anywhere on this screen and not only when the button happens to
  // hold focus — that is `onHomeKey()` below. A caption that were only true for the focused
  // control would be the kind of small lie this screen exists not to tell.
  //
  // The bottom-centered pill this replaces is gone. A SWAP STILL TOUCHES TWO THINGS: this
  // function, and the `#home-switch` / `#home-enter` block in `home.css`.
  //
  // THE DOT IS CARRIED FROM THE MOCKUP AND CARRIES NOTHING. `round-11.2/v1` describes it as
  // "one breathing gold dot for the live thing"; nothing in this app feeds it, so it is
  // `aria-hidden` presence and not a count. Kept because the CEO named that button and asked
  // for its treatment rather than a redesign of it — flagged here because wiring it to
  // `get_worker_status` is one line, and so is deleting it.
  // -----------------------------------------------------------------------------------------

  var DOOR_LABEL = "Talk to Rich";
  var DOOR_CAPTION = "Enter";

  function buildSwitch() {
    var box = elem("div", null, { id: "home-switch" });

    var b = elem("button", null, {
      id: "home-enter",
      type: "button",
      // The caption's claim, said to assistive technology too.
      "aria-keyshortcuts": "Enter",
    });
    b.appendChild(elem("span", "dot", { "aria-hidden": "true" }));
    var label = elem("span", "home-enter-label");
    label.textContent = DOOR_LABEL;
    b.appendChild(label);
    // NO ARROW. The mockup's sill ends in a `\u2192`; his ruling names the label and nothing
    // else, and the glyph would have been an eighth character on the list of non-ASCII the
    // vendored faces have to carry (§22).
    b.addEventListener("click", function () {
      hide("switch");
    });
    box.appendChild(b);

    var cap = elem("p", null, { id: "home-door-cap" });
    cap.textContent = DOOR_CAPTION;
    box.appendChild(cap);

    return box;
  }

  /// Enter leaves. Bound while the home screen is up and removed when it is not.
  ///
  /// FOUR THINGS IT REFUSES TO ACT ON, and each is a place Enter already means something:
  /// a modifier is held (that is a different shortcut); the settings menu or the company-buttons
  /// panel has the keystroke (both float ABOVE this surface and own their own Enter); the
  /// keystroke is on a control inside the home screen that already answers it, which is the
  /// case every time the CEO arrives, because `focusHome()` puts focus on the door; or
  /// something else has already handled it.
  function onHomeKey(e) {
    if (!state.open || !e || e.key !== "Enter") return;
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
    var t = e.target;
    if (t && t.closest) {
      if (t.closest(".settings") || t.closest(".home-prefs")) return;
      if (t.closest("#home button, #home a[href], #home input, #home textarea, #home select, #home [tabindex]")) return;
    }
    e.preventDefault();
    hide("enter-key");
  }

  /// Put the door where the left column ends.
  ///
  /// MEASURED FROM `#home-signals`, because that block's height is whatever the field put in
  /// it — five signals today, and the engine owns how tall each one is. 30px is the clear space
  /// under "of your attention saved", which is the rhythm the column already uses between its
  /// own blocks (19px between signals, 11px inside one).
  ///
  /// It returns without writing anything while the signals are still empty, so the door sits on
  /// the CSS fallback — that block's own measured 345px — rather than jumping up to y=282 for
  /// the second and a half before the picture arrives and then back down.
  function reserveDoorTop() {
    if (!root) return;
    var sig = root.querySelector("#home-signals");
    if (!sig) return;
    var r = sig.getBoundingClientRect();
    if (r.height < 1) return;
    var next = Math.round(r.bottom + 30) + "px";
    if (root.style.getPropertyValue("--home-door-top") === next) return;
    root.style.setProperty("--home-door-top", next);
  }

  // =========================================================================================
  // THE FIELD — loaded late, never on the boot path.
  // =========================================================================================

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src;
      s.async = false; // injected scripts still execute in insertion order with this set
      s.onload = function () {
        resolve();
      };
      s.onerror = function () {
        reject(new Error(src + " did not load"));
      };
      document.head.appendChild(s);
    });
  }

  function startField() {
    if (fieldStarted) return;
    // The surface may already be gone: this runs on an idle callback, and a page that has
    // navigated has no home screen to draw into. Loading 5 MB for a document nobody is
    // looking at is the cheapest thing to not do.
    if (!document.getElementById("home")) return;
    fieldStarted = true;

    window.VARIANT = VARIANT;

    // WHOSE NAME IS ON IT. The round hardcoded a name for the mockup; the app asks the store.
    // If nobody has said who this is — which is most installs, because the preference is new —
    // the engine's own fallback renders "for you", which is true, rather than a placeholder.
    var setUser = Promise.resolve(null);
    if (window.RichBridge && typeof window.RichBridge.invoke === "function") {
      setUser = window.RichBridge.invoke("get_appearance").catch(function () {
        return null;
      });
    }

    setUser
      .then(function (appearance) {
        var name = appearance && appearance.user_name;
        if (name && String(name).trim()) window.RICHOS_USER = { name: String(name).trim() };
        var chain = Promise.resolve();
        FIELD.forEach(function (src) {
          chain = chain.then(function () {
            return loadScript(src);
          });
        });
        return chain;
      })
      .then(function () {
        // The engine is an async IIFE: its script having loaded is not the picture being up.
        // `window.__loro` is what it publishes when it is, and it is what is waited on.
        return settled();
      })
      .then(function () {
        state.field = "live";
        // The signal block is only now carrying its five lines, so the left column has a real
        // bottom edge for the first time and the door can sit on it rather than on the
        // fallback.
        reserveDoorTop();
        // THE DATASET IS ONLY NOW ON THE PAGE. Until this line `window.MATURE_LORO` did not
        // exist, so the banner has been up on the honest default ("nobody has said it is
        // his"). Re-derive from what actually loaded: if it ever says it is his, this is where
        // the banner takes itself down.
        refreshNote();
        // If the CEO already left for the app UI while this was loading, the picture must not
        // start burning frames behind an opaque surface.
        if (!state.open && window.__loro && window.__loro.pause) window.__loro.pause();
      })
      .catch(function (e) {
        degrade((e && e.message) || String(e));
      });
  }

  /// Wait for the engine to publish itself, with a ceiling. The ceiling is not politeness: the
  /// engine throws on a machine with no WebGL, and a throw inside its async IIFE is a rejected
  /// promise nobody is holding — so without this the "waking loro…" state would be forever.
  function settled() {
    return new Promise(function (resolve, reject) {
      var deadline = Date.now() + 8000;
      (function poll() {
        if (window.__loro) return resolve();
        if (Date.now() > deadline) return reject(new Error("the picture did not start within 8 seconds"));
        setTimeout(poll, 40);
      })();
    });
  }

  /// THE HONEST FAILURE. A machine with no WebGL, a script that did not load, a shader that
  /// would not compile: the home screen stays up and stays usable, says one true sentence in
  /// Rich's voice, and keeps the way through to the app. It never sits on "waking loro…"
  /// forever and it never pretends the picture is there.
  function degrade(reason) {
    state.field = "degraded";
    state.fieldError = reason;
    if (!root) return;
    var loading = root.querySelector("#home-loading");
    if (!loading) return;
    loading.innerHTML = "";
    var txt = elem("div", "txt");
    txt.textContent = "I couldn't draw the picture on this display. Everything else works.";
    loading.appendChild(txt);
    // The switch has to stay reachable, and the loading layer covers the whole surface, so it
    // stops taking the pointer rather than being removed — the sentence above stays readable.
    loading.style.pointerEvents = "none";
    loading.style.background = "transparent";
    loading.style.alignItems = "center";
    loading.style.justifyContent = "center";
  }

  // =========================================================================================
  // THE SWITCH ITSELF — home screen out, app UI in, and back.
  // =========================================================================================

  function isOpen() {
    return state.open;
  }

  /// Is the opening curtain still on screen? `state.reason` is null until it yields, and
  /// `state.shown` is false when it declined to draw at all — so this is true only while
  /// there is really a curtain up that owns the always-dark clamp.
  function splashStillUp() {
    try {
      var s = window.RichSplash && window.RichSplash.state;
      return !!(s && s.shown && !s.reason);
    } catch (e) {
      return false;
    }
  }

  /// Take the CEO to the regular app UI.
  function hide(reason) {
    if (!root || !state.open) return;
    state.open = false;
    state.lastLeaveReason = reason || null;

    // §15's always-dark clamp is the HOME SCREEN's, not the app's. Dropping it here is what
    // puts a CEO on light mode back on light mode — his preference was never written over.
    //
    // ...UNLESS THE CURTAIN IS STILL UP, and that condition is the whole of a real defect.
    // `forceDark` is one boolean with TWO owners, and dropping it here while the opening
    // screen still holds it would light a curtain that §15 says is always dark. The curtain
    // drops it itself when it yields, and the listener installed in `start()` re-raises it if
    // this screen is still the one in front. Measured: without this clause, `appearance.js`
    // check 4 goes red — "the opening screen is ALWAYS dark, even for a CEO who chose light",
    // expected dark, got light.
    if (window.RichTheme && !splashStillUp()) window.RichTheme.forceDark(false);

    if (appEl) appEl.removeAttribute("inert");
    document.body.classList.remove("home-open");
    document.removeEventListener("focusin", onFocusIn, true);
    document.removeEventListener("keydown", onHomeKey, true);

    root.classList.add("home-leaving");
    if (fadeTimer) clearTimeout(fadeTimer);
    fadeTimer = setTimeout(function () {
      fadeTimer = null;
      root.hidden = true;
      root.classList.remove("home-leaving");
      // Paused AFTER the fade, not before it: stopping the loop first would freeze the picture
      // for the whole 200 ms it is still on screen, which reads as a stall rather than a door.
      if (window.__loro && window.__loro.pause) window.__loro.pause();
    }, FADE_MS);

    // Focus follows the surface. The composer is where work happens in the app UI and is what
    // `main.js` itself focuses at boot, so it is where the CEO's next keystroke should land.
    var composer = document.getElementById("input");
    if (composer && composer.focus) {
      try {
        composer.focus();
      } catch (e) {
        /* a composer that refuses focus is the shell's business, not this file's */
      }
    }
  }

  /// Bring the CEO back to the home screen. This is what the logo in the corner does.
  function show(reason) {
    if (!root || state.open) return;
    state.open = true;
    state.lastEnterReason = reason || null;

    if (fadeTimer) {
      clearTimeout(fadeTimer);
      fadeTimer = null;
    }

    if (window.RichTheme) window.RichTheme.forceDark(true);

    root.hidden = false;
    root.classList.add("home-leaving"); // start transparent...
    document.body.classList.add("home-open");
    if (appEl) appEl.setAttribute("inert", "");
    document.addEventListener("focusin", onFocusIn, true);
    document.addEventListener("keydown", onHomeKey, true);

    // NOTHING IS REBUILT. If the picture was already up it resumes; if the CEO never waited
    // for it the first time, the load is still in flight and finishes on its own.
    if (window.__loro && window.__loro.resume) window.__loro.resume();
    else startField();

    // ...and fade in on the next frame, so the transition has a start state to run from.
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (root) root.classList.remove("home-leaving");
      });
    });

    focusHome();
  }

  function toggle() {
    if (state.open) hide("toggle");
    else show("toggle");
  }

  function focusHome() {
    var b = root && root.querySelector("#home-enter");
    if (b && b.focus) {
      try {
        b.focus({ preventScroll: true });
      } catch (e) {
        b.focus();
      }
    }
  }

  /// While the home screen is up, focus belongs to it. `#app` is `inert`, which handles the
  /// ordinary cases, and this is the belt: `main.js` focuses the composer at the end of its
  /// boot, and a composer that has focus behind an opaque picture is a place the CEO's typing
  /// goes to disappear.
  ///
  /// THE ONE EXCEPTION IS THE SETTINGS BUTTON, and it is the same exception `splash.js` makes
  /// for the same reason: §15 puts it on every screen and its floor is "Bust a bug", so it
  /// floats ABOVE this surface and has to be able to hold focus while it is up.
  function onFocusIn(e) {
    if (!state.open || !root) return;
    var t = e && e.target;
    if (!t || t === document.body || t === document) return;
    if (root.contains(t)) return;
    if (t.closest && t.closest(".settings")) return;
    // ...AND THE COMPANY-BUTTONS PANEL, for exactly the same reason, which this file was
    // missing. `openSettings()` focuses the first label field; `#home-prefs` is appended to
    // `document.body` rather than to `#home`, so `root.contains` is false for everything in it
    // and this listener pulled focus straight back to the door. Measured, driving the real
    // panel: focus landed on the field and was on `#home-enter` before the next keystroke, so
    // the panel he reaches FROM the home screen could not be typed into at all. `page.fill()`
    // hid it from the older checks because it writes the value without holding focus.
    if (t.closest && t.closest(".home-prefs")) return;
    focusHome();
  }

  // =========================================================================================
  // THE WAY BACK — "in the regular app UI a click on the logo (in the upper left corner)
  // brings the user back to the home screen".
  //
  // The mark is already in `index.html` and belongs to the rail. It is PROMOTED to a control
  // here, at runtime, rather than edited there, for two reasons and both are practical: the
  // markup is being changed by someone else this session, and an `<svg role="img">` that has
  // become pressable should say so in the accessibility tree — which is an attribute change,
  // not a markup change. If the id ever moves, the fallback finds it by where it lives.
  // =========================================================================================

  function bindWordmark() {
    var mark = document.getElementById("rail-wordmark") || document.querySelector("#rail-header svg");
    if (!mark) return null;
    mark.setAttribute("role", "button");
    mark.setAttribute("tabindex", "0");
    mark.setAttribute("aria-label", "RichOS — go to the home screen");
    mark.addEventListener("click", function () {
      show("wordmark");
    });
    mark.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
        e.preventDefault();
        show("wordmark-key");
      }
    });
    return mark;
  }


  // =========================================================================================
  // THE SETTINGS FOR THAT ROW — "the user should also be able to customize in the settings the
  // labels on those company buttons and well as which to display on their home screen"
  // (CEO, 2026-09-01).
  //
  // WHY THIS IS A PANEL AND NOT TWELVE ROWS IN THE SETTINGS MENU. That menu's shape is one
  // row, one label, one control on the right, and its own source says why: *"A SELECT AND NOT
  // A RADIO GROUP ... Four stacked radios would be the popover problem again, one row down."*
  // Six companies with a name field and a switch each is a table, and a table does not fit in
  // a popover. So the menu keeps its shape — one row, "Home screen", one button — and the
  // button opens this. It is BESIDE the Company row, which is where he asked for it.
  //
  // WHAT HE SEES WHEN HE ANONYMIZES IT. His stated use is publishing a screenshot, so the
  // anonymized state has to look as considered as the named one. The field is a plain text box
  // with the registry name as its PLACEHOLDER, so an empty box reads as "this is the real
  // name" and never as a blank button — and typing `1` into it is the whole of the operation.
  // Clearing the box puts the real name back.
  //
  // BOTH THEMES. This panel is the one part of the home-screen work that renders OUTSIDE
  // `#home` — it opens from the settings button, which is on every screen, so it can be on
  // screen in light mode over the app UI. It therefore paints in the APP's tokens rather than
  // in the round's, and every one of them is a value `style.css` has already measured.
  // =========================================================================================

  var prefsEl = null;

  function openSettings() {
    if (!prefsEl) {
      prefsEl = buildPrefs();
      document.body.appendChild(prefsEl);
    }
    prefsEl.hidden = false;
    refreshPrefs();
    var first = prefsEl.querySelector(".home-prefs-label");
    if (first && first.focus) first.focus();
  }

  function closeSettings() {
    if (prefsEl) prefsEl.hidden = true;
  }

  function buildPrefs() {
    var wrap = elem("div", "home-prefs", { id: "home-prefs", hidden: "hidden" });

    var scrim = elem("div", "home-prefs-scrim");
    scrim.addEventListener("click", closeSettings);
    wrap.appendChild(scrim);

    var panel = elem("div", "home-prefs-panel", {
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "home-prefs-title",
    });

    var h = elem("h2", "home-prefs-title", { id: "home-prefs-title" });
    h.textContent = "Company buttons on the home screen";
    panel.appendChild(h);

    var note = elem("p", "home-prefs-note");
    note.textContent =
      "Every button shows a number, and clicking one slides that company's name out. Give a " +
      "button its own label here instead, or take it off the home screen. This changes the " +
      "button only — the company itself, and everything filed under it, stays exactly as it is.";
    panel.appendChild(note);

    panel.appendChild(elem("ul", "home-prefs-list", { id: "home-prefs-list" }));

    var foot = elem("p", "home-prefs-foot", { id: "home-prefs-foot", role: "status" });
    panel.appendChild(foot);

    var actions = elem("div", "home-prefs-actions");
    var done = elem("button", "home-prefs-done", { type: "button", id: "home-prefs-done" });
    done.textContent = "Done";
    done.addEventListener("click", closeSettings);
    actions.appendChild(done);
    panel.appendChild(actions);

    wrap.appendChild(panel);
    wrap.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        e.stopPropagation();
        closeSettings();
      }
    });
    return wrap;
  }

  /// Read the row and draw one line per company — INCLUDING the ones he has hidden, which is
  /// the whole reason `home_entity_row` does not apply the visibility filter itself: a hidden
  /// company that vanished from this list could never be brought back.
  function refreshPrefs() {
    var list = prefsEl && prefsEl.querySelector("#home-prefs-list");
    if (!list) return;
    var bridge = window.RichBridge;
    if (!bridge || typeof bridge.invoke !== "function") {
      drawPrefsRows([]);
      return;
    }
    bridge
      .invoke("home_entity_row")
      .then(drawPrefsRows)
      .catch(function () {
        drawPrefsRows([]);
      });
  }

  function drawPrefsRows(rows) {
    rows = rows || [];
    var list = prefsEl && prefsEl.querySelector("#home-prefs-list");
    if (!list) return;
    list.innerHTML = "";
    // The number each button shows, worked out the same way the row works it out — over the
    // companies that are SHOWN, in order. A company he has hidden gets the number it would take
    // if he showed it again, which is the next one at its own position: that is what its field
    // has to promise, because an empty label box means "show the number".
    var n = 0;
    for (var i = 0; i < rows.length; i++) {
      var shown = rows[i] && rows[i].visible !== false;
      if (shown) n++;
      list.appendChild(prefsRow(rows[i], String(shown ? n : n + 1)));
    }
    prefsFoot(rows);
    // The home screen's own row follows the same answer, live, so he can see what he is doing
    // to it while the panel is open.
    renderEntities(rows);
  }

  function prefsRow(row, number) {
    var li = elem("li", "home-prefs-row");
    var id = String(row.id);

    var name = elem("span", "home-prefs-name");
    name.textContent = row.display_name || id;
    li.appendChild(name);

    var input = elem("input", "home-prefs-label", {
      type: "text",
      // THE NUMBER as the placeholder, and the OVERRIDE as the value. It used to be the
      // registry name, and that stopped being true on 2026-09-02: an empty box now means the
      // button shows its number, and a placeholder saying otherwise would be the panel
      // describing a default the product no longer has. The override stays the VALUE, so
      // "no override" and "an override that happens to match" are still different states on
      // screen and clearing the box still reads as clearing rather than as deleting a name.
      placeholder: number || "",
      "aria-label": "What the " + (row.display_name || id) + " button says on the home screen",
      "data-entity": id,
      maxlength: "24",
    });
    input.value = row.custom_label || "";
    input.addEventListener("change", function () {
      writeLabel(id, input.value);
    });
    input.addEventListener("blur", function () {
      writeLabel(id, input.value);
    });
    li.appendChild(input);

    var showWrap = elem("label", "home-prefs-show");
    var box = elem("input", null, { type: "checkbox", "data-entity": id });
    box.checked = row.visible !== false;
    box.addEventListener("change", function () {
      var bridge = window.RichBridge;
      if (!bridge || typeof bridge.invoke !== "function") return;
      bridge
        .invoke("set_home_entity_visible", { entityId: id, visible: box.checked })
        .then(drawPrefsRows)
        .catch(function () {
          // The write refused, so the control goes back to what is actually stored rather
          // than showing him a state the app is not in.
          box.checked = !box.checked;
        });
    });
    var showTxt = elem("span", null);
    showTxt.textContent = "Show";
    showWrap.appendChild(box);
    showWrap.appendChild(showTxt);
    li.appendChild(showWrap);

    return li;
  }

  var lastWritten = {};
  function writeLabel(id, value) {
    var v = String(value == null ? "" : value).trim();
    if (lastWritten[id] === v) return; // `change` and `blur` both fire; the write happens once
    lastWritten[id] = v;
    var bridge = window.RichBridge;
    if (!bridge || typeof bridge.invoke !== "function") return;
    bridge
      .invoke("set_home_entity_label", { entityId: id, label: v === "" ? null : v })
      .then(drawPrefsRows)
      .catch(function () {
        delete lastWritten[id];
      });
  }

  /// The one line that explains the row's own disappearing act, because a control that
  /// silently stops existing is the state nobody can diagnose.
  function prefsFoot(rows) {
    var foot = prefsEl && prefsEl.querySelector("#home-prefs-foot");
    if (!foot) return;
    var shown = 0;
    for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].visible !== false) shown++;
    if (rows.length === 0) {
      foot.textContent = "I can't read your companies right now, so there is nothing to change here yet.";
      return;
    }
    if (shown < 2) {
      // CEO: "the company buttons should only appear if the user has more than one company.
      // Not if there's only one."
      foot.textContent =
        shown === 1
          ? "With one company shown, the buttons are off the home screen — a row of one is just noise."
          : "With no companies shown, the buttons are off the home screen.";
      return;
    }
    foot.textContent = shown + " of " + rows.length + " showing on the home screen.";
  }

  // =========================================================================================
  // BOOT
  // =========================================================================================

  function start() {
    try {
      root = build();
    } catch (e) {
      // A home screen that will not build leaves NOTHING behind and the app boots normally —
      // the same posture `splash.js` takes. A half-drawn surface is worse than no surface.
      root = null;
      state.field = "degraded";
      state.fieldError = "the home screen would not build: " + ((e && e.message) || e);
      return;
    }

    // FIRST IN THE BODY, like the curtain, so the composition is in the window's first paint
    // rather than something that arrives after the shell has been parsed.
    document.body.insertBefore(root, document.body.firstChild);
    document.body.classList.add("home-open");
    state.open = true;

    // §15's one permanent exception: the home screen is always dark, and the clamp is a FORCE
    // flag rather than a write, so the CEO's own choice is exactly where he left it when he
    // switches to the app UI.
    if (window.RichTheme) window.RichTheme.forceDark(true);

    document.addEventListener("focusin", onFocusIn, true);
    document.addEventListener("keydown", onHomeKey, true);

    // THE CLAMP HAS TO BE RE-ASSERTED, AND THIS IS NOT BELT AND BRACES — it is a real defect
    // this file would otherwise ship, caught by `tests/home.js`.
    //
    // `RichTheme.forceDark` is a single boolean, not a counter, and TWO surfaces raise it: the
    // curtain and this screen. The curtain drops it in `yieldNow`, which fires while the home
    // screen is still up and still owed §15's exception — so a CEO on light mode would watch
    // the settings button, which floats above this composition and reads the app's tokens,
    // turn ivory the moment the curtain lifted.
    //
    // A listener rather than a second raise after the yield, because the yield has three
    // triggers (app-ready, his first keystroke, the ceiling) and no single point after all of
    // them. Re-raising from inside the notification is safe: `forceDark` returns immediately
    // when the flag is already what it is being set to, so the second pass does not notify.
    if (window.RichTheme && window.RichTheme.onChange) {
      window.RichTheme.onChange(function (t) {
        if (state.open && !t.forcedDark) window.RichTheme.forceDark(true);
      });
    }

    // The shell below only exists once the document has been parsed, so everything that
    // reaches into it waits for that. Nothing here is awaited by anything.
    function afterShell() {
      appEl = document.getElementById("app");
      if (appEl && state.open) appEl.setAttribute("inert", "");
      bindWordmark();
      loadEntities();
      reserveTopInset();
      refreshNote();
      reserveDoorTop();
      // The sentence re-wraps when the window changes width, and the aside sits on its
      // measured height. Nothing else in this file listens for resize, so this is scoped to
      // the reservation it owns rather than re-running the whole layout.
      window.addEventListener("resize", reserveNoteInset);
      window.addEventListener("resize", reserveDoorTop);
      // The two labels' widths depend on the vendored face, and at first paint it may not have
      // arrived: a fallback-metrics measurement would leave every pill a few pixels wrong for
      // the rest of the launch. `document.fonts` is the only event that says otherwise.
      if (document.fonts && document.fonts.ready && document.fonts.ready.then) {
        document.fonts.ready.then(measureChips).catch(function () {});
      }
      focusHome();

      // The settings menu gets ONE row — "Home screen", with a button that opens the panel
      // above. §15 puts that menu on every screen, so this reaches him from the home screen
      // itself, which is the screen the setting is about.
      if (window.RichSettings && window.RichSettings.registerHome) {
        window.RichSettings.registerHome({ open: openSettings });
      }

      // THE PICTURE STARTS HERE AND NOWHERE EARLIER. `requestIdleCallback` fires when the main
      // thread is free, which during a launch is after the boot's synchronous work; the
      // timeout is the floor under it so a busy boot cannot push the picture past the curtain.
      if (window.requestIdleCallback) {
        window.requestIdleCallback(startField, { timeout: FIELD_IDLE_TIMEOUT_MS });
      } else {
        setTimeout(startField, 300);
      }
    }

    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", afterShell, { once: true });
    } else {
      afterShell();
    }
  }

  start();

  return {
    show: show,
    hide: hide,
    toggle: toggle,
    isOpen: isOpen,
    state: state,
    /// Exported so the acceptance suite can drive the picture without waiting on an idle
    /// callback that may never come in a headless run.
    startField: startField,
    /// The tuning constants, exported so a test can assert they are still round-11.1/v1's
    /// rather than something that drifted.
    VARIANT: VARIANT,
    /// The company-buttons panel. Opened from the settings menu's "Home screen" row.
    openSettings: openSettings,
    closeSettings: closeSettings,
    /// Re-read the row from the backend. The acceptance suite drives this directly rather
    /// than reloading the page after every write.
    reloadEntities: loadEntities,
    /// Re-derive the first-run banner from whatever dataset is currently loaded. Exported so
    /// the acceptance suite can drive BOTH sides of the condition — including the real-loro
    /// side, which no code path in the product can produce yet.
    refreshNote: refreshNote,
    /// The condition itself, exported for the same reason.
    fieldDataIsCustomers: fieldDataIsCustomers,
    /// The sentence, exported so a test asserts the rendered string against the source of
    /// truth rather than against a copy of it typed into the test.
    NOTE: NOTE,
  };
})();
