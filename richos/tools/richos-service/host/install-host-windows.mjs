#!/usr/bin/env node
/** Register the native host for the current Windows user. No elevation or listening port. */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REGISTRY_KEY = 'HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.richos.host';

export function installWindowsHost({ extensionId, nodePath = process.execPath, hostPath = path.join(HERE, 'native-host.js'),
  installDir = path.join(process.env.LOCALAPPDATA || '', 'RichOS', 'native-host'), dropZone,
  platform = process.platform, registry = (args) => execFileSync('reg.exe', args, { stdio: ['ignore', 'pipe', 'pipe'] }) }) {
  if (platform !== 'win32') throw new Error('Run this installer on Windows');
  if (!/^[a-p]{32}$/.test(extensionId || '')) throw new Error('Expected the 32-character Chrome extension ID');
  if (!path.isAbsolute(installDir)) throw new Error('Expected an absolute installation directory');
  for (const value of [nodePath, hostPath, installDir, dropZone].filter(Boolean)) {
    if (!path.isAbsolute(value) || /[\r\n"%!]/.test(value)) throw new Error('Paths must be absolute and cannot contain quotes, percent signs, exclamation marks or newlines');
  }
  if (!fs.statSync(nodePath).isFile() || !fs.statSync(hostPath).isFile()) throw new Error('Node executable or native host entrypoint missing');
  fs.mkdirSync(installDir, { recursive: true });
  if (dropZone) fs.mkdirSync(dropZone, { recursive: true });
  const launcher = path.join(installDir, 'richos-host.cmd');
  const manifest = path.join(installDir, 'com.richos.host.json');
  const environment = dropZone ? `set "RICHOS_DROP_ZONE=${dropZone}"\r\n` : '';
  fs.writeFileSync(launcher, `@echo off\r\nsetlocal DisableDelayedExpansion\r\n${environment}"${nodePath}" "${hostPath}" %*\r\n`, 'utf8');
  fs.writeFileSync(manifest, JSON.stringify({ name: 'com.richos.host', description: 'RichOS call capture and local processing',
    path: launcher, type: 'stdio', allowed_origins: [`chrome-extension://${extensionId}/`] }, null, 2) + '\n');
  registry(['add', REGISTRY_KEY, '/ve', '/t', 'REG_SZ', '/d', manifest, '/f']);
  return { extensionId, manifest, launcher, nodePath, hostPath, dropZone: dropZone || 'service default' };
}
export function uninstallWindowsHost({ platform = process.platform, registry = args => execFileSync('reg.exe', args) } = {}) {
  if (platform !== 'win32') throw new Error('Run this installer on Windows');
  registry(['delete', REGISTRY_KEY, '/f']);
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.argv[2] === '--uninstall') uninstallWindowsHost();
    else {
      const [extensionId, dropZone] = process.argv.slice(2);
      console.log(JSON.stringify(installWindowsHost({ extensionId, dropZone }), null, 2));
    }
  } catch (err) { console.error(err.message); process.exitCode = 1; }
}
