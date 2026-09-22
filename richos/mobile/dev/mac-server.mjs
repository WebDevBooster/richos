// Launch the production Rust phone stack inside its test binary, with isolated state.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, readFileSync, writeFileSync, rmSync, mkdirSync, openSync, closeSync, copyFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
const require = createRequire(import.meta.url);
const { createScratch } = require('../test/storage.cjs');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function startMac(cache) {
  const origin = process.env.RICHOS_MOBILE_MAC_ORIGIN || 'https://localhost';
  if (new URL(origin).origin !== origin || !origin.startsWith('https://')) throw Error('Mac test origin must be an HTTPS origin');
  rmSync(join(cache, 'mac.json'), { force: true });
  const scratch = createScratch('rust-server');
  const data = join(scratch, 'data'); mkdirSync(data, { mode: 0o700 });
  const env = { ...process.env, TMPDIR: scratch + '/', RICHOS_MOBILE_MAC_DIR: data, RICHOS_MOBILE_MAC_ORIGIN: origin };
  const log = join(cache, 'mac-server.log');
  const fd = openSync(log, 'w', 0o600);
  let child, stopped, proxy, serving = false, binary;
  function killOwned(signal) {
    if (!child?.pid) return;
    try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  let closed = false;
  async function close() {
    if (closed) return; closed = true;
    proxy?.closeAllConnections(); proxy?.close();
    writeFileSync(join(data, 'stop'), 'stop');
    if (child && child.exitCode === null) {
      let timeout;
      const finished = await Promise.race([stopped.then(() => true), new Promise(resolve => { timeout = setTimeout(() => resolve(false), 5000); })]);
      clearTimeout(timeout);
      if (!finished) {
        killOwned('SIGTERM');
        const force = setTimeout(() => killOwned('SIGKILL'), 2000);
        try { await stopped; } finally { clearTimeout(force); }
      }
    }
    for (const name of ['timeline.json', 'ledger.jsonl', 'intake.jsonl']) {
      if (existsSync(join(data, name))) copyFileSync(join(data, name), join(cache, 'mac-' + name));
    }
    closeSync(fd); rmSync(scratch, { recursive: true, force: true });
    if (serving && child.exitCode !== 0) throw Error(`Rust server did not shut down cleanly. Read ${log}`);
  }
  try {
    const cargo = existsSync(join(process.env.HOME, '.cargo/bin/cargo')) ? join(process.env.HOME, '.cargo/bin/cargo') : 'cargo';
    child = spawn(cargo, ['test', '--manifest-path', join(root, 'app/src-tauri/Cargo.toml'), '--no-run', '--message-format=json'], { env, detached: true, stdio: ['ignore', 'pipe', fd] });
    stopped = once(child, 'close');
    let compiled = ''; child.stdout.on('data', chunk => { compiled += chunk; });
    let force;
    const timeout = setTimeout(() => { killOwned('SIGTERM'); force = setTimeout(() => killOwned('SIGKILL'), 2000); }, 300000);
    let code;
    try { [code] = await stopped; } finally { clearTimeout(timeout); clearTimeout(force); }
    writeFileSync(join(cache, 'mac-build.jsonl'), compiled);
    if (code !== 0) throw Error(`Rust server build failed. Read ${log} and mac-build.jsonl`);
    binary = compiled.split('\n').filter(Boolean).map(line => JSON.parse(line))
      .find(row => row.reason === 'compiler-artifact' && row.profile.test && row.target.name === 'richos-tauri' && row.executable)?.executable;
    if (!binary) throw Error('Cargo did not produce the Rust test executable');
    child = spawn(binary, ['mobile_mac_server::serve', '--exact', '--ignored', '--nocapture'], { env, detached: true, stdio: ['ignore', fd, fd] });
    stopped = once(child, 'close');
    const deadline = Date.now() + (process.env.RICHOS_MOBILE_VOICE_TEST === '1' ? 120000 : 20000);
    while (!existsSync(join(data, 'ready.json'))) {
      if (child.exitCode !== null || Date.now() > deadline) throw Error(`Rust server did not start. Read ${log}`);
      await pause(50);
    }
    serving = true;
    const state = JSON.parse(readFileSync(join(data, 'ready.json'), 'utf8'));
    const ca = readFileSync(state.ca);
    if (state.protocol !== "http") {
    proxy = http.createServer((request, response) => {
      const upstream = https.request({ hostname: '127.0.0.1', servername: 'localhost', port: state.port,
        path: request.url, method: request.method, headers: request.headers, ca }, result => {
        response.writeHead(result.statusCode, result.headers); response.flushHeaders(); result.pipe(response);
      });
      upstream.on('error', () => { if (!response.headersSent) response.writeHead(502); response.end(); });
      request.pipe(upstream); response.on('close', () => upstream.destroy());
    });
    await new Promise((resolve, reject) => { proxy.once('error', reject); proxy.listen(0, '127.0.0.1', resolve); });
    }
    const config = { pairLink: state.pairLink, words: state.words, replyMarker: state.replyMarker, serverRun: randomUUID() };
    writeFileSync(join(cache, 'mac-test-config.json'), JSON.stringify(config), { mode: 0o600 });
    const publicState = { ...state, port: proxy ? proxy.address().port : state.port, rustPort: state.port, origin, log, data };
    writeFileSync(join(cache, 'mac.json'), JSON.stringify(publicState, null, 2), { mode: 0o600 });
    async function restart() {
      if (closed || !serving) throw Error('Only the owned running Mac fixture can restart');
      child.kill('SIGKILL'); // One exact owned process. Its guard must notice the parent pipe closing.
      await stopped;
      rmSync(join(data,'ready.json'),{force:true});
      rmSync(join(data,'stop'),{force:true});
      child = spawn(binary, ['mobile_mac_server::serve','--exact','--ignored','--nocapture'], {
        env: {...env,RICHOS_MOBILE_MAC_RESTART:'1'}, detached:true, stdio:['ignore',fd,fd] });
      stopped = once(child,'close');
      const deadline = Date.now() + (process.env.RICHOS_MOBILE_VOICE_TEST === '1' ? 120000 : 20000);
      while (!existsSync(join(data,'ready.json'))) {
        if (child.exitCode !== null || Date.now() > deadline) throw Error(`Restart failed. Read ${log}`);
        await pause(50);
      }
      Object.assign(state,JSON.parse(readFileSync(join(data,'ready.json'),'utf8')));
      publicState.pid = state.pid; publicState.rustPort = state.port;
      writeFileSync(join(cache,'mac.json'),JSON.stringify(publicState),{mode:0o600});
      return publicState;
    }
    return { state: publicState, close, restart, get exited() { return stopped; } };
  } catch (error) { await close(); throw error; }
}
export async function serveMac(cache) {
  const server = await startMac(cache);
  console.log(JSON.stringify({ ok: true, mode: 'mac', state: server.state }));
  let timer, done;
  const requested = new Promise(resolve => {
    done = () => resolve('requested');
    timer = setTimeout(done, 55 * 60 * 1000);
    process.once('SIGINT', done); process.once('SIGTERM', done);
  });
  try {
    const reason = await Promise.race([requested, server.exited.then(() => 'exited')]);
    if (reason === 'exited') throw Error(`Rust server exited unexpectedly. Read ${server.state.log}`);
  } finally {
    clearTimeout(timer); process.off('SIGINT', done); process.off('SIGTERM', done);
    await server.close();
  }
  return { stopped: true };
}
