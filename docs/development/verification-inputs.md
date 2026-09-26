# Verification input contracts

`richos/engine/scripts/lib/verification_inputs.py` parses config assignments and
hook entries without executing them. A supported config change identifies keys,
including transitive key references. Hook changes retain command identity,
matcher, ordering and command metadata. Unsupported syntax has an explicit reason
for conservative selection.

`verification-dependencies.json` contains content-bound reader declarations.
Each node names its source, digest, read keys, evidence and executed/source edges.
A copy is a transport, with a dependency on the source file's existence. Its
downstream readers decide which values matter. Fixture replacement and individual
key overrides are explicit. Whole-content checks remain sensitive to all bytes.
Missing or changed declarations remain unresolved for their consumers. Known
direct reads and declared finite indirect aliases are checked against the source.
These checks supplement reviewed contracts; they do not interpret arbitrary shell.

The initial map covers the two finite indirect-key helpers and the two shared
copy regions. Full unit closures and production selector integration are still
pending. Until those are qualified, the existing selector remains authoritative.
Run `bash richos/engine/scripts/verification-inputs.test.sh` for the bounded parser
and dependency fixtures. Do not regenerate source digests to silence a changed
reader without checking its new input and execution relationships.
