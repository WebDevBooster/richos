/**
 * Stop a Chrome for Testing a harness spawned, and wait until it AND every process it started
 * have exited, before the caller removes the scratch folder under them.
 *
 * Why (nightly 44, 2026-10-07): the harness sent SIGTERM, slept 400 ms and removed its workdir.
 * SIGTERM only STARTS Chrome's shutdown; the browser then flushes Preferences,
 * TransportSecurity, the Reporting-and-NEL journal and the service-worker script cache into the
 * profile. On a busy Mac that took longer than the sleep, Chrome re-created files inside the
 * folder while fs.rmSync was emptying it, and a run whose every check had passed ended in
 * "ENOTEMPTY, Directory not empty" (exit 2). Measured under 60 one-core workers: the browser pid
 * exited 419-1283 ms after SIGTERM, and its helpers up to ~30 ms after the browser.
 *
 * Ownership: the processes waited for are the spawned browser and the descendants of its pid,
 * read from the process table while the browser is still alive (after it exits they reparent to
 * launchd and can no longer be told apart). That includes the native host Chrome launches and
 * the pipeline the host starts. Nothing is looked up by name, and no process but the browser
 * this module was handed ever receives a signal from it.
 */
import { execFileSync } from 'node:child_process';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const started = new Set();
const lingering = [];

/** Remember a spawned browser so stopAllChrome() can still stop it if a leg throws. */
export function trackChrome(child) {
  started.add(child);
  return child;
}

function descendantsOf(rootPid) {
  const rows = execFileSync('ps', ['-A', '-o', 'pid=,ppid=,comm='], { encoding: 'utf8' })
    .trim().split('\n').map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
    .map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), comm: m[3] }));
  const owned = new Set([rootPid]);
  for (let grew = true; grew;) {
    grew = false;
    for (const row of rows) if (owned.has(row.ppid) && !owned.has(row.pid)) { owned.add(row.pid); grew = true; }
  }
  return rows.filter((row) => row.pid !== rootPid && owned.has(row.pid));
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function exited(child) {
  return child.exitCode !== null || child.signalCode !== null;
}

/**
 * SIGTERM the browser, wait for its exit (SIGKILL after graceMs), then wait for every descendant
 * recorded before the signal to exit. Throws, naming them, if any is still running after settleMs:
 * the folder is then not safe to remove and the caller must not report a clean run.
 */
export async function stopChrome(child, { graceMs = 15000, settleMs = 10000 } = {}) {
  if (!child || !started.has(child)) return;
  started.delete(child);
  const owned = exited(child) ? [] : descendantsOf(child.pid);
  if (!exited(child)) {
    const gone = new Promise((resolve) => child.once('exit', resolve));
    child.kill('SIGTERM');
    const inTime = await Promise.race([gone.then(() => true), sleep(graceMs).then(() => false)]);
    if (!inTime) { child.kill('SIGKILL'); await gone; }
  }
  await settle(owned, settleMs);
}

async function settle(owned, settleMs) {
  const deadline = Date.now() + settleMs;
  while (owned.some((row) => alive(row.pid)) && Date.now() < deadline) await sleep(50);
  const left = owned.filter((row) => alive(row.pid));
  if (left.length) {
    lingering.push(...left);
    throw new Error(`Chrome's processes still running ${settleMs} ms after the browser exited: ${
      left.map((row) => `${row.pid} ${row.comm}`).join(', ')}`);
  }
}

/**
 * Stop every tracked browser that a leg left running (a leg that threw never reached its stop),
 * and wait once more for any process an earlier stop reported still running, so a failure caught
 * as non-fatal by a leg still blocks the folder's removal. Throws if anything is still running.
 */
export async function stopAllChrome(options = {}) {
  for (const child of [...started]) await stopChrome(child, options).catch(() => {});
  await settle(lingering.splice(0), options.settleMs ?? 10000);
}
