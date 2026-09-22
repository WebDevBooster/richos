const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync, writeFileSync, rmSync } = require('node:fs');
const { join } = require('node:path');
const { createScratch } = require('./storage.cjs');

async function setup(t) {
  const { runDeviceProcess } = await import('../cli/device-runner.mjs');
  const folder = createScratch('device-runner');
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  return { runDeviceProcess, log: join(folder, 'child.log') };
}
test('device runner writes live diagnostics and checks host health before and after success', async t => {
  const { runDeviceProcess, log } = await setup(t);
  let checks = 0, observedLive = false;
  const result = await runDeviceProcess(process.execPath, ['-e', 'console.log("started"); const fs=require("node:fs"); const timer=setInterval(()=>{if(fs.existsSync(process.argv[1])){clearInterval(timer);console.log("finished");}},10)',log+'.continue'], {
    log, healthIntervalMs: 20, health: async () => {
      checks++;
      try { const text = readFileSync(log, 'utf8'); observedLive ||= text.includes('started') && !text.includes('finished');if(observedLive)writeFileSync(log+'.continue','continue'); } catch {}
    }
  });
  assert.equal(result.status, 0); assert(observedLive); assert(checks >= 3);
  assert.match(readFileSync(log, 'utf8'), /started\nfinished/);
});
test('device runner terminates its child on a host-health failure without retrying', async t => {
  const { runDeviceProcess, log } = await setup(t);
  let checks = 0;
  await assert.rejects(runDeviceProcess(process.execPath, ['-e', 'console.log("one launch"); setInterval(() => {}, 1000)'], {
    log, healthIntervalMs: 50, health: async () => { checks++;try{if(readFileSync(log,'utf8').includes('one launch'))throw Error('receiver disappeared');}catch(error){if(error.code!=='ENOENT')throw error;} }
  }), /receiver disappeared/);
  const text = readFileSync(log, 'utf8');
  assert.equal(text.match(/one launch/g).length, 1); assert.match(text, /Device test stopped: receiver disappeared/);
});
test('device runner bounds a hung test and preserves its diagnostics', async t => {
  const { runDeviceProcess, log } = await setup(t);
  await assert.rejects(runDeviceProcess(process.execPath, ['-e', 'console.log("hung stage"); setInterval(() => {}, 1000)'], {
    log, timeoutMs: 200
  }), /time limit/);
  assert.match(readFileSync(log, 'utf8'), /Device test stopped: Device test exceeded its time limit/);
});
test('device runner refuses to launch when its initial health check fails', async t => {
  const { runDeviceProcess, log } = await setup(t);
  await assert.rejects(runDeviceProcess('this-program-does-not-exist', [], {
    log, health: async () => { throw Error('preflight failed'); }
  }), /preflight failed/);
});

test('physical orchestration selects one test, detects a reset and never invokes a device reset', async t => {
  const { device } = await import('../cli/device.mjs');
  const folder = createScratch('device-orchestration');
  const names = ['RICHOS_MOBILE_CACHE', 'RICHOS_IOS_DEVICE', 'RICHOS_APPLE_TEAM', 'RICHOS_MOBILE_TEST_CONFIG'];
  const saved = Object.fromEntries(names.map(name => [name, process.env[name]]));
  Object.assign(process.env, { RICHOS_MOBILE_CACHE: folder, RICHOS_IOS_DEVICE: 'a'.repeat(40), RICHOS_APPLE_TEAM: 'TESTTEAM01' });
  t.after(() => { for (const name of names) saved[name] === undefined ? delete process.env[name] : process.env[name] = saved[name]; rmSync(folder, { recursive: true, force: true }); });
  process.env.RICHOS_MOBILE_TEST_CONFIG = join(folder, 'test.json');
  writeFileSync(process.env.RICHOS_MOBILE_TEST_CONFIG, JSON.stringify({ pairLink:'https://example.com/#pair=code',words:'synthetic words' }));
  let usb = ['receiver:1', 'hub:2'], calls = 0;
  const ports = { project: () => join(folder, 'project.xcodeproj'), usbSnapshot: async () => usb,
    run: async (bin, args, options) => {
      calls++; assert.equal(bin, 'xcodebuild');
      assert(args.includes('-only-testing:RichOSMobileUITests/NativeClientTests/testAuthenticatedTextAndStreamResume'));
      assert.equal(args[args.indexOf('-parallel-testing-enabled') + 1], 'NO');
      await options.health(); usb = ['receiver:1', 'hub:3']; await options.health();
    } };
  await assert.rejects(device('verify', 'text', ports), /USB device disappeared or reset/);
  assert.equal(calls, 1);
  await assert.rejects(device('verify', 'unknown', ports), /selection/);
  assert.equal(calls, 1);
  delete process.env.RICHOS_MOBILE_TEST_CONFIG;
  await assert.rejects(device('verify','text',ports), /RICHOS_MOBILE_TEST_CONFIG/);
  assert.equal(calls,1,'Missing configuration launched Xcode');
});


test('physical verification rejects an Xcode success with skipped or absent tests', async t => {
  const { device } = await import('../cli/device.mjs');
  const folder = createScratch('device-results');
  const names = ['RICHOS_MOBILE_CACHE','RICHOS_IOS_DEVICE','RICHOS_APPLE_TEAM','RICHOS_MOBILE_TEST_CONFIG'];
  const saved = Object.fromEntries(names.map(name=>[name,process.env[name]]));
  Object.assign(process.env,{RICHOS_MOBILE_CACHE:folder,RICHOS_IOS_DEVICE:'a'.repeat(40),RICHOS_APPLE_TEAM:'TESTTEAM01'});
  t.after(()=>{for(const name of names) saved[name]===undefined?delete process.env[name]:process.env[name]=saved[name];rmSync(folder,{recursive:true,force:true});});
  process.env.RICHOS_MOBILE_TEST_CONFIG=join(folder,'test.json');
  writeFileSync(process.env.RICHOS_MOBILE_TEST_CONFIG,JSON.stringify({pairLink:'https://example.com/#pair=code',words:'synthetic words'}));
  const ports={project:()=>join(folder,'test.xcodeproj'),usbSnapshot:async()=>[],run:async()=>({status:0})};
  for(const result of [
    {passedTests:0,skippedTests:1,failedTests:0,totalTestCount:1,expectedFailures:0},
    {passedTests:0,skippedTests:0,failedTests:0,totalTestCount:0,expectedFailures:0},
    {passedTests:1,skippedTests:0,failedTests:1,totalTestCount:2,expectedFailures:0},
  ]) await assert.rejects(device('verify','recording',{...ports,summary:async()=>result}),/not proved/);
  const result=await device('verify','recording',{...ports,summary:async()=>({passedTests:1,skippedTests:0,failedTests:0,totalTestCount:1,expectedFailures:0})});
  assert.deepEqual(result.verification,{passed:1,skipped:0,failed:0});
});


test('recording cleanup requires the disposable app and an explicit cleanup configuration', async t => {
  const {device}=await import('../cli/device.mjs');
  const folder=createScratch('device-cleanup');
  const names=['RICHOS_MOBILE_CACHE','RICHOS_IOS_DEVICE','RICHOS_APPLE_TEAM','RICHOS_MOBILE_TEST_CONFIG','RICHOS_MOBILE_TEST_APP'];
  const saved=Object.fromEntries(names.map(name=>[name,process.env[name]]));
  t.after(()=>{for(const name of names)saved[name]===undefined?delete process.env[name]:process.env[name]=saved[name];rmSync(folder,{recursive:true,force:true});});
  Object.assign(process.env,{RICHOS_MOBILE_CACHE:folder,RICHOS_IOS_DEVICE:'a'.repeat(40),RICHOS_APPLE_TEAM:'TESTTEAM01',RICHOS_MOBILE_TEST_CONFIG:join(folder,'test.json')});
  delete process.env.RICHOS_MOBILE_TEST_APP;
  let calls=0;
  const ports={project:()=>join(folder,'test.xcodeproj'),usbSnapshot:async()=>[],run:async()=>{calls++;return {status:0};},summary:async()=>({passedTests:1,skippedTests:0,failedTests:0,totalTestCount:1,expectedFailures:0})};
  writeFileSync(process.env.RICHOS_MOBILE_TEST_CONFIG,'{}');
  await assert.rejects(device('verify','cleanup',ports),/disposable integration app/);
  await assert.rejects(device('verify','preview',ports),/disposable integration app/);
  await assert.rejects(device('verify','reconnect',ports),/disposable integration app/);
  await assert.rejects(device('verify','notification-defaults',ports),/disposable integration app/);
  process.env.RICHOS_MOBILE_TEST_APP='integration';
  await assert.rejects(device('verify','cleanup',ports),/cleanupTestRecordings/);
  assert.equal(calls,0);
  writeFileSync(process.env.RICHOS_MOBILE_TEST_CONFIG,JSON.stringify({cleanupTestRecordings:'true'}));
  await device('verify','cleanup',ports);assert.equal(calls,1);
  delete process.env.RICHOS_MOBILE_TEST_CONFIG;
  await device('verify','preview',ports);assert.equal(calls,2,'Preview preserves the existing session without pairing or cleanup config');
  await device('verify','notification-defaults',ports);assert.equal(calls,3);
});
