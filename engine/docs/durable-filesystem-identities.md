# Durable filesystem identities

The first real reboot fixture exposed a wrong persistence assumption: the Data
volume's `st_dev` changed from 16777232 to 16777230. The test stopped before
cleanup because its unchanged directory no longer matched the numeric pin.
A mount number is useful for a live race or filesystem-boundary check but cannot
identify the filesystem across a Mac reboot.

Persistent identity slots now contain a tagged native volume UUID plus the
existing inode. Fields historically named `device`, and the first entry in
image/archive identity pairs, carry `darwin-volume-uuid-v1:<UUID>` on macOS.
This covers gate metadata, planner and pointer snapshots, capture comparisons,
job scratch, acceptance roots, managed images and archives, source Git stores,
failed-creation inventories and ordinary quarantine records.

The shared helper opens the exact inode without following a final symlink and
queries `fgetattrlist` on that descriptor. It checks lstat/fstat identity before
and after the query, rejects missing, malformed or zero UUIDs and does not cache
mount identities. It supports dangling links without identifying their targets.
Raw `st_dev` still enforces live open/fstat races and same-filesystem traversal.
The actual kernel boot cutoff, ownership, modes, hashes and immutable approved
selection checks remain mandatory.

Linux's fallback explicitly includes the current boot UUID and raw device
number. It does not claim stable identity across Linux boots. The installed
privileged volume and legacy-gate service remains macOS-only.

Numeric-only records are not upgraded by guessing today's UUID. They remain
held for explicit recovery. In particular, the first disposable legacy fixture
is preserved unchanged as failure evidence. A newly prepared fixture must
record UUID identities before its real reboot test. Approved plan or selection
hashes must never be rewritten to make an old snapshot match.

Regression controls simulate consistent kernel device renumbering while still
querying actual native volume UUIDs. They require unchanged plans, successful
frozen capture/restoration and recovery replay. Different UUIDs, changed inodes,
other live devices and old integer pins refuse. The old production versions
fail the new controls. This source evidence does not replace the next real
installed reboot acceptance.

Sage and Frank independently reviewed the final consumer changes with no
remaining findings. Their native regression runs covered legacy planning,
gates, capture, branch cleanup, managed recovery and the installed acceptance
driver. The final retirement review also closed a post-rename error path:
if the UUID query fails, retirement restores the original directory and refuses
before recording completion or pruning Git registration. All 11 recovery
safety tests pass, including the injected native-query failure.
