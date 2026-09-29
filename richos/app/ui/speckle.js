/* =================================================================================================
   RICHOS DESIGN SYSTEM — THE SPECKLED GROUND
   design/system/speckle.js · the engine, and the four configurations the CEO chose, as presets.

   THE RULING. 2026-09-29, his words: "add this speckled background design for dark theme
   (round-15/v6) and this for light theme (round-15/v6-light-2) to our DESIGN SYSTEM so that those
   background designs can always be easily and reliably integrated in our desktop and mobile apps.
   And add the following rule: The splash screens on desktop and mobile apps as well as the desktop
   app home screen should never have that speckled background design."

   THE RULE IS ENFORCED HERE, NOT ONLY WRITTEN DOWN: `RichOSSpeckle.background()` accepts exactly two
   surfaces, "desktop" and "mobile", and REFUSES "splash" and "home" by throwing. Nothing in the
   presets can be reached under those names.

   -------------------------------------------------------------------------------------------------
   HOW AN APP INTEGRATES IT — one script, one call
   -------------------------------------------------------------------------------------------------
     <link rel="stylesheet" href="speckle.css">           the host + rail rules (four lines)
     <script src="speckle.js"></script>
     <script>
       var bg = RichOSSpeckle.background({ surface: "desktop" });   // the desktop app, whole window
       var bg = RichOSSpeckle.background({ surface: "mobile" });    // the phone app, whole window
     </script>

   The theme is read from <html data-theme="dark|light"> and followed live (a change re-solves and
   redraws). The canvas paints the ruled ground itself, so the app's own ground planes under it are
   made transparent (class `speckle-ground` in speckle.css) and everything raised — panels, cards,
   the composer — stays opaque and untouched. The rail keeps its deeper tone as a translucent
   darkening over the sheen (class `speckle-rail`).

   Options, all optional:
     parent          an element to fill instead of the viewport (a phone frame in a mockup, an app
                     shell). Give it `position: relative; isolation: isolate` (class `speckle-host`).
     theme           "dark" | "light" — pin the theme instead of following <html data-theme>.
     themeOf         function returning "dark" | "light" — your own theme source.
     extraTextPairs  [{ rgb: [r,g,b], a: 1, name: "…" }] — EVERY color your app draws DIRECTLY on the
                     ground that is not already in the preset's list. Each preset solves its caps
                     against the text colors round 15 draws on the ground; add yours and the caps are
                     re-solved at mount so the 4.5:1 floor holds for them too. Text on an opaque
                     surface never touches the speckle and needs no entry.
     zIndex          default -1 (behind everything in the host's stacking context).
     paintGround     false to leave the canvas transparent (then YOUR ground must be the ruled one).

   Returns { rebuild(), report(), destroy(), canvas }. `report()` gives the solved caps, the worst
   text pair, its ratio, and the brightest (dark) or darkest (light) pixel any point can produce.

   -------------------------------------------------------------------------------------------------
   WHAT IT IS, AND WHAT IT GUARANTEES BY CONSTRUCTION
   -------------------------------------------------------------------------------------------------
   A very fine, subtle glittery speckle that reads almost like a gradient: single device-pixel
   points, each at a low alpha, whose COVERAGE follows a light shape (a lamp pooled at the top of the
   window, thinning to nothing two-thirds of the way down). From reading distance it is a sheen; up
   close it resolves into fine glitter. Nothing is bigger than one pixel, nothing has a halo, nothing
   is countable.

   DARK (round-15/v6): cool points rgb(214,226,250), 85%, and warm gold rgb(240,208,140), 15%, on
   the ruled ground #0C1322.
   LIGHT (round-15/v6-light-2): glitter on paper is COLOR — champagne gold rgb(255,186,30) 62%, a
   pearl's rose rgb(255,110,150) 19% and aqua rgb(40,200,235) 19%, each brighter point carrying its
   lit side, a white point one device pixel up-left toward the lamp, on the ruled paper #EAE6DD.

   - Deterministic: one seed, one field. The same window shows the same speckle on every launch.
   - Contrast everywhere, always: every point's alpha is at or under a CAP solved numerically at
     mount (bisection, 48 steps) from the ground and every text color that sits on it, so that any
     listed text pair keeps 4.55:1 (WCAG AA 4.5:1 plus a margin for 8-bit rounding) against a point
     at its strongest; every alpha is stored with Math.floor so quantization can only lower it. On a
     light ground the cap is solved on the UNLIT paper, the darkest ground a point can land on, and
     on the deeper rail too. Because no pixel can exceed the cap, the guarantee does not depend on
     where the text is or how far anything has scrolled, and nothing has to be masked.
   - Motion: none in the chosen configurations (`shape: null`). The engine keeps the optional slow
     shimmer for a future ruling; it is off under prefers-reduced-motion and never moves layout.
   - Nothing fetched. No dependencies. Redraws only on resize, theme change and visibility; tiles
     are cached per 256 css px, so a still window costs nothing after the first paint.

   Engine lineage: design/mockups/rounds/round-15/v6-light-2/speckle-light.js, itself
   round-15/speckle.js with four opt-in additions (tint.max, tint.curve, tint.facet, cfg.grounds); a
   dark configuration renders here pixel for pixel as it did there. Rounds are frozen; this is the
   copy forward. Added here: presets, background(), destroy(), and the refusal.
   ================================================================================================= */
(function (global) {
  "use strict";
  var TILE = 256; /* css px per cached tile */

  /* ---- color, in sRGB, the way the browser composites ---- */
  function lin(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  function lum(rgb) { return 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2]); }
  function ratio(a, b) { var la = lum(a) + 0.05, lb = lum(b) + 0.05; return la > lb ? la / lb : lb / la; }
  function over(fg, a, bg) { return [fg[0] * a + bg[0] * (1 - a), fg[1] * a + bg[1] * (1 - a), fg[2] * a + bg[2] * (1 - a)]; }
  function worstAt(tint, a, ground, pairs) {
    var bg = over(tint, a, ground), worst = Infinity, which = null;
    for (var i = 0; i < pairs.length; i++) {
      var p = pairs[i], t = over(p.rgb, p.a == null ? 1 : p.a, bg), r = ratio(t, bg);
      if (r < worst) { worst = r; which = p; }
    }
    return { worst: worst, pair: which, bg: bg };
  }
  /* the largest alpha of `tint` over `ground` at which every text pair still meets `floor`; bisection */
  function capAlpha(tint, ground, pairs, floor) {
    if (worstAt(tint, 0, ground, pairs).worst < floor) return 0;
    var lo = 0, hi = 1;
    for (var k = 0; k < 48; k++) { var m = (lo + hi) / 2; if (worstAt(tint, m, ground, pairs).worst >= floor) lo = m; else hi = m; }
    return lo;
  }

  /* ---- a fast integer hash → [0,1) per pixel ---- */
  function h3(seed, x, y) {
    var h = (seed | 0) ^ Math.imul(x | 0, 0x85EBCA6B) ^ Math.imul(y | 0, 0xC2B2AE35);
    h ^= h >>> 15; h = Math.imul(h, 0x2C1B3C6D); h ^= h >>> 12; h = Math.imul(h, 0x297A2D39); h ^= h >>> 15;
    return (h >>> 0) / 4294967296;
  }

  function mount(opts) {
    var doc = document, cfgs = opts.themes;
    var themeOf = opts.themeOf || function () { return doc.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark"; };
    var host = opts.parent || null; /* when set, the canvas fills that element instead of the viewport */
    var canvas = doc.createElement("canvas"); canvas.className = opts.className || "speckle"; canvas.setAttribute("aria-hidden", "true");
    canvas.style.cssText = (host ? "position:absolute;" : "position:fixed;") + "inset:0;width:100%;height:100%;pointer-events:none;z-index:" + (opts.zIndex == null ? 1 : opts.zIndex) + ";" + (opts.blend ? "mix-blend-mode:" + opts.blend + ";" : "") + (opts.style || "");
    var parent = host || doc.body; if (opts.insertFirst) parent.insertBefore(canvas, parent.firstChild); else parent.appendChild(canvas);
    var ctx = canvas.getContext("2d", { alpha: true });
    var layer = doc.createElement("canvas"), lctx = layer.getContext("2d", { alpha: true });
    var mq = global.matchMedia ? global.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
    var reduce = mq.matches;
    var state = { cfg: null, theme: null, caps: [], vw: 0, vh: 0, dpr: 1, W: 0, H: 0, t0: performance.now(), raf: 0, tiles: new Map(), report: null, dead: false };

    function docSize() { if (host) return { W: host.clientWidth, H: host.clientHeight }; var de = doc.documentElement; return { W: Math.max(de.clientWidth, de.scrollWidth), H: Math.max(de.clientHeight, de.scrollHeight) }; }
    function size() {
      var dpr = Math.min(global.devicePixelRatio || 1, 3);
      state.vw = host ? host.clientWidth : global.innerWidth; state.vh = host ? host.clientHeight : global.innerHeight; state.dpr = dpr;
      canvas.width = layer.width = Math.round(state.vw * dpr); canvas.height = layer.height = Math.round(state.vh * dpr);
      state.tiles.clear();
    }
    function build() {
      var theme = themeOf(), cfg = cfgs[theme] || null;
      state.theme = theme; state.cfg = cfg; state.tiles.clear(); state.report = null;
      var s = docSize(); state.W = s.W; state.H = s.H;
      /* a tint may also carry a design ceiling `max` under the solved cap. For a highlight on a light ground the
         solved cap is 1 (lighter only raises the contrast of dark text), so the ceiling is what keeps it barely there.
         Every ground in `grounds` (the darkest the tint can land on) is solved; the lowest cap wins. */
      if (cfg) {
        var gs = cfg.grounds || [cfg.ground];
        state.caps = cfg.tints.map(function (t) {
          var c = 1; gs.forEach(function (g) { c = Math.min(c, capAlpha(t.rgb, g, cfg.textPairs, cfg.floor || 4.5)); });
          return t.max == null ? c : Math.min(c, t.max);
        });
        report();
      }
      draw();
    }
    function fieldSize() { return state.cfg.space === "page" ? { W: state.W, H: state.H } : { W: state.vw, H: state.vh }; }
    function report() {
      var cfg = state.cfg, worst = Infinity, which = null, at = null, tintName = null;
      (cfg.grounds || [cfg.ground]).forEach(function (gr) {
        cfg.tints.forEach(function (t, ti) { var w = worstAt(t.rgb, state.caps[ti], gr, cfg.textPairs); if (w.worst < worst) { worst = w.worst; which = w.pair; at = w.bg; tintName = t.name || String(ti); } });
      });
      /* coverage, sampled on a grid of the field */
      var f = fieldSize(), sum = 0, n = 0, peak = 0;
      for (var y = 8; y < f.H; y += 16) for (var x = 8; x < f.W; x += 16) { var c = cfg.coverage(x, y, f.W, f.H); sum += c; n++; if (c > peak) peak = c; }
      state.report = { theme: state.theme, caps: state.caps.map(function (a) { return +a.toFixed(4); }), tints: cfg.tints.map(function (t) { return t.name; }), worstRatio: worst, worstPair: which, brightestPixel: at.map(Math.round), tint: tintName, space: cfg.space || "fixed", meanCoverage: n ? +(sum / n).toFixed(4) : 0, peakCoverage: +peak.toFixed(4), reducedMotion: reduce, field: [f.W, f.H], floor: cfg.floor || 4.5 };
      return state.report;
    }

    /* one tile of the field, per device pixel: lit with probability coverage(x,y); alpha ≤ cap */
    function tile(tx, ty) {
      var key = tx + "," + ty, hit = state.tiles.get(key); if (hit) return hit;
      var cfg = state.cfg, dpr = state.dpr, wpx = Math.round(TILE * dpr), f = fieldSize();
      var c = doc.createElement("canvas"); c.width = wpx; c.height = wpx;
      var g = c.getContext("2d"), img = g.createImageData(wpx, wpx), d = img.data;
      var tints = cfg.tints, nt = tints.length, totalW = 0; for (var i = 0; i < nt; i++) totalW += tints[i].w;
      var cum = []; var acc = 0; for (i = 0; i < nt; i++) { acc += tints[i].w / totalW; cum.push(acc); }
      var k = cfg.alphaCurve && cfg.alphaCurve.k != null ? cfg.alphaCurve.k : 3, amin = cfg.alphaCurve && cfg.alphaCurve.min != null ? cfg.alphaCurve.min : 0.15;
      /* per-tint alpha curve (light: the glints skew brighter than the shadows); default is the cfg's */
      function curveK(ti) { var c = tints[ti].curve; return c && c.k != null ? c.k : k; }
      function curveMin(ti) { var c = tints[ti].curve; return c && c.min != null ? c.min : amin; }
      function pick(w, x, y, W, H) { var ti = 0; while (ti < nt - 1 && w > cum[ti]) ti++; if (cfg.tintAt) ti = cfg.tintAt(x, y, W, H, w); return ti; }
      var hasFacet = tints.some(function (t) { return !!t.facet; });
      var facetDX = cfg.facetOffset ? cfg.facetOffset[0] : 1, facetDY = cfg.facetOffset ? cfg.facetOffset[1] : 1;
      var seed = cfg.seed | 0, ox = tx * wpx, oy = ty * wpx, step = 8; /* coverage sampled every 8 device px, bilinear */
      var cols = Math.floor(wpx / step) + 2, rows = cols, cov = new Float32Array(cols * rows);
      for (var j = 0; j < rows; j++) for (i = 0; i < cols; i++) cov[j * cols + i] = cfg.coverage((ox + i * step) / dpr, (oy + j * step) / dpr, f.W, f.H);
      for (var py = 0; py < wpx; py++) {
        var gy = py / step, j0 = Math.floor(gy), fy = gy - j0;
        for (var px = 0; px < wpx; px++) {
          var gx = px / step, i0 = Math.floor(gx), fx = gx - i0;
          var c00 = cov[j0 * cols + i0], c10 = cov[j0 * cols + i0 + 1], c01 = cov[(j0 + 1) * cols + i0], c11 = cov[(j0 + 1) * cols + i0 + 1];
          var cv = (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy;
          if (cv <= 0) continue;
          var X = ox + px, Y = oy + py, o = (py * wpx + px) * 4, t, a;
          var u = h3(seed, X, Y);
          if (u >= cv) {
            /* Light only: not lit itself, but it may be the SHADOW SIDE of a lit facet up-light of it. A glint on a
               light ground is a point that catches the lamp next to a point that does not; the pair is what reads
               as glitter rather than as a lightening fog. Deterministic per pixel, so tiles meet seamlessly. */
            if (!hasFacet) continue;
            var FX = X - facetDX, FY = Y - facetDY;
            if (h3(seed, FX, FY) >= cv) continue;
            var fw = h3(seed + 104729, FX, FY), fti = pick(fw, (FX) / dpr, (FY) / dpr, f.W, f.H);
            var fc = tints[fti].facet; if (!fc || h3(seed + 31337, FX, FY) >= fc.p) continue;
            var fv = h3(seed + 7919, FX, FY), sc = fc.shadow;
            if (fc.vMin != null && fv < fc.vMin) continue; /* only the brighter glints are faceted */
            var fq = fc.vMin != null ? (fv - fc.vMin) / (1 - fc.vMin) : fv; /* the brighter the glint, the deeper its shadow */
            a = state.caps[sc] * (fc.min + (1 - fc.min) * fq);
            t = tints[sc].rgb;
            d[o] = t[0]; d[o + 1] = t[1]; d[o + 2] = t[2]; d[o + 3] = Math.floor(a * 255); /* floor: never above the cap */
            continue;
          }
          var v = h3(seed + 7919, X, Y), w = h3(seed + 104729, X, Y);
          var ti = pick(w, X / dpr, Y / dpr, f.W, f.H);
          a = state.caps[ti] * (curveMin(ti) + (1 - curveMin(ti)) * Math.pow(v, curveK(ti)));
          t = tints[ti].rgb;
          d[o] = t[0]; d[o + 1] = t[1]; d[o + 2] = t[2]; d[o + 3] = Math.floor(a * 255); /* floor: never above the cap */
        }
      }
      g.putImageData(img, 0, 0);
      if (state.tiles.size > 48) state.tiles.delete(state.tiles.keys().next().value);
      state.tiles.set(key, c); return c;
    }

    function draw() {
      var cfg = state.cfg, dpr = state.dpr;
      if (!canvas.width || !canvas.height) return; /* a hidden host (display:none) has no size yet; the ResizeObserver rebuilds when it shows */
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (opts.paintGround) { var pg = opts.paintGround(state.theme); if (pg) { ctx.fillStyle = pg; ctx.fillRect(0, 0, canvas.width, canvas.height); } }
      if (!cfg) return;
      var page = cfg.space === "page", sx = page ? (global.scrollX || 0) : 0, sy = page ? (global.scrollY || 0) : 0;
      lctx.setTransform(1, 0, 0, 1, 0, 0); lctx.globalCompositeOperation = "source-over"; lctx.clearRect(0, 0, layer.width, layer.height);
      var wpx = Math.round(TILE * dpr), f = fieldSize();
      for (var ty = Math.floor(sy / TILE); ty * TILE < sy + state.vh && ty * TILE < f.H; ty++)
        for (var tx = Math.floor(sx / TILE); tx * TILE < sx + state.vw && tx * TILE < f.W; tx++)
          lctx.drawImage(tile(tx, ty), tx * wpx - Math.round(sx * dpr), ty * wpx - Math.round(sy * dpr));
      if (cfg.shape && !reduce) { /* the slow shimmer: a moving light shape multiplies the field's alpha */
        lctx.globalCompositeOperation = "destination-in";
        lctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        cfg.shape(lctx, (performance.now() - state.t0) / 1000, state.vw, state.vh);
        lctx.setTransform(1, 0, 0, 1, 0, 0); lctx.globalCompositeOperation = "source-over";
      }
      ctx.drawImage(layer, 0, 0);
    }

    var last = 0;
    function frame(now) {
      state.raf = 0;
      if (state.dead) return;
      var live = !!(state.cfg && state.cfg.shape && !reduce && !doc.hidden);
      if (now - last >= 40 || !live) { last = now; draw(); }
      if (live) state.raf = requestAnimationFrame(frame);
    }
    function schedule() { if (!state.raf && !state.dead) state.raf = requestAnimationFrame(frame); }

    var rebuildTimer = 0;
    function rebuildSoon() { clearTimeout(rebuildTimer); rebuildTimer = setTimeout(function () { if (state.dead) return; size(); build(); schedule(); }, 120); }
    function onMotion(e) { reduce = e.matches; build(); schedule(); }

    size(); build(); schedule();
    global.addEventListener("resize", rebuildSoon);
    global.addEventListener("scroll", schedule, { passive: true });
    var ro = null, mo = null;
    if (global.ResizeObserver) { ro = new ResizeObserver(function () { var s = docSize(); if (s.W !== state.W || s.H !== state.H) rebuildSoon(); }); ro.observe(host || doc.body); }
    if (global.MutationObserver) { mo = new MutationObserver(function () { rebuildSoon(); }); mo.observe(doc.documentElement, { attributes: true, attributeFilter: ["data-theme"] }); }
    if (mq.addEventListener) mq.addEventListener("change", onMotion);
    doc.addEventListener("visibilitychange", schedule);

    /* destroy(): the way out. Removes the canvas and every listener; the host is left as it was. */
    function destroy() {
      if (state.dead) return; state.dead = true;
      clearTimeout(rebuildTimer); if (state.raf) cancelAnimationFrame(state.raf); state.raf = 0;
      global.removeEventListener("resize", rebuildSoon); global.removeEventListener("scroll", schedule);
      if (ro) ro.disconnect(); if (mo) mo.disconnect();
      if (mq.removeEventListener) mq.removeEventListener("change", onMotion);
      doc.removeEventListener("visibilitychange", schedule);
      state.tiles.clear(); if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
    }

    return { rebuild: function () { if (state.dead) return; size(); build(); schedule(); }, report: function () { return state.report; }, destroy: destroy, canvas: canvas };
  }

  /* ===============================================================================================
     THE PRESETS — the four configurations he chose, value for value.
     Sources, frozen: round-15/desktop.html (dark desktop), round-15/mobile.html (dark phone),
     round-15/v6-light-2/desktop.html (light desktop), round-15/v6-light-2/mobile.html (light phone).
     Nothing here is tuned; anything that differs from those files is a defect in this file.
     =============================================================================================== */
  var GROUND_DARK = [12, 19, 34];            /* #0C1322, the ruled dark ground */
  var PAPER = [234, 230, 221];               /* #EAE6DD, the ruled light ground, UNLIT — the darkest a point can land on */
  var RAIL_LIGHT = [228, 223, 211];          /* the light rail: rgba(134,113,54,.06) over the paper, exactly */
  var INK_DARK = [223, 228, 238], INK_LIGHT = [12, 19, 34];

  /* The text colors round 15 draws DIRECTLY on the ground, per surface and theme. Each cap is solved so that every one
     of these keeps 4.55:1 against a point at its strongest. Several are the app's own unruled tones (design-system
     GAPS 2-4: trim-text, gold-text, danger, the muted inks); they are listed because they are what the app draws on
     the ground TODAY, and the cap has to hold for what is drawn. When a ruling replaces one of them, replace it here. */
  var PAIRS_DARK = [
    { rgb: INK_DARK, a: 1, name: "ink" }, { rgb: INK_DARK, a: 0.72, name: "ink-soft" }, { rgb: INK_DARK, a: 0.62, name: "ink-faint" },
    { rgb: [126, 146, 184], a: 1, name: "trim-text" }, { rgb: [194, 163, 92], a: 1, name: "gold" },
    { rgb: [143, 149, 160], a: 1, name: "rich-name" }, { rgb: [164, 169, 181], a: 1, name: "your-team" }
  ];
  var PAIRS_LIGHT_DESKTOP = [
    { rgb: INK_LIGHT, a: 1, name: "ink" }, { rgb: INK_LIGHT, a: 0.72, name: "ink-soft" }, { rgb: INK_LIGHT, a: 0.64, name: "ink-faint" },
    { rgb: [68, 86, 122], a: 1, name: "trim-text" }, { rgb: [113, 87, 21], a: 1, name: "gold-text" }
  ];
  var PAIRS_LIGHT_MOBILE = [
    { rgb: INK_LIGHT, a: 1, name: "ink" }, { rgb: INK_LIGHT, a: 0.72, name: "ink-soft" }, { rgb: [138, 47, 40], a: 1, name: "danger" }
  ];

  /* DARK: a cool sheen with a little warm gold in it. */
  function tintsDark() { return [{ name: "cool", rgb: [214, 226, 250], w: 85 }, { name: "gold", rgb: [240, 208, 140], w: 15 }]; }
  /* LIGHT: glitter on paper is color — champagne gold carries it, a pearl's rose and aqua for the iridescence, and the
     brighter points carry their lit side, a white point one device pixel up-left, toward the lamp. `max` is the design
     ceiling under the solved cap; `facet` is the lit-side pairing; `shadow: 3` names the "lit side" tint below. */
  function spark(name, rgb, w, max, k) { return { name: name, rgb: rgb, w: w, max: max, curve: { min: 0.12, k: k }, facet: { p: 0.7, vMin: 0.55, shadow: 3, min: 0.55 } }; }
  function tintsLight() { return [spark("gold", [255, 186, 30], 62, 0.85, 2.4), spark("rose", [255, 110, 150], 19, 0.6, 2.6), spark("aqua", [40, 200, 235], 19, 0.64, 2.6), { name: "lit side", rgb: [255, 255, 255], w: 0, max: 0.95 }]; }

  /* The lamp. Desktop: pooled at 58% of the width, mobile: centered and a little wider; both thin to nothing about
     two-thirds of the way down. Peak coverage 30% of pixels in dark, 24% in light. */
  function lampDesktop(peak) { return function (x, y, W, H) { var dx = (x - 0.58 * W) / (0.62 * W), dy = (y + 0.08 * H) / (0.62 * H); return peak * Math.exp(-(dx * dx + dy * dy)); }; }
  function lampMobile(peak) { return function (x, y, W, H) { var dx = (x - 0.5 * W) / (0.8 * W), dy = (y + 0.05 * H) / (0.6 * H); return peak * Math.exp(-(dx * dx + dy * dy)); }; }

  function copyPairs(p) { return p.map(function (q) { return { rgb: q.rgb.slice(), a: q.a, name: q.name }; }); }

  var PRESETS = {
    desktop: {
      dark: function () { return { seed: 15061, space: "fixed", ground: GROUND_DARK.slice(), floor: 4.55, textPairs: copyPairs(PAIRS_DARK), tints: tintsDark(), alphaCurve: { min: 0.12, k: 3 }, coverage: lampDesktop(0.3), shape: null }; },
      light: function () { return { seed: 15161, space: "fixed", grounds: [PAPER.slice(), RAIL_LIGHT.slice()], floor: 4.55, textPairs: copyPairs(PAIRS_LIGHT_DESKTOP), tints: tintsLight(), facetOffset: [-1, -1], alphaCurve: { min: 0.12, k: 2.6 }, coverage: lampDesktop(0.24), shape: null }; }
    },
    mobile: {
      dark: function () { return { seed: 15062, space: "fixed", ground: GROUND_DARK.slice(), floor: 4.55, textPairs: copyPairs(PAIRS_DARK), tints: tintsDark(), alphaCurve: { min: 0.12, k: 3 }, coverage: lampMobile(0.3), shape: null }; },
      light: function () { return { seed: 15162, space: "fixed", grounds: [PAPER.slice()], floor: 4.55, textPairs: copyPairs(PAIRS_LIGHT_MOBILE), tints: tintsLight(), facetOffset: [-1, -1], alphaCurve: { min: 0.12, k: 2.6 }, coverage: lampMobile(0.24), shape: null }; }
    }
  };

  /* The ruled grounds the canvas paints under the speckle, per theme (tokens.css --ground). */
  var GROUND_CSS = { dark: "#0c1322", light: "#eae6dd" };

  /* ===============================================================================================
     THE RULE, enforced. His words, 2026-09-29.
     =============================================================================================== */
  var RULE = "The splash screens on desktop and mobile apps as well as the desktop app home screen should never have that speckled background design.";
  var NEVER = {
    splash: "the splash screen (desktop or mobile)",
    home: "the desktop app home screen"
  };

  /* preset(surface, theme) → a fresh configuration object an app may extend before mount() */
  function preset(surface, theme) {
    if (NEVER[surface]) throw new Error("RichOSSpeckle: no speckle preset exists for " + NEVER[surface] + ". CEO rule, 2026-09-29: \"" + RULE + "\"");
    if (!PRESETS[surface]) throw new Error("RichOSSpeckle: unknown surface \"" + surface + "\"; the surfaces are \"desktop\" and \"mobile\".");
    if (theme !== "dark" && theme !== "light") throw new Error("RichOSSpeckle: unknown theme \"" + theme + "\"; the themes are \"dark\" and \"light\".");
    return PRESETS[surface][theme]();
  }

  /* background(opts) — the one call. See the head of this file. */
  function background(opts) {
    opts = opts || {};
    var surface = opts.surface;
    if (NEVER[surface]) throw new Error("RichOSSpeckle.background: refused for " + NEVER[surface] + ". CEO rule, 2026-09-29: \"" + RULE + "\"");
    if (!PRESETS[surface]) throw new Error("RichOSSpeckle.background: `surface` must be \"desktop\" or \"mobile\" (got " + JSON.stringify(surface) + ").");
    var themes = {};
    ["dark", "light"].forEach(function (t) {
      var cfg = preset(surface, t);
      if (opts.textPairs && opts.textPairs[t]) cfg.textPairs = copyPairs(opts.textPairs[t]);
      if (opts.extraTextPairs) {
        var extra = Array.isArray(opts.extraTextPairs) ? opts.extraTextPairs : (opts.extraTextPairs[t] || []);
        cfg.textPairs = cfg.textPairs.concat(copyPairs(extra));
      }
      themes[t] = cfg;
    });
    var themeOf = opts.themeOf || (opts.theme ? function () { return opts.theme; } : null);
    var paint = opts.paintGround === false ? null : (typeof opts.paintGround === "function" ? opts.paintGround : function (theme) { return GROUND_CSS[theme] || GROUND_CSS.dark; });
    var mounted = mount({
      parent: opts.parent || null, insertFirst: true, zIndex: opts.zIndex == null ? -1 : opts.zIndex,
      className: opts.className || "speckle", style: opts.style || "",
      themeOf: themeOf || undefined, paintGround: paint, themes: themes
    });
    mounted.surface = surface;
    return mounted;
  }

  global.RichOSSpeckle = {
    mount: mount, background: background, preset: preset,
    PRESETS: PRESETS, RULE: RULE, NEVER: NEVER, GROUND: GROUND_CSS,
    capAlpha: capAlpha, worstAt: worstAt, ratio: ratio, over: over, lum: lum
  };
})(window);
