// Timeline payloads at SCALE, in the same wire shape as `lib/fixtures.js`.
//
// `fixtures.js` holds hand-written payloads copied from what `richos_core::timeline`
// serializes — a handful of items, each one chosen to make a rule visible. This file is the
// other half: the same shapes, generated, in the quantities two design documents promise
// ("A 10,000-item thread history remains smooth"). Nothing here invents a field; every one
// is a field `fixtures.js` already carries, and `realbytes.js` is still what joins that
// shape to the genuine bytes on disk.
//
// A THREAD IS TURNS, NOT ITEMS, and the two scale differently — 10,000 items over 1,000
// ordinary turns is a very different DOM from 10,000 items over 10,000 one-line turns. So
// the generator takes both numbers and the bench sweeps several ratios rather than picking
// one and calling it "10,000".

"use strict";

const ENTITY = "northwind";
const THREAD = "thr_scale";
const T0 = 1787000000000;
const TURN_SPACING_MS = 600000; // 10 minutes between turns — they never overlap by default
const TURN_ACTIVE_MS = 52000; // the pilot's real 52s multi-tool turn (architecture doc §2.1)

const ACTIVITY_TYPES = ["read", "edit", "shell", "search", "web", "image", "integration", "thread", "setup"];

function base(turnId, id, extra) {
  return Object.assign(
    {
      id,
      entityId: ENTITY,
      threadId: THREAD,
      turnId,
      bindingRevision: 1,
      createdAt: T0,
      sequence: null,
      slot: "stream",
      visibility: "ceo",
    },
    extra || {}
  );
}

/// `turns` turns of `itemsPerTurn` items each — one CEO message, one duration row, and the
/// rest interleaved prose and activity in shared-counter order, which is the shape §5/§6
/// actually renders.
function makeSnapshot(turns, itemsPerTurn) {
  const items = [];
  for (let t = 0; t < turns; t++) {
    const turnId = "turn_" + t;
    const at = T0 + t * TURN_SPACING_MS;
    items.push(
      Object.assign(base(turnId, turnId + ":user", { slot: "opening", createdAt: at }), {
        kind: "user_message",
        text: "Turn " + t + ": look at the packaging gate and tell me whether the icon pipeline actually arms it.",
        source: "text",
      })
    );
    const stream = Math.max(0, itemsPerTurn - 2);
    for (let k = 0; k < stream; k++) {
      const kAt = at + 1000 + k;
      if (k % 3 === 0) {
        items.push(
          Object.assign(base(turnId, turnId + ":text:" + k, { sequence: k, createdAt: kAt }), {
            kind: "rich_message",
            phase: "unknown",
            text:
              "Checked the gate at step " +
              k +
              ". The caller exists and the manifest lines up, so the arming path is real rather than asserted.",
          })
        );
      } else {
        items.push(
          Object.assign(base(turnId, turnId + ":act:" + k, { sequence: k, createdAt: kAt }), {
            kind: "activity",
            activityType: ACTIVITY_TYPES[k % ACTIVITY_TYPES.length],
            state: "completed",
            summary: "Read app/ui/timeline.js line " + k * 7,
            detailRef: turnId + ":act:" + k,
            startedAt: kAt,
          })
        );
      }
    }
    items.push(
      Object.assign(base(turnId, turnId + ":duration", { slot: "terminal", createdAt: at }), {
        kind: "work_duration",
        state: "completed",
        startedAt: at,
        endedAt: at + TURN_ACTIVE_MS,
        activeMs: TURN_ACTIVE_MS,
      })
    );
  }
  return { entityId: ENTITY, threadId: THREAD, mode: "ceo", bindingRevision: 1, items };
}

/// One more activity row arriving on `turnId` — the STRUCTURAL change that costs a render.
/// This is the event the CEO generates dozens of times in a single working turn.
///
/// THE PAYLOAD IS THE ITEM, plus `at`. Not an envelope around one: `onActivityUpserted`
/// does `putItem(model, p)` on the payload itself (STREAMING.md — "the payload IS the
/// timeline item a reload projects"). Wrapping it in `{ item: ... }` produces an item with
/// no `id` and no `turnId`, which lands under the key `undefined` and draws an EXTRA,
/// empty turn section. That is how the first version of this file read, and `scale.js`
/// check 1 caught it by counting turns.
function oneMoreActivity(turnId, n) {
  const at = T0 + 999_000_000;
  return Object.assign(base(turnId, "scale:new:" + n, { sequence: 9000 + n, createdAt: at + n }), {
    kind: "activity",
    activityType: "read",
    state: "completed",
    summary: "Read one more file (" + n + ")",
    detailRef: "scale:new:" + n,
    startedAt: at + n,
    at: at + n,
  });
}

module.exports = { makeSnapshot, oneMoreActivity, ENTITY, THREAD, T0, TURN_SPACING_MS, TURN_ACTIVE_MS };
