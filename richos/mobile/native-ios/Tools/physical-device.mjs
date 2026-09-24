// Physical native checks share the existing USB/process supervisor. The app is
// Release, normally paired and never receives fixture arguments or lab secrets.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, realpathSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runDeviceProcess } from '../../cli/device-runner.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const checks = {
  pairing: 'testPairAndDeliverAcrossHomeAndRelaunch',
  text: 'testDeliverAcrossHomeAndRelaunch',
  quiet: 'testScrollAndQuietBackgroundReturn',
  recording: 'testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination',
};

export function configuration(env, command, selection) {
  if (!['build', 'verify'].includes(command)) throw Error('device build | device verify pairing|text|recording|quiet');
  if (!/^[A-Fa-f0-9-]{20,64}$/.test(env.RICHOS_IOS_DEVICE || '')) throw Error('Set RICHOS_IOS_DEVICE to the connected physical UDID');
  if (!/^[A-Z0-9]{10}$/.test(env.RICHOS_APPLE_TEAM || '')) throw Error('Set RICHOS_APPLE_TEAM to the signing team');
  if (command === 'verify' && !checks[selection]) throw Error('Choose one named physical check');
  return { device: env.RICHOS_IOS_DEVICE, team: env.RICHOS_APPLE_TEAM, test: checks[selection] };
}

function usb() {
  return execFileSync('ioreg', ['-p', 'IOUSB', '-w0'], { encoding: 'utf8', timeout: 5000 })
    .split('\n').filter(line => line.includes('<class IOUSBHostDevice,'))
    .map(line => line.match(/\+-o (.*?)\s+<class IOUSBHostDevice, id (.*?),/)?.slice(1).join(':')).filter(Boolean);
}

export async function main(args, env = process.env) {
  const [command, selection] = args;
  const settings = configuration(env, command, selection);
  const cache = join(env.RICHOS_NATIVE_IOS_CACHE, 'physical');
  mkdirSync(cache, { recursive: true });
  if (!realpathSync(cache).startsWith('/Volumes/E1TB/')) throw Error('Physical cache must remain on the external SSD');
  let config;
  if (command === 'verify') {
    const file = env.RICHOS_MOBILE_TEST_CONFIG;
    if (!file || !realpathSync(file).startsWith('/Volumes/E1TB/')) throw Error('Set RICHOS_MOBILE_TEST_CONFIG to the isolated external lab JSON');
    config = JSON.parse(readFileSync(file, 'utf8'));
    if (config.isolatedLab !== 'true') throw Error('The physical test configuration must explicitly mark isolatedLab: true (string)');
    if (selection === 'pairing' && (!config.pairLink?.startsWith('https://') || !config.words?.trim())) throw Error('Pairing needs a current HTTPS pairing link and exact fingerprint words');
    config = Object.fromEntries(Object.entries(config).filter(([, value]) => typeof value === 'string'));
  }
  const native = resolve(root, '../../engine/scripts/lib/native-work.py');
  const stamp = Date.now();
  const log = join(cache, `${command}-${selection || 'app'}-${stamp}.log`);
  const result = join(cache, `${selection}-${stamp}.xcresult`);
  const project = execFileSync(join(root, 'Release/generate.sh'), [join(cache, 'project')], { encoding: 'utf8', env }).trim();
  const derived = join(cache, 'derived');
  const baseline = usb();
  const health = async () => {
    const current = usb();
    if (baseline.some(device => !current.includes(device))) throw Error('USB device disappeared or reset; stopped without retry or USB reset');
  };
  const base = ['-project', project, '-scheme', 'RichOSPhysical', '-configuration', 'Release',
    '-destination', `id=${settings.device}`, '-derivedDataPath', derived,
    `DEVELOPMENT_TEAM=${settings.team}`, 'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development',
    'RICHOS_APS_ENVIRONMENT=development', '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration'];
  const built = await runDeviceProcess('python3', ['-B', native, '--', 'xcodebuild', 'build-for-testing', ...base],
    { log, env, health, timeoutMs: 600000 });
  if (built.status !== 0) throw Error(`Device build failed: ${log}`);
  if (command === 'build') return { log, app: join(derived, 'Build/Products/Release-iphoneos/RichOSNative.app') };
  const spec = join(cache, `physical-${stamp}.xctestrun`);
  // Rewrite only the runner's environment and paths. Private config is fed via stdin,
  // never process arguments, app launch arguments or a committed test resource.
  const prepare = `import sys,json,pathlib,plistlib
root=pathlib.Path(sys.argv[1]); files=list(root.glob('RichOSPhysical_iphoneos*.xctestrun'))
assert len(files)==1, 'Expected one physical test specification'
x=plistlib.loads(files[0].read_bytes());t=x['RichOSNativeUITests']
t['EnvironmentVariables']['RICHOS_PHYSICAL_CONFIG']=sys.stdin.read()
t['OnlyTestIdentifiers']=['PhysicalDeviceTests/'+sys.argv[3]]
for k in ['TestHostPath','UITargetAppPath']: t[k]=t[k].replace('__TESTROOT__',str(root))
t['DependentProductPaths']=[v.replace('__TESTROOT__',str(root)) for v in t.get('DependentProductPaths',[])]
p=pathlib.Path(sys.argv[2]);p.touch(mode=0o600,exist_ok=False);p.write_bytes(plistlib.dumps(x))`;
  execFileSync('python3', ['-c', prepare, join(derived, 'Build/Products'), spec, settings.test], { input: JSON.stringify(config), env });
  try {
    const tested = await runDeviceProcess('python3', ['-B', native, '--', 'xcodebuild', 'test-without-building',
      '-xctestrun', spec, '-destination', `id=${settings.device}`, '-resultBundlePath', result,
      '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '240'],
    { log: log.replace('.log', '-test.log'), env, health, timeoutMs: 300000 });
    if (tested.status !== 0) throw Error(`Physical check failed: ${result}. No retry attempted.`);
    const summary = JSON.parse(execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', result, '--format', 'json'], { encoding: 'utf8', env }));
    writeFileSync(result + '.summary.json', JSON.stringify(summary, null, 2));
    if (summary.passedTests !== 1 || summary.failedTests !== 0 || summary.skippedTests !== 0 || summary.totalTestCount !== 1) throw Error(`Selected physical check not proved: ${result}`);
    return { passed: 1, result, log, app: join(derived, 'Build/Products/Release-iphoneos/RichOSNative.app') };
  } finally { rmSync(spec, { force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(result => console.log(JSON.stringify({ ok: true, result })))
    .catch(error => { console.error(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; });
}
