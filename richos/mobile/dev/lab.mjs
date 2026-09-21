// Isolated protocol test server. Never reads the user's Mac identity, ledger or pairing.
import http from 'node:http';
import https from 'node:https';
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { createStubMac } = require('../../web/web-app/test/stub-mac.js');
const { phraseFromHex } = require('../../web/web-app/lib/fingerprint.js');
export async function serve(cache) {
  const stub = createStubMac({ bindHost: '127.0.0.1', history: 0, capabilities: ['text'], pairCode: randomBytes(24).toString('base64url') });
  const tlsPort = await stub.listen(0);
  const proxy = http.createServer((request, response) => {
    const upstream = https.request({ hostname: '127.0.0.1', servername: 'localhost', port: tlsPort, path: request.url, method: request.method,
      headers: request.headers, ca: stub.caPem }, result => { response.writeHead(result.statusCode, result.headers); result.pipe(response); });
    upstream.on('error', error => { console.error('Lab upstream TLS failure:', error.code); response.writeHead(502); response.end(); });
    request.pipe(upstream); response.on('close', () => upstream.destroy());
  });
  await new Promise(resolve => proxy.listen(Number(process.env.RICHOS_LAB_PORT || 0), '127.0.0.1', resolve));
  const status = () => ({ pid: process.pid, port: proxy.address()?.port, fingerprintWords: phraseFromHex(stub.caFingerprintHex),
    pairingCode: stub.state.pairCode, pairedDevices: stub.state.devices.size, activeStreams: stub.state.streams.size,
    received: stub.received(), messages: stub.state.ledger });
  const save = () => writeFileSync(join(cache, 'lab.json'), JSON.stringify(status(), null, 2), { mode: 0o600 });
  save(); const timer = setInterval(save, 500);
  console.log(JSON.stringify({ ok: true, mode: 'lab', state: status() }));
  let finish; const finished = new Promise(resolve => { finish = resolve; });
  let stopped = false;
  const shutdown = async () => { if (stopped) return; stopped = true; clearInterval(timer); clearTimeout(expiry); proxy.closeAllConnections(); proxy.close(); await stub.close(); finish({ stopped: true }); };
  process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
  const expiry = setTimeout(shutdown, 60 * 60 * 1000);
  return await finished;
}
