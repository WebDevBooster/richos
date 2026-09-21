// A narrow native boundary. Business rules stay in core/client.js and the shared PWA modules.
(function (root, factory) {
  const value = factory();
  if (typeof module === 'object') module.exports = value;
  root.RichOSNative = value;
})(globalThis, function () {
  function sseParser(deliver) {
    let buffer = '', event = 'message', data = [];
    return chunk => {
      buffer += chunk;
      if (buffer.length > 262144) throw new Error('Event stream frame exceeds the limit');
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end).replace(/\r$/, ''); buffer = buffer.slice(end + 1);
        if (!line) { if (data.length) deliver(event, data.join('\n')); event = 'message'; data = []; }
        else if (line.startsWith('event:')) event = line.slice(6).replace(/^ /, '');
        else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
        if (data.reduce((n, x) => n + x.length, 0) > 262144) throw new Error('Event stream frame exceeds the limit');
      }
    };
  }
  function createPorts(call, subscribe) {
    class NativeEvents {
      constructor(url) {
        this.handlers = {}; this.readyState = 0; this.id = crypto.randomUUID();
        const decoder = new TextDecoder();
        const parse = sseParser((name, data) => (this.handlers[name] || []).forEach(fn => fn({ data })));
        this.unsubscribe = subscribe(event => {
          if (event.id !== this.id || this.readyState === 2) return;
          if (event.kind === 'stream-open') { this.readyState = 1; this.onopen?.(); }
          if (event.kind === 'stream-data') {
            try { parse(decoder.decode(Uint8Array.from(atob(event.data), c => c.charCodeAt(0)), { stream: true })); }
            catch { this.onerror?.(); this.close(); }
          }
          if (event.kind === 'stream-error') this.onerror?.();
        });
        call('streamOpen', { url, id: this.id }).catch(() => { if (this.readyState !== 2) this.onerror?.(); });
      }
      addEventListener(name, fn) { (this.handlers[name] ||= []).push(fn); }
      close() { this.readyState = 2; this.unsubscribe(); call('streamClose', { id: this.id }).catch(() => {}); }
    }
    return {
      native: call, EventSource: NativeEvents,
      fetch: async (url, options = {}) => {
        const result = await call('request', { url, method: options.method || 'GET', headers: options.headers || {}, body: options.body || '' });
        return new Response([204, 205, 304].includes(result.status) ? null : result.body, { status: result.status, headers: result.headers });
      },
      load: () => call('load', {}), save: value => call('save', { value }),
      hash: value => call('hash', { value: typeof value === 'string' ? value : new TextDecoder().decode(value) }),
      nextId: () => crypto.randomUUID()
    };
  }
  return { sseParser, createPorts };
});
