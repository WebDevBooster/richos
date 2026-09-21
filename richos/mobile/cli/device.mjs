import { project, cacheRoot, bundleId } from './simulator.mjs';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { runDeviceProcess } from './device-runner.mjs';
const execute = promisify(execFile);
async function usbSnapshot() {
  const { stdout } = await execute('ioreg', ['-p', 'IOUSB', '-w0'], { timeout: 5000 });
  return stdout.split('\n').filter(line => line.includes('<class IOUSBHostDevice,') && !line.includes('iPhone@'))
    .map(line => line.match(/\+-o (.*?)\s+<class IOUSBHostDevice, id (.*?),/)?.slice(1).join(':')).filter(Boolean);
}
export async function device(command, selection = 'all', ports = {}) {
  const snapshot = ports.usbSnapshot || usbSnapshot;
  const generate = ports.project || project;
  const run = ports.run || runDeviceProcess;
  const id = process.env.RICHOS_IOS_DEVICE;
  const team = process.env.RICHOS_APPLE_TEAM;
  if (!id || !/^[a-fA-F0-9-]{20,64}$/.test(id)) throw Error('Set RICHOS_IOS_DEVICE to the connected physical device identifier');
  if (!team || !/^[A-Z0-9]{10}$/.test(team)) throw Error('Set RICHOS_APPLE_TEAM to the signing team identifier');
  if (!['build', 'verify'].includes(command)) throw Error('device expects build or verify');
  const tests = { updates: 'NativeClientTests/testIndependentUpdateService', all: 'NativeClientTests', text: 'NativeClientTests/testAuthenticatedTextAndStreamResume', recording: 'NativeClientTests/testNativeRecordingAndRelaunch' };
  if (!tests[selection]) throw Error('Device test selection must be all, text, recording or updates');
  const cache = cacheRoot();
  const stamp = Date.now();
  const log = join(cache, `device-${command}-${stamp}.log`);
  const result = join(cache, `device-${command}-${stamp}.xcresult`);
  const extra = command === 'verify' ? [`-only-testing:RichOSMobileUITests/${tests[selection]}`, '-parallel-testing-enabled', 'NO'] : [];
  const baseline = command === 'verify' ? await snapshot() : [];
  const health = command === 'verify' ? async () => {
    const current = await snapshot();
    if (baseline.some(device => !current.includes(device))) throw Error('A host USB device disappeared or reset during the test; no retry or USB reset was attempted');
  } : undefined;
  const output = await run('xcodebuild', ['-project', generate(), '-scheme', 'RichOSMobile', '-configuration', 'Debug',
    '-sdk', 'iphoneos', '-destination', `platform=iOS,id=${id}`, '-destination-timeout', '30',
    '-derivedDataPath', join(cache, 'device-derived-data'), '-resultBundlePath', result,
    'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development', `DEVELOPMENT_TEAM=${team}`,
    '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', ...extra, command === 'verify' ? 'test' : 'build'],
    { log, health, env: { ...process.env, CLANG_MODULE_CACHE_PATH: join(cache, 'module-cache') } })
    .catch(error => { throw Error(`${error.message}. Read ${log}`); });
  if (output.status !== 0) throw Error(`Device ${command} failed. Read ${log}\n${readFileSync(log, 'utf8').slice(-1600)}`);
  return { bundleId, app: join(cache, 'device-derived-data/Build/Products/Debug-iphoneos/RichOSMobile.app'), log, result };
}
