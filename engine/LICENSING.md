# License — GNU AGPL v3, unmodified

**Ruled by the owner on 2026-09-04: the RichOS license is the unmodified GNU
Affero General Public License, version 3.**

This file was called `LICENSE-TODO.md` while that decision was open. The
decision is closed, so the file is no longer a TODO — but it is still the place
the engine explains its own terms, because the engine is distributed as a
standalone release asset and an asset that carries a license text with no
explanation of scope is only half an answer.

## Where the text lives

**In this repository:** the canonical text is the root `LICENSE`, byte-identical
to the Free Software Foundation's published text
(<https://www.gnu.org/licenses/agpl-3.0.txt>), sha256
`0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`. It is at the
root deliberately: GitHub's license detection reads only the repository root, so
a `LICENSE` moved anywhere else silently loses the badge that tells a visitor
what they are allowed to do.

**In the standalone engine asset:** `app/scripts/make-engine-asset.sh` copies
that same file into the archive, so an extracted engine has `LICENSE` sitting
beside `VERSION` and carries its terms wherever it lands. The archive is opened
and the copy compared to the root text before the build is accepted, so
"byte-identical" is checked rather than claimed. The copy is made at packaging
time rather than committed, because a second committed copy of a license text is
a file that can drift from the canonical one with nothing to catch it.

**Unmodified means unmodified.** Do not add exceptions, preambles, or a modified
header to that file. A license with local edits is a bespoke license that no
tool recognizes and no lawyer has read. Exceptions and scope live here and in
`docs/legal/`, never inside the license text.

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

## What the AGPL here does NOT cover

**Brand material is excluded.** The RichOS name, the mark and wordmark, the
application icons, the banner artwork and the Rich Hand avatar are not licensed
under the AGPL. The exclusion is defined file by file in
`docs/legal/BRAND-ASSETS.md`, which is the document that governs — this
paragraph is a pointer, not the rule.

**Bundled third-party material keeps its own terms.** The engine ships work by
other authors, and each piece stays under the license it arrived with.

## The third-party material inside this engine

`LICENSE-TODO.md` used to say there was exactly **one** documented exception,
the vendored GPT Exporter. That was true when it was written and false by the
time the publication audit read it: the engine now bundles seven separately
licensed items, and an undercount in the file that exists to prevent an
undercount is the worst place for one.

| Path (from this directory) | Upstream | License |
|---|---|---|
| `tools/gpt-exporter/` | WebDevBooster/gpt-exporter | MIT |
| `skills/frontend-design/` | Anthropic, official Claude Code plugin marketplace | Apache-2.0 |
| `skills/android-emulator-qa/` | third-party emulator-QA skill | Apache-2.0 |
| `skills/landing-page-taste/` | Leonxlnx/taste-skill | MIT |
| `skills/landing-page-redesign/` | Leonxlnx/taste-skill | MIT |
| `skills/marketing-strategy-pmm/` | alirezarezvani/claude-skills | MIT |
| `skills/resend/` | resend/resend-skills | MIT |

Every one of those directories carries its own full license text alongside the
work. The authoritative inventory — versions, pinned commits, copyright lines
and the path to each full text — is `docs/legal/THIRD-PARTY-NOTICES.md` in the
repository; packaging copies it into the archive as `THIRD-PARTY-NOTICES.md`
beside `LICENSE`, so the asset is self-contained.

**A table is a thing that drifts.** The list above is a reader's orientation, not
the gate. The gate is that every bundled directory holds its own license file,
and `app/scripts/make-engine-asset.test.sh` refuses an archive in which any one
of them is missing.

## Standing obligation for anyone adding a dependency

The AGPL covers the whole combined work. **A dependency whose own license
forbids that combination cannot be bundled**, however convenient it is. Check
before vendoring — proprietary binaries and non-free redistributables are the
usual trap, and the cost of finding out after publication is a re-release.

Vendoring anything new means three things in the same commit: the upstream
license file next to the work, a row in `docs/legal/THIRD-PARTY-NOTICES.md`, and
a pinned version or commit so the claim can be checked later rather than
believed.
