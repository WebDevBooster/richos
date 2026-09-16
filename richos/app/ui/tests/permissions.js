"use strict";
const path=require("path");
const {loadPlaywright,createRun,assert,assertEqual,UI_DIR,leaveHome}=require("./lib/harness");
async function main(){
 const run=createRun("native permission decisions in the shipping renderer");const browser=await loadPlaywright().webkit.launch();
 for(const allow of [true,false]) await run.check(allow?"explicit approval is bound to the displayed request":"decline is returned without approval",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[];page.on("pageerror",e=>errors.push(String(e)));
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.evaluate(()=>{window.__RICHOS_MOCK_PRESET__={pendingPermission:{id:"synthetic-action",binding:{entity_id:"depot"},tool:"Write",input:{file_path:"/fictional/one.txt",content:"<img src=x onerror=alert(1)>"},description:"Write one fictional file"}};});
  await page.waitForSelector("#permission-sheet:not([hidden])");
  assert((await page.textContent("#permission-input")).includes("<img"),"tool input missing");assertEqual(await page.locator("#permission-input img").count(),0,"tool input was interpreted as markup");
  await page.click(allow?"#permission-allow":"#permission-deny");await page.waitForSelector("#permission-sheet",{state:"hidden"});
  assertEqual(await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.permissionAnswer),allow,"wrong permission decision");assertEqual(errors.length,0,"renderer errors");await page.close();return "one decision for the displayed action";
 });
 await run.check("Stop removes a stale permission request",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__={pendingPermission:{id:"stale",binding:{entity_id:"depot"},tool:"Bash",input:{command:"true"}}});
  await page.waitForSelector("#permission-sheet:not([hidden])");await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.pendingPermission=null);
  await page.waitForSelector("#permission-sheet",{state:"hidden"});assertEqual(await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.permissionAnswer),undefined,"disappearance granted permission");await page.close();return "stale requests disappear without approval";
 });
 await browser.close();process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
