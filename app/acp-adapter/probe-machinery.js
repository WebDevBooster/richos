// ACP MACHINERY PROBE — records what claude-agent-acp actually emits, durably, on disk.
//
// probe.js proves the wire shape with a prompt that invokes no tools and logs non-text
// update kinds to stderr only (probe.js:36-38). That leaves the routing table in
// docs/plans/richos-techy-mode-2026-08-26.md §1.2 designed against an unobserved
// emission set. This probe closes that: a tool-using prompt, and EVERY inbound
// JSON-RPC message appended to a JSONL file as it arrives.
//
//   node probe-machinery.js <cwd> <raw-out.jsonl> [summary-out.json]
//
// Output line shape: { n, atMs, sinceStartMs, phase, dir, kind, method, msg }
//   n            monotonic arrival index — the observed order, which is the only
//                ordering claim this probe makes (timestamps collide, util.rs:5-8).
//   phase        init | session_new | prompt | post_stop  — which lifecycle window the
//                message arrived in. `init`/`session_new` traffic is exactly the
//                "between-turn, structurally unroutable" class of §1.5.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const CWD = process.argv[2] || path.resolve(__dirname, "..", "..", "engine");
const RAW_OUT = process.argv[3] || path.resolve(__dirname, "probe-machinery.raw.jsonl");
const SUMMARY_OUT = process.argv[4] || RAW_OUT.replace(/\.jsonl$/, "") + ".summary.json";

// The prompt. Deliberately exercises: file read, grep, bash, a multi-step plan, and a
// write to a path OUTSIDE any repo. Recorded verbatim in the summary so the run is
// reproducible.
const WRITE_TARGET = process.env.PROBE_WRITE_TARGET || "/tmp/richos-acp-probe-write-target.txt";
const PROMPT = process.env.PROBE_PROMPT || [
  "Do all five of the following yourself, with your tools, right now. Do not ask me anything first, do not delegate, and do not spawn subagents.",
  "Track the five steps on your todo list as you go.",
  "1. Read the file VERSION in your current working directory and tell me its contents.",
  '2. Grep for the string "sessionUpdate" under /Users/alex/ab/richos/app and tell me how many matches you find.',
  "3. Run the shell command: echo hello-from-acp-probe && uname -s",
  `4. Write exactly the single line probe-write-ok to the file ${WRITE_TARGET} (this path is outside every repo; overwriting it is fine).`,
  "5. Finish with one short sentence summarising what you found.",
].join("\n");

const bin = path.resolve(__dirname, "node_modules/.bin/claude-agent-acp");
const raw = fs.createWriteStream(RAW_OUT, { flags: "w" });
const startedAt = Date.now();

let phase = "init";
let n = 0;
const updateKinds = new Map(); // sessionUpdate -> {count, firstSample, phases}
const requestMethods = new Map(); // method -> {count, firstSample, phases}
const notifOtherMethods = new Map();

function record(dir, msg) {
  n += 1;
  const at = Date.now();
  let kind = null;
  const method = msg.method || null;
  if (msg.method === "session/update" && msg.params && msg.params.update) {
    kind = msg.params.update.sessionUpdate || "(missing sessionUpdate)";
  }
  raw.write(JSON.stringify({ n, atMs: at, sinceStartMs: at - startedAt, phase, dir, kind, method, msg }) + "\n");
  if (dir !== "in") return;
  if (kind) {
    const e = updateKinds.get(kind) || { count: 0, phases: {}, firstSample: msg.params.update };
    e.count += 1;
    e.phases[phase] = (e.phases[phase] || 0) + 1;
    updateKinds.set(kind, e);
  } else if (method && msg.id !== undefined) {
    const e = requestMethods.get(method) || { count: 0, phases: {}, firstSample: msg.params };
    e.count += 1;
    e.phases[phase] = (e.phases[phase] || 0) + 1;
    requestMethods.set(method, e);
  } else if (method) {
    const e = notifOtherMethods.get(method) || { count: 0, phases: {}, firstSample: msg.params };
    e.count += 1;
    e.phases[phase] = (e.phases[phase] || 0) + 1;
    notifOtherMethods.set(method, e);
  }
}

const child = spawn(bin, [], { stdio: ["pipe", "pipe", "pipe"], cwd: CWD, env: process.env });
let buf = "";
let id = 0;
const pending = new Map();

function send(method, params) {
  const msg = { jsonrpc: "2.0", id: ++id, method, params };
  record("out", msg);
  child.stdin.write(JSON.stringify(msg) + "\n");
  return new Promise((res) => pending.set(msg.id, res));
}
function reply(reqId, result) {
  const msg = { jsonrpc: "2.0", id: reqId, result };
  record("out", msg);
  child.stdin.write(JSON.stringify(msg) + "\n");
}

child.stderr.on("data", (d) => {
  if (process.env.PROBE_VERBOSE) process.stderr.write("[acp-stderr] " + d);
});

child.stdout.on("data", (d) => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let m;
    try {
      m = JSON.parse(line);
    } catch {
      raw.write(JSON.stringify({ n: ++n, phase, dir: "in", unparsed: line }) + "\n");
      continue;
    }
    record("in", m);
    if (m.id !== undefined && m.method) {
      handleReq(m); // agent -> client REQUEST
    } else if (m.id !== undefined) {
      const r = pending.get(m.id);
      if (r) {
        pending.delete(m.id);
        r(m);
      }
    }
  }
});

// Identical auto-satisfaction policy to acp.rs:184-205, so what we observe is what the
// shipped client would observe. Permission requests are auto-approved; fs helpers are
// answered for real here (acp.rs returns an EMPTY string for fs/read_text_file — see the
// artifact's "what this probe does differently" note).
function handleReq(m) {
  if (m.method === "session/request_permission") {
    const opts = (m.params && m.params.options) || [];
    const opt = opts.find((o) => o.kind && String(o.kind).startsWith("allow")) || opts[0];
    reply(m.id, { outcome: { outcome: "selected", optionId: opt ? opt.optionId : "allow" } });
  } else if (m.method === "fs/read_text_file") {
    let content = "";
    try {
      content = fs.readFileSync(m.params.path, "utf8");
    } catch {
      content = "";
    }
    reply(m.id, { content });
  } else if (m.method === "fs/write_text_file") {
    try {
      fs.writeFileSync(m.params.path, m.params.content);
    } catch {
      /* observed either way */
    }
    reply(m.id, null);
  } else {
    reply(m.id, {});
  }
}

function finish(stopResult, err) {
  const summary = {
    probe: "app/acp-adapter/probe-machinery.js",
    ranAt: new Date(startedAt).toISOString(),
    adapterRange: require("./package.json").dependencies["@agentclientprotocol/claude-agent-acp"],
    adapterInstalled: (() => {
      try {
        return require("./node_modules/@agentclientprotocol/claude-agent-acp/package.json").version;
      } catch {
        return "unknown";
      }
    })(),
    cwd: CWD,
    protocolVersionRequested: 1,
    prompt: PROMPT,
    writeTarget: WRITE_TARGET,
    totalMessagesRecorded: n,
    stopResult: stopResult || null,
    error: err ? String((err && err.stack) || err) : null,
    sessionUpdateKinds: Object.fromEntries(
      [...updateKinds].map(([k, v]) => [k, { count: v.count, phases: v.phases, firstSample: v.firstSample }]),
    ),
    clientDirectedRequestMethods: Object.fromEntries(
      [...requestMethods].map(([k, v]) => [k, { count: v.count, phases: v.phases, firstSample: v.firstSample }]),
    ),
    otherInboundNotifications: Object.fromEntries(
      [...notifOtherMethods].map(([k, v]) => [k, { count: v.count, phases: v.phases, firstSample: v.firstSample }]),
    ),
  };
  fs.writeFileSync(SUMMARY_OUT, JSON.stringify(summary, null, 2));
  raw.end();
  process.stderr.write(`\n=== observed sessionUpdate kinds (${n} messages recorded) ===\n`);
  for (const [k, v] of updateKinds) process.stderr.write(`  ${k}  x${v.count}  phases=${JSON.stringify(v.phases)}\n`);
  process.stderr.write("=== client-directed request methods ===\n");
  for (const [k, v] of requestMethods) process.stderr.write(`  ${k}  x${v.count}  phases=${JSON.stringify(v.phases)}\n`);
  process.stderr.write("=== other inbound notifications ===\n");
  for (const [k, v] of notifOtherMethods) process.stderr.write(`  ${k}  x${v.count}\n`);
  process.stderr.write(`raw:     ${RAW_OUT}\nsummary: ${SUMMARY_OUT}\n`);
}

(async () => {
  const init = await send("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
  });
  process.stderr.write("INIT " + JSON.stringify(init.result && init.result.protocolVersion) + "\n");
  phase = "session_new";
  const ns = await send("session/new", { cwd: CWD, mcpServers: [] });
  const sessionId = ns.result && ns.result.sessionId;
  process.stderr.write("SESSION=" + sessionId + "\n");
  // Deliberate quiet window: anything emitted here is between-turn traffic (§1.5).
  await new Promise((r) => setTimeout(r, 3000));
  phase = "prompt";
  const pr = await send("session/prompt", { sessionId, prompt: [{ type: "text", text: PROMPT }] });
  phase = "post_stop";
  // Second quiet window after stopReason, for anything trailing.
  await new Promise((r) => setTimeout(r, 3000));
  finish(pr.result);
  child.kill();
  setTimeout(() => process.exit(0), 300);
})().catch((e) => {
  finish(null, e);
  child.kill();
  setTimeout(() => process.exit(1), 300);
});
