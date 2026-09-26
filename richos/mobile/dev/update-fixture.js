// Debug ports for the real client. Neither this data nor the install action ships in Release.
(function (root, factory) {
  const value = factory(); if (typeof module === 'object') module.exports = value;
  root.RichOSUpdateFixture = value;
})(globalThis, function () {
  // Stands in for the running app while a synthetic policy is installed, so it mirrors the shipped
  // version and build in release-config.json (this file also runs in the page, where that file
  // cannot be read synchronously). client-part2.test.js holds the fixture to that file, which is
  // the earlier iPhone app's own version and no other app's; the offered release is the next minor version.
  const client = { version: '1.0.0', build: '2', osVersion: '16.7.16', appId: '1234567890', storefront: 'GBR' };
  function policy(mode, revision = 1) {
    const now = Date.now();
    return { schema: 1, revision, issuedAt: new Date(now).toISOString(), expiresAt: new Date(now + 3600000).toISOString(),
      severity: mode, title: mode === 'blocking' ? 'Update required' : 'A new RichOS version is ready', message: 'Update to continue with the latest RichOS improvements.', allowDismiss: true, remindAfterSeconds: 60,
      minimum: { version: '1.1.0', build: '3' }, latest: { version: '1.1.0', build: '3', minimumOS: '16.7', appId: client.appId, storefronts: ['GBR'], verifiedAt: new Date(now).toISOString() } };
  }
  async function wrap(ports) {
    const original = ports.updates ? await ports.updates() : { client: { ...client, appId: null } };
    let current, signal;
    const info = async () => current ? client : original.client;
    return { ports: { ...ports, updates: async () => ({ ...original, client: await info(), clientInfo: info,
      fetchPolicy: async () => current || (original.fetchPolicy ? original.fetchPolicy() : Promise.reject(Error('Development policy not set'))),
      subscribe: async fn => { signal = fn; const source = await original.subscribe?.(fn); return { close() { signal = null; source?.close(); } }; } }) },
      async install(next, app) { current = next; await app.dispatch({ type: 'resume' }); signal?.(); await app.dispatch({ type: 'update-check' }); return app.state(); } };
  }
  return { wrap, policy, client };
});
