# Independent staging deployment evidence

Each product deployment records the commit observed by its own freshness gate:

```sh
"$ENGINE/scripts/staging-record.sh" --root "$ENTITY" --tree avelor \
    --sha "$OBSERVED_COMMIT" --outcome "$FRESHNESS_GATE_OUTCOME"
```

Call this after the gate completes. A command exit status, background wrapper
completion or a deployment request is not destination evidence. Non-success
outcomes remain unknown. They cannot certify the product as current.

With `STAGING_DEPLOY_RECORD=.claude/state/staging-deployed`, the recorder writes
`.claude/state/staging-deployed.trees/avelor`. Each product has an independent,
atomically replaced file. A successful avelor deploy neither advances fitapp's
commit nor overwrites fitapp's failure record. Nested product paths are encoded
with `%2F` in the sidecar filename. Traversal names are rejected.

The guard checks each product named by a dispatch against that product's record.
A mixed-product dispatch must satisfy both. A deployment from a commit outside
main's ancestry is unknown, even when a commit-count range would be empty.

A pre-existing record containing `tree=avelor` remains valid for avelor when no
avelor sidecar exists. It never certifies a different product. A legacy record
without a tree is usable only when one product tree is declared. Multiple trees
need scoped evidence; existing ambiguous records are not silently migrated.

`staging-record.sh --show` displays all available records. Add `--tree avelor` to
show that product's sidecar. The unscoped legacy file may remain visible but is
superseded for a product once its sidecar exists.

Missing, failed or ambiguous evidence retains the configured adoption behavior:
announce for an in-scope dispatch, or refuse when `STAGING_RECORD_REQUIRED=1`.
Known undeployed product commits refuse an in-scope dispatch. A source-only task
can use the existing explicit `stale-staging-ack: <reason>` line for one dispatch;
this also works for unknown evidence and is recorded in the acknowledgement log.
It does not change any deployment record or carry to another dispatch.
