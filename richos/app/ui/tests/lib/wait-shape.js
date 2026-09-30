// A WAIT DEADLINE MUST BE IN THE THIRD ARGUMENT.
//
// Playwright's `page.waitForFunction(fn, arg, options)` reads its timeout from the THIRD
// parameter. Giving the options object as the second argument hands it to the page function
// as its `arg` and the wait quietly uses the library's 30-second default. Ninety-four calls in this
// directory did that (hunt part 2, finding 28, 2026-09-29): a written 5-second guard cost 30
// seconds on a failure, and a written 90-second bloom budget was refused at 30.
//
// `findMisplacedTimeouts(dir)` returns every waitForFunction call with exactly two arguments
// whose second is an object holding `timeout`, as `file:line`. `wait-shape.test.js` fails when the list is not empty.
// This is a scanner, not a parser: it balances brackets, skips strings, template literals and
// comments, and does not try to understand regular expression literals.

"use strict";

const fs = require("fs");
const path = require("path");

function jsFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".shots") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) jsFiles(full, out);
    else if (full.endsWith(".js")) out.push(full);
  }
  return out;
}

/// The top-level arguments of the call whose opening parenthesis ends just before `start`.
function callArguments(src, start) {
  let depth = 0;
  let current = "";
  const out = [];
  let quote = null;
  for (let k = start; k < src.length; k++) {
    const c = src[k];
    if (quote) {
      current += c;
      if (c === "\\") current += src[++k];
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      quote = c;
      current += c;
      continue;
    }
    if (c === "/" && src[k + 1] === "/") {
      while (k < src.length && src[k] !== "\n") k++;
      continue;
    }
    if (c === "/" && src[k + 1] === "*") {
      k = src.indexOf("*/", k) + 1;
      continue;
    }
    if ("([{".includes(c)) depth++;
    if (")]}".includes(c)) {
      if (depth === 0) {
        out.push(current);
        return out;
      }
      depth--;
    }
    if (c === "," && depth === 0) {
      out.push(current);
      current = "";
      continue;
    }
    current += c;
  }
  return out;
}

function findMisplacedTimeouts(dir) {
  const hits = [];
  for (const file of jsFiles(dir)) {
    const src = fs.readFileSync(file, "utf8");
    const call = /\.waitForFunction\(/g;
    let m;
    while ((m = call.exec(src))) {
      const args = callArguments(src, m.index + m[0].length);
      if (args.length === 2 && /^\s*\{[^}]*\btimeout\b/.test(args[1])) {
        hits.push(path.relative(dir, file) + ":" + (src.slice(0, m.index).split("\n").length));
      }
    }
  }
  return hits;
}

module.exports = { findMisplacedTimeouts };
