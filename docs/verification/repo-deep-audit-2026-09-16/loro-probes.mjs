import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const engine = path.resolve(process.argv[2] || '.', 'richos/engine');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'loro-audit-proof-'));
function run(bin, args) {
  const r=spawnSync(process.execPath,[path.join(engine,'loro/bin',bin),...args],{encoding:'utf8'});
  return {code:r.status,out:r.stdout,error:r.stderr};
}
function write(corpus, verb, args) {
  const r=run('loro-write.mjs',[verb,'--corpus',corpus,'--json',...args]);
  assert.equal(r.code,0,JSON.stringify(r)); return JSON.parse(r.out);
}
const corpus=path.join(scratch,'corpus');fs.mkdirSync(path.join(corpus,'ceo/records'),{recursive:true});
for(const id of ['alpha','beta']) write(corpus,'create-company',['--id',id]);
write(corpus,'append',['--partition','alpha','--id','contract','--kind','fact','--scope','org-shared','--body','Fictional Alpha contract renewal is February.']);
const compile=()=>run('loro-context.mjs',['compile','--corpus',corpus,'--company','beta','--audience','rich','--topic','Fictional Alpha contract renewal','--budget-chars','6000']);
const before=JSON.parse(compile().out);
const replacement=write(corpus,'supersede',['--ref','rec:companies/alpha/records/contract','--id','contract-corrected','--kind','fact','--scope','org-shared','--body','Fictional Alpha contract renewal is March, not February.','--why','Correct the month']);
const after=JSON.parse(compile().out);
assert.equal(before.items.length,0);
assert.ok(after.text.includes('Fictional Alpha contract renewal is March'));
assert.ok(after.items.some(i=>i.ref===replacement.ref));
console.log(JSON.stringify({finding:'company partition lost on supersede',replacement:replacement.ref,betaItemsBefore:before.items,betaItemsAfter:after.items},null,2));
// A synthetic product marker is sufficient for the real resolver's refusal.
const product=path.join(scratch,'product');fs.mkdirSync(path.join(product,'richos/app/crates/richos-core'),{recursive:true});
fs.writeFileSync(path.join(product,'richos/app/crates/richos-core/Cargo.toml'),'[package]\nname="fictional"\n');
const productDocs=path.join(product,'docs');fs.mkdirSync(productDocs);
const linked=path.join(scratch,'linked-corpus');fs.mkdirSync(path.join(linked,'ceo'),{recursive:true});
fs.symlinkSync(productDocs,path.join(linked,'ceo/records'),'dir');
const boundaryControl=run('loro-write.mjs',['append','--corpus',productDocs,'--id','control','--kind','fact','--body','CONTROL']);
assert.notEqual(boundaryControl.code,0);assert.match(boundaryControl.error,/inside the RichOS product repo/);
const escaped=write(linked,'append',['--id','private-fact','--kind','fact','--body','SYNTHETIC PRIVATE MEMORY']);
assert.match(fs.readFileSync(path.join(productDocs,'private-fact.md'),'utf8'),/SYNTHETIC PRIVATE MEMORY/);
console.log(JSON.stringify({finding:'linked child escapes corpus',control:boundaryControl.error.trim(),reportedFile:escaped.file,physicalFile:fs.realpathSync(escaped.file)},null,2));
console.log(JSON.stringify({scratch}));
