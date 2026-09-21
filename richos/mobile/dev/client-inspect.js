// Included only in Debug simulator assets. Drives the actual client, not a fixture copy.
globalThis.RichOSClientInspect = (app, fixture) => {
  globalThis.RichOSDev = { execute: async request => {
    if (request.command === 'state') return { state: app.state() };
    if (request.command === 'action') return { state: await app.dispatch(request.action) };
    if (request.command === 'policy') return { state: await fixture.install(request.policy, app) };
    throw Error('Native client supports state, action and policy commands');
  } };
};
