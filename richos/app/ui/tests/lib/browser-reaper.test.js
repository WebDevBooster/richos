// A UI suite that ends abnormally (SIGKILL, from a timeout or a build gate) must leave no test
// browser behind: an orphaned Playwright.app is what later crashed and put macOS's "Playwright
// quit unexpectedly" dialog on the CEO's screen (2026-10-09). No real browser here: a fake
// Playwright whose `webkit.launch` starts a long-lived child stands in for the browser, and the
// suite process is killed with SIGKILL, which no in-process cleanup can survive.
"use strict";

const path = require("path");
const { spawn } = require("child_process");

const REAPER = process.env.BROWSER_REAPER_LIB || path.join(__dirname, "browser-reaper.js");

const suite = `
  const { spawn } = require("child_process");
  const reaper = require(${JSON.stringify(REAPER)});
  const fake = { webkit: { launch: async () => {
    const b = spawn("sleep", ["300"], { stdio: "ignore" });
    console.log("BROWSER " + b.pid);
    return { close: async () => {} };
  } } };
  const pw = reaper.install(fake);
  pw.webkit.launch().then(() => console.log("READY"));
  setInterval(() => {}, 1000);
`;

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const child = spawn(process.execPath, ["-e", suite], { stdio: ["ignore", "pipe", "inherit"] });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  for (let i = 0; i < 100 && !out.includes("READY"); i++) await sleep(50);
  const m = /BROWSER (\d+)/.exec(out);
  if (!m || !out.includes("READY")) {
    console.log("FAIL  the stand-in suite never launched its browser: " + JSON.stringify(out));
    child.kill("SIGKILL");
    process.exit(1);
  }
  const browser = Number(m[1]);
  await sleep(400); // the watcher takes its first look at the suite's children
  child.kill("SIGKILL");
  let gone = false;
  for (let i = 0; i < 60 && !gone; i++) {
    await sleep(100);
    gone = !alive(browser);
  }
  if (!gone) {
    process.kill(browser, "SIGKILL"); // our own stand-in, captured at spawn
    console.log("FAIL  the browser (pid " + browser + ") outlived its SIGKILLed suite");
    process.exit(1);
  }
  console.log("PASS  a SIGKILLed suite leaves no browser process behind");
})();
