const assert = require('node:assert/strict');
const {axSearch} = require('../ax.js');
const n = (id, kids=[]) => ({id,kids});
const transcript=n('history',Array.from({length:4000},(_,i)=>n('old'+i)));
const composer=n('form',[n('Message'),n('Send')]);
const root=n('window',[transcript,composer,n('Send')]);
let examined=[];
const api={children:e=>e.kids,scope:(e,s)=>e.id===s,matches:e=>{examined.push(e.id);return e.id==='Send';}};
const p={mode:'find',max:5000,depth:16,first:true,nth:null};
assert.equal(axSearch([root],p,api).hits[0].el.id,'Send');
assert.ok(examined.length<6,'first match must precede thousands of history children');
const all=axSearch([root],{...p,first:false},api);
assert.equal(all.hits.length,2);assert.ok(all.exhaustive);
const second=axSearch([root],{...p,first:false,nth:1},api);
assert.equal(second.hits.length,2);
const scoped=axSearch([root],{...p,scope:'form'},api);
assert.equal(scoped.hits.length,1);assert.equal(scoped.hits[0].parent,composer);
assert.equal(axSearch([root],{...p,max:1},api).truncated,true);
assert.equal(axSearch([root],{...p,scope:'missing'},api).scoped,false);
assert.equal(axSearch([n('Send',[n('unvisited')])],p,api).exhaustive,false);
console.log('AX search: early exit, duplicate labels, explicit nth, scopes and caps passed');
// Exercise the actual JXA run() control flow with a System Events boundary fake.
const vm = require('node:vm');
const fs = require('node:fs');
function exercise(mode, extra={}) {
  let value='', focused=false, front=true, pressed=0, typed=0, clicked='', pending=null;
  const area={role:()=> 'AXTextArea',title:()=> 'Message',description:()=> '',
    value:()=>value,enabled:()=>true,uiElements:()=>[],position:()=>[10,20],size:()=>[100,30]};
  Object.defineProperty(area,'focused',{get:()=>()=>focused,set:v=>{focused=!extra.rejectFocus && v;}});
  const actions=()=>[{name:()=> 'AXPress'}];actions.byName=()=>({perform:()=>pressed++});area.actions=actions;
  const dialog={role:()=> 'AXGroup',subrole:()=> 'AXApplicationDialog',title:()=> 'Modal',uiElements:()=>[area]};
  const window={role:()=> 'AXWindow',uiElements:()=>extra.dialog?[dialog]:[area]};
  const proc={unixId:()=>71,name:()=> 'richos-tauri',windows:()=>[window]};
  Object.defineProperty(proc,'frontmost',{set:v=>{front=v;}});
  const se={processes:{byName:n=>n==='SecurityAgent'?{exists:()=>!!extra.blocked,windows:()=>[{}]}:proc,
    whose:query=>query.frontmost?[{unixId:()=>front?71:99}]:[proc]},
    keystroke:(text,opts)=>{if(opts)value='';else{if(extra.delayedValue)pending=text;else if(!extra.dropInput)value+=text;typed++;}}};
  const app=()=>se;app.currentApplication=()=>({doShellScript:s=>{clicked=s;}});
  const context={Application:app,delay:()=>{if(pending!==null){value+=pending;pending=null;}},AX_PARAMS:{mode,pid:71,text:'Message',value:null,first:true,nth:null,max:100,depth:16,
    input:'some text',replace:true,atx:12,aty:34,...extra}};
  vm.createContext(context);vm.runInContext(fs.readFileSync(require.resolve('../ax.js'),'utf8'),context);
  const records=JSON.parse('['+vm.runInContext('run()',context).split('\n').join(',')+']');
  return {records,pressed,typed,value,clicked};
}
assert.equal(exercise('focus').records.at(-1).verified,true);
assert.equal(exercise('type').value,'some text');
const delayed=exercise('type',{delayedValue:true});
assert.equal(delayed.records.at(-1).verified,true);assert.equal(delayed.typed,1);
assert.equal(exercise('type',{dropInput:true}).records.at(-1).error,'typefailed');
const refused=exercise('type',{rejectFocus:true});
assert.equal(refused.records.at(-1).error,'focusfailed');assert.equal(refused.typed,0);
assert.equal(exercise('click').pressed,1);
assert.match(exercise('clickat').clicked,/click at \{12, 34\}/);
assert.equal(exercise('find',{blocked:true}).records.at(-1).error,'blocked');
assert.equal(exercise('find',{text:'Absent',dialog:true}).records.at(-1).error,'blocked');
assert.equal(exercise('find',{text:'Absent'}).records.at(-1).error,'notfound');
assert.equal(axSearch([root],{...p,first:false,depth:1},api).exhaustive,false);
console.log('AX actions: verified focus/type, failed focus refuses typing, AXPress, coordinate dispatch and modal refusal passed');
