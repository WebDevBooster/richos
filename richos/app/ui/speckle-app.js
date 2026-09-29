/* =================================================================================================
   THE SPECKLED GROUND, IN THE DESKTOP APP.

   THE CEO, 2026-09-29, verbatim: "add this speckled background design for dark theme [round-15/v6]
   and this for light theme [round-15/v6-light-2] to our DESIGN SYSTEM so that those background
   designs can always be easily and reliably integrated in our desktop and mobile apps. And add the
   following rule: The splash screens on desktop and mobile apps as well as the desktop app home
   screen should never have that speckled background design." Then: "After the design system
   addition lands, get it integrated in desktop and mobile apps."

   WHAT THIS FILE IS. The design system's one call, made once, for the `desktop` surface, in both
   themes. `speckle.js` and `speckle.css` beside this file are the design system's files COPIED
   BYTE FOR BYTE from richos-hq `design/system/` at 8b85de45 (sha256 744e5106… and 42383e4c…);
   nothing in them is edited here, so a later design-system revision is a copy, not a merge.
   Everything app-specific is in this file and in the "THE SPECKLED GROUND" block of style.css.

   THE RULE, AND WHERE IT IS HELD. The splash screen and the home screen never carry the speckle:
     * the canvas is one fixed layer BEHIND the shell (z-index -1). `#splash` (z 200) and `#home`
       (z 150) are opaque full-window layers above it, so neither can show it;
     * and it is not merely covered: style.css hides the canvas outright (`visibility: hidden`)
       whenever `body.home-open` is set or `#splash` is in the document, so no pixel of it is
       composited while either screen is up, including during their fades;
     * and `RichOSSpeckle.background()` itself refuses the surfaces "splash" and "home".
   `tests/speckled-ground.js` asserts all three.

   THE TEXT ON THE GROUND. The engine caps every point's alpha so that each listed text color keeps
   4.55:1 against a point at its strongest. The design-system preset lists the colors round 15 drew
   on the ground; the app draws more than that, so every text token in style.css that can land on
   a ground plane is listed below, per theme, and the caps are re-solved for them at mount. Numbers
   (engine arithmetic, both themes, computed 2026-09-29): dark caps are unchanged (cool 0.1132,
   gold 0.1241 — `trim-text` still binds); in light `--attention` #8c4a1b binds and the caps fall
   from gold 0.4212 / rose 0.1615 / aqua 0.2382 to 0.3795 / 0.1467 / 0.2154, i.e. the light glitter
   is about 10% fainter than the design-system page, because the app draws a color on the ground
   the page does not. `tests/speckled-ground.js` walks the rendered shell and fails on any text drawn on
   the ground whose color is not held by the mounted caps.

   COST. The first paint of the field is one synchronous build of the tiles covering the window.
   It is taken on an idle callback after `load`, while the opening curtain and the home screen are
   still covering the shell (the canvas is hidden under them anyway), so it never lands on the
   launch path or on the home screen's first frames. `tests/speckled-ground.js` prints the measured build
   time.

   The way out: `RichSpeckle.destroy()` removes the canvas and every listener; the shell's ground
   planes are transparent over `html`'s ruled ground, so without the canvas the app looks exactly
   as it did before this file existed.
   ================================================================================================= */
(function () {
  "use strict";

  /// Every text color the shell can draw DIRECTLY on a ground plane (the stage, its header, the
  /// composer band, the rail), per theme, from style.css's two palettes. Colors already in the
  /// design-system preset are listed again on purpose: this list is the app's own inventory, and
  /// the engine takes the union. `a` is the color's own alpha (the muted inks are translucent).
  var TEXT_ON_GROUND = {
    dark: [
      { rgb: [223, 228, 238], a: 1, name: "--ink" },
      { rgb: [223, 228, 238], a: 0.64, name: "--ink-soft" },
      { rgb: [223, 228, 238], a: 0.62, name: "--ink-faint" },
      { rgb: [223, 228, 238], a: 0.75, name: "--ink-tech" },
      { rgb: [194, 163, 92], a: 1, name: "--gold-text" },
      { rgb: [126, 146, 184], a: 1, name: "--trim-text" },
      { rgb: [224, 154, 85], a: 1, name: "--attention" },
      { rgb: [232, 131, 124], a: 1, name: "--danger" },
      { rgb: [127, 184, 148], a: 1, name: "--success" },
    ],
    light: [
      { rgb: [12, 19, 34], a: 1, name: "--ink" },
      { rgb: [12, 19, 34], a: 0.68, name: "--ink-soft" },
      { rgb: [12, 19, 34], a: 0.63, name: "--ink-faint" },
      { rgb: [12, 19, 34], a: 0.75, name: "--ink-tech" },
      { rgb: [113, 87, 21], a: 1, name: "--gold-text" },
      { rgb: [68, 86, 122], a: 1, name: "--trim-text" },
      { rgb: [140, 74, 27], a: 1, name: "--attention" },
      { rgb: [138, 47, 40], a: 1, name: "--danger" },
      { rgb: [58, 92, 70], a: 1, name: "--success" },
    ],
  };

  var state = { handle: null, mountedAt: null, buildMs: null, error: null };

  function mount() {
    if (state.handle || !window.RichOSSpeckle) return state.handle;
    try {
      var t0 = performance.now();
      state.handle = window.RichOSSpeckle.background({ surface: "desktop", extraTextPairs: TEXT_ON_GROUND });
      state.buildMs = performance.now() - t0;
      state.mountedAt = t0;
    } catch (e) {
      // A failure here must never take the shell with it: the ground planes are transparent over
      // html's ruled ground, so the app without the canvas is the app as it was.
      state.error = String((e && e.message) || e);
    }
    return state.handle;
  }

  function destroy() {
    if (state.handle) state.handle.destroy();
    state.handle = null;
  }

  function whenIdle(fn) {
    if (typeof window.requestIdleCallback === "function") window.requestIdleCallback(fn, { timeout: 1500 });
    else setTimeout(fn, 200);
  }

  if (document.readyState === "complete") whenIdle(mount);
  else window.addEventListener("load", function () { whenIdle(mount); }, { once: true });

  window.RichSpeckle = {
    surface: "desktop",
    textOnGround: TEXT_ON_GROUND,
    state: state,
    mount: mount,
    destroy: destroy,
    report: function () { return state.handle ? state.handle.report() : null; },
    canvas: function () { return state.handle ? state.handle.canvas : null; },
  };
})();
