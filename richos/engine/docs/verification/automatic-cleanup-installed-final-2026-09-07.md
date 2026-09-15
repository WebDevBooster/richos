# Final inactive installed cleanup acceptance

All phases passed for source `e49e902d6bd6c7c2110c569beeac5df8eef0e32d`.
The protected 24-module release is
`264e5dd53a4caa819faf86457a4ba34d56e69876cb95bf8507d88a1d78d46648`.
Its canonical installed manifest SHA-256 is
`af179e8be5ba8a244426f98e129cb27cf8ffc738b391893837adeabfac517143`.

The [complete structured receipts](automatic-cleanup-installed-final-2026-09-07.json)
include every phase and the final `complete` record. The root-owned durable
source receipt is:

```
/Library/Application Support/RichOS/workspace-broker/acceptance-runs/claude-canary-daf3e419a0d643b7b21d4187d54553ec/receipt.jsonl
```

## Results

| Installed phase | Result |
| --- | --- |
| Managed lifecycle, delivery and metadata | 41 checks passed |
| Interrupted creation and raw recovery | 24 checks passed |
| Locked checkout recovery | 7 checks passed |
| Missing-directory registration recovery | 7 checks passed |
| Recreated-path refusal | 4 checks passed |
| Real Claude native plus managed lifecycle | 15 checks passed |

The first two disposable namespaces were removed after strict attachment
checks. Orphan-controller fixtures and the real-Claude fixture remain as
explicitly retained evidence. The Claude fixture has no remaining image
attachments. Retaining these small fixtures is not a claim that their disk
space was reclaimed.

The orphan scenarios ran actual installed capture, retirement, branch
publication and recovery checks. Their controller-only boot seam is explicitly
reported as `tests_cutoff: false`; they are not additional real-reboot tests.
The earlier [actual reboot acceptance](legacy-workspace-uuid-installed-postboot-2026-09-07.md)
remains separate evidence for the unchanged cutoff implementation.

The actual Claude worker delivered commit
`f55dbf52771457483a50184c975a6d6e69aa7747` through managed UUID
`301eb087-71b7-4e88-b995-8dc524707184`. The generated source repository merged
that exact commit after active-image reclamation. The real terminal transaction
persisted its delivery. Native paths, registration and ordinary branches
returned to their recorded baseline. No ordinary source branch was created for
managed delivery.

No WorktreeRemove event record was observed. The report says so explicitly and
does not infer whether the CLI invoked it. Actual cleanup is independently
established by the strict NUL registry, filesystem absence, exact platform-owned
transaction state and branch baseline. The earlier failed event assertion is
[retained unchanged](claude-native-cleanup-event-assumption-2026-09-07.md).

## Readiness and limits

The package was installed **inactive**. The launcher verified that the published
LaunchDaemon, public `client.json` and production broker socket remained absent.
No real repository was gated, no existing worktree or branch was retired and
the candidate branch was not merged.

Sage independently checked the structured receipts against the raw launcher
output and found no missing required evidence. Frank independently verified all
24 installed runtime files against the manifest and candidate, the exact pending
configuration and absence of the live service. Both final reviews were clear.
Canonical `main` remained `7f9077f07c959079323df1fb89367873be6f2b83`, an
ancestor of the accepted candidate, so landing currently permits a fast-forward.

The real CLI used the reviewed copied engine and isolated lifecycle settings.
This does not certify the operator's currently registered canonical engine or
settings already loaded by another session. Production rollout still requires
the [activation sequence](../managed-workspace-activation.md), followed by a
live configured assignment check. Existing backlog migration requires an exact
reviewed selection and coordinated repository downtime.
