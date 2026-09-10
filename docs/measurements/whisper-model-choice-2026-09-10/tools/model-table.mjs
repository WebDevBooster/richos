// Render every table in this measurement directly from the collected raw artifacts.
//
// WHY THE TABLES ARE GENERATED RATHER THAN TYPED. This project has a standing rule that a number
// in a brief carries the command that produced it. The weakest link in that chain is the human
// copying a figure out of a run log into a markdown table, which is exactly where a stale or
// transposed digit enters and then gets quoted forward as established. So `measurements/*.txt`
// here is the STDOUT of this file, and the record's tables are copied from that — one transcription
// step, from a generated artifact, rather than one per cell.
//
// Reads only `measurements/raw/`. Prints, in order: the short-call 2x2, the render-stability pair,
// the guard tallies, the long-form rows, and the resource rows.
//
// usage: model-table.mjs --raw <measurements/raw>
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const raw = flag('--raw');
if (!raw) { console.error('usage: model-table.mjs --raw <dir>'); process.exit(2); }
const rd = (f) => JSON.parse(fs.readFileSync(path.join(raw, f), 'utf8'));
const has = (f) => fs.existsSync(path.join(raw, f));
const jsonl = (f) => fs.readFileSync(path.join(raw, f), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const pct = (x) => `${(x * 100).toFixed(2)}%`;
const GB = (b) => (b / 1024 ** 3).toFixed(2);

const LABEL = {
  turbo: 'large-v3-turbo',
  q5: 'large-v3-turbo-q5_0',
  turboNfa: 'large-v3-turbo  -nfa',
  q5Nfa: 'large-v3-turbo-q5_0  -nfa',
};

console.log('SHORT CALL — 6 invented two-speaker calls, 12 channels, 1,905 scoring tokens.');
console.log('Corpus render A. Every row back to back on one render, one binary, one sitting.');
console.log('r1 and r2 are the SAME four configurations run in OPPOSITE order.\n');
console.log('rep config                        WER    cased     S   D   I   seg  wordT  wall');
for (const rep of ['r1', 'r2']) {
  for (const cfg of ['turbo', 'q5', 'turboNfa', 'q5Nfa']) {
    const f = `shortcall/${rep}-${cfg}.summary.json`;
    if (!has(f)) continue;
    const s = rd(f);
    console.log(
      `${rep}  ${LABEL[cfg].padEnd(27)} ${pct(s.wer).padStart(6)}  ${pct(s.werCase).padStart(6)}  ` +
      `${String(s.S).padStart(3)} ${String(s.D).padStart(3)} ${String(s.I).padStart(3)}  ` +
      `${String(s.segments).padStart(4)}  ${String(s.wordTimes).padStart(5)}  ${s.wallSec.toFixed(0).padStart(4)}s`,
    );
  }
}

console.log('\nDETERMINISM — r1 against r2, per configuration');
for (const cfg of ['turbo', 'q5', 'turboNfa', 'q5Nfa']) {
  const a = has(`shortcall/r1-${cfg}.summary.json`) ? rd(`shortcall/r1-${cfg}.summary.json`) : null;
  const b = has(`shortcall/r2-${cfg}.summary.json`) ? rd(`shortcall/r2-${cfg}.summary.json`) : null;
  if (!a || !b) continue;
  const same = a.S === b.S && a.D === b.D && a.I === b.I && a.segments === b.segments && a.wordTimes === b.wordTimes;
  console.log(`  ${LABEL[cfg].padEnd(27)} ${same ? 'IDENTICAL S/D/I/segments/wordTimes' : 'DIFFERS'}   wall ${a.wallSec.toFixed(0)}s vs ${b.wallSec.toFixed(0)}s`);
}

console.log('\nRENDER STABILITY — the SAME script rendered a second time by `say` (corpus B),');
console.log('both models re-run on it. The question is whether the GAP survives a re-render.\n');
console.log('render  model                        WER      S   D   I');
for (const [rep, name] of [['r1', 'A'], ['b1', 'B']]) {
  for (const cfg of ['turbo', 'q5']) {
    const f = `shortcall/${rep}-${cfg}.summary.json`;
    if (!has(f)) continue;
    const s = rd(f);
    console.log(`  ${name}     ${LABEL[cfg].padEnd(27)} ${pct(s.wer).padStart(6)}   ${String(s.S).padStart(3)} ${String(s.D).padStart(3)} ${String(s.I).padStart(3)}`);
  }
}
for (const [rep, name] of [['r1', 'A'], ['b1', 'B']]) {
  const t = has(`shortcall/${rep}-turbo.summary.json`) ? rd(`shortcall/${rep}-turbo.summary.json`) : null;
  const q = has(`shortcall/${rep}-q5.summary.json`) ? rd(`shortcall/${rep}-q5.summary.json`) : null;
  if (!t || !q) continue;
  console.log(`  render ${name}: q5_0 minus turbo = ${((q.wer - t.wer) * 100).toFixed(2)} WER points`);
}

console.log('\nFABRICATION — the SHIPPING repetition guard over the same decodes,');
console.log('with the physical speech-burst probe. Pre/post-guard WER is the same guard run.\n');
for (const [rep, name] of [['r1', 'A'], ['b1', 'B']]) {
  const f = `shortcall/${rep}.guard-tally.json`;
  if (!has(f)) continue;
  const g = rd(f);
  console.log(`render ${name}`);
  console.log('  model                        loops  stutters  silenceFabs  removed   pre-guard WER   post-guard WER');
  for (const cfg of Object.keys(g)) {
    const t = g[cfg];
    const pre = t.werPre != null ? pct(t.werPre) : '—';
    const post = t.werPost != null ? pct(t.werPost) : '—';
    console.log(
      `  ${LABEL[cfg].padEnd(27)} ${String(t.loops).padStart(5)} ${String(t.stutters).padStart(9)} ` +
      `${String(t.silenceFabrications).padStart(12)} ${String(t.removed).padStart(8)}   ${pre.padStart(13)}   ${post.padStart(14)}`,
    );
  }
  console.log();
}

console.log('LONG FORM — 92.3 minutes of REAL two-channel audio, shipping settings, both channels.');
console.log('No WER is quoted and none can be: this recording has no verified reference and,');
console.log('per the CEO ruling of 2026-09-10, no further recording will ever exist to make one.\n');
console.log('model                 ch      seg   words  post-guard  loops  span s  silFab  removed  decode wall');
for (const cfg of ['turbo', 'q5']) {
  for (const ch of ['me', 'others']) {
    const sf = `longform/${cfg}-${ch}.summary.json`;
    const gf = `longform/${cfg}-${ch}.guard.json`;
    if (!has(sf) || !has(gf)) continue;
    const s = rd(sf); const g = rd(gf);
    console.log(
      `${LABEL[cfg].padEnd(21)} ${ch.padEnd(6)} ${String(s.segments).padStart(4)} ${String(g.wordsIn).padStart(7)} ` +
      `${String(g.wordsOut).padStart(11)} ${String(g.loopFindings).padStart(6)} ${g.loopSpanSec.toFixed(1).padStart(7)} ` +
      `${String(g.silenceFabrications).padStart(7)} ${String(g.removed).padStart(8)} ${s.wallSec.toFixed(0).padStart(11)}s`,
    );
  }
}

console.log('\nRESOURCES — peak memory of the whisper-cli process that actually decoded,');
console.log('/usr/bin/time -l, BYTES on macOS. The `--version` identity probe is excluded by argv.\n');
console.log('scope         model                        peak maxRSS   peak footprint   decode wall');
for (const cfg of ['turbo', 'q5', 'turboNfa', 'q5Nfa']) {
  const f = `shortcall/r1-${cfg}.rss.jsonl`;
  if (!has(f)) continue;
  const rows = jsonl(f).filter((r) => r.argv.includes('-f'));
  const s = rd(`shortcall/r1-${cfg}.summary.json`);
  console.log(
    `${'short call'.padEnd(14)}${LABEL[cfg].padEnd(27)} ${(GB(Math.max(...rows.map((r) => r.maxrssBytes))) + ' GB').padStart(11)}   ` +
    `${(GB(Math.max(...rows.map((r) => r.footprintBytes))) + ' GB').padStart(14)}   ${(s.wallSec.toFixed(0) + ' s').padStart(11)}`,
  );
}
for (const cfg of ['turbo', 'q5']) {
  for (const ch of ['me', 'others']) {
    const f = `longform/${cfg}-${ch}.rss.jsonl`;
    if (!has(f)) continue;
    const rows = jsonl(f).filter((r) => r.argv.includes('-f'));
    for (const r of rows) {
      console.log(
        `${`92 min ${ch}`.padEnd(14)}${LABEL[cfg].padEnd(27)} ${(GB(r.maxrssBytes) + ' GB').padStart(11)}   ` +
        `${(GB(r.footprintBytes) + ' GB').padStart(14)}   ${(r.wallSec + ' s').padStart(11)}`,
      );
    }
  }
}
