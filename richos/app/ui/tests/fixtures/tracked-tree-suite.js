// A child "suite" for `tracked-tree.js`: it loads the real harness, does ONE thing to a
// throwaway git repository inside a check, and reports exactly as a real suite does. The
// repository is named by RICHOS_UI_TRACKED_TREE_ROOT, so nothing here can reach a real
// tracked file. Not discovered by `run.js` (it only runs top-level files).

"use strict";

const fs = require("fs");
const path = require("path");
const { createRun } = require(path.join(__dirname, "..", "lib", "harness"));

const root = process.env.RICHOS_UI_TRACKED_TREE_ROOT;
const mode = process.argv[2];

async function main() {
  if (!root) throw new Error("RICHOS_UI_TRACKED_TREE_ROOT is not set; refusing to run against a real checkout");
  const run = createRun("tracked-tree fixture (" + mode + ")");
  await run.check("the fixture's own action: " + mode, async () => {
    switch (mode) {
      case "clean":
      case "predirty-untouched":
        return "wrote nothing";
      case "modify":
        fs.writeFileSync(path.join(root, "tracked.txt"), "rewritten by a test\n");
        return "rewrote tracked.txt";
      case "predirty-changed":
        fs.writeFileSync(path.join(root, "dirty.txt"), "changed again by a test\n");
        return "changed dirty.txt again";
      case "modify-outside-scope":
        // Another process saving an unrelated file: from the guard's side it is the same
        // write whoever makes it, so the child makes it.
        fs.writeFileSync(path.join(root, "elsewhere", "notes.txt"), "an unrelated save\n");
        return "rewrote elsewhere/notes.txt, outside the watched scope";
      case "modify-inside-scope":
        fs.writeFileSync(path.join(root, "ui", "view.txt"), "rewritten by a test\n");
        return "rewrote ui/view.txt, inside the watched scope";
      case "untracked":
        fs.writeFileSync(path.join(root, "new-reference.png"), "not a png");
        return "created new-reference.png";
      case "ignored":
        fs.mkdirSync(path.join(root, "scratch"), { recursive: true });
        fs.writeFileSync(path.join(root, "scratch", "x.png"), "not a png");
        return "wrote scratch/x.png, which .gitignore covers";
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
