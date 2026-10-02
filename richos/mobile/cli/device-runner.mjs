import { spawn } from 'node:child_process';
import { openSync, closeSync, appendFileSync, existsSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Stream diagnostics immediately and supervise only the process group we created.
// A transport failure is final: never restart a test or reset host devices.
//
// `admission: true` is for a command run through engine/scripts/lib/native-work.py, which holds
// it until a worker, the compiler lane and CPU headroom are free. The time limit (`timeoutMs`)
// then starts when native-work ADMITS the command (it writes RICHOS_NATIVE_ADMITTED_FILE), never
// when it was queued. The wait is bounded by its own limit (`admissionMs`, 30 minutes, the
// same bound native-work puts on CPU headroom) and written to the log as "admitted after N s".
export const ADMISSION_LIMIT_MS = 1800000;
export async function runDeviceProcess(bin, args, { log, env = process.env, health,
  timeoutMs = 300000, healthIntervalMs = 1000, admission = false, admissionMs = ADMISSION_LIMIT_MS,
  admissionPollMs = 100 } = {}) {
  await health?.();
  const marker = admission ? join(tmpdir(), `richos-admitted-${process.pid}-${Date.now()}`) : null;
  if (marker) env = { ...env, RICHOS_NATIVE_ADMITTED_FILE: marker };
  // Truncate, then open for APPEND: the runner writes its own lines ("admitted after", "stopped")
  // into the same file the child writes to, and a shared plain offset made them overwrite each other.
  closeSync(openSync(log, 'w', 0o600));
  const fd = openSync(log, 'a', 0o600);
  let child;
  try { child = spawn(bin, args, { env, detached: true, stdio: ['ignore', fd, fd] }); }
  finally { closeSync(fd); }
  return await new Promise((resolve, reject) => {
    let failure, killing, checking = false, finished = false;
    const kill = signal => {
      if (!child.pid) return;
      try { process.kill(-child.pid, signal); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    const stop = error => {
      if (failure || finished) return;
      failure = error;
      appendFileSync(log, `\nDevice test stopped: ${error.message}\n`);
      kill('SIGTERM');
      killing = setTimeout(() => kill('SIGKILL'), 2000);
    };
    const interrupted = () => stop(Error('Device test interrupted'));
    process.on('SIGINT', interrupted); process.on('SIGTERM', interrupted);
    let timeout;
    const startClock = () => { timeout = setTimeout(() => stop(Error('Device test exceeded its time limit')), timeoutMs); };
    let admissionTimer, admissionWatch;
    if (marker) {
      const queuedAt = Date.now();
      admissionTimer = setTimeout(() => stop(Error(`Device test was not admitted within ${Math.round(admissionMs / 1000)} s (waiting for CPU, a worker or the build lane)`)), admissionMs);
      admissionWatch = setInterval(() => {
        if (!existsSync(marker)) return;
        clearInterval(admissionWatch); clearTimeout(admissionTimer);
        let waited = ((Date.now() - queuedAt) / 1000).toFixed(1);
        try { waited = readFileSync(marker, 'utf8').trim() || waited; } catch {}
        rmSync(marker, { force: true });
        if (finished || failure) return;
        appendFileSync(log, `\nDevice test admitted after ${waited} s; its time limit starts now\n`);
        startClock();
      }, admissionPollMs);
    } else startClock();
    const monitor = health && setInterval(async () => {
      if (checking || finished || failure) return;
      checking = true;
      try { await health(); } catch (error) { stop(error); }
      finally { checking = false; }
    }, healthIntervalMs);
    child.on('error', error => { failure ||= error; });
    child.on('close', async (status, signal) => {
      finished = true;
      clearTimeout(timeout); clearTimeout(killing); clearInterval(monitor);
      clearInterval(admissionWatch); clearTimeout(admissionTimer);
      if (marker) rmSync(marker, { force: true });
      process.off('SIGINT', interrupted); process.off('SIGTERM', interrupted);
      if (!failure && status === 0) {
        try { await health?.(); } catch (error) { failure = error; }
      }
      if (failure) reject(failure);
      else resolve({ status, signal });
    });
  });
}
