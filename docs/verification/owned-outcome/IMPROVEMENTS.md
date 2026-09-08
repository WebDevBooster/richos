# Improvements outside this change

Record suggestions here without silently adding them to the implementation scope.

- A separate OS service for execution while RichOS and Claude Code are both fully
  quit. This requires a product lifecycle and permission design; existing work
  remains durable for restart. Closing a process is distinct from a model ending
  a turn. Do not claim this branch installs such a service.
- Consolidate historical policy prose and duplicated notice hooks across the
  engine. Only the dispatch and continuation conflict is addressed here.
- Optimize large history indexing after correctness measurements establish a need.
- Add an installer compatibility preflight for Claude's native wake contract.
  The integration was measured on Claude Code 2.1.263; installation does not
  currently reject older or incompatible versions.
- Remove the existing missing-skills diagnostic from intentionally tool-limited
  auditor leases without hiding a real worker setup failure.
- Strengthen machine-verifiable test-execution provenance. In the final native
  trial the model auditor inferred execution from `__pycache__`, which is not
  proof that tests ran. The acceptance harness executed the tests and two coverage
  mutants itself; that external evidence is what supports the passing claim.
