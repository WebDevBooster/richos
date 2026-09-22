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
  const summary = ports.summary || (async path => {
    const { stdout } = await execute('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', path, '--format', 'json'], { timeout: 15000, maxBuffer: 1024 * 1024 });
    return JSON.parse(stdout);
  });
  const id = process.env.RICHOS_IOS_DEVICE;
  const team = process.env.RICHOS_APPLE_TEAM;
  if (!id || !/^[a-fA-F0-9-]{20,64}$/.test(id)) throw Error('Set RICHOS_IOS_DEVICE to the connected physical device identifier');
  if (!team || !/^[A-Z0-9]{10}$/.test(team)) throw Error('Set RICHOS_APPLE_TEAM to the signing team identifier');
  if (!['build', 'verify'].includes(command)) throw Error('device expects build or verify');
  const tests = { notifications: 'NativeClientTests/testNativeReplyNotification', voice: 'NativeClientTests/testSpokenVoiceSubmissionAndReply', updates: 'NativeClientTests/testIndependentUpdateService', all: 'NativeClientTests', text: 'NativeClientTests/testAuthenticatedTextAndStreamResume', recording: 'NativeClientTests/testNativeRecordingAndRelaunch' };
  if (!tests[selection]) throw Error('Device test selection must be all, text, recording, voice, notifications or updates');
  if (command === 'verify' && ['text','updates','all','voice','notifications'].includes(selection)) {
    const file = process.env.RICHOS_MOBILE_TEST_CONFIG;
    if (!file) throw Error('Set RICHOS_MOBILE_TEST_CONFIG to the prepared lab configuration before this physical test');
    const config = JSON.parse(readFileSync(file, 'utf8'));
    if (['text','all','voice','notifications'].includes(selection) && (typeof config.pairLink !== 'string' || !config.pairLink.startsWith('https://') || typeof config.words !== 'string')) throw Error('Physical text test requires an HTTPS pairLink and fingerprint words');
    if (selection === 'voice' && !config.spokenPhrase) throw Error('Physical voice proof requires the agreed spokenPhrase');
    if (selection === 'notifications' && config.notificationTest !== 'true') throw Error('Physical notification proof requires the live notification lab configuration');
    if (['updates','all'].includes(selection) && config.updateServiceTest !== 'true') throw Error('Physical update test requires the independent update lab configuration');
  }
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
  let verification;
  if (command === 'verify') {
    verification = await summary(result);
    const minimum = selection === 'all' ? 3 : 1;
    if (!Number.isInteger(verification.passedTests) || verification.passedTests < minimum
      || verification.failedTests !== 0 || verification.expectedFailures !== 0
      || (selection !== 'all' && (verification.skippedTests !== 0 || verification.totalTestCount !== 1))) {
      throw Error(`Device test was not proved: ${verification.passedTests || 0} passed, ${verification.skippedTests || 0} skipped, ${verification.failedTests || 0} failed. Read ${result}`);
    }
  }
  return { ...(verification ? { verification: { passed: verification.passedTests, skipped: verification.skippedTests, failed: verification.failedTests } } : {}), bundleId, app: join(cache, 'device-derived-data/Build/Products/Debug-iphoneos/RichOSMobile.app'), log, result };
}
