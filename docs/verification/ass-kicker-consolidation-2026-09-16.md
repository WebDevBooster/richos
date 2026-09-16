# ASS Kicker consolidation verification

Date: 2026-09-16. Base: `f81eb2b4706d5b73eb8a28aab264ec3e5beb2287`, the freshly fetched `origin/main` used to create the implementation worktree.

## Result

The three existing control families now live under
[`richos/engine/ass-kicker`](../../richos/engine/ass-kicker/README.md): brief
provenance, brief scope and stated-action analysis. Their owned tests, the
historical acceptance fixture and corpus report moved with them. Three Python
compatibility entry points preserve old command and import paths. Maintained
consumers use the canonical implementations.

Shared hooks, orchestration and Mega Lander keep their existing responsibilities.
Dependency discovery, test sandboxes, installer hash paths, the demo and test
inventory metadata include the new directory. Hook registration and ordering,
state locations, configuration variables and decision policies are unchanged.
CI remains disabled. No live engine installation or nightly build was performed.

## Behavior preservation

- Provenance and scope implementations are byte-identical to the base revision.
- Every function and class in all three implementations compares identically by
  Python AST against the base. The stated-action module's helper-directory
  assignment changes to reach the same shared readers; its corpus comment points
  to the moved report.
- The historical corpus report and acceptance brief are byte-identical to their
  base versions. The brief retains SHA-256
  `76c8eb46b09f9238b714fe6e5b9322a75f8e8611c2612e62dff307b0d7dea16e`.
- Baseline behavioral runs before relocation passed 47 provenance cases,
  53 scope cases and 45 stated-action cases. The moved suites retain those
  outcomes.

## Local checks

Commands below are relative to `richos/engine/`. Behavioral scope runs used
`RICHOS_MUTATION_INNER=1`; its mutation harness ran separately. Mutation runs used
`RICHOS_MUTANT_JOBS=2` where the harness honors it. Results are local macOS
observations, not Linux, Windows or nightly-artifact certification.

| Command (`bash <path>`) | Result |
|---|---|
| `ass-kicker/tests/brief-provenance.test.sh` | 47 passed |
| `ass-kicker/tests/brief-scope.test.sh` | 53 passed |
| `ass-kicker/tests/guard-stated-actions.test.sh` | 45 passed |
| `scripts/hooks/notice-claim-capability.test.sh` | 14 passed |
| `ass-kicker/tests/relocation.test.sh` | 7 tests passed |
| `ass-kicker/tests/brief-scope.mutation.sh` | 11 of 11 mutations detected at their named cases |
| `ass-kicker/tests/stated-actions.mutation.sh` | Intact copied control passed; 31 of 31 mutations detected at their named cases |
| `scripts/hooks/claim-capability-delivery.mutation.sh` | Intact copied control passed; 8 of 8 mutations detected |
| `scripts/lib/hook-dependencies.test.sh` | 14 passed |
| `scripts/lib/mutation-harness.test.sh` | 24 passed |
| `scripts/ci-units.test.sh` | 17 passed; inventory script only, no workflow run |
| `scripts/ci-affected-units.test.sh` | 10 passed; selection script only, no workflow run |
| `scripts/mutation-inventory.test.sh` | 6 passed |
| `scripts/spawn.test.sh` | 32 passed, 0 skipped |
| `scripts/locate-engine.test.sh` | 20 passed |
| `scripts/lib/global-state-witness.test.sh` | 13 passed |
| `scripts/hooks/session-start-stdin.test.sh` | 14 passed |
| `scripts/hooks/root-contract.test.sh` | 29 passed, plus 11 mutation properties proven |
| `scripts/hooks/install-retire-reconciler.test.sh` | 5 passed |
| `scripts/hooks/by-reference.test.sh` | 53 passed |
| `scripts/hooks/engine-status.test.sh` | 20 passed |
| `scripts/demo.test.sh` | 11 passed, including two complete demo runs |

The relocation suite exercises legacy CLI arguments and stdin, nonzero exit-code
preservation, imports sharing canonical module globals, dependency closure,
canonical installation hashes and registration counts. It checks discovery and
selection for moved implementations, old wrappers, adapters and the fixture.
Its copied engine lives in a path containing spaces. It runs the Stop hook's
self-test through the real adapter and the scope suite with the private source
record deliberately unavailable: required cases pass and the optional comparison
is explicitly `NOT RUN`.

The first relocation-suite run exposed a test assertion comparing macOS's `/var`
alias to its resolved `/private/var` path. Resolving the temporary root fixed that
assertion; all seven tests passed on the final run. No runtime behavior changed
for that correction.

The generated demo and integrity-fixture ignore rules were checked with Git after
the final sidecar-path update: canonical `ass-kicker/*.sha256` files are ignored.
Shell syntax checks also passed.

Installation hashes establish file identity relative to installation. This
change does not introduce a new generic runtime tamper detector or claim that a
hash proves the correctness of a control.

## Coverage and delivery limits

The catalog records 61 stable IDs at its source snapshot and supports later
additions. Assessed rows describe bounded behavior of the three existing control
families. Remaining rows are explicitly unassessed in this consolidation, not
implicitly protected. The 55-item marketing selection is separate from these IDs.

No new failure-prevention policy was implemented. In particular, a design
declaration does not prove a design correct and a stop declaration does not prove
that stopping was justified. Corpus metrics remain historical observations.

Full engine verification, remote CI and delivered nightly acceptance were not
run. The application can resolve an existing external engine directory; a later
nightly test must record the actual resolved engine path and source revision, not
assume that a new app binary is executing this change. Nightly acceptance remains
pending until a delivered artifact is tested through that route.
