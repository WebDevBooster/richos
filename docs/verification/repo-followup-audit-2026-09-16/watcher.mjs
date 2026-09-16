import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const source=process.argv[2];
const {scanZone}=await import(path.join(source,'richos/tools/richos-service/lib/watcher.js'));
const zone=fs.mkdtempSync(path.join(os.tmpdir(),'watcher-audit-'));
const good=path.join(zone,'b-good'); fs.mkdirSync(good);
fs.writeFileSync(path.join(good,'session.json'),JSON.stringify({sessionId:'good',status:'closed',startedAt:1,endedAt:2,audio:{parts:['audio-part-0.wav'],bytesTotal:10},pipeline:{status:'ready'}}));
fs.writeFileSync(path.join(good,'audio-part-0.wav'),'synthetic');fs.writeFileSync(path.join(good,'transcript.md'),'synthetic');
const control=scanZone({zone,process:false});
const bad=path.join(zone,'a-broken');fs.mkdirSync(bad);
fs.writeFileSync(path.join(bad,'session.json'),JSON.stringify({sessionId:'broken',status:'closed',startedAt:1,endedAt:2,audio:{parts:['audio-part-0.wav'],bytesTotal:10}}));
fs.symlinkSync(path.join(zone,'missing.wav'),path.join(bad,'audio-part-0.wav'));
const failures=[]; for(let i=0;i<2;i++){try{failures.push(scanZone({zone,process:false}));}catch(e){failures.push(e.message)}}
fs.unlinkSync(path.join(bad,'audio-part-0.wav'));fs.writeFileSync(path.join(bad,'audio-part-0.wav'),'synthetic');
fs.symlinkSync(path.join(good,'transcript.md'),path.join(bad,'transcript.md'));
let boundaryFailure;try{scanZone({zone,process:true});}catch(e){boundaryFailure=e.message;}
assert.match(boundaryFailure,/storage boundary/);
assert.deepEqual(control.skipped,['good']);assert.ok(failures.every(r=>typeof r==='string' && r.includes('ENOENT')));
console.log(JSON.stringify({control,failures,boundaryFailure},null,2));fs.rmSync(zone,{recursive:true,force:true});
