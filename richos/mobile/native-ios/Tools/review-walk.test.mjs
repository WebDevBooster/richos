// review-walk.test.mjs — the parts of the App Review walk (Tools/review-walk.mjs, CEO §107) that can be
// checked without a simulator, a browser or the live review service. The walk itself is proven by
// running it (`bin/rios review-walk --commit SHA`); these guard what silently breaks it:
//   - the app's step lines are read back exactly (a torn or repeated line never passes a step)
//   - a failure before any step names the first step, and the steps keep the review notes' order
//   - every accessibility identifier the walk's UI test touches still exists in the app's code
//   - a bad commit is refused before anything is leased, built or signed in
//
//   node --test richos/mobile/native-ios/Tools/review-walk.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { appSteps, nextStep, STEPS, APP_STEPS } from './review-walk.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const native = dirname(here);

test('the app half\'s step lines are read exactly; torn and repeated lines are not', () => {
	const dir = fs.mkdtempSync(join(os.tmpdir(), 'review-walk-test-'));
	try {
		const log = join(dir, 'test.log');
		fs.writeFileSync(log, [
			'Test Case started',
			'REVIEW_WALK_STEP {"detail":"","name":"open it in the app","ok":true}',
			'REVIEW_WALK_STEP {"detail":"","name":"open it in the app","ok":false}',
			'REVIEW_WALK_STEP {"detail":"the words differ","name":"six words match and They match on both sides","ok":false}',
			'REVIEW_WALK_STEP {"name":"send a message and see the Demo reply","ok":tr',
			''
		].join('\n'));
		const { steps } = appSteps(log);
		assert.deepEqual(steps.map((s) => [s.name, s.ok]), [[STEPS.open, true], [STEPS.words, false]]);
		assert.equal(steps[1].detail, 'the words differ');
		assert.deepEqual(appSteps(join(dir, 'missing.log')).steps, []);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test('the steps are the review notes\' order, and a failure before any step names the first', () => {
	assert.deepEqual(Object.values(STEPS), ['build the Release app', 'sign in', 'get a pairing link', 'open it in the app',
		'six words match and They match on both sides', 'send a message and see the Demo reply', 'reset the review host']);
	assert.deepEqual(APP_STEPS, [STEPS.open, STEPS.words, STEPS.reply]);
	assert.equal(nextStep([]), STEPS.build);
	assert.equal(nextStep([{ name: STEPS.build, ok: true }]), STEPS.signIn);
});

test('every identifier the walk\'s UI test touches exists in the app', () => {
	const source = fs.readFileSync(join(native, 'UITests/ReviewWalkTests.swift'), 'utf8');
	const used = new Set([...source.matchAll(/any\("([a-zA-Z.]+)"\)|\["(composer\.field)"\]/gu)].map((m) => m[1] || m[2]));
	assert.ok(used.size >= 7, `found only ${[...used].join(', ')}`);
	// Every literal on an identifier line, so `typing ? "composer.send" : ...` counts too.
	const app = execFileSync('grep', ['-rhoE', 'accessibilityIdentifier\\(.*', join(native, 'App')], { encoding: 'utf8' });
	const defined = new Set([...app.matchAll(/"([^"]+)"/gu)].map((m) => m[1]));
	assert.deepEqual([...used].filter((id) => !defined.has(id)), [], 'identifiers the walk uses that the app no longer has');
	// The words are read by their accessibility label, which the app builds as "Word N: word".
	assert.match(fs.readFileSync(join(native, 'App/Features/Pairing/Takeovers.swift'), 'utf8'), /accessibilityLabel\("Word \\\(index \+ 1\): \\\(word\)"\)/u);
});

test('a bad commit is refused before anything is leased, built or signed in', () => {
	const run = spawnSync(process.execPath, [join(here, 'review-walk.mjs'), '--commit', 'not-a-commit-anywhere'], { encoding: 'utf8' });
	assert.equal(run.status, 1);
	assert.match(run.stderr, /not-a-commit-anywhere is not a commit/u);
	assert.doesNotMatch(run.stderr, /waiting for the prepared simulator|building/u);
	const help = spawnSync(process.execPath, [join(here, 'review-walk.mjs'), '--help'], { encoding: 'utf8' });
	assert.equal(help.status, 0);
	assert.match(help.stdout, /rios review-walk --commit <sha>/u);
});
