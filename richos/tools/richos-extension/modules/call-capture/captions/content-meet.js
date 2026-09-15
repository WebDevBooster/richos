/**
 * RichOS — Meet caption content script (ISOLATED world, runs automatically on meet.google.com).
 *
 * This is the ONLY code RichOS runs inside a meeting page, and it is deliberately tiny and
 * READ-ONLY: it observes the caption text Meet renders and forwards it to the service worker.
 * It injects NOTHING visible into the page — no banner, no overlay, no styles, no nodes (the
 * sole permitted page injection remains the opt-in disclosure banner, which the controller
 * handles separately). Status UI stays toolbar-only.
 *
 * It STARTS AUTOMATICALLY with zero user gesture (that is the whole point of the caption
 * failsafe layer): the manifest injects it on every Meet page, so captions are being collected
 * the instant a call tab exists, covering the seconds before tab-audio is armed and the worst
 * case where tab-audio is never armed at all.
 *
 * Content scripts cannot be ES modules directly, so this classic bootstrap dynamically imports
 * the real logic from web-accessible module files.
 */

(async () => {
  // Only meaningful inside a top-level Meet page (skip cross-origin iframes with no captions).
  if (typeof chrome === 'undefined' || !chrome.runtime?.getURL) return;

  let adapterMod;
  let seamMod;
  try {
    adapterMod = await import(chrome.runtime.getURL('modules/call-capture/captions/meet.js'));
    seamMod = await import(chrome.runtime.getURL('modules/call-capture/captions/adapter.js'));
  } catch (err) {
    // If our own modules fail to load, the audio path is entirely unaffected — fail silent here
    // and let the service worker's "captions unavailable" reconciliation do its job.
    return;
  }

  /** Forward one already-deduped caption revision to the service worker. Never throws. */
  function send(message) {
    try {
      chrome.runtime.sendMessage({ target: 'sw', module: 'callCapture', ...message }, () => void chrome.runtime.lastError);
    } catch {
      /* the worker may be mid-restart; the next event re-reports */
    }
  }

  const adapter = adapterMod.createMeetCaptionAdapter({
    emit: (event) => send({ type: 'cc:caption', adapter: adapterMod.MEET_ADAPTER_ID, adapterVersion: adapterMod.MEET_ADAPTER_VERSION, event }),
    onDegraded: (detail) => send({ type: 'cc:captions-degraded', adapter: adapterMod.MEET_ADAPTER_ID, detail }),
  });
  seamMod.registerAdapter(adapter);

  // Announce that a caption adapter is live for this tab, so the controller can mark the
  // caption channel available even before the first caption word arrives.
  send({ type: 'cc:captions-attached', adapter: adapter.id, adapterVersion: adapter.version });
  await adapter.attach();

  // A periodic safety pump in case a mutation batch is missed (characterData mutations on
  // deeply-recycled nodes can be flaky); cheap because extraction is dedup-gated.
  const pumpTimer = setInterval(() => adapter.pump(), 1000);

  window.addEventListener('pagehide', () => {
    clearInterval(pumpTimer);
    void adapter.detach();
    send({ type: 'cc:captions-detached', adapter: adapter.id });
  });
})();
