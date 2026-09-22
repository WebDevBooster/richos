const test=require('node:test'),assert=require('node:assert/strict');
const {find}=require('../lib/notification-target.js'),{createThread}=require('../lib/thread.js');
test('an old notification retrieves history until its actual reply is found',async()=>{
 const model=createThread();model.merge({id:'new',cursor:100});const calls=[];
 const found=await find({model,matches:async row=>row.id==='wanted',fetchPage:async before=>{calls.push(before);return {messages:[{id:before===100?'older':'wanted',cursor:before-40}],more:true}}});
 assert.equal(found.id,'wanted');assert.deepEqual(calls,[100,60]);
});
test('cached targets need no fetch and an empty history stops without a request loop',async()=>{
 const model=createThread();model.merge({id:'wanted',cursor:20});let count=0;
 const fetchPage=async()=>{count++;return {messages:[],more:true}};
 assert.equal((await find({model,matches:r=>r.id==='wanted',fetchPage})).id,'wanted');assert.equal(count,0);
 assert.equal(await find({model,matches:()=>false,fetchPage}),null);assert.equal(count,1);
});
test('switching away during history fetch cannot focus or merge the previous conversation',async()=>{
 const model=createThread();let current=true;
 const found=await find({model,matches:()=>true,isCurrent:()=>current,fetchPage:async()=>{current=false;return {messages:[{id:'wrong',cursor:1}],more:false}}});
 assert.equal(found,null);assert.deepEqual(model.view([]),[]);
});

test('a live reply arriving during history lookup is found even if absent from that page',async()=>{
 const model=createThread();
 const found=await find({model,matches:row=>row.id==='wanted',fetchPage:async()=>{model.merge({id:'wanted',cursor:10});return {messages:[],more:false};}});
 assert.equal(found.id,'wanted');
});

test('only visible completed replies are acknowledged, once per thread and message',async()=>{
 const sent=[];const observe=require('../lib/notification-target.js').receipts(async(t,id)=>sent.push([t,id]));
 const rows=[{id:'r',role:'rich',complete:false}];
 await observe('a',rows,true);rows[0].complete=true;await observe('a',rows,false);assert.deepEqual(sent,[]);
 await observe('a',rows,true);await observe('a',rows,true);await observe('b',rows,true);
 assert.deepEqual(sent,[['a','r'],['b','r']]);
});
test('a failed receipt can retry and simultaneous renders do not duplicate the request',async()=>{
 let calls=0,release;const observe=require('../lib/notification-target.js').receipts(async()=>{calls++;if(calls===1)throw Error('offline');await new Promise(r=>release=r);});
 const rows=[{id:'r',role:'rich'}];await observe('a',rows,true);
 const pending=observe('a',rows,true);await observe('a',rows,true);assert.equal(calls,2);release();await pending;
 await observe('a',rows,true);assert.equal(calls,2);
});
