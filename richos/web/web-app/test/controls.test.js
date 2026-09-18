'use strict';

// A CONTROL THE MAC CANNOT STAND BEHIND CANNOT REACH HIS SCREEN — asserted on the SHIPPED FILES.
//
// The app shipped "Hold to record" as one of the two biggest controls on the screen while the Mac
// answered every voice note `503` (plan §2 A). The decision that fixes it is tested in
// `api.test.js` (`offers`, default-deny) and the wiring is walked in a real browser by
// `desktop-verify.js`. Neither of those is what this file is for.
//
// This file exists because `desktop-verify.js` needs Playwright and says so and exits 0 when it is
// not there — which is an honest skip and also a day on which nothing checks the screen. What is
// asserted here needs no browser, because it is a property of the bytes that ship:
//
//   1. BOTH HALVES SHIP HIDDEN. Not "the app hides them at boot" — hidden is the state in
//      `index.html`, so there is no path through this app that shows the control by omission, by an
//      error before the stream opens, or in the seconds before the first `hello` arrives.
//   2. THE STYLESHEET HONORS IT. `hidden` is only as good as the CSS, and this file's own
//      convention is a per-class `[hidden] { display: none }` rule rather than a global one.
//   3. ONE WRITER. `hold.hidden` is assigned in exactly one function, and that function asks the
//      api whether the Mac offers voice. A second writer somewhere else is how the control comes
//      back for a reason nobody remembers.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(ROOT, 'styles.css'), 'utf8');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');

test('the voice control ships HIDDEN, so a Mac that says nothing shows nothing', () => {
	const hold = html.match(/<button[^>]*id="hold"[^>]*>/);
	assert.ok(hold, 'the hold control is gone from index.html entirely');
	assert.match(hold[0], /\shidden[\s>]/, `the hold control ships visible: ${hold[0]}`);

	const note = html.match(/<p[^>]*id="hold-note"[^>]*>/);
	assert.ok(note, 'the note under the hold control is gone from index.html entirely');
	assert.match(note[0], /\shidden[\s>]/, `the note under the hold control ships visible: ${note[0]}`);
});

test('the stylesheet honors `hidden` on both halves — the attribute is only as good as the CSS', () => {
	// This file sets `display` per class rather than relying on a global `[hidden]` rule, so an
	// element whose class sets a display and whose `[hidden]` rule is missing stays on screen.
	assert.match(css, /\.hold\[hidden\]\s*\{\s*display:\s*none;?\s*\}/);
	assert.match(css, /\.hold-note\[hidden\]\s*\{\s*display:\s*none;?\s*\}/);
});

test('exactly one place in the app decides whether the voice control is on screen', () => {
	const writes = appJs.match(/^\s*(hold|\$\('hold-note'\))\.hidden\s*=/gm) || [];
	assert.strictEqual(writes.length, 2, `the control's visibility is written in ${writes.length} places, not the two inside applyCapabilities`);

	// And that one place asks the Mac rather than deciding for itself.
	const body = appJs.match(/function applyCapabilities\(\)\s*\{[\s\S]*?\n\}/);
	assert.ok(body, 'applyCapabilities is gone, and with it the only thing standing between the CEO and a control that does not work');
	assert.match(body[0], /api\.offers\('voice'\)/);
	assert.match(body[0], /hold\.hidden\s*=\s*!voice/);
	assert.match(body[0], /\$\('hold-note'\)\.hidden\s*=\s*!voice/);
	// Both `.hidden` writes in the file are the two inside this function.
	assert.strictEqual((body[0].match(/\.hidden\s*=/g) || []).length, 2);
});
