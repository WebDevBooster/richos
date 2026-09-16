# Neutral import schema 1

This boundary imports synthetic obligations through normal ECS events. Real
legacy extractors, personal-context migration and knowledge/configuration import
are separate work. Unsupported types receive an individual `unsupported` result.
No imported record dispatches a worker, revives a session or enables a hook.

An envelope has exactly `schema`, `batch_id`, `source` and `items`. Source contains
`system`, `namespace`, `revision` and `layout`. These describe the source engine
or adapter without adopting its paths as the destination's architecture. An app
version alone cannot identify independently updated engine contents.

Every item contains:

- `type`, `id` and `digest`
- Explicit `person_id`, `entity_id` and `visibility`
- `created_at` and `observed_at`, each a timestamp with timezone or null for unknown
- `provenance: {ref}` and `evidence: [{ref, available}]`
- `related` source IDs and `supersedes` source ID or null
- `authority`, `confidence` and a type-specific `payload`

The digest is SHA-256 of canonical JSON for the item with `digest` omitted:
sorted keys, UTF-8, no insignificant whitespace and no ASCII escaping. The
`item_digest` helper is the reference encoder. Obligations have payload fields
`title`, `details` and original `status`. ECS visibility is `ceo_private`, `rich`
or `worker`. No visibility conversion is inferred.

`import-preview` takes `envelope` and explicit `target` with person_id, entity_id
and thread_id. It performs no writes even if the destination is absent. Each item
is importable, already_imported, conflicting, unresolved, unsupported or invalid,
with a reason and missing-evidence references. Supersession requires a later
reviewed domain operation and is currently unsupported. Relationships require an
existing mapping in the same target scope and visibility; import dependencies in
order across batches.

`import-apply` takes the envelope and current app binding. Importable obligations
become pending open loops. Their original status, unknown timestamps, evidence
availability and resolved relationships remain source metadata. Missing evidence
is never fetched automatically. Source system, namespace and ID determine stable
identity, so moving an old `engine/` directory under `richos/engine/` does not
duplicate an unchanged record. Changed content or a different target produces a
conflict instead of overwriting an existing record.

The private append-only import receipt records intent before the domain write.
Retries reconcile the normal domain event's idempotency key. Each batch records
individual outcomes and an explicit partial/complete result. A corrupt receipt
journal requires recovery rather than silently skipping bytes. Perform migration
in an isolated destination with a retained backup; there is deliberately no
destructive rollback that could erase subsequent user edits.

The synthetic legacy tests identify public revision
`704b4596d6bacf1757db99ffec2ba17e7b1530e4` for the engine associated with app
v1.0.2. That source has top-level `engine/` and `ceo-wiki/`; it does not have the
later component directories. Source relocation at
`59b492c3d3d4d2b01d216724c2da3596bcaa8252` is tested separately from record identity.
The packaged archive's `engine/` root is a separate contract from source nesting.
