import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveCorpusRoot } from '../lib/layout.js';
import { loadCorpus } from '../lib/store.js';

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'loro layout '));
const write = (rel, text = '') => {
  const file = path.join(temporary, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
};
try {
  for (const layout of ['old', 'new', 'packed']) {
    const component = layout === 'old' ? 'old/engine/loro' : layout === 'new' ? 'new/richos/engine/loro' : 'packed/engine/loro';
    write(`${component}/lib/store.js`);
    write(`${component}/bin/loro-context.mjs`);
    if (layout !== 'packed') write(`${layout}/${layout === 'new' ? 'richos/' : ''}app/crates/richos-core/Cargo.toml`);
    const protectedRoot = layout === 'packed' ? 'packed/engine' : layout;
    const deeplyNested = `${protectedRoot}/${'nested/'.repeat(18)}corpus`;
    fs.mkdirSync(path.join(temporary, deeplyNested, 'ceo'), { recursive: true });
    assert.throws(() => resolveCorpusRoot({ corpus: path.join(temporary, deeplyNested), env: {} }), /product repo/);
    const alias = path.join(temporary, `${layout}-alias`);
    fs.symlinkSync(path.join(temporary, deeplyNested), alias);
    assert.throws(() => resolveCorpusRoot({ corpus: alias, env: {} }), /product repo/);
  }
  // The installed engine's parent is app data, not itself shipped product code.
  fs.mkdirSync(path.join(temporary, 'packed/private-corpus/ceo'), { recursive: true });
  assert.equal(resolveCorpusRoot({ corpus: path.join(temporary, 'packed/private-corpus'), env: {} }).layout, 'corpus');
  for (const prefix of ['engine', 'richos/engine']) {
    write(`legacy/${prefix}/ceo-wiki/wiki/delivery.md`, '# Delivery\n\n## Policy\n\nThe fictional depot sends all replacement parts by the morning truck after the order has been checked.\n');
  }
  const corpus = loadCorpus({ root: path.join(temporary, 'legacy') });
  assert.ok(corpus.byId.has('wiki:engine/ceo-wiki/wiki/delivery.md#policy'));
  assert.ok(corpus.byId.has('wiki:richos/engine/ceo-wiki/wiki/delivery.md#policy'));
  console.log('Loro relocation, physical storage boundary and legacy refs: passed');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
