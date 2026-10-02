import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { installWindowsHost, uninstallWindowsHost, REGISTRY_KEY } from '../host/install-host-windows.mjs';
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-windows-host-'));
try {
  const calls = [];
  const opts = { extensionId: 'abcdefghijklmnopabcdefghijklmnop', nodePath: process.execPath,
    hostPath: path.resolve('richos/tools/richos-service/host/native-host.js'), installDir: path.join(scratch, 'space in name'),
    dropZone: path.join(scratch, 'calls & evidence'), platform: 'win32', registry: args => calls.push(args) };
  const receipt = installWindowsHost(opts);
  const manifest = JSON.parse(fs.readFileSync(receipt.manifest, 'utf8'));
  assert.deepEqual(manifest.allowed_origins, [`chrome-extension://${opts.extensionId}/`]);
  assert.equal(manifest.path, receipt.launcher);
  const launcher = fs.readFileSync(receipt.launcher, 'utf8');
  assert.ok(launcher.includes(`"${opts.nodePath}" "${opts.hostPath}" %*`));
  assert.ok(launcher.includes(`set "RICHOS_DROP_ZONE=${opts.dropZone}"`));
  assert.deepEqual(calls[0], ['add', REGISTRY_KEY, '/ve', '/t', 'REG_SZ', '/d', receipt.manifest, '/f']);
  assert.throws(() => installWindowsHost({ ...opts, extensionId: '*' }));
  assert.throws(() => installWindowsHost({ ...opts, platform: 'darwin' }));
  assert.throws(() => installWindowsHost({ ...opts, dropZone: path.join(scratch, '%unsafe%') }));
  assert.throws(() => installWindowsHost({ ...opts, hostPath: path.join(scratch, 'missing') }));
  uninstallWindowsHost({ platform: 'win32', registry: args => calls.push(args) });
  assert.deepEqual(calls[1], ['delete', REGISTRY_KEY, '/f']);
  console.log('PASS Windows host files, quoting, exact extension origin, registry arguments and uninstall');
} finally { fs.rmSync(scratch, { recursive: true, force: true }); }
