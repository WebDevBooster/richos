"use strict";
const {loadPlaywright,createRun,assert,assertEqual}=require("./lib/harness");
const A=require("./lib/assignments");
async function main(){
 const browser=await loadPlaywright().webkit.launch(), run=createRun("Exact operation permission controls");
 const page=await A.open(browser), panel=page.locator("#managed-run");
 async function prepare(){
   await A.drive(page,"decision");
   await page.evaluate(async()=>{
     const t=window.assignmentCurrent.tasks[1]; t.decision=null;
     t.permission={id:"operation-17",runId:"assignment-1",taskId:t.id,planRevision:4,workspace:"/company/selected",tool:"Bash",input:{command:"python3 validate.py",description:"Validate the saved output"}};
     await window.RichRuns.show("hiring");
   }); await A.review(page);
 }
 await run.check("The exact tool input and workspace are displayed without business-answer controls",async()=>{
   await prepare(); const content=await panel.innerText(); assert(content.includes("/company/selected"));assert(content.includes("python3 validate.py"));
   assertEqual(await panel.getByRole("button",{name:"Write an answer",exact:true}).count(),0);
   assertEqual(await panel.getByRole("button",{name:"Keep going",exact:true}).count(),0);
 });
 for(const [label,action] of [["Allow this operation once","approve_once"],["Decline and find another way","reject"]]) await run.check(`${label} uses the typed permission command and exact identity`,async()=>{
   await prepare(); await panel.getByRole("button",{name:label,exact:true}).click();
   assert(await page.evaluate(expected=>window.assignmentCalls.some(([n,a])=>n==="respond_run_permission"&&a.operationId==="operation-17"&&a.runId==="assignment-1"&&a.taskId==="task-1"&&a.action===expected),action));
   assert(!(await page.evaluate(()=>window.assignmentCalls.some(([n])=>n==="respond_run_decision"))));
 });
 await run.check("A stale approval retains the request and exposes recovery without reporting success",async()=>{
   await prepare();await page.evaluate(()=>window.decisionFailure="The operation changed");await panel.getByRole("button",{name:"Allow this operation once",exact:true}).click();
   assert(await panel.locator("[data-run-refresh]").isVisible());assert((await panel.innerText()).includes("python3 validate.py"));
 });
 await run.check("End uses the real end command when only a permission is pending",async()=>{
   await prepare();await panel.getByRole("button",{name:"End assignment",exact:true}).click();await panel.getByRole("button",{name:"Confirm end",exact:true}).click();
   assert(await page.evaluate(()=>window.assignmentCalls.some(([n,a])=>n==="end_run"&&a.runId==="assignment-1")));
 });
 await run.check("Narrow screens retain both typed controls in the shared reading flow",async()=>{
   await A.resize(page,{width:520,height:680});await prepare();
   for(const name of ["Allow this operation once","Decline and find another way"]){const b=panel.getByRole("button",{name,exact:true});await b.scrollIntoViewIfNeeded();assert(await b.isVisible());}
 });
 assertEqual(page.__errors,[]);await browser.close();return run.report();
}
main().then(n=>process.exit(n?1:0),e=>{console.error(e);process.exit(1);});
