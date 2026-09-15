# Installed managed delivery and interrupted creation passed

The protected inactive release `8397310ea1b75b6e48a839d403be70624f964d114d5e820a76dd245ecf83e04b`
from source `4fa95ca` passed 31 managed lifecycle/delivery checks and 24
interrupted-creation checks on 2026-09-07. Every recorded check passed and both
suites removed their exclusively generated storage after attachment checks.

The actual owner client authenticated the installed root broker, committed work
inside a managed image and retrieved the exact delivered commit after normal
unattended image reclamation. That commit merged into the disposable source.
An existing same-name ordinary branch was unchanged; other managed requests
created no ordinary source branches. Existing dirty/clean recovery and shutdown
controls also passed.

The interrupted suite killed its creator at the real attached-before-clone
boundary. Same-boot scans invented no cancellation. A wrong-session request was
refused. After explicit owner cancellation, a live writable descriptor blocked
unforced reclamation. Once its final write was fsynced and closed, normal timer
sweeps captured verified raw recovery and reclaimed original storage. Actual
readonly restoration recovered the final bytes. A separately malformed sparse
image preserved its exact bad plist and binary outer xattr; a request that never
reserved storage finished without an archive or invented byte-reclamation claim.
Retries retained the original request identities. No extra reboot was used.

The first launcher attempt incorrectly used the pretty staged manifest digest
for the compact installed manifest. That formatting mismatch was refused before
fault fixtures were created. The corrected launcher verifies the exact installed
mapping and bytes then uses their digest. It now fsyncs each phase receipt into
protected storage before continuing, including bounded failure diagnostics.
Both suites were repeated to preserve complete direct evidence.

Production remains inactive and the branch is unmerged. Actual Claude lifecycle
wiring and activation remain separate. The actual legacy reboot acceptance
already passed using the unchanged legacy runtime in its original release.

Evidence: [managed31](managed-delivery-acceptance-installed-2026-09-07.json),
[interrupted24](interrupted-creation-acceptance-installed-2026-09-07.json),
[installed release and protected receipt](managed-delivery-installed-release-2026-09-07.json),
[source review](managed-delivery-source-review-2026-09-07.json) and
[launcher correction](installed-acceptance-launcher-correction-2026-09-07.json).
