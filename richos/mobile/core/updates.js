// Update decisions have no UI, network or Apple dependencies. All time is injected.
(function (root, factory) {
  const value = factory();
  if (typeof module === 'object') module.exports = value;
  root.RichOSUpdates = value;
})(globalThis, function () {
  const clone = value => JSON.parse(JSON.stringify(value));
  function version(value) {
    if (typeof value !== 'string' || !/^\d+(\.\d+){0,3}$/.test(value) || value.length > 40) throw Error('Invalid numeric version');
    const parts = value.split('.').map(Number);
    if (parts.some(n => !Number.isSafeInteger(n))) throw Error('Invalid numeric version');
    return parts;
  }
  function compare(a, b) {
    a = version(a); b = version(b);
    for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0) ? 1 : -1;
    return 0;
  }
  function releaseCompare(a, b) { return compare(a.version, b.version) || compare(a.build, b.build); }
  function validate(policy) {
    if (!policy || policy.schema !== 1 || !Number.isSafeInteger(policy.revision) || policy.revision < 1) throw Error('Invalid update policy revision');
    const issued = Date.parse(policy.issuedAt), expires = Date.parse(policy.expiresAt);
    if (!Number.isFinite(issued) || !Number.isFinite(expires) || expires <= issued || expires - issued > 86400000) throw Error('Policy lifetime must be at most 24 hours');
    if (!['none', 'banner', 'dialog', 'blocking'].includes(policy.severity)) throw Error('Invalid update prominence');
    for (const name of ['title', 'message']) if (typeof policy[name] !== 'string' || policy[name].length > (name === 'title' ? 100 : 1200)) throw Error('Invalid update copy');
    if (typeof policy.allowDismiss !== 'boolean' || !Number.isInteger(policy.remindAfterSeconds) || policy.remindAfterSeconds < 60 || policy.remindAfterSeconds > 604800) throw Error('Invalid update reminder');
    if (policy.latest) {
      const release = policy.latest;
      version(release.version); version(release.build); version(release.minimumOS);
      if (typeof release.appId !== 'string' || !/^\d{6,15}$/.test(release.appId) || !Array.isArray(release.storefronts) || !release.storefronts.length || release.storefronts.some(x => !/^[A-Z]{3}$/.test(x))) throw Error('Invalid verified App Store release');
      const verified = Date.parse(release.verifiedAt);
      if (!Number.isFinite(verified) || verified > issued || issued - verified > 86400000) throw Error('Release availability needs recent verification');
    }
    if (policy.severity !== 'none' && !policy.latest) throw Error('An update notice needs a verified replacement');
    if (policy.minimum) { version(policy.minimum.version); version(policy.minimum.build);
      if (!policy.latest || releaseCompare(policy.minimum, policy.latest) > 0) throw Error('The verified replacement must satisfy the minimum version');
    }
    if (policy.blockedBuilds && (!Array.isArray(policy.blockedBuilds) || policy.blockedBuilds.length > 100 || policy.blockedBuilds.some(x => typeof x !== 'string' || !/^\d+(\.\d+){0,3}\+\d+(\.\d+){0,3}$/.test(x)))) throw Error('Invalid blocked builds');
    if (policy.latest && policy.blockedBuilds?.includes(`${policy.latest.version}+${policy.latest.build}`)) throw Error('The replacement build cannot also be blocked');
    if (policy.features && (typeof policy.features !== 'object' || Array.isArray(policy.features) || Object.entries(policy.features).some(([k, v]) => !['text', 'recording'].includes(k) || typeof v !== 'boolean'))) throw Error('Invalid feature switches');
    return clone(policy);
  }
  function evaluate(policy, client, now, dismissal, busy = false) {
    const normal = { mode: 'none', blocked: false, features: { text: true, recording: true }, storeURL: null, expired: false };
    if (!policy) return normal;
    validate(policy);
    if (Date.parse(policy.issuedAt) > now + 300000 || Date.parse(policy.expiresAt) <= now) return { ...normal, expired: true };
    const result = { ...normal, features: { ...normal.features, ...policy.features }, revision: policy.revision, title: policy.title, message: policy.message };
    const latest = policy.latest;
    const available = latest && client.appId === latest.appId && latest.storefronts.includes(client.storefront) && compare(client.osVersion, latest.minimumOS) >= 0 && releaseCompare(client, latest) < 0;
    if (!available || policy.severity === 'none') return result;
    const affected = (policy.minimum && releaseCompare(client, policy.minimum) < 0) || policy.blockedBuilds?.includes(`${client.version}+${client.build}`);
    result.blocked = policy.severity === 'blocking' && !!affected;
    result.mode = result.blocked ? 'blocking' : policy.severity === 'blocking' ? 'dialog' : policy.severity;
    result.storeURL = `https://apps.apple.com/app/id${client.appId}`;
    result.dismissible = !result.blocked && policy.allowDismiss;
    if (!result.blocked && (busy || (result.dismissible && dismissal?.revision === policy.revision && dismissal.until > now))) result.mode = 'none';
    return result;
  }
  async function createController(ports) {
    const now = ports.now || Date.now;
    const setTimer = ports.setTimeout || setTimeout, clearTimer = ports.clearTimeout || clearTimeout;
    const cached = await ports.load() || {}, authority = ports.authority || 'unconfigured';
    let policy;
    try { if (cached.authority === authority && cached.policy) policy = validate(cached.policy); } catch { /* invalid cache has no authority */ }
    let dismissal = cached.authority === authority ? cached.dismissal : null, active = false, busy = false, running, timer, expiryTimer, source, generation = 0, retrySignal = false, error = null;
    const listeners = new Set();
    let reported;
    function state() { return { ...evaluate(policy, ports.client, now(), dismissal, busy), configured: !!ports.fetchPolicy, error, policyRevision: policy?.revision || 0 }; }
    function emit() { const s = state();
      const key = `${s.policyRevision}:${s.mode}`;
      if (reported !== key && s.mode !== 'none') Promise.resolve(ports.metric?.('policy-visible', s.policyRevision)).catch(() => {});
      reported = key; for (const fn of listeners) fn(s); }
    function scheduleExpiry() {
      clearTimer(expiryTimer);
      if (policy && active && Date.parse(policy.expiresAt) > now()) expiryTimer = setTimer(() => emit(), Date.parse(policy.expiresAt) - now() + 1);
    }
    let writes = Promise.resolve();
    function accept(next) {
      const result = writes.then(() => acceptOne(next));
      writes = result.catch(() => {}); return result;
    }
    async function acceptOne(next) {
      next = validate(next);
      if (next.revision <= (policy?.revision || 0)) return false;
      if (Date.parse(next.issuedAt) > now() + 300000 || Date.parse(next.expiresAt) <= now()) throw Error('Update policy is outside its validity period');
      await ports.save({ policy: next, dismissal, authority }); policy = next; error = null; scheduleExpiry(); emit(); return true;
    }
    async function refresh(signal = false) {
      if (!active || !ports.fetchPolicy) return;
      if (running) { retrySignal ||= signal; return running; }
      running = (async () => {
        try { await accept(await ports.fetchPolicy()); error = null; }
        catch { Promise.resolve(ports.metric?.('policy-failed', policy?.revision || 0)).catch(() => {}); error = 'Update checks are temporarily unavailable. Your saved work is safe.'; }
        finally { emit(); }
      })();
      try { await running; } finally {
        running = null;
        clearTimer(timer);
        if (active) {
          if (retrySignal) { retrySignal = false; void refresh(true); }
          else timer = setTimer(() => { void refresh(); }, 60000);
        }
      }
    }
    function stop() { active = false; generation++; clearTimer(timer); clearTimer(expiryTimer); source?.close(); source = null; }
    async function start() {
      if (active) { void refresh(true); return; }
      active = true; const mine = ++generation; scheduleExpiry();
      void refresh(true);
      if (ports.subscribe) {
        try {
          const opened = await ports.subscribe(() => { void refresh(true); });
          if (mine === generation && active) source = opened; else opened?.close();
        } catch { /* bounded refresh remains active if the signal channel is unavailable */ }
      }
    }
    return { state, accept, refresh, start, stop,
      setBusy(value) { if (busy !== value) { busy = value; emit(); } },
      setClient(value) { ports.client = value; emit(); },
      dismiss() {
        const result = writes.then(async () => {
          if (!state().dismissible || !policy) throw Error('This notice cannot be dismissed');
          const next = { revision: policy.revision, until: now() + policy.remindAfterSeconds * 1000 };
          await ports.save({ policy, dismissal: next, authority }); dismissal = next; emit();
        });
        writes = result.catch(() => {}); return result;
      },
      subscribe(fn) { listeners.add(fn); fn(state()); return () => listeners.delete(fn); }
    };
  }
  return { compare, releaseCompare, validate, evaluate, createController };
});
