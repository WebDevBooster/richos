// A SUITE THAT MUST FAIL — the fixture `navigation-evidence.js` runs as a child process to
// prove that a navigation which never completes still turns its suite red, with Playwright's
// own message, while leaving an evidence bundle behind. It lives under `fixtures/` so
// `run.js` never discovers it as a suite of its own.
//
//   node fixtures/navigation-hang-suite.js <mode>
//
//   stall-subresource  the document arrives and parses; one image never answers, so `load`
//                      never fires. The navigation is given an explicit 1500 ms timeout.
//   never-document     the document request itself never answers. No timeout is passed; the
//                      page's own default is set to 1200 ms by THIS file, standing in for a
//                      suite's default, to prove the wrapper enforces whatever the page says.
//   wedged             the document's own script never yields, so the page cannot answer an
//                      evaluate or paint a screenshot — collection has to stay bounded.
//
// Everything is served from 127.0.0.1 by this process and torn down before it exits.

"use strict";

const http = require("http");
const H = require("../lib/harness");

const MODE = process.argv[2] || "stall-subresource";

const PAGES = {
  "/stall":
    "<!doctype html><html><head><title>stall</title></head>" +
    "<body style='background:#fff;color:#111;font:24px sans-serif'>" +
    "<p>Waiting on an image that never arrives.</p><img src='/never' alt=''></body></html>",
  "/wedged":
    "<!doctype html><html><head><title>wedged</title></head><body><p>busy</p>" +
    "<script>for (;;) {}</script></body></html>",
};

async function main() {
  const server = http.createServer((req, res) => {
    const body = PAGES[req.url];
    if (body) {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(body);
    }
    // Anything else — `/never`, `/never-document` — is deliberately never answered.
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await H.loadPlaywright().webkit.launch();
  const run = H.createRun("navigation evidence fixture: " + MODE);

  await run.check("hang: " + MODE, async () => {
    const page = await browser.newPage({ viewport: { width: 640, height: 360 }, colorScheme: "dark" });
    if (MODE === "stall-subresource") {
      await page.goto(origin + "/stall", { timeout: 1500 });
    } else if (MODE === "never-document") {
      page.setDefaultNavigationTimeout(1200);
      await page.goto(origin + "/never-document");
    } else if (MODE === "wedged") {
      await page.goto(origin + "/wedged", { timeout: 1500 });
    } else {
      throw new Error("unknown fixture mode " + MODE);
    }
  });

  const failed = run.report();
  await browser.close();
  server.closeAllConnections();
  server.close();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
