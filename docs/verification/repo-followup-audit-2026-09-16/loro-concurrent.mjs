import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
const source=process.argv[2];
const root=fs.mkdtempSync(path.join(os.tmpdir(),'loro-concurrent-audit-'));
fs.mkdirSync(path.join(root,'ceo/records'),{recursive:true});fs.mkdirSync(path.join(root,'companies'));
const cli=path.join(source,'richos/engine/loro/bin/loro-write.mjs');
const append=spawnSync(process.execPath,[cli,'append','--corpus',root,'--id','original','--kind','fact','--body','Synthetic acquisition budget 42 million.'],{encoding:'utf8'});
if(append.status!==0)throw Error(append.stderr);
async function pending(id){
 const child=spawn(process.execPath,['--import',path.join(import.meta.dirname,'observe-stdin.mjs'),cli,'supersede','--corpus',root,'--ref','rec:ceo/records/original','--id',id,'--kind','fact','--body-stdin','--why','Synthetic correction','--json']);
 let output='',error='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>error+=b);
 const completion=once(child,'exit').then(([code])=>({code,output,error}));
 while(!error.includes('AUDIT_STDIN_READY')){await Promise.race([once(child.stderr,'data'),completion.then(()=>{throw Error('child exited before stdin')})]);}
 return {child,completion};
}
const one=await pending('replacement-one');const two=await pending('replacement-two');
one.child.stdin.end('Synthetic acquisition budget 43 million.');const first=await one.completion;
two.child.stdin.end('Synthetic acquisition budget 44 million.');const second=await two.completion;
const {loadCorpus}=await import(path.join(source,'richos/engine/loro/lib/store.js'));
const records=loadCorpus({root,layout:'corpus'}).records.map(r=>({ref:r.id,supersededBy:r.supersededBy,text:r.text}));
assert.equal(first.code,0);assert.equal(second.code,0);assert.equal(records.filter(r=>!r.supersededBy).length,2);
const sequential=spawnSync(process.execPath,[cli,'supersede','--corpus',root,'--ref','rec:ceo/records/original','--id','third','--kind','fact','--body','Another correction','--why','Sequential control'],{encoding:'utf8'});assert.equal(sequential.status,5);
console.log(JSON.stringify({firstExit:first.code,secondExit:second.code,sequentialExit:sequential.status,records},null,2));
fs.rmSync(root,{recursive:true,force:true});
