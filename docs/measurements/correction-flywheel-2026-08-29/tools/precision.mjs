// THE NEGATIVE CONTROL. The flywheel measurement shows what the gate SAYS. This shows what it does
// not say, on the same corpus, which is the half that decides whether the vocabulary stays clean.
//
// A negative test that passes for the wrong reason proves nothing, so each control below is paired
// with a POSITIVE probe over the identical text: the same sentence with a real name mis-hearing in
// it must still produce an ask. If the positive probe went quiet too, the control would only be
// showing that the harness is broken.
//
// usage: precision.mjs <libDir> <corpusDir> <runsDir> <tag> <model> <mc>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [libDir, corpusDir, runsDir, tag, model, mc] = process.argv.slice(2);
const imp = (f) => import(pathToFileURL(path.join(libDir, f)).href);
const { askCandidates, reviewSent, matchHeard } = await imp('dictation.js');

const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
const runDir = path.join(runsDir, `${model}__mc${mc}__${tag}`);

const say = [];
const out = (s = '') => { say.push(s); console.log(s); };

/** A CHANGE OF MIND: swap the words a person changes their mind about, never a name. */
const MIND = [
  [/\bThursday\b/g, 'Friday'], [/\bTuesday\b/g, 'Wednesday'], [/\bMonday\b/g, 'Thursday'],
  [/\bmorning\b/g, 'afternoon'], [/\bshould\b/g, 'must'], [/\bcan\b/g, 'will'],
  [/\bthree\b/g, 'four'], [/\bsixty\b/g, 'seventy'], [/\bfourteen\b/g, 'fifteen'],
  [/\bquick\b/g, 'fast'], [/\bplease\b/g, 'kindly'], [/\bthink\b/g, 'believe'],
];

/** A REAL mis-hearing, planted so the positive probe has something true to find. */
const PLANT = [['Marla', 'Marlow'], ['Tobias', 'Tobiaz'], ['Nadia', 'Nadya'], ['Halden', 'Holden'],
  ['Tidemark', 'Tidemarck'], ['Wexford', 'Wexfird'], ['Everlock', 'Everloch'], ['Ridgeline', 'Ritchline']];

let channels = 0;
let mindAsks = 0;
let plantChannels = 0;
let plantAsks = 0;
const mindDetail = [];

for (const m of manifest) {
  for (const ch of ['me', 'others']) {
    const hypPath = path.join(runDir, m.id, `${ch}.hyp.txt`);
    if (!fs.existsSync(hypPath)) continue;
    const heard = fs.readFileSync(hypPath, 'utf8').trim();
    channels += 1;

    // CONTROL 1 — a change of mind, over the whole channel.
    let minded = heard;
    for (const [re, to] of MIND) minded = minded.replace(re, to);
    if (minded !== heard) {
      const { asks } = askCandidates(heard, minded);
      mindAsks += asks.length;
      for (const a of asks) mindDetail.push(`${m.id}/${ch}: "${a.from}" -> "${a.to}" (${a.leg})`);
    }

    // POSITIVE PROBE over the same text — plant a mis-hearing and require the gate to speak.
    for (const [real, mangled] of PLANT) {
      if (!heard.includes(real)) continue;
      const misheard = heard.split(real).join(mangled);
      const { asks } = askCandidates(misheard, heard);
      plantChannels += 1;
      plantAsks += asks.length;
      break;
    }
  }
}

out('PRECISION — what the ask gate does NOT say, measured on the same corpus');
out('');
out(`CONTROL 1  a change of mind (day names, numbers, ordinary verbs) across ${channels} channels`);
out(`           asks raised: ${mindAsks}${mindAsks ? '' : '   <- silent, as required'}`);
for (const d of mindDetail) out(`           ${d}`);
out('');
out(`PROBE      the SAME channels with a real name mis-hearing planted (${plantChannels} channels)`);
out(`           asks raised: ${plantAsks}${plantAsks >= plantChannels ? '   <- the gate is awake, so the silence above means something' : '   <- PROBE FAILED: the gate is asleep, control 1 proves nothing'}`);
out('');

// CONTROL 2 — a TYPED message must never be paired with a dictation at all.
const now = 1_700_000_000_000;
const first = fs.readFileSync(path.join(runDir, manifest[0].id, 'me.hyp.txt'), 'utf8').trim();
const journal = [{ id: 'd1', at: now - 30_000, text: first }];
const typed = [
  'Remind me to renew the parking permit before the end of the month.',
  'What is on my calendar on Thursday afternoon?',
  'Draft a short reply saying we will confirm the numbers next week.',
];
let typedPrompts = 0;
let typedMatches = 0;
for (const t of typed) {
  const r = reviewSent(journal, t, {}, { now });
  if (r.matched) typedMatches += 1;
  typedPrompts += r.prompts.length;
}
const sentCorrected = first.replace(/\bPriya\b/, 'Briella');
const roundTrip = reviewSent([{ id: 'd1', at: now - 30_000, text: sentCorrected }], first, {}, { now });

out(`CONTROL 2  ${typed.length} TYPED messages offered against a live dictation journal`);
out(`           matched a dictation: ${typedMatches}   prompts: ${typedPrompts}${typedPrompts ? '' : '   <- silent, as required'}`);
out(`PROBE      the same journal, sent as a corrected dictation: matched ${roundTrip.matched}, `
  + `prompts ${roundTrip.prompts.length}${roundTrip.prompts.length ? '   <- the pairing works, so the refusals above mean something' : ''}`);
out('');
out(`VERDICT    ${mindAsks === 0 && typedPrompts === 0 && plantAsks >= plantChannels
  ? 'the gate stayed silent on every change of mind and every typed message, while still speaking on a planted mis-hearing'
  : 'FAILED — see above'}`);

fs.writeFileSync(path.join(runsDir, `precision-${tag}.txt`), say.join('\n') + '\n');
console.log(`\nwritten: ${path.join(runsDir, `precision-${tag}.txt`)}`);
