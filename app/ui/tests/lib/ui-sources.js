// THE SHIPPED-SOURCE MANIFEST, DERIVED FROM THE TREE. NEVER TYPED.
//
// WHY THIS FILE EXISTS
// ====================
// Three gates in this directory each carried their own hand-written list of which files in
// `app/ui/` they look at, and every one of those lists had gone stale:
//
//   lib/state-strings.js  `UI_SOURCES = ["index.html", "main.js", "timeline.js"]`
//                         against nine `<script src>` tags in index.html. So the affordance
//                         rule — "every ACTIONABLE state names a control" — could not see
//                         `updates.js`, the surface the CEO ruled on the day it was found,
//                         nor `home.js`, `settings-button.js`, `splash.js`,
//                         `splash-library.js` or `theme-boot.js`.
//   tests/contrast.js     `SOURCE_FILES` = four of them, so check 12's exemption inventory
//                         could not see a `data-contrast-exempt` declared in the other five;
//                         `CSS_FILES` = two of the three linked stylesheets, missing the
//                         53 KB `home.css` entirely.
//
// The file that held the worst of them opens with the words "DERIVE THE USER-VISIBLE STATE
// INVENTORY FROM SOURCE. NEVER TYPE IT." A typed list under that header is not an oversight;
// it is the proof that a rule written as a sentence does not survive contact with a second
// author. So the lists are gone and this is the derivation that replaced them.
//
// HOW THE DERIVATION WORKS — THREE STEPS, ALL OFF DISK
// ===================================================
//   1. ENTRY.    `index.html` is the shell Tauri loads. Its `<script src>` and
//                `<link rel=stylesheet href>` tags, read out of the markup with comments
//                stripped, are the first generation.
//   2. CLOSURE.  Every JS file already in the set is scanned for string literals naming an
//                existing file under `app/ui/`, and those are added, repeatedly, until the
//                set stops growing. This is what reaches `home/field-*.js`: they are in no
//                script tag, they are loaded at runtime from `home.js:56`'s `FIELD` array,
//                and a manifest built only from `index.html` would have been a shorter list
//                that LOOKED derived. It is four more files than the nine `ls app/ui/*.js`
//                reports.
//   3. RECONCILE. Every `.js`/`.css`/`.html` file that actually exists under `app/ui/`
//                (`tests/` and `node_modules/` excluded — they do not ship) must be in the
//                closure. One that is not throws BY NAME. A file nobody loads is either a
//                gate's blind spot or dead weight in the bundle, and both are worth a
//                failure rather than a silent skip.
//
// THE ONE DECLARED LIST, AND WHY IT IS NOT THE DEFECT AGAIN
// ========================================================
// `ROLES` below classifies each discovered file. It is written down, because "is this file
// seeded preview data or is it product?" is a judgment no scanner can make. What stops it
// rotting is that it is RECONCILED IN BOTH DIRECTIONS against the derivation, every run:
//
//   * a discovered file with no role      -> throws, naming the file
//   * a role for a file nobody discovers  -> throws, naming the role
//
// So the list cannot be short (step 3 plus the first rule) and it cannot be stale (the
// second). That is the difference between a list that IS the inventory — the defect — and a
// list that is checked against one.
//
// RUN IT:  node lib/ui-sources.js     — prints the manifest and the reconciliation.

"use strict";

const fs = require("fs");
const path = require("path");

const UI_DIR = path.resolve(__dirname, "..", "..");
const ENTRY = "index.html";

/// What each shipped file is. Every row says WHY, because every row is a claim about
/// whether a gate needs to look at the file, and an undeclared claim is the defect above.
///
/// `role` is one of:
///   "ui"            product code or markup. Its user-visible strings are STATES, and every
///                   state-facing gate reads it.
///   "preview-data"  seeded data for the browser preview. Its strings are sample content,
///                   not states the product can enter (`state-strings.js` blind spot B4).
///                   Scanned separately and reported, never folded into the inventory.
///   "style"         a stylesheet. No string inventory; read by the contrast gate for
///                   declared exemptions and color literals.
const ROLES = {
  "index.html": { role: "ui", why: "the shell Tauri loads" },
  "main.js": { role: "ui", why: "the chat surface and the bridge" },
  "timeline.js": { role: "ui", why: "the working timeline's model and render" },
  "home.js": { role: "ui", why: "the home screen the CEO lands on" },
  "updates.js": { role: "ui", why: "the update surface — CEO ruling §26" },
  "settings-button.js": { role: "ui", why: "the universal settings button — CEO ruling §15" },
  "splash.js": { role: "ui", why: "the opening curtain's renderer" },
  "splash-library.js": { role: "ui", why: "the two approved splash compositions — data, with prose in it" },
  "theme-boot.js": { role: "ui", why: "the pre-paint theme mirror" },
  "home/field-engine.js": { role: "ui", why: "the home screen's WebGL field — it authors the hover card and the loro line" },
  "home/field-prep.js": { role: "ui", why: "the field's geometry preparation" },
  "home/field-ref.js": { role: "ui", why: "the field's reference tables" },

  "mock.js": {
    role: "preview-data",
    why:
      "the dev bridge harness, inert whenever `window.__TAURI__` is present. Its strings are " +
      "SEEDED CONVERSATION DATA for the browser preview, not states the product can enter.",
  },
  "home/field-data.js": {
    role: "preview-data",
    why:
      "4.9 MB of wholly synthetic loro, declared as such in its own `meta.synthetic` field. " +
      "Design input for the home screen's composition, not product copy.",
  },

  "style.css": { role: "style", why: "the shell's stylesheet" },
  "home.css": { role: "style", why: "the home screen's stylesheet" },
  "splash.css": { role: "style", why: "the opening curtain's stylesheet" },
  "fonts/fonts.css": { role: "style", why: "the vendored font faces" },
};

// ---------------------------------------------------------------------------------------
// Step 1 — the entry document's own references
// ---------------------------------------------------------------------------------------

/// `<script src>` and `<link rel=stylesheet href>` in `html`, in document order, with HTML
/// comments removed first so a commented-out tag is not counted as shipped.
function entryReferences(html) {
  const src = String(html).replace(/<!--[\s\S]*?-->/g, "");
  const out = [];
  const script = /<script\b[^>]*\bsrc\s*=\s*(["'])([^"']+)\1/gi;
  const link = /<link\b[^>]*>/gi;
  let m;
  while ((m = script.exec(src))) out.push({ ref: m[2].trim(), kind: "script" });
  while ((m = link.exec(src))) {
    const tag = m[0];
    if (!/\brel\s*=\s*["']?stylesheet\b/i.test(tag)) continue;
    const href = tag.match(/\bhref\s*=\s*(["'])([^"']+)\1/i);
    if (href) out.push({ ref: href[2].trim(), kind: "stylesheet" });
  }
  return out;
}

/// An absolute URL or a protocol-relative one. This manifest is about files on disk, and a
/// CDN reference is not one. There are none today; `manifest()` collects any it finds into
/// `remote` so that a gate can assert on the number rather than assume it.
function isRemote(ref) {
  return /^[a-z][a-z0-9+.-]*:/i.test(ref) || ref.indexOf("//") === 0;
}

/// `tests/` is this harness (it does not ship), `node_modules/` is the harness's
/// dependencies. Everything else under `app/ui/` is bundled. Used by BOTH the disk walk and
/// the closure, so the two agree about what "shipped" means by construction.
const NOT_SHIPPED_DIRS = new Set(["tests", "node_modules"]);

// ---------------------------------------------------------------------------------------
// Step 2 — the closure over runtime-loaded files
// ---------------------------------------------------------------------------------------

/// Every `"…/x.js"`-shaped literal in `src` that names a file which EXISTS under `app/ui/`.
///
/// Deliberately existence-gated rather than pattern-gated. `main.js` mentions
/// `app/src-tauri/src/main.rs` and `STREAMING.md` in prose; `home.js` mentions
/// `design/mockups/data/generate-loro.mjs`. None of those resolve to a file under this
/// directory, so none of them enter the manifest, and the rule needs no exception list to
/// achieve that. What DOES resolve is `home/field-data.js` and its three siblings — which is
/// the whole reason this step exists.
///
/// This reads the raw source, comments included, on purpose: a comment naming a file that
/// exists is a file this directory ought to know about, and the cost of a false positive is
/// one extra correct classification while the cost of a false negative is a blind gate.
///
/// `tests/` IS EXCLUDED HERE AS WELL AS IN THE DISK WALK, and it has to be: five shipped
/// files name a suite in this directory in a comment ("`tests/splash.js` check 1 strips the
/// assignment below…"), and reading comments means those resolve. A harness suite is not a
/// shipped file, and classifying one would put this directory's own prose into the product's
/// state inventory.
function referencedFiles(src) {
  const out = [];
  const re = /["'`]([A-Za-z0-9_./-]+\.(?:js|css|html))["'`]/g;
  let m;
  while ((m = re.exec(src))) {
    const ref = m[1];
    if (isRemote(ref) || ref.charAt(0) === "/" || ref.indexOf("..") >= 0) continue;
    if (NOT_SHIPPED_DIRS.has(ref.replace(/^\.\//, "").split("/")[0])) continue;
    const full = path.join(UI_DIR, ref);
    if (full.indexOf(UI_DIR + path.sep) !== 0) continue;
    let st;
    try { st = fs.statSync(full); } catch (_e) { continue; }
    if (st.isFile()) out.push(ref.replace(/^\.\//, ""));
  }
  return out;
}

// ---------------------------------------------------------------------------------------
// Step 3 — what is actually on disk
// ---------------------------------------------------------------------------------------

function onDisk(dir, prefix, out) {
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1));
  for (const e of entries) {
    const rel = prefix ? prefix + "/" + e.name : e.name;
    if (e.isDirectory()) {
      if (NOT_SHIPPED_DIRS.has(e.name) || e.name.charAt(0) === ".") continue;
      onDisk(path.join(dir, e.name), rel, out);
      continue;
    }
    if (/\.(js|css|html)$/.test(e.name)) out.push(rel);
  }
  return out;
}

// ---------------------------------------------------------------------------------------
// The manifest
// ---------------------------------------------------------------------------------------

/// STEP 3, AS A PURE FUNCTION OF ITS THREE INPUTS, so a suite can prove it refuses.
///
/// `manifest()` calls exactly this with the real derivation and the real tree; a test calls
/// it with a short list, or a missing role, or a stale one, and watches it throw. That is
/// the difference between a check that has been OBSERVED passing and one that has been shown
/// able to fail — and it matters more here than almost anywhere, because this function is
/// the thing standing between the gates and a second silent blind spot. A test that
/// re-implemented these three rules would be proving its own copy.
///
/// Throws on the first disagreement. Returns the count reconciled.
function reconcile(order, disk, roles) {
  const seen = new Set(order);

  const unreferenced = disk.filter((f) => !seen.has(f));
  if (unreferenced.length) {
    throw new Error(
      unreferenced.length + " file(s) exist under app/ui/ and nothing loads them:\n  " +
        unreferenced.join("\n  ") +
        "\nEither wire them into index.html (or into a file that is already loaded), or delete " +
        "them. This manifest will not classify a file it cannot prove ships, and every gate " +
        "that reads it would otherwise be silently short by exactly these."
    );
  }

  const unclassified = order.filter((f) => !roles[f]);
  if (unclassified.length) {
    throw new Error(
      unclassified.length + " shipped file(s) have no role in lib/ui-sources.js's ROLES table:\n  " +
        unclassified.join("\n  ") +
        "\nAdd each one with the role it plays and WHY. `ui` puts its strings in the state " +
        "inventory and under the affordance rule; `preview-data` keeps them out and says on " +
        "what grounds. There is no third option and no default, because a default is how six " +
        "files became invisible to three gates."
    );
  }

  const stale = Object.keys(roles).filter((f) => !seen.has(f));
  if (stale.length) {
    throw new Error(
      stale.length + " role(s) in lib/ui-sources.js name a file the derivation does not reach:\n  " +
        stale.join("\n  ") +
        "\nThe file was renamed, deleted, or is no longer loaded. Remove the row — a " +
        "classification of something that does not ship is the list drifting away from the " +
        "tree again, in the other direction."
    );
  }

  return order.length;
}

let CACHE = null;

/// The derived manifest, or a thrown Error naming exactly what disagrees.
///
/// `{ entry, order, roles, byRole, remote, disk }` where `order` is discovery order (the
/// entry document, then its tags in document order, then each generation of the closure).
///
/// Memoized: five consumers call this and the closure reads every shipped file, one of which
/// is 4.9 MB. The cache is per-process and the process is one test run, so it cannot go
/// stale within a run and cannot survive one.
function manifest() {
  if (CACHE) return CACHE;

  const entryPath = path.join(UI_DIR, ENTRY);
  if (!fs.existsSync(entryPath)) {
    throw new Error(
      "lib/ui-sources.js cannot derive anything: " + ENTRY + " is not at " + UI_DIR + ". This " +
        "module refuses to return a manifest it did not derive — an empty inventory reporting " +
        "green is the failure it exists to stop."
    );
  }

  const remote = [];
  const order = [ENTRY];
  const seen = new Set(order);

  const push = (ref) => {
    if (isRemote(ref)) { if (remote.indexOf(ref) < 0) remote.push(ref); return; }
    const rel = ref.replace(/^\.\//, "").split("?")[0].split("#")[0];
    if (seen.has(rel)) return;
    if (!fs.existsSync(path.join(UI_DIR, rel))) {
      throw new Error(
        "a shipped file references " + rel + ", which does not exist under " + UI_DIR + ". A " +
          "shell that loads a file that is not there is a broken build, and a manifest that " +
          "quietly dropped it would hide that."
      );
    }
    seen.add(rel);
    order.push(rel);
  };

  for (const r of entryReferences(fs.readFileSync(entryPath, "utf8"))) push(r.ref);

  // The closure. Bounded by the number of files on disk, so it terminates; the bound below
  // is a guard against a bug here, not against the tree.
  const SOURCES = {};
  for (let pass = 0; pass < 50; pass++) {
    const before = order.length;
    for (const rel of order.slice()) {
      if (!/\.js$/.test(rel)) continue;
      if (!SOURCES[rel]) SOURCES[rel] = fs.readFileSync(path.join(UI_DIR, rel), "utf8");
      for (const ref of referencedFiles(SOURCES[rel])) push(ref);
    }
    if (order.length === before) break;
  }

  // Step 3, both directions.
  const disk = onDisk(UI_DIR, "", []);
  reconcile(order, disk, ROLES);

  const roles = {};
  const byRole = {};
  for (const f of order) {
    roles[f] = ROLES[f];
    (byRole[ROLES[f].role] = byRole[ROLES[f].role] || []).push(f);
  }
  CACHE = { entry: ENTRY, order, roles, byRole, remote, disk };
  return CACHE;
}

/// Shipped product files whose user-visible strings are STATES — `index.html` plus every
/// `role: "ui"` script, in load order. This is what replaced `UI_SOURCES`.
function stateSources() {
  return manifest().byRole.ui.slice();
}

/// Files whose strings are seeded preview data. Reported, never folded into the inventory.
function previewDataSources() {
  return (manifest().byRole["preview-data"] || []).slice();
}

/// The linked stylesheets, in document order.
function styleSources() {
  return (manifest().byRole.style || []).slice();
}

/// Absolute path, for callers that hand it straight to `fs`.
function abs(rel) {
  return path.join(UI_DIR, rel);
}

module.exports = {
  UI_DIR,
  ENTRY,
  ROLES,
  manifest,
  reconcile,
  stateSources,
  previewDataSources,
  styleSources,
  abs,
  entryReferences,
  referencedFiles,
  onDisk,
  isRemote,
};

// `node lib/ui-sources.js` prints the derivation — the manifest, runnable.
if (require.main === module) {
  const m = manifest();
  let w = 0;
  for (const f of m.order) w = Math.max(w, f.length);
  for (const f of m.order) {
    console.log("  " + f + " ".repeat(w - f.length) + "  " + (m.roles[f].role + "             ").slice(0, 14) + m.roles[f].why);
  }
  console.error(
    "\n" + m.order.length + " shipped file(s) derived from " + m.entry + " and the closure over it: " +
      (m.byRole.ui || []).length + " ui, " + (m.byRole["preview-data"] || []).length + " preview-data, " +
      (m.byRole.style || []).length + " style."
  );
  console.error(
    m.disk.length + " .js/.css/.html file(s) on disk under app/ui (tests/ and node_modules/ excluded); " +
      "every one of them is above."
  );
  console.error(m.remote.length + " remote reference(s)" + (m.remote.length ? ": " + m.remote.join(", ") : "."));
}
