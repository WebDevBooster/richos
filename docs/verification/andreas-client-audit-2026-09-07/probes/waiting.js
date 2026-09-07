'use strict';
const fs = require('fs'), Module = require('module');
const root = '/Users/alex/ab/richos';
const filename = root + '/app/ui/tests/waiting-state.js';
const mod = new Module(filename, module);
mod.filename = filename;
mod.paths = Module._nodeModulePaths(root + '/app/ui/tests');
mod._compile(fs.readFileSync(filename, 'utf8').replace(/main\(\)\.catch\([\s\S]*$/, 'module.exports = { openApp, startTurn, goWorking, advance, tick, band };'), filename);
const {openApp,startTurn,goWorking,advance,tick,band}=mod.exports;
const {webkit}=require(root+'/app/ui/tests/node_modules/playwright');
const output=[];
const record=async(page,name)=>{const b=await band(page);const ui=await page.evaluate(()=>({stop:{hidden:document.getElementById('stop').hidden,disabled:document.getElementById('stop').disabled},input:document.getElementById('input').value,messages:document.getElementById('messages').innerText,wait:window.__RICHOS_WAIT__(),errors:window.__probeErrors||[]}));output.push({name,band:b,ui});console.log(name,JSON.stringify({band:b,stop:ui.stop,input:ui.input,messages:ui.messages}));};
(async()=>{
const browser=await webkit.launch();
try {
// Actual rejection arriving after queued, before working. Keep promise controlled.
let p=await openApp(browser,'dark');
await p.evaluate(()=>{const oi=window.RichBridge.invoke;window.RichBridge.invoke=(cmd,args)=>cmd==='send_message'?new Promise((resolve,reject)=>{window.__rejectSend=reject;}):cmd==='stop_turn'?Promise.resolve({stopped:false,turnId:null,reachedLease:false}):oi(cmd,args);});
await startTurn(p,'audit_prime');
await advance(p,60000);await tick(p);await record(p,'queued after 60s');
await p.locator('#stop').click();await p.waitForTimeout(100);await record(p,'Stop while priming returns stopped:false');
await p.evaluate(()=>window.__rejectSend('cognition io: first priming process exited'));
await p.waitForTimeout(100);await advance(p,240000);await tick(p);await record(p,'priming rejected; after total 5m');
await p.screenshot({path:'/tmp/richos-audit-20260907/ray/priming-failed-5m.png'});await p.close();
// Pending invocation with no accepted turn, eg waiting for spine mutex.
p=await openApp(browser,'dark');await p.evaluate(()=>window.__TAP.hang=true);await p.fill('#input','Hello Rich, can you help?');await p.press('#input','Enter');await advance(p,60000);await tick(p);await record(p,'send pending 60s without queued event');await p.close();
// An unrelated description-free event resets the displayed age of the previous fact.
p=await openApp(browser,'dark');let f=await startTurn(p,'audit_age');await goWorking(p,f,'audit_age');
await p.evaluate(f=>window.__emit('rich://activity-upserted',{...f,kind:'activity',id:'audit_first',turnId:'audit_age',createdAt:Date.now(),sequence:1,slot:'stream',visibility:'ceo',activityType:'command',state:'completed',summary:'Read the Q3 board pack',at:Date.now()}),f);
await advance(p,23000);await tick(p);await record(p,'last described activity 23s old before new event');
await p.evaluate(f=>window.__emit('rich://activity-upserted',{...f,kind:'activity',id:'audit_new_no_summary',turnId:'audit_age',createdAt:Date.now(),sequence:2,slot:'stream',visibility:'ceo',activityType:'command',state:'running',at:Date.now()}),f);
await advance(p,3000);await tick(p);await record(p,'26s-old completed activity now described as 3s ago');await p.close();
}finally{await browser.close();fs.writeFileSync('/tmp/richos-audit-20260907/ray/probe-results.json',JSON.stringify(output,null,2));}
})().catch(e=>{console.error(e);process.exitCode=1;});
