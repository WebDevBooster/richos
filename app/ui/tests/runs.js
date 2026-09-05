"use strict";
const fs=require("fs");
const {loadPlaywright,createRun,assert,assertEqual}=require("./lib/harness");
const C=require("./lib/contrast");
const A=require("./lib/assignments");
async function main(){
 const browser=await loadPlaywright().webkit.launch(), run=createRun("Assignment controls in the shipping shell");
 const page=await A.open(browser);
 const panel=page.locator("#managed-run");
 const click=label=>panel.getByRole("button",{name:label,exact:true}).click();
 await run.check("Running work has pinned Pause and End with one closed history disclosure",async()=>{
   await A.drive(page); assert(await panel.locator("[data-run-pause]").isVisible());assert(await panel.locator("[data-run-end]").isVisible());
   assertEqual(await panel.locator("details").count(),1);assertEqual(await panel.locator("details").getAttribute("open"),null);
   assert(!(await panel.innerText()).includes("Completion checks"));assertEqual(await panel.locator("[data-run-picker]").count(),1);
 });
 await run.check("Every required control is in the viewport at five sizes in both themes",async()=>{
   for(const theme of ["dark","light"])for(const [width,height]of [[1400,900],[1280,800],[1024,768],[760,720],[520,680]])for(const state of ["running","decision"]){
     await A.resize(page,{width,height}); await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);await A.drive(page,state);
     const clipped=await panel.evaluate(root=>Array.from(root.querySelectorAll("[data-run-pause],[data-run-end],[data-run-answer],[data-run-scope]")).filter(e=>{const r=e.getBoundingClientRect();const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return r.top<0||r.bottom>innerHeight||!e.contains(hit);}).map(e=>e.textContent));
     assertEqual(clipped,[],`${theme} ${width}x${height} ${state}`);
     if(state==="decision")assert(await panel.locator(".run-question-body").evaluate(e=>e.scrollHeight<=e.clientHeight),"Resource question and spending terms must fit without scrolling");
     const size=await panel.boundingBox();if(state==="running")assert(size.height<height*.3,`${size.height}/${height}`);
   }
   await A.resize(page,{width:1400,height:900});
 });
 await run.check("Resource Continue calls the real command contract with assignment and decision identities",async()=>{
   await A.drive(page,"decision");assert(!(await panel.innerText()).includes("CEO_DECISION"));await click("Keep going");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="respond_run_decision"&&a.runId==="assignment-1"&&a.taskId==="task-1"&&a.decisionId==="question-1"&&a.action.kind==="continue")));
   assert(!(await panel.innerText()).includes("Waiting for your decision"));
 });
 await run.check("Scope changes send the exact typed correction through the decision command",async()=>{
   await A.drive(page,"decision");await click("Change instructions");await panel.getByLabel("New instructions").fill("Summary only. Do not send it.");await click("Send decision");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="respond_run_decision"&&a.action.kind==="change_scope"&&a.action.text==="Summary only. Do not send it.")));
 });
 await run.check("End requires confirmation and uses the question identity while a decision is pending",async()=>{
   await A.drive(page,"decision");await click("End assignment");assert(!(await page.evaluate(()=>window.assignmentCalls.some(([n])=>n==="end_run"||n==="respond_run_decision"))));
   assert((await panel.innerText()).includes("Prepare the Q4 investor update"));await click("Go back");assert(await panel.locator("[data-run-end]").isVisible());
   await click("End assignment");await click("Confirm end");assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="respond_run_decision"&&a.action.kind==="end")));
   assert((await panel.locator('[role="status"]').innerText()).includes("Ended without completion"));
 });
 await run.check("Business options ask for confirmation and free answers keep their exact wording",async()=>{
   await A.drive(page,"decision");await page.evaluate(async()=>{const d=window.assignmentCurrent.tasks[1].decision;d.resource=false;d.options=["Buy A","Buy B"];d.question="Which supplier should Rich use?";await window.RichRuns.show("hiring");});
   assertEqual(await panel.getByText("Keep going",{exact:true}).count(),0);await click("Buy B");await click("Confirm decision");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="respond_run_decision"&&a.action.text==="Buy B")));
   await A.drive(page,"decision");await page.evaluate(async()=>{window.assignmentCurrent.tasks[1].decision.resource=false;await window.RichRuns.show("hiring");});
   await click("Write an answer");await panel.getByLabel("Your answer").fill("Buy B, under $80.");await click("Send decision");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="respond_run_decision"&&a.action.kind==="answer"&&a.action.text==="Buy B, under $80.")));
 });
 await run.check("Stale-decision failures retain the draft and offer Refresh before technical history",async()=>{
   await A.drive(page,"decision");await click("Change instructions");await panel.getByLabel("New instructions").fill("Keep the report private.");await page.evaluate(()=>window.decisionFailure="This decision has changed");await click("Send decision");
   assertEqual(await panel.getByLabel("New instructions").inputValue(),"Keep the report private.");assert(await panel.locator("[data-run-refresh]").isVisible());
   assert(!(await panel.innerText()).includes("This decision has changed"));
 });
 await run.check("Load errors use friendly copy and harmless recovery comes first",async()=>{
   await A.drive(page,"error");const text=await panel.innerText();assert(text.includes("Your saved work is kept"));assert(!text.includes("Corrupt"));
   assertEqual(await panel.getByRole("button").first().innerText(),"Refresh assignments");
   assert(await panel.evaluate(e=>e.firstElementChild.getAttribute("role")==="status"));
 });
 await run.check("Twenty assignments report all three decisions and put them first with distinct duplicate names",async()=>{
   await A.drive(page);await page.evaluate(async()=>{window.assignmentRows=Array.from({length:20},(_,i)=>({...window.assignmentCurrent,runId:String(i).padStart(8,"0"),state:[1,9,17].includes(i)?"needs_decision":"running"}));window.assignmentCurrent=window.assignmentRows[0];await window.RichRuns.show("hiring");});
   assert((await panel.locator('[role="status"]').innerText()).includes("3 need you"));await panel.locator("[data-run-picker]").click();
   const rows=await panel.locator("[data-run-choice]").allTextContents();assertEqual(new Set(rows).size,20);assert(rows.slice(0,3).every(t=>t.includes("Needs your decision")));
   await panel.locator('[data-run-choice="00000009"]').click();await click("End assignment");await click("Confirm end");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="end_run"&&a.runId==="00000009")));
 });
 await run.check("Pause changes the visible status and issues a scoped backend request",async()=>{
   await A.drive(page);await click("Pause assignment");assert((await panel.locator('[role="status"]').innerText()).includes("Paused"));
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="pause_run"&&a.runId==="assignment-1")));
 });
 await run.check("Definition of done and file controls are at least 16px",async()=>{
   await A.drive(page);await panel.locator("summary").click();assert(await panel.locator(".run-checks").first().evaluate(e=>parseFloat(getComputedStyle(e).fontSize)>=16));
   await A.drive(page,"empty");await panel.locator("summary").evaluate(e=>e.parentElement.open=true);
   const sizes=await panel.locator("input").evaluate(e=>[getComputedStyle(e).fontSize,getComputedStyle(e,"::file-selector-button").fontSize].map(parseFloat));assert(sizes.every(n=>n>=16));
 });
 await run.check("Importing an assignment never executes it",async()=>{
   await panel.getByLabel("Import assignment from a file").setInputFiles({name:"assignment.json",mimeType:"application/json",buffer:Buffer.from('{"goal":"Imported assignment"}')});
   await page.waitForFunction(()=>window.assignmentCalls.some(([n])=>n==="prepare_run"));assert(!(await page.evaluate(()=>window.assignmentCalls.some(([n])=>n==="drive_run"))));
 });
 await run.check("The shared contrast walk measures the real panel in both themes, including open history and picker",async()=>{
   for(const theme of ["dark","light"])for(const state of ["empty","running","decision","error"]){
     await A.drive(page,state);await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);
     await panel.locator("summary").evaluate(e=>e.parentElement.open=true);
     await page.evaluate(C.pageScript());const out=await page.evaluate(()=>window.__contrastProbe({surface:"assignment",theme:document.documentElement.dataset.theme}));
     assertEqual(Object.keys(out.failures),[],JSON.stringify(out.failures));assertEqual(Object.keys(out.unresolvable),[],JSON.stringify(out.unresolvable));
     assert(out.measuredPaths.some(p=>p.includes("managed-run")),"Panel absent from contrast walk");
   }
 });
 await run.check("Old revisions and other conversations cannot replace the displayed work",async()=>{
   await A.drive(page);await page.evaluate(async()=>{
     await window.emitAssignment({...window.assignmentCurrent,revision:1,goal:"Stale content"});
     await window.emitAssignment({...window.assignmentCurrent,threadId:"other",goal:"Other private work"});
     await window.emitAssignment({...window.assignmentCurrent,runId:"obsolete",revision:999,goal:"Obsolete content"});
   });assert(!(await panel.innerText()).match(/Stale content|Other private work|Obsolete content/));
 });
 await run.check("Portfolio status refreshes when another assignment needs attention without stealing selection",async()=>{
   await A.drive(page);await page.evaluate(async()=>{
     const another={...window.assignmentCurrent,runId:"another",state:"needs_decision",goal:"Separate work"};
     window.assignmentRows.push(another);await window.emitAssignment(another);
   });assert((await panel.locator('[role="status"]').innerText()).includes("1 need you"));
   assert((await panel.locator('[data-run-picker]').innerText()).includes("Prepare the Q4 investor update"));
 });
 await run.check("History and instruction editing preserve visible controls at the smallest viewport",async()=>{
   await A.resize(page,{width:520,height:680});
   await A.drive(page,"decision");await click("Change instructions");await panel.locator("summary").evaluate(e=>e.parentElement.open=true);
   const r=await panel.getByRole("button",{name:"Send decision",exact:true}).boundingBox();assert(r.y>=0&&r.y+r.height<=680);
   await click("Go back");assert(await panel.locator("[data-run-pause]").isVisible());await A.resize(page,{width:1400,height:900});
 });
 await run.check("Unreadable assignment recovery requires an explicit confirmation",async()=>{
   await A.drive(page,"error");await panel.locator("summary").evaluate(e=>e.parentElement.open=true);await click("Set aside unreadable assignment");
   assert(!(await page.evaluate(()=>window.assignmentCalls.some(([n])=>n==="archive_run"))));await click("Confirm set aside");
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n])=>n==="archive_run")));
 });
 await run.check("Thread changes clear the assignment and its error",async()=>{await page.evaluate(()=>window.RichRuns.show(null));assert(await panel.isHidden());assertEqual(await panel.innerText(),"");});
 assertEqual(page.__errors,[]);fs.mkdirSync("/tmp/richos-urban-shots",{recursive:true});await A.drive(page,"decision");await page.screenshot({path:"/tmp/richos-urban-shots/decision.png"});await browser.close();return run.report();
}
main().then(n=>process.exit(n?1:0),e=>{console.error(e);process.exit(1);});
