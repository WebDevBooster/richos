// Browser target for the existing PWA. Commands stay on disk, never on a network API.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, openSync, closeSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { cacheRoot } from './simulator.mjs';

const pause = () => new Promise((resolve) => setTimeout(resolve, 25));
export async function command(request) {
  const root = join(cacheRoot(), 'pwa');
  mkdirSync(root, { recursive: true });
  const statusFile = join(root, 'worker.json');
  let status = existsSync(statusFile) ? JSON.parse(readFileSync(statusFile, 'utf8')) : null;
  if (status) {
    try { process.kill(status.pid, 0); } catch { status = null; rmSync(statusFile, { force: true }); }
  }
  if (!status && request.command === 'stop') return { stopped: true };
  if (!status && request.command !== 'prepare') throw new Error('Run pwa prepare first');
  if (!status) {
    const log = openSync(join(root, 'worker.log'), 'w');
    const child = spawn(process.execPath, [fileURLToPath(new URL('./pwa-worker.mjs', import.meta.url)), root], {
      detached: true, stdio: ['ignore', log, log], env: process.env
    });
    closeSync(log);
    const started = performance.now();
    let failed;
    child.on('error', (error) => { failed = error; });
    child.on('exit', (code) => { failed = new Error(`Browser worker exited ${code}. See ${join(root, 'worker.log')}`); });
    child.unref();
    while (!existsSync(statusFile)) {
      if (failed) throw failed;
      if (performance.now() - started > 45000) {
        child.kill('SIGTERM');
        throw new Error(`Browser worker startup timed out. See ${join(root, 'worker.log')}`);
      }
      await pause();
    }
  }
  const token = randomUUID();
  const input = join(root, `${token}.request.json`);
  const output = join(root, `${token}.response.json`);
  writeFileSync(input + '.new', JSON.stringify(request));
  renameSync(input + '.new', input);
  const started = performance.now();
  try {
    while (!existsSync(output)) {
      if (performance.now() - started > 45000) throw new Error(`PWA command timed out; inspect state before repeating actions. See ${join(root, 'worker.log')}`);
      await pause();
    }
    const result = JSON.parse(readFileSync(output, 'utf8'));
    if (!result.ok) throw new Error(result.error);
    if (request.command === 'stop') {
      const stopping = performance.now();
      while (existsSync(statusFile)) {
        if (performance.now() - stopping > 10000) throw new Error('PWA worker did not finish shutting down');
        await pause();
      }
    }
    return result.result;
  } finally { rmSync(input, { force: true }); rmSync(output, { force: true }); }
}
