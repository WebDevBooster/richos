const test = require('node:test');
const assert = require('node:assert/strict');
test('connection diagnosis distinguishes phone, service, Mac, revocation and compatibility', async () => {
  const connection = require('../../web/web-app/lib/connection.js');
  assert(connection.managed('https://c-'+'a'.repeat(32)+'-g1.richos.ceo'));
  assert(!connection.managed('https://c-'+'a'.repeat(32)+'-g1.richos.ceo.attacker.example'));
  assert.equal(connection.classify({phoneOnline:false}),'phone-offline');
  assert.equal(connection.classify({serviceState:'unavailable'}),'service-unavailable');
  assert.equal(connection.classify({serviceState:'available'}),'mac-unreachable');
  assert.equal(connection.classify({serviceState:'unknown'}),'mac-unreachable');
  assert.equal(connection.classify({connected:true,revoked:true}),'revoked');
  assert.equal(connection.classify({connected:true,unsupported:true}),'incompatible');
  let fetched=false;
  assert.deepEqual(await connection.probe({online:()=>false,fetch:()=>{fetched=true;}}),{phoneOnline:false});
  assert(!fetched);
  assert.deepEqual(await connection.probe({fetch:async()=>Response.json({service:'richos-connect',ready:true})}),{serviceState:'available'});
  assert.deepEqual(await connection.probe({fetch:async()=>Response.json({ready:false},{status:503})}),{serviceState:'unavailable'});
  assert.deepEqual(await connection.probe({fetch:async()=>{throw Error('network');}}),{serviceState:'unknown'});
});
