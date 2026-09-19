'use strict';

// THE INSTRUCTION NAMES THE CONTROL THE DEVICE ACTUALLY HAS. `npm test`.
//
// Ray's candidate .11 walk, §4.5, verified on the CEO's HONOR X6b:
//
//     "The Mac instructs: 'Add Rich to your phone's Home Screen and allow notifications when it
//      asks.' Chrome's menu on this phone offers 'Install and create shortcut'. There is no 'Add
//      to Home Screen' item."
//
// WHAT THIS COMMIT CAN AND CANNOT REACH. The sentence Ray read is the MAC's, at
// `app/ui/phone.js:580`, and that file is held by another teammate on a parallel branch — it is
// not touched here. What is fixed here is the phone page's own half, which used to say NOTHING:
// a browser that cannot take a push until the app is installed had its offer hidden outright, so
// on iOS Safari in a tab he was told neither that push needs an install nor what the control is
// called. It is now named in the device's own words, or not at all.
//
// ANDROID CHROME IS DELIBERATELY NOT THAT CASE and the walk is why: Ray's §5 got both the site
// prompt and the system prompt from a TAB. Chrome on Android subscribes without an install, so
// the page needs no instruction there — which is exactly why §4.5 was only ever about the Mac's
// card. The Android wording is still derived here, because the function's whole job is to be
// right about the device rather than about one branch of the caller.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');

function lift(name) {
	const found = appJs.match(new RegExp(`\\nfunction ${name}\\(\\) \\{[\\s\\S]*?\\n\\}`));
	assert.ok(found, `${name} is gone from app.js`);
	return found[0];
}

/// The shipped functions, driven with a navigator of this test's choosing. `app.js` is an IIFE
/// that boots a browser app on load and cannot be `require`d; these two read nothing but
/// `navigator`.
function on(navigator) {
	const source = `${lift('installControlName')}\n${lift('installSentence')}\nreturn { control: installControlName(), sentence: installSentence() };`;
	// eslint-disable-next-line no-new-func
	return new Function('navigator', source)(navigator);
}

const IPHONE_X = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';
const HONOR_X6B = 'Mozilla/5.0 (Linux; Android 14; HONOR X6b) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';
const IPADOS = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

test('his iPhone is told Safari\'s own words', () => {
	const { control, sentence } = on({ userAgent: IPHONE_X });
	assert.deepStrictEqual(control, { menu: 'the Share menu', item: 'Add to Home Screen' });
	assert.match(sentence, /open the Share menu and choose “Add to Home Screen”\./);
	// And it says WHY he would, in his terms rather than the platform's.
	assert.match(sentence, /Rich can only reach you while this app is open\./);
});

test('his Android is told Chrome\'s own words, which are not the Mac\'s', () => {
	const { control, sentence } = on({ userAgent: HONOR_X6B });
	assert.deepStrictEqual(control, { menu: "your browser's menu", item: 'Install and create shortcut' });
	assert.match(sentence, /choose “Install and create shortcut”\./);
	assert.doesNotMatch(sentence, /Add to Home Screen/, 'the phone repeats the name his phone does not have');
});

test('an iPad, which calls itself a Mac, is still an iPad', () => {
	assert.deepStrictEqual(
		on({ userAgent: IPADOS, maxTouchPoints: 5 }).control,
		{ menu: 'the Share menu', item: 'Add to Home Screen' }
	);
	// A real Mac reports the same string with no touch points, and gets nothing.
	assert.strictEqual(on({ userAgent: IPADOS, maxTouchPoints: 0 }).control, null);
});

test('a browser this app cannot name is told NOTHING, rather than guessed at', () => {
	// A wrong menu name sends him looking for something that is not there, which is worse than
	// the silence this replaced.
	for (const ua of [
		'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/128.0.0.0 Mobile Safari/537.36 EdgA/128.0.0.0',
		'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/128.0.0.0 Mobile Safari/537.36 SamsungBrowser/23.0',
		'Mozilla/5.0 (Android 14; Mobile; rv:128.0) Gecko/128.0 Firefox/128.0',
		'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36',
		''
	]) {
		const { control, sentence } = on({ userAgent: ua });
		assert.strictEqual(control, null, `a menu name was invented for: ${ua || '(empty)'}`);
		assert.strictEqual(sentence, null);
	}
});

test('the offer shows the sentence only where the browser cannot take a push at all, and offers no button for it', () => {
	const branch = appJs.match(/if \(!\('serviceWorker' in navigator\)[\s\S]*?\n\t\}/);
	assert.ok(branch, 'the branch for a browser with no push at all is gone');
	assert.match(branch[0], /const sentence = installSentence\(\);/, 'the branch still says nothing on iOS');
	assert.match(branch[0], /!alreadyInstalled\(\)/, 'an app already on his home screen is told to install itself');
	assert.match(branch[0], /\$\('push-on'\)\.hidden = true;/,
		'a button is offered for something only the browser\'s own menu can do');
	assert.match(branch[0], /offer\.hidden = true;\n\t\treturn;/, 'a browser this app cannot name no longer falls silent');
});

test('the user agent decides two things in this app and no third', () => {
	// It is a string a browser is free to lie in, so what it is allowed to decide is the point.
	// `deviceName` picks the name of this phone in the Mac's device list; `installControlName`
	// picks a menu name in a sentence. Neither is a security decision, neither routes a request,
	// and a third reader would be the one to argue about.
	const readers = ['deviceName', 'installControlName'];
	for (const name of readers) {
		assert.match(lift(name), /navigator\.userAgent/, `${name} stopped reading the user agent`);
	}
	const reads = (appJs.match(/navigator\.userAgent/g) || []).length;
	const inside = readers.reduce((n, name) => n + (lift(name).match(/navigator\.userAgent/g) || []).length, 0);
	assert.strictEqual(reads, inside, `the user agent is read ${reads - inside} time(s) outside those two functions`);
});
