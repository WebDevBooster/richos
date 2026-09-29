// Make this process's stdout and stderr BLOCKING when they are pipes, so nothing it printed
// can be lost when it exits.
//
// WHY. On macOS, Node writes to a pipe ASYNCHRONOUSLY (Linux and TTYs are synchronous). When
// the reader has not drained the pipe, a write that does not fit is queued inside the process,
// and `process.exit()` discards that queue. `run.js --shards` prints every shard's held output
// in one burst and then exits, so the nightly's log of the UI gate stopped at one pipe buffer
// (about 64 KB) in the middle of shard 2 in runs 20260928T230511Z-20aa349a and
// 20260928T233221Z-56bcde43. Shards 3 and 4 and the coverage verdict never arrived, which is
// why neither log could say which check had failed. `ui-ledger.test.py`
// (test_a_sharded_run_prints_every_byte_before_it_exits) reproduced it: 303 of 4,000 lines.
//
// A blocking write waits for the reader instead of queueing, so the last line printed before
// `process.exit()` is on the pipe when the process ends. The cost is that a writer waits for
// a slow reader, which is the behavior every caller of this directory already assumes.
//
// `_handle.setBlocking` is libuv's `uv_stream_set_blocking`, the long-standing way to do this
// from Node. Where it is missing (a TTY already writes synchronously, a file is synchronous),
// there is nothing to do.

"use strict";

module.exports = function blockingStdio() {
  for (const stream of [process.stdout, process.stderr]) {
    const handle = stream && stream._handle;
    if (handle && typeof handle.setBlocking === "function") handle.setBlocking(true);
  }
};
