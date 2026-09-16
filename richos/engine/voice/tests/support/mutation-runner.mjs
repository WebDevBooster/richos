// Mutations run only in a disposable snapshot. No checkout/reset touches the caller.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

export function testNames(source) {
  return [...source.matchAll(/^test(?:Async)?\('((?:[^'\\]|\\.)*)'/gm)].map((m) => m[1].replace(/\\'/g, "'"));
}

export async function audit({ sources, mutations, suites, checks, list = false }) {
  if (!mutations.length || !checks.length || !suites.length) throw new Error('Empty mutation/check/suite inventory');
  if (new Set(checks).size !== checks.length) throw new Error('Duplicate audited check names');
  console.log(`${mutations.length} mutations over ${checks.length} checks`);
  if (list) {
    for (const m of mutations) console.log(`  ${m.label}`);
    return true;
  }
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-voice-mutations-'));
  const snapshot = path.join(temporary, 'snapshot');
  const trial = path.join(temporary, 'trial');
  let child;
  let interrupted = false;
  const interrupt = () => { interrupted = true; child?.kill('SIGTERM'); };
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', interrupt);
  const run = (suite) => new Promise((resolve, reject) => {
    if (interrupted) return reject(new Error('Mutation audit interrupted'));
    let output = '';
    child = spawn(process.execPath, suite.args, { cwd: path.join(trial, suite.cwd || '.'), stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (b) => { output += b; });
    child.stderr.on('data', (b) => { output += b; });
    const timer = setTimeout(() => child?.kill('SIGKILL'), 60000);
    child.on('error', (error) => { clearTimeout(timer); reject(error); });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      child = undefined;
      if (interrupted) return reject(new Error('Mutation audit interrupted'));
      const fails = [...output.matchAll(/^FAIL  (.+)$/gm)].map((m) => m[1]);
      const complete = /\d+ passed, \d+ failed/.test(output);
      resolve({ code, fails, crashed: Boolean(signal) || !complete || (code !== 0 && fails.length === 0), output });
    });
  });
  try {
    for (const { source, destination } of sources) {
      const dest = path.resolve(snapshot, destination);
      if (!dest.startsWith(snapshot + path.sep)) throw new Error('Snapshot destination escapes scratch');
      fs.cpSync(source, dest, { recursive: true, filter: (file) => !['.git', 'node_modules', 'target', '.DS_Store'].includes(path.basename(file)) });
    }
    const digest = crypto.createHash('sha256');
    function inventory(dir) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) inventory(file);
        else {
          digest.update(path.relative(snapshot, file) + '\0');
          digest.update(entry.isSymbolicLink() ? fs.readlinkSync(file) : fs.readFileSync(file));
        }
      }
    }
    inventory(snapshot);
    console.log(`Snapshot sha256: ${digest.digest('hex')}`);
    fs.cpSync(snapshot, trial, { recursive: true });
    for (const suite of suites) {
      const result = await run(suite);
      if (result.code !== 0 || result.crashed || result.fails.length) throw new Error(`Intact positive control failed:\n${result.output}`);
    }
    const killedBy = new Map();
    const problems = [];
    for (const m of mutations) {
      if (interrupted) throw new Error('Mutation audit interrupted');
      // The next mutation always starts from the frozen intact snapshot.
      fs.rmSync(trial, { recursive: true, force: true });
      fs.cpSync(snapshot, trial, { recursive: true });
      const file = path.resolve(trial, m.file);
      if (!file.startsWith(trial + path.sep) || !fs.realpathSync(file).startsWith(fs.realpathSync(trial) + path.sep)) throw new Error('Mutation target escapes scratch');
      const before = fs.readFileSync(file, 'utf8');
      if (!m.from || before.split(m.from).length !== 2) {
        problems.push(`DID NOT APPLY EXACTLY ONCE: ${m.label}`);
        continue;
      }
      fs.writeFileSync(file, before.replace(m.from, () => m.to));
      const fails = new Set();
      let crashed = false;
      for (const suite of suites) {
        const result = await run(suite);
        if (result.crashed) {
          crashed = true;
          console.error(result.output.slice(-1500));
        }
        for (const name of result.fails) fails.add(name);
      }
      if (crashed) problems.push(`CRASHED THE SUITE: ${m.label}`);
      else {
        const intended = [...fails].filter((name) => checks.includes(name));
        if (!intended.length) problems.push(`SURVIVED (no audited assertion failed): ${m.label}`);
        else {
          for (const name of intended) killedBy.set(name, m.label);
          console.log(`${intended.length} red  ${m.label}`);
        }
      }
    }
    for (const check of checks) if (!killedBy.has(check)) problems.push(`NEVER SEEN RED: ${check}`);
    console.log(`${killedBy.size}/${checks.length} audited checks observed RED`);
    for (const problem of problems) console.error(problem);
    return problems.length === 0;
  } finally {
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
