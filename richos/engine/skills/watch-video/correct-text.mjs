// correct-text.mjs -- reads a JSON array of strings on stdin, writes the same array
// with the RichOS vocabulary corrector (tools/richos-service/lib/correct.js) applied
// to each string, using the entity memory the transcription pipeline uses. Any
// failure exits non-zero and sentences.py keeps the uncorrected text.
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const here = path.dirname(new URL(import.meta.url).pathname);
const lib = process.env.RICHOS_SERVICE_LIB || path.resolve(here, '../../../tools/richos-service/lib');
const { correctText } = await import(pathToFileURL(path.join(lib, 'correct.js')).href);
const { loadEntityMemory } = await import(pathToFileURL(path.join(lib, 'entities.js')).href);

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const { entities } = loadEntityMemory();
process.stdout.write(JSON.stringify(input.map((s) => correctText(s, entities).text)));
