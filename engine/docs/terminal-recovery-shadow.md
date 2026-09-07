# Captured workspace recovery refs

`terminal-recovery-shadow.py` prepares additive recovery refs under the actual
verified later-boot legacy gate lock. It does not publish refs, remove Git
registrations or erase working directories.

The exact approved selection binds the gate UUID and plan digest, repository
alias, current ref and registration snapshots and a root-private capture path
with its receipt digest. `capture_path` must be canonical with protected
ancestors and independent protected receipt, manifest and archive files.
`approval_kind` is `exact-captured-recovery`.

Preparation independently revalidates the captured archive, source inventory
and complete Git dependency list against the current frozen view. Caller-edited
or truncated dependency declarations cannot authorize fewer recovery refs.
Missing objects, unparsed Git state and external gitlinks refuse preparation.
Every endpoint must exist and trusted Git traverses its complete object closure
with missing-object errors enabled. This is a connectivity check, not a general
repository integrity audit.

Each validated endpoint receives an additive ref under
`refs/richos/recovery/<gate UUID>/<capture receipt SHA256>/<object ID>`.
Commit, tree, blob and tag endpoints are supported. Existing ref bytes are
unchanged and an occupied recovery namespace requires replay of the existing
publication. Git uses the controlled metadata shadow and fixed trusted runtime;
held repository configuration, hooks and external object dependencies are not
loaded. Shared Git objects are read in place and never copied into the artifact.

The returned artifact matches the branch publication file-delta format with
`purpose: captured-recovery`, `retired_branches: []` and a `preserved_objects`
receipt. Every change creates one new recovery ref. `before` is always null.
The separate publication journal must make those refs durable before any
registration removal can proceed. Recovery still requires retaining the
verified capture archive and these refs together. No archive expiry or
registration removal authority is granted by this preparation.
