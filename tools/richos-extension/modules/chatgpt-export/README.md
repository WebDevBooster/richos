# Module seam: `chatgpt-export` (not implemented yet)

This directory is an intentional empty seam. The existing standalone **GPT Exporter**
extension (`engine/tools/gpt-exporter/`) folds in here as a second RichOS module in a later
pass — both it and call capture are loro capture channels, so the CEO should install **one**
RichOS extension, not two tools.

**Do not port it as part of the call-capture work.** That is a separate task.

## What the port looks like when it happens

Register a module object with the core registry, exactly like `modules/call-capture/`:

```js
export const chatgptExportModule = {
  id: 'chatgptExport',
  label: 'ChatGPT export',
  defaults: { /* … */ },
  settingsSchema: { title: 'ChatGPT export', fields: [ /* … */ ] },
  init, onMessage, getStatus,
};
```

and it inherits, without duplicating any of it:

| Core service | File | What the export module reuses it for |
|---|---|---|
| Namespaced settings + generic options UI | `core/settings.js`, `options/options.js` | its own settings section, rendered from `settingsSchema` |
| Drop-zone writer | `core/output.js` | writing `.md` / `.zip` output into the same drop folder |
| Offscreen document (blob URLs, DOM work) | `core/offscreen-host.js`, `core/offscreen.js` | building files without a visible tab |
| Alerts + badge health indicator | `core/alerts.js` | progress/failure signalling |
| IndexedDB | `core/idb.js` | its own object stores (add them to `DB.stores`) |

## Migration notes for the porter

- The standalone extension has its own content script for `chatgpt.com`; add it to
  `manifest.json` under `content_scripts` — the shell manifest is shared by all modules.
- Its download logic must move to `core/output.js` so there is still exactly one place that
  writes bytes out of the browser.
- Keep its deliberate slow-download pacing; that behaviour is a feature, not a defect.
- Bump the extension `version` in `manifest.json` in the same commit as the port.
