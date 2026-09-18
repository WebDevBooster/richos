// The service worker. It handles two events and nothing else.
//
// THERE IS DELIBERATELY NO `fetch` HANDLER AND NO CACHE. A probe that serves a cached page is a
// probe that answers questions about the wrong build, and a stale service worker is the classic way
// for that to happen without anybody noticing. Nothing here is offline-capable, on purpose. (An
// installed iOS web app does not require a fetch handler to be installable; the manifest's
// `display: standalone` is what matters, and that is what check 1 measures.)

self.addEventListener('install', (event) => {
	// Take over immediately rather than waiting for the old worker to be released. He will relaunch
	// this app several times during the probe and must never be talking to a previous version.
	event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
	event.waitUntil(self.clients.claim());
});

// ---------------------------------------------------------------------------
// Check 4 — the push arriving with the app closed
// ---------------------------------------------------------------------------

self.addEventListener('push', (event) => {
	// The server sends a payload that is both a plain object and a valid Declarative Web Push
	// document, so `notification` is where the fields live either way. On iOS 18.4+ Safari may
	// render the declared notification itself without ever running this handler; on 16.4-18.3 this
	// handler is the only path. Both are covered rather than whichever one his phone happens to use.
	let payload = {};
	try {
		payload = event.data ? event.data.json() : {};
	} catch {
		// A push with an undecryptable or non-JSON body still has to show something: WebKit's rule
		// is that EVERY push must display a notification, and a handler that shows none can get the
		// subscription revoked. That would present as check 4 failing for the wrong reason.
		payload = {};
	}

	const declared = payload.notification || {};
	const title = declared.title || 'Rich';
	const body = declared.body || 'A test push arrived.';
	const url = declared.navigate || payload.url || '/?from=push';

	event.waitUntil((async () => {
		await self.registration.showNotification(title, {
			body,
			// `tag` plus `renotify` means a second test push replaces the first rather than stacking,
			// so what he sees matches what he last asked for.
			tag: 'richos-probe',
			renotify: true,
			requireInteraction: false,
			data: { url, sentAt: payload.sentAt || null }
		});

		// A second, independent signal that the push landed: documented as working both in the
		// foreground and while handling a push in the background. If the banner is missed, the badge
		// is still on the icon.
		if (self.navigator && self.navigator.setAppBadge) {
			try { await self.navigator.setAppBadge(1); } catch { /* not fatal, and not worth failing the notification over */ }
		}

		// Tell an open window, if there is one, so the page can record the arrival without waiting
		// for a relaunch.
		const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
		for (const client of windows) client.postMessage({ type: 'push-arrived', sentAt: payload.sentAt || null });
	})());
});

// ---------------------------------------------------------------------------
// Check 5 — tapping it opens the app on the right view
// ---------------------------------------------------------------------------

self.addEventListener('notificationclick', (event) => {
	event.notification.close();
	const target = (event.notification.data && event.notification.data.url) || '/?from=push';

	event.waitUntil((async () => {
		if (self.navigator && self.navigator.clearAppBadge) {
			try { await self.navigator.clearAppBadge(); } catch { /* nothing depends on this */ }
		}

		const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
		// If the window is already open, focus it and tell it directly. `navigate()` is not used:
		// it is unreliable in an installed iOS web app, and a postMessage the page acts on is both
		// simpler and observable.
		for (const client of windows) {
			if ('focus' in client) {
				await client.focus();
				client.postMessage({ type: 'notification-clicked', url: target });
				return;
			}
		}
		if (self.clients.openWindow) await self.clients.openWindow(target);
	})());
});
