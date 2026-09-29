// A HOST TOO LOADED TO START A HELPER PROCESS IN TIME — loaded with `node --require` into the
// failing fixture suite by `navigation-evidence.js` check 7.
//
// Nightly run `20260929T044015Z-588457c3` failed its UI gate because the evidence capture's
// CPU sample was `spawnSync /usr/bin/top` and, with three gates side by side (load average
// 13.0 on 10 cores), that call ran past its ceiling: `spawnSync /usr/bin/top ETIMEDOUT`. This
// file makes every `child_process.spawnSync` in the process answer exactly the way Node
// answers a spawnSync that ran past its `timeout` (an `ETIMEDOUT` error, `status: null`,
// `signal: "SIGTERM"`, empty output), deterministically and without loading anyone's Mac.
//
// It replaces the module's exported `spawnSync` before any suite code runs, so a caller that
// destructures `const { spawnSync } = require("child_process")` gets this one. Node's own
// `execFileSync` / `execSync` call the module's internal function, not the export, and are
// untouched. Each refusal is announced on stderr so the check can prove the simulation was on.

"use strict";

const cp = require("child_process");

cp.spawnSync = function refusedSpawnSync(file) {
  const error = new Error("spawnSync " + file + " ETIMEDOUT");
  error.code = "ETIMEDOUT";
  error.errno = -60;
  error.syscall = "spawnSync " + file;
  error.path = file;
  process.stderr.write("loaded-host: refused spawnSync " + file + "\n");
  return { error, status: null, signal: "SIGTERM", pid: 0, output: [null, "", ""], stdout: "", stderr: "" };
};
