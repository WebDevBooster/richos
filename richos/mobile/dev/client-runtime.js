// Deterministic ports for the real client actions; excluded from shipped assets.
const { createClient } = require('../core/client.js');
function harness() {
  let disk, keyOrigin, recordings = [], recording = false;
  const opened = [], requests = [], signed = [];
  class Events {
    constructor(url) { this.url = url; this.handlers = {}; opened.push(this); }
    addEventListener(name, fn) { this.handlers[name] = fn; }
    close() { this.closed = true; }
    event(name, data) { this.handlers[name]?.({ data: JSON.stringify(data) }); }
  }
  const ports = {
    load: async () => structuredClone(disk), save: async data => { disk = structuredClone(data); },
    nextId: () => 'message-1', now: () => 1000, hash: async () => '0'.repeat(64), EventSource: Events,
    native: async (method, args) => {
      if (method === 'configure') { keyOrigin = args.origin; return true; }
      if (method === 'publicKey') return { kty: 'EC', crv: 'P-256', x: 'x', y: 'y' };
      if (method === 'sign') { signed.push(args.input); return 'signature'; }
      if (method === 'recordings') return recordings.slice();
      if (method === 'recordStart') { recording = true; return true; }
      if (method === 'recordStop') { if (recording) recordings.push({ id: 'recording-1', seconds: 2 }); recording = false; return true; }
      if (method === 'recordCancel') { recording = false; return true; }
      if (method === 'recordDelete') { recordings = recordings.filter(x => x.id !== args.id); return true; }
      throw Error(method);
    },
    fetch: async (url, options = {}) => {
      requests.push({ url, ...options });
      if (url.endsWith('/api/challenge')) return new Response('', { status: 404, headers: { 'X-RichOS-Challenge': 'fresh' } });
      if (url.endsWith('/api/pair')) {
        const body = JSON.parse(options.body);
        return Response.json(body.code ? { device_id: 'phone', challenge: 'pair-challenge', api_base: 'https://mac.example', ca_fingerprint_sha256: 'ab'.repeat(32), threads: [{ id: 'general', title: 'General' }] } : { ok: true });
      }
      if (url.endsWith('/api/messages')) return Response.json({ accepted: true, id: 'accepted' });
      return Response.json({ messages: [] });
    }
  };
  return { ports, opened, requests, signed, disk: () => disk, origin: () => keyOrigin };
}

async function scenario(name) {
  if (name === 'update-controls') {
    const fixture = require('./update-fixture.js'), environment = harness(); environment.ports.now = Date.now;
    const wrapped = await fixture.wrap(environment.ports), app = await createClient(wrapped.ports);
    try {
      const trace = [];
      for (const [index, mode] of ['banner', 'dialog', 'blocking', 'none'].entries()) {
        await wrapped.install(fixture.policy(mode, index + 1), app); trace.push({ mode, state: app.state() });
      }
      return { name, trace, state: app.state() };
    } finally { app.close(); }
  }
  if (!['connection-restart', 'recording-interruption','voice-restart','voice-gestures'].includes(name)) throw Error('Unknown client scenario');
  const environment = harness();
  let app = await createClient(environment.ports);
  const trace = [];
  async function action(value) { trace.push({ action: value.type, state: await app.dispatch(value) }); }
  try {
    if (name === 'recording-interruption') {
      await action({ type: 'record-start' }); await action({ type: 'suspend' });
      await action({ type: 'record-start' }); await action({ type: 'record-cancel' });
    } else {
      await action({ type: 'pair', link: 'https://mac.example/#pair=secret' });
      await action({ type: 'confirm-pair', matched: true });
      await new Promise(resolve => setImmediate(resolve));
      if(name==='voice-gestures') {
        environment.opened.at(-1).event('hello',{capabilities:['text','voice','audio']});await app.settle();
        await action({type:'network',online:false});
        await action({type:'voice-press'});await action({type:'voice-move',dx:0,dy:-90});await action({type:'voice-release'});
        if(app.state().voice.phase!=='locked' || app.state().outbox.length)throw Error('Locked release sent or stopped');
        await action({type:'voice-cancel'});
        await action({type:'voice-press'});await action({type:'voice-release'});
        if(app.state().outbox.length!==1)throw Error('Held release did not enqueue once');
        return {name,trace,state:app.state()};
      } else if(name==='voice-restart') {
        environment.opened.at(-1).event('hello',{capabilities:['text','voice','audio']});await app.settle();
        await action({type:'network',online:false});await action({type:'record-start'});await action({type:'record-stop'});
        await action({type:'record-send',id:'recording-1'});
        const fetch=environment.ports.fetch;environment.ports.fetch=async(url,options)=>url.includes('kind=voice')?Response.json({accepted:true,id:'accepted'}):fetch(url,options);
      } else {await action({ type: 'compose', text: 'Survives native client restart' }); await action({ type: 'send' });}
      app.close(); app = await createClient(environment.ports);
      await new Promise(resolve => setImmediate(resolve));
      trace.push({ action: 'relaunch', state: app.state() });
      environment.opened.at(-1).event('hello', { challenge: 'fresh', capabilities: name==='voice-restart'?['text','voice','audio']:['text'] });
      await app.settle(); trace.push({ action: 'server-hello', state: app.state() });
    }
    return { name, trace, state: app.state() };
  } finally { app.close(); }
}
module.exports = { harness, scenario };
