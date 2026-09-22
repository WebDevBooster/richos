// Shared voice-message gestures. No DOM, audio implementation or network ownership.
(function(root, factory) {
  const api = factory(); if (typeof module === 'object') module.exports = api; root.RichOSVoice = api;
})(globalThis, function() {
  function createGesture(ports) {
    let phase = 'idle', context = null, startedAt = null, revision = 0, task = Promise.resolve();
    const snapshot = () => ({ phase, startedAt, context: context && {...context} });
    const emit = () => ports.changed?.(snapshot());
    const idle = () => { phase = 'idle'; context = null; startedAt = null; emit(); };
    function run(promise) { task = Promise.resolve(promise).catch(error => { idle(); ports.error?.(error); throw error; }); return task; }
    function cancel() {
      if (phase === 'idle' || phase === 'finishing') return Promise.resolve();
      revision++; phase = 'finishing'; emit();
      return run(Promise.resolve().then(() => ports.cancel()).then(idle));
    }
    function finish(send) {
      if (!['held','locked'].includes(phase)) return phase === 'preparing' ? cancel() : Promise.resolve();
      const owner = context; phase = 'finishing'; emit();
      return run(Promise.resolve().then(() => ports.finish({send, context:owner})).then(idle));
    }
    function press(owner) {
      if (phase !== 'idle') return Promise.resolve();
      context = {...owner}; phase = 'preparing'; const mine = ++revision; emit();
      // Starting now lets native permission cancellation overtake a pending permission dialog.
      return run(Promise.resolve(ports.start(context)).then(() => {
        if (mine !== revision) return;
        phase = 'held'; startedAt = (ports.now || Date.now)(); emit();
      }).catch(error => { if (mine === revision) throw error; }));
    }
    function move(dx, dy) {
      if (phase !== 'held') return Promise.resolve();
      if (dx <= -80) return cancel();
      if (dy <= -64) { phase = 'locked'; emit(); }
      return Promise.resolve();
    }
    return { snapshot, press, move, cancel, interrupt: () => finish(false),
      release: () => phase === 'locked' ? Promise.resolve() : finish(true),
      send: () => phase === 'locked' ? finish(true) : Promise.resolve(),
      // Accessible keyboard/switch-control equivalent of sliding upwards.
      lock: () => { if (phase === 'held') { phase = 'locked'; emit(); } }, settle: () => task };
  }
  return {createGesture};
});
