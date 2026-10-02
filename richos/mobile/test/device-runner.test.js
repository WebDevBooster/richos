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

test('the preserved app never goes on a physical iPhone: `mobile.mjs device` refuses before anything is built or installed', async () => {
  const { device } = await import('../cli/device.mjs');
  for (const [command, selection] of [['build', 'all'], ['verify', 'text'], ['verify', 'recording']]) {
    await assert.rejects(device(command, selection, { run: async () => { throw Error('xcodebuild must not run'); } }),
      /Retired: .*only through `richos\/mobile\/native-ios\/bin\/rios device/);
  }
});
