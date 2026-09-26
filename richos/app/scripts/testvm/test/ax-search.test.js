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
  let value=extra.initialValue || '', focused=false, front=true, pressed=0, typed=0, clicked='', pending=null, clipboard='original clipboard';
  const area={role:()=> extra.nodeRole || 'AXTextArea',title:()=> 'Message',description:()=> '',
    value:()=>extra.toxicValue ? {toString(){throw new Error("cannot coerce AX specifier");}} : value,enabled:()=>true,uiElements:()=>[],position:()=>[10,20],size:()=>[100,30]};
  Object.defineProperty(area,'focused',{get:()=>()=>focused,set:v=>{focused=!extra.rejectFocus && v;}});
  area.attributes={byName:name=>({value:()=>name==='AXDOMIdentifier'?'route-choice':null})};
  const actions=()=>[{name:()=> 'AXPress'}];actions.byName=()=>({perform:()=>{
    pressed++;
    if(extra.pressValue!==undefined){if(extra.delayedPress)pending=extra.pressValue;else value=extra.pressValue;}
    if(extra.throwAfterPress)throw new Error('reply lost after press');
  }});area.actions=actions;
  const dialog={role:()=> 'AXGroup',subrole:()=> 'AXApplicationDialog',title:()=> 'Modal',uiElements:()=>[area]};
  const window={role:()=> 'AXWindow',uiElements:()=>extra.dialog?[dialog]:extra.duplicate?[area,area]:[area]};
  const proc={unixId:()=>71,name:()=> 'richos-tauri',windows:()=>[window]};
  Object.defineProperty(proc,'frontmost',{set:v=>{front=v;}});
  const se={processes:{byName:n=>n==='SecurityAgent'?{exists:()=>!!extra.blocked,windows:()=>[{}]}:proc,
    whose:query=>query.frontmost?[{unixId:()=>front?71:99}]:[proc]},
    keystroke:(text,opts)=>{if(opts && text==='a')value='';else if(opts && text==='v'){if(extra.delayedValue)pending=clipboard;else if(!extra.dropInput)value+=clipboard;typed++;}else throw new Error('literal input must use paste');}};
  const app=()=>se;app.currentApplication=()=>({doShellScript:s=>{clicked=s;},theClipboard:()=>clipboard,setTheClipboardTo:v=>{clipboard=v;}});
  const context={Application:app,delay:()=>{if(pending!==null){if(extra.delayedPress)value=pending;else value+=pending;pending=null;}},AX_PARAMS:{mode,pid:71,text:'Message',value:null,first:true,nth:null,max:100,depth:16,
    input:'some text',replace:true,atx:12,aty:34,...extra}};
  vm.createContext(context);vm.runInContext(fs.readFileSync(require.resolve('../ax.js'),'utf8'),context);
  const records=JSON.parse('['+vm.runInContext('run()',context).split('\n').join(',')+']');
  return {records,pressed,typed,value,clicked,clipboard};
}
assert.equal(exercise('focus').records.at(-1).verified,true);
assert.equal(exercise('type').value,'some text');
const delayed=exercise('type',{delayedValue:true});
assert.equal(delayed.records.at(-1).verified,true);assert.equal(delayed.typed,1);
assert.equal(exercise('type',{dropInput:true}).records.at(-1).error,'typefailed');
const refused=exercise('type',{rejectFocus:true});
assert.equal(refused.records.at(-1).error,'focusfailed');assert.equal(refused.typed,0);
assert.equal(exercise('click').pressed,1);
// The press is timed where it happens, on the guest's clock: a caller that reads the clock
// before ax.sh measures the SSH trip and the tree search too (2.6-5.6 s, guest walk-0ddfdbf8ff00).
{ const before=Date.now(); const clicked=exercise('click').records.at(-1); const after=Date.now();
  assert.ok(Number.isInteger(clicked.pressed_at_ms) && clicked.pressed_at_ms>=before && clicked.pressed_at_ms<=after, JSON.stringify(clicked));
  assert.ok(clicked.returned_at_ms>=clicked.pressed_at_ms && clicked.returned_at_ms<=after, JSON.stringify(clicked)); }
assert.match(exercise('clickat').clicked,/click at \{12, 34\}/);
assert.equal(exercise('find',{blocked:true}).records.at(-1).error,'blocked');
assert.equal(exercise('find',{text:'Absent',dialog:true}).records.at(-1).error,'blocked');
assert.equal(exercise('find',{text:'Absent'}).records.at(-1).error,'notfound');
assert.equal(axSearch([root],{...p,first:false,depth:1},api).exhaustive,false);
console.log('AX actions: verified focus/type, failed focus refuses typing, AXPress, coordinate dispatch and modal refusal passed');

const literal = exercise('type',{input:'Keep "quotes", `ticks`, $money and\nnewlines exactly.'});
assert.equal(literal.records.at(-1).verified,true);
assert.equal(literal.clipboard,'original clipboard');
assert.equal(exercise('type',{dropInput:true}).clipboard,'original clipboard');
assert.equal(exercise('find',{toxicValue:true}).records.at(-1).value,'');
assert.equal(exercise('find',{toxicValue:true,value:'expected'}).records.at(-1).error,'notfound');
console.log('AX scalar read refuses object coercion; literal paste preserves text and restores clipboard');

// The app's own Quit is a MENU BAR item (main.rs builds "Quit {name}" under MENU_QUIT), and the
// menu bar is not one of proc.windows(). A search of the windows can never find it: reap-walk
// asked for it that way, and that step had never run. `--in menubar` searches proc.menuBars().
function menuExercise(extra) {
  let pressed = 0;
  const el = (role, title, kids = []) => ({role:()=>role, title:()=>title, description:()=> '', value:()=> '',
    enabled:()=>true, uiElements:()=>kids, position:()=>[0,0], size:()=>[10,10]});
  const quit = el('AXMenuItem', 'Quit RichOS');
  const actions = ()=>[{name:()=> 'AXPress'}]; actions.byName = ()=>({perform:()=>pressed++}); quit.actions = actions;
  const bar = el('AXMenuBar', '', [el('AXMenuBarItem', 'RichOS', [el('AXMenu', '', [el('AXMenuItem', 'About RichOS'), quit])])]);
  const window = el('AXWindow', 'RichOS', [el('AXButton', 'Send')]);
  const proc = {unixId:()=>71, name:()=> 'richos-tauri', windows:()=>[window], menuBars:()=>[bar]};
  const se = {processes:{byName:n=>n==='SecurityAgent'?{exists:()=>false,windows:()=>[]}:proc, whose:()=>[proc]}};
  const app = ()=>se; app.currentApplication = ()=>({});
  const context = {Application:app, delay:()=>{}, AX_PARAMS:{mode:'click', pid:71, text:'Quit RichOS', role:'AXMenuItem',
    value:null, first:true, nth:null, max:100, depth:16, ...extra}};
  vm.createContext(context); vm.runInContext(fs.readFileSync(require.resolve('../ax.js'), 'utf8'), context);
  return {records: JSON.parse('[' + vm.runInContext('run()', context).split('\n').join(',') + ']'), pressed};
}
const inWindows = menuExercise({});
assert.equal(inWindows.pressed, 0); assert.equal(inWindows.records.at(-1).error, 'notfound');
const inMenuBar = menuExercise({scope:'menubar'});
assert.equal(inMenuBar.pressed, 1, JSON.stringify(inMenuBar.records));
assert.equal(inMenuBar.records.at(-1).node.title, 'Quit RichOS');
console.log('AX menu bar: a menu item is in no window, and --in menubar finds and presses it');
// Stable selectors and role hints must never change which element is acted on.
assert.equal(exercise('find',{id:'route-choice'}).records.at(-1).role,'AXTextArea');
assert.equal(exercise('find',{id:'wrong'}).records.at(-1).error,'notfound');
const hint=exercise('click',{role:'AXCheckBox'});
assert.equal(hint.pressed,0);
assert.equal(hint.records.at(-1).near_matches[0].role,'AXTextArea');
assert.equal(exercise('click',{id:'route-choice',duplicate:true,first:false}).records.at(-1).error,'ambiguous');
const verified=exercise('click',{id:'route-choice',expect:{value:'1'},initialValue:'0',pressValue:'1',delayedPress:true});
assert.equal(verified.records.at(-1).verified,true);assert.equal(verified.pressed,1);
const already=exercise('click',{expect:{value:'1'},initialValue:'1'});
assert.equal(already.records.at(-1).already_satisfied,true);assert.equal(already.pressed,0);
const unknown=exercise('click',{expect:{value:'1'}});
assert.equal(unknown.records.at(-1).error,'effect_unknown');assert.equal(unknown.pressed,1);
const lost=exercise('click',{expect:{value:'1'},pressValue:'1',throwAfterPress:true});
assert.equal(lost.records.at(-1).error,'effect_unknown');assert.equal(lost.pressed,1);
assert.equal(exercise('click',{expect:{value:'1'},toxicValue:true}).records.at(-1).error,'effect_unknown');
assert.equal(exercise('click',{id:'route-choice',first:false,max:1}).records.at(-1).error,'incomplete');
console.log('AX IDs, role hints, ambiguity, delayed click verification and unknown-effect refusal passed');

