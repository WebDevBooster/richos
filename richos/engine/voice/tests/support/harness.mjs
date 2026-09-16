import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

let passed = 0;
const failures = [];
const pending = [];
const temporary = [];
export function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok  ${name}`);
  } catch (err) {
    failures.push({ name, err });
    console.log(`FAIL  ${name}\n      ${err.message}`);
  }
}
export function group(name) { console.log(`\n${name}`); }
export function testAsync(name, fn) { pending.push({ name, fn }); }
export function tmp() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-voice-test-'));
  temporary.push(dir);
  return dir;
}
export async function finish() {
  try {
    for (const { name, fn } of pending) {
      try {
        await fn();
        passed += 1;
        console.log(`  ok  ${name}`);
      } catch (err) {
        failures.push({ name, err });
        console.log(`FAIL  ${name}\n      ${err.message}`);
      }
    }
    if (passed + failures.length === 0) throw new Error('No tests executed');
    console.log(`\n${passed} passed, ${failures.length} failed`);
    for (const { name, err } of failures) console.error(`${name}: ${err.stack}`);
    if (failures.length) process.exitCode = 1;
  } finally {
    for (const dir of temporary) fs.rmSync(dir, { recursive: true, force: true });
  }
}
