"use strict";
// How long a real turn goes with NOTHING observable arriving.
// Source: docs/verification/acp-emission-probe-2026-08-28/run{1..5}.raw.jsonl,
// five real `claude-agent-acp` runs, every inbound message with its arrival ms.
const fs = require("fs");
const path = require("path");
const DIR = path.resolve(__dirname, "..", "acp-emission-probe-2026-08-28");

const all = [];
for (const f of fs.readdirSync(DIR).filter((f) => f.endsWith(".raw.jsonl")).sort()) {
  const rows = fs.readFileSync(path.join(DIR, f), "utf8").trim().split("\n").map(JSON.parse);
  // Only what the UI could ever see: inbound messages during the PROMPT phase.
  const inbound = rows.filter((r) => r.dir === "in" && r.phase === "prompt");
  const gaps = [];
  for (let i = 1; i < inbound.length; i++) gaps.push(inbound[i].atMs - inbound[i - 1].atMs);
  const first = inbound.length ? inbound[0].atMs - rows.filter((r) => r.dir === "out" && r.method === "session/prompt")[0].atMs : null;
  const span = inbound.length ? inbound[inbound.length - 1].atMs - inbound[0].atMs : 0;
  console.log(
    f.padEnd(16),
    "inbound=" + String(inbound.length).padStart(3),
    "prompt->first=" + String(first).padStart(6) + "ms",
    "span=" + String(span).padStart(6) + "ms",
    "maxGap=" + String(gaps.length ? Math.max.apply(null, gaps) : 0).padStart(6) + "ms",
    "medianGap=" + (gaps.length ? gaps.slice().sort((a, b) => a - b)[Math.floor(gaps.length / 2)] : 0) + "ms"
  );
  all.push(...gaps);
  if (first !== null) all.push(first);
}
all.sort((a, b) => a - b);
const pct = (p) => all[Math.min(all.length - 1, Math.floor((p / 100) * all.length))];
console.log("\nALL gaps (incl. prompt->first), n=" + all.length);
console.log("  p50 =", pct(50) + "ms", " p90 =", pct(90) + "ms", " p95 =", pct(95) + "ms", " p99 =", pct(99) + "ms", " max =", all[all.length - 1] + "ms");
console.log("  gaps over 5s:", all.filter((g) => g > 5000).length, " over 10s:", all.filter((g) => g > 10000).length, " over 20s:", all.filter((g) => g > 20000).length);
