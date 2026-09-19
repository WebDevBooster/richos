'use strict';

// THE ANSWER HE ALREADY GAVE SURVIVES A RELOAD. `npm test`.
//
// Ray's candidate .11 walk, §5 (recorded as a minor, and it is the one sentence in that section
// he praised):
//
//     "the client side handles refusal gracefully and honestly. The banner updated itself to:
//      'Notifications stayed off, so Rich can only reach you while this app is open.' Accurate,
//      plain, no blame, no dead end. Minor: after the page was reloaded the banner reverted to the
//      generic 'Notifications are off…' wording rather than keeping the better sentence."
//
// WHY THE PERMISSION CANNOT CARRY THIS, which is the whole reason a flag exists at all. A phone
// that has never been asked and a phone whose owner dismissed the system prompt BOTH report
// `Notification.permission === 'default'`. That is exactly the state Ray was in: he allowed
// Chrome's site prompt and dismissed Android's system prompt, and nothing in the browser
// distinguishes that from a first visit. So what is remembered is HIS ANSWER, on this phone.
//
// WHAT THIS FILE PROVES. The shipped bytes: that the refusal is recorded where it happens, that
// it is cleared when he later says yes, that the restored value is read at boot, and that the
// sentence is chosen from it. It does NOT drive a reload in a browser — that needs a real
// permission prompt, which `test/desktop-verify.js` cannot produce and which on a device is the
// walk itself.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

const KEPT = 'Notifications stayed off, so Rich can only reach you while this app is open.';
const GENERIC = 'Notifications are off, so Rich cannot reach you when this app is closed.';

test('his refusal is written down at the moment he makes it', () => {
	const handler = appJs.match(/const permission = await Notification\.requestPermission\(\);[\s\S]*?\n\t\t\}/);
	assert.ok(handler, 'the moment he answers the prompt is gone from app.js');
	assert.match(handler[0], /notificationsDeclined = true;/);
	assert.match(handler[0], /settings\.set\('notificationsDeclined', true\)/, 'the refusal lives only in memory and dies with the page');
	assert.match(handler[0], new RegExp(KEPT.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('and it is thrown away the moment he says yes instead', () => {
	// A stale "no" would put the wrong sentence in front of him the next time the offer appears
	// for any other reason.
	const yes = appJs.match(/notificationsDeclined = false;\n\t\tsettings\.set\('notificationsDeclined', false\)/);
	assert.ok(yes, 'a refusal he has since reversed is kept forever');
});

test('the restored answer is read at boot, beside everything else this phone remembers', () => {
	assert.match(appJs, /notificationsDeclined = Boolean\(saved\.notificationsDeclined\);/,
		'nothing reads the stored answer back, so the reload still forgets it');
});

test('the banner says which of the two things is true, and the better sentence is the remembered one', () => {
	const chooser = appJs.match(/\$\('push-offer-text'\)\.textContent = notificationsDeclined[\s\S]*?;\n/);
	assert.ok(chooser, 'the banner no longer chooses its sentence from his answer');
	assert.ok(chooser[0].includes(KEPT), 'the sentence he earned is not the one kept');
	assert.ok(chooser[0].includes(GENERIC), 'a phone that has never been asked is told it "stayed" off');
});

test('the markup still ships the generic sentence, because a phone that has never been asked is the default', () => {
	assert.match(html, new RegExp(GENERIC.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
	assert.doesNotMatch(html, /stayed off/, 'the markup asserts an answer nobody has given yet');
});

test('the offer is never a sentence without its control, or a control without its sentence', () => {
	// The standing shape of this element (`index.html`: "A state he can change is rendered WITH the
	// control that changes it"). The remembered sentence must not have quietly removed the button
	// that lets him change his mind.
	const chooser = appJs.match(/\$\('push-offer-text'\)\.textContent = notificationsDeclined[\s\S]*?;\n/);
	const before = appJs.slice(0, appJs.indexOf(chooser[0]));
	const lastShow = before.lastIndexOf("$('push-on').hidden = false;");
	const lastHide = before.lastIndexOf("$('push-on').hidden = true;");
	assert.ok(lastShow > lastHide, 'the sentence that says notifications stayed off is shown with no way to turn them on');
});
