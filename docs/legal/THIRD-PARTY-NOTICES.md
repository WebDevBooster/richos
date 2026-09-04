# Third-party notices

RichOS bundles work by other authors. Each piece stays under the license it
arrived with, and none of it becomes AGPL by sitting in this repository. This
file is the inventory: what is bundled, where it came from, which revision or
version, who holds the copyright, and where the full terms live.

**Last verified 2026-09-04.** Every provenance claim below was checked against
the named upstream on that date rather than carried forward from a previous
document. Where a check could not be completed, this file says so instead of
rounding up.

**Nine skills were added to this table on 2026-09-04**, on the CEO's express
exception to his own standing rule that a skill carrying no license gets none
added. They are third-party, they were established as such by
`docs/legal/SKILL-PROVENANCE-2026-09-04.md`, and until that day they carried no
license file at all. Each now carries one, taken from its upstream rather than
from a template. The other twelve skills in `engine/skills/` are RichOS-authored
and stay bare, which is correct and deliberate.

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
| `engine/skills/copywriting` | coreyhaines31/marketingskills, `skills/copywriting` | `68f5eaf64e858438db47e436d7a3bef0e9d69721` (2026-03-04) | MIT | 2025 Corey Haines | `engine/skills/copywriting/LICENSE` | modified — 3 of 4 files byte-identical; the fourth differs in 4 lines of spelling, see the note below |
| `engine/skills/customer-research` | coreyhaines31/marketingskills, `skills/customer-research` | `cc1a9c106b1030ae2994167d9160bc51e54e8d26` (2026-03-28) | MIT | 2025 Corey Haines | `engine/skills/customer-research/LICENSE` | modified — 1 of 3 files byte-identical; the other two differ only in indentation and a trailing newline, see the note below |
| `engine/skills/marketing-psychology` | coreyhaines31/marketingskills, `skills/marketing-psychology` | `68f5eaf64e858438db47e436d7a3bef0e9d69721` (2026-03-04) | MIT | 2025 Corey Haines | `engine/skills/marketing-psychology/LICENSE` | byte-identical (both files) |
| `engine/skills/product-marketing-context` | coreyhaines31/marketingskills, `skills/product-marketing-context` | `68f5eaf64e858438db47e436d7a3bef0e9d69721` (2026-03-04) | MIT | 2025 Corey Haines | `engine/skills/product-marketing-context/LICENSE` | byte-identical (both files) |
| `engine/skills/playwright-cli` | microsoft/playwright-cli, `skills/playwright-cli` | `4fafcccadd265f959b41ee8bc87eff7cc607e8e7` (2026-02-06) | Apache-2.0 | Microsoft Corporation | `engine/skills/playwright-cli/LICENSE.txt` | modified — see `engine/skills/playwright-cli/MODIFICATIONS.md` |
| `engine/skills/playwright-e2e-testing` | bobmatnyc/claude-mpm-skills, `toolchains/javascript/testing/playwright` | `a0632b527e53d377e186e16b3b8edb8bc2892a98` (2025-12-31) | MIT | 2025 Claude MPM Contributors | `engine/skills/playwright-e2e-testing/LICENSE` | modified — one line of the single bundled file, see the note below |
| `engine/skills/svelte-code-writer` | sveltejs/ai-tools, `plugins/claude/svelte/skills/svelte-code-writer` | `0e55ee792d3d72fc413162ec6442a0c436ff1294` (2026-03-12) | MIT | 2026 Svelte Contributors | `engine/skills/svelte-code-writer/LICENSE` | byte-identical (1 file) — but the license text is dated after the copy, see the note below |
| `engine/skills/svelte-core-bestpractices` | sveltejs/ai-tools, `plugins/claude/svelte/skills/svelte-core-bestpractices` | `0e55ee792d3d72fc413162ec6442a0c436ff1294` (2026-03-12) | MIT | 2026 Svelte Contributors | `engine/skills/svelte-core-bestpractices/LICENSE` | byte-identical (all 10 files) — but the license text is dated after the copy, see the note below |
| `engine/skills/use-railway` | railwayapp/railway-skills, `plugins/railway/skills/use-railway` | `1b59fd592cd4413f3c325f139bf3f3afa99ee095` (2026-07-09), declaring skill version 1.3.5 | MIT | 2026 Railway Corporation | `engine/skills/use-railway/LICENSE` | modified — 24 lines of roughly 600, enumerated in that file |
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

**`copywriting`.** Three of the four bundled files are byte-identical to the
pinned revision. The fourth, `references/natural-transitions.md`, differs in four
lines, and in nothing but spelling: two headings carry the British `-ising` form
upstream and the American `-izing` form here, each appearing twice. The cause is
in this repository's own history — commit
`06f4a8221a61500b90790383c8359d931391fe4f` (2026-08-30), "docs(prose): US
spelling in engine/scripts, engine/skills and root repo comments". **The
spellings were left as they are.** MIT does not require a modified copy to
disclose the change, and reverting an edit to make a table say "byte-identical"
would be the tail wagging the dog. The row says "modified" because it is.

**`customer-research`.** Word for word identical to the pinned revision; nothing
a reader would call a difference is a word. `SKILL.md` has eight lines whose
leading indentation is four spaces here and three upstream, and
`evals/evals.json` is one byte shorter because the bundled copy has no trailing
newline. `references/source-guides.md` is byte-identical. It is pinned to a
different revision from its three siblings because it did not exist upstream at
theirs: it was created upstream on 2026-03-28 at 06:32 UTC and reached this
project's source repository at 10:53 UTC the same morning.

**`playwright-cli`.** The Apache-2.0 one, and the only one of the nine where the
license imposes conditions beyond carrying the notice. All three that apply are
answered: the license travels (`LICENSE.txt`), the modified file carries a
notice (`MODIFICATIONS.md`, per section 4(b)), and section 4(d) — carry forward
an upstream `NOTICE` — is answered by the fact that upstream publishes none, at
the pinned revision or on `main` today, both listed and checked. The single
modification is an inserted eighteen-line "Headed browser requirement" section
that is RichOS doctrine rather than Playwright's; all seven files under
`references/` are byte-identical. The revision was pinned by fetching all
twenty-six upstream revisions and comparing: at `4fafccc` the references match
and `SKILL.md` differs only by the insertion, and one revision later 57 lines
differ. Upstream's `LICENSE` is CRLF throughout and this repository stores LF,
so the bundled text is the LF form; no character of the license differs and both
hashes are recorded at the top of the file.

**`playwright-e2e-testing`.** One line differs from the pinned revision: a
deprecated `page.type(...)` call replaced by `page.locator(...).fill(...)`.
Nothing else — the frontmatter matches exactly, including the skill name, which
is upstream's own at that revision rather than a local rename. Upstream ships a
`metadata.json` beside the skill declaring `"license": "MIT"`, a second
independent statement of the same grant; it is not bundled.

**`svelte-code-writer` and `svelte-core-bestpractices`.** Both are byte-identical
to `0e55ee7` — all ten files of one, the single file of the other. The thing
worth knowing is about the license rather than the code: **at that revision
`sveltejs/ai-tools` published no license file at all**, at its root or in the
plugin directory, and its root `package.json` is private with no license field.
The `LICENSE` granting MIT was added upstream seven weeks later, on 2026-04-28,
in `1ce957ac72c9b6d1d6086cc2f38254d802caebf7`. That file is what both
directories reproduce, and each says so in its own header. It is upstream's only
statement of its own terms, and it is not a license this project picked on
upstream's behalf. Upstream's copyright line is a Markdown link and is
reproduced as written.

**`use-railway`.** Pinned to the upstream revision that declares skill version
1.3.5 — the version the bundled copy declares in its own text — which is also
the closest by content of all thirty upstream revisions: 24 differing lines out
of roughly 600, against 34 for upstream's current `main`. Pinning it makes the
claim smaller and truer than the provenance document's, which read the skill as
substantially extended in-house on the strength of a commit message and a diff
against today's `main`. Against its actual base it is upstream's file with four
small edits — three punctuation swaps, one added CLI line, one "must" changed to
"should", and one dropped routing step with the renumbering it forced. All four
are enumerated in that directory's `LICENSE`.

**`gpt-exporter`.** Its `LICENSE` reads "Copyright (c) 2026 Alex Booster". It is
the repository owner's own separately published MIT project, vendored here — not
third-party code in the usual sense. It is listed anyway, because a reader
deciding what they may reuse needs the same answer either way, and because
`engine/LICENSING.md` used to describe it as the *only* exception when there are
seven.

### The reason two rows say "modified" that should not have to

`copywriting` is not byte-identical because **this project edited it**, and not
on purpose. The dialect guard enforces American spelling on every file written
in this tree, and it cannot tell a vendored third-party file from one we wrote.
On 2026-08-30 a sweep under that rule
(`06f4a8221a61500b90790383c8359d931391fe4f`) changed four lines in
`engine/skills/copywriting/references/natural-transitions.md`.

**The same sweep changed ten lines in `engine/skills/landing-page-taste/SKILL.md`,
which is also third-party** (MIT, Leonxlnx) and already in the table above. Its
row does not claim byte-identity, so nothing in this file is false — but the row
is quieter than the fact deserves, and a reader comparing that directory against
`72e2995` will find ten differences with nothing here to explain them. Both are
American spelling substitutions of the same kind.

Nothing hazardous follows from either. MIT requires only that the notice travel
with the copy, and it does. What follows is narrower and worth naming: **a guard
that rewrites vendored files will keep manufacturing "modified" rows**, one
sweep at a time, until vendored paths are exempt from it. That is a defect with
a known remedy, it belongs to whoever owns the guard, and it is recorded here
rather than fixed here.

Until it is fixed, the rule is the one this file already follows: **do not revert
the edits to make a row read better.** Record what the tree actually contains.

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

## Compiled dependency inventory — GENERATED, and where it lives

`docs/legal/THIRD-PARTY-RUST-DEPENDENCIES.md` is the per-package inventory of
every Rust dependency that resolves in this repository: 498 distinct
third-party packages across the three workspaces, each with its version, the
license its publisher declares, and whether it reaches a macOS binary at all.

**Every one of them may be distributed as part of an AGPL-3.0-only combined
work.** Nothing in the tree is proprietary and nothing carries terms that
conflict with the AGPL.

The two things the pre-publication audit told us not to round up are answered
there in full rather than summarized here, because a second copy of a legal
finding is a second thing that can go stale:

- **MPL-2.0** — five packages. Reciprocal per file, and section 3.3 expressly
  permits distributing the Larger Work under the GNU AGPL v3 provided no
  covered file carries the Exhibit B notice. None does.
- **`r-efi`** — offered as "MIT OR Apache-2.0 OR LGPL-2.1-or-later". RichOS
  takes the MIT branch, and the package is a UEFI binding that is never
  compiled for either Darwin target. Its two coexisting versions are explained
  there too: the Tauri workspace is deliberately detached and resolves
  independently, and inside it two semver-major lines of `getrandom` coexist.

### Why it can be trusted, which is the part that took the work

Until 2026-09-04 this section said the inventory did **not** exist, and gave a
structural reason: `app/.gitignore` ignored both `Cargo.lock` files, so an
inventory generated on any given morning would have been keyed to whatever
versions resolved that morning on one machine. A license list keyed to versions
nobody can reproduce is not evidence; it is a document that looks like evidence.

Both lockfiles are now tracked. The inventory is generated from them by
`app/scripts/dependency-license-inventory.sh`, which:

- discovers its workspaces as every `Cargo.lock` git tracks, so a fourth Rust
  workspace appears with no edit to the tool;
- reads the **resolved graph** via `cargo metadata --locked`, which refuses to
  run at all if a lockfile would have to change;
- records the sha256 of each lockfile it read, so the document's identity is
  the lockfile rather than a date;
- **refuses to produce a document** if any package declares no license, or
  declares one that has never been reviewed against AGPL-3.0-only. A new
  dependency arriving under unreviewed terms is the event this inventory exists
  to catch, and rendering it as a row saying "unknown" would convert the
  finding into a line of text.

`app/scripts/dependency-license-inventory.sh --check` fails if the committed
document no longer describes the committed lockfiles. Run it after any
dependency change; it is the only way this document can lie.

### What is still open before a binary ships

The audit's wording was "for the actual release bundle", and there is still no
release, tag or signed artifact. Two things therefore remain, and they belong
to the release work rather than to this file:

- **Build the release with `--locked`.** `app/scripts/package-app.sh` invokes
  `cargo tauri build` without it, so a release build would use the committed
  lockfile but would not be *refused* if it had to deviate from it. CI already
  passes `--locked` on both of its cargo steps.
- **Carry these notices inside the artifact.** The engine asset already does
  this and has a packaging test that opens the archive and refuses it when
  license material is missing. The application bundle needs the same.

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
