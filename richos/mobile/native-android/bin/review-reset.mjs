// review-reset.mjs — the last step of bin/review-walk.mjs: unpair the Google review host from its access
// page, so the real reviewer finds it ready to pair. Kept apart from the walk so a no-device test can
// drive it with a stubbed page (review-reset.test.mjs).
//
// The page's sign-in can have expired by the time the walk gets here (a long walk, a page that signs
// out): then the page shows its sign-in form and no Reset button. This signs in again with the same
// credentials, resets, reads the page back and throws unless the host shows no phone.

/** True when the page is showing its sign-in form, not the host. */
async function signedOut(page) {
	return (await page.locator('input[name=password]').count()) > 0;
}

async function signIn(page, creds) {
	await page.fill('input[name=username]', creds.username);
	await page.fill('input[name=password]', creds.password);
	await page.click('button[type=submit]');
	await page.locator('h2, h1:has-text("Not allowed")').first().waitFor({ timeout: 20_000 });
	const text = await page.locator('body').innerText();
	if (/Not allowed|did not match|Too many sign-in attempts/.test(text) || !text.includes(creds.host)) {
		throw new Error(`the access page's sign-in expired and signing in again failed: ${text.slice(0, 300)}`);
	}
}

/**
 * @param page   a Playwright page (or a stub with the same calls)
 * @param creds  { access, username, password, host }
 * @param walked true when every earlier step passed: the phone is paired, so Reset must be offered
 * @returns the step's detail line
 */
export async function resetReviewHost(page, creds, { walked = true } = {}) {
	const body = () => page.locator('body').innerText();
	await page.goto(creds.access, { waitUntil: 'load' });
	if (await signedOut(page)) await signIn(page, creds);
	const reset = page.getByRole('button', { name: 'Reset this review host', exact: true });
	const canReset = (await reset.count()) > 0;
	if (walked && !canReset) throw new Error(`the page offers no Reset this review host after pairing; ${(await body()).slice(0, 300)}`);
	if (canReset) {
		await page.locator('#reset').check();
		await reset.click();
	} else if (!(await page.getByRole('button', { name: 'Get a pairing link', exact: true }).count())) {
		// A waiting phone (the walk stopped between pairing and the press): They do not match removes it.
		const no = page.getByRole('button', { name: 'They do not match', exact: true });
		if (await no.count()) await no.click();
	}
	// Read the page back from the server, not from the page the click left: the host must show no phone.
	await page.goto(creds.access, { waitUntil: 'load' });
	if (await signedOut(page)) await signIn(page, creds);
	// No phone: either no link, or this walk's unused link (it expires by itself in 5 minutes and
	// pairs nobody; the next reviewer's "Get a new link instead" replaces it).
	await page.locator('button:text-is("Get a pairing link"), button:text-is("Get a new link instead")').first().waitFor({ timeout: 20_000 });
	const text = await body();
	if (/is paired with this review host|A phone reached this review host/.test(text)) throw new Error(`${creds.host} still has a phone after the reset`);
	await page.getByRole('button', { name: 'Sign out', exact: true }).click();
	return canReset ? `pressed Reset this review host on the page; ${creds.host} has no phone and its sample conversations again; signed out`
		: `nothing was paired, so there was nothing to reset; ${creds.host} has no phone; signed out`;
}
