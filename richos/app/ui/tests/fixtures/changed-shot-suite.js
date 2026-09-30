// A child "suite" for `gate-honesty.js`: it loads the real harness, publishes ONE picture through
// the real `publishShot` against the real committed reference `shots-5c/5c-02-…png`, and reports
// exactly as a real suite does. `changed` publishes a picture that differs from the reference;
// `same` publishes the reference's own bytes. Neither can rewrite the reference (a test run
// never does; `RICHOS_SHOTS_REGENERATE` is removed from the child's environment by its parent).
// Not discovered by `run.js` (it only runs top-level files).

"use strict";

const fs = require("fs");
const path = require("path");
const { createRun, publishShot } = require(path.join(__dirname, "..", "lib", "harness"));
const { tinyPng } = require("./tiny-png");

const mode = process.argv[2];
const reference = path.join(__dirname, "..", "shots-5c", "5c-02-after-a-plain-decline.png");

async function main() {
  const run = createRun("changed-shot fixture (" + mode + ")");
  await run.check("the fixture's own action: " + mode, async () => {
    switch (mode) {
      case "changed":
        publishShot(tinyPng(40), reference);
        return "published a picture that differs from the committed reference";
      case "same":
        publishShot(fs.readFileSync(reference), reference);
        return "published the reference's own bytes";
      default:
        throw new Error("unknown fixture mode " + JSON.stringify(mode));
    }
  });
  process.exit(run.report() ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
