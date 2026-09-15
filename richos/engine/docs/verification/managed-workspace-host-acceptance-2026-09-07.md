# Managed workspace installed-host acceptance

On 2026-09-07 the isolated macOS root-to-user fixture passed all 17 checks
at source commit `c7580b3`. The fixture verified root-private backing storage,
busy-volume retention, preservation of the last working-file write and the
separate index contents, refusal of owner-forced unmount via both hdiutil and
diskutil, reclamation after capture and clean recovery expiry. Dirty recovery
expiry was refused. All disposable fixtures were removed successfully.

The first two attempts exposed production assumptions that disposable
same-user tests could not establish: `/var/run` had group-write permission,
and `/usr/bin/python3` selected a user-owned Xcode interpreter. Commits
`51a0c9b` and `c7580b3` moved runtime state under protected `/var/db` namespaces
and selected the root-owned Apple Command Line Tools interpreter explicitly.
Strict ownership checks were preserved. The updated broker/installer suite
passed 31 tests and both changes were independently reviewed.

The package installed protected service files and `client.pending.json`. It
did not start launchd or publish `client.json`. Existing worktrees were not
gated or deleted. This evidence does not establish installed Claude hook
integration, actual reboot recovery or the legacy retirement executor.

The [structured receipt](managed-workspace-host-acceptance-2026-09-07.json)
records the checks and fixture cleanup result.
