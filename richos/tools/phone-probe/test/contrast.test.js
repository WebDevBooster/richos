'use strict';

// WCAG AA, computed, in BOTH themes. `node --test "test/*.test.js"`.
//
// This is a floor that is cleared before handover, not a review note raised afterwards. It is a
// TEST rather than a one-off calculation for one reason: a number in a report is a claim about a
// moment, and a test is a claim about every future edit to styles.css. The app this probe borrows
// its palette from shipped four failing light-mode nodes at 2.95:1, 2.95:1, 3.15:1 and 3.60:1, and
// every one of them looked fine to the people who made them.
//
// The floors (WCAG 2.1 AA, per https://webaim.org/resources/contrastchecker/):
//   4.5:1  normal text
//   3:1    large text — 24px+, or 18.66px+ bold — and non-text UI indicators
//
// Every pair below names the rule in styles.css it comes from, so a pair cannot quietly stop
// matching the stylesheet. There is exactly one declared exemption, at the bottom, and it is
// declared because calling something exempt is a claim that it is skippable.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// ---------------------------------------------------------------------------
// Color math
// ---------------------------------------------------------------------------

function parse(color) {
	const hex = /^#([0-9a-f]{6})$/i.exec(color.trim());
	if (hex) {
		const n = parseInt(hex[1], 16);
		return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 };
	}
	const rgba = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i.exec(color.trim());
	if (rgba) {
		return { r: +rgba[1], g: +rgba[2], b: +rgba[3], a: rgba[4] === undefined ? 1 : +rgba[4] };
	}
	throw new Error(`cannot parse color: ${color}`);
}

// A translucent token has no contrast of its own; it has the contrast of what it lands on. Testing
// the token instead of the composite is how an alpha value passes a checker and fails a user.
function over(fg, bg) {
	const f = parse(fg);
	const b = parse(bg);
	if (f.a === 1) return f;
	return {
		r: f.r * f.a + b.r * (1 - f.a),
		g: f.g * f.a + b.g * (1 - f.a),
		b: f.b * f.a + b.b * (1 - f.a),
		a: 1
	};
}

function luminance(c) {
	const ch = [c.r, c.g, c.b].map((v) => {
		const s = v / 255;
		return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
	});
	return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

function ratio(fg, bg) {
	const a = luminance(over(fg, bg));
	const b = luminance(parse(bg));
	const hi = Math.max(a, b);
	const lo = Math.min(a, b);
	return (hi + 0.05) / (lo + 0.05);
}

// ---------------------------------------------------------------------------
// The two palettes, as they appear in styles.css
// ---------------------------------------------------------------------------

const DARK = {
	ground: '#0c1322',
	'surface-sunk': '#0a1120',
	'surface-raised': '#141e34',
	card: '#182440',
	ink: '#dfe4ee',
	'ink-soft': '#b9c1d2',
	line: 'rgba(76, 96, 135, 0.42)',
	'line-control': '#6b7ea8',
	gold: '#c2a35c',
	'gold-text': '#c2a35c',
	'on-gold': '#0c1322',
	'on-danger': '#0c1322',
	attention: '#e09a55',
	danger: '#e8837c',
	success: '#7fb894',
	'trim-text': '#7e92b8',
	// The QR code's own paper and ink, used by the trust step. Identical in both themes on purpose: a
	// QR code is dark modules on a light quiet zone by specification, and one inverted to match a dark
	// page is one a scanner may refuse.
	'qr-paper': '#ffffff',
	'qr-ink': '#000000'
};

const LIGHT = {
	ground: '#eae6dd',
	'surface-sunk': '#efebe0',
	'surface-raised': '#f7f5ef',
	card: '#fdfcf8',
	ink: '#0c1322',
	'ink-soft': '#4a5265',
	line: 'rgba(60, 70, 95, 0.38)',
	'line-control': '#767c8d',
	gold: '#9c7c34',
	'gold-text': '#715715',
	'on-gold': '#0c1322',
	'on-danger': '#fdfcf8',
	attention: '#8c4a1b',
	danger: '#8a2f28',
	success: '#3a5c46',
	'trim-text': '#44567a',
	// The QR code's own paper and ink, used by the trust step. Identical in both themes on purpose: a
	// QR code is dark modules on a light quiet zone by specification, and one inverted to match a dark
	// page is one a scanner may refuse.
	'qr-paper': '#ffffff',
	'qr-ink': '#000000'
};

// ---------------------------------------------------------------------------
// Every pair the page actually renders
// ---------------------------------------------------------------------------
// `floor` is 4.5 unless the rule's own font-size/weight in styles.css makes it large text, or it
// is a non-text indicator. The size is quoted in `where` so the claim is checkable against the
// stylesheet rather than taken on trust.

const TEXT_PAIRS = [
	// --- on the page ground ---
	{ fg: 'ink', bg: 'ground', floor: 4.5, where: 'body, 17px' },
	{ fg: 'ink', bg: 'ground', floor: 3.0, where: 'h1, 26px (large; also clears 4.5)' },
	{ fg: 'ink-soft', bg: 'ground', floor: 4.5, where: '.lede, 16px' },
	{ fg: 'trim-text', bg: 'ground', floor: 4.5, where: '.build, 15px mono' },
	{ fg: 'ink-soft', bg: 'ground', floor: 4.5, where: '.note, 16px' },
	{ fg: 'ink', bg: 'ground', floor: 4.5, where: '.note strong, 16px' },

	// --- inside a step card ---
	{ fg: 'ink', bg: 'card', floor: 4.5, where: '.step h2, 20px 650 — under 24px so 4.5 applies' },
	{ fg: 'ink', bg: 'card', floor: 4.5, where: '.step p.plain, 16px' },
	{ fg: 'ink-soft', bg: 'card', floor: 4.5, where: '.step p, 16px' },
	{ fg: 'gold-text', bg: 'card', floor: 4.5, where: '.gate, 15px 700 — bold but under 18.66px, so 4.5' },

	// --- the gold accent, carrying dark ink in both themes ---
	{ fg: 'on-gold', bg: 'gold', floor: 4.5, where: '.step-n, 17px 700 — under 18.66px, so 4.5' },
	{ fg: 'on-gold', bg: 'gold', floor: 4.5, where: 'button.primary, 18px 600 — under 18.66px, so 4.5' },
	// 21px at weight 600 clears the 18.66px-bold large-text threshold, so the floor is 3:1. It is
	// asserted at 4.5 anyway: this is the label on the one control the entire probe turns on, read
	// at arm's length while he is talking, and "technically large text" is a poor reason to give the
	// most important string on the page the weaker floor.
	{ fg: 'on-danger', bg: 'danger', floor: 4.5, where: '#record.recording, 21px 600 — large text, held to the normal floor on purpose' },

	// --- raised surfaces: banner, buttons, verdicts ---
	{ fg: 'ink', bg: 'surface-raised', floor: 4.5, where: '.banner, 16px' },
	{ fg: 'attention', bg: 'surface-raised', floor: 4.5, where: '.banner strong / .verdict.ask .label, 16px 700' },
	{ fg: 'ink', bg: 'surface-raised', floor: 4.5, where: 'button, 18px 600' },
	{ fg: 'ink', bg: 'surface-raised', floor: 4.5, where: '.verdict, 16px' },
	{ fg: 'success', bg: 'surface-raised', floor: 4.5, where: '.verdict.pass .label, 16px 700' },
	{ fg: 'danger', bg: 'surface-raised', floor: 4.5, where: '.verdict.fail .label, 16px 700' },
	{ fg: 'trim-text', bg: 'surface-raised', floor: 4.5, where: '.verdict.waiting .label, 16px 700' },
	{ fg: 'ink-soft', bg: 'surface-raised', floor: 4.5, where: '.detail, 15px mono' },

	// --- sunk surfaces: the disabled control, the meter readout, the results box ---
	{ fg: 'trim-text', bg: 'surface-sunk', floor: 4.5, where: 'button:disabled, 18px 600' },
	{ fg: 'ink', bg: 'surface-sunk', floor: 4.5, where: '#results-text, 15px mono' },
	{ fg: 'ink', bg: 'card', floor: 4.5, where: '.meter-read, 16px mono (card is its parent)' },
	{ fg: 'ink', bg: 'card', floor: 4.5, where: '.results h2, 20px' },

	// --- the trust step (check 0), which shares this stylesheet ---
	{ fg: 'on-gold', bg: 'gold', floor: 4.5, where: '.button-link, 18px 600 — the download control; same tokens as button.primary' },
	{ fg: 'gold-text', bg: 'card', floor: 4.5, where: '.plain-link inside .detail on a step card, 15px — underlined, so it is not color alone' },
	{ fg: 'ink', bg: 'card', floor: 4.5, where: '.steps li, 16px — the numbered taps' },
	// The QR code itself. Its modules are a non-text indicator in the strictest sense — everything
	// depends on a camera telling one from the other — so it is held to 3:1 and clears 21:1.
	{ fg: 'qr-ink', bg: 'qr-paper', floor: 3.0, where: '/qr.png modules on their quiet zone, inside .qr' }
];

// Non-text indicators owe 3:1 against what they sit on. A control's border is an indicator: it is
// the only thing saying where the control is.
const INDICATOR_PAIRS = [
	{ fg: 'line-control', bg: 'card', floor: 3.0, where: 'button border, .meter border, #results-text border — all inside .step/.results (card)' },
	{ fg: 'line-control', bg: 'surface-raised', floor: 3.0, where: 'button border against its own fill' },
	{ fg: 'line-control', bg: 'surface-sunk', floor: 3.0, where: '.meter border against the meter track; disabled button border' },
	{ fg: 'success', bg: 'surface-sunk', floor: 3.0, where: '.meter-fill against the .meter track — the live level, the one indicator that must never be ambiguous' },
	{ fg: 'gold', bg: 'card', floor: 3.0, where: '.results border' },
	{ fg: 'gold', bg: 'ground', floor: 3.0, where: '.results border where the card meets the ground; button:focus-visible outline' },
	{ fg: 'gold', bg: 'surface-raised', floor: 3.0, where: 'button:focus-visible outline against a raised control' },
	{ fg: 'attention', bg: 'ground', floor: 3.0, where: '.banner border' },
	{ fg: 'attention', bg: 'surface-raised', floor: 3.0, where: '.banner left border against its own fill' },
	// The verdict stripe sits between the card outside it and its own raised fill, so both sides
	// are checked rather than whichever happened to look better.
	{ fg: 'success', bg: 'card', floor: 3.0, where: '.verdict.pass left border (card side)' },
	{ fg: 'success', bg: 'surface-raised', floor: 3.0, where: '.verdict.pass left border (fill side)' },
	{ fg: 'danger', bg: 'card', floor: 3.0, where: '.verdict.fail left border (card side)' },
	{ fg: 'danger', bg: 'surface-raised', floor: 3.0, where: '.verdict.fail left border (fill side)' },
	{ fg: 'attention', bg: 'card', floor: 3.0, where: '.verdict.ask left border (card side)' },
	{ fg: 'trim-text', bg: 'card', floor: 3.0, where: '.verdict.waiting left border (card side)' },
	{ fg: 'trim-text', bg: 'surface-raised', floor: 3.0, where: '.verdict.waiting left border (fill side)' },
	{ fg: 'line-control', bg: 'ground', floor: 3.0, where: '.meter border where a step is not the parent' },
	// The QR paper's own edge. In the light theme white paper on the ivory ground is 1.2:1 and would
	// have no visible edge at all; the border is the only thing saying where the code ends, and a
	// scanner needs the quiet zone to be seen as part of the code.
	{ fg: 'line-control', bg: 'qr-paper', floor: 3.0, where: '.qr border against the QR paper it encloses' },
	{ fg: 'line-control', bg: 'card', floor: 3.0, where: '.qr border against the step card behind it' }
];

function check(themeName, theme, pairs, kind) {
	const failures = [];
	const rows = [];
	for (const p of pairs) {
		const fg = theme[p.fg];
		const bg = theme[p.bg];
		assert.ok(fg, `${p.fg} missing from ${themeName}`);
		assert.ok(bg, `${p.bg} missing from ${themeName}`);
		const r = ratio(fg, bg);
		const line = `${themeName.padEnd(5)} ${r.toFixed(2).padStart(6)}:1  (floor ${p.floor})  --${p.fg} on --${p.bg}  — ${p.where}`;
		rows.push(line);
		if (r < p.floor) failures.push(line);
	}
	// Printed on every run, pass or fail: the numbers are the deliverable, not the exit code.
	process.stdout.write(`\n--- ${kind}, ${themeName} ---\n${rows.join('\n')}\n`);
	assert.deepStrictEqual(failures, [], `WCAG AA failures in ${themeName}:\n${failures.join('\n')}`);
}

test('text meets WCAG AA in DARK', () => check('dark', DARK, TEXT_PAIRS, 'text'));
test('text meets WCAG AA in LIGHT', () => check('light', LIGHT, TEXT_PAIRS, 'text'));
test('non-text indicators meet 3:1 in DARK', () => check('dark', DARK, INDICATOR_PAIRS, 'indicators'));
test('non-text indicators meet 3:1 in LIGHT', () => check('light', LIGHT, INDICATOR_PAIRS, 'indicators'));

// ---------------------------------------------------------------------------
// The one declared exemption
// ---------------------------------------------------------------------------

test('DECLARED EXEMPTION: --line is a divider, not an indicator, and is still measured', () => {
	// `--line` draws the hairline around `.step` and the rule above `.note`. It is a DIVIDER: it
	// separates two regions that are each already legible, and nothing about the meaning of this
	// page depends on seeing it. It is therefore exempt from the 3:1 indicator floor — which is a
	// claim that it is skippable, so it is declared here rather than left implicit, and the numbers
	// are printed anyway so nobody has to take the claim on trust.
	//
	// It is deliberately NOT applied to `--line-control`, which draws the edge of a button, a text
	// area and the level meter. A control's border is the only thing saying where the control is,
	// so it owes 3:1 and is asserted above in both themes.
	for (const [name, theme] of [['dark', DARK], ['light', LIGHT]]) {
		const onCard = ratio(theme.line, theme.card);
		const onGround = ratio(theme.line, theme.ground);
		process.stdout.write(`\n--- declared exemption, ${name} ---\n` +
			`${name.padEnd(5)} ${onCard.toFixed(2).padStart(6)}:1  --line over --card   (divider, exempt from 3:1)\n` +
			`${name.padEnd(5)} ${onGround.toFixed(2).padStart(6)}:1  --line over --ground (divider, exempt from 3:1)\n`);
		// Still held to something: a divider nobody can see at all is a bug even if it is exempt.
		assert.ok(onCard > 1.3, `--line over --card in ${name} is ${onCard.toFixed(2)}:1 — invisible`);
		assert.ok(onGround > 1.3, `--line over --ground in ${name} is ${onGround.toFixed(2)}:1 — invisible`);
	}
});

// ---------------------------------------------------------------------------
// The tables above must stay tied to the stylesheet
// ---------------------------------------------------------------------------

test('every token in both tables is actually declared in styles.css, with the same value', () => {
	const css = fs.readFileSync(path.join(__dirname, '..', 'public', 'styles.css'), 'utf8');
	// styles.css declares dark at :root and light inside the prefers-color-scheme block; split on
	// the media query so a token is compared against the right theme.
	const splitAt = css.indexOf('@media (prefers-color-scheme: light)');
	assert.ok(splitAt > 0, 'styles.css must carry a light-scheme block — a single-theme page cannot clear a both-themes floor');
	const darkBlock = css.slice(0, splitAt);
	const lightBlock = css.slice(splitAt);

	for (const [themeName, theme, block] of [['dark', DARK, darkBlock], ['light', LIGHT, lightBlock]]) {
		for (const [token, value] of Object.entries(theme)) {
			const re = new RegExp(`--${token}:\\s*([^;]+);`);
			const m = re.exec(block);
			assert.ok(m, `--${token} is not declared in the ${themeName} block of styles.css`);
			assert.strictEqual(
				m[1].trim().replace(/\s+/g, ' ').toLowerCase(),
				value.trim().replace(/\s+/g, ' ').toLowerCase(),
				`--${token} in the ${themeName} block of styles.css is "${m[1].trim()}" but this test computes "${value}" — one of the two is stale`
			);
		}
	}
});
