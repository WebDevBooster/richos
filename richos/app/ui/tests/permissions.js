"use strict";
const path=require("path");
const {loadPlaywright,createRun,assert,assertEqual,UI_DIR,leaveHome}=require("./lib/harness");
async function main(){
 const run=createRun("native permission decisions in the shipping renderer");const browser=await loadPlaywright().webkit.launch();
 for(const allow of [true,false]) await run.check(allow?"explicit approval is bound to the displayed request":"decline is returned without approval",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[];page.on("pageerror",e=>errors.push(String(e)));
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.evaluate(()=>{window.__RICHOS_MOCK_PRESET__={pendingPermission:{id:"synthetic-action",binding:{entity_id:"depot"},tool:"Write",input:{file_path:"/fictional/one.txt",content:"<img src=x onerror=alert(1)>"},description:"Write one fictional file",reason:"Outside the approved directory <img src=x onerror=alert(1)>"}};});
  await page.waitForSelector("#permission-sheet:not([hidden])");
  assert((await page.textContent("#permission-input")).includes("<img"),"tool input missing");assertEqual(await page.locator("#permission-input img").count(),0,"tool input was interpreted as markup");
  assert((await page.textContent("#permission-description")).includes("Outside the approved directory"),"permission reason was omitted");assertEqual(await page.locator("#permission-description img").count(),0,"permission reason was interpreted as markup");
  await page.click(allow?"#permission-allow":"#permission-deny");await page.waitForSelector("#permission-sheet",{state:"hidden"});
  assertEqual(await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.permissionAnswer),allow,"wrong permission decision");assertEqual(errors.length,0,"renderer errors");await page.close();return "one decision for the displayed action";
 });
 await run.check("Stop removes a stale permission request",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__={pendingPermission:{id:"stale",binding:{entity_id:"depot"},tool:"Bash",input:{command:"true"}}});
  await page.waitForSelector("#permission-sheet:not([hidden])");await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.pendingPermission=null);
  await page.waitForSelector("#permission-sheet",{state:"hidden"});assertEqual(await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.permissionAnswer),undefined,"disappearance granted permission");await page.close();return "stale requests disappear without approval";
 });
 // AUDIT-9 ROW 5 — what the sheet PUTS IN FRONT OF HIM, and in what order.
 //
 // Ray, on candidate .9: "A raw command line, inside a JSON object, with escaped quotes and a
 // backslash alternation, in a small scrollable box, put to a man who is not going to read it.
 // The `description` field directly beneath it is the thing he can actually judge, and it is the
 // smaller of the two."
 //
 // So: the sentence he can judge comes first, the raw form starts closed, and it is still
 // REACHABLE — one press, from the keyboard as well as the mouse. Nothing is taken away.
 await run.check("the sheet says what is about to happen before it shows the raw form",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[];page.on("pageerror",e=>errors.push(String(e)));
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.evaluate(()=>{window.__RICHOS_MOCK_PRESET__={pendingPermission:{id:"row5",binding:{entity_id:"depot"},tool:"Bash",
   input:{command:"cd /tmp/fixture && git log --oneline -5 --all && grep -in \"nine\\\\|eight\" notes.txt",description:"Check the fixture repo's history and notes file"},
   description:"Check the fixture repo's history and notes file"}};});
  await page.waitForSelector("#permission-sheet:not([hidden])");
  // ORDER, read from the document rather than from the stylesheet: the description precedes the
  // raw form, and it precedes the scope line too.
  const order=await page.evaluate(()=>{
   const ids=["permission-description","permission-scope","permission-detail","permission-input"];
   const nodes=ids.map(id=>document.getElementById(id));
   return nodes.every(Boolean)&&ids.filter((_,i)=>i===0||(nodes[i-1].compareDocumentPosition(nodes[i])&Node.DOCUMENT_POSITION_FOLLOWING)).length===ids.length?ids:["OUT OF ORDER"];
  });
  assertEqual(order,["permission-description","permission-scope","permission-detail","permission-input"],"the raw form is not last in the sheet");
  assert(await page.isHidden("#permission-input"),"the raw command is on screen before he asked for it");
  assertEqual(await page.getAttribute("#permission-detail","aria-expanded"),"false","the disclosure lies about its own state");
  // ...AND IT IS STILL THERE. The text is in the document whether or not the box is open, which
  // is what keeps the two checks above this one honest about markup.
  assert((await page.textContent("#permission-input")).includes("git log --oneline"),"the exact request is not in the document at all");
  // ONE PRESS OPENS IT, AND THE PRESS IS REACHABLE FROM THE KEYBOARD. Tab used to flip between
  // Decline and Allow only; a disclosure outside that ring would be mouse-only.
  await page.keyboard.press("Tab");await page.keyboard.press("Tab");
  assertEqual(await page.evaluate(()=>document.activeElement&&document.activeElement.id),"permission-detail","Tab does not reach the disclosure");
  await page.keyboard.press("Enter");
  assert(await page.isVisible("#permission-input"),"the disclosure did not open");
  assertEqual(await page.getAttribute("#permission-detail","aria-expanded"),"true","the disclosure opened without saying so");
  assertEqual(await page.textContent("#permission-detail"),"Hide the technical detail","the label still offers to show what is already shown");
  // AND ESCAPE STILL DECLINES, from a hand that is nowhere near Decline.
  await page.keyboard.press("Escape");
  await page.waitForSelector("#permission-sheet",{state:"hidden"});
  assertEqual(await page.evaluate(()=>window.__RICHOS_MOCK_PRESET__.permissionAnswer),false,"Escape hid the request without declining it");
  assertEqual(errors.length,0,"renderer errors");await page.close();
  return "description, scope, then a closed disclosure — reachable by Tab, opened by Enter, and Escape still declines";
 });
 await browser.close();process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
