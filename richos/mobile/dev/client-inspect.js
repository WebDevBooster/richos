// Included only in Debug simulator assets. Drives the actual client, not a fixture copy.
globalThis.RichOSClientInspect = app => {
  globalThis.RichOSDev = { execute: async request => {
    if (request.command === 'state') return { state: app.state() };
    if (request.command === 'action') return { state: await app.dispatch(request.action) };
    throw Error('Native client supports state and action commands');
  } };
};
