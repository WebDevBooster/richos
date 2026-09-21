import { spawn } from 'node:child_process';
import { openSync, closeSync, appendFileSync } from 'node:fs';

// Stream diagnostics immediately and supervise only the process group we created.
// A transport failure is final: never restart a test or reset host devices.
export async function runDeviceProcess(bin, args, { log, env = process.env, health,
  timeoutMs = 300000, healthIntervalMs = 1000 } = {}) {
  await health?.();
  const fd = openSync(log, 'w', 0o600);
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
    const timeout = setTimeout(() => stop(Error('Device test exceeded its time limit')), timeoutMs);
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
      process.off('SIGINT', interrupted); process.off('SIGTERM', interrupted);
      if (!failure && status === 0) {
        try { await health?.(); } catch (error) { failure = error; }
      }
      if (failure) reject(failure);
      else resolve({ status, signal });
    });
  });
}
