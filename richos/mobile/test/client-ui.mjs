// Real bundled DOM/controller with delayed native persistence. This catches lost
// keystrokes that headless core actions alone cannot reveal.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { rmSync, mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { stageAssets } from '../cli/simulator.mjs';
const require = createRequire(import.meta.url);
const { createScratch } = require('./storage.cjs');
const {createClient}=require('../core/client.js');
const {harness}=require('../dev/client-runtime.js');
const { loadPlaywright } = require('../../app/ui/tests/lib/harness.js');
export async function clientUI() {
  const scratch = createScratch('client-ui'), assets = join(scratch, 'mobile-ui');
  let browser;
  try {
    stageAssets(assets, false);
    browser = await loadPlaywright().chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 375, height: 812 }, isMobile: true, hasTouch: true });
    const h=harness(), seed=await createClient(h.ports);
    await seed.dispatch({type:'pair',link:'https://mac.example/#pair=code'});
    await seed.dispatch({type:'confirm-pair',matched:true}); seed.close();
    await context.addInitScript(initial => {
      let data=initial, files=[{id:'retained',seconds:9,threadId:'general',origin:'https://mac.example'}], recording=false, serial=0;
      window.__voiceCalls=[];
      window.webkit = { messageHandlers: { richos: { async postMessage({ method, args }) {
        if (method === 'load') return data;
        if (method === 'save') { await new Promise(resolve => setTimeout(resolve, 25)); data = args.value; return true; }
        if (method === 'updateInfo') return { version: '0.1.0', build: '2', osVersion: '16.7.16', configured: false, appId: null, storefront: null };
        if (method === 'recordings') return files;
        if (method === 'recordStart') {recording=true;window.__voiceCalls.push(method);return true;}
        if (method === 'recordStop') {if(recording)files.push({id:'audio-'+(++serial),seconds:3});recording=false;window.__voiceCalls.push(method);return true;}
        if (method === 'recordCancel') {recording=false;window.__voiceCalls.push(method);return true;}
        if (['configure','sign','hash','recordHash'].includes(method)) return method==='hash'?'0'.repeat(64):'fixture';
        if (method === 'streamClose') return true;
        if (method === 'streamOpen') {window.__hello=()=>window.RichOSNativeEvent({id:args.id,kind:'stream-data',data:btoa('event: hello\ndata: '+JSON.stringify({capabilities:['text','voice','audio']})+'\n\n')});return true;}
        if (method === 'request') return {status:200,body:JSON.stringify({messages:[]}),headers:{'X-RichOS-Challenge':'fresh'}};
        if (method === 'incomingLink' || method === 'pushIncoming') return null;
        throw Error(method);
      } } } };
    },h.disk());
    const page = await context.newPage(), errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(join(assets, 'client.html')).href);
    const message = page.getByRole('textbox', { name: 'Message', exact: true });
    await page.getByRole('button', { name: 'Hold to record', exact: true }).waitFor();
    const recoveredSend=page.getByRole('button',{name:'Send unsent recording',exact:true});
    await recoveredSend.waitFor(); assert(await recoveredSend.isDisabled());
    await page.waitForFunction(()=>typeof window.__hello==='function');
    await page.evaluate(()=>window.__hello());
    await page.waitForFunction(()=>!document.querySelector('#recordings button[aria-label="Send unsent recording"]').disabled);
    const text = 'Native phone check 0123456789';
    await message.pressSequentially(text, { delay: 1 });
    await page.waitForFunction(value => document.querySelector('#message').value === value, text);
    // Wait on a semantic durability boundary, not a timing guess.
    await page.waitForFunction(() => !document.querySelector('#error').textContent);
    assert.equal(await message.inputValue(), text);
    // A new character after the delayed writes settle must append to the complete draft.
    await page.waitForTimeout(text.length * 35);
    assert.equal(await message.inputValue(), text);
    await message.pressSequentially('!'); assert.equal(await message.inputValue(), text + '!');
    for (const colorScheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme });
      for (const width of [320, 375, 430]) {
        await page.setViewportSize({ width, height: 812 });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${colorScheme} ${width}: horizontal overflow`);
      }
    }
    if(process.env.RICHOS_UI_SHOTS){mkdirSync(process.env.RICHOS_UI_SHOTS,{recursive:true});await page.screenshot({path:join(process.env.RICHOS_UI_SHOTS,'native-composer.png')});}
    await message.fill(''); await message.dispatchEvent('input');
    const mic=page.getByRole('button',{name:'Hold to record',exact:true});await mic.waitFor();
    const hold=async()=>{const box=await mic.boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.waitForFunction(()=>document.body.dataset.voice==='held');return box;};
    let box=await hold();await page.mouse.move(box.x+20,box.y-85,{steps:5});
    await page.waitForFunction(()=>document.body.dataset.voice==='locked');assert(await mic.isVisible(),'Keep the captured microphone attached until touch release');await page.mouse.up();assert(await mic.isHidden(),'Show only locked controls after release');
    if(process.env.RICHOS_UI_SHOTS)await page.screenshot({path:join(process.env.RICHOS_UI_SHOTS,'native-locked.png')});
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordStop').length),0);
    await page.getByRole('button',{name:'Cancel recording',exact:true}).click();
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    box=await hold();await page.mouse.move(box.x-100,box.y+20,{steps:5});await page.mouse.up();
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordCancel').length),2);
    await hold();await page.mouse.up();await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordStop').length),1);
    box=await hold();await page.mouse.move(box.x+20,box.y-85,{steps:5});
    await page.waitForFunction(()=>document.body.dataset.voice==='locked');assert(await mic.isVisible(),'Keep the captured microphone attached until touch release');await page.mouse.up();assert(await mic.isHidden(),'Show only locked controls after release');
    await page.getByRole('button',{name:'Send voice message',exact:true}).click();
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordStop').length),2);
    const input=await context.newCDPSession(page);
    const touchStart=async()=>{const b=await mic.boundingBox();const point={x:b.x+b.width/2,y:b.y+b.height/2};await input.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[point]});await page.waitForFunction(()=>document.body.dataset.voice==='held');return point;};
    await touchStart();
    await mic.dispatchEvent('pointercancel',{pointerType:'touch'});
    assert.equal(await page.evaluate(()=>document.body.dataset.voice),'held','A cancelled pointer must not end an ongoing finger hold');
    await input.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordStop').length),3);
    let point=await touchStart();
    await input.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:point.x-120,y:point.y}]});
    await input.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordCancel').length),3);
    point=await touchStart();
    await input.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:point.x,y:point.y-100}]});
    await page.waitForFunction(()=>document.body.dataset.voice==='locked');
    await input.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    await page.getByRole('button',{name:'Send voice message',exact:true}).tap();
    await page.waitForFunction(()=>document.body.dataset.voice==='idle');
    assert.equal(await page.evaluate(()=>window.__voiceCalls.filter(x=>x==='recordStop').length),4);
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.getByRole('button',{name:'Close settings',exact:true}).click();
    assert.deepEqual(errors, []);
    return { rapidTypingPreserved: true, bothThemesFitPhoneWidths: true };
  } finally { await browser?.close(); rmSync(scratch, { recursive: true, force: true }); }
}
