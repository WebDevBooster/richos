// THE PAGES A PERSON READS: the access page for reviewers and the one-screen notice a review host
// shows in a browser. Plain HTML, one inline style sheet and one tiny script (copy the link), both
// pinned by hash in a strict Content-Security-Policy. No external requests of any kind.
//
// Contrast (WCAG AA, both themes): every text/background pair below is declared in `PALETTE` and
// `test/pages.test.mjs` computes each ratio. Normal text needs 4.5:1; borders and focus rings 3:1.
// Nothing on these pages is exempt: all of it is meant to be read.

import { sha256 } from './codec.mjs';

/** The two themes. `test/pages.test.mjs` checks every pair listed in `PAIRS`. */
export const PALETTE = {
	light: { bg: '#ffffff', surface: '#f3f4f6', ink: '#16181d', soft: '#474d5a', accent: '#0a58b8', onAccent: '#ffffff', danger: '#a4161a', border: '#757b87', focus: '#0a58b8' },
	dark: { bg: '#111317', surface: '#1c1f25', ink: '#eef0f4', soft: '#b7bdc9', accent: '#8ab4ff', onAccent: '#0b1020', danger: '#ff9b94', border: '#8a909c', focus: '#8ab4ff' }
};

/** [foreground, background, minimum ratio, what it is]. */
export const PAIRS = [
	['ink', 'bg', 4.5, 'body text'],
	['ink', 'surface', 4.5, 'text on a card'],
	['soft', 'bg', 4.5, 'secondary text'],
	['soft', 'surface', 4.5, 'secondary text on a card'],
	['accent', 'bg', 4.5, 'links'],
	['accent', 'surface', 4.5, 'links on a card'],
	['onAccent', 'accent', 4.5, 'button label'],
	['danger', 'bg', 4.5, 'warning text'],
	['danger', 'surface', 4.5, 'warning text on a card'],
	['border', 'bg', 3, 'field and card borders'],
	['border', 'surface', 3, 'field borders on a card'],
	['focus', 'bg', 3, 'focus ring'],
	['focus', 'surface', 3, 'focus ring on a card']
];

const vars = (p) => Object.entries(p).map(([k, v]) => `--${k}:${v}`).join(';');

export const STYLE = `:root{${vars(PALETTE.light)};color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{${vars(PALETTE.dark)}}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:18px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:44rem;margin:0 auto;padding:1.5rem 1.25rem 3rem}
h1{font-size:1.75rem;line-height:1.25;margin:0 0 .5rem}
h2{font-size:1.3rem;margin:0 0 .5rem}
p,li{margin:.5rem 0}
.soft{color:var(--soft)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:1rem 1.25rem;margin:1rem 0}
.warn{color:var(--danger);font-weight:600}
a{color:var(--accent)}
label{display:block;font-weight:600;margin:.75rem 0 .25rem}
input[type=text],input[type=password]{width:100%;font:inherit;color:var(--ink);background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:.6rem .75rem}
button{font:inherit;font-weight:600;color:var(--onAccent);background:var(--accent);border:0;border-radius:8px;padding:.65rem 1.1rem;margin:.5rem .5rem .25rem 0;cursor:pointer}
button:focus-visible,a:focus-visible,input:focus-visible{outline:3px solid var(--focus);outline-offset:2px}
.qr{display:inline-block;background:#ffffff;border-radius:8px;padding:8px;line-height:0}
.qr svg{width:100%;max-width:18rem;height:auto}
.words{font-size:1.2rem;font-weight:600;letter-spacing:.02em}
button.secondary{color:var(--ink);background:var(--surface);border:1px solid var(--border)}
.inline{display:inline}
.check{display:flex;gap:.5rem;align-items:flex-start;font-weight:400}`;

export const SCRIPT = `document.querySelectorAll('[data-copy]').forEach(function(b){b.addEventListener('click',function(){var f=document.getElementById(b.getAttribute('data-copy'));var done=function(){b.textContent='Copied';};if(navigator.clipboard){navigator.clipboard.writeText(f.value).then(done,function(){f.select();});}else{f.select();}});});`;

let csp = null;
async function policy() {
	if (!csp) {
		const b64 = async (text) => btoa(String.fromCharCode(...(await sha256(text))));
		csp = `default-src 'none'; style-src 'sha256-${await b64(STYLE)}'; script-src 'sha256-${await b64(SCRIPT)}'; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`;
	}
	return csp;
}

/** The headers every page carries. */
export async function pageHeaders() {
	return {
		'content-type': 'text/html; charset=utf-8',
		'cache-control': 'no-store',
		'x-content-type-options': 'nosniff',
		'referrer-policy': 'no-referrer',
		'x-frame-options': 'DENY',
		'content-security-policy': await policy()
	};
}

/** Escape text for HTML element content and quoted attributes. */
export function escape(value) {
	return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

export function layout(title, body) {
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>${escape(title)}</title><style>${STYLE}</style></head><body><main>${body}</main><script>${SCRIPT}</script></body></html>`;
}

/** What a review host shows in an ordinary browser: where the app is, and nothing else. */
export function hostPage(hostname) {
	return layout('RichConnect review host', `<h1>RichConnect review host</h1>
<p>This address, <strong>${escape(hostname)}</strong>, is a review demo host for the RichConnect app. It stands in for a Mac running RichOS, with fictional conversations and simulated replies.</p>
<p>To use it, open the RichConnect app and scan the code or paste the pairing link from the review access page. A pairing link opened in a web browser does nothing.</p>`);
}
