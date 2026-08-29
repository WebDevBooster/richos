// DOES THE VOCABULARY REACH THE DICTATION DECODE?
//
// The call pipeline pins MAX_CONTEXT_TOKENS = 0, and at `-mc 0` whisper.cpp discards the initial
// prompt entirely — proven by sha256: three decodes of the same channel, with no prompt, with a
// prompt, and with a prompt plus --carry-initial-prompt, produced byte-identical output. So for
// CALLS, up-front biasing is structurally unavailable on the shipped configuration.
//
// open-wispr does NOT pass -mc (Transcriber.arguments builds `-m -f -l --no-timestamps -nt` and
// nothing else), so DICTATION runs at whisper.cpp's own default and the prompt is live. That is the
// difference this rig measures, on the same invented vocabulary, at open-wispr's exact arguments.
//
// AND IT MEASURES THE THING WER CANNOT SEE. Every dictation utterance is an INDEPENDENT decode with
// no shared context whatsoever — the cross-window consistency problem in its purest form. Each name
// below is spoken in several separate utterances, so "how many different ways did the machine spell
// one name" is asked of dictation exactly as the short-call measurement asked it of calls.
//
// usage: dictation-bias.mjs <libDir> <workDir>
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
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
const { tokens, align } = await import(pathToFileURL(path.join(WER_TOOLS, 'wer.mjs')).href);



const [libDir, workDir] = process.argv.slice(2);
const imp = (f) => import(pathToFileURL(path.join(libDir, f)).href);
const { correctText } = await imp('correct.js');
const { normalizeEntities } = await imp('entities.js');
const { askCandidates, answerAsk, phoneticSimilarity } = await imp('dictation.js');
const { learnTerm } = await imp('capture.js');

const MODEL = path.join(process.env.HOME, 'Models', 'Whisper', 'ggml-large-v3-turbo-q5_0.bin');
const SAY_VOICE = 'Samantha';

// INVENTED dictated messages. Every person, company, street and product here was written for this
// measurement; none of it is anyone's speech. Each tracked name recurs in several utterances.
const UTTERANCES = [
  'Ask Priya Sandoval to confirm the Halden Freight pickup window.',
  'Tell Priya Sandoval the Halden Freight manifest needs a second signature.',
  'Marla Kestrel is escalating the Corvane Systems ticket this afternoon.',
  'The Everlock agent stopped reporting after the Corvane Systems upgrade.',
  'Send Marla Kestrel the Everlock heartbeat logs.',
  'Quilvern Media wants the Ridgeline Analytics comparison by end of week.',
  'Tobias Renner signs off on the Quilvern Media contract.',
  'Nadia Kwok pulled the Ridgeline Analytics numbers already.',
  'The invoice is for Brightmoor Dental on Cannery Street, not Wexford Road.',
  'Brightmoor Dental moved from Wexford Road to Cannery Street in June.',
  'Northgate assumed the permission was granted and Pallas rejected the writes.',
  'Nadia Kwok escalated before Pallas was healthy again, and Northgate recovered.',
];

const TERMS = ['Priya Sandoval', 'Halden Freight', 'Marla Kestrel', 'Corvane Systems', 'Everlock',
  'Ridgeline Analytics', 'Quilvern Media', 'Tobias Renner', 'Nadia Kwok', 'Brightmoor Dental',
  'Wexford Road', 'Cannery Street', 'Northgate', 'Pallas'];

// The prompt the vocabulary produces. Names only — never the manglings, which would bias the decode
// TOWARD the mistake. Deterministic order so the same vocabulary always yields the same prompt.
const VOCAB_PROMPT = `${[...TERMS].sort().join('. ')}.`;
// The head token identifies an occurrence and is what varies in spelling — the same rule the
// short-call consistency measurement uses.
const HEADS = new Map(TERMS.map((t) => [t.split(' ')[0], t]));

fs.mkdirSync(workDir, { recursive: true });
const audio = [];
for (let i = 0; i < UTTERANCES.length; i += 1) {
  const wav = path.join(workDir, `u${String(i).padStart(2, '0')}.wav`);
  if (!fs.existsSync(wav)) {
    const aiff = `${wav}.aiff`;
    execFileSync('say', ['-v', SAY_VOICE, '-o', aiff, UTTERANCES[i]]);
    execFileSync(process.env.RICHOS_FFMPEG_BIN || 'ffmpeg',
      ['-y', '-i', aiff, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav],
      { stdio: 'ignore' });
    fs.rmSync(aiff, { force: true });
  }
  audio.push(wav);
}

/** open-wispr's EXACT argument set (Transcriber.arguments), plus the prompt when there is one. */
function dictate(wav, prompt) {
  const args = ['-m', MODEL, '-f', wav, '-l', 'en', '--no-timestamps', '-nt'];
  if (prompt) args.push('--prompt', prompt);
  const out = execFileSync('whisper-cli', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return out.replace(/\s+/g, ' ').trim();
}

/**
 * How many DIFFERENT ways did this set of independent decodes spell one name, and how often was it
 * exactly right?
 *
 * Scored by the SAME case-sensitive token alignment the short-call consistency measurement uses
 * (tools/wer.mjs), against each utterance's own reference. Reading off the hypothesis token the
 * alignment put opposite each reference name token is the only honest way to say what the machine
 * wrote there; searching the sentence for something that merely looks similar reports "permission"
 * as a rendering of "Pallas".
 */
function scoreNames(hyps) {
  const spellings = new Map(); // term -> Set of renderings across every utterance it appears in
  let expected = 0;
  let exact = 0;
  UTTERANCES.forEach((ref, i) => {
    const rt = tokens(ref, { caseSensitive: true });
    const ht = tokens(hyps[i], { caseSensitive: true });
    const a = align(rt, ht);
    for (const op of a.trace) {
      if (op.type === 'ins') continue;
      const term = HEADS.get(op.ref);
      if (!term) continue;
      expected += 1;
      if (op.type === 'ok') exact += 1;
      const set = spellings.get(term) || new Set();
      set.add(op.type === 'del' ? '<not written>' : op.hyp);
      spellings.set(term, set);
    }
  });
  const tracked = [...spellings.entries()];
  const consistent = tracked.filter(([, s]) => s.size === 1);
  return { expected, exact, tracked: tracked.length, consistent: consistent.length, spellings };
}

const say = [];
const out = (s = '') => { say.push(s); console.log(s); };

out('DICTATION — does the shared vocabulary reach the decode?');
out(`${UTTERANCES.length} invented utterances, ${TERMS.length} names, ${MODEL.split('/').pop()}`);
out("open-wispr's exact arguments: -m -f -l en --no-timestamps -nt  (NO -mc, so whisper's own default)");
out('');

const plain = audio.map((w) => dictate(w, null));
const biased = audio.map((w) => dictate(w, VOCAB_PROMPT));

// And the third path: no prompt, but the SHIPPED corrector run over the plain output, using the
// same names as a vocabulary the CEO had confirmed.
const doc = {
  schemaVersion: 1,
  version: '2026-08-29',
  entities: TERMS.map((t) => ({ canonical: t, type: 'unknown', aliases: [], mangled: [] })),
};
const mem = normalizeEntities(doc);
const corrected = plain.map((t) => correctText(t, mem.entities).text);
const both = biased.map((t) => correctText(t, mem.entities).text);

// THE FLYWHEEL'S OWN VOCABULARY. Not the names handed over as a gift — the pairs the ask gate
// raised from the FIRST utterance in which each name came out wrong, confirmed one at a time. Every
// later utterance is held out.
let fwDoc = { schemaVersion: 1, version: '2026-08-28', entities: [] };
let fwLedger = { suppressed: [], declined: {} };
const learnedFrom = [];
const already = new Set();
UTTERANCES.forEach((ref, i) => {
  for (const term of TERMS) {
    if (!ref.includes(term) || already.has(term)) continue;
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\p{L}\\p{N}])`, 'u');
    if (re.test(plain[i])) continue;           // came out right — nothing to correct here
    already.add(term);
    const { asks } = askCandidates(plain[i], ref);
    for (const a of asks) {
      const res = answerAsk(fwLedger, { ...a }, 'confirm');
      fwLedger = res.ledger;
      fwDoc = learnTerm(fwDoc, { canonical: res.learn.canonical, mangled: res.learn.mangled }, { today: '2026-08-29' }).doc;
      learnedFrom.push(`u${i}: "${a.from}" -> "${a.to}"  [${a.leg}]`);
    }
  }
});
const fwMem = normalizeEntities(fwDoc);
const flywheeled = plain.map((t) => correctText(t, fwMem.entities).text);
const flywheeledBiased = biased.map((t) => correctText(t, fwMem.entities).text);

const rows = [
  ['no vocabulary at all (today)', scoreNames(plain)],
  ['vocabulary as an initial PROMPT', scoreNames(biased)],
  ['vocabulary as a CORRECTION', scoreNames(corrected)],
  ['prompt AND correction', scoreNames(both)],
  ['FLYWHEEL vocabulary, correction', scoreNames(flywheeled)],
  ['FLYWHEEL vocabulary, prompt + correction', scoreNames(flywheeledBiased)],
];

out('path                                names right   names spelled consistently');
for (const [label, s] of rows) {
  out(`${label.padEnd(35)} ${String(`${s.exact}/${s.expected}`).padStart(11)}   ${String(`${s.consistent}/${s.tracked}`).padStart(26)}`);
}
out('');
out(`WHAT THE FLYWHEEL LEARNED — ${fwDoc.entities.length} entities, from the FIRST wrong utterance only:`);
for (const l of learnedFrom) out(`  ${l}`);
out('');
out('WHERE THE PROMPT ALONE STILL SPELLS ONE NAME MORE THAN ONE WAY:');
for (const [term, set] of rows[1][1].spellings) {
  if (set.size === 1 && set.has(term.split(' ')[0])) continue;
  out(`  ${term} -> ${[...set].map((x) => `"${x}"`).join(' , ')}`);
}
out('');
out('WHERE THE FLYWHEEL VOCABULARY STILL SPELLS ONE NAME MORE THAN ONE WAY:');
let anyLeft = false;
for (const [term, set] of rows[4][1].spellings) {
  if (set.size === 1 && set.has(term.split(' ')[0])) continue;
  anyLeft = true;
  out(`  ${term} -> ${[...set].map((x) => `"${x}"`).join(' , ')}`);
}
if (!anyLeft) out('  nothing — every tracked name came out exactly right, every time');

fs.writeFileSync(path.join(workDir, 'dictation-bias.txt'), say.join('\n') + '\n');
fs.writeFileSync(path.join(workDir, 'hypotheses.json'), JSON.stringify({ UTTERANCES, plain, biased, corrected, both }, null, 1));
console.log(`\nwritten: ${path.join(workDir, 'dictation-bias.txt')}`);
