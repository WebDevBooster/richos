// THE UNIVERSAL SETTINGS BUTTON — controller.
//
// CEO ruling §15, and the invariant is the whole point:
//
//   1. "That little settings button is ALWAYS EVERYWHERE ON EVERY PAGE." It is global
//      chrome, not a feature of a surface. A screen without it is a defect. So this file
//      mounts it against `document.body` on load and nothing has to remember to include it.
//   2. "Even if the user can't change the light/dark mode, the very least that settings
//      button always provides (from every page and every screen) is a quick access to the
//      'Bust a bug' button." The theme row is the part that can be absent. The button and
//      its bug path never are.
//
// Structure and behaviour are deeply's, ported (see the CSS header for the source of record
// and the exact list of what was adapted). What is RichOS's own is the menu's CONTENTS and
// their order, which §15 fixes: the theme switch, then Text size "directly under the theme
// switch", then "directly under that, a Techy Mode toggle". Then the floor.
//
// STANDALONE ON PURPOSE. This file depends on `theme-boot.js` and on nothing else — not on
// main.js, not on the Tauri bridge, not on the shell existing. That is what lets the same
// component sit on the opening screen before the app has booted, and it is what will let it
// be lifted into the website the ruling also names. Durable persistence and the Techy
// toggle are OPTIONAL capabilities that a host registers; absent a host, the control still
// works and still remembers, through the mirror.
"use strict";

window.RichSettings = (function () {
  var T = window.RichTheme;

  // ---- optional host capabilities ------------------------------------------------------
  // Registered by main.js when the shell is up. Each is a plain object or null; every call
  // site below tolerates null, because the opening screen has no shell behind it yet.
  var durable = null; // { saveTheme(pref), saveScale(pct) }
  var techy = null; // { read(), write(on) }
  var bug = null; // { open() } — what "Bust a bug" actually opens, when that exists
  var splash = null; // { read(), write(on) } — the opening screen's off switch
  var updates = null; // { render(container), onOpen() } — the update surface fills its own row

  var wrap = null;
  var menuEl = null;
  var btnEl = null;
  var toastTimer = null;

  // ---- icons, copied from the reference implementation ---------------------------------
  var SVG_NS = "http://www.w3.org/2000/svg";
  function icon(paths, size) {
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    for (var i = 0; i < paths.length; i++) {
      var spec = paths[i];
      var node = document.createElementNS(SVG_NS, spec[0]);
      for (var k in spec[1]) node.setAttribute(k, spec[1][k]);
      svg.appendChild(node);
    }
    if (size) {
      svg.setAttribute("width", size);
      svg.setAttribute("height", size);
    }
    return svg;
  }
  // The settings glyph is a SLIDER PAIR, not a cog — the reference is explicit about it.
  var ICON_SETTINGS = [
    ["path", { d: "M20 7h-9" }],
    ["path", { d: "M14 17H5" }],
    ["circle", { cx: "17", cy: "17", r: "3" }],
    ["circle", { cx: "7", cy: "7", r: "3" }],
  ];
  var ICON_SUN = [
    ["circle", { cx: "12", cy: "12", r: "4" }],
    ["path", { d: "M12 2v2" }],
    ["path", { d: "M12 20v2" }],
    ["path", { d: "m4.93 4.93 1.41 1.41" }],
    ["path", { d: "m17.66 17.66 1.41 1.41" }],
    ["path", { d: "M2 12h2" }],
    ["path", { d: "M20 12h2" }],
    ["path", { d: "m6.34 17.66-1.41 1.41" }],
    ["path", { d: "m19.07 4.93-1.41 1.41" }],
  ];
  var ICON_SYSTEM = [
    ["rect", { width: "20", height: "14", x: "2", y: "3", rx: "2" }],
    ["line", { x1: "8", x2: "16", y1: "21", y2: "21" }],
    ["line", { x1: "12", x2: "12", y1: "17", y2: "21" }],
  ];
  var ICON_MOON = [["path", { d: "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" }]];
  var ICON_BUG = [
    ["path", { d: "m8 2 1.88 1.88" }],
    ["path", { d: "M14.12 3.88 16 2" }],
    ["path", { d: "M9 7.13v-1a3.003 3.003 0 1 1 6 0v1" }],
    ["path", { d: "M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6" }],
    ["path", { d: "M12 20v-9" }],
    ["path", { d: "M6.53 9C4.6 8.8 3 7.1 3 5" }],
    ["path", { d: "M6 13H2" }],
    ["path", { d: "M3 21c0-2.1 1.7-3.8 3.8-4" }],
    ["path", { d: "M20.97 5c0 2.1-1.6 3.8-3.5 4" }],
    ["path", { d: "M22 13h-4" }],
    ["path", { d: "M17.2 17c2.1.2 3.8 1.9 3.8 4" }],
  ];

  function elem(tag, cls, attrs) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    for (var k in attrs || {}) n.setAttribute(k, attrs[k]);
    return n;
  }

  // ---- the menu ------------------------------------------------------------------------

  function buildThemeRow() {
    var row = elem("div", "set-row");
    var label = elem("span", "set-name", { id: "set-theme-label" });
    label.textContent = "Theme";
    var seg = elem("div", "theme-seg", { role: "group", "aria-labelledby": "set-theme-label" });
    var opts = [
      ["light", "Light theme", "Light", ICON_SUN],
      ["system", "Follow the system", "System", ICON_SYSTEM],
      ["dark", "Dark theme", "Dark", ICON_MOON],
    ];
    for (var i = 0; i < opts.length; i++) {
      var b = elem("button", "theme-opt", {
        type: "button",
        "data-th": opts[i][0],
        "aria-label": opts[i][1],
        title: opts[i][2],
        "aria-pressed": "false",
      });
      b.appendChild(icon(opts[i][3]));
      seg.appendChild(b);
    }
    row.appendChild(label);
    row.appendChild(seg);
    return row;
  }

  function buildFontRow() {
    var row = elem("div", "set-row");
    var label = elem("span", "set-name", { id: "set-font-label" });
    label.textContent = "Text size";
    var seg = elem("div", "font-seg", { role: "group", "aria-labelledby": "set-font-label" });

    var down = elem("button", "font-opt", { type: "button", id: "font-down", "aria-label": "Smaller text", title: "Smaller (⌘−)" });
    down.textContent = "−";
    var val = elem("span", "font-val", { id: "font-val", "aria-live": "polite" });
    var up = elem("button", "font-opt", { type: "button", id: "font-up", "aria-label": "Larger text", title: "Larger (⌘+)" });
    up.textContent = "+";

    seg.appendChild(down);
    seg.appendChild(val);
    seg.appendChild(up);
    row.appendChild(label);
    row.appendChild(seg);
    return row;
  }

  function buildTechyRow() {
    var row = elem("div", "set-row", { id: "set-techy-row" });
    var label = elem("span", "set-name", { id: "set-techy-label" });
    label.textContent = "Techy Mode";
    var input = elem("input", "set-switch", {
      type: "checkbox",
      id: "set-techy",
      "aria-labelledby": "set-techy-label",
    });
    row.appendChild(label);
    row.appendChild(input);
    return row;
  }

  /// The opening screen's off switch, as a SECOND entrance to the switch that already
  /// exists behind the rail's gear.
  ///
  /// It is here because the CEO restated on 2026-08-31 that turning the splash off FROM
  /// SETTINGS is a requirement, and this button is what "settings" now means: the one piece
  /// of chrome that is on every screen. The gear's own preferences panel keeps its copy —
  /// nothing was moved and nothing was lost — so this is the same pattern as Techy Mode, one
  /// state with two doors, and `RichSettings.paint()` in the shell's render path is what
  /// keeps the two from ever showing different answers.
  ///
  /// It sits BELOW the three rows §15 fixed, because that ruling governs their order and
  /// says nothing about this one, and because the three above it are things he changes while
  /// working while this is a thing he decides once.
  function buildSplashRow() {
    var row = elem("div", "set-row", { id: "set-splash-row" });
    var label = elem("span", "set-name", { id: "set-splash-label" });
    label.textContent = "Opening screen";
    var input = elem("input", "set-switch", {
      type: "checkbox",
      id: "set-splash",
      "aria-labelledby": "set-splash-label",
    });
    row.appendChild(label);
    row.appendChild(input);
    return row;
  }

  /// UPDATES — an empty slot, and the host fills it (RICH-TODOs row 12).
  ///
  /// EVERY OTHER CAPABILITY HERE IS DATA (`read`/`write`) AND THIS ONE IS A SLOT, which is a
  /// deliberate exception rather than a shortcut. Techy Mode and the opening screen are one
  /// boolean each, so this file can own their whole control. The update surface is nine
  /// states, three buttons, a progress bar and a disclosure — owning it here would put a
  /// `RichBridge` dependency inside the one component whose stated contract is that it has
  /// none (see this file's header: it must keep working on the opening screen, before the
  /// shell exists, and be liftable into the website). So this file owns the ROW and knows
  /// nothing else; `updates.js` owns everything inside it and is the only thing that talks
  /// to the shell.
  ///
  /// It sits below the opening-screen row and above the floor: §15 fixes the order of the
  /// three rows it names and says nothing about this one, and "Bust a bug" stays last
  /// because the ruling's floor is that it is always there.
  function buildUpdatesRow() {
    var row = elem("div", "set-updates", { id: "set-updates" });
    return row;
  }

  function buildBugButton() {
    var b = elem("button", "bugbtn", { type: "button", id: "bug-btn" });
    b.appendChild(icon(ICON_BUG));
    b.appendChild(document.createTextNode("Bust a bug!"));
    return b;
  }

  /** Build (or rebuild) the menu for the CURRENT capabilities.
   *
   *  The theme row is OMITTED, not disabled, when the theme is forced (§15's always-dark
   *  opening screen). A disabled control is a promise that it will work later; here it
   *  never will, and the ruling's floor is about what the button still DOES, not about
   *  showing a dead switch.
   *
   *  The Techy row appears only when a host has registered the capability, so a page with no
   *  shell behind it carries no dead toggle. It DOES appear on the opening screen, and that
   *  is correct rather than an oversight: what it moves is the GLOBAL default (§3.1 — "all"
   *  has to be one switch), which is a real preference whether or not a conversation happens
   *  to be open, and the shell is already live underneath the curtain.
   */
  function buildMenu() {
    var menu = elem("div", "setmenu", { id: "set-menu", "aria-label": "Settings", role: "menu" });
    menu.hidden = true;
    if (!T.forcedDark()) menu.appendChild(buildThemeRow());
    menu.appendChild(buildFontRow()); // ...then Text size directly under it (§15)
    if (techy) menu.appendChild(buildTechyRow()); // ...and directly under that, Techy Mode
    if (splash) menu.appendChild(buildSplashRow()); // ...then the opening screen's off switch
    if (updates) menu.appendChild(buildUpdatesRow()); // ...then what version this is, and what is waiting
    menu.appendChild(buildBugButton()); // the floor, always last and always present
    return menu;
  }

  function rebuild() {
    if (!wrap) return;
    var wasOpen = menuEl && !menuEl.hidden;
    if (menuEl) menuEl.remove();
    menuEl = buildMenu();
    wrap.appendChild(menuEl);
    wireMenu();
    paint();
    if (wasOpen) open();
  }

  // ---- state painting ------------------------------------------------------------------

  function paint() {
    if (!menuEl) return;
    var opts = menuEl.querySelectorAll(".theme-opt");
    for (var i = 0; i < opts.length; i++) {
      opts[i].setAttribute("aria-pressed", String(opts[i].dataset.th === T.theme()));
    }
    var val = menuEl.querySelector("#font-val");
    if (val) val.textContent = T.scale() + "%";
    var steps = T.STEPS;
    var down = menuEl.querySelector("#font-down");
    var up = menuEl.querySelector("#font-up");
    if (down) down.disabled = T.scale() <= steps[0];
    if (up) up.disabled = T.scale() >= steps[steps.length - 1];
    var sw = menuEl.querySelector("#set-techy");
    if (sw && techy) sw.checked = !!techy.read();
    var sp = menuEl.querySelector("#set-splash");
    if (sp && splash) sp.checked = !!splash.read();
    // The updates row is painted by its owner, because this file does not know what is in
    // it. Called on every paint so a rebuild (a forced-dark flip) never leaves an empty row.
    var up2 = menuEl.querySelector("#set-updates");
    if (up2 && updates && updates.render) updates.render(up2);
    if (wrap) wrap.setAttribute("data-force-dark", String(T.forcedDark()));
  }

  // ---- open / close --------------------------------------------------------------------

  function open() {
    if (!menuEl || !menuEl.hidden) return;
    menuEl.hidden = false;
    wrap.classList.add("open");
    btnEl.setAttribute("aria-expanded", "true");
    // A claim about an update must not be stale on the screen that makes it: the automatic
    // launch check may have completed while this menu was closed. One read of an in-memory
    // struct, on an explicit click.
    if (updates && updates.onOpen) updates.onOpen();
  }
  function close(refocus) {
    if (!menuEl || menuEl.hidden) return;
    menuEl.hidden = true;
    wrap.classList.remove("open");
    btnEl.setAttribute("aria-expanded", "false");
    if (refocus) btnEl.focus();
  }

  // ---- actions -------------------------------------------------------------------------

  // NONE OF THESE THREE CALL `paint()`, AND THAT IS DELIBERATE.
  //
  // Every one of them moves state through `RichTheme`, which paints and then notifies its
  // subscribers — and this file is a subscriber (see `mount`). A local `paint()` here as
  // well is dead code that LOOKS load-bearing: deleting it changes nothing, so a future
  // reader cannot tell from the source whether the row updates because of this line or in
  // spite of it. Worse, it hides the real dependency. If the subscription breaks, the menu
  // stops tracking the keyboard, and check 10 is the thing that says so — which it can only
  // do if there is exactly one path.
  function applyTheme(pref) {
    if (T.setTheme(pref)) saveTheme(pref);
    close(true);
  }
  function saveTheme(pref) {
    if (durable && durable.saveTheme) {
      try {
        durable.saveTheme(pref);
      } catch (e) {
        /* the mirror already holds it; a failed durable write is not a failed preference */
      }
    }
  }
  function saveScale(pct) {
    if (durable && durable.saveScale) {
      try {
        durable.saveScale(pct);
      } catch (e) {
        /* as above */
      }
    }
  }

  function stepFont(delta) {
    var next = T.stepScale(delta);
    saveScale(next);
    return next;
  }
  function resetFont() {
    T.setScale(T.DEFAULT_SCALE);
    saveScale(T.DEFAULT_SCALE);
    return T.DEFAULT_SCALE;
  }

  function bustABug() {
    close(true);
    if (bug && bug.open) {
      bug.open();
      return;
    }
    // WHAT "Bust a bug" OPENS IS NOT DESIGNED IN THIS ROUND — the round-10.1 index says so
    // in as many words. What it must not do is nothing: a control that appears to do
    // nothing is indistinguishable from a broken one, and this is the control a stuck
    // first-run user reaches for. So it acknowledges, in Rich's voice, and says the one
    // thing about it that IS decided — that nothing leaves the machine unasked.
    toast(
      "Got it — the bug report starts from this exact screen, as it stands. " +
        "Nothing leaves this machine until you say so."
    );
  }

  function toast(text) {
    var t = document.getElementById("bug-toast");
    if (!t) {
      t = elem("div", "", { id: "bug-toast", role: "status", "aria-live": "polite" });
      document.body.appendChild(t);
    }
    t.textContent = text;
    t.hidden = false;
    t.classList.remove("is-leaving");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      t.classList.add("is-leaving");
      setTimeout(function () {
        t.hidden = true;
        t.classList.remove("is-leaving");
      }, 450);
    }, 3400);
  }

  // ---- wiring --------------------------------------------------------------------------

  function wireMenu() {
    var opts = menuEl.querySelectorAll(".theme-opt");
    for (var i = 0; i < opts.length; i++) {
      (function (o) {
        o.addEventListener("click", function () {
          applyTheme(o.dataset.th);
        });
      })(opts[i]);
    }
    var down = menuEl.querySelector("#font-down");
    var up = menuEl.querySelector("#font-up");
    if (down) down.addEventListener("click", function () { stepFont(-1); });
    if (up) up.addEventListener("click", function () { stepFont(1); });

    var sw = menuEl.querySelector("#set-techy");
    if (sw) {
      sw.addEventListener("change", function () {
        if (techy && techy.write) techy.write(sw.checked);
      });
    }
    var spEl = menuEl.querySelector("#set-splash");
    if (spEl) {
      spEl.addEventListener("change", function () {
        if (splash && splash.write) splash.write(spEl.checked);
      });
    }
    var bugEl = menuEl.querySelector("#bug-btn");
    if (bugEl) bugEl.addEventListener("click", bustABug);
  }

  function mount() {
    if (wrap) return;
    wrap = elem("div", "settings", { id: "settings" });
    btnEl = elem("button", "setbtn", {
      type: "button",
      id: "set-btn",
      "aria-label": "Settings",
      "aria-haspopup": "true",
      "aria-expanded": "false",
    });
    btnEl.appendChild(icon(ICON_SETTINGS));
    wrap.appendChild(btnEl);
    menuEl = buildMenu();
    wrap.appendChild(menuEl);
    document.body.appendChild(wrap);

    btnEl.addEventListener("click", function () {
      if (menuEl.hidden) open();
      else close(false);
    });
    wireMenu();

    document.addEventListener("pointerdown", function (e) {
      if (!e.target.closest || !e.target.closest(".settings")) close(false);
    });

    document.addEventListener("keydown", function (e) {
      // THE ACCELERATOR IS THE APP'S, NOT THE WEBVIEW'S (§15). `preventDefault` is what
      // takes it: without it WebKit runs its own page zoom, which scales the whole document
      // including fixed chrome and layout, does not persist, and is invisible to the Text
      // size row — two controls, two states, one of them a lie. With it, ⌘+/−/0 and the row
      // move the same single persisted number.
      if ((e.metaKey || e.ctrlKey) && !e.altKey) {
        if (e.key === "+" || e.key === "=") {
          e.preventDefault();
          stepFont(1);
          return;
        }
        if (e.key === "-" || e.key === "_") {
          e.preventDefault();
          stepFont(-1);
          return;
        }
        if (e.key === "0") {
          e.preventDefault();
          resetFont();
          return;
        }
      }
      if (e.key === "Escape") close(true);
    });

    // A forced-dark flip CHANGES THE MENU'S SHAPE (the theme row is omitted, not disabled),
    // so it needs a rebuild and not just a repaint. splash.js raises the clamp against
    // `RichTheme` directly — it is loaded in `<head>` and this file is not — so the
    // reaction has to live here rather than only in `RichSettings.forceDark`.
    var lastForced = T.forcedDark();
    T.onChange(function (s) {
      if (s.forcedDark !== lastForced) {
        lastForced = s.forcedDark;
        rebuild();
        return;
      }
      paint();
    });
    paint();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }

  return {
    mount: mount,
    close: close,
    paint: paint,
    stepFont: stepFont,
    resetFont: resetFont,
    toast: toast,

    /** The shell registers durable persistence once the bridge is up. Until then the
     *  mirror carries the preference on its own, which is why the control works on the
     *  opening screen and on a page that has no backend at all. */
    registerDurable: function (host) {
      durable = host || null;
    },

    /** §15: "directly under that, a Techy Mode toggle". The host passes the SAME read and
     *  write the rail's own preference row uses — `techy.default` and `setTechyDefault` —
     *  so the two entrances move one state rather than two that agree most of the time.
     *  `RichSettings.paint()` after any change is what keeps the other entrance honest. */
    registerTechy: function (host) {
      techy = host || null;
      rebuild();
    },

    /** The opening screen's off switch, registered with the SAME read and write the gear's
     *  own checkbox uses — one state, two doors, exactly as Techy Mode is. Registering the
     *  capability is also what makes the row exist, so a page with no shell behind it does
     *  not offer to switch off a screen it cannot reach. */
    registerSplash: function (host) {
      splash = host || null;
      rebuild();
    },

    /** What "Bust a bug" opens, when something exists to open. Not designed this round. */
    registerBugReport: function (host) {
      bug = host || null;
    },

    /** THE UPDATE SURFACE (RICH-TODOs row 12), as a SLOT rather than as data — see
     *  `buildUpdatesRow` for why this one capability is shaped differently from the rest.
     *  `host.render(container)` fills the row; `host.onOpen()` is called when the menu is
     *  opened. Registering is also what makes the row exist, so the opening screen — which
     *  has no shell behind it yet — carries no dead update panel. */
    registerUpdates: function (host) {
      updates = host || null;
      rebuild();
    },

    /** Repaint the menu from outside. `updates.js` calls this when a `rich://update` event
     *  arrives while the menu is open, so a download's progress moves on screen rather than
     *  only in memory. */
    repaintUpdates: function () {
      paint();
    },

    /** §15's one permanent exception, raised while the opening screen's curtain is up and
     *  dropped when it yields. The CEO's own preference is never written, so light mode is
     *  exactly where he left it the moment the shell appears. */
    forceDark: function (on) {
      T.forceDark(on);
      rebuild();
    },
  };
})();
