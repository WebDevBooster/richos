// Fails if `registry-rekey.js` swaps a key it should refuse, or refuses one it should swap.
// No browser, and it never touches the real registry: it re-keys a temporary copy.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { rekey } = require("./registry-rekey");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "registry-rekey-"));
const file = path.join(dir, "state-registry.js");
try {
  fs.writeFileSync(
    file,
    [
      "module.exports = [",
      '  { "s": "Set up this Mac, then pair your phone with its code.", "c": "ACTIONABLE" },',
      '  { s: "A sentence written " +', // hand-wrapped: refused, never guessed at
      '      "across two lines.", c: "INFORMATIONAL" },',
      '  { "s": "Twice.", "c": "FRAGMENT" }, { "s": "Twice.", "c": "FRAGMENT" },',
      "];",
      "",
    ].join("\n")
  );
  const byHand = rekey(
    [
      ["Set up this Mac, then pair your phone with its code.", "First, set up this RichOS app on your Mac. Then pair your phone with it."],
      ["A sentence written across two lines.", "Anything."],
      ["Twice.", "Once."],
      ["Not in the file.", "Anything."],
    ],
    file
  );
  const after = fs.readFileSync(file, "utf8");
  const problems = [];
  if (!after.includes('"First, set up this RichOS app on your Mac. Then pair your phone with it."')) problems.push("the verbatim key was not swapped");
  if (after.includes("Set up this Mac, then pair")) problems.push("the old verbatim key is still there");
  if (!after.includes('"across two lines."')) problems.push("a hand-wrapped key was edited");
  if ((after.match(/"Twice\."/g) || []).length !== 2) problems.push("a key written twice was swapped");
  const refused = byHand.map((b) => b.oldKey + " x" + b.found).sort().join(" | ");
  if (refused !== "A sentence written across two lines. x0 | Not in the file. x0 | Twice. x2") problems.push("refused: " + refused);
  if (problems.length) {
    console.log("FAIL  registry-rekey: " + problems.join("; "));
    process.exitCode = 1;
  } else {
    console.log("PASS  registry-rekey swaps a verbatim key and refuses a wrapped, missing or doubled one");
  }
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
