"use strict";
const path=require("path");
const {loadPlaywright,createRun,assert,assertEqual,UI_DIR,leaveHome}=require("./lib/harness");
async function main(){
 const run=createRun("repository connection in the shipping renderer");
 const browser=await loadPlaywright().webkit.launch();
 await run.check("two repositories connect to an explicitly selected company",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[];page.on("pageerror",e=>errors.push(String(e)));
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.click("#set-repositories-open");
  await page.waitForSelector("#repository-company option:nth-child(2)",{state:"attached"});
  assert(await page.isDisabled("#repository-connect"),"company must be explicitly selected");
  const company=await page.locator("#repository-company option").nth(1).getAttribute("value");
  await page.selectOption("#repository-company",company);
  await page.fill("#repository-folder","/fictional/first project");await page.click("#repository-connect");
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent==="Repository connected.");
  await page.fill("#repository-folder","/fictional/second project");await page.check("#repository-initialize");await page.click("#repository-connect");
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent.includes("Git initialized"));
  assertEqual(await page.locator("#repository-list li").count(),2,"connections retained");
  await page.click("#repository-close");assert(await page.isHidden("#repositories-sheet"),"close failed");
  assertEqual(errors.length,0,"renderer errors");await page.close();return "explicit company, two folders and opt-in Git initialization";
 });
 await run.check("a refused connection stays unconnected and says why",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});
  await page.addInitScript(()=>window.__RICHOS_MOCK_PRESET__={repositoryRefusal:true});
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.click("#set-repositories-open");
  await page.waitForSelector("#repository-company option:nth-child(2)",{state:"attached"});
  await page.selectOption("#repository-company",await page.locator("#repository-company option").nth(1).getAttribute("value"));
  await page.fill("#repository-folder","/fictional/nonempty");await page.click("#repository-connect");
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent.includes("empty folder"));
  assert((await page.textContent("#repository-list")).includes("No repositories"),"refusal rendered as connected");
  assertEqual(await page.inputValue("#repository-folder"),"/fictional/nonempty","retry lost entered folder");
  assert(!await page.isDisabled("#repository-connect"),"retry disabled");await page.close();return "backend refusal preserved with retry available";
 });
 await browser.close();process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
