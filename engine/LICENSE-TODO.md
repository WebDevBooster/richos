# License — CHOSEN: GNU AGPL v3, unmodified

**Ruled by the owner on 2026-09-04: the RichOS license is the unmodified GNU
Affero General Public License, version 3.**

The license text lives at the repository root in `LICENSE`, byte-identical to
the Free Software Foundation's published text
(<https://www.gnu.org/licenses/agpl-3.0.txt>), sha256
`0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`. It is at the
root deliberately: GitHub's license detection reads only the repository root, so
a `LICENSE` moved anywhere else silently loses the badge that tells a visitor
what they are allowed to do.

**Unmodified means unmodified.** Do not add exceptions, preambles, or a modified
header to that file. A license with local edits is a bespoke license that no
tool recognizes and no lawyer has read.

## What this grants, and what it requires

Anyone may use, study, modify and redistribute this software. The AGPL's
distinguishing term is section 13: if someone runs a modified version and lets
users interact with it **over a network**, those users must be offered the
corresponding source. That is the clause a permissive license does not have, and
it is why this one was chosen.

Copyright remains the owner's. The AGPL binds everyone who receives the software
under it; it does not bind the copyright holder, who may additionally offer the
same code under separate commercial terms to anyone who does not want the
AGPL's obligations.

## The one documented exception

`tools/gpt-exporter/LICENSE` is scoped **only** to the vendored GPT Exporter
Chrome extension in that subdirectory (MIT). MIT is compatible with the AGPL —
that subtree keeps its own notice, as vendored third-party code should.

## Standing obligation for anyone adding a dependency

The AGPL covers the whole combined work. **A dependency whose own license
forbids that combination cannot be bundled**, however convenient it is. Check
before vendoring — proprietary binaries and non-free redistributables are the
usual trap, and the cost of finding out after publication is a re-release.
