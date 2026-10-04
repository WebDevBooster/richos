// Where the Playwright package is, for the access page's real-browser sign-in test
// (test/browser-signin.test.mjs) and the automated reviewer walk (native-ios/Tools/review-walk.mjs).

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));

/** The Playwright package: RICHOS_PLAYWRIGHT_DIR, this checkout's UI harness, or the main checkout's. */
export function locatePlaywright(env = process.env) {
	const candidates = [];
	if (env.RICHOS_PLAYWRIGHT_DIR) candidates.push(env.RICHOS_PLAYWRIGHT_DIR);
	const repo = resolve(here, '..', '..', '..');
	candidates.push(join(repo, 'app', 'ui', 'tests', 'node_modules', 'playwright'));
	try {
		const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: here, encoding: 'utf8' }).trim();
		candidates.push(join(dirname(common), 'richos', 'app', 'ui', 'tests', 'node_modules', 'playwright'));
	} catch { /* not in a checkout */ }
	return candidates.find((c) => existsSync(join(c, 'package.json'))) || null;
}
