"use strict";
const path = require("path");
const { UI_DIR, leaveHome } = require("./harness");
function assignment(state = "running", id = "assignment-1") {
  return { threadId: "hiring", runId: id, revision: 2, createdAt: 1788634800000, autonomous: true,
    goal: "Prepare the Q4 investor update", state, workspace: "/fixture", tasks: [0,1,2].map((n) => ({
      id: "task-"+n, description: ["Gather the figures", "Write the update", "Deliver the approved update"][n],
      state: n===0 ? "passed" : n===1 ? "running" : "pending", checks: ["The figures match the ledger"], evidence: [], commands: []
    })) };
}
function fixture(state) {
  if (state === "empty" || state === "error") return null;
  const a = assignment(state === "decision" ? "needs_decision" : state);
  if (state === "decision") {
    a.tasks[1].state = "needs_decision";
    a.tasks[1].decision = { id: "question-1", resource: true,
      question: "Rich has used the allowance without finishing.",
      whyCeo: "Keep going allows up to 10 more attempts of up to 15 minutes each, plus checks. Provider charges apply.",
      recommendation: "Review what happened before spending more, or change the instructions.", options: [] };
    a.tasks[1].evidence = ['CEO_DECISION:internal marker must not be displayed'];
  }
  return a;
}
async function drive(page, state = "running") {
  await page.evaluate(({ snapshot, state }) => {
    if (!window.__assignmentOriginal) {
      window.__assignmentOriginal = window.RichBridge.invoke.bind(window.RichBridge);
      window.RichBridge.invoke = async (name, args) => {
        window.assignmentCalls.push([name, args]);
        if (name === "list_runs") return window.assignmentRows;
        if (name === "get_run") { if (window.assignmentError) throw Error(window.assignmentError); return window.assignmentCurrent; }
        if (name === "select_run") { window.assignmentCurrent = window.assignmentRows.find(a => a.runId === args.runId); return window.assignmentCurrent; }
        if (name === "pause_run") { window.assignmentCurrent.state = "paused"; return; }
        if (name === "drive_run") { window.assignmentCurrent.state = "running"; return window.assignmentCurrent; }
        if (name === "retry_run_task") { window.assignmentCurrent.tasks.find(t=>t.id===args.taskId).state="pending";return window.assignmentCurrent; }
        if (name === "end_run") { window.assignmentCurrent.state = "canceled"; return window.assignmentCurrent; }
        if (name === "respond_run_permission") {
          if (window.decisionFailure) throw Error(window.decisionFailure);
          window.assignmentCurrent.state = "ready";
          for (const t of window.assignmentCurrent.tasks) if (t.id === args.taskId) { t.permission = null; t.state = "pending"; }
          return window.assignmentCurrent;
        }
        if (name === "respond_run_decision") {
          if (window.decisionFailure) throw Error(window.decisionFailure);
          window.assignmentCurrent.state = args.action.kind === "end" ? "canceled" : "ready";
          for (const t of window.assignmentCurrent.tasks) if (t.id === args.taskId) { t.decision = null; t.state = "pending"; }
          return window.assignmentCurrent;
        }
        if (name === "archive_run") { window.assignmentError = ""; return; }
        if (name === "prepare_run") { window.assignmentCurrent = { ...args.plan, threadId:"hiring", runId:"imported", state:"paused", tasks:[] }; return window.assignmentCurrent; }
        return window.__assignmentOriginal(name,args);
      };
    }
    window.assignmentCalls = []; window.assignmentError = state === "error" ? "Corrupt committed journal" : "";
    window.decisionFailure = ""; window.assignmentCurrent = snapshot; window.assignmentRows = snapshot ? [snapshot] : [];
  }, { snapshot: fixture(state), state });
  await page.evaluate(() => window.RichRuns.show("hiring"));
}
async function open(browser, theme = "dark", viewport = { width:1400,height:900 }) {
  const page = await browser.newPage({viewport,colorScheme:theme}); page.setDefaultTimeout(15000); page.__errors=[];
  page.on("pageerror", e=>page.__errors.push(String(e)));
  await page.addInitScript(() => {
    let real; window.assignmentListeners = {};
    Object.defineProperty(window, "RichBridge", { configurable:true, get:()=>real, set:value=>{
      real=value;const listen=value.listen.bind(value);value.listen=(name,fn)=>{(window.assignmentListeners[name] ||= []).push(fn);return listen(name,fn);};
    }});
    window.emitAssignment = async payload => { for(const fn of window.assignmentListeners["rich://run-updated"]||[]) await fn({payload}); };
  });
  await page.addInitScript(t => { localStorage.setItem("richos-theme",t); localStorage.setItem("richos-mock-config",JSON.stringify({theme:t,font_scale:100,user_name:null})); }, theme);
  await page.goto("file://"+path.join(UI_DIR,"index.html")); await leaveHome(page);
  await page.waitForFunction(()=>typeof window.RichRuns === "object");
  await page.waitForSelector('.nav-thread[data-thread-id="hiring"]', {state:"attached"});
  await page.evaluate(()=>document.querySelector('.nav-thread[data-thread-id="hiring"]').click());
  await page.waitForSelector("#managed-run:not([hidden])");
  await page.waitForFunction(()=>!document.getElementById("splash") || document.getElementById("splash").hidden || getComputedStyle(document.getElementById("splash")).display === "none");
  if (await page.locator("#rail-drawer-close").isVisible()) await page.click("#rail-drawer-close");
  await page.evaluate(t=>{document.documentElement.dataset.theme=t;},theme);
  return page;
}
async function resize(page, viewport) {
  await page.setViewportSize(viewport);
  await page.waitForFunction(()=>document.body.classList.contains(innerWidth<820 ? "bp-narrow" : innerWidth>=1180 ? "bp-wide" : "bp-mid"));
  if (await page.evaluate(()=>innerWidth<820 && !document.body.classList.contains("rail-closed"))) await page.click("#rail-drawer-close");
}
async function review(page) {
  const button=page.locator("#managed-run [data-run-review]");
  if (await button.count() && await button.innerText() === "Review decision") await button.click();
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}
const longQuestion = "The Q4 numbers Finance signed off on show 18% growth, but the ledger you asked me to reconcile against shows 14% once the two November credit notes are applied. Should the update to Andreas use the Finance figure, the reconciled figure, or state both and explain the difference?";
const longWhy = "This changes what the board is told about the quarter, and the two figures support different stories about whether the year landed. Rich will not choose between them on your behalf, because the choice is about how much detail you want the board holding, not about which arithmetic is correct.";
async function longDecision(page, repetitions=1, options=3) {
  await drive(page, "decision");
  await page.evaluate(async ({question, why, options}) => {
    Object.assign(window.assignmentCurrent.tasks[1].decision, {resource:false, question, whyCeo:why, options:Array.from({length:options},(_,i)=>`Use approved approach ${i+1}`)});
    await window.RichRuns.show("hiring");
  }, {question:longQuestion.repeat(repetitions), why:longWhy, options});
}
module.exports={assignment,fixture,drive,open,resize,review,longDecision};
