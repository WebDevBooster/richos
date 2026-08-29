// Timeline payloads in the EXACT shape `get_timeline` puts on the wire.
//
// Not invented: every field name and value here is copied from what
// `richos_core::timeline` serializes. `tests/realbytes.js` renders the genuine bytes from
// a real ledger through the real command body and asserts the two agree — so if this file
// ever drifts from the backend, that test fails rather than these quietly passing.

"use strict";

const ENTITY = "femcboost";
const THREAD = "thr_fem";
const TURN = "turn_ok";

function base(id, extra) {
  return Object.assign(
    {
      id,
      entityId: ENTITY,
      threadId: THREAD,
      turnId: TURN,
      bindingRevision: 1,
      createdAt: 1787949000000,
      sequence: null,
      slot: "stream",
      visibility: "ceo",
    },
    extra || {}
  );
}

function userMessage() {
  return Object.assign(base(TURN + ":user", { slot: "opening", createdAt: 1787948000000 }), {
    kind: "user_message",
    text: "Design the RichOS memory strategy.",
    source: "text",
  });
}

function richMessage(idx, text, seq) {
  return Object.assign(base(`${TURN}:text:${idx}`, { sequence: seq, createdAt: 1787948500000 + idx }), {
    kind: "rich_message",
    phase: "unknown",
    text,
  });
}

function activity(id, summary, seq, state) {
  return Object.assign(base(id, { sequence: seq }), {
    kind: "activity",
    activityType: "read",
    state: state || "completed",
    summary,
    detailRef: id,
    startedAt: 1787948600000,
  });
}

/// One delegated worker, exactly as `WorkerActivityItem` serializes (camelCase, flattened
/// base, `kind: "worker_activity"`).
function worker(id, seq, w) {
  return Object.assign(base(id, { sequence: seq }), {
    kind: "worker_activity",
    worker: Object.assign(
      {
        agentId: w.agentId,
        observedState: w.observedState,
        state: w.state,
        eventsObserved: w.eventsObserved === undefined ? 2 : w.eventsObserved,
      },
      w.workerName ? { workerName: w.workerName } : {},
      w.agentType ? { agentType: w.agentType } : {},
      w.latestUpdate ? { latestUpdate: w.latestUpdate } : {},
      w.firstObservedAt ? { firstObservedAt: w.firstObservedAt } : {},
      w.lastObservedAt ? { lastObservedAt: w.lastObservedAt } : {}
    ),
    detailRef: id,
  });
}

function duration(state, activeMs) {
  return Object.assign(base(TURN + ":duration", { slot: "terminal", createdAt: 1787948000000 }), {
    kind: "work_duration",
    state,
    startedAt: 1787948100000,
    endedAt: 1787948100000 + (activeMs || 0),
    activeMs,
  });
}

function snapshot(items) {
  return { entityId: ENTITY, threadId: THREAD, mode: "ceo", bindingRevision: 1, items };
}

/// THE REGRESSION FIXTURE: one CEO prompt, Rich's prose, three concurrently-delegated
/// workers in three different states, and a completed turn.
///
/// The three states are the three the engine can actually witness, one each:
///   Sage   `created`   -> pending_init -> "Starting"
///   Frank  `started`   -> running      -> "Working"
///   Clark  `run_ended` -> unknown      -> the word this slice had to choose
function threeWorkers() {
  return snapshot([
    userMessage(),
    richMessage(0, "Splitting this three ways — architecture, red team and research.", 0),
    worker("m_w_sage", 1, {
      agentId: "agt_sage",
      workerName: "Sage",
      agentType: "architecture",
      observedState: "created",
      state: "pending_init",
      eventsObserved: 1,
      firstObservedAt: "2026-08-29T04:00:00+00:00",
      lastObservedAt: "2026-08-29T04:00:00+00:00",
    }),
    worker("m_w_frank", 2, {
      agentId: "agt_frank",
      workerName: "Frank",
      agentType: "red team",
      observedState: "started",
      state: "running",
      firstObservedAt: "2026-08-29T04:00:01+00:00",
      lastObservedAt: "2026-08-29T04:00:04+00:00",
    }),
    worker("m_w_clark", 3, {
      agentId: "agt_clark",
      workerName: "Clark",
      agentType: "research",
      observedState: "run_ended",
      state: "unknown",
      latestUpdate: "Pulled 14 sources on Claude Code memory",
      eventsObserved: 4,
      firstObservedAt: "2026-08-29T04:00:02+00:00",
      lastObservedAt: "2026-08-29T04:07:31+00:00",
    }),
    activity("m_read", "Read a file", 4),
    richMessage(1, "Here is the shape I'd take.", 5),
    duration("completed", 461000),
  ]);
}

/// All three workers started together and all three are still open — §7.1's own example.
function allRunning() {
  const names = [
    ["agt_sage", "Sage", "architecture"],
    ["agt_frank", "Frank", "red team"],
    ["agt_clark", "Clark", "research"],
  ];
  return snapshot([
    userMessage(),
    ...names.map(([id, n, r], i) =>
      worker("m_w_" + n, i + 1, {
        agentId: id,
        workerName: n,
        agentType: r,
        observedState: "started",
        state: "running",
      })
    ),
    duration("working", null),
  ]);
}

/// All three runs are over and nothing recorded how any of them ended. The state §7.4 asks
/// about and the state this build genuinely cannot resolve.
function allEnded() {
  const names = [
    ["agt_sage", "Sage", "architecture"],
    ["agt_frank", "Frank", "red team"],
    ["agt_clark", "Clark", "research"],
  ];
  return snapshot([
    userMessage(),
    ...names.map(([id, n, r], i) =>
      worker("m_w_" + n, i + 1, {
        agentId: id,
        workerName: n,
        agentType: r,
        observedState: "run_ended",
        state: "unknown",
      })
    ),
    duration("completed", 461000),
  ]);
}

module.exports = {
  ENTITY,
  THREAD,
  TURN,
  snapshot,
  userMessage,
  richMessage,
  activity,
  worker,
  duration,
  threeWorkers,
  allRunning,
  allEnded,
};
