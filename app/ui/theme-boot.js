// THE PRE-PAINT THEME BOOT — synchronous, tiny, and first in `<head>` on purpose.
//
// The durable answer to "which theme?" and "how big is the type?" lives in `config.rs`,
// beside `splash_enabled` and `techy_default`, and it reaches this UI over the Tauri
// bridge — which is asynchronous. An async read cannot decide the FIRST FRAME. Boot the
// app on the default and reconcile a moment later and the CEO who chose light mode gets a
// full-screen flash of midnight blue on every single launch, which is exactly the kind of
// thing that makes a calm instrument feel cheap.
//
// So this file runs BEFORE the stylesheets are even linked and applies a synchronous
// MIRROR of the durable preference. The mirror is not the source of truth and never
// decides anything on its own:
//
//   config.rs  is the truth. It survives reinstall-adjacent things the webview's storage
//              does not, and it is what the Rust side reads.
//   this mirror is a cache of that truth, written by `settings-button.js` on every change
//              and re-synced from config.rs by main.js at init. If the two ever disagree,
//              config.rs wins and the mirror is corrected — see `RichTheme.sync`.
//
// A first launch has no mirror, so it takes the default, and §15's default is DARK: "a
// newly installed app opens dark." That is a ruling, not a fallback — `system` is an
// option the CEO can pick, never the thing he gets without picking.
"use strict";

window.RichTheme = (function () {
  var THEME_KEY = "richos-theme";
  var SCALE_KEY = "richos-font-scale";

  // The steps the ⌘+/⌘− control walks. Not a free-form number: a percentage box the CEO
  // can type into is a way to get 43% type, and there is no reading of §15 in which
  // "font size is a control" means "font size is a text field".
  var STEPS = [80, 90, 100, 110, 120, 135, 150];
  var DEFAULT_SCALE = 100;

  var root = document.documentElement;
  var mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function read(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (e) {
      // Private mode, a locked-down webview, storage disabled. Never a reason not to boot.
      return null;
    }
  }
  function write(key, value) {
    try {
      window.localStorage.setItem(key, String(value));
    } catch (e) {
      /* the mirror is an optimisation; config.rs still has the truth */
    }
  }

  function validTheme(v) {
    return v === "light" || v === "dark" || v === "system" ? v : null;
  }
  function validScale(v) {
    var n = parseInt(v, 10);
    return STEPS.indexOf(n) !== -1 ? n : null;
  }

  var pref = validTheme(read(THEME_KEY)) || "dark";
  var scale = validScale(read(SCALE_KEY)) || DEFAULT_SCALE;

  // THE ONE PERMANENT EXCEPTION (§15). The opening screen is ALWAYS dark — "because of its
  // nature the start screen will always need to be in dark mode" — and no switch reaches
  // it. It is expressed as a FORCE flag rather than by writing `dark` into the preference,
  // because the CEO's light-mode choice must still be there when the curtain lifts.
  var forcedDark = false;

  function resolved() {
    if (forcedDark) return "dark";
    if (pref === "system") return mq && mq.matches ? "dark" : "light";
    return pref;
  }

  function paint() {
    root.setAttribute("data-theme", resolved());
    // `--app-font-scale` multiplies the root font size; every size in style.css is rem, so
    // this one number moves the whole interface (§15, "Font size is a CONTROL").
    root.style.setProperty("--app-font-scale", String(scale / 100));
    root.setAttribute("data-font-scale", String(scale));
    notify();
  }

  var listeners = [];
  function notify() {
    for (var i = 0; i < listeners.length; i++) {
      try {
        listeners[i]({ pref: pref, resolved: resolved(), scale: scale, forcedDark: forcedDark });
      } catch (e) {
        /* one bad listener never breaks the paint */
      }
    }
  }

  if (mq && mq.addEventListener) {
    mq.addEventListener("change", function () {
      if (pref === "system") paint();
    });
  }

  var api = {
    STEPS: STEPS,
    DEFAULT_SCALE: DEFAULT_SCALE,

    theme: function () {
      return pref;
    },
    resolvedTheme: resolved,
    scale: function () {
      return scale;
    },
    forcedDark: function () {
      return forcedDark;
    },

    /** Set the CEO's theme preference. Mirrors immediately; the durable write is the
     *  caller's job (settings-button.js sends it to config.rs). */
    setTheme: function (next) {
      var v = validTheme(next);
      if (!v || v === pref) return false;
      pref = v;
      write(THEME_KEY, v);
      paint();
      return true;
    },

    /** Move `delta` steps along STEPS and clamp. Returns the new percentage. */
    stepScale: function (delta) {
      var i = STEPS.indexOf(scale);
      if (i === -1) i = STEPS.indexOf(DEFAULT_SCALE);
      var next = STEPS[Math.min(STEPS.length - 1, Math.max(0, i + delta))];
      if (next !== scale) {
        scale = next;
        write(SCALE_KEY, scale);
        paint();
      }
      return scale;
    },

    setScale: function (next) {
      var v = validScale(next);
      if (v === null || v === scale) return false;
      scale = v;
      write(SCALE_KEY, v);
      paint();
      return true;
    },

    resetScale: function () {
      return api.setScale(DEFAULT_SCALE) || scale;
    },

    /** The opening screen's always-dark clamp. `settings-button.js` raises it while the
     *  curtain is up and drops it when the curtain yields; the CEO's own preference is
     *  untouched throughout, which is why light mode is still there afterwards. */
    forceDark: function (on) {
      if (forcedDark === !!on) return;
      forcedDark = !!on;
      paint();
    },

    /** Reconcile against the durable truth in config.rs. Called by main.js at init with
     *  whatever the backend actually holds; disagreement is resolved in the backend's
     *  favour and the mirror is corrected, never the other way round. */
    sync: function (durable) {
      var changed = false;
      if (durable && validTheme(durable.theme) && durable.theme !== pref) {
        pref = durable.theme;
        write(THEME_KEY, pref);
        changed = true;
      }
      if (durable && validScale(durable.font_scale) !== null && durable.font_scale !== scale) {
        scale = validScale(durable.font_scale);
        write(SCALE_KEY, scale);
        changed = true;
      }
      if (changed) paint();
      return changed;
    },

    onChange: function (fn) {
      if (typeof fn === "function") listeners.push(fn);
    },
  };

  paint();
  return api;
})();
