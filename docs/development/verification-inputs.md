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

The map includes finite indirect-key helpers, the two shared copy regions and
reviewed direct, transitive and private-fixture unit closures. Qualification of
the complete incident cohort remains pending.
Run `bash richos/engine/scripts/verification-inputs.test.sh` for the bounded parser
and dependency fixtures. Do not regenerate source digests to silence a changed
reader without checking its new input and execution relationships.

The selector now uses these contracts for config changes. It reads the actual
committed, staged or working versions, follows changed key references and always
selects the global syntax/unknown-key check. `proof-for.sh` preserves that context
and propagates selection failures. A path-only request has no value identity and
uses an explained conservative selection. Unqualified unit closures also remain
explicit conservative selections; full incident-cohort qualification is unfinished.
The ordinary sibling, basename and per-section rules remain in place for other
paths. Shared changes outside a section still select all sections.

`affected-units.test.sh` covers planning without executing selected workloads.
`verification-config.test.sh` validates the real configuration as data, including
the key registry. The source-bound direct-read and literal execute-edge checks
catch known omissions but do not replace review of indirect calls and fixture
provenance. In the reviewed CEO-ask suite, generated configs remain independent
through its nested mutation harness; an invalid helper declaration still prevents
that exclusion.

Hook selection also reads actual before/after snapshots. It selects behavior
consumers of removed and added commands, then retains manifest inventory and
ordering obligations. Reviewed `hook_readers` bind the suite and its helpers to
the command or event scope they inspect. Raw-text registration assertions also
retain their matching lines, so a description or formatting change cannot hide
an input to a grep-based assertion. Unknown readers stay conservative. Unsupported
command syntax selects the full inventory with its reason and is never executed
by the planner.

The additional config closures cover model-ceiling, CEO-input and ruling checks.
Their private fixture settings remain independent of the real config through
their nested helpers and mutations. Literal source-replacement operands require
an explained `literal_keys` declaration tied to the full helper digest. This is
reviewed metadata, not an exemption inferred from a string search.
