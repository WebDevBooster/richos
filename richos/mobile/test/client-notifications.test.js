const test=require('node:test'),assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const {harness}=require('../dev/client-runtime.js'),{createClient}=require('../core/client.js');
const tick=()=>new Promise(r=>setImmediate(r));
async function setup(t) {
 const h=harness();let previews=true,permission='allowed',token='d'.repeat(64);const registrations=[];
 const native=h.ports.native,fetch=h.ports.fetch;
 h.ports.hash=async text=>createHash('sha256').update(text).digest('hex');
 h.ports.native=async(method,args)=>method==='pushPreview'?(previews=args.enabled):['pushInfo','pushRequest'].includes(method)?{permission,registration:permission==='allowed'?{token,topic:'dev.richos.mobile.integration',environment:'sandbox',previews,preview_key:'a'.repeat(43)}:undefined}:native(method,args);
 h.ports.fetch=async(url,options)=>{if(url.endsWith('/api/pair') && JSON.parse(options.body).native_push!==undefined){const registration=JSON.parse(options.body).native_push;registrations.push(registration);return Response.json({host_id:'a'.repeat(32),registered:!!registration});}return fetch(url,options)};
 const app=await createClient(h.ports);t.after(()=>app.close());
 await app.dispatch({type:'pair',link:'https://mac.example/#pair=code'});await app.dispatch({type:'confirm-pair',matched:true});await tick();
 h.opened.at(-1).event('hello',{capabilities:['text','native-push'],threads:[{id:'general',title:'General'},{id:'another',title:'Another'}]});await app.settle();
 const settle=async()=>{for(let i=0;i<8;i++){await tick();await app.settle();}};
 return {h,app,registrations,settle,permission:value=>{permission=value},token:value=>{token=value}};
}
test('notifications opt in explicitly, rotate tokens and unregister after permission denial',async t=>{
 const f=await setup(t);assert.equal(f.registrations.length,0);
 await f.app.dispatch({type:'notifications-enable'});await f.settle();assert.equal(f.app.state().notifications.status,'enabled');assert.equal(f.registrations.length,1);
 assert(!JSON.stringify(f.h.disk()).includes('d'.repeat(64)),'Token must not be saved in shared session JSON');
 f.token('e'.repeat(64));await f.app.dispatch({type:'notifications-refresh'});await f.settle();assert.equal(f.registrations.at(-1).token,'e'.repeat(64));
 f.permission('denied');await f.app.dispatch({type:'notifications-refresh'});await f.settle();assert.equal(f.registrations.at(-1),null);assert.equal(f.app.state().notifications.status,'denied');
 await f.app.dispatch({type:'compose',text:'Notifications are optional'});assert.equal(f.app.state().draft,'Notifications are optional');assert(f.app.state().canText);
});
test('a notification opens only an opaque thread reference belonging to the paired host and preserves drafts',async t=>{
 const f=await setup(t);await f.app.dispatch({type:'notifications-enable'});await f.settle();await f.app.dispatch({type:'compose',text:'Retain this draft'});
 const value={host:'b'.repeat(32),thread:await f.h.ports.hash('another'),event:'c'.repeat(64)};
 await f.app.dispatch({type:'notification-open',value});assert.equal(f.app.state().selectedThreadId,'general');
 await f.app.dispatch({type:'notification-open',value:{...value,host:'a'.repeat(32)}});await f.settle();assert.equal(f.app.state().selectedThreadId,'another');
 await f.app.dispatch({type:'select-thread',threadId:'general'});assert.equal(f.app.state().draft,'Retain this draft');
});
test('failed notification registration does not disable foreground text and keeps a retry action',async t=>{
 const f=await setup(t);const fetch=f.h.ports.fetch;f.h.ports.fetch=async(url,options)=>options.body?.includes('native_push')?Response.json({reason:'unreachable',retryable:true},{status:503}):fetch(url,options);
 await f.app.dispatch({type:'notifications-enable'});await f.settle();assert.equal(f.app.state().notifications.status,'service-unavailable');assert(f.app.state().canText);
});

test('preview preference defaults on, persists, updates registration and never stores the key in JS state',async t=>{
 const f=await setup(t);assert.equal(f.app.state().notifications.previews,true);
 await f.app.dispatch({type:'notifications-enable'});await f.settle();assert.equal(f.registrations.at(-1).previews,true);
 await f.app.dispatch({type:'notifications-previews',enabled:false});await f.settle();assert.equal(f.registrations.at(-1).previews,false);
 assert.equal(f.h.disk().push.previews,false);assert(!JSON.stringify(f.h.disk()).includes('a'.repeat(43)));
 await f.app.dispatch({type:'notifications-previews',enabled:true});await f.settle();assert.equal(f.registrations.at(-1).previews,true);
});

test('notification return focuses the referenced reply after it arrives',async t=>{
 const f=await setup(t);await f.app.dispatch({type:'notifications-enable'});await f.settle();
 const value={host:'a'.repeat(32),thread:await f.h.ports.hash('general'),event:await f.h.ports.hash('reply-42')};
 await f.app.dispatch({type:'notification-open',value});assert.equal(f.app.state().focusMessage,null);
 f.h.opened.at(-1).event('message',{id:'reply-42',text:'Your approval is needed',role:'rich',cursor:42,complete:true});await f.settle();
 assert.equal(f.app.state().focusMessage,'reply-42');
 await f.app.dispatch({type:'notification-focused',id:'reply-42'});assert.equal(f.app.state().focusMessage,null);
 f.h.opened.at(-1).event('message',{id:'reply-43',text:'Later reply',role:'rich',cursor:43,complete:true});await f.settle();assert.equal(f.app.state().focusMessage,null,'Later traffic must not refocus an already opened notification');
});
