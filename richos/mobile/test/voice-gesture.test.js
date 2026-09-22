const test = require('node:test'), assert = require('node:assert/strict');
const {createGesture} = require('../../web/web-app/lib/voice.js');
function setup(start = async () => {}) {
  const calls=[]; const gesture=createGesture({start,cancel:async()=>calls.push('cancel'),finish:async value=>calls.push(value),now:()=>123});
  return {gesture,calls};
}
test('held release sends exactly once, with the conversation captured at press',async()=>{
  const {gesture:g,calls}=setup(), owner={threadId:'one'};
  await g.press(owner); owner.threadId='two'; await g.release(); await g.release();
  assert.deepEqual(calls,[{send:true,context:{threadId:'one'}}]); assert.equal(g.snapshot().phase,'idle');
});
test('upward lock frees the finger; release and movement cannot send or cancel it',async()=>{
  const {gesture:g,calls}=setup(); await g.press({threadId:'one'}); await g.move(0,-70);
  await g.release(); await g.move(-100,0); assert.equal(g.snapshot().phase,'locked'); assert.equal(calls.length,0);
  await g.send(); assert.equal(calls[0].send,true);
});
test('left cancellation never sends on the subsequent release',async()=>{
  const {gesture:g,calls}=setup();await g.press({});await g.move(-90,0);await g.release();assert.deepEqual(calls,['cancel']);
});
test('locked cancellation discards; interruption retains without sending',async()=>{
  const {gesture:g,calls}=setup();await g.press({});g.lock();await g.cancel();
  await g.press({threadId:'one'});await g.interrupt();await g.release();assert.deepEqual(calls,['cancel',{send:false,context:{threadId:'one'}}]);
});
test('releasing during permission cancels and cannot start recording after the answer',async()=>{
  let ready; const {gesture:g,calls}=setup(()=>new Promise(r=>ready=r));
  const opening=g.press({});assert.equal(g.snapshot().phase,'preparing');await g.release();ready();await opening;
  assert.equal(g.snapshot().phase,'idle');assert.deepEqual(calls,['cancel']);
});
test('an interrupted permission request cannot replace a newer gesture',async()=>{
  const starts=[];const {gesture:g,calls}=setup(()=>new Promise(r=>starts.push(r)));
  const first=g.press({threadId:'old'});await g.cancel();const second=g.press({threadId:'new'});
  starts[0]();await first;assert.equal(g.snapshot().phase,'preparing');starts[1]();await second;
  await g.release();assert.deepEqual(calls,['cancel',{send:true,context:{threadId:'new'}}]);
});
