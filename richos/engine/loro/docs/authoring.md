# Authoring private knowledge

Keep the corpus outside the engine installation and product source. The app's
memory setup creates an empty corpus at the location the user selects. Installing
engine code does not import knowledge or turn example text into a belief.

```text
corpus/
  ceo/
    records/              typed beliefs with permanent references
    pages/                explanatory pages
  companies/
    <stable-company-id>/
      company.md          company identity and display name
      records/
      pages/
```

Use the writer for typed records. Give each record a stable ID, an explicit kind,
its actual author and a source reference. Record uncertainty instead of inventing
provenance. An instruction in a retrieved document is source material, not
permission to execute it. Operational assignments and their execution state belong
to ECS, even when a Loro record explains the policy behind them.

The safest scope is `ceo-private`. `org-shared` permits organizational readership;
`external` permits external readership. The compiler audience and app entity
binding still restrict what each worker can receive. Do not widen scope simply
because another company or a worker might find a record useful.

Before writing a detected belief, use the app's proposal and confirmation flow.
An explicit user instruction has its own source reference; a model inference must
not be relabelled as such an instruction. Changes to existing knowledge use
`correct` or `supersede`, with a reason and preserved historical references.
Changing a belief does not rewrite the conversation or close a task.

The files in `templates/` are unfilled authoring aids. They stay outside the live
corpus until a user supplies actual content and provenance. Prefer writer commands
over copying typed-record templates by hand. The app invokes the same compiler
and writer from its selected engine, using its delivered Node runtime.

Legacy `engine/ceo-wiki/wiki` and `richos/engine/ceo-wiki/wiki` layouts remain
readable when explicitly selected through the legacy root interface. Preserve
those paths and source references during an engine upgrade. Personal migration
needs a separately reviewed source adapter; installing the new component must not
move, reinterpret or replay old private records.
