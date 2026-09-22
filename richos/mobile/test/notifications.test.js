const test=require('node:test'),assert=require('node:assert/strict');
const {fixture}=require('./connect-fixture.cjs');
async function setup(t,route='connect') {
 const f=await fixture(t),id=await f.identity();
 Object.assign(f.env,{APNS_TEAM_ID:'A123456789',APNS_SANDBOX_KEY_ID:'B123456789',APNS_SANDBOX_KEY:'server-secret',APNS_TOPICS:'dev.richos.mobile.integration'});
 assert.equal((await f.send(await id.request('POST',route==='connect'?'/v1/hosts':'/v1/push/hosts'))).status,200);
 const deviceHash='a'.repeat(64),event={eventRef:'b'.repeat(64),threadRef:'c'.repeat(64),revision:1,deviceHash};
 if(route==='connect')assert.equal((await f.send(await id.request('PUT','/v1/host/device',JSON.stringify({generation:1,deviceKeyHash:deviceHash})))).status,200);
 const registration={revision:1,generation:1,deviceHash,token:'d'.repeat(64),topic:'dev.richos.mobile.integration',environment:'sandbox',route};
 const send=(path,data,method='POST')=>id.request(method,path,JSON.stringify(data)).then(f.send);
 assert.equal((await send('/v1/push/device',registration,'PUT')).status,200);
 return {...f,id,event,registration,sendRequest:f.send,send};
}
test('APNs jobs are authenticated, content-free, deduplicated and bound to the registered phone',async t=>{
 const f=await setup(t);
 assert.equal((await f.send('/v1/push/events',f.event)).status,202);assert.equal(f.pushes.length,1);
 assert.equal((await f.send('/v1/push/events',f.event)).status,202);assert.equal(f.pushes.length,1);
 assert.equal((await f.send('/v1/push/events',{...f.event,threadRef:'e'.repeat(64)})).status,409);
 assert.equal((await f.send('/v1/push/events',{...f.event,text:'private'})).status,400);
 assert.equal((await f.send('/v1/push/events',{...f.event,deviceHash:'e'.repeat(64)})).status,409);
 const other=await f.identity();assert.equal((await f.sendRequest(await other.request('POST','/v1/push/events',JSON.stringify(f.event)))).status,404);
});
test('token rotation and stale registration cannot deliver old queued notifications',async t=>{
 const f=await setup(t);f.pushOutcome('retry');
 assert.equal((await f.send('/v1/push/events',f.event)).status,202);
 assert.equal((await f.send('/v1/push/device',{...f.registration,revision:2,token:'e'.repeat(64)},'PUT')).status,200);
 assert.equal((await f.send('/v1/push/device',f.registration,'PUT')).status,409);
 f.advance(300000);await f.reconcile();assert.equal(f.pushes.length,1);
 assert.equal((await f.send('/v1/push/events',f.event)).status,409);
});
test('revocation and provider invalid-token responses delete tokens and pending work',async t=>{
 const f=await setup(t);f.pushOutcome('invalid');await f.send('/v1/push/events',f.event);
 assert.equal((await f.store.statement('SELECT token FROM push_bindings WHERE host_id=?',f.id.id).first()).token,null);
 assert.equal((await f.send('/v1/push/events',f.event)).status,409);
 assert.equal((await f.send('/v1/push/device',{...f.registration,revision:2},'PUT')).status,200);
 f.pushOutcome('retry');await f.send('/v1/push/events',{...f.event,revision:2});
 await f.sendRequest(await f.id.request('DELETE','/v1/host'));
 f.advance(300000);await f.reconcile();assert.equal(f.pushes.length,2);
 assert.equal((await f.store.statement('SELECT token FROM push_bindings WHERE host_id=?',f.id.id).first()).token,null);
});
test('notifications have bounded retry and one-hour retention',async t=>{
 const f=await setup(t);f.pushOutcome('retry');await f.send('/v1/push/events',f.event);
 for(let n=0;n<6;n++){f.advance(300000);await f.reconcile();}
 assert(f.pushes.length<=5);
 f.advance(3600000);await f.reconcile();assert.equal((await f.store.statement('SELECT count(*) AS n FROM push_jobs').first()).n,0);
});
test('Tailscale users can opt into hosted alerts without allocating a tunnel',async t=>{
 const f=await setup(t,'tailnet');assert.equal(f.tunnels.size,0);assert.equal(f.dns.size,0);
 await f.send('/v1/push/events',f.event);assert.equal(f.pushes.length,1);
 assert.equal((await f.send('/v1/push/device',{...f.registration,revision:2,environment:'production'},'PUT')).status,400);
 assert.equal((await f.send('/v1/push/device',{...f.registration,revision:2,topic:'unapproved'},'PUT')).status,400);
});
test('APNs signs only the chosen environment and sends a generic alert with opaque references',async()=>{
 const {APNs}=await import('../service/connect/apns.mjs');
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const key=Buffer.from(await crypto.subtle.exportKey('pkcs8',keys.privateKey)).toString('base64');let request;
 const env={APNS_TEAM_ID:'A123456789',APNS_SANDBOX_KEY_ID:'B123456789',APNS_SANDBOX_KEY:key,APNS_TOPICS:'dev.richos.mobile.integration'};
 const provider=new APNs(env,{now:()=>1790000000000,fetchImpl:async(url,options)=>{request={url,options};return new Response('',{status:200})}});
 assert.equal((await provider.send({host_id:'a'.repeat(32),token:'d'.repeat(64),environment:'sandbox',topic:env.APNS_TOPICS},{event_ref:'b'.repeat(64),thread_ref:'c'.repeat(64),expires_at:1790003600000})).outcome,'sent');
 assert.match(request.url,/^https:\/\/api.sandbox.push.apple.com\/3\/device\/[a-f0-9]+$/);
 const token=request.options.headers.authorization.slice(7),[header,payload,signature]=token.split('.');
 assert.equal(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},keys.publicKey,Buffer.from(signature,'base64url'),Buffer.from(header+'.'+payload)),true);
 assert.deepEqual(JSON.parse(Buffer.from(payload,'base64url')),{iss:env.APNS_TEAM_ID,iat:1790000000});
 assert.equal(JSON.parse(request.options.body).aps.alert.body,'Rich has replied.');
 assert.equal(request.options.redirect,'manual');assert.equal(request.options.headers['apns-topic'],env.APNS_TOPICS);
 assert(!request.options.body.includes('private'));assert(!request.options.body.includes(key));
});
test('default provider transport calls global fetch with its native receiver',async()=>{
 const {APNs}=await import('../service/connect/apns.mjs');const original=globalThis.fetch;
 try {
  globalThis.fetch=function(){assert.equal(this,globalThis,'Worker fetch must not receive the APNs adapter as its receiver');return Promise.resolve(Response.json({reason:'BadDeviceToken'},{status:400}));};
  const provider=new APNs({APNS_TEAM_ID:'A123456789',APNS_SANDBOX_KEY_ID:'B123456789',APNS_SANDBOX_KEY:'fixture',APNS_TOPICS:'dev.richos.mobile.integration'});provider.token=async()=> 'signed-fixture';
  const result=await provider.send({token:'a'.repeat(64),environment:'sandbox',topic:'dev.richos.mobile.integration'},{event_ref:'b'.repeat(64),expires_at:Date.now()+1000});assert.equal(result.outcome,'invalid');
 }finally{globalThis.fetch=original;}
});

test('provider retains only bounded ciphertext and refuses plaintext preview fields',async t=>{
 const f=await setup(t),preview={v:1,nonce:'a'.repeat(16),body:'b'.repeat(100)};
 assert.equal((await f.send('/v1/push/events',{...f.event,preview})).status,202);
 assert.equal(f.pushes.length,1);assert.equal(f.pushes[0].job.preview,JSON.stringify(preview));
 assert.equal((await f.send('/v1/push/events',{...f.event,preview:{...preview,body:'c'.repeat(100)}})).status,409);
 for(const invalid of [{text:'private'}, {...preview,body:'a'.repeat(1400)}, {...preview,nonce:'short'}, {...preview,v:2}]) {
  assert.equal((await f.send('/v1/push/events',{...f.event,preview:invalid})).status,400);
 }
});
