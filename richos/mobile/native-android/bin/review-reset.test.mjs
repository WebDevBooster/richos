// review-reset.test.mjs — the Google review walk's last step (bin/review-reset.mjs, CEO §107) against a
// stubbed access page: no browser, emulator, phone or network.
//   node --test richos/mobile/native-android/bin/review-reset.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { resetReviewHost } from './review-reset.mjs';

const creds = { access: 'https://access.example/', username: 'google-review', password: 'pw', host: 'google-review.example' };

// A stub of the access page: a sign-in form, then the host with or without a phone.
function stubAccessPage({ signedIn, paired, refuseSignIn = false, resetWorks = true }) {
	const site = { signedIn, paired, typed: {}, signOuts: 0, signIns: 0 };
	const text = () => !site.signedIn ? 'Sign in\nUsername\nPassword'
		: `${creds.host}\n${site.paired ? `${creds.host} is paired with this review host` : 'Get a pairing link'}`;
	return {
		site,
		goto: async () => {},
		fill: async (selector, value) => { site.typed[selector] = value; },
		click: async () => {
			if (!refuseSignIn && site.typed['input[name=username]'] === creds.username && site.typed['input[name=password]'] === creds.password) { site.signedIn = true; site.signIns += 1; }
		},
		locator: (selector) => ({
			innerText: async () => text(),
			count: async () => (selector === 'input[name=password]' && !site.signedIn ? 1 : 0),
			check: async () => {},
			first() { return this; },
			waitFor: async () => {}
		}),
		getByRole: (_role, { name }) => ({
			count: async () => (name === 'Reset this review host' && site.signedIn && site.paired ? 1
				: name === 'Get a pairing link' && site.signedIn && !site.paired ? 1 : 0),
			click: async () => {
				if (name === 'Reset this review host' && resetWorks) site.paired = false;
				if (name === 'Sign out') { site.signedIn = false; site.signOuts += 1; }
			}
		})
	};
}

test('the reset signs in again when the access page\'s sign-in has expired, and leaves the host unpaired', async () => {
	const page = stubAccessPage({ signedIn: false, paired: true });
	const detail = await resetReviewHost(page, creds, { walked: true });
	assert.equal(page.site.paired, false, 'the host is still paired');
	assert.equal(page.site.signOuts, 1);
	assert.match(detail, /has no phone/u);
});

test('the reset fails, naming what is wrong, when the host still shows a phone or the sign-in is refused', async () => {
	const stuck = stubAccessPage({ signedIn: true, paired: true, resetWorks: false });
	await assert.rejects(resetReviewHost(stuck, creds, { walked: true }), /still has a phone after the reset/u);
	const refused = stubAccessPage({ signedIn: false, paired: true, refuseSignIn: true });
	await assert.rejects(resetReviewHost(refused, creds, { walked: true }), /signing in again failed/u);
	assert.equal(refused.site.paired, true);
});
