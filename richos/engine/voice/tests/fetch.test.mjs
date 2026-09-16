import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { test, testAsync, group } from './support/harness.mjs';
import { GGML, fakeModel, pinOf, CAPTIVE_PORTAL } from './support/models.mjs';
import { FAILURE } from '../provisioning/model-integrity.js';
import { fetchVerified, downloadModel, modelStatus } from '../provisioning/model-fetch.js';

group('model fetch — driven against a real server, with real failures');

/**
 * A local HTTP server that answers the way the things that actually go wrong on the road answer.
 * Real sockets, real `fetch`, real files on disk: the failure paths are DRIVEN here rather than
 * simulated with a stubbed transport, because a stub only ever proves the stub.
 */
function scriptedServer(body, pin) {
  const seen = [];
  const server = http.createServer((req, res) => {
    seen.push({ url: req.url, range: req.headers.range || null });
    const p = new URL(req.url, 'http://x').pathname;
    const range = req.headers.range ? Number(/bytes=(\d+)-/.exec(req.headers.range)[1]) : null;
    // Half the bytes, then the socket goes away — with the headers and the partial body given
    // enough of a gap to actually reach the client, which is what makes this a mid-transfer
    // failure rather than a connection that was never established.
    const dieHalfway = (r) => {
      r.writeHead(200, { 'content-length': body.length });
      r.write(body.subarray(0, Math.floor(body.length / 2)));
      setTimeout(() => r.destroy(), 25);
    };
    const serve = (buf, honourRange = true) => {
      if (honourRange && range != null) {
        res.writeHead(206, {
          'content-range': `bytes ${range}-${buf.length - 1}/${buf.length}`,
          'content-length': buf.length - range,
        });
        return res.end(buf.subarray(range));
      }
      res.writeHead(200, { 'content-length': buf.length });
      return res.end(buf);
    };
    switch (p) {
      case `/good/${pin.file}`:
        return serve(body);
      case `/no-range/${pin.file}`:
        return serve(body, false); // answers a Range request with 200 and the whole file, again
      case `/captive/${pin.file}`:
        res.writeHead(200, { 'content-type': 'text/html', 'content-length': CAPTIVE_PORTAL.length });
        return res.end(CAPTIVE_PORTAL);
      case `/captive-padded/${pin.file}`: {
        // The nastiest shape: a portal that MITMs and pads its page to the EXACT pinned length, so
        // even Content-Length agrees and only the body gives it away.
        const padded = Buffer.concat([CAPTIVE_PORTAL, Buffer.alloc(body.length - CAPTIVE_PORTAL.length, 0x20)]);
        res.writeHead(200, { 'content-length': padded.length });
        return res.end(padded);
      }
      case `/wrong-content/${pin.file}`:
        // Exactly the right length. Starts with the GGML magic. Not the model.
        return serve(Buffer.concat([GGML, Buffer.alloc(body.length - 4, 0x42)]), false);
      case `/truncated/${pin.file}`:
        // Declares the full length, then stops halfway and hangs up — a train tunnel.
        return dieHalfway(res);
      case `/flaky/${pin.file}`: {
        // Dies halfway on the first attempt, then serves honestly (honouring Range) afterwards.
        const already = seen.filter((s) => s.url.includes('/flaky/')).length;
        return already === 1 ? dieHalfway(res) : serve(body);
      }
      case `/error-text/${pin.file}`: {
        // Declares a length, so the pin disagreement is visible before the body is transferred.
        const msg = Buffer.from('Internal Server Error: the object store is unavailable\n');
        res.writeHead(200, { 'content-type': 'text/plain', 'content-length': msg.length });
        return res.end(msg);
      }
      case `/slow/${pin.file}`: {
        // The same bytes, dribbled out in eight pieces with a gap between them, so a reader gets
        // many progress ticks spread over real time. A test that watches for a file appearing
        // mid-transfer needs the transfer to HAVE a middle.
        res.writeHead(200, { 'content-length': body.length });
        const piece = Math.ceil(body.length / 8);
        let sent = 0;
        const tick = () => {
          if (sent >= body.length) return res.end();
          res.write(body.subarray(sent, sent + piece));
          sent += piece;
          return setTimeout(tick, 5);
        };
        return tick();
      }
      case `/short-clean/${pin.file}`:
        // No declared length, half the bytes, then a clean end() — a proxy that truncated a
        // chunked stream. The transfer SUCCEEDS as far as the socket is concerned, so this is the
        // only route by which a short file reaches the post-transfer checks.
        res.writeHead(200, {});
        return res.end(body.subarray(0, Math.floor(body.length / 2)));
      case `/error-text-chunked/${pin.file}`:
        // The same error with NO declared length, so only reading the body can name it.
        res.writeHead(200, { 'content-type': 'text/plain' });
        return res.end('Internal Server Error: the object store is unavailable\n');
      case `/busy/${pin.file}`:
        res.writeHead(503);
        return res.end('busy');
      default:
        res.writeHead(404);
        return res.end('no');
    }
  });
  return { server, seen };
}

async function withServer(fn) {
  const body = fakeModel('e2e');
  const pin = pinOf(body);
  const { server, seen } = scriptedServer(body, pin);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-fetch-'));
  const dest = path.join(dir, pin.file);
  try {
    return await fn({ base, dir, dest, pin, body, seen });
  } finally {
    server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

testAsync('an honest download verifies, installs, and leaves no .part behind', () =>
  withServer(async ({ base, dest, pin }) => {
    const r = await fetchVerified({ url: `${base}/good/${pin.file}`, dest, pin });
    assert.equal(r.ok, true, r.message);
    assert.equal(r.status, 'downloaded');
    assert.equal(r.sha256, pin.sha256);
    assert.ok(fs.existsSync(dest));
    assert.ok(!fs.existsSync(`${dest}.part`), 'the .part must not survive a successful install');
  }));

testAsync('a captive portal is caught BY NAME, and nothing is installed', () =>
  withServer(async ({ base, dest, pin }) => {
    const r = await fetchVerified({ url: `${base}/captive/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.HTML_BODY, `got ${r.kind}: ${r.message}`);
    assert.match(r.message, /came back as a web page, not a model/);
    assert.match(r.message, /Sign in to the network/);
    assert.ok(!fs.existsSync(dest) && !fs.existsSync(`${dest}.part`), 'a login page must leave nothing on disk');
  }));

testAsync('a portal that pads its page to the EXACT pinned length is still caught by name', () =>
  withServer(async ({ base, dest, pin }) => {
    // Content-Length agrees with the pin here, so the cheap pre-check cannot help. Only reading the
    // first bytes of the body can — and it must still produce the portal sentence rather than a
    // hash mismatch, because "you are behind a login page" is the one somebody can act on.
    const r = await fetchVerified({ url: `${base}/captive-padded/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.HTML_BODY, `got ${r.kind}: ${r.message}`);
    assert.ok(!fs.existsSync(dest) && !fs.existsSync(`${dest}.part`));
  }));

testAsync('a right-size, right-magic, WRONG-CONTENT body is caught by the hash and deleted', () =>
  withServer(async ({ base, dest, pin }) => {
    const r = await fetchVerified({ url: `${base}/wrong-content/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.HASH_MISMATCH, `got ${r.kind}: ${r.message}`);
    assert.equal(r.retryable, false, 'a corrupted download is never retried in a loop');
    assert.match(r.message, /has been deleted and nothing was installed/);
    assert.ok(!fs.existsSync(dest), 'never installed');
    assert.ok(!fs.existsSync(`${dest}.part`), 'DISCARDED, not quarantined — nothing is left for anything to read');
  }));

testAsync('a truncated transfer keeps its prefix, says so, and is retryable', () =>
  withServer(async ({ base, dest, pin, body }) => {
    const r = await fetchVerified({ url: `${base}/truncated/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.retryable, true);
    assert.match(r.message, /resumes from where it stopped|stopped after/);
    assert.ok(!fs.existsSync(dest), "a truncated file never gets a model's name");
    const kept = fs.statSync(`${dest}.part`).size;
    assert.ok(kept > 0 && kept < body.length, `kept ${kept} of ${body.length}`);
  }));

testAsync('a body that ends cleanly but short keeps its prefix for the resume', () =>
  withServer(async ({ base, dest, pin, body }) => {
    // Distinct from the socket dying: here the transfer completes and only the post-transfer size
    // check catches it, which is the branch that decides whether the prefix is worth keeping.
    const r = await fetchVerified({ url: `${base}/short-clean/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.SHORT, `got ${r.kind}: ${r.message}`);
    assert.equal(r.retryable, true);
    assert.match(r.message, /resumes from where it stopped/);
    assert.ok(!fs.existsSync(dest));
    assert.equal(fs.statSync(`${dest}.part`).size, Math.floor(body.length / 2), 'the prefix must be kept');
  }));

testAsync('a flaky connection resumes from the kept prefix rather than starting over', () =>
  withServer(async ({ base, dir, dest, pin, body, seen }) => {
    const r = await downloadModel(pin, dir, { baseUrl: `${base}/flaky`, maxAttempts: 3 });
    assert.equal(r.ok, true, r.message);
    assert.equal(r.status, 'resumed', 'the second attempt must resume, not restart');
    assert.ok(r.resumedFrom > 0, `resumed from ${r.resumedFrom}`);
    assert.deepEqual(fs.readFileSync(dest), body, 'a resumed file is byte-identical to a fresh one');
    assert.equal(seen.filter((s) => s.url.includes('/flaky/') && s.range).length, 1, 'exactly one request carried a Range');
  }));

testAsync('a server that ignores Range does not get its body appended onto the partial', () =>
  withServer(async ({ base, dest, pin, body }) => {
    fs.writeFileSync(`${dest}.part`, body.subarray(0, 2000));
    const r = await fetchVerified({ url: `${base}/no-range/${pin.file}`, dest, pin });
    assert.equal(r.ok, true, r.message);
    assert.equal(r.status, 'downloaded', 'it restarted rather than resuming');
    assert.deepEqual(fs.readFileSync(dest), body, 'appending would have left 2000 extra bytes in front');
  }));

testAsync('the model never exists under its real name until it has verified', () =>
  withServer(async ({ base, dest, pin }) => {
    // This is the invariant that lets a resolver search a directory safely: a half-written model
    // does not have a model's name, so it cannot be found by one.
    let sawNamedFileMidFlight = false;
    let ticks = 0;
    const r = await fetchVerified({
      url: `${base}/slow/${pin.file}`, // dribbled out over eight ticks — the transfer has a middle
      dest,
      pin,
      onProgress: () => {
        ticks += 1;
        if (fs.existsSync(dest)) sawNamedFileMidFlight = true;
      },
    });
    assert.equal(r.ok, true, r.message);
    assert.ok(ticks >= 3, `the progress callback fired ${ticks} times — too few to have watched anything`);
    assert.equal(sawNamedFileMidFlight, false);
    assert.ok(fs.existsSync(dest), 'and it does exist once it has verified');
  }));

testAsync('a full disk is refused before a single request reaches the server', () =>
  withServer(async ({ base, dest, pin, seen }) => {
    const r = await fetchVerified({ url: `${base}/good/${pin.file}`, dest, pin, freeBytes: 10 });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.NO_SPACE);
    assert.match(r.message, /nothing was started/);
    assert.equal(seen.length, 0, 'the server saw a request it should never have received');
  }));

testAsync('a declared length that disagrees with the pin stops the transfer before the body', () =>
  withServer(async ({ base, dest, pin }) => {
    // On a metered or slow connection this is the difference between 3 KB and 1.6 GB of waste.
    const r = await fetchVerified({ url: `${base}/error-text/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.status, 'refused', 'refused, not failed — it never started');
    assert.equal(r.kind, FAILURE.TEXT_BODY, `got ${r.kind}: ${r.message}`);
    assert.match(r.message, /error message saved under a model's name/);
  }));

testAsync('a server that declares no length at all is still named correctly, from its body', () =>
  withServer(async ({ base, dest, pin }) => {
    // Content-Length is optional. When it is missing the early refusal cannot fire, and the answer
    // has to come from the bytes themselves — the same diagnosis by a slower road.
    const r = await fetchVerified({ url: `${base}/error-text-chunked/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.equal(r.kind, FAILURE.TEXT_BODY, `got ${r.kind}: ${r.message}`);
    assert.match(r.message, /the server said: "Internal Server Error/);
    assert.ok(!fs.existsSync(dest) && !fs.existsSync(`${dest}.part`));
  }));

testAsync('an HTTP error names the status and installs nothing', () =>
  withServer(async ({ base, dest, pin }) => {
    const r = await fetchVerified({ url: `${base}/busy/${pin.file}`, dest, pin });
    assert.equal(r.ok, false);
    assert.match(r.message, /the server answered 503/);
    assert.equal(r.retryable, true, '503 is one of the two statuses worth trying again');
    assert.ok(!fs.existsSync(dest));
  }));

testAsync('a hash mismatch stops at ONE attempt; a dropped connection gets its retries', () =>
  withServer(async ({ base, dir, pin }) => {
    // Retrying a corrupted download in a loop is how a transient CDN fault becomes a support
    // ticket. Retrying a dropped connection is just what a train tunnel needs.
    const bad = await downloadModel(pin, dir, { baseUrl: `${base}/wrong-content`, maxAttempts: 3 });
    assert.equal(bad.ok, false);
    assert.equal(bad.attempts.length, 1, 'a corrupted download must not be retried automatically');
    const flaky = await downloadModel(pin, dir, { baseUrl: `${base}/flaky`, maxAttempts: 3 });
    assert.equal(flaky.ok, true, flaky.message);
    assert.equal(flaky.attempts.length, 2);
  }));

testAsync('a download that never succeeds stops after its attempts and says how many it made', () =>
  withServer(async ({ base, dir, pin }) => {
    const r = await downloadModel(pin, dir, { baseUrl: `${base}/truncated`, maxAttempts: 2 });
    assert.equal(r.ok, false);
    assert.equal(r.attempts.length, 2);
    assert.match(r.message, /tried 2 times and stopped rather than looping/);
  }));

testAsync('an unpinned model never reaches the network at all', () =>
  withServer(async ({ base, dir, seen }) => {
    await assert.rejects(() => downloadModel('definitely-not-a-model', dir, { baseUrl: `${base}/good` }), /no pinned sha256/);
    assert.equal(seen.length, 0);
  }));

testAsync('a model already installed and verified is not downloaded again', () =>
  withServer(async ({ base, dest, pin, body, seen }) => {
    fs.writeFileSync(dest, body);
    const r = await fetchVerified({ url: `${base}/good/${pin.file}`, dest, pin });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'already-present');
    assert.equal(seen.length, 0, 'it re-downloaded a file the user already had');
  }));

testAsync('a model already installed but CORRUPT is replaced, never left where a resolver would find it', () =>
  withServer(async ({ base, dest, pin, body }) => {
    fs.writeFileSync(dest, Buffer.concat([GGML, Buffer.alloc(body.length - 4, 0x42)])); // right size, wrong bytes
    const r = await fetchVerified({ url: `${base}/good/${pin.file}`, dest, pin });
    assert.equal(r.ok, true, r.message);
    assert.deepEqual(fs.readFileSync(dest), body);
  }));

testAsync('modelStatus answers "what would this cost" without touching the network', () =>
  withServer(async ({ dir, dest, pin, body, seen }) => {
    const before = await modelStatus(pin, dir, { deep: true });
    assert.equal(before.installed, false);
    assert.equal(before.downloadBytes, pin.bytes);
    fs.writeFileSync(`${dest}.part`, body.subarray(0, 1000));
    const partial = await modelStatus(pin, dir, { deep: true });
    assert.equal(partial.partialBytes, 1000);
    assert.equal(partial.downloadBytes, pin.bytes - 1000, 'a resume only costs what is left');
    fs.rmSync(`${dest}.part`);
    fs.writeFileSync(dest, body);
    const after = await modelStatus(pin, dir, { deep: true });
    assert.equal(after.installed, true);
    assert.equal(after.verified, true, 'a deep status must say the hash was actually checked');
    assert.equal(after.downloadBytes, 0);
    assert.equal(seen.length, 0, 'a status check must never call out');
  }));

// ---------------------------------------------------------------------------------------
