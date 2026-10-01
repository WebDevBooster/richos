// Physical native checks share the existing USB/process supervisor. The app is
// Release, normally paired and never receives fixture arguments or lab secrets.
//
// THE TEST PHONE KEEPS ITS APPS (CEO, 2026-10-01: the iPhone is dedicated to testing). The app and
// its XCUITest runner (dev.richos.connect.uitests.xctrunner) stay installed permanently: no tool
// uninstalls or wipes them, and their bytes change only when their committed source changed. So
// every committed source tree is built and signed ONCE, into a store shared by every checkout
// (RICHOS_PHYSICAL_STORE), and every later `build` or `verify` of the same tree reuses those exact
// signed bytes, checked by hash, instead of building and signing again in its own per-checkout
// cache. xcodebuild still hands the products to the phone at each session; with unchanged bytes
// that is an empty binary delta ("App installation will use binary delta information"), and the
// runner's identity on the phone does not change. Uncommitted source builds in the checkout's own
// cache as before and is never published.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runDeviceProcess } from '../../cli/device-runner.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const checks = {
  pairing: 'testPairAndDeliverAcrossHomeAndRelaunch',
  text: 'testDeliverAcrossHomeAndRelaunch',
  voice: 'testSpokenMessageReachesMacAndReturnsReply',
  notifications: 'testReplyNotificationAfterHomeAndTermination',
  quiet: 'testScrollAndQuietBackgroundReturn',
  recording: 'testActualMicrophonePreservesUnsentAudioAfterHomeAndTermination',
  // A walker's list of real-control steps (richos/app/scripts/qa/phone-ios.py).
  script: 'testScript',
};

export const DEFAULT_STORE = '/Volumes/E1TB/caches/richos-native-ios/physical-store';
const APP = 'Release-iphoneos/RichOSNative.app';
const RUNNER = 'Release-iphoneos/RichOSNativeUITests-Runner.app';

// A script may hold a timed background interval; its allowance is bounded, never open-ended.
export function allowanceSeconds(config) {
  const seconds = config?.allowanceSeconds === undefined ? 240 : Number(config.allowanceSeconds);
  if (!Number.isInteger(seconds) || seconds < 60 || seconds > 1800) throw Error('allowanceSeconds must be a whole number from 60 to 1800');
  return seconds;
}

export function configuration(env, command, selection) {
  if (!['build', 'verify'].includes(command)) throw Error('device build | device verify pairing|text|recording|quiet|voice|notifications|script');
  if (!/^[A-Fa-f0-9-]{20,64}$/.test(env.RICHOS_IOS_DEVICE || '')) throw Error('Set RICHOS_IOS_DEVICE to the connected physical UDID');
  if (!/^[A-Z0-9]{10}$/.test(env.RICHOS_APPLE_TEAM || '')) throw Error('Set RICHOS_APPLE_TEAM to the signing team');
  if (command === 'verify' && !checks[selection]) throw Error('Choose one named physical check');
  return { device: env.RICHOS_IOS_DEVICE, team: env.RICHOS_APPLE_TEAM, test: checks[selection] };
}

export function verifyPushEnvironment(configured, signed) {
  if (!['development', 'production'].includes(configured) || configured !== signed) {
    throw Error('APNs registration environment must match the signed aps-environment entitlement');
  }
}

// Only `verify` may reuse this checkout's own earlier products on request; `build` never does.
export function prebuilt(env, command) {
  return command === 'verify' && env.RICHOS_PHYSICAL_PREBUILT === '1';
}

// One store entry per (committed source tree, signing team, Xcode). Anything that changes the
// signed bytes is in the key; nothing else is, so the same tree in another checkout finds it.
export function storeKey({ tree, team, xcode }) {
  if (!/^[0-9a-f]{40,64}$/.test(tree || '')) throw Error('storeKey needs the git tree id of the native-ios sources');
  if (!team || !xcode) throw Error('storeKey needs the signing team and the Xcode version');
  return createHash('sha256').update(`${tree}\n${team}\n${xcode}`).digest('hex').slice(0, 24);
}

// Entries of native-ios that are not build inputs: tooling and prose beside the app. A change to
// them alone must not re-sign the app or put new runner bytes on the phone.
export const NOT_BUILD_INPUTS = ['Tools', 'docs', 'bin', 'README.md'];

// The identity of the build inputs: `git ls-tree` of native-ios without NOT_BUILD_INPUTS.
export function buildTree(lsTree) {
  const kept = lsTree.split('\n').filter(Boolean).filter(line => !NOT_BUILD_INPUTS.includes(line.split('\t')[1]));
  if (!kept.length) throw Error('buildTree: git ls-tree listed no build inputs');
  return createHash('sha256').update(kept.join('\n')).digest('hex');
}

// What one run does about its products, decided before anything is built or installed.
//   store    the committed tree was built before: reuse those exact signed bytes (no build, no signing)
//   checkout RICHOS_PHYSICAL_PREBUILT=1: this checkout's own earlier products (stamp checked by the caller)
//   publish  committed tree never built: build it once, then publish it to the store for everyone
//   local    uncommitted changes: build in this checkout's cache, never published
export function plan({ command, env, source, stored }) {
  if (prebuilt(env, command)) return 'checkout';
  if (source.dirty) return 'local';
  return stored ? 'store' : 'publish';
}

// The identity a store entry was published with, or null when there is none. A present entry whose
// bytes no longer hash to its identity is refused, never rebuilt over: identity or refuse.
export function stored(store, key, hash) {
  const entry = join(store, key);
  const file = join(entry, 'identity.json');
  if (!existsSync(file)) return null;
  const identity = JSON.parse(readFileSync(file, 'utf8'));
  const products = join(entry, 'Products');
  for (const [name, rel] of [['app', APP], ['runner', RUNNER]]) {
    const actual = hash(join(products, rel));
    if (actual !== identity[name]) {
      throw Error(`freshness mismatch: the stored ${name} ${join(products, rel)} hashes ${String(actual).slice(0, 12)}…, `
        + `published as ${String(identity[name]).slice(0, 12)}…. Refusing to install changed bytes under an unchanged source; `
        + `move ${entry} aside by hand to build that tree once more`);
    }
  }
  return { ...identity, products };
}

// Publish a finished build: copy into a private directory, then one rename. The first publisher of a
// key wins; a later one discards its copy and uses the winner's bytes, so every run of one tree
// installs the same signed runner.
export function publish(store, key, products, identity, deps) {
  const entry = join(store, key);
  if (existsSync(join(entry, 'identity.json'))) return stored(store, key, deps.hash);
  mkdirSync(store, { recursive: true });
  const staging = join(store, `.${key}.${process.pid}.${Date.now()}`);
  mkdirSync(staging);
  try {
    deps.copy(products, join(staging, 'Products'));
    const full = { ...identity, key, app: deps.hash(join(staging, 'Products', APP)),
      runner: deps.hash(join(staging, 'Products', RUNNER)), publishedAt: new Date().toISOString() };
    writeFileSync(join(staging, 'identity.json'), JSON.stringify(full, null, 1));
    // The perf.py stamp shape, so `phone-ios.py run --prebuilt --stamp` can name this entry too.
    writeFileSync(join(staging, 'stamp.json'), JSON.stringify({ artifact: join(entry, 'Products', APP), sha256: full.app,
      commit: identity.commit, dirty: false, paths: ['richos/mobile/native-ios'], stampedAt: full.publishedAt }, null, 1));
    try {
      renameSync(staging, entry);
    } catch (error) {
      if (!existsSync(join(entry, 'identity.json'))) throw error;
    }
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
  prune(store, key);
  return stored(store, key, deps.hash);
}

// The store stays bounded: past the newest KEEP entries, an entry untouched for a day is removed.
// A day-old entry is not one a running check is using, and removing it only means that tree would
// be built once more if it is ever checked out again.
export const KEEP = 8;
export function prune(store, keep, now = Date.now()) {
  const entries = readdirSync(store).filter(name => /^[0-9a-f]{24}$/.test(name))
    .map(name => ({ name, at: statSync(join(store, name, 'identity.json'), { throwIfNoEntry: false })?.mtimeMs ?? 0 }))
    .sort((a, b) => b.at - a.at);
  const removed = [];
  for (const entry of entries.slice(KEEP)) {
    if (entry.name === keep || now - entry.at < 86400000) continue;
    rmSync(join(store, entry.name), { recursive: true, force: true });
    removed.push(entry.name);
  }
  return removed;
}

// Products for this run, and how they were obtained. `deps` are the side effects (git, Xcode, the
// build itself, hashing, copying), injected so the decision is provable without a phone.
export async function resolveProducts({ command, env, team, derived, store }, deps) {
  const source = deps.source();
  const own = join(derived, 'Build/Products');
  if (prebuilt(env, command)) {
    if (!existsSync(join(own, APP))) throw Error('RICHOS_PHYSICAL_PREBUILT=1 but there is no earlier build to reuse; run once without it');
    return { mode: 'checkout', products: own };
  }
  const key = source.dirty ? null : storeKey({ tree: source.tree, team, xcode: deps.xcode() });
  const entry = key ? stored(store, key, deps.hash) : null;
  const mode = plan({ command, env, source, stored: entry });
  if (mode === 'store') return { mode, key, products: entry.products, identity: entry };
  await deps.build();
  if (mode === 'local') return { mode, products: own };
  const published = publish(store, key, own, { tree: source.tree, commit: source.commit, team, xcode: deps.xcode() }, deps);
  return { mode, key, products: published.products, identity: published };
}

function usb() {
  return execFileSync('ioreg', ['-p', 'IOUSB', '-w0'], { encoding: 'utf8', timeout: 5000 })
    .split('\n').filter(line => line.includes('<class IOUSBHostDevice,'))
    .map(line => line.match(/\+-o (.*?)\s+<class IOUSBHostDevice, id (.*?),/)?.slice(1).join(':')).filter(Boolean);
}

function git(...args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
}

const perf = resolve(root, '../perf');
const hashTree = path => existsSync(path)
  ? execFileSync('python3', ['-B', '-c', 'import sys; sys.path.insert(0, sys.argv[1]); import perfcore; print(perfcore.tree_sha256(sys.argv[2]))', perf, path], { encoding: 'utf8' }).trim()
  : 'absent';

export async function main(args, env = process.env) {
  const [command, selection] = args;
  const settings = configuration(env, command, selection);
  const cache = join(env.RICHOS_NATIVE_IOS_CACHE, 'physical');
  mkdirSync(cache, { recursive: true });
  if (!realpathSync(cache).startsWith('/Volumes/E1TB/')) throw Error('Physical cache must remain on the external SSD');
  const store = env.RICHOS_PHYSICAL_STORE || DEFAULT_STORE;
  if (!resolve(store).startsWith('/Volumes/E1TB/')) throw Error('RICHOS_PHYSICAL_STORE must be on /Volumes/E1TB');
  let config;
  if (command === 'verify') {
    const file = env.RICHOS_MOBILE_TEST_CONFIG;
    if (!file || !realpathSync(file).startsWith('/Volumes/E1TB/')) throw Error('Set RICHOS_MOBILE_TEST_CONFIG to the isolated external lab JSON');
    config = JSON.parse(readFileSync(file, 'utf8'));
    if (config.isolatedLab !== 'true') throw Error('The physical test configuration must explicitly mark isolatedLab: true (string)');
    if (selection === 'pairing' && (!config.pairLink?.startsWith('https://') || !config.words?.trim())) throw Error('Pairing needs a current HTTPS pairing link and exact fingerprint words');
    if (selection === 'voice' && !config.spokenPhrase?.trim()) throw Error('Voice requires a unique spokenPhrase expected from actual microphone capture');
    if (selection === 'notifications' && config.delayedReplies !== 'true') throw Error('Notifications require an isolated Mac configured to delay replies until after Home');
    if (selection === 'script' && (typeof config.steps !== 'string' || !config.steps.trim())) throw Error('A script check needs steps: a JSON list, as a string');
    config = Object.fromEntries(Object.entries(config).filter(([, value]) => typeof value === 'string'));
  }
  const native = resolve(root, '../../engine/scripts/lib/native-work.py');
  const stamp = Date.now();
  const log = join(cache, `${command}-${selection || 'app'}-${stamp}.log`);
  const result = join(cache, `${selection}-${stamp}.xcresult`);
  const derived = join(cache, 'derived');
  const baseline = usb();
  const health = async () => {
    const current = usb();
    if (baseline.some(device => !current.includes(device))) throw Error('USB device disappeared or reset; stopped without retry or USB reset');
  };
  let xcode;
  const resolved = await resolveProducts({ command, env, team: settings.team, derived, store }, {
    // --full-tree: from a subdirectory, ls-tree would otherwise filter the subtree by that
    // subdirectory's own path and list nothing.
    source: () => ({ tree: buildTree(git('ls-tree', '--full-tree', git('rev-parse', 'HEAD:./'))), commit: git('rev-parse', 'HEAD'),
      dirty: git('status', '--porcelain', '--', '.', ...NOT_BUILD_INPUTS.map(name => `:(exclude)${name}`)) !== '' }),
    xcode: () => (xcode ??= execFileSync('xcodebuild', ['-version'], { encoding: 'utf8', env }).trim().replace(/\s+/g, ' ')),
    hash: hashTree,
    copy: (from, to) => execFileSync('ditto', [from, to]),
    build: async () => {
      // The project is needed only to build; a reused build never regenerates it.
      const project = execFileSync(join(root, 'Release/generate.sh'), [join(cache, 'project')], { encoding: 'utf8', env }).trim();
      const base = ['-project', project, '-scheme', 'RichOSPhysical', '-configuration', 'Release',
        '-destination', `id=${settings.device}`, '-derivedDataPath', derived,
        `DEVELOPMENT_TEAM=${settings.team}`, 'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development',
        'RICHOS_APS_ENVIRONMENT=development', '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration'];
      const built = await runDeviceProcess('python3', ['-B', native, '--', 'xcodebuild', 'build-for-testing', ...base],
        { log, env, health, timeoutMs: 600000 });
      if (built.status !== 0) throw Error(`Device build failed: ${log}`);
    },
  });
  const products = resolved.products;
  const app = join(products, APP);
  const build = { mode: resolved.mode, key: resolved.key ?? null, products, commit: resolved.identity?.commit ?? null };
  const push = JSON.parse(execFileSync('python3', ['-c', `import json,plistlib,pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1]);info=plistlib.loads((p/'Info.plist').read_bytes())
signed=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(p)],stderr=subprocess.DEVNULL))
print(json.dumps([info.get('RichOSAPNsEnvironment'),signed.get('aps-environment')]))`, app], { encoding: 'utf8', env }));
  verifyPushEnvironment(...push);
  if (command === 'build') return { log, app, build };
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
  execFileSync('python3', ['-c', prepare, products, spec, settings.test], { input: JSON.stringify(config), env });
  const allowance = allowanceSeconds(config);
  try {
    const tested = await runDeviceProcess('python3', ['-B', native, '--', 'xcodebuild', 'test-without-building',
      '-xctestrun', spec, '-destination', `id=${settings.device}`, '-resultBundlePath', result,
      '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', String(allowance)],
    { log: log.replace('.log', '-test.log'), env, health, timeoutMs: (allowance + 60) * 1000 });
    if (tested.status !== 0) throw Error(`Physical check failed: ${result}. No retry attempted.`);
    const summary = JSON.parse(execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', result, '--format', 'json'], { encoding: 'utf8', env }));
    writeFileSync(result + '.summary.json', JSON.stringify(summary, null, 2));
    if (summary.passedTests !== 1 || summary.failedTests !== 0 || summary.skippedTests !== 0 || summary.totalTestCount !== 1) throw Error(`Selected physical check not proved: ${result}`);
    return { passed: 1, result, log, app, build };
  } finally { rmSync(spec, { force: true }); }
}

// Every device tool, for the never-uninstall test: none of them may remove an app from the phone.
export function deviceToolSources() {
  const tools = readdirSync(join(root, 'Tools')).filter(name => /\.(mjs|py|sh)$/.test(name) && !name.includes('.test.'));
  return [...tools.map(name => join(root, 'Tools', name)), join(root, 'bin/rios'),
    resolve(root, '../../app/scripts/qa/phone-ios.py'), resolve(root, '../cli/device-runner.mjs')];
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(result => console.log(JSON.stringify({ ok: true, result })))
    .catch(error => { console.error(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; });
}
