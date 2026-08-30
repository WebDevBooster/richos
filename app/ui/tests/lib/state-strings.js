// DERIVE THE USER-VISIBLE STATE INVENTORY FROM SOURCE. NEVER TYPE IT.
//
// WHY THIS FILE EXISTS
// ====================
// The rule this module serves: *a state the user could change must be rendered together
// with the control that changes it. A state change requiring a human action is not a
// status, it is a request.*
//
// Enforcing that rule needs an INVENTORY of the states the app can show, and the one thing
// an inventory must never be is hand-written. A typed list of 14 against a registration of
// 15 is the defect that opened this whole sequence; `run.js` beside this file lost a whole
// suite the same way; the engine's `run-all-tests.sh` lost five. So the inventory here is
// scraped out of the shipped source every time the suite runs, and the classification
// registry is checked AGAINST it — source is the authority, the registry is the annotation.
//
// HOW THE SCRAPE WORKS
// ====================
// Two extractors, both purely lexical, both deliberately dumb:
//
//   HTML  every non-empty text node outside <script>/<style>/comments, plus the
//         `placeholder`, `title` and `aria-label` attribute values.
//   JS    every string literal (single, double, template) that survives comment stripping,
//         filtered by `looksLikeProse` below.
//
// Comment stripping is a real character scanner (strings, template literals, line and block
// comments, and regex literals via the standard prev-significant-token heuristic), because
// this source is roughly 40% prose commentary and a naive regex would harvest all of it.
//
// THE BLIND SPOTS, NAMED RATHER THAN GLOSSED — each one is text a reader could see that
// this scrape does not produce a literal for:
//
//   B1. COMPOSED strings. `"Working for " + d` yields the literal `Working for ` and never
//       the rendered `Working for 4m 7s`. The state is SEEN; its rendered form is not.
//   B2. BACKEND-AUTHORED strings. `showUnboundView` prints `navTree.unbound_explanation`
//       and `String(e)` — text minted in Rust and relayed verbatim. Covered by the
//       separate `rustStrings()` scrape below, which greps the Rust sources that feed
//       those fields and is therefore weaker than the JS one.
//   B3. Strings under the prose floor. "Rich", "Copied", "Show more" are real UI text and
//       are deliberately excluded: they are labels ON controls, not states, and including
//       them buries the states in nouns.
//   B4. mock.js. Its strings are SEEDED CONVERSATION DATA for the browser preview, not
//       states the product can enter. Scanned separately and reported, never mixed in.
//   B5. UNBOUNDED MACHINERY LEAK. `send()` prints `String(e)` from `send_message` into the
//       timeline. If the failure came from inside richos-core rather than from the command
//       layer's own authored refusal, that text is a Display impl — "cognition io: broken
//       pipe", "the loro slice did not parse". Any error in the crate can reach that
//       sentence, so the set is not enumerable and this module does not pretend to
//       enumerate it. Reported as a finding, not folded into the inventory.
//
// A blind spot that is named is a bounded gap. A blind spot that is quietly omitted is the
// defect this module exists to stop.

"use strict";

const fs = require("fs");
const path = require("path");

const UI_DIR = path.resolve(__dirname, "..", "..");

// ---------------------------------------------------------------------------------------
// JS: strip comments, keep string literals
// ---------------------------------------------------------------------------------------

/// Scan `src` character by character and return the string literals with their 1-based
/// line numbers. Comments are dropped. Regex literals are recognized so that a slash inside
/// one cannot be mistaken for the start of a comment, and vice versa.
///
/// ADJACENT LITERALS JOINED BY `+` ARE FOLDED INTO ONE. The unbound-thread explanation is
/// one sentence written across three source lines by prettier; scraped naively it becomes
/// three entries, none of which is the sentence the CEO reads. Folding is what makes the
/// registry key equal to the rendered text.
function jsStringLiterals(src) {
  const out = [];
  let i = 0;
  let line = 1;
  // The last significant character before the cursor, used only to decide whether a slash
  // opens a regex (after an operator, keyword, `(` or `,`) or is a division (after a value).
  let prevSig = "";
  // Every significant character seen since the previous string literal closed. Exactly `+`
  // means the two literals are one concatenated string.
  let sigSince = null;

  const n = src.length;
  while (i < n) {
    const c = src[i];

    if (c === "\n") { line++; i++; continue; }
    if (c === " " || c === "\t" || c === "\r") { i++; continue; }

    // line comment
    if (c === "/" && src[i + 1] === "/") {
      while (i < n && src[i] !== "\n") i++;
      continue;
    }
    // block comment
    if (c === "/" && src[i + 1] === "*") {
      i += 2;
      while (i < n && !(src[i] === "*" && src[i + 1] === "/")) { if (src[i] === "\n") line++; i++; }
      i += 2;
      continue;
    }
    // regex literal — only where a value cannot precede it
    if (c === "/" && !/[A-Za-z0-9_$)\]]/.test(prevSig)) {
      i++;
      let inClass = false;
      while (i < n) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === "[") inClass = true;
        else if (src[i] === "]") inClass = false;
        else if (src[i] === "/" && !inClass) { i++; break; }
        else if (src[i] === "\n") { line++; break; }
        i++;
      }
      while (i < n && /[a-z]/.test(src[i])) i++;
      prevSig = "/";
      if (sigSince !== null) sigSince += "/";
      continue;
    }
    // string / template literal
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      const startLine = line;
      let buf = "";
      i++;
      while (i < n) {
        const d = src[i];
        if (d === "\\") {
          // Keep the escaped character's VALUE where it is one the UI can render.
          const e = src[i + 1];
          if (e === "n") buf += "\n";
          else if (e === "t") buf += " ";
          else if (e === "u" && /^[0-9a-fA-F]{4}$/.test(src.slice(i + 2, i + 6))) {
            buf += String.fromCharCode(parseInt(src.slice(i + 2, i + 6), 16));
            i += 6;
            continue;
          } else buf += e;
          i += 2;
          continue;
        }
        if (d === quote) { i++; break; }
        if (d === "\n") line++;
        // `${...}` inside a template literal is an expression, not text. It is dropped so
        // the surrounding words survive; the hole is blind spot B1.
        if (quote === "`" && d === "$" && src[i + 1] === "{") {
          let depth = 1;
          i += 2;
          while (i < n && depth > 0) {
            if (src[i] === "{") depth++;
            else if (src[i] === "}") depth--;
            else if (src[i] === "\n") line++;
            i++;
          }
          continue;
        }
        buf += d;
        i++;
      }
      if (sigSince !== null && sigSince.trim() === "+" && out.length) {
        out[out.length - 1].text += buf;
      } else {
        out.push({ text: buf, line: startLine });
      }
      prevSig = quote;
      sigSince = "";
      continue;
    }

    prevSig = c;
    if (sigSince !== null) sigSince += c;
    i++;
  }
  return out;
}

// ---------------------------------------------------------------------------------------
// HTML: text nodes and the three human-readable attributes
// ---------------------------------------------------------------------------------------

function htmlVisibleStrings(src) {
  const out = [];
  // Drop comments and script/style bodies, keeping newlines so line numbers stay true.
  const blank = (m) => m.replace(/[^\n]/g, " ");
  const cleaned = src
    .replace(/<!--[\s\S]*?-->/g, blank)
    .replace(/<script\b[\s\S]*?<\/script>/gi, blank)
    .replace(/<style\b[\s\S]*?<\/style>/gi, blank);

  const attrRe = /\b(placeholder|title|aria-label)\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = attrRe.exec(cleaned)) !== null) {
    out.push({ text: m[2], line: cleaned.slice(0, m.index).split("\n").length, kind: "attr:" + m[1] });
  }

  const textRe = />([^<]+)</g;
  while ((m = textRe.exec(cleaned)) !== null) {
    const t = m[1].replace(/\s+/g, " ").trim();
    if (!t) continue;
    out.push({ text: t, line: cleaned.slice(0, m.index).split("\n").length, kind: "text" });
  }
  return out;
}

// ---------------------------------------------------------------------------------------
// The prose filter
// ---------------------------------------------------------------------------------------

/// MACHINERY, never read by anyone: selectors, event channels, class names, keys, formats.
const MACHINERY = [
  /:\/\//,                        // rich://turn-status
  /^[.#[]/,                       // CSS selectors
  /^[a-z0-9]+([-_][a-z0-9]+)*$/i, // a single identifier-ish token
  /^[A-Za-z-]+\/[A-Za-z-]+$/,     // mime types, short paths
  /\.(js|css|png|html|json|rs)$/,
];

/// Reads as something a person could read: at least three whitespace-separated tokens, at
/// least two of them carrying two or more letters, and at least 12 characters overall.
///
/// THE FLOOR IS DELIBERATE AND IT COSTS SOMETHING (blind spot B3): "Copied", "Show more",
/// "Working" and "Ended" are user-visible and are excluded. They are control labels and
/// one-word statuses whose whole meaning lives in the row around them; a rule about
/// SENTENCES that also swept in every noun in the app would flag roughly 200 strings, and a
/// check that flags 200 things gets deleted within a day.
function looksLikeProse(s) {
  const t = String(s).trim();
  if (t.length < 12) return false;
  if (!/[A-Za-z]/.test(t)) return false;
  for (const re of MACHINERY) if (re.test(t)) return false;
  const words = t.split(/\s+/).filter(Boolean);
  if (words.length < 3) return false;
  const wordy = words.filter((w) => /[A-Za-z]{2}/.test(w));
  return wordy.length >= 2;
}

// ---------------------------------------------------------------------------------------
// Rust: the strings that cross the bridge into the UI (blind spot B2)
// ---------------------------------------------------------------------------------------

/// `src-tauri/src` is the command layer — the ONLY Rust the renderer calls, and the only
/// place an authored `Err(String)` is written for the CEO to read. `crates/` is walked too,
/// but only `ceo_message()` bodies inside it survive the filter below: richos-core's
/// `Display` impls are machinery ("cognition io: broken pipe", "the loro slice did not
/// parse"), and although one CAN leak through `String(e)` into a local notice, that surface
/// is unbounded — see blind spot B5. An inventory that listed 37 core error strings as
/// "states" would be inventing a set, not deriving one.
const RUST_ROOTS = [
  path.resolve(UI_DIR, "..", "src-tauri", "src"),
  path.resolve(UI_DIR, "..", "crates"),
];

/// Rust files whose authored `Err(String)` sentences the renderer relays. Outside these,
/// only `ceo_message()` counts.
const RUST_COMMAND_LAYER = path.resolve(UI_DIR, "..", "src-tauri", "src");

function walk(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_e) { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    // `examples/` and `tests/` are operator binaries and unit tests. Their prose is printed
    // to a terminal by an engineer, never to the CEO's screen, and including it puts
    // "cannot open the microphone" in an inventory of UI states.
    if (e.isDirectory()) {
      if (e.name !== "target" && e.name !== "examples" && e.name !== "tests") walk(p, out);
    }
    else if (e.name.endsWith(".rs")) out.push(p);
  }
  return out;
}

/// Rust string literals with 1-based start lines. Comments dropped, `\`-at-end-of-line
/// continuation resolved the way rustc resolves it (the newline AND the following
/// indentation are swallowed), raw strings skipped whole, and `'a` lifetimes distinguished
/// from `'a'` char literals.
///
/// A LINE-BASED GREP IS NOT ENOUGH HERE, and the first version of this file proved it: every
/// CEO-facing sentence in main.rs is written across two or three lines with a trailing
/// backslash, so a per-line regex saw only fragments — and it found the strings quoted in
/// the TEST module instead of the const the app actually ships.
function rustStringLiterals(src) {
  const out = [];
  let i = 0;
  let line = 1;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === "\n") { line++; i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < n && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") {
      i += 2;
      let depth = 1;
      while (i < n && depth > 0) {
        if (src[i] === "\n") line++;
        else if (src[i] === "/" && src[i + 1] === "*") { depth++; i++; }
        else if (src[i] === "*" && src[i + 1] === "/") { depth--; i++; }
        i++;
      }
      continue;
    }
    // raw string: r"..." / r#"..."# — skipped whole, never CEO prose in this codebase.
    if (c === "r" && (src[i + 1] === '"' || src[i + 1] === "#")) {
      let j = i + 1;
      let hashes = 0;
      while (src[j] === "#") { hashes++; j++; }
      if (src[j] === '"') {
        const close = '"' + "#".repeat(hashes);
        const end = src.indexOf(close, j + 1);
        const stop = end < 0 ? n : end + close.length;
        for (let k = i; k < stop; k++) if (src[k] === "\n") line++;
        i = stop;
        continue;
      }
    }
    // char literal vs lifetime
    if (c === "'") {
      if (src[i + 1] === "\\") { i += 4; continue; }
      if (src[i + 2] === "'") { i += 3; continue; }
      i++;
      continue;
    }
    if (c === '"') {
      const startLine = line;
      let buf = "";
      i++;
      while (i < n) {
        const d = src[i];
        if (d === "\\") {
          const e = src[i + 1];
          if (e === "\n") {
            // rustc: the newline and all following whitespace vanish.
            line++;
            i += 2;
            while (i < n && (src[i] === " " || src[i] === "\t")) i++;
            continue;
          }
          if (e === "n") buf += " ";
          else if (e === "t") buf += " ";
          else buf += e;
          i += 2;
          continue;
        }
        if (d === '"') { i++; break; }
        if (d === "\n") line++;
        buf += d;
        i++;
      }
      out.push({ text: buf, line: startLine });
      continue;
    }
    i++;
  }
  return out;
}

/// WHICH RUST STRINGS CAN REACH THE CEO'S SCREEN.
///
/// Two paths, and both are structural rather than a list of blessed identifiers:
///
///   1. `ceo_message()` — richos-voice's own name for "the calm line the CEO sees"
///      (controller.rs:73). Every literal inside a function of that name is CEO-facing by
///      the codebase's own declaration.
///   2. The `Err(String)` of a `#[tauri::command]`, and the `const … : &str` those errors
///      are built from. `main.js` relays those verbatim: `String(e)` into the local notice
///      (`send()`), into `#composer-blocked` (`create_thread_in`) and into
///      `#unbound-view-detail` (`loadTimeline`). So a sentence written beside `Err(` or
///      `ok_or` in a command is a sentence the CEO can read.
///
/// The first version of this scrape keyed on a typed list of field names, and it missed
/// BOTH of the two worst states in the app — "I'm not connected to my thinking right now"
/// and the RICHOS_ENTITY instruction — while confidently reporting the fragments that
/// appear in main.rs's test assertions. That is the typed-list defect one more time, inside
/// the very module written to stop it.
const RUST_CEO_CONTEXT = /\bErr\(|\bok_or|const\s+[A-Z0-9_]+\s*:\s*&'?\w*\s*str\s*=|\.into\(\)/;

function rustStrings() {
  const files = [];
  for (const r of RUST_ROOTS) walk(r, files);
  const out = [];
  const repoRoot = path.resolve(UI_DIR, "..", "..");
  for (const f of files) {
    const src = fs.readFileSync(f, "utf8");
    const lines = src.split("\n");

    // Inline `#[cfg(test)] mod tests { … }` — test prose is not product prose, and a
    // directory-based exclusion cannot see a module that lives inside a shipped file.
    let testStart = Infinity;
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*mod tests\s*\{/.test(lines[i]) || /^\s*#\[cfg\(test\)\]/.test(lines[i])) {
        testStart = i + 1;
        break;
      }
    }

    // The nearest preceding `fn NAME`, per line.
    const fnAt = [];
    let currentFn = "";
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/\bfn\s+([A-Za-z0-9_]+)/);
      if (m) currentFn = m[1];
      fnAt.push(currentFn);
    }

    for (const lit of rustStringLiterals(src)) {
      const idx = lit.line - 1;
      if (idx >= testStart) continue;
      if (!looksLikeProse(lit.text)) continue;
      const own = lines[idx] || "";
      if (/assert/.test(own)) continue;
      // The literal's own line plus the two above it — enough for `return Err(` or a
      // `const … : &str =` that sits on the line before the sentence.
      const ctx = [lines[idx - 2] || "", lines[idx - 1] || "", own].join("\n");
      const inCommandLayer = f.startsWith(RUST_COMMAND_LAYER + path.sep);
      const ceoFacing = fnAt[idx] === "ceo_message" || (inCommandLayer && RUST_CEO_CONTEXT.test(ctx));
      if (!ceoFacing) continue;
      out.push({ text: lit.text, file: path.relative(repoRoot, f), line: lit.line });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------
// The inventory
// ---------------------------------------------------------------------------------------

/// Collapse whitespace so a sentence wrapped across three source lines matches the same
/// sentence written on one. The registry keys on this normal form.
function normalize(s) {
  return String(s).replace(/\s+/g, " ").trim();
}

const UI_SOURCES = ["index.html", "main.js", "timeline.js"];

/// Every user-visible prose string the shipped UI can render, derived from disk.
/// `{ text, normal, sites: ["main.js:1113", ...] }`, sorted by normal form.
function inventory() {
  const byNormal = new Map();
  const add = (text, site) => {
    const normal = normalize(text);
    if (!looksLikeProse(normal)) return;
    let rec = byNormal.get(normal);
    if (!rec) { rec = { text: normal, normal, sites: [] }; byNormal.set(normal, rec); }
    if (rec.sites.indexOf(site) < 0) rec.sites.push(site);
  };

  for (const name of UI_SOURCES) {
    const src = fs.readFileSync(path.join(UI_DIR, name), "utf8");
    if (name.endsWith(".html")) {
      for (const s of htmlVisibleStrings(src)) add(s.text, name + ":" + s.line);
    } else {
      for (const s of jsStringLiterals(src)) add(s.text, name + ":" + s.line);
    }
  }
  for (const s of rustStrings()) add(s.text, s.file + ":" + s.line);

  return Array.from(byNormal.values()).sort((a, b) => (a.normal < b.normal ? -1 : 1));
}

/// mock.js, kept OUT of the inventory and reported separately (blind spot B4).
function mockStrings() {
  const src = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
  const seen = new Set();
  for (const s of jsStringLiterals(src)) {
    const nrm = normalize(s.text);
    if (looksLikeProse(nrm)) seen.add(nrm);
  }
  return Array.from(seen).sort();
}

module.exports = {
  inventory,
  mockStrings,
  rustStrings,
  jsStringLiterals,
  htmlVisibleStrings,
  looksLikeProse,
  normalize,
  UI_DIR,
  UI_SOURCES,
};

// `node lib/state-strings.js` prints the derived inventory — the derivation, runnable.
if (require.main === module) {
  const inv = inventory();
  for (const rec of inv) console.log(rec.sites.join(" ") + "\n  " + JSON.stringify(rec.normal));
  console.error(
    "\n" + inv.length + " user-visible prose string(s) derived from " + UI_SOURCES.join(", ") +
      " + the Rust bridge scrape"
  );
  console.error(mockStrings().length + " further prose string(s) in mock.js (seeded preview data — NOT states)");
}
