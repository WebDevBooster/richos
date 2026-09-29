#!/usr/bin/env node
// The speckled ground's reference numbers, computed by the design system's own engine.
//
// Runs richos-hq `design/system/speckle.js` (the file the CEO's 2026-09-29 ruling put in the design
// system) under Node with a minimal stand-in for the DOM, mounts `background({ surface: "mobile" })`
// at a given phone size and pixel density, and prints, per case: the solved caps, and the SHA-256 of
// the point field the engine writes (RGBA, row by row, before any compositing: exactly the bytes its
// tiles hand to putImageData, laid out where its draw loop places them). `SpeckleTest` compares the
// Android port (app/.../design/Speckle.kt) against these numbers, so the phone draws what the design
// system draws, point for point.
//
//   node bin/speckle-golden.mjs [path/to/speckle.js]
//   (default: ~/ab/richos-hq/design/system/speckle.js)
//
// Prints JSON. Nothing is written.
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import vm from "node:vm";

const enginePath = process.argv[2] || `${homedir()}/ab/richos-hq/design/system/speckle.js`;
const source = readFileSync(enginePath, "utf8");

// The colors the Android app draws directly on the ground that the mobile preset does not already
// list: dark's danger ("Not sent", the Forget row). Kept here and in Speckle.kt, one list.
const EXTRA = { dark: [{ rgb: [232, 131, 124], a: 1, name: "danger" }], light: [] };

// The cases: the design system's own 402 x 874 phone at DPR 2, a 1080 x 2400 phone at 2.625
// (the emulator's 420 dpi), and a 1440 x 3200 phone at 3.5 (the engine caps DPR at 3).
const CASES = [
  { theme: "dark", w: 402, h: 874, dpr: 2 },
  { theme: "light", w: 402, h: 874, dpr: 2 },
  { theme: "dark", w: 1080 / 2.625, h: 2400 / 2.625, dpr: 2.625 },
  { theme: "light", w: 1080 / 2.625, h: 2400 / 2.625, dpr: 2.625 },
  { theme: "dark", w: 1440 / 3.5, h: 3200 / 3.5, dpr: 3.5 },
];

function run({ theme, w, h, dpr }, extra) {
  const canvases = [];
  function canvas() {
    const c = { width: 0, height: 0, style: {}, className: "", draws: [], img: null, setAttribute() {} };
    c.getContext = () => ({
      setTransform() {}, clearRect() {}, fillRect() {},
      set fillStyle(_) {}, set globalCompositeOperation(_) {},
      createImageData: (iw, ih) => ({ width: iw, height: ih, data: new Uint8ClampedArray(iw * ih * 4) }),
      putImageData: (img) => { c.img = img; },
      drawImage: (src, x, y) => { c.draws.push({ src, x, y }); },
    });
    canvases.push(c);
    return c;
  }
  const host = { clientWidth: w, clientHeight: h, firstChild: null, insertBefore() {}, appendChild() {} };
  const document = {
    createElement: canvas, hidden: false,
    documentElement: { getAttribute: () => theme, clientWidth: w, clientHeight: h, scrollWidth: w, scrollHeight: h },
    body: host, addEventListener() {}, removeEventListener() {},
  };
  const win = {
    devicePixelRatio: dpr, innerWidth: w, innerHeight: h, scrollX: 0, scrollY: 0,
    addEventListener() {}, removeEventListener() {},
  };
  const ctx = vm.createContext({
    window: win, document, performance, Math, Map, Float32Array, Uint8ClampedArray, JSON, Array, Object, Error, String, Number, Infinity,
    requestAnimationFrame: () => 1, cancelAnimationFrame() {}, setTimeout: () => 0, clearTimeout() {},
  });
  vm.runInContext(source, ctx);
  const bg = win.RichOSSpeckle.background({ surface: "mobile", parent: host, theme, extraTextPairs: extra });
  const [main, layer] = canvases;
  const W = main.width, H = main.height, field = new Uint8Array(W * H * 4);
  for (const d of layer.draws) {
    const img = d.src.img, tw = img.width;
    for (let py = 0; py < img.height; py++) {
      const y = d.y + py; if (y < 0 || y >= H) continue;
      for (let px = 0; px < tw; px++) {
        const x = d.x + px; if (x < 0 || x >= W) continue;
        const s = (py * tw + px) * 4, o = (y * W + x) * 4;
        field[o] = img.data[s]; field[o + 1] = img.data[s + 1]; field[o + 2] = img.data[s + 2]; field[o + 3] = img.data[s + 3];
      }
    }
  }
  let lit = 0; for (let i = 3; i < field.length; i += 4) if (field[i]) lit++;
  const r = bg.report();
  return {
    theme, w, h, dpr, canvas: [W, H], caps: r.caps, worstRatio: r.worstRatio, worstPair: r.worstPair.name,
    litPixels: lit, sha256: createHash("sha256").update(field).digest("hex"),
  };
}

// The unrounded caps, from the engine's own solver, with and without the app's extra pairs.
function rawCaps(theme, extra) {
  const ctx = vm.createContext({ window: {}, Math, Map, JSON, Array, Object, Error, String, Number, Infinity });
  vm.runInContext(source, ctx);
  const S = ctx.window.RichOSSpeckle, cfg = S.preset("mobile", theme);
  const pairs = cfg.textPairs.concat(extra);
  return cfg.tints.map((t) => {
    let c = 1; (cfg.grounds || [cfg.ground]).forEach((g) => { c = Math.min(c, S.capAlpha(t.rgb, g, pairs, cfg.floor || 4.5)); });
    return t.max == null ? c : Math.min(c, t.max);
  });
}

const out = {
  engine: enginePath,
  engineSha256: createHash("sha256").update(source).digest("hex"),
  caps: {
    dark: rawCaps("dark", EXTRA.dark), light: rawCaps("light", EXTRA.light),
    darkPresetOnly: rawCaps("dark", []), lightPresetOnly: rawCaps("light", []),
  },
  cases: CASES.map((c) => run(c, EXTRA[c.theme])),
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
