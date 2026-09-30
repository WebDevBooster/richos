// hand-file.test.js — the drag's Desktop placement, run through the real JXA program with the
// platform boundaries (System Events, NSFileManager, CoreGraphics) replaced by stand-ins over a
// temporary directory. No guest, no Finder, no mouse event; nothing here touches a screen.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '..', 'hand-file.js'), 'utf8');

function drag(sourceBytes, desktopBytes) {
  const root = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'hand-file-test-'));
  try {
    const home = path.join(root, 'home');
    fs.mkdirSync(path.join(home, 'Desktop'), {recursive: true});
    const src = path.join(root, 'report.pdf');
    fs.writeFileSync(src, sourceBytes);
    const placed = path.join(home, 'Desktop', 'report.pdf');
    if (desktopBytes !== null) fs.writeFileSync(placed, desktopBytes);
    const fm = {
      fileExistsAtPath: p => fs.existsSync(p),
      contentsEqualAtPathAndPath: (a, b) => fs.readFileSync(a).equals(fs.readFileSync(b)),
      removeItemAtPathError: p => { fs.rmSync(p); return true; },
      copyItemAtPathToPathError: (a, b) => { fs.copyFileSync(a, b); return true; },
    };
    let events = 0;
    const icon = {position: () => [100, 100], size: () => [64, 64]};
    const proc = {unixId: () => 71};
    let front = 99;
    Object.defineProperty(proc, 'frontmost', {set: v => { front = v ? 71 : 99; }});
    const se = {processes: {
      whose: q => q.frontmost ? [{unixId: () => front}] : [proc],
      byName: () => ({scrollAreas: [{groups: [{images: {whose: () => [icon]}}]}]}),
    }};
    const context = {
      HAND_PARAMS: {mode: 'drag', path: src, pid: 71, tox: 500, toy: 400},
      Application: () => se,
      ObjC: {import: () => {}},
      delay: () => {},
      $: Object.assign(() => ({}), {
        NSFileManager: {defaultManager: fm},
        NSHomeDirectory: () => ({js: home}),
        CGEventCreateMouseEvent: () => { events++; return {}; },
        CGEventPost: () => {},
      }),
    };
    vm.createContext(context);
    vm.runInContext(source, context);
    const result = JSON.parse(vm.runInContext('run()', context));
    return {result, desktop: fs.readFileSync(placed), events};
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
}

// A stale copy under the same name is replaced by the requested bytes, and the result says so.
let r = drag('NEW requested bytes', 'OLD desktop bytes');
assert.equal(r.result.handed, 'drag');
assert.equal(r.desktop.toString(), 'NEW requested bytes', 'the drag must carry the requested file, not an older one');
assert.equal(r.result.placed, 'copied');
assert.ok(r.events > 0);

// An identical copy is reused, not needlessly replaced.
r = drag('same bytes', 'same bytes');
assert.equal(r.result.placed, 'reused');
assert.equal(r.desktop.toString(), 'same bytes');

// No copy yet: it is placed.
r = drag('fresh', null);
assert.equal(r.result.placed, 'copied');
assert.equal(r.desktop.toString(), 'fresh');

console.log('hand-file drag: stale same-name Desktop copy replaced, identical copy reused, absent copy placed');
