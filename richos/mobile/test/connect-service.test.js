const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');

function database(t) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  db.exec(readFileSync(join(__dirname, '../service/connect/schema.sql'), 'utf8'));
  return {
    prepare(sql) { return { bind(...args) { const query = db.prepare(sql); return {
      first: async () => query.get(...args) || null,
      all: async () => ({ results: query.all(...args) }),
      run: async () => ({ meta: { changes: Number(query.run(...args).changes) } }),
    }; } }; },
    async batch(statements) {
      db.exec('BEGIN IMMEDIATE');
      try { const rows=[]; for(const statement of statements) rows.push(await statement.run()); db.exec('COMMIT'); return rows; }
      catch(error) { db.exec('ROLLBACK'); throw error; }
    },
  };
}
async function fixture(t) {
  const { Store } = await import('../service/connect/store.mjs');
  const { handle, reconcile } = await import('../service/connect-worker.mjs');
  const { digest, encode, signingInput } = await import('../service/connect/auth.mjs');
  let time = 1790037000000;
  const db = database(t), store = new Store(db, () => time);
  const tunnels = new Map(), dns = new Map(), calls = [];
  let failure;
  const check = action => { calls.push(action); if(failure===action) { failure=null; throw Error('provider_unavailable'); } };
  const provider = {
    async createTunnel(host) { const key=host.id+':'+host.generation; if(!tunnels.has(key)) tunnels.set(key,{id:crypto.randomUUID()}); check('create'); return tunnels.get(key); },
    async configure() { check('configure'); },
    async dns(host) { if(!dns.has(host.hostname)) dns.set(host.hostname,{id:crypto.randomUUID()}); check('dns'); return dns.get(host.hostname); },
    async token(host) { check('token'); return 'scoped-token-for-'+host.id; },
    async remove(host) { check('remove'); tunnels.delete(host.id+':'+host.generation); dns.delete(host.hostname); },
  };
  const env = { DB: db, CF_API_TOKEN:'server-only-sentinel', CF_ACCOUNT_ID:'a'.repeat(32), CF_ZONE_ID:'b'.repeat(32),
    CONNECT_DOMAIN:'example.com', HOST_CAPACITY:'10', ENROLLMENT_OPEN:'true', REQUEST_LIMIT:{limit:async()=>({success:true})} };
  async function identity() {
    const keys = await crypto.subtle.generateKey({ name:'ECDSA',namedCurve:'P-256' }, true, ['sign','verify']);
    const point = await crypto.subtle.exportKey('raw',keys.publicKey), publicKey = encode(point);
    return {
      id:(await digest(point)).slice(0,32), publicKey,
      async request(method, path, body='', overrides={}) {
        const stamp = String(overrides.time || time), nonce = overrides.nonce || crypto.randomUUID().replaceAll('-','');
        const signature = encode(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,
          new TextEncoder().encode(await signingInput(stamp,nonce,method,path,body))));
        return new Request('https://connect.example.com'+path,{method,
          headers:{'x-richos-key':publicKey,'x-richos-time':stamp,'x-richos-nonce':nonce,'x-richos-signature':signature,'cf-connecting-ip':'192.0.2.1',...overrides.headers},
          ...(method==='GET'?{}:{body}) });
      },
    };
  }
  const send = request => handle(request,env,{store,provider,now:()=>time});
  return { env,store,provider,identity,send,tunnels,dns,calls,fail:action=>{failure=action;},advance:ms=>{time+=ms;},reconcile:()=>reconcile(env,{store,provider}) };
}

test('signed host enrolls once, retrieves only its token and cannot impersonate another host', async t => {
  const f=await fixture(t), a=await f.identity(), b=await f.identity();
  let response=await f.send(await a.request('POST','/v1/hosts'));
  assert.equal(response.status,200); const first=await response.json(); assert.equal(first.phase,'active');
  assert(!JSON.stringify(first).includes('token'));
  response=await f.send(await a.request('POST','/v1/hosts')); assert.equal(response.status,200);
  assert.equal(f.tunnels.size,1); assert.equal(f.dns.size,1);
  assert.equal((await f.send(await b.request('POST','/v1/host/token'))).status,404);
  const token=await (await f.send(await a.request('POST','/v1/host/token'))).json();
  assert.equal(token.token,'scoped-token-for-'+a.id); assert(!JSON.stringify(token).includes(f.env.CF_API_TOKEN));
  assert.equal((await f.send(await b.request('POST','/v1/hosts'))).status,200);
  const second=await (await f.send(await b.request('GET','/v1/host'))).json(); assert.notEqual(second.endpoint,first.endpoint);
});

test('service signatures bind method, path, body, timestamp and a single-use nonce', async t => {
  const f=await fixture(t), a=await f.identity();
  const enroll=await a.request('POST','/v1/hosts');
  assert.equal((await f.send(enroll.clone())).status,200);
  assert.equal((await f.send(enroll)).status,409);
  for(const mode of ['method','path','body','key','signature']) {
    const good=await a.request('POST','/v1/host/token');
    const headers=new Headers(good.headers);
    if(mode==='key') headers.set('x-richos-key',(await f.identity()).publicKey);
    if(mode==='signature') headers.set('x-richos-signature','a'.repeat(86));
    const bad=new Request('https://connect.example.com'+(mode==='path'?'/v1/hosts':'/v1/host/token'),{method:mode==='method'?'DELETE':'POST',headers,body:mode==='body'?'{}':''});
    assert.equal((await f.send(bad)).status,404,mode);
  }
  assert.equal((await f.send(await a.request('GET','/v1/host','',{time:1790036000000}))).status,404);
});

test('closed enrollment permits only operator-authorized public keys and capacity stays bounded', async t => {
  const f=await fixture(t), a=await f.identity(), b=await f.identity();
  f.env.ENROLLMENT_OPEN='false'; f.env.HOST_CAPACITY='1';
  assert.equal((await f.send(await a.request('POST','/v1/hosts'))).status,403);
  await f.store.statement('INSERT INTO allowed_hosts(id) VALUES(?)',a.id).run();
  assert.equal((await f.send(await a.request('POST','/v1/hosts'))).status,200);
  f.env.ENROLLMENT_OPEN='true';
  assert.equal((await f.send(await b.request('POST','/v1/hosts'))).status,403);
  assert.equal(f.tunnels.size,1);
});

for(const stage of ['create','configure','dns']) test(`provisioning recovers after lost ${stage} response without duplicate resources`, async t => {
  const f=await fixture(t), a=await f.identity(); f.fail(stage);
  assert.equal((await f.send(await a.request('POST','/v1/hosts'))).status,503);
  assert.equal((await f.store.get(a.id)).phase,'pending');
  await f.reconcile();
  assert.equal((await f.store.get(a.id)).phase,'active');
  assert.equal(f.tunnels.size,1); assert.equal(f.dns.size,1);
});

test('disable survives provider failure, denies tokens immediately and reconciles before reenabling', async t => {
  const f=await fixture(t), a=await f.identity();
  const old=await (await f.send(await a.request('POST','/v1/hosts'))).json();
  f.fail('remove'); assert.equal((await f.send(await a.request('DELETE','/v1/host'))).status,503);
  assert.equal((await f.send(await a.request('POST','/v1/host/token'))).status,410);
  await f.reconcile(); assert.equal(f.tunnels.size,0); assert.equal(f.dns.size,0);
  const next=await (await f.send(await a.request('POST','/v1/hosts'))).json();
  assert.equal(next.generation,2); assert.notEqual(next.endpoint,old.endpoint);
});

test('an expired lease cannot write or release its replacement', async t => {
  const f=await fixture(t), a=await f.identity();
  await f.send(await a.request('POST','/v1/hosts'));
  const old=await f.store.lease(a.id); assert(old);
  assert.equal(await f.store.lease(a.id),null);
  f.advance(120001); const next=await f.store.lease(a.id); assert(next);
  await assert.rejects(f.store.write(a.id,old,{desired:0}),/lease_lost/);
  await f.store.release(a.id,old); assert.equal((await f.store.get(a.id)).lease_id,next);
});

test('device registration is host-owned and generation-bound; disable clears it', async t => {
  const f=await fixture(t), a=await f.identity();
  await f.send(await a.request('POST','/v1/hosts'));
  assert.equal((await f.send(await a.request('PUT','/v1/host/device',JSON.stringify({generation:2,deviceKeyHash:'c'.repeat(64)})))).status,400);
  assert.equal((await f.send(await a.request('PUT','/v1/host/device',JSON.stringify({generation:1,deviceKeyHash:'c'.repeat(64)})))).status,200);
  assert.equal((await f.store.get(a.id)).device_key_hash,'c'.repeat(64));
  await f.send(await a.request('DELETE','/v1/host'));
  assert.equal((await f.store.get(a.id)).device_key_hash,null);
});

test('closed route surface, body limits and rate limits do not reach the provider', async t => {
  const f=await fixture(t);
  for(const path of ['/api/messages','/v1/host?auth=secret','/admin']) assert.equal((await f.send(new Request('https://connect.example.com'+path))).status,404);
  assert.equal((await f.send(new Request('http://connect.example.com/v1/hosts',{method:'POST'}))).status,400);
  assert.equal((await f.send(new Request('https://connect.example.com/v1/hosts',{method:'POST',body:'x'.repeat(9000)}))).status,413);
  f.env.REQUEST_LIMIT.limit=async()=>({success:false});
  assert.equal((await f.send(new Request('https://connect.example.com/v1/hosts',{method:'POST'}))).status,429);
  assert.equal(f.calls.length,0);
});

test('provider adapter fixes the loopback origin and refuses deletion of another DNS target', async () => {
  const { Provider }=await import('../service/connect/provider.mjs');
  const calls=[];
  const host={id:'a'.repeat(32),generation:1,tunnel_id:'owned',hostname:'c-owned.example.com'};
  let unrelated=false;
  const provider=new Provider({CF_API_TOKEN:'secret',CF_ACCOUNT_ID:'account',CF_ZONE_ID:'zone'},async (url,options)=>{
    calls.push({url,options});
    let result={id:'owned',name:'richos-'+host.id+'-g1'};
    if(url.includes('dns_records?')) result=[{id:'dns',type:'CNAME',content:unrelated?'someone-else.cfargotunnel.com':'owned.cfargotunnel.com'}];
    return Response.json({success:true,result});
  });
  await provider.configure(host);
  const config=JSON.parse(calls.find(call=>call.options.method==='PUT').options.body);
  assert.equal(config.config.ingress[0].service,'http://127.0.0.1:18443');
  assert.equal(config.config.ingress[1].service,'http_status:404');
  unrelated=true; await assert.rejects(provider.remove(host),/resource_conflict/);
  assert(!calls.some(call=>call.options.method==='DELETE'));
});

test('managed artifact preserves only server secrets and packages the tested service modules', async () => {
  const { managedArtifact } = await import('../cli/connect.mjs');
  const profile = { accountId:'a'.repeat(32),zoneId:'b'.repeat(32),databaseId:crypto.randomUUID(),domain:'example.com',capacity:10 };
  const artifact = managedArtifact(profile);
  assert.equal(artifact.metadata.main_module,'connect-worker.mjs');
  assert.deepEqual(artifact.metadata.keep_bindings,['secret_text']);
  assert.equal(artifact.metadata.bindings.find(row=>row.name==='ENROLLMENT_OPEN').text,'false');
  assert.equal(artifact.metadata.bindings.find(row=>row.name==='DB').id,profile.databaseId);
  assert.equal(artifact.modules.length,5);
  assert(artifact.modules.every(row=>/^[a-f0-9]{64}$/.test(row.sha256)));
  assert.throws(()=>managedArtifact({...profile,capacity:11}),/capacity/);
  assert.throws(()=>managedArtifact({...profile,domain:'https://example.com'}),/Invalid/);
});
