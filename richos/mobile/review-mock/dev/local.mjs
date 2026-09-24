// The review Worker in Cloudflare's own runtime (workerd, through Miniflare), on loopback, with
// a local Durable Object namespace. Node-only tests do not prove Worker behavior; this does, for
// what workerd can show without a network: bundling, WebCrypto, Durable Object storage, streams.
//
// Nothing is installed. esbuild and Miniflare are taken from the Wrangler already on PATH (as
// `mobile/dev/policy-worker-local.mjs` does), or from RICHOS_WRANGLER_DIR. The bundle is built in
// memory and never written to disk. The workerd process belongs to the returned handle and ends
// with `dispose()`.

import { existsSync, realpathSync } from 'node:fs';
import { dirname, join, delimiter } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const ENTRY = join(here, '..', 'src', 'worker.mjs');

/** The Wrangler package directory, or null when none is installed. */
export function locateWrangler(env = process.env) {
	if (env.RICHOS_WRANGLER_DIR) return existsSync(join(env.RICHOS_WRANGLER_DIR, 'node_modules', 'miniflare')) ? env.RICHOS_WRANGLER_DIR : null;
	for (const directory of (env.PATH || '').split(delimiter)) {
		const bin = join(directory, 'wrangler');
		if (!existsSync(bin)) continue;
		const root = dirname(dirname(realpathSync(bin)));
		if (existsSync(join(root, 'node_modules', 'miniflare')) && existsSync(join(root, 'node_modules', 'esbuild'))) return root;
	}
	return null;
}

/** Bundle the Worker the way Wrangler does (one ES module, workerd conditions), in memory. */
export async function bundle(wrangler) {
	const esbuild = await import(pathToFileURL(join(wrangler, 'node_modules', 'esbuild', 'lib', 'main.js')).href);
	const result = await (esbuild.build || esbuild.default.build)({
		entryPoints: [ENTRY], bundle: true, write: false, format: 'esm', platform: 'neutral', target: 'es2022',
		conditions: ['workerd', 'worker', 'browser'], mainFields: ['browser', 'module', 'main'], logLevel: 'silent'
	});
	return result.outputFiles[0].text;
}

/**
 * Start the bundled Worker. `bindings` are the plain variables and secrets (strings).
 * @returns {Promise<{fetch: (url: string, init?: RequestInit) => Promise<Response>, dispose: () => Promise<void>, compatibilityDate: string}>}
 */
export async function startLocalReview(bindings, wrangler = locateWrangler()) {
	if (!wrangler) throw new Error('Cloudflare local runtime not installed (no Wrangler with Miniflare and esbuild on PATH; set RICHOS_WRANGLER_DIR)');
	const source = await bundle(wrangler);
	const { Miniflare, supportedCompatibilityDate } = await import(pathToFileURL(join(wrangler, 'node_modules', 'miniflare', 'dist', 'src', 'index.js')).href);
	const compatibilityDate = supportedCompatibilityDate < '2026-09-01' ? supportedCompatibilityDate : '2026-09-01';
	const mf = new Miniflare({
		// cf: false keeps Miniflare from downloading Cloudflare's request-metadata file.
		cf: false, compatibilityDate,
		modules: [{ type: 'ESModule', path: 'worker.mjs', contents: source }],
		durableObjects: { HOSTS: { className: 'ReviewHost', useSQLite: true } },
		ratelimits: { LOGIN_LIMIT: { simple: { limit: 20, period: 60 } } },
		bindings
	});
	try {
		await mf.ready;
	} catch (error) {
		await mf.dispose().catch(() => {});
		throw error;
	}
	return { fetch: (url, init) => mf.dispatchFetch(url, init), dispose: () => mf.dispose(), compatibilityDate, bytes: source.length };
}
