"use strict";
const path=require("path");
const {loadPlaywright,createRun,assert,assertEqual,UI_DIR,leaveHome}=require("./lib/harness");
async function main(){
 const run=createRun("non-blocking question cards"); const browser=await loadPlaywright().webkit.launch();
 const page=await browser.newPage({viewport:{width:1280,height:900}}); const errors=[];page.on("pageerror",e=>errors.push(String(e)));
 await page.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(page);
 await page.evaluate(()=>{
  // This component suite owns its mounting surface. main.js retains the original
  // messages element and periodically repaints it, even without a user turn.
  // Give fixtures an identical sibling so that refresh cannot erase a test card.
  const live=document.getElementById("messages");
  const fixture=live.cloneNode(false);live.id="live-messages";live.hidden=true;
  live.after(fixture);
  window.answerCalls=[];window.shownCalls=[];
  const invoke=window.RichBridge.invoke;
  window.RichBridge.invoke=async(command,args)=>{
   if(command==="question_shown"){shownCalls.push(args);return;}
   if(command==="answer_question"){
    answerCalls.push(args);const q=structuredClone(window.fixtureQuestion);
    q.state="answered";q.revision++;q.answer={...args.answer,method:args.method,surface:"mac"};return {outcome:"accepted",question:q};
   }
   return invoke(command,args);
  };
  window.mountQuestion=(multiple=false)=>{
   document.querySelectorAll(".question-row").forEach(n=>n.remove());
   const q={id:crypto.randomUUID(),thread_id:"general",set_id:"set",text:"When should the release ship?",options:[{id:"today",label:"Ship today",description:"Earlier fixes"},{id:"tomorrow",label:"Ship tomorrow",description:"More testing"}],multiple,free_answer:true,recommended:"tomorrow",state:"open",revision:0,delivered:false};
   window.fixtureQuestion=q;document.getElementById("messages").appendChild(window.RichQuestions.render({threadId:"general",question:q}));
  };
 });
 await run.check("question module loaded before the native bridge still acknowledges and answers",async()=>{
  // index.html loads questions.js before main.js installs RichBridge in Tauri.
  // mock.js installs it earlier in ordinary browser fixtures, hiding this ordering.
  const late=await browser.newPage();const lateErrors=[];late.on("pageerror",e=>lateErrors.push(String(e)));
  try {
   await late.goto("file://"+path.join(UI_DIR,"index.html"));await leaveHome(late);
   await late.evaluate(()=>{window.savedBridge=window.RichBridge;delete window.RichBridge;});
   await late.addScriptTag({path:path.join(UI_DIR,"questions.js")});
   await late.evaluate(()=>{
    window.lateCalls=[];
    const q={id:"late-bridge",text:"Ship when?",options:[{id:"today",label:"Today",description:"Earlier fixes"},{id:"tomorrow",label:"Tomorrow",description:"More testing"}],multiple:false,free_answer:true,state:"open",revision:0,delivered:false};
    window.RichBridge={...savedBridge,invoke:async(c,a)=>{lateCalls.push(c);if(c==="answer_question")return {outcome:"accepted",question:{...q,state:"answered",revision:1,remaining:0,answer:{...a.answer,method:a.method,surface:"mac"}}};}};
    document.getElementById("messages").appendChild(RichQuestions.render({threadId:"general",question:q}));
   });
   await late.waitForFunction(()=>lateCalls.includes("question_shown"));
   await late.locator('[data-question-id="late-bridge"] .question-option').first().click();
   await late.waitForFunction(()=>lateCalls.includes("answer_question"));
   assertEqual(await late.locator('[data-question-id="late-bridge"]').getAttribute("data-state"),"answered","native-order answer stayed pending");
   assertEqual(lateErrors,[],"native-order renderer errors");
  } finally {await late.close();}
  return "bridge resolves when used, after the native shell installs it";
 });
 await run.check("single tap saves once and leaves composer draft and focus alone",async()=>{
  await page.fill("#input","Keep this draft");await page.evaluate(()=>mountQuestion());
  assertEqual(await page.inputValue("#input"),"Keep this draft","draft changed");
  assertEqual(await page.evaluate(()=>document.activeElement.id),"input","card stole focus");
  assertEqual(await page.locator('.question-option[aria-checked="true"]').count(),0,"option preselected");
  await page.locator(".question-option").first().click();
  await page.waitForFunction(()=>answerCalls.length===1);
  assertEqual(await page.inputValue("#input"),"Keep this draft","answer overwrote composer");
  assert((await page.textContent(".question-status")).includes("Ship today"),"answer missing");
  assertEqual(await page.evaluate(()=>shownCalls.length),1,"display was not acknowledged once");
  return "saved one answer and preserved draft";
 });
 await run.check("multiple choices require Send and keyboard digits stay in the card",async()=>{
  await page.evaluate(()=>mountQuestion(true));await page.focus("#input");await page.keyboard.type("2");
  assertEqual(await page.evaluate(()=>answerCalls.length),1,"composer digit answered question");
  await page.locator(".question-option").first().focus();await page.keyboard.press("1");await page.keyboard.press("2");
  assertEqual(await page.locator('.question-option[aria-checked="true"]').count(),2,"digits did not select choices");
  assertEqual(await page.evaluate(()=>answerCalls.length),1,"selection sent before Send");
  await page.locator(".ask-foot .ask-send").click();
    await page.waitForFunction(()=>answerCalls.length===2);
  assertEqual(await page.evaluate(()=>answerCalls[1].answer.option_ids.length),2,"multiple answer lost choice");return "scoped keyboard and explicit submission";
 });
 await run.check("free answer and Escape preserve the main conversation",async()=>{
  await page.evaluate(()=>mountQuestion());await page.getByRole("button",{name:"Other answer",exact:true}).click();
  await page.getByRole("textbox",{name:"Other answer"}).fill("Next Tuesday");
  await page.locator(".question-controls form button").click();await page.waitForFunction(()=>answerCalls.length===3);
  assertEqual(await page.evaluate(()=>answerCalls[2].answer.text),"Next Tuesday","free answer lost");
  await page.getByRole("button",{name:"Change answer",exact:true}).click();await page.keyboard.press("Escape");
  assertEqual(await page.evaluate(()=>document.activeElement.id),"input","Escape trapped focus");
  await page.locator(".question-option").last().click();await page.waitForFunction(()=>answerCalls.length===4);
  assertEqual(await page.evaluate(()=>answerCalls[3].answer.expected_revision),1,"edit lost revision");return "typed answer, explicit revision and unblocked composer";
 });

 await run.check("uncertain save retries the same answer without replacing it",async()=>{
  await page.evaluate(()=>{mountQuestion();window.originalAnswerInvoke=RichBridge.invoke;let uncertain=true;RichBridge.invoke=async(c,a)=>{if(c==="answer_question" && uncertain){uncertain=false;window.uncertainAnswer=a;throw new Error("Receipt lost");}return originalAnswerInvoke(c,a);};});
  await page.locator(".question-option").first().click();
  await page.getByRole("button",{name:"Retry saved answer",exact:true}).click();
  await page.waitForFunction(()=>answerCalls.length===5);
  assertEqual(await page.evaluate(()=>answerCalls[4]),await page.evaluate(()=>uncertainAnswer),"retry changed the saved input");
  await page.evaluate(()=>{RichBridge.invoke=originalAnswerInvoke;});
  return "same submission identity and exact answer after an uncertain receipt";
 });
 await run.check("round 13 text, boundaries and font scaling work in both themes",async()=>{
  const C=require("./lib/contrast");await page.addScriptTag({content:C.pageScript()});
  const measurements=[];
  for(const theme of ["dark","light"]){
   await page.evaluate(theme=>{document.documentElement.dataset.theme=theme;mountQuestion(true);},theme);
   await page.locator(".question-card.ask").scrollIntoViewIfNeeded();
   await page.locator(".question-option").first().focus();
   await page.waitForTimeout(650);
   const values=await page.evaluate(()=>{
    const M=window.__contrastMath,card=document.querySelector(".question-card.ask");
    const background=el=>{const chain=[];for(let e=el;e;e=e.parentElement)chain.unshift(e);let bg={r:255,g:255,b:255,a:1};for(const e of chain){const c=M.parseCssColor(getComputedStyle(e).backgroundColor);if(c)bg=M.compositeOver(c,bg);}return bg;};
    const text=[...card.querySelectorAll("*")].filter(el=>el.getClientRects().length&&[...el.childNodes].some(n=>n.nodeType===3&&n.textContent.trim())&&!el.closest(":disabled")&&!el.classList.contains("ask-box")).map(el=>{const cs=getComputedStyle(el),bg=background(el);return {text:el.textContent,ratio:M.contrastRatio(M.compositeOver(M.parseCssColor(cs.color),bg),bg),size:parseFloat(cs.fontSize)};});
    const controls=[...card.querySelectorAll(".ask-opt,.ask-box")].map(el=>{const cs=getComputedStyle(el),bg=background(el);return {name:el.className,ratio:M.contrastRatio(M.compositeOver(M.parseCssColor(cs.borderTopColor),bg),bg)};});
    return {text,controls,title:getComputedStyle(card.querySelector(".ask-q")).fontSize};
   });
   for(const n of values.text){assert(n.ratio>=4.5,theme+" text contrast: "+JSON.stringify(n));assert(n.size>=16,theme+" text below 16px: "+JSON.stringify(n));}
   for(const n of values.controls)assert(n.ratio>=3,theme+" boundary contrast: "+JSON.stringify(n));
   assertEqual(values.title,"22px","round 13 open title size");
   await page.evaluate(()=>{document.documentElement.style.fontSize="20px";});
   assertEqual(await page.locator(".ask-q").evaluate(el=>getComputedStyle(el).fontSize),"27.5px","question ignored font scaling");
   await page.evaluate(()=>{document.documentElement.style.fontSize="";});
   if(process.env.RICHOS_QUESTION_SHOTS){require("fs").mkdirSync(process.env.RICHOS_QUESTION_SHOTS,{recursive:true});await page.screenshot({path:path.join(process.env.RICHOS_QUESTION_SHOTS,"questions-"+theme+".png")});}
   measurements.push(theme+" text min "+Math.min(...values.text.map(n=>n.ratio)).toFixed(2)+":1; boundary min "+Math.min(...values.controls.map(n=>n.ratio)).toFixed(2)+":1");
  }
  return measurements.join("; ");
 });
 assertEqual(errors,[],"renderer errors");await browser.close();process.exit(run.report()?1:0);
}
main().catch(e=>{console.error(e);process.exit(1);});
