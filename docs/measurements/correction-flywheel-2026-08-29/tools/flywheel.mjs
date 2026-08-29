// THE FLYWHEEL, TURNED ONCE, AND MEASURED ON THE ONE THING WER CANNOT SEE.
//
// The 2026-08-29 short-call measurement found the shipped `-mc 0` decode spells a repeated name
// consistently 17 times out of 24, against 23/24 with carried context. That gap is exactly what a
// correction flywheel is supposed to close, so it is the metric — not WER.
//
// THE SIMULATION, AND WHY IT IS NOT A TAUTOLOGY. Handing the corrector the whole reference would
// make it an oracle and the result meaningless. So the CEO corrects EXACTLY ONE OCCURRENCE PER
// CHANNEL: the first name he would see rendered wrong, in a window of the surrounding words, the way
// he would fix it in a composer. Everything else — every later occurrence, every other channel,
// every DIFFERENT mis-spelling of the same name — is held out. The learned pair has to earn those.
//
// Every step runs through the SHIPPED code path and nothing else:
//   askCandidates()  the §7 ask gate, phonetic leg included, decides what is worth asking
//   answerAsk()      a confirm — the human statement; every ask here is confirmed, and that is
//                    recorded plainly, because a human standing in for the CEO IS the design
//   learnTerm()      the same writer `learn-term` and `dictation-answer` use
//   correctText()    the same corrector the call pipeline runs, which is now also the corrector
//                    `richos-service correct-text` gives the dictation path
//
// usage: flywheel.mjs <libDir> <corpusDir> <runsDir> <baseTag> <model> <mc> <afterTag>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

/**
 * Token alignment comes from the short-call WER harness (`tools/wer.mjs`), which is not vendored
 * here — one alignment implementation, and the numbers in this directory are comparable to that
 * brief's precisely because it is the same one. Point `RICHOS_WER_TOOLS` at that harness's `tools/`
 * directory. A missing harness fails HERE, by name, rather than as a bare module-not-found.
 */
const WER_TOOLS = process.env.RICHOS_WER_TOOLS;
if (!WER_TOOLS) {
  console.error('set RICHOS_WER_TOOLS to the short-call WER harness tools/ directory (it holds wer.mjs)');
  process.exit(2);
}
const { tokens, align, score } = await import(pathToFileURL(path.join(WER_TOOLS, 'wer.mjs')).href);



const [libDir, corpusDir, runsDir, baseTag, model, mcRaw, afterTag] = process.argv.slice(2);
if (!afterTag) {
  console.error('usage: flywheel.mjs <libDir> <corpusDir> <runsDir> <baseTag> <model> <mc> <afterTag>');
  process.exit(2);
}
const mc = Number(mcRaw);
const imp = (f) => import(pathToFileURL(path.join(libDir, f)).href);
const { askCandidates, answerAsk, applyLedger } = await imp('dictation.js');
const { learnTerm, serializeEntitiesDoc } = await imp('capture.js');
const { correctText } = await imp('correct.js');
const { normalizeEntities } = await imp('entities.js');

// The same tracked vocabulary the consistency measurement uses — invented, in full.
const TERMS = ['Priya Sandoval', 'Halden Freight', 'Marla Kestrel', 'Corvane Systems', 'Everlock',
  'Ridgeline Analytics', 'Quilvern Media', 'Tobias Renner', 'Nadia Kwok', 'Brightmoor Dental',
  'Wexford Road', 'Cannery Street', 'Tidemark', 'Northgate', 'Pallas'];
const HEADS = new Map(TERMS.map((t) => [t.split(' ')[0], t]));

const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
const runDirFor = (tag) => path.join(runsDir, `${model}__mc${mc}__${tag}`);

const WINDOW = 7; // words of context either side — a composer sentence, not a whole transcript

/**
 * What the CEO would fix: the FIRST tracked name in this channel that the decode rendered wrong.
 * Returns the heard window and the corrected window, as raw text, or null when the channel has
 * nothing wrong to correct.
 */
function firstCorrection(refText, hypText) {
  const rt = tokens(refText, { caseSensitive: true });
  const ht = tokens(hypText, { caseSensitive: true });
  const a = align(rt, ht);
  let hypPos = -1;
  for (const op of a.trace) {
    if (op.type !== 'ins') {
      if (op.type !== 'del') hypPos += 1;
    } else {
      hypPos += 1;
      continue;
    }
    if (!HEADS.has(op.ref)) continue;
    if (op.type === 'ok') continue;          // this occurrence came out right
    if (op.type === 'del') continue;         // a dropped word is not a mis-spelling to correct
    // op.type === 'sub': the decode wrote something else where this name belongs.
    const raw = hypText.split(/\s+/).filter(Boolean);
    // Locate the offending rendering in the RAW text (punctuation attached), nearest to hypPos.
    let idx = -1;
    let bestDist = Infinity;
    for (let k = 0; k < raw.length; k += 1) {
      const core = raw[k].replace(/[^\p{L}\p{N}']/gu, '');
      if (core !== op.hyp) continue;
      const dist = Math.abs(k - hypPos);
      if (dist < bestDist) { bestDist = dist; idx = k; }
    }
    if (idx < 0) continue;
    const lo = Math.max(0, idx - WINDOW);
    const hi = Math.min(raw.length, idx + WINDOW + 1);
    const heard = raw.slice(lo, hi).join(' ');
    const fixedTok = raw[idx].replace(op.hyp, op.ref);
    const correctedArr = raw.slice(lo, hi);
    correctedArr[idx - lo] = fixedTok;
    return { heard, corrected: correctedArr.join(' '), wrote: op.hyp, shouldBe: op.ref, name: HEADS.get(op.ref) };
  }
  return null;
}

// ---- turn the wheel ------------------------------------------------------------------------------
let doc = { schemaVersion: 1, version: '2026-08-28', entities: [] };
let ledger = { suppressed: [], declined: {} };
const audit = [];
const say = [];
const out = (s = '') => { say.push(s); console.log(s); };

out('THE CORRECTION FLYWHEEL, TURNED ONCE — what one correction per channel teaches');
out(`model ${model}   -mc ${mc}   (the shipped pipeline-wide MAX_CONTEXT_TOKENS)`);
out('');
out('The CEO corrects the FIRST name he sees rendered wrong in each channel, and nothing else.');
out('Every later occurrence, every other channel and every other mis-spelling is held out.');
out('');

for (const m of manifest) {
  for (const ch of ['me', 'others']) {
    const refPath = path.join(corpusDir, m.sessionId, `reference-${ch}.txt`);
    const hypPath = path.join(runDirFor(baseTag), m.id, `${ch}.hyp.txt`);
    if (!fs.existsSync(hypPath)) continue;
    const ref = fs.readFileSync(refPath, 'utf8');
    const hyp = fs.readFileSync(hypPath, 'utf8');
    const c = firstCorrection(ref, hyp);
    if (!c) { audit.push({ call: m.id, channel: ch, correction: null }); continue; }

    const { asks, rejected } = askCandidates(c.heard, c.corrected);
    const { prompts } = applyLedger(asks, ledger);
    const answered = [];
    for (const p of prompts) {
      // THE HUMAN STATEMENT. Standing in for the CEO, every ask raised here is confirmed — which is
      // the honest description of this measurement: it measures what the loop does WHEN HE ANSWERS,
      // not whether he would.
      const res = answerAsk(ledger, p, 'confirm');
      ledger = res.ledger;
      const r = learnTerm(doc, { canonical: res.learn.canonical, mangled: res.learn.mangled }, { today: '2026-08-29' });
      doc = r.doc;
      answered.push({ from: p.from, to: p.to, leg: p.leg, orthographic: p.orthographic, phonetic: p.phonetic, learned: r.changed });
    }
    audit.push({ call: m.id, channel: ch, correction: c, asks: answered, rejected });
    out(`${m.id}/${ch}`);
    out(`  he saw     "${c.wrote}"  where "${c.shouldBe}" belongs  (${c.name})`);
    out(`  he fixed   ...${c.heard}...`);
    if (!answered.length) out('  ASKED      nothing — the gate stayed silent on this correction');
    for (const a of answered) {
      out(`  ASKED      Add "${a.to}" to your vocabulary?   [${a.leg}: spelling ${a.orthographic}, sound ${a.phonetic}]  -> CONFIRMED`);
    }
    for (const r of rejected) out(`  silent     "${r.from}" -> "${r.to}": ${r.reason}`);
  }
}

const entitiesPath = path.join(runsDir, `entities-${afterTag}.json`);
fs.writeFileSync(entitiesPath, serializeEntitiesDoc(doc));
out('');
out(`LEARNED ${doc.entities.length} entities -> ${entitiesPath}  (version ${doc.version})`);
for (const e of doc.entities) out(`  ${e.canonical}  <- ${JSON.stringify(e.mangled)}`);

// ---- apply the learned vocabulary to EVERY channel, including the held-out ones -------------------
const mem = normalizeEntities(JSON.parse(fs.readFileSync(entitiesPath, 'utf8')));
const afterDir = runDirFor(afterTag);
const rows = JSON.parse(fs.readFileSync(path.join(runsDir, `results-${baseTag}.json`), 'utf8'));
const newRows = [];
let totalCorrections = 0;
for (const m of manifest) {
  for (const ch of ['me', 'others']) {
    const hypPath = path.join(runDirFor(baseTag), m.id, `${ch}.hyp.txt`);
    if (!fs.existsSync(hypPath)) continue;
    const hyp = fs.readFileSync(hypPath, 'utf8');
    const res = correctText(hyp, mem.entities);
    totalCorrections += res.corrections.length;
    fs.mkdirSync(path.join(afterDir, m.id), { recursive: true });
    fs.writeFileSync(path.join(afterDir, m.id, `${ch}.hyp.txt`), res.text);
    const ref = fs.readFileSync(path.join(corpusDir, m.sessionId, `reference-${ch}.txt`), 'utf8');
    const ci = score(ref, res.text);
    const cs = score(ref, res.text, { caseSensitive: true });
    const base = rows.find((r) => r.call === m.id && r.channel === ch) || {};
    newRows.push({ ...base, tag: afterTag, N: ci.N, hypWords: ci.M, S: ci.S, D: ci.D, I: ci.I, wer: ci.wer, werCase: cs.wer, errorsCase: cs.errors });
  }
}
fs.writeFileSync(path.join(runsDir, `results-${afterTag}.json`), JSON.stringify(newRows, null, 1));

const sum = (rs, k) => rs.reduce((a, r) => a + r[k], 0);
const wer = (rs) => (sum(rs, 'S') + sum(rs, 'D') + sum(rs, 'I')) / sum(rs, 'N');
out('');
out(`APPLIED ${totalCorrections} corrections across all ${newRows.length} channels -> ${afterDir}`);
out(`WER   before ${(wer(rows) * 100).toFixed(2)}%   after ${(wer(newRows) * 100).toFixed(2)}%`);
out(`cased WER   before ${(sum(rows, 'errorsCase') / sum(rows, 'N') * 100).toFixed(2)}%   after ${(sum(newRows, 'errorsCase') / sum(newRows, 'N') * 100).toFixed(2)}%`);

fs.writeFileSync(path.join(runsDir, `flywheel-${afterTag}.txt`), say.join('\n') + '\n');
fs.writeFileSync(path.join(runsDir, `flywheel-audit-${afterTag}.json`), JSON.stringify(audit, null, 1));
console.log(`\nwritten: ${path.join(runsDir, `flywheel-${afterTag}.txt`)}`);
