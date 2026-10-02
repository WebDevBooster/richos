import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile(new URL('../modules/call-capture/content-zoom.js',import.meta.url),'utf8');
for(const path of ['/wc/12345678901/join','/wc/12345678901/start','/wc/home']){
 let dialogs=[],callback,disconnected=false,messages=[];
 const context={location:{pathname:path},document:{documentElement:{},querySelectorAll:()=>dialogs},MutationObserver:class{constructor(f){callback=f}observe(){}disconnect(){disconnected=true}},setInterval:()=>1,clearInterval:()=>{},chrome:{runtime:{sendMessage:async m=>{messages.push(m);return{ok:true}}}}};
 vm.runInNewContext(source,context);
 if(path.endsWith('home')){assert.equal(callback,undefined);continue;}
 dialogs=[{textContent:'End Meeting for All Leave Meeting',getClientRects:()=>[1]}];await callback();assert.equal(messages.length,0,'confirmation is not a completed meeting');
 dialogs=[{textContent:'This meeting has been ended by host',getClientRects:()=>[]}];await callback();assert.equal(messages.length,0,'hidden terminal dialogs do not end active calls');
 dialogs=[{textContent:'This meeting has been ended by host',getClientRects:()=>[1]}];await callback();await callback();assert.equal(messages.length,1);assert.equal(messages[0].type,'cc:platform-ended');assert.equal(disconnected,true);
}
console.log('PASS Zoom host and guest terminal dialog detection, deduplication and dashboard exclusion');
