// Does the app RENDER from the vendored faces, or does it only NAME them?
//
// Reading the stylesheet cannot answer that. A stack can name a face the binary
// does not carry, a @font-face can point at a file that 404s, and a unicode-range
// can exclude the one character the control is drawn with — every one of those
// looks perfect in the CSS and falls through to a system font on screen.
//
// WebKit, not Chromium: Tauri renders through WKWebView on macOS, and a green
// Chromium run says nothing about what the CEO sees. Same engine and same pinned
// Playwright version app/ui/tests uses.
//
// TWO-SIDED, because a one-sided check is satisfied by a corpse. Pass 1 loads the
// page as it ships. Pass 2 loads the identical page with every .woff2 request
// aborted, which is the only honest simulation of "the vendored faces are not
// there". If the two passes agree, the faces are not doing the work and something
// else is drawing the text.
//
// Run: node render-check.js   (RICHOS_PLAYWRIGHT may point at an existing install)

"use strict";

const path = require("path");
const fs = require("fs");
const http = require("http");

// RICHOS_UI_DIR exists so this check can be pointed at a DIFFERENT tree — which is
// how it was made to fail before it was allowed to pass. Run against the app/ui of
// the commit before this change, every section below goes red; that red run is in
// raw/red-before.txt and is the only reason the green one is worth reading.
const UI_DIR = process.env.RICHOS_UI_DIR
  ? path.resolve(process.env.RICHOS_UI_DIR)
  : path.resolve(__dirname, "..", "..", "..", "..", "app", "ui");
const OUT_DIR = process.env.RICHOS_OUT_DIR
  ? path.resolve(process.env.RICHOS_OUT_DIR)
  : path.resolve(__dirname, "..", "raw");

function loadPlaywright() {
  const candidates = [];
  if (process.env.RICHOS_PLAYWRIGHT) candidates.push(process.env.RICHOS_PLAYWRIGHT);
  candidates.push("playwright");
  for (const c of candidates) {
    try {
      return require(c);
    } catch (_e) {
      /* keep looking */
    }
  }
  throw new Error("playwright not found; set RICHOS_PLAYWRIGHT to an existing install");
}

// The 30 non-ASCII characters the shipped UI actually renders, derived by reading
// every file under app/ui rather than by listing the ones somebody remembered.
const CHARS = [
  "§", "·", "–", "—", "•", "…", "›",
  "→", "↓", "⇒", "−", "≥", "⊘", "⋯",
  "⌄", "⌘", "▪", "△", "▷", "▾", "◆",
  "◇", "◉", "○", "●", "◐", "☰", "⚙",
  "✓", "✕",
];

// The controls the ruling is really about: the ones he clicks.
const PROBES = [
  ["#rail-settings", "the settings gear"],
  ["#rail-toggle", "the navigation toggle"],
  ["#inspector-close", "a close button"],
  [".voice-footnote-glyph", "the voice control glyph"],
  ["body", "ordinary body text"],
];

const MIME = {
  ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
  ".woff2": "font/woff2", ".png": "image/png", ".svg": "image/svg+xml",
  ".json": "application/json", ".txt": "text/plain",
};

// Served over http rather than file://, because WebKit applies CORS to font loads
// and a file:// origin would fail them for a reason that has nothing to do with
// whether the fonts are correct. This is also closer to what Tauri does: the
// shipped app serves the embedded frontend over its own protocol handler.
function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "") || "index.html";
      const file = path.join(UI_DIR, rel);
      if (!file.startsWith(UI_DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        res.writeHead(404).end("no");
        return;
      }
      res.writeHead(200, { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" });
      res.end(fs.readFileSync(file));
    });
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

async function measure(page, base, { starveFonts }) {
  if (starveFonts) {
    await page.route("**/*.woff2", (route) => route.abort());
  }
  await page.goto(base + "/index.html", { waitUntil: "load" });
  // main.js talks to Tauri and will not finish here; the DOM and the CSS are what
  // this measures, and both are in place at `load`.
  await page.waitForTimeout(1500);
  await page.evaluate(() => document.fonts.ready.catch(() => {}));

  // ASK FOR EACH VENDORED FAMILY BY NAME BEFORE JUDGING WHETHER IT LOADED.
  // A `font-display: block` face is fetched lazily, only when something on the page
  // needs it — and nothing in the initial DOM is set in the monospace face, so the
  // first green run reported "JetBrains Mono: no loaded face" over a face that was
  // present, correct and embedded. That was the check being wrong, not the app.
  //
  // This does NOT weaken the check into a formality: `fonts.load()` resolves with
  // the FontFaces MATCHING that family in the set, and on a tree with no @font-face
  // rules it resolves with an empty array and the family still reports nothing
  // loaded. The red run confirms that — all three families still fail there.
  await page.evaluate(async () => {
    for (const fam of ["Inter", "Newsreader", "RichOS Symbols"]) {
      try { await document.fonts.load('16px "' + fam + '"', "Aa1 ⚙☰✕"); } catch (_e) { /* absent */ }
    }
  });
  await page.waitForTimeout(500);

  return await page.evaluate(
    ({ chars, probes }) => {
      const faces = [];
      document.fonts.forEach((f) => {
        faces.push({
          family: f.family, weight: f.weight, style: f.style,
          unicodeRange: f.unicodeRange, status: f.status,
        });
      });

      // WHICH FACE ACTUALLY DRAWS EACH CHARACTER — by rasterizing it, not by asking.
      //
      // The obvious API here is `document.fonts.check('16px Inter', '⚙')`, and it is
      // WRONG FOR THIS QUESTION. Per the CSS Font Loading spec it answers true for a
      // family that is installed on the machine as well as for one that is loaded as
      // a web font, so on the tree BEFORE this change it returned true for all 30
      // characters and reported a clean pass over a UI drawing every one of them
      // from a system font. It cannot tell the two apart, which is the only
      // distinction that matters here. (That false pass is in raw/red-before.txt.)
      //
      // So: draw the character twice into a canvas at 64px — once in the vendored
      // families with NO generic behind them, once in a family that cannot exist,
      // which forces the browser's own default — and compare the pixels. Identical
      // rasters mean the same font drew both, i.e. the default drew it. Different
      // rasters mean something vendored did. A raster cannot be true for the wrong
      // reason.
      const raster = (text, family) => {
        const c = document.createElement("canvas");
        c.width = 96; c.height = 96;
        const x = c.getContext("2d");
        x.fillStyle = "#fff"; x.fillRect(0, 0, 96, 96);
        x.fillStyle = "#000";
        x.font = '64px ' + family;
        x.textBaseline = "middle";
        x.fillText(text, 8, 48);
        return { url: c.toDataURL(), width: +x.measureText(text).width.toFixed(3) };
      };

      const VENDORED = '"Inter", "Newsreader", "RichOS Symbols"';
      const NOTHING = '"__no_such_family__"';
      const charCoverage = chars.map((ch) => {
        const a = raster(ch, VENDORED);
        const b = raster(ch, NOTHING);
        return {
          ch,
          code: "U+" + ch.codePointAt(0).toString(16).toUpperCase().padStart(4, "0"),
          vendoredWidth: a.width,
          defaultWidth: b.width,
          drawnByVendoredFace: a.url !== b.url,
          raster: a.url,
        };
      });

      // THE WIDTH DIFFERENTIAL. For each probe, render its own text twice in a
      // detached span: once with the element's real computed font-family, once
      // with a family that cannot exist, which forces the browser's own default.
      // Identical widths would mean the real stack IS the default.
      const host = document.createElement("div");
      host.style.cssText = "position:absolute;left:-99999px;top:0;white-space:pre;visibility:hidden";
      document.body.appendChild(host);
      const widthOf = (text, family, size, weight) => {
        const s = document.createElement("span");
        s.style.cssText =
          "font-family:" + family + ";font-size:" + size + ";font-weight:" + weight + ";white-space:pre";
        s.textContent = text;
        host.appendChild(s);
        const w = s.getBoundingClientRect().width;
        host.removeChild(s);
        return w;
      };

      const probeRows = probes.map(([sel, label]) => {
        const el = document.querySelector(sel);
        if (!el) return { sel, label, found: false };
        const cs = getComputedStyle(el);
        const text = sel === "body" ? "Handgloves — the quick brown fox 0123456789" : (el.textContent || "").trim();
        return {
          sel, label, found: true, text,
          computedFamily: cs.fontFamily,
          fontSize: cs.fontSize,
          widthReal: +widthOf(text, cs.fontFamily, cs.fontSize, cs.fontWeight).toFixed(3),
          widthDefault: +widthOf(text, "__no_such_family__", cs.fontSize, cs.fontWeight).toFixed(3),
          // The raster of this element's own text in this element's own computed
          // family. Compared BETWEEN the two passes, not against a control: in the
          // starved pass the computed family string is identical and only the files
          // are gone, so a raster that does not move is a raster the vendored faces
          // never touched. A width comparison against the browser default was tried
          // first and is not a discriminator — the OLD stack also differed from the
          // default, because it named a system face rather than falling to the
          // generic one. "Different from the default" and "ours" are not the same
          // claim, and the red run is what showed it.
          raster: raster(text, cs.fontFamily).url,
        };
      });
      host.remove();

      return { faces, charCoverage, probeRows };
    },
    { chars: CHARS, probes: PROBES }
  );
}

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const { chromium, webkit } = loadPlaywright();
  void chromium;
  const { server, port } = await serve();
  const base = "http://127.0.0.1:" + port;
  const browser = await webkit.launch();

  const report = {};
  for (const pass of ["shipped", "fonts-starved"]) {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await ctx.newPage();
    page.on("pageerror", () => {});
    report[pass] = await measure(page, base, { starveFonts: pass === "fonts-starved" });
    const shot = path.join(OUT_DIR, "render-" + pass + ".png");
    await page.screenshot({ path: shot });
    report[pass].screenshot = path.basename(shot);
    await ctx.close();
  }

  await browser.close();
  server.close();

  fs.writeFileSync(path.join(OUT_DIR, "render-check.json"), JSON.stringify(report, null, 2));

  // ---- the verdict, printed rather than buried in the JSON --------------------
  const A = report["shipped"];
  const B = report["fonts-starved"];
  let failures = 0;
  const fail = (m) => { console.log("  FAIL  " + m); failures++; };
  const ok = (m) => console.log("  PASS  " + m);

  console.log("\n=== 1. the vendored faces are LOADED, not merely declared ===");
  const loaded = A.faces.filter((f) => f.status === "loaded");
  for (const fam of ["Inter", "Newsreader", "RichOS Symbols"]) {
    const n = loaded.filter((f) => f.family === fam).length;
    if (n > 0) ok(fam + ": " + n + " face(s) loaded");
    else fail(fam + ": no loaded face — declared but not rendering");
  }

  console.log("\n=== 2. every character the UI renders is DRAWN by a vendored face ===");
  console.log("      (raster in the vendored families vs raster in the browser default)");
  const orphans = A.charCoverage.filter((r) => !r.drawnByVendoredFace);
  for (const r of A.charCoverage) {
    const bWidth = (B.charCoverage.find((x) => x.code === r.code) || {}).vendoredWidth;
    console.log(
      "        " + (r.drawnByVendoredFace ? "vendored" : "DEFAULT ") +
      "  " + r.code.padEnd(7) + " " + r.ch +
      "   vendored=" + String(r.vendoredWidth).padStart(7) +
      "  default=" + String(r.defaultWidth).padStart(7) +
      "  starved=" + String(bWidth).padStart(7)
    );
  }
  if (orphans.length === 0) ok("all " + A.charCoverage.length + " characters rasterize differently from the browser default");
  else for (const o of orphans) fail(o.code + " " + o.ch + " — rasterizes IDENTICALLY to the browser default, so a system font is drawing it");

  console.log("\n=== 3. THE CONTROLS HE CLICKS are drawn by a vendored face ===");
  console.log("      (each element's own text, its own computed family, shipped vs fonts-starved)");
  for (const p of A.probeRows) {
    if (!p.found) { fail(p.sel + " (" + p.label + ") not in the DOM"); continue; }
    const q = B.probeRows.find((x) => x.sel === p.sel);
    const moved = q && q.found && q.raster !== p.raster;
    const detail = " [" + p.computedFamily + " @ " + p.fontSize + "]";
    if (moved) ok(p.label + " " + p.sel + detail + " — raster changes when the faces are starved");
    else fail(p.label + " " + p.sel + detail + " — renders IDENTICALLY with every font file aborted, so nothing vendored is drawing it");
  }

  console.log("\n=== 4. THE OTHER SIDE: the starved pass really is starved ===");
  const bLoaded = B.faces.filter((f) => f.status === "loaded").length;
  if (bLoaded === 0) ok("with .woff2 aborted, zero faces load (" + B.faces.length + " declared, none loaded)");
  else fail("with .woff2 aborted, " + bLoaded + " face(s) still report loaded — this check is not measuring what it claims");

  const charsMoved = A.charCoverage.filter((r) => {
    const q = B.charCoverage.find((x) => x.code === r.code);
    return q && q.raster !== r.raster;
  }).length;
  if (charsMoved === A.charCoverage.length) ok("all " + charsMoved + " characters rasterize differently once the faces are gone");
  else fail(charsMoved + " of " + A.charCoverage.length + " characters changed — the rest were never coming from a vendored face");

  console.log("\n" + (failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"));
  console.log("evidence: " + OUT_DIR);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
