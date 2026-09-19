'use strict';

// THE THREAD OPENS AT ITS NEWEST MESSAGE AND STAYS THERE. `npm test`.
//
// Ray's candidate .13 walk, defect R2
// (`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260919.2-mac-and-android-audit.md`):
//
//     "He opens Rich on his phone and the thread rests roughly one bubble short of the bottom...
//      Then a message sent from the Mac arrives instantly — and he never sees it, because the view
//      does not move. He has to scroll by hand to discover it."
//
// THE MECHANISM, MEASURED IN A REAL BROWSER AT 360 px (his HONOR X6b's width) rather than guessed
// at. `startConversation` pins the view with `render(true)` while nothing has taken any height
// from the column yet; `refreshPushOffer()` then un-hides the notification offer ABOVE the thread
// and the thread's viewport shrinks by the offer's height. `scrollTop` is measured from the TOP,
// so shrinking a scroller leaves it exactly where it was and moves the visible BOTTOM up. Nothing
// is clamped, no `scroll` event fires, and from then on `render()`'s `wasAtBottom` test answers
// "no" forever — so every message that arrives afterwards lands below the fold.
//
//     the pin     thread 598px tall, bottom = scrollTop 1377 of 1975
//     settled     thread 505px tall (93px offer), scrollTop still 1377   ->  93px short
//
// WHAT THIS FILE CAN AND CANNOT PROVE. It asserts the mechanism on the shipped bytes; it lays
// nothing out, because `npm test` has no browser. `test/desktop-verify.js` measures the real
// thing in a real browser — see its "the thread opens at its newest message" section, whose five
// checks all fail on `a2cef8ee` — and it is not part of `npm test` because it needs Playwright.
//
// EACH ASSERTION BELOW IS A THING THAT WAS TRIED AND MEASURED FAILING, not a style preference.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const app = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');

function body(name) {
	const at = app.indexOf(`function ${name}(`);
	assert.notStrictEqual(at, -1, `${name}() is gone from app.js`);
	const open = app.indexOf('{', at);
	let depth = 0;
	for (let i = open; i < app.length; i++) {
		if (app[i] === '{') depth++;
		else if (app[i] === '}') {
			depth--;
			if (depth === 0) return app.slice(at, i + 1);
		}
	}
	assert.fail(`${name}() has no closing brace`);
}

test('the app remembers whether he is at the bottom rather than re-measuring at the moment it matters', () => {
	assert.match(app, /let pinnedToBottom = true;/,
		'the remembered answer is gone; `atBottom()` alone cannot see a view a RESIZE moved');
	const render = body('render');
	assert.match(render, /forceBottom \|\| pinnedToBottom/,
		'render() decides from `atBottom()` alone again — the exact test that answers "no" once a band has stranded the view');
});

test('something watches the column for the resize that strands the view', () => {
	assert.match(app, /new ResizeObserver\(/,
		'nothing watches the thread for a resize, so a band appearing above it goes unanswered');
	assert.match(app, /threadWatcher\.observe\(\$\('thread'\)\)/,
		'the scroller itself is not observed — that is the box the notification offer takes height from');
	assert.match(app, /threadWatcher\.observe\(\$\('messages'\)\)/,
		'the list is not observed — that is the box a reply growing as it streams changes');
	// AN OBSERVER WITH NO LIVE REFERENCE IS COLLECTABLE, AND A COLLECTED ONE STOPS DELIVERING —
	// silently, and not immediately. Measured exactly that way while this was being built: the
	// first resize of the session was answered and the one that mattered, seconds later, was not.
	assert.match(app, /^let threadWatcher = null;/m,
		'the observer is back to a block-scoped const, which is collectable the moment the block ends');
});

test('only a move that actually leaves the bottom lets go of it', () => {
	// BOTH DIRECTIONS WERE MEASURED WRONG BEFORE THIS ORDER WAS RIGHT.
	//
	//  * `pinnedToBottom = atBottom()` — the obvious form — was cleared by the late scroll event
	//    that `stickToBottom()` itself queues, which is dispatched a frame later, AFTER the offer
	//    has taken its 93 px. Measured `pinned:false, gap:199` at 360 px: the defect intact with
	//    the fix in.
	//  * `if (top < lastScrollTop - 1) unpin` failed the other way. A band DISAPPEARING grows the
	//    viewport and the browser clamps `scrollTop` DOWN to the new maximum, which is a move
	//    upwards by every measure this handler has. It unpinned a reader who had not moved.
	//
	// So the WHERE is asked before the WHICH WAY, and this is that order in the shipped bytes.
	const handler = app.slice(app.indexOf("$('thread').addEventListener('scroll'"));
	const atBottomAt = handler.indexOf('if (atBottom()) pinnedToBottom = true;');
	const directionAt = handler.indexOf('else if (top < lastScrollTop - 1) pinnedToBottom = false;');
	assert.ok(atBottomAt !== -1, 'the handler no longer re-pins a view that is at the bottom');
	assert.ok(directionAt !== -1, 'the handler no longer releases the bottom when he scrolls up');
	assert.ok(atBottomAt < directionAt,
		'the direction test comes first again — that is the order that unpinned a reader whose viewport merely grew');
});

test('the pin computes the bottom rather than writing past the end of it', () => {
	const stick = body('stickToBottom');
	assert.match(stick, /el\.scrollTop = Math\.max\(0, el\.scrollHeight - el\.clientHeight\)/,
		'`scrollTop = scrollHeight` is clamped to the extent the browser has already laid out, which mid-resize is the one from before it');
	assert.match(stick, /pinnedToBottom = true;/, 'pinning no longer records that he is pinned');
});

test('loading earlier messages still keeps his place rather than throwing him to the bottom', () => {
	// The one path that deliberately moves `scrollTop` without wanting the bottom. It runs only
	// with the thread scrolled to its top — where `pinnedToBottom` is false — and this is the
	// guard that says so out loud.
	const older = body('loadOlder');
	assert.match(older, /el\.scrollTop \+= el\.scrollHeight - heightBefore;/,
		'the "keep his place" adjustment is gone from loadOlder()');
	assert.doesNotMatch(older, /stickToBottom\(/,
		'loadOlder() now pins to the bottom, which throws away the place it exists to keep');
});
