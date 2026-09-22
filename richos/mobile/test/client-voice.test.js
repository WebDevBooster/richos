const test=require('node:test'),assert=require('node:assert/strict');
const {createClient}=require('../core/client.js');
const {harness}=require('../dev/client-runtime.js');
const tick=()=>new Promise(r=>setImmediate(r));
async function setup(t) {
 const h=harness();let count=0;h.ports.nextId=()=>`voice-${++count}`;
 const app=await createClient(h.ports);t.after(()=>app.close());
 await app.dispatch({type:'pair',link:'https://mac.example/#pair=code'});await app.dispatch({type:'confirm-pair',matched:true});await tick();
 h.opened.at(-1).event('hello',{capabilities:['text','voice','audio']});await app.settle();
 await app.dispatch({type:'record-start'});await app.dispatch({type:'record-stop'});
 return {h,app};
}
test('voice enqueue is durable, file-referenced and never changes the typed draft',async t=>{
 const {h,app}=await setup(t);await app.dispatch({type:'network',online:false});
 await app.dispatch({type:'compose',text:'A newer typed draft'});
 await app.dispatch({type:'record-send',id:'recording-1'});
 const item=h.disk().outbox[0];assert.equal(item.kind,'voice');assert.equal(item.fileId,'recording-1');assert.equal(item.threadId,'general');assert.equal(item.bytes,undefined);
 assert.equal(app.state().draft,'A newer typed draft');
 await assert.rejects(app.dispatch({type:'record-delete',id:'recording-1'}),/queued/);
 await assert.rejects(app.dispatch({type:'record-send',id:'recording-1'}),/already queued/);
 await app.dispatch({type:'discard',clientId:item.clientId});assert.equal(app.state().recordings.length,1);
 await app.dispatch({type:'record-delete',id:'recording-1'});assert.equal(app.state().recordings.length,0);
});
test('voice resumes after termination using the same queue ID and actual native file reference',async t=>{
 const {h,app}=await setup(t);await app.dispatch({type:'network',online:false});await app.dispatch({type:'record-send',id:'recording-1'});
 const id=h.disk().outbox[0].clientId;app.close();
 const fetch=h.ports.fetch;let captured;
 h.ports.fetch=async(url,options)=>{if(url.includes('kind=voice')){captured={url,options};return Response.json({message_id:'intake_1',cursor:1,thread_id:'general',accepted_at:'2026-09-22T00:00:00Z'});}return fetch(url,options)};
 const next=await createClient(h.ports);t.after(()=>next.close());await tick();h.opened.at(-1).event('hello',{capabilities:['text','voice','audio']});await next.settle();
 assert.equal(next.state().outbox.length,0);assert.ok(captured.url.includes(`client_id=${id}`));assert.deepEqual(captured.options.body,{recordingFile:'recording-1'});
});
test('cancel dispatches no voice and old Macs retain saved audio without retries',async t=>{
 const {h,app}=await setup(t);await app.dispatch({type:'record-start'});await app.dispatch({type:'record-cancel'});
 assert.equal(h.requests.filter(x=>x.url.includes('kind=voice')).length,0);
 h.opened.at(-1).event('hello',{capabilities:['text']});await app.settle();
 await assert.rejects(app.dispatch({type:'record-send',id:'recording-1'}),/cannot accept voice/);
 assert.equal(app.state().recordings.length,1);assert.equal(app.state().outbox.length,0);
});
for (const action of ['playback-stop','record-play','record-start']) test(`${action} prevents a late download from starting audio`,async t=>{
 const {h,app}=await setup(t);let resolveAudio,plays=0;
 const native=h.ports.native;h.ports.native=async(method,args)=>{if(['playbackStop','recordPlay'].includes(method))return true;if(method==='replyPlay'){plays++;return true;}return native(method,args)};
 const fetch=h.ports.fetch;h.ports.fetch=async(url,options)=>url.includes('/api/audio/') ? new Promise(resolve=>{resolveAudio=()=>{const response=new Response('');response.nativeAudio='audio-file';resolve(response)}}) : fetch(url,options);
 await app.dispatch({type:'reply-play',id:'reply'});await tick();await app.dispatch({type:action,id:'recording-1'});
 if (action==='record-start') await app.dispatch({type:'record-stop'});
 resolveAudio();await tick();await app.settle();assert.equal(plays,0);
});
test('native voice hashing reads the saved audio file and sends no audio through JavaScript',async()=>{
 const {createPorts}=require('../platform/native.js');const calls=[];
 const ports=createPorts(async(method,args)=>{calls.push({method,args});return method==='recordHash'?'a'.repeat(64):{status:200,body:'',headers:{}}},()=>()=>{});
 const ref={recordingFile:'opaque-id'};assert.equal(await ports.hash(ref),'a'.repeat(64));
 await ports.fetch('https://mac.example/api/messages',{method:'POST',headers:{'Content-Type':'audio/wav'},body:ref});
 assert.deepEqual(calls[0],{method:'recordHash',args:{id:'opaque-id'}});assert.deepEqual(calls[1].args.body,ref);
});
for (const projectionFirst of [true,false]) test(`voice transcript replaces its placeholder with projection first=${projectionFirst}`,async t=>{
 const {h,app}=await setup(t),{createHash}=require('node:crypto');
 const originalHash=h.ports.hash;h.ports.hash=async value=>typeof value==='string'?createHash('sha256').update(value).digest('hex'):originalHash(value);
 const transcript='The blue notebook is on the kitchen table.', hash=await h.ports.hash(transcript);
 const fetch=h.ports.fetch;let acknowledge;
 h.ports.fetch=async(url,options)=>url.includes('kind=voice')?new Promise(resolve=>{acknowledge=()=>resolve(Response.json({message_id:'intake_1',cursor:1,thread_id:'general',accepted_at:'2026-09-22T00:00:00Z',text_sha256:hash}));}):fetch(url,options);
 await app.dispatch({type:'record-send',id:'recording-1'});
 for(let i=0;i<20 && !acknowledge;i++) await tick();
 assert(acknowledge);
 const project=()=>h.opened.at(-1).event('message',{id:'turn_voice:user',role:'ceo',cursor:2,text:transcript,complete:true});
 if(projectionFirst) {project();await tick();}
 acknowledge();await app.settle();
 if(!projectionFirst) project();
 await tick();await app.settle();
 assert.equal(app.state().outbox.length,0);
 assert.deepEqual(app.state().messages.map(row=>row.text),[transcript]);
});

test('Telegram gestures enqueue immediately on release and preserve a simultaneous typed draft',async t=>{
 const {h,app}=await setup(t);await app.dispatch({type:'record-delete',id:'recording-1'});
 await app.dispatch({type:'network',online:false});await app.dispatch({type:'compose',text:'Typed thought'});
 await app.dispatch({type:'voice-press'});assert.equal(app.state().voice.phase,'held');
 await app.dispatch({type:'voice-release'});
 assert.equal(app.state().outbox.length,1);assert.equal(app.state().messages[0].voice.seconds,2);
 assert.equal(app.state().draft,'Typed thought');assert.equal(app.state().recoveredRecordings.length,0);
 assert.equal(app.state().voice.phase,'idle');assert.equal(h.disk().outbox[0].fileId,'recording-1');
});
test('locked release keeps recording; an interruption retains an unsent in-conversation draft',async t=>{
 const {app}=await setup(t);await app.dispatch({type:'record-delete',id:'recording-1'});
 await app.dispatch({type:'voice-press'});await app.dispatch({type:'voice-move',dx:0,dy:-90});
 await app.dispatch({type:'voice-release'});assert.equal(app.state().voice.phase,'locked');assert.equal(app.state().outbox.length,0);
 await app.dispatch({type:'voice-interrupt'});assert.equal(app.state().outbox.length,0);assert.equal(app.state().recoveredRecordings.length,1);
 await app.dispatch({type:'voice-release'});assert.equal(app.state().outbox.length,0);
});
test('cancelled and accidentally interrupted gestures never submit voice',async t=>{
 const {app}=await setup(t);await app.dispatch({type:'record-delete',id:'recording-1'});
 await app.dispatch({type:'voice-press'});await app.dispatch({type:'voice-move',dx:-90,dy:0});await app.dispatch({type:'voice-release'});
 assert.equal(app.state().outbox.length,0);assert.equal(app.state().recordings.length,0);
});

test('a paired offline relaunch can record without waiting for another server hello',async t=>{
 const {h,app}=await setup(t);await app.dispatch({type:'network',online:false});app.close();
 const next=await createClient(h.ports);t.after(()=>next.close());assert.equal(next.state().canVoice,true);
 await next.dispatch({type:'voice-press'});await next.dispatch({type:'voice-move',dx:0,dy:-90});
 await next.dispatch({type:'voice-cancel'});assert.equal(next.state().outbox.length,0);
});
