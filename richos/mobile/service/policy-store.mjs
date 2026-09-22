// Read side of the hosted update-policy store, shared by the Worker and the operator readback.
// SELECT statements only. (workerd accepts only handlers as main-module exports, so these
// constants live here rather than in policy-worker.mjs.)
import '../core/updates.js';

const { validate, compare, releaseCompare } = globalThis.RichOSUpdates;

// Each record targets exactly one app. A record without `target` is for the preserved iPhone app:
// every record published before targets existed, and the only kind its routes ever serve. The two
// native apps read their own routes, so a notice or feature switch meant for one of them can never
// reach the preserved app, whatever that app's code does with fields it does not know.
export const PRESERVED = 'ios-preserved';
export const TARGETS = Object.freeze([PRESERVED, 'ios-native', 'android-native']);
export const targetOf = policy => policy?.target === undefined ? PRESERVED : policy.target;

// Revisions are one global sequence across targets (the PUBLISH statement is unchanged), so each
// target's own revisions still only ever increase. The target is read from the stored, previewed
// and digested policy JSON itself, so the table needs no new column. Parameters: $.target path,
// the preserved default, the requested target.
export const LATEST = 'SELECT revision, policy FROM revisions ORDER BY revision DESC LIMIT 1';
export const TARGET_LATEST = 'SELECT revision, policy FROM revisions WHERE COALESCE(json_extract(policy, ?1), ?2) = ?3 ORDER BY revision DESC LIMIT 1';
const HEAD = 'SELECT revision FROM revisions ORDER BY revision DESC LIMIT 1';
const TARGET_HEAD = 'SELECT revision FROM revisions WHERE COALESCE(json_extract(policy, ?1), ?2) = ?3 ORDER BY revision DESC LIMIT 1';
export const scope = target => ['$.target', PRESERVED, target];

// Android releases name a Google Play package and version code instead of an App Store listing.
// Every rule that is not about the listing is the shared core rule, applied unchanged.
const ANDROID_APP = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
function androidRelease(release, issued) {
  if (!release || typeof release !== 'object' || 'appId' in release || 'storefronts' in release || !ANDROID_APP.test(release.packageName || '')) throw Error('Invalid verified Google Play release');
  compare(release.version, '0');
  if (typeof release.build !== 'string' || !/^[1-9]\d{0,9}$/.test(release.build) || Number(release.build) > 2100000000) throw Error('Invalid Android version code');
  if (!Number.isInteger(release.minimumSdk) || release.minimumSdk < 21 || release.minimumSdk > 99) throw Error('Invalid minimum Android API level');
  const verified = Date.parse(release.verifiedAt);
  if (!Number.isFinite(verified) || verified > issued || issued - verified > 86400000) throw Error('Release availability needs recent verification');
}
function validateAndroid(policy) {
  validate({ ...policy, severity: 'none', latest: undefined, minimum: undefined });
  if (!['none', 'banner', 'dialog', 'blocking'].includes(policy.severity)) throw Error('Invalid update prominence');
  if (policy.latest) androidRelease(policy.latest, Date.parse(policy.issuedAt));
  if (policy.severity !== 'none' && !policy.latest) throw Error('An update notice needs a verified replacement');
  if (policy.minimum) { compare(policy.minimum.version, '0'); compare(policy.minimum.build, '0');
    if (!policy.latest || releaseCompare(policy.minimum, policy.latest) > 0) throw Error('The verified replacement must satisfy the minimum version');
  }
  if (policy.latest && policy.blockedBuilds?.includes(`${policy.latest.version}+${policy.latest.build}`)) throw Error('The replacement build cannot also be blocked');
  return JSON.parse(JSON.stringify(policy));
}
// The single validation rule for every target, used by the Worker, the operator and the local store.
export function validateTargeted(policy) {
  if (!TARGETS.includes(targetOf(policy))) throw Error('Invalid update policy target');
  return targetOf(policy) === 'android-native' ? validateAndroid(policy) : validate(policy);
}

// Workers Free allows 50 D1 queries per invocation. One stream spends 1 + lifetime/poll = 36.
// The stream ends before the iPhone client's 120 s resource timeout and keeps bytes flowing
// inside its 15 s idle timeout; the client reconnects 15 s after a close and keeps a 60 s
// foreground fallback, so an ended stream never leaves a session stale.
export const STREAM = Object.freeze({ poll: 3000, keepalive: 12000, lifetime: 105000 });

// Without a target: the newest revision of any target (health only). With one: that target's.
export async function head(db, target) {
  const row = target === undefined ? await db.prepare(HEAD).first() : await db.prepare(TARGET_HEAD).bind(...scope(target)).first();
  return row?.revision || 0;
}
export async function latest(db, target = PRESERVED) {
  const row = await db.prepare(TARGET_LATEST).bind(...scope(target)).first();
  if (!row) return null;
  const policy = validateTargeted(JSON.parse(row.policy));
  // A mismatched row is refused rather than replaced by an older one: the client keeps its cache.
  if (policy.revision !== row.revision || targetOf(policy) !== target) throw Error('revision_mismatch');
  return policy;
}
