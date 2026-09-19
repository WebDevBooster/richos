// WHICH COMMITTED SHOTS ARE ALLOWED TO DIFFER FROM RUN TO RUN, BY HOW MUCH, AND WHY.
//
// WHY THIS FILE EXISTS. `lib/png.js` stopped the tree going dirty for the wrong reason — two
// PNGs holding the same picture — and `lib/harness.js` writes a committed shot only when a
// decoded sample actually differs. That left a smaller, harder problem, and this file is it: a
// handful of surfaces are NOT the same picture twice, because the thing photographed is still
// moving. Measured here on 2026-09-19 against `5f3a1a1e`, over five consecutive same-source
// runs of every suite that writes shots, and again over two more from the regenerated tree at
// `a1c65c3a`: 104 of the 131 committed shots differed only because the product had changed and
// nobody had regenerated them, 7 differed from one run to the next, and 11 did so at least once
// across the seven.
//
// THE 104 WERE THE REAL DAMAGE. `git checkout -- richos/app/ui/tests/shots-*` after a run was
// the standing habit, and every one of those reverts threw away a legitimately updated
// reference — the settings button had moved 12px and the phone sheet had grown a footer bar,
// and neither change reached the committed record for days. A reference that is dirty after
// every run trains everybody to discard it, and then it protects nothing.
//
// SO THE RULE IS: A DIFFERENCE IS EITHER SIGNAL OR IT IS DECLARED HERE, WITH ITS CAUSE, ITS
// MEASUREMENT AND ITS BOUND. There is no third setting and there is no global tolerance. A
// global tolerance would be a lie told about every file at once; a declaration is a claim about
// ONE file that names what is moving in it, and a claim can be checked, argued with and
// removed.
//
// WHAT A BOUND IS FOR. It is not there to make a run quiet. It is there so that the part of the
// picture that is genuinely moving cannot hide a change that is not. Every bound below is set
// ABOVE everything that was measured and BELOW what the smallest real regression would produce
// — a palette flip is 100% of the pixels, a layout shift is thousands of pixels at full
// channel delta, and the `splash-01` canary of 2026-09-05 was 88% at delta 63. Each entry says
// which of its numbers is the measurement and which is the bound.
//
// AND A HELD SHOT IS NEVER SILENT. `publishShot` prints the file, the class, the measured
// difference and the bound it was held under, on every run, exactly as it prints a shot that
// changed. "Named rather than excused" is the whole of the arrangement: the line in the run's
// output is what makes a bound that has quietly grown into a blindfold visible to the next
// person who reads it.
//
// TO REGENERATE ONE DELIBERATELY: `RICHOS_SHOTS_REGENERATE=shots-home/home-named.png node
// home.js`, or a comma-separated list, a directory (`shots-home`), or `all`. Regeneration
// ignores every bound below and writes whenever the picture differs at all — which is what a
// deliberate regeneration means.

"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const png = require("./png");

const TESTS_DIR = path.resolve(__dirname, "..");

// ---------------------------------------------------------------------------------------
// THE DECLARATION
// ---------------------------------------------------------------------------------------
//
// `measured` is what seven consecutive same-source runs produced on 2026-09-19, and it is the
// evidence for the bound beside it — every figure is a `shot changed`/`shot held` line from a
// real run, not an estimate. `source` is the file:line that makes the picture move, so the next
// reader can go and look rather than take this file's word for it.
//
// A bound is one or both of:
//   maxChannelDelta   the largest per-channel difference any pixel may show
//   maxPixelFraction  the largest fraction of the image that may differ at all
// ALL bounds an entry declares must hold, or the shot is written and announced.

const DECLARED = [
  // -------------------------------------------------------------------------------------
  // CLASS 1 — THE LIVE FIELD, RUNNING.
  // -------------------------------------------------------------------------------------
  //
  // `home/field-engine.js:1031` integrates 7,500 objects on springs and flies packets along
  // 12,817 links, every frame, off `performance.now()`. Its randomness is seeded
  // (`mulberry32(6401)`, `field-engine.js:106`) and there is no `Math.random` anywhere in it —
  // the wall clock is the only thing about the picture that is not reproducible. Two runs
  // therefore photograph the same field at two different moments in its own life, and roughly
  // a fifth of the frame is somewhere else.
  //
  // IT CANNOT BE FROZEN INTO A BYTE-EQUAL SHOT, and that is measured rather than assumed. A
  // test-side frame clock — `performance.now()` replaced by a counter advancing one 60Hz step
  // per animation frame — was built and measured on 2026-09-05: two loads paused at the same
  // frame went from 44,039 differing samples to 293. 293, not 0. The residue is the blur/glow
  // framebuffer passes, which are floating-point and order-dependent on the GPU. So a frame
  // clock would buy a smaller envelope at the cost of a clock override across three large
  // suites, and it would STILL need an entry here. The envelope is set from the picture as it
  // ships.
  {
    file: "shots-home/home-named.png",
    class: "the live field, running",
    source: "app/ui/home/field-engine.js:1031 (`frame()` off `performance.now()`)",
    measured: "7 runs: 6.0829%, 22.4992%, 22.5146%, 22.7613%, 22.9008%, 22.9893%, 24.9046% of pixels, delta 234-253",
    bound: { maxPixelFraction: 0.35 },
    why:
      "A fifth of this frame is the field's own motion. 35% is above every measurement and " +
      "well below a palette flip (100%) or a layout shift; anything structural exceeds it.",
  },
  {
    file: "shots-home/home-returned.png",
    class: "the live field, running",
    source: "app/ui/home/field-engine.js:1031 (`frame()` off `performance.now()`)",
    measured: "7 runs: 14.0804%, 23.1111%, 24.0682%, 24.1225%, 24.3658%, 24.7527%, 25.1364% of pixels, delta 239-247",
    bound: { maxPixelFraction: 0.35 },
    why: "As `home-named`; this one is photographed just after `resume()`, so it moves slightly more.",
  },
  {
    file: "shots-home/home-anonymized.png",
    class: "the live field, running",
    source: "app/ui/home/field-engine.js:1031 (`frame()` off `performance.now()`)",
    measured: "7 runs: 6.4448%, 7.4204%, 17.1735%, 17.4061%, 17.5236%, 17.6735%, 17.7684% of pixels, delta 205-248",
    bound: { maxPixelFraction: 0.35 },
    why: "As `home-named`. The spread is wide because the labels are masked, so what moves is the field alone.",
  },

  // -------------------------------------------------------------------------------------
  // CLASS 2 — THE COMPOSITOR'S OWN DITHER.
  // -------------------------------------------------------------------------------------
  //
  // A gradient drawn over a large area is dithered by WebKit's compositor, and the dither is
  // not stable across page loads. Nothing on the surface has MOVED: the worst per-channel
  // difference is 2 of 255, scattered, with no edge anywhere. It is not something a suite can
  // wait for, because there is no state that is "after" it.
  //
  // THE BOUND IS THE DELTA, NOT THE AREA, AND THAT IS THE POINT. `splash-01-round-11-v1.png`
  // drifted for a day in 2026-09-05 at 88.46% of pixels and delta 63 — a photograph of the
  // home screen through a curtain at opacity 0 — and nothing failed, because the guard of the
  // day asked only whether `#splash` was still in the DOM. A bound of "delta <= 2" fails that
  // drift on the spot while holding the dither, which an area bound would not.
  {
    file: "shots-splash/material-round-11-v1.png",
    class: "compositor dither over a gradient",
    source: "WebKit's compositor; the mat is a gradient in `app/ui/splash.js`'s material layer",
    measured: "7 runs: 0.0717%, 0.0896%, 0.2281%, 0.2496%, 0.2553%, 0.4040%, 0.5862% of pixels, worst channel delta 2 in every one",
    bound: { maxChannelDelta: 2 },
    why:
      "2 of 255 on a gradient is the compositor's dither and cannot be a visible regression. " +
      "Anything that moved an edge, a glyph or a color shows a delta far above 2.",
  },
  {
    file: "shots-splash/material-round-11-v2.png",
    class: "compositor dither over a gradient",
    source: "WebKit's compositor; the mat is a gradient in `app/ui/splash.js`'s material layer",
    measured: "7 runs: 0.1744%, 0.1983%, 0.2947%, 0.3440%, 0.5285%, 0.6331%, 0.7719% of pixels, worst channel delta 2 in every one",
    bound: { maxChannelDelta: 2 },
    why: "As `material-round-11-v1`.",
  },
  {
    file: "shots-contrast/inspector.png",
    class: "compositor dither over a gradient",
    source: "WebKit's compositor; the inspector pane's ground",
    measured: "7 runs: unchanged in three of them, then 0.5181%, 0.5208%, 0.5208%, 0.5224% of pixels, worst channel delta 2, 2, 2 and 3",
    bound: { maxChannelDelta: 3 },
    why:
      "Does not differ on every run, which is why `measured` says how often. The 2026-09-05 note " +
      "on this file named the `WORKING` pulse dot at 25 pixels; `pinLoops` took that, and what " +
      "is left is dither. 3 rather than 2 because one of the four transitions measured 3, and a " +
      "bound set under a measurement is a bound that will be waived on the day it fires.",
  },

  // -------------------------------------------------------------------------------------
  // CLASS 3 — A LIVE COUNTER THE FIXTURE DOES NOT ANCHOR.
  // -------------------------------------------------------------------------------------
  //
  // §26's clock IS injected: `setMemoryStrategyAnchor` puts the turn 18.6s past its lease
  // handoff so the row reads `Working for 18s`, and `memory-strategy.js`'s `evidence()` now
  // pins the page's wall clock to that same instant for the length of every capture, through
  // the product's own visibility recompute. That took five of the nine shots from drifting by
  // 176-617 pixels to not drifting at all.
  //
  // WHAT IS LEFT IS ONE ROW THE FIXTURE NEVER ANCHORED. §26.12 opens a SECOND Sage run, and
  // `mock.js` stamps that run's `startedAt` from the real clock at the moment the walk applies
  // step 12. Its elapsed is therefore `pinned_now - whenever_the_walk_got_there`, and the walk
  // gets there a few hundred milliseconds apart on consecutive runs — so the seconds digit of
  // one right-aligned counter changes, and nothing else in the frame does. Measured: a 10x14
  // box at x[1162..1171], `31s` in one run and `32s` in the next.
  //
  // THIS IS A FIXTURE GAP AND IT IS NAMED RATHER THAN BOUGHT OFF. Anchoring the replacement
  // run's start the way the first one is anchored — `ui/mock.js`'s `memoryStrategy` step 12,
  // beside `setMemoryStrategyAnchor` at `ui/mock.js:3503` — removes this entry entirely. The
  // bound below is deliberately the tightest in this file: 0.02% of the frame is about 276
  // pixels, which is two glyphs. Anything larger than a changed digit fails it.
  {
    file: "shots-26/ms-04-run-ended-with-recovery-commentary.png",
    class: "one unanchored elapsed counter (the §26.12 replacement run)",
    source: "app/ui/main.js:1437 `updateTimers`, over a `startedAt` app/ui/mock.js stamps from the real clock",
    measured: "3 transitions after the clock pin: 79 pixels (0.0057%) every time, worst channel delta 135 — one digit",
    bound: { maxPixelFraction: 0.0002 },
    why:
      "0.02% of this frame is 276 pixels, roughly two glyphs. A changed digit fits; a changed " +
      "word, a moved row or a palette shift does not.",
  },
  {
    file: "shots-26/ms-05-worker-detail-beside-thread.png",
    class: "one unanchored elapsed counter (the §26.12 replacement run)",
    source: "app/ui/main.js:1437 `updateTimers`, over a `startedAt` app/ui/mock.js stamps from the real clock",
    measured: "3 transitions after the clock pin: 116 pixels (0.0084%) every time, worst channel delta 135 — one digit",
    bound: { maxPixelFraction: 0.0002 },
    why: "As `ms-04`; the same counter, with the inspector pane open beside it.",
  },
];

// ---------------------------------------------------------------------------------------

const BY_FILE = new Map();
for (const d of DECLARED) {
  if (BY_FILE.has(d.file)) {
    throw new Error("lib/shot-stability.js declares " + d.file + " twice — one file, one claim");
  }
  BY_FILE.set(d.file, Object.freeze(d));
}

/// `shots-home/home-named.png` for an absolute path under the tests directory; null for
/// anything else (`.shots/` scratch, a path outside this tree).
function relKey(file) {
  const rel = path.relative(TESTS_DIR, path.resolve(file));
  if (rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join("/");
}

/// The declaration for a destination file, or null.
function ruleFor(file) {
  const key = relKey(file);
  return key ? BY_FILE.get(key) || null : null;
}

/// Is this file being regenerated deliberately? `RICHOS_SHOTS_REGENERATE` takes `all`, a
/// comma-separated list of `shots-x/y.png` paths, or a directory name (`shots-home`).
function regenerating(file) {
  const raw = (process.env.RICHOS_SHOTS_REGENERATE || "").trim();
  if (!raw) return false;
  const key = relKey(file);
  if (!key) return false;
  for (const piece of raw.split(",")) {
    const want = piece.trim().replace(/\/+$/, "");
    if (!want) continue;
    if (want === "all") return true;
    if (want === key) return true;
    if (key.startsWith(want + "/")) return true;
  }
  return false;
}

/// Does the difference between a committed shot and a fresh one stay inside what this file
/// declares for it?
///
/// Returns `{ held, measurement, bound }`. `held` is FALSE for anything this cannot prove —
/// an undeclared file, an unreadable PNG, a change of dimensions — for the same reason
/// `samePicture` is false in the same cases: a redundant write costs a line in `git status`,
/// and a wrongly-held shot costs a regression nobody sees.
function heldBy(rule, existing, fresh) {
  if (!rule) return { held: false, measurement: null, bound: null };
  const m = png.measureDifference(existing, fresh);
  if (!m.ok) return { held: false, measurement: null, bound: describeBound(rule.bound) };
  let held = true;
  if (rule.bound.maxChannelDelta !== undefined && m.worst > rule.bound.maxChannelDelta) held = false;
  if (rule.bound.maxPixelFraction !== undefined && m.fraction > rule.bound.maxPixelFraction) held = false;
  return { held, measurement: m, bound: describeBound(rule.bound) };
}

/// The bound, in the words the run prints. PRECISION SCALES WITH THE BOUND, because the tightest
/// entries in this file are the ones worth reading: `shots-26`'s 0.0002 printed as "at most 0.0%
/// of pixels" at one decimal place, which reads as "at most nothing" and tells the next person
/// neither what was allowed nor that it was deliberately the tightest claim here.
function describeBound(bound) {
  const parts = [];
  if (bound.maxChannelDelta !== undefined) parts.push("worst channel delta <= " + bound.maxChannelDelta);
  if (bound.maxPixelFraction !== undefined) {
    const pct = bound.maxPixelFraction * 100;
    parts.push("at most " + (pct < 1 ? pct.toFixed(4).replace(/0+$/, "").replace(/\.$/, "") : pct.toFixed(1)) + "% of pixels");
  }
  return parts.join(" and ");
}

// ---------------------------------------------------------------------------------------
// The self-test
// ---------------------------------------------------------------------------------------
//
// THE SAME REASON `lib/png.js` SELF-TESTS ITS DECODER. Every line of this file is a decision
// to NOT write a file, which is the one failure mode that does not announce itself: a bound
// that is wrong, or that names a file which no longer exists, makes a run quieter rather than
// louder. So both halves are proved at require time, before a suite can reach them.
//
//   1. EVERY DECLARED FILE EXISTS. A suite renamed or a shot deleted leaves a claim here about
//      nothing, and a claim about nothing is how a table becomes decoration.
//   2. THE ARITHMETIC SAYS NO. A bound that held everything would pass any test that only
//      checked it held the thing it was written for, so the probe below is symmetric: a delta
//      of exactly the bound is held, a delta one greater is NOT, and the same for the area.
(function selfTest() {
  const missing = DECLARED.map((d) => d.file).filter((f) => !fs.existsSync(path.join(TESTS_DIR, f)));
  if (missing.length) {
    throw new Error(
      "lib/shot-stability.js declares shots that do not exist, so those claims are about " +
        "nothing:\n  " +
        missing.join("\n  ")
    );
  }
  for (const d of DECLARED) {
    if (!d.bound || (d.bound.maxChannelDelta === undefined && d.bound.maxPixelFraction === undefined)) {
      throw new Error("lib/shot-stability.js: " + d.file + " declares no bound, which excuses everything");
    }
    for (const field of ["class", "source", "measured", "why"]) {
      if (!d[field] || String(d[field]).trim().length < 8) {
        throw new Error("lib/shot-stability.js: " + d.file + " has no usable `" + field + "` — a bound with no reason is a mute button");
      }
    }
  }

  // A 4x4 RGB PNG builder, using `lib/png.js`'s own accepted shape (chunk CRCs are not
  // verified by that decoder and are written zero here, exactly as its own fixture does).
  const build = (pixels) => {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(4, 0);
    ihdr.writeUInt32BE(4, 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    const raw = Buffer.alloc(4 * (4 * 3 + 1));
    let p = 0;
    for (let y = 0; y < 4; y++) {
      raw[p++] = 0;
      for (let x = 0; x < 4; x++) {
        const v = pixels[y * 4 + x];
        raw[p++] = v;
        raw[p++] = v;
        raw[p++] = v;
      }
    }
    const chunk = (type, data) => {
      const len = Buffer.alloc(4);
      len.writeUInt32BE(data.length);
      return Buffer.concat([len, Buffer.from(type, "ascii"), data, Buffer.alloc(4)]);
    };
    return Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk("IHDR", ihdr),
      chunk("IDAT", zlib.deflateSync(raw)),
      chunk("IEND", Buffer.alloc(0)),
    ]);
  };
  const flat = new Array(16).fill(100);
  const base = build(flat);
  const byTwo = build(flat.map((v, i) => (i === 5 ? v + 2 : v)));
  const byThree = build(flat.map((v, i) => (i === 5 ? v + 3 : v)));
  const fourPixels = build(flat.map((v, i) => (i < 4 ? v + 1 : v)));

  const deltaRule = { bound: { maxChannelDelta: 2 } };
  if (!heldBy(deltaRule, base, byTwo).held) throw new Error("lib/shot-stability.js: a delta of exactly the bound is not held");
  if (heldBy(deltaRule, base, byThree).held) throw new Error("lib/shot-stability.js: a delta ABOVE the bound is held — the bound is a mute button");

  // 4 of 16 pixels is 25%.
  const areaRule = { bound: { maxPixelFraction: 0.25 } };
  if (!heldBy(areaRule, base, fourPixels).held) throw new Error("lib/shot-stability.js: an area of exactly the bound is not held");
  if (heldBy({ bound: { maxPixelFraction: 0.24 } }, base, fourPixels).held) {
    throw new Error("lib/shot-stability.js: an area ABOVE the bound is held");
  }
  // Both bounds must hold, not either.
  if (heldBy({ bound: { maxChannelDelta: 2, maxPixelFraction: 0.01 } }, base, byTwo).held) {
    throw new Error("lib/shot-stability.js: an entry with two bounds held when only one of them did");
  }
  // And nothing at all is held for an undeclared file or an unreadable side.
  if (heldBy(null, base, byTwo).held) throw new Error("lib/shot-stability.js: an undeclared file was held");
  if (heldBy(deltaRule, Buffer.from("not a png"), byTwo).held) {
    throw new Error("lib/shot-stability.js: an unreadable side was held rather than written");
  }
})();

module.exports = { DECLARED, ruleFor, regenerating, heldBy, describeBound, relKey };
