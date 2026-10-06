"use strict";
const path=require("path");
const {loadPlaywright,createRun,assert,assertEqual,UI_DIR,leaveHome}=require("./lib/harness");
async function main(){
 const run=createRun("repository connection in the shipping renderer");
 const browser=await loadPlaywright().webkit.launch();
 await run.check("two repositories connect to an explicitly selected company",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[];page.on("pageerror",e=>errors.push(String(e)));
  await page.addInitScript(()=>window.__RICHOS_MOCK_PRESET__={gitFolders:["/fictional/first project"]});
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.click("#set-repositories-open");
  await page.waitForSelector("#repository-company option:nth-child(2)",{state:"attached"});
  assert(await page.isDisabled("#repository-connect"),"company must be explicitly selected");
  const company=await page.locator("#repository-company option").nth(1).getAttribute("value");
  await page.selectOption("#repository-company",company);
  await page.fill("#repository-folder","/fictional/first project");await page.click("#repository-connect");
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent==="Folder connected.");
  await page.fill("#repository-folder","/fictional/second project");await page.click("#repository-connect");
  // CEO, 2026-10-06: every connected folder gets Git, so there is no opt-in to tick, and
  // the message says when Git was set up.
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent==="Folder connected. Git was set up to track its files.");
  assertEqual(await page.locator("#repository-initialize").count(),0,"the Initialize Git checkbox is gone");
  assertEqual(await page.locator("#repository-list li").count(),2,"connections retained");
  await page.click("#repository-close");assert(await page.isHidden("#repositories-sheet"),"close failed");
  assertEqual(errors.length,0,"renderer errors");await page.close();return "explicit company, two folders, and Git set up for the one without it";
 });
 await run.check("a refused connection stays unconnected and says why",async()=>{
  const page=await browser.newPage({viewport:{width:1280,height:900}});
  await page.addInitScript(()=>window.__RICHOS_MOCK_PRESET__={repositoryRefusal:true});
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.click("#set-repositories-open");
  await page.waitForSelector("#repository-company option:nth-child(2)",{state:"attached"});
  await page.selectOption("#repository-company",await page.locator("#repository-company option").nth(1).getAttribute("value"));
  await page.fill("#repository-folder","/fictional/nonempty");await page.click("#repository-connect");
  await page.waitForFunction(()=>document.getElementById("repository-message").textContent.includes("overlaps"));
  assert((await page.textContent("#repository-list")).includes("No project folders connected yet."),"refusal rendered as connected");
  assertEqual(await page.inputValue("#repository-folder"),"/fictional/nonempty","retry lost entered folder");
  assert(!await page.isDisabled("#repository-connect"),"retry disabled");await page.close();return "backend refusal preserved with retry available";
 });
 await run.check("2d  the sheet says his copy, word for word",async()=>{
  // CEO feedback 2026-10-06_01, item 2d: the table is the specification.
  const page=await browser.newPage({viewport:{width:1280,height:900}});
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.click("#set-repositories-open");
  await page.waitForSelector("#repository-company option:nth-child(2)",{state:"attached"});
  const seen=await page.evaluate(()=>{const q=s=>document.querySelector(s);const notes=[...document.querySelectorAll("#repositories-sheet .overlay-panel > p.overlay-note:not([role])")].map(n=>n.textContent);
   return {headline:q("#repositories-title").textContent,description:notes[0],guidance:notes[1],guidanceSize:notes[1]?getComputedStyle(document.querySelectorAll("#repositories-sheet .overlay-panel > p.overlay-note:not([role])")[1]).fontSize:null,descriptionSize:getComputedStyle(document.querySelectorAll("#repositories-sheet .overlay-panel > p.overlay-note:not([role])")[0]).fontSize,
    company:q('label[for="repository-company"]').textContent,folder:q('label[for="repository-folder"]').textContent,placeholder:q("#repository-folder").placeholder,
    connect:q("#repository-connect").textContent,close:q("#repository-close").textContent,empty:q("#repository-list").textContent};});
  assertEqual(seen.headline,"Connected project folders (repositories)","headline");
  assertEqual(seen.description,"Connect a project folder as this company\u2019s home for Rich. Connecting it does not move or change its existing files.","description");
  assertEqual(seen.guidance,"One folder per company is usually enough. But in rare cases additional folders might be needed. Ask Rich if you\u2019re unsure.","guidance");
  assert(parseFloat(seen.guidanceSize)<parseFloat(seen.descriptionSize)&&parseFloat(seen.guidanceSize)>=14,`guidance is smaller text and never below 14px: ${seen.guidanceSize} under ${seen.descriptionSize}`);
  assertEqual(seen.company,"Company","company label");assertEqual(seen.empty,"No project folders connected yet.","empty state");
  assertEqual(seen.folder,"Project folder location","folder label");assertEqual(seen.placeholder,"Click and select folder","placeholder");
  assertEqual(seen.connect,"Connect folder","primary button");assertEqual(seen.close,"Close","secondary button");
  await page.close();return "headline, description, guidance, labels, empty state, placeholder and both buttons";
 });
 await run.check("2a  the settings row says Connected folders (repositories)",async()=>{
  // CEO feedback 2026-10-06_01, item 2a.
  const page=await browser.newPage({viewport:{width:1280,height:900}});
  await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
  await page.click("#set-btn");await page.waitForSelector("#set-repositories-open");
  assertEqual((await page.textContent("#set-repositories-open")).trim(),"Connected folders (repositories)","the settings menu row");
  await page.close();return "the row reads Connected folders (repositories)";
 });
 await browser.close();process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
