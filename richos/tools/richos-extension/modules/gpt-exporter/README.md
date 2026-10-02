# GPT Exporter module

RichOS Helper 1.1.0 preserves the manual Current, All and New/Updated export
workflows from standalone GPT Exporter 2.2.1. Markdown, JSON, Unicode paths,
project metadata, branch handling, limits, request pacing and ZIP thresholds
remain intact. There is no automatic RichOS ingestion or conversation sync.

`controller.js` registers the module and owns job admission. `runtime.js` adapts
the standalone export workflows. `jobs.js` owns a separate IndexedDB database
for resumable response caches, stable output plans and Chrome download IDs.
`content.js` is injected only when requested on https://chatgpt.com. Tokens stay
in the page bridge and are never persisted. `panel.html` and `panel.js` own the
manual controls. `offscreen.js` owns export URLs and creates dedicated packaging
workers; `packaging-worker.js` owns file and compressed ZIP generation.

Enable ChatGPT export once in its panel to grant that origin access. A job is
pinned to its starting tab and account/workspace. Interrupted jobs require an
explicit Resume action. Completed outputs are reused only while Chrome reports
successful completion and the file still exists. Failed saves never acknowledge
history. Closing the popup does not cancel the job. Starting another export
replaces the prior interrupted job; cancelling never deletes downloaded files.

Call capture and exporter code must not import each other. Shared document
ownership is managed by core. Routine closure respects every lease, recorder
activity and outstanding URLs. Recorder recovery can force a reset; an export
then fails visibly and remains resumable. Export progress never writes the badge
or recorder notifications. Heavy ZIP work runs outside the audio thread.

## Standalone source and migration

`UPSTREAM.json` pins source provenance and exact unchanged file hashes. The
standalone repository owns formatter and library changes; refresh these files
from a reviewed upstream commit rather than editing divergent copies. Preserve
both this module's MIT license and the Helper's AGPL license.

Chrome gives each extension separate storage. Existing Helper recordings and
settings retain their keys. A new exporter module starts with empty history.
Its panel exports/imports a JSON settings/history migration file. To prepare a
file from the old standalone extension, open its service-worker DevTools and run:

```javascript
chrome.storage.local.get(['gpt_exporter_settings', 'gpt_exporter_sync_data'])
  .then(data => copy(JSON.stringify(data, null, 2)))
```

Save the clipboard as a JSON file and import it through the Helper export panel.
Import replaces exporter settings/history only. It cannot repair incorrectly
acknowledged history from older exporter releases. Re-export missing files with
Current or All, or clear exporter history before using New/Updated.

## Verification

`bash richos/app/scripts/extension-gpt-exporter.test.sh` exercises synthetic
workflows, download races, durable caches, migration validation and actual
worker ZIP compression. The existing recorder and browser suites remain
required. An authenticated ChatGPT export and real Zoom coexistence must be
reported separately from routed browser fixtures.
