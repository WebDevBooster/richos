# Third-party notices

RichOS bundles work by other authors. Each piece stays under the license it
arrived with, and none of it becomes AGPL by sitting in this repository. This
file is the inventory: what is bundled, where it came from, which revision or
version, who holds the copyright, and where the full terms live.

**Last verified 2026-09-04.** Every provenance claim below was checked against
the named upstream on that date rather than carried forward from a previous
document. Where a check could not be completed, this file says so instead of
rounding up.

The RichOS-authored software around all of this is AGPL-3.0-only — see
`docs/legal/LICENSING.md`. The RichOS brand material is excluded from both —
see `docs/legal/BRAND-ASSETS.md`.

## How to read the "Verified" column

- **byte-identical** — every bundled file was fetched from the named upstream
  revision and compared byte for byte on the date above.
- **modified** — the bundled copy differs from upstream, and the difference is
  written down in the directory alongside the work.
- **by version** — the upstream project publishes versioned skills rather than
  a stable path history, so the bundled copy is identified by the version it
  declares in its own frontmatter. The body was compared to the nearest
  upstream revision and the differences are stated in the row.

## Bundled skills and tools — redistributed inside the engine

| Work | Upstream | Revision / version | License | Copyright | Full terms | Verified |
|---|---|---|---|---|---|---|
| `engine/skills/frontend-design` | anthropics/skills, `skills/frontend-design` | `00756142ab04c82a447693cf373c4e0c554d1005` (2025-12-04) | Apache-2.0 | Anthropic | `engine/skills/frontend-design/LICENSE.txt` | modified — see `engine/skills/frontend-design/MODIFICATIONS.md` |
| `engine/skills/android-emulator-qa` | openai/plugins, `plugins/test-android-apps/skills/android-emulator-qa` | plugin v0.1.2, `42e54808e826d2002f73d85d6538c144dd805059` (2026-03-25) | MIT | OpenAI | `engine/skills/android-emulator-qa/LICENSE.txt` | byte-identical (all 3 files) |
| `engine/skills/landing-page-taste` | Leonxlnx/taste-skill, `skills/taste-skill` | `72e299530e2eb31ed8da06181bc19f6c18a00821` | MIT | 2026 Leonxlnx | `engine/skills/landing-page-taste/LICENSE` | pinned in `SKILL.md`, below a scope pin |
| `engine/skills/landing-page-redesign` | Leonxlnx/taste-skill, `skills/redesign-skill` | `72e299530e2eb31ed8da06181bc19f6c18a00821` | MIT | 2026 Leonxlnx | `engine/skills/landing-page-redesign/LICENSE` | pinned in `SKILL.md`, below a scope pin |
| `engine/skills/marketing-strategy-pmm` | alirezarezvani/claude-skills, `marketing-skill/skills/marketing-strategy-pmm` | version 1.0.0 (frontmatter, updated 2025-10-20) | MIT | 2025 Alireza Rezvani | `engine/skills/marketing-strategy-pmm/LICENSE` | by version — see the note below |
| `engine/skills/resend` | resend/resend-skills, `skills/resend` | version 3.5.0 (frontmatter) | MIT | 2026 Resend | `engine/skills/resend/LICENSE` | by version — see the note below |
| `engine/tools/gpt-exporter` | WebDevBooster/gpt-exporter | vendored copy | MIT | 2026 Alex Booster | `engine/tools/gpt-exporter/LICENSE` | the repository owner's own separately published project |

### Notes on the rows that are not byte-identical

**`frontend-design`.** One word differs from the pinned upstream revision:
`retro-futuristic,` is absent from the bundled `SKILL.md` line 15. Apache-2.0
section 4(b) requires a modified file to carry a notice that it was changed,
and `MODIFICATIONS.md` in that directory is that notice. Its `LICENSE.txt` was
missing entirely until 2026-09-04 while the skill's own frontmatter said
"Complete terms in LICENSE.txt" — a citation pointing at nothing. The file is
now present and byte-identical to upstream.

**`android-emulator-qa`.** This directory previously carried the **Apache
License 2.0**, which nobody upstream ever granted. `openai/plugins` publishes
no LICENSE file at all; the grant of record is the upstream plugin manifest
`plugins/test-android-apps/.codex-plugin/plugin.json`, which declares
`"license": "MIT"` with author `OpenAI`. The bundled `SKILL.md`,
`scripts/ui_pick.py` and `scripts/ui_tree_summarize.py` were each fetched from
the pinned revision and compared: all three byte-identical. The license file
now carries the MIT terms and records where the claim was read from.

**`marketing-strategy-pmm`.** The bundled `SKILL.md` is a single 38 KB file.
Upstream ships a 12 KB `SKILL.md` plus four files under `references/`
(`international-gtm.md`, `launch-checklists.md`, `messaging-templates.md`,
`positioning-frameworks.md`), so the bundled copy is a consolidated form of the
upstream skill rather than a byte copy of any one file. MIT permits that and
requires only that the copyright notice and permission notice travel with it,
which the restored `LICENSE` does. The directory carried **no** MIT notice at
all before 2026-09-04.

**`resend`.** The bundled copy declares version 3.5.0; upstream is now 3.7.0.
Compared against the upstream revision that also declared 3.5.0
(`3553a52065b48240c7786332fa431d4cd6f39d36`), the bundled body differs in one
line — the HTTP 429 row of the error table, where the bundled copy carries the
*newer* rate-limit wording — and in the frontmatter `metadata` block, which
upstream has since extended. The bundled copy is therefore a 3.5.0-era release
taken through a distribution channel other than that commit, and is recorded by
version. The directory carried no MIT notice before 2026-09-04.

**`gpt-exporter`.** Its `LICENSE` reads "Copyright (c) 2026 Alex Booster". It is
the repository owner's own separately published MIT project, vendored here — not
third-party code in the usual sense. It is listed anyway, because a reader
deciding what they may reuse needs the same answer either way, and because
`engine/LICENSING.md` used to describe it as the *only* exception when there are
seven.

## Bundled fonts — redistributed inside the application

All four families are under the **SIL Open Font License 1.1**, whose only
material conditions are that the fonts are not sold on their own, that the
copyright and license notice travel with them, and that a derived font is not
released under the reserved font name. RichOS satisfies all three: the fonts
ship as part of the application, the notices below are in the tree beside the
files, and nothing is renamed or re-released.

| Family | Files | Copyright | Full terms |
|---|---|---|---|
| Inter | `Inter-Variable.woff2`, `Inter-Italic.woff2` | 2016 The Inter Project Authors (<https://github.com/rsms/inter>) | `app/ui/fonts/LICENSE-Inter.txt` |
| Newsreader | `Newsreader-Regular.woff2`, `Newsreader-Italic.woff2` | 2020 The Newsreader Project Authors (<http://github.com/productiontype/Newsreader>) | `app/ui/fonts/LICENSE-Newsreader.txt` |
| Noto Sans Math | `NotoSansMath-subset.woff2` | 2022 The Noto Project Authors (<https://github.com/notofonts/math>) | `app/ui/fonts/LICENSE-NotoSansMath.txt` |
| Noto Sans Symbols | `NotoSansSymbols-subset.woff2`, `NotoSansSymbols2-subset.woff2` | 2022 The Noto Project Authors (<https://github.com/notofonts/symbols>) | `app/ui/fonts/LICENSE-NotoSansSymbols.txt` |

The Noto files are **subsets**. Subsetting is a modification the OFL allows; the
reserved-font-name clause is not engaged because the subsets keep the original
names and are not redistributed as a separate font product.

## Authoring-time tools — used to build artifacts, not redistributed

These never reach a user. They are recorded because "we do not ship it" is a
claim worth being able to check.

| Tool | License | Where it is used |
|---|---|---|
| Pillow | MIT-CMU | `app/scripts/generate-app-icons.sh` and `app/scripts/lib/app_icons.py` — decode, resample, PNG and ICO writing for the application icon set |
| Apple `iconutil` | Apple system tool | `.icns` assembly, same script |
| Playwright | Apache-2.0 | `app/ui/tests` — a devDependency of the browser acceptance harness. Not part of any bundle; excluded from the shipped frontend by `app/src-tauri/build.rs` and gated by `app/scripts/frontend-payload.test.sh`. |

## Compiled dependency inventory — NOT YET GENERATED, and why

The pre-publication audit inspected dependency metadata for 108 packages in the
app workspace, 498 in the Tauri workspace and 11 in the native probe, and found
no obviously proprietary dependency. It also flagged two things that must be
recorded accurately rather than rolled into the AGPL claim: the **MPL-2.0**
packages in the tree, and **`r-efi`**, which offers an LGPL alternative
alongside permissive ones.

A per-package inventory is **not** published here yet, and the reason is
structural rather than an oversight:

1. **Neither `Cargo.lock` is tracked.** `app/.gitignore` ignores both. An
   inventory generated today would be pinned to whatever versions resolved on
   this machine this morning — and the two untracked lockfiles on the
   development machine already disagree with each other, carrying `r-efi`
   5.3.0 and 6.0.0 in the Tauri workspace and 6.0.0 in the app workspace. A
   license list keyed to versions nobody can reproduce is not evidence; it is a
   document that looks like evidence.
2. **There is no release bundle to inventory.** The audit's own wording is "for
   the actual release bundle", and no release, tag or signed artifact exists.

**So this is a gate, not a TODO.** Before any RichOS binary is distributed:
track and commit both lockfiles, generate the inventory from them with a tool
that reads the resolved graph rather than the manifests, review the MPL-2.0 and
`r-efi` entries explicitly, and add the result to this file with the lockfile
digests it was generated from.

Nothing above blocks publishing the **source**. The AGPL obligations attach to
what this repository contains, and every bundled work in it is named here with
its terms.

## Adding something new

Vendoring anything means three things in the same commit:

1. the upstream license file next to the work,
2. a row in this table with a pinned revision or a declared version, and
3. if the bundled copy differs from upstream at all, a notice in that directory
   saying how — required by Apache-2.0 section 4(b), and good manners
   everywhere else.

A dependency whose own license forbids combination with the AGPL cannot be
bundled, however convenient it is.
