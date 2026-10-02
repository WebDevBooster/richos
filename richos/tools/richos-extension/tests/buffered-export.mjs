import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

/** Exercise the explicit archive action and inspect it with Python's independent ZIP reader. */
export async function exportBufferedArchive(cdp, session, evaluate, downloadDir, sessionId) {
  const extensionId=await evaluate(cdp,session,'chrome.runtime.id');
  const {targetId}=await cdp.send('Target.createTarget',{url:`chrome-extension://${extensionId}/options/options.html`});
  const {sessionId:exportSession}=await cdp.send('Target.attachToTarget',{targetId,flatten:true});
  await cdp.send('Runtime.enable',{},exportSession);
  await cdp.send('Page.navigate',{url:`chrome-extension://${extensionId}/options/options.html`},exportSession);
  const expression=`(async()=>JSON.stringify(await chrome.runtime.sendMessage({target:'sw',module:'callCapture',type:'cc:export-session',sessionId:${JSON.stringify(sessionId)}})))()`;
  let result=await evaluate(cdp,exportSession,expression);
  if(typeof result==='string')result=JSON.parse(result);
  if(!result?.ok)throw new Error(`explicit archive export failed: ${JSON.stringify(result)}`);
  await cdp.send('Target.closeTarget',{targetId});
  const archives=[];const walk=dir=>{for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,entry.name);if(entry.isDirectory())walk(p);else if(entry.name===`${sessionId}.zip`)archives.push(p);}};walk(downloadDir);
  const archive=archives.at(-1);
  if(!archive)throw new Error('successful export has no ZIP on disk');
  execFileSync('python3',['-c',`import zipfile,sys,pathlib
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None, 'archive CRC failure'
 for name in z.namelist():
  p=pathlib.PurePosixPath(name)
  assert not p.is_absolute() and '..' not in p.parts, 'unsafe archive path'
 z.extractall(sys.argv[2])`,archive,path.join(downloadDir,'richos-capture')]);
  return {...result,archivePath:archive};
}
