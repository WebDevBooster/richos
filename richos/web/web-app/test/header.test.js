'use strict';

// THE HEADER DOES NOT BREAK A WORD IN HALF. `npm test`.
//
// Ray's candidate .11 walk, §4.3
// (`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260918.6-mac-and-android-audit.md`):
//
//     "The header renders 'Runni / ng' — the thread title broken across two lines because three
//      items are crammed onto one row: the title, the word 'Conversation', and a dropdown also
//      reading 'Running'. The first thing he sees after pairing is a broken word and the same
//      word three times."
//
// THE MECHANISM, AND IT IS TWO RULES RATHER THAN ONE. The title was a flex child beside the
// picker with `min-width: 0`, so the flex algorithm was allowed to shrink it below its own
// longest word in order to fit a picker whose select alone claimed `58vw` = 208.8 px of the 328 px
// content box at 360 px; and it carried `overflow-wrap: anywhere`, which is the value that counts
// soft-wrap opportunities in the MIN-CONTENT size and therefore lets a word break inside itself.
// `break-word` does not. Either rule alone is survivable; together they are "Runni / ng".
//
// MEASURED, NOT ESTIMATED. `test/desktop-verify.js` was run in Chromium against the OLD rules,
// with two threads so the picker is on screen, at the width his HONOR X6b reports:
//
//   360 px — the title's box was 80.6 px, "Running" needs 82.4 px, and the word occupied 2 line
//            boxes. At 320 px the box was 70.4 px and it broke there too. At 375 px it did not.
//
// On the new rules the same run reports the box at 328.0 px at 360 px wide, one line box per word.
//
// WHAT THIS FILE CAN AND CANNOT PROVE. It asserts the two rules on the shipped bytes; it does not
// lay anything out. `desktop-verify.js` measures the real thing in a real browser — see its
// `the header at 360 px` section — and it is not part of `npm test` because it needs Playwright.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(ROOT, 'styles.css'), 'utf8');

function rule(selector) {
	const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const found = css.match(new RegExp(`(^|\\n)${escaped}\\s*\\{[^}]*\\}`));
	assert.ok(found, `${selector} is gone from styles.css`);
	return found[0];
}

test('the title is not a flex sibling of anything — it has the row, and the whole width of it', () => {
	// The `<div class="topbar-row">` that held both is gone, and so is its rule.
	assert.doesNotMatch(html, /class="topbar-row"/, 'the title is back in a row with the picker');
	// The RULE, not the word: the comment above `.title` explains the flex row that produced the
	// defect, and a test that forbids naming it forbids explaining it.
	assert.doesNotMatch(css, /(^|\n)\s*\.topbar-row\s*[,{]/, 'the rule that made that row a flex container is still here');

	// The two elements are siblings of the header itself, title first.
	const bar = html.match(/<header class="topbar">[\s\S]*?<\/header>/);
	assert.ok(bar, 'the top bar is gone');
	const titleAt = bar[0].indexOf('id="thread-title"');
	const pickerAt = bar[0].indexOf('id="thread-picker-label"');
	assert.ok(titleAt !== -1 && pickerAt !== -1, 'the title or the picker is gone from the top bar');
	assert.ok(titleAt < pickerAt, 'the picker now comes before the title');
});

test('the title breaks at spaces, never inside a word it could have fitted', () => {
	const title = rule('.title');
	assert.doesNotMatch(
		title,
		/overflow-wrap:\s*anywhere/,
		'`anywhere` lets the element shrink below its longest word — this is half of "Runni / ng"'
	);
	assert.match(title, /overflow-wrap:\s*break-word/, 'a long unbroken URL in a title must still not scroll the page sideways');
	assert.doesNotMatch(title, /min-width:\s*0/, '`min-width: 0` is what let a flex parent squeeze it; there is no flex parent now');
});

test('the word "Conversation" no longer competes with the title it sits under', () => {
	const caption = html.match(/<span class="picker-caption[^"]*"/);
	assert.ok(caption, 'the picker caption is gone entirely — the select then has no label at all');
	assert.match(caption[0], /visually-hidden/, 'the caption is still on screen under a title that says the same thing');
	// It is HIDDEN, not deleted: the select still needs an accessible name.
	assert.match(html, /<span class="picker-caption visually-hidden">Conversation<\/span>/);
});

test('the select cannot claim more of the row than the row has', () => {
	const select = rule('select');
	assert.doesNotMatch(select, /max-width:\s*58vw/, '58vw was sized for a row it shared; it has the row now');
	assert.match(select, /max-width:\s*100%/);
});

test('the picker sits below the title rather than beside it', () => {
	const picker = rule('.picker');
	assert.match(picker, /margin:\s*8px 0 0/, 'nothing separates the picker from the title above it');
});
