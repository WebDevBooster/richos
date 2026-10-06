// RE-KEY THE STATE REGISTRY AFTER A COPY CHANGE, WITHOUT RE-TYPING 27 KB BY HAND.
//
// `state-registry.js` keys each row on the exact normalized text the inventory derives from
// source (`state-strings.js`), and `affordances.js` part 1 fails while the two sets differ.
// A copy change therefore leaves one orphan row and one unregistered string per edited
// sentence. The phone sheet's whole template literal is ONE key, so a one-word edit in it
// re-keys a 27 KB string that nobody should be re-typing.
//
//   node lib/registry-rekey.js --orphans
//       Prints, as JSON, the registry rows whose key is no longer in the inventory and the
//       inventory strings no row classifies, each with its sites. Nothing is written.
//
//   node lib/registry-rekey.js PAIRS.json
//       PAIRS.json is [[oldKey, newKey], ...]. Each old key is replaced where it is written
//       verbatim as a JSON string literal (most rows are). A key that is hand-wrapped across
//       several concatenated lines is NOT guessed at: it is named, and the run exits 1, so it
//       is edited by hand. An old key found more or less than once is also refused.
//
// It never adds or removes a row and never touches a classification: what a state MEANS is a
// judgment the rows carry, and a copy change does not make it for you.

"use strict";

const fs = require("fs");
const path = require("path");

const FILE = path.join(__dirname, "state-registry.js");

function orphans() {
  const { inventory } = require("./state-strings");
  const registry = require("./state-registry");
  const inv = inventory();
  const have = new Set(inv.map((r) => r.normal));
  const keyed = new Set(registry.map((r) => r.s));
  return {
    rowsWithNoSource: registry.filter((r) => !have.has(r.s)).map((r) => r.s),
    sourceWithNoRow: inv.filter((r) => !keyed.has(r.normal)).map((r) => ({ text: r.normal, sites: r.sites })),
  };
}

function rekey(pairs, file = FILE) {
  let text = fs.readFileSync(file, "utf8");
  const byHand = [];
  for (const [oldKey, newKey] of pairs) {
    const needle = JSON.stringify(oldKey);
    const count = text.split(needle).length - 1;
    if (count !== 1) {
      byHand.push({ oldKey: oldKey.slice(0, 120), found: count });
      continue;
    }
    text = text.replace(needle, () => JSON.stringify(newKey));
  }
  fs.writeFileSync(file, text);
  return byHand;
}

if (require.main === module) {
  const arg = process.argv[2];
  if (arg === "--orphans") {
    process.stdout.write(JSON.stringify(orphans(), null, 2) + "\n");
  } else if (arg) {
    const byHand = rekey(JSON.parse(fs.readFileSync(arg, "utf8")));
    if (byHand.length) {
      process.stderr.write("edit these by hand (not written verbatim exactly once):\n" + JSON.stringify(byHand, null, 2) + "\n");
      process.exit(1);
    }
  } else {
    process.stderr.write("usage: node lib/registry-rekey.js --orphans | PAIRS.json\n");
    process.exit(2);
  }
}

module.exports = { orphans, rekey };
