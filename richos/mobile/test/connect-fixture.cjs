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
  const pushes=[];let pushOutcome='sent';const apns={send:async(binding,job)=>{pushes.push({binding,job});return {outcome:pushOutcome}}};
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
  const send = request => handle(request,env,{store,provider,apns,now:()=>time});
  return { env,store,provider,identity,send,tunnels,dns,calls,pushes,pushOutcome:value=>{pushOutcome=value},fail:action=>{failure=action;},advance:ms=>{time+=ms;},reconcile:()=>reconcile(env,{store,provider,apns}) };
}


module.exports={database,fixture};
