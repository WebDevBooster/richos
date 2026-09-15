# First reboot: disk space and identity failure

Free space was approximately 31.6GB just before reboot and 93.76GB afterward.
The additional roughly 62.16GB cannot be attributed precisely: the available
records do not include pre-reboot swap, a complete temporary-directory inventory
or deleted-open-file measurements. Swap was zero afterward and the earlier
`/tmp` artifacts were gone. Production cleanup was inactive.

The separately measured build-cache deletions recovered 17,646,563,328 bytes
before that reboot baseline. Do not add the extra reboot recovery to the
cleaner's measured result or describe it as definitely swap.

The legacy fixture stopped before cleanup with `fixture root was replaced`.
The actual Data filesystem mount number changed from 16777232 to 16777230,
invalidating its numeric-only pins. This is a code defect in durable identity,
not evidence that the fixture was actually replaced. The old fixture is retained
without editing its original records. See [the corrected identity format](../durable-filesystem-identities.md).

The [measured values and failure](workspace-reboot-findings-2026-09-07.json)
record the two real boot UUIDs. The replacement fixture still requires a real
reboot after recording the corrected UUID pins.
