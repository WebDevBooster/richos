"use strict";
const path = require("path");
const {loadPlaywright, createRun, assert, assertEqual, UI_DIR, leaveHome, openThread} = require("./lib/harness");
async function main() {
  const run = createRun("saved work in the shipping renderer");
  const browser = await loadPlaywright().webkit.launch();
  await run.check("saved outcomes remain distinct and scoped when the conversation changes", async () => {
    const page = await browser.newPage({viewport: {width:1280, height:900}});
    const errors = []; page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(() => window.__RICHOS_MOCK_PRESET__ = {workSummaries: {
      hiring: {items:[{title:"<img src=x onerror=alert(1)>", role:"worker", repository:"/fictional/one", state:"run-ended", detail:"Worker run ended. Review is still required."}, {title:"Reviewed change", role:"worker", repository:"/fictional/two", state:"integrated", detail:"Reviewed commit integrated locally. Whole assignment remains open."}], omitted:2}
    }});
    await page.goto("file://" + path.join(UI_DIR,"index.html")); await leaveHome(page);
    await openThread(page,"hiring");
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("2 saved work records"));
    await page.click(".drill-chip");
    assert((await page.textContent("#slideover-body")).includes("Review is still required"), "run end became success");
    assert((await page.textContent("#slideover-body")).includes("Whole assignment remains open"), "integration became whole-task completion");
    assertEqual(await page.locator("#slideover-body img").count(),0,"receipt rendered as markup");
    await page.click("#slideover-close"); await openThread(page,"acme");
    assert(!(await page.textContent("#drill-chip-zone")).includes("2 saved work records"),"old-company receipt leaked");
    await page.evaluate(() => window.__RICHOS_MOCK_PRESET__.workSummaryError = "Synthetic damaged receipt");
    await page.waitForFunction(() => document.getElementById("drill-chip-zone").textContent.includes("Saved work unavailable"));
    await page.click(".drill-chip");
    assert((await page.textContent("#slideover-body")).includes("Synthetic damaged receipt"),"damaged receipt looked empty");
    assertEqual(errors.length,0,"renderer errors"); await page.close();
    return "scoped receipts, explicit outcomes, escaped content and visible read failure";
  });
  await browser.close(); process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
