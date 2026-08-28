// ACP protocol probe: newline-delimited JSON-RPC over stdio to claude-agent-acp.
// Proves the round-trip end to end and prints the exact wire shape for the Rust client.
const { spawn } = require("child_process");
const path = require("path");

const ENGINE = process.argv[2] || path.resolve(__dirname, "..", "..", "engine");
const bin = path.resolve(__dirname, "node_modules/.bin/claude-agent-acp");

const child = spawn(bin, [], { stdio: ["pipe", "pipe", "pipe"], env: process.env });
let buf = "";
let id = 0;
const pending = new Map();
function send(method, params) {
  const msg = { jsonrpc: "2.0", id: ++id, method, params };
  process.stderr.write("--> " + JSON.stringify(msg) + "\n");
  child.stdin.write(JSON.stringify(msg) + "\n");
  return new Promise((res) => pending.set(msg.id, res));
}
child.stderr.on("data", (d) => process.stderr.write("[acp-stderr] " + d));
child.stdout.on("data", (d) => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { process.stderr.write("[unparsed] " + line + "\n"); continue; }
    if (m.id !== undefined && m.method) {
      // agent -> client request
      process.stderr.write("<== REQ " + m.method + " " + JSON.stringify(m.params).slice(0, 200) + "\n");
      handleReq(m);
    } else if (m.method === "session/update") {
      const u = m.params.update;
      if (u && u.sessionUpdate === "agent_message_chunk") {
        process.stdout.write(u.content.text || "");
      } else {
        process.stderr.write("<~~ update " + (u && u.sessionUpdate) + "\n");
      }
    } else if (m.id !== undefined) {
      process.stderr.write("<-- RESP " + JSON.stringify(m.result || m.error).slice(0, 300) + "\n");
      const r = pending.get(m.id); if (r) { pending.delete(m.id); r(m); }
    }
  }
});
function reply(reqId, result) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: reqId, result }) + "\n");
}
function handleReq(m) {
  if (m.method === "session/request_permission") {
    // auto-approve: pick first allow option
    const opt = (m.params.options || []).find((o) => o.kind && o.kind.startsWith("allow")) || m.params.options[0];
    reply(m.id, { outcome: { outcome: "selected", optionId: opt.optionId } });
  } else if (m.method === "fs/read_text_file") {
    reply(m.id, { content: "" });
  } else if (m.method === "fs/write_text_file") {
    reply(m.id, null);
  } else {
    reply(m.id, {});
  }
}

(async () => {
  const init = await send("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
  });
  process.stderr.write("INIT protocolVersion=" + JSON.stringify(init.result && init.result.protocolVersion) + "\n");
  const ns = await send("session/new", { cwd: ENGINE, mcpServers: [] });
  const sessionId = ns.result && ns.result.sessionId;
  process.stderr.write("SESSION=" + sessionId + "\n");
  process.stderr.write("\n===== PROMPT: asking Rich who he is =====\n");
  const pr = await send("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: "In one sentence: who are you and what is your current working directory?" }],
  });
  process.stderr.write("\nSTOP=" + JSON.stringify(pr.result) + "\n");
  child.kill();
  process.exit(0);
})().catch((e) => { process.stderr.write("ERR " + e.stack + "\n"); child.kill(); process.exit(1); });
