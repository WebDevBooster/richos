# Loro

Loro owns durable organizational knowledge. Its compiler selects relevant records
for a topic and audience. Its separate writer records corrections with provenance.
It does not own live assignments, worker execution or Git integration.

The component ships code and fictional tests. User knowledge lives in an explicitly
selected private corpus outside the product checkout and engine installation.
An empty corpus contains `ceo/records`, `ceo/pages` and `companies/`. It contains no
sample company facts. Company partitions have stable IDs and editable display names.

```sh
node loro/bin/loro-context.mjs compile --corpus /path/to/private/corpus --topic 'delivery policy'
node loro/bin/loro-write.mjs append --corpus /path/to/private/corpus \
  --id delivery-policy --kind decision --scope org-shared --body-stdin --json
node loro/bin/loro-context.mjs fetch --corpus /path/to/private/corpus \
  --ref rec:ceo/records/delivery-policy
node loro/bin/loro-coverage.mjs report --corpus /path/to/private/corpus
```

`lib/` is read-only and performs no network access. `writer/` owns mutations.
`bin/` contains the command interfaces. The app resolves compiler and writer from
the same selected engine and corpus. A missing component is an error rather than
an empty successful answer.

`--root` explicitly selects a legacy repository-shaped corpus. Both older
`engine/ceo-wiki/wiki` and relocated `richos/engine/ceo-wiki/wiki` directories remain
readable. Their existing path-based references are preserved. Loro does not move
or rewrite adopter files. Raw evidence and unfilled scaffolding are excluded from
compiled knowledge.

Run `node loro/tests/run.js` and `node loro/tests/relocation.js`. The scale explorer
is `node loro/tests/scale.js`. No private repository or existing corpus is required.
See [the context contract](CONTEXT-CONTRACT.md).
