# Standard orchestrator pause message

Branch: `codex/standard-pause-message`. Tested code:
`db052bb816dfa366e69e601469220ff0c7ccb6c1`, against `origin/main` at
`261bc268bb87d488407f0b2cc6a88d06a08aff02`.

The terminal and desktop paths prepare the same fixed pause message and validate
its complete body and summary before delivery. The incident's instructions to
end a heavy run and rerun interrupted work are rejected. A sent request is not
reported as confirmation that work has paused. See [the contract](contract.md)
for the exact enforcement boundary, including ordinary free-text messages.

## Verification result

All 45 selected engine units have passing receipts at the same unchanged code
commit. All 88 non-engine top-level checks passed in the completed full run.
Two of those checks wrap native GUI suites that explicitly reported
**NOT RUN (no screen)**: `front-door.test.sh` and `gui-boot.test.sh`.
Browser UI tests, including quota, appearance, affordances, contrast and settings
fit, did run and pass. Native GUI launch is not claimed as tested.

The full selection contained 128 commands, grouped into 91 checks in this run:

```sh
RICHOS_MUTANT_JOBS=2 python3 richos/app/scripts/proof-run.py \
  --keep-going --engine-shards 2 --admission-wait 7200 origin/main..HEAD
```

That invocation **exited 1 after 3,713 seconds**, not 0. Its only unresolved engine
unit was `scripts/hooks/contract-integrity.test.sh:SCR`, which reached its
900-second deadline. The engine-group and receipt checks therefore failed.
The other 44 engine units and all 88 non-engine checks passed. The original
failure is retained; it has not been rewritten as a passing invocation.

The source fingerprint remained identical. After cancelling an unnecessary full
retry, the unresolved unit was run alone with default mutation parallelism:

```sh
env -u RICHOS_MUTANT_JOBS CI_SHARD_UNIT_TIMEOUT=3600 \
  bash scripts/ci-shard.sh \
  --only-units scripts/hooks/contract-integrity.test.sh:SCR \
  --receipt scratch-first-receipt.jsonl
```

It **exited 0 in 493.9 seconds**, including all 51 mutation cases. The original
44 passing receipts and this retry's unmodified receipt were then checked using
the existing `ci-receipts.py verify` command against the original 45-unit plan.
That verification **exited 0: 45/45 planned units, all green, all at the same
commit**. This is a reconciled result across the full run and one targeted retry,
not a claim that a single `proof-run.py` invocation exited 0.

[The result inventory](results.md) records every non-engine check and engine unit.
[Engine receipts](engine-receipts.jsonl) retain their actual exit codes and times.
[The engine plan](engine-units.txt) is the original selected plan.

The Rust fast-set `clippy::let_underscore_must_use` count is 777; Tauri's count is
165. No lint baseline, test assertion or coverage exclusion was relaxed.
`proof-for.sh origin/main..HEAD` also exited 0.

## Why verification took too long

The selector maps `guard-resume-isolation.sh` to every section of the contract
suite because its filename appears in a shared fixture outside the section
bodies. This brings in unrelated work, including scratch-reaper. The comparison
against main also includes the earlier desktop quota and reset implementation.

The execution compounded that breadth by reducing engine groups from the default
five to two and limiting mutation workers to two, then repeating the full
selection. The completed run averaged 49% total CPU usage. The broad claim that
the machine itself was the problem was unsupported. The sole unresolved unit
should have been retried first using the existing receipt-verification mechanism.

Scratch, build caches and evidence were kept on the external SSD. A task-local
`mktemp` adapter made BSD `mktemp -t` respect the task's external `TMPDIR`.
Detailed logs, original timeout evidence, source fingerprints and receipt
provenance are preserved at
`/Volumes/E1TB/reports/richos-standard-pause-message/`.

No real reset was approved or redeemed. No app was installed, branch pushed or
merge performed. The following documentation commit changes no tested code.
