# Skill provenance — `engine/skills/`, 2026-09-04

`engine/skills/` holds **27 skills**. Six were already documented in
`docs/legal/THIRD-PARTY-NOTICES.md` as third-party. This pass answers the
question the other twenty-one left open: **for each of the 27, did RichOS write
it?**

**This document determines and records. It changes nothing else.** No skill was
deleted, moved or edited; no license file was added; no notices row was added.
Per the CEO's ruling of 2026-09-04 — skills that already carry a license keep
it, skills that carry none get none added unless he says otherwise — the only
action this pass produces is the list in the final section, which is his to rule
on.

## Result in one line

**Fifteen of the 27 are third-party.** Six were already known and licensed. The
other **nine were not known to be third-party and carry no license file**; all
nine are permissively licensed upstream (eight MIT, one Apache-2.0), and every
one of the nine is named with its upstream and its evidence in the last section.
The remaining **twelve are RichOS-authored**, eleven at high confidence and one
(`ui-ux-design`) at medium-high with the doubt written out.

## How this was established

Four independent methods. Each row below says which one settled it.

1. **Byte comparison against a pinned upstream revision.** Where an upstream
   repository could be identified, the file was fetched from a revision dated
   near the acquisition date and compared byte for byte. This is the strongest
   evidence available and it settled seven of the nine new findings.
2. **Arrival history in the two repositories that actually hold it.** This
   repository's git history **cannot answer provenance for anything predating
   2026-08-20** — the history was rewritten on 2026-08-29, and the oldest
   surviving commit is `2e82948`, the `git mv kit/ -> engine/` rename, which
   introduces 80 skill files in one move. The real record lives in two other
   trees on the owner's machine: the product repository `femcboost`, where most
   of these skills first landed between 2026-03 and 2026-08, and the
   orchestration-kit repository from which this engine was extracted on
   2026-07-14. Both were read.
3. **Dangling sibling references.** A skill that tells the reader to "see
   `page-cro`" came from somewhere that had a `page-cro`. Every skill name
   mentioned in every `SKILL.md` was enumerated and checked against this tree.
4. **Verbatim prose search of public code.** Distinctive sentences were searched
   against GitHub's public code index. A hit is decisive; **a miss is supporting
   evidence only** — that index covers public repositories and is not
   exhaustive, so "no public copy found" is never on its own a claim of
   authorship. Where a verdict of RichOS-authored rests partly on a miss, it
   also rests on an arrival commit and on engine-internal vocabulary
   (`${APP_ROOT}`, `orchestration.config`, `TaskUpdate`, `ceo-wiki/`, the
   orchestrator and land vocabulary) that no external skill would contain.

A fifth source was checked and produced nothing: **there is no vendoring ledger
anywhere in the record.** The only vendoring event ever written down as such is
`landing-page-taste` and `landing-page-redesign`, and it was written down in a
commit message (`c076d4c` here, `f3fad6fb5` in `femcboost`), not in a document.
That absence is itself a finding: it is why twenty-one skills reached a
publication audit with their origins unrecorded.

## The dangling-sibling signal, and what it turned out to be

Four skills — `copywriting`, `customer-research`, `marketing-psychology`,
`product-marketing-context` — point the reader at siblings that **do not exist
in this tree**: `email-sequence`, `popup-cro`, `copy-editing`, `page-cro` and
`ab-test-setup`.

At revision `68f5eaf64e85` of `coreyhaines31/marketingskills`, `skills/`
contains 32 directories, and among them are **exactly** `email-sequence`,
`popup-cro`, `copy-editing`, `page-cro` and `ab-test-setup`. Three of the four
skills are byte-identical to that revision. The signal was right, and it named
the source.

`svelte-code-writer` carries the same signature — it instructs the reader to run
inside a `svelte-file-editor` agent that does not exist here. That agent is
`sveltejs/ai-tools`, `plugins/claude/svelte/agents/svelte-file-editor.md`.

## The 27 skills

Confidence is one of **certain** (byte-identical or near-identical to a named
upstream revision), **high**, or **medium-high** (verdict stated with its doubt).

### Third-party — already licensed and documented before this pass

| Skill | Verdict | Confidence | Upstream | Evidence that settled it |
|---|---|---|---|---|
| `android-emulator-qa` | third-party | certain | `openai/plugins`, `plugins/test-android-apps/skills/android-emulator-qa`, MIT (OpenAI) | Already verified byte-identical on 2026-09-04 and recorded in `docs/legal/THIRD-PARTY-NOTICES.md`. Arrived `femcboost` `a40015065` (2026-04-15) with its `LICENSE.txt`. |
| `frontend-design` | third-party | certain | `anthropics/skills`, `skills/frontend-design`, Apache-2.0 (Anthropic) | Already recorded in the notices, with `MODIFICATIONS.md` for the one-word divergence. Arrived `femcboost` `2d7355b51` (2026-03-28). |
| `landing-page-redesign` | third-party | certain | `Leonxlnx/taste-skill`, `skills/redesign-skill` @ `72e2995`, MIT | Already recorded. Its vendoring is the one event with an explicit written record: `c076d4c` here, `f3fad6fb5` in `femcboost`, both naming upstream, revision, license and the CEO greenlight. |
| `landing-page-taste` | third-party | certain | `Leonxlnx/taste-skill`, `skills/taste-skill` @ `72e2995`, MIT | Same commit, same record. |
| `marketing-strategy-pmm` | third-party | high | `alirezarezvani/claude-skills`, `marketing-skill/skills/marketing-strategy-pmm`, version 1.0.0, MIT | Already recorded. See the note below — this pass found a reason to look again at the attribution, and it survived. |
| `resend` | third-party | certain | `resend/resend-skills`, `skills/resend`, version 3.5.0, MIT | Already recorded. The skill's own frontmatter declares `source: https://github.com/resend/resend-skills`. |

**Note on `marketing-strategy-pmm`.** This pass established that
`alirezarezvani/claude-skills` is itself downstream of
`coreyhaines31/marketingskills` for its marketing pack: its
`marketing-skill/skills/` listing is the 2026-03 snapshot of Corey Haines's
`skills/` (the same names, including `ab-test-setup`, `page-cro`, `popup-cro`,
`email-sequence`, `copy-editing`), and its `copywriting/SKILL.md` carries
`author: Alireza Rezvani` over a body that is Corey Haines's. That is a reason to
distrust an attribution to Alireza Rezvani. **It does not overturn this row.**
`marketing-strategy-pmm` has no counterpart in Corey Haines's repository at any
revision checked, and its own frontmatter declares `updated: 2025-10-20`, which
predates the creation of `coreyhaines31/marketingskills` (2026-01-15). The
existing notices row stands as written.

### Third-party — established by this pass, no license file present

| Skill | Verdict | Confidence | Upstream | Evidence that settled it |
|---|---|---|---|---|
| `copywriting` | third-party | certain | `coreyhaines31/marketingskills`, `skills/copywriting` @ `68f5eaf64e85` (2026-03-04), MIT, Copyright (c) 2025 Corey Haines | **Byte-identical.** `SKILL.md` (7,533 bytes), `evals/evals.json` and `references/copy-frameworks.md` all match that revision exactly. `references/natural-transitions.md` differs in **four lines only**, every one of them a local Americanization of upstream's British spelling (`Emphasising` to `Emphasizing`, `Summarising` to `Summarizing`). |
| `customer-research` | third-party | certain | `coreyhaines31/marketingskills`, `skills/customer-research` @ `cc1a9c106b10`, MIT, Corey Haines | Identical **word for word**; the only differences are eight lines whose leading indentation is four spaces rather than three. The timeline is decisive: the skill was created upstream at 2026-03-28 06:32 UTC and arrived in `femcboost` at 2026-03-28 10:53 UTC (`2d7355b51`), four hours later. It did **not** exist upstream at the 2026-03-04 revision, which is why it is the only one of the four not matched there. |
| `marketing-psychology` | third-party | certain | `coreyhaines31/marketingskills`, `skills/marketing-psychology` @ `68f5eaf64e85`, MIT, Corey Haines | **Byte-identical** (21,739 bytes). |
| `product-marketing-context` | third-party | certain | `coreyhaines31/marketingskills`, `skills/product-marketing-context` @ `68f5eaf64e85`, MIT, Corey Haines | **Byte-identical** (7,561 bytes). Upstream has since renamed the skill to `product-marketing`, which is why a search of upstream's current tree finds no such name — the rename is itself corroboration of the era our copy came from. |
| `playwright-cli` | third-party | certain | `microsoft/playwright-cli`, `skills/playwright-cli`, **Apache-2.0** (Microsoft) | Upstream ships this skill at that exact path with a `references/` directory, and **all seven of our reference files match upstream's names exactly** (`request-mocking`, `running-code`, `session-management`, `storage-state`, `test-generation`, `tracing`, `video-recording`), upstream having since added two more. Our `description` and `allowed-tools` frontmatter match upstream's 2026-02 revision verbatim. The copy **as acquired** (`femcboost` `cf43ddd10`, 2026-03-27) had **CRLF line terminators** — a downloaded-package artifact, not hand-authored text. **Locally modified:** the "Headed browser requirement" section was added in `femcboost` `88ee99d4c` (2026-04-01) and encodes RichOS doctrine, not Playwright's. |
| `playwright-e2e-testing` | third-party | certain | `bobmatnyc/claude-mpm-skills`, `toolchains/javascript/testing/playwright`, MIT, "Claude MPM Contributors" (2025); the skill's own `metadata.json` declares `"license": "MIT"` | Differs from upstream in **four lines total**: the `name` (`playwright` becomes `playwright-e2e-testing`), two dropped frontmatter keys, and one code line. Upstream's own frontmatter contains the string `"When writing tests, implementing playwright-e2e-testing, ..."` — our renamed skill's name appears **inside upstream's file**, which cannot happen in the other direction. The doubled frontmatter block and the `progressive_disclosure` / `token_estimate` convention are that pack's signature throughout. |
| `svelte-code-writer` | third-party | certain | `sveltejs/ai-tools`, `plugins/claude/svelte/skills/svelte-code-writer`, MIT, Copyright (c) 2026 Svelte Contributors | Identical to upstream apart from **heading capitalization and one added H1**. Independently corroborated by a contemporaneous internal record: the source project's own role-research document cites this skill four times as `https://skills.sh/sveltejs/ai-tools/svelte-code-writer`. Its dangling `svelte-file-editor` reference resolves to `sveltejs/ai-tools`, `plugins/claude/svelte/agents/svelte-file-editor.md`. |
| `svelte-core-bestpractices` | third-party | certain | `sveltejs/ai-tools`, `plugins/claude/svelte/skills/svelte-core-bestpractices` @ `0e55ee792d3d` (2026-03-12), MIT, Svelte Contributors | **Byte-identical** to that revision (7,195 bytes). The nine `references/*.md` files carry upstream's original filenames (`@attach.md`, `$inspect.md`, `@render.md`), which upstream has since renamed — our copy preserves the older spelling. |
| `use-railway` | third-party base, substantially extended in-house | certain (origin) | `railwayapp/railway-skills`, `plugins/railway/skills/use-railway`, MIT, Copyright (c) 2026 Railway Corporation | The origin is stated **in our own commit record**: `femcboost` `16b9bc310` (2026-07-14), "merge upstream Railway skill additions into use-railway ... Merged upstream railwayapp/railway-skills main additions into our structure as a superset", enumerating both what came from upstream and which local sections were preserved. Against upstream's current `main` the two files differ in 32 lines out of roughly 600. The original arrival is `femcboost` `68e03efa9` (2026-03-27), where it landed as an incidental addition inside an unrelated bug-fix commit, alongside a duplicated nested `skills/use-railway/use-railway/SKILL.md` — the unmistakable shape of an unpacked download. |

### RichOS-authored

| Skill | Verdict | Confidence | Evidence that settled it |
|---|---|---|---|
| `android-native-dev` | RichOS-authored | high | Arrived `femcboost` `ba305f55b` (2026-04-11), "add native mobile skills and update agent definitions for Andy, Isaac, and Quint" — authored alongside the roles that use it. Exported to the engine as **ship-scrubbed**: it carried product-name literals that were mapped to `${APP_ROOT}` and `orchestration.config`, and a stale `jj` reference was repointed at `using-git-worktrees`. A vendored skill does not contain your product's name. Verbatim search of its distinctive prose: no public copy. |
| `appium-vision-mobile-testing` | RichOS-authored | high | Same arrival commit and same scrubbing history. "Appium is the robot hand, not the tester." — no public copy. |
| `bootstrap-interview` | RichOS-authored | high | The only one of the 27 with **no history in the product repository at all**. It was written in the orchestration-kit repository: `172f8ee` (2026-07-14), "Ship Item A: skills/bootstrap-interview/SKILL.md — the 20-minute bootstrap", with `references/portable-interview-prompt.md` following the same day in `4d3810d`. Its subject matter is this engine's own adoption flow (`CLAUDE.md`, `orchestration.config`, Dean, `ceo-wiki/`). `engine/skills/README.md` records it as "as-is (engine-authored)". No public copy. |
| `health-data-sync-contracts` | RichOS-authored | high | Arrived `femcboost` `ba305f55b` (2026-04-11). Named in `engine/skills/README.md`'s 2026-07-14 correction as one of three files that still carried **source-product role vocabulary** ("coach" and "client") and had to be genericized — evidence of in-house authorship that no external skill could produce. No public copy. |
| `ios-native-dev` | RichOS-authored | high | Same arrival commit and scrubbing history as `android-native-dev`. No public copy of its description or body. |
| `live-app-assessment` | RichOS-authored | high | Arrived `femcboost` `0e400875d` (2026-03-31) in a commit that adds this engine's own advisor-role skills. Also named in the 2026-07-14 correction as having carried product role vocabulary. "This skill is not QA. It does not turn the agent into a release gate..." — no public copy. |
| `mobile-qa-reporting-and-device-matrix` | RichOS-authored | high | Arrived `femcboost` `ba305f55b` (2026-04-11); ship-scrubbed for one product-name literal. Cross-references `appium-vision-mobile-testing`, a sibling that **does** exist here — the inverse of the dangling-sibling signal. No public copy. |
| `mobile-release-and-build-ops` | RichOS-authored | high | Same arrival commit; its product-specific "Repo Rules" section was collapsed into an adopter TODO stub at export. No public copy. |
| `native-client-visual-qa` | RichOS-authored | high | Arrived `femcboost` `27606ad51` (2026-04-24) together with the QA role scope it exists to constrain. Its rationale section narrates a specific internal incident — checkmark-format audits that hid an iOS/Android mismatch — and prescribes the three-column format as the fix. No public copy of that passage. |
| `rich-lander` | RichOS-authored | high | Arrived `femcboost` `99a9ccc76` (2026-04-12), "add Rich's 14-step per-handoff land skill". Describes this engine's single-writer-to-`main` procedure by name. No public copy. |
| `ui-ux-design` | RichOS-authored | **medium-high** | Arrived `femcboost` `665f8969f` (2026-03-29), "Hire Urban (Principal Product Designer) + distribute ui-ux-design skill", and it shipped with a `references/fitapp-surface-map.md` — a file named after the source product, which an external skill would not carry. Verbatim searches of its Operating Principles and Senior Judgment prose return no public copy. **The stated doubt:** the skill's own comment block says a sibling project "independently instantiated this exact same base skill for its own product, swapping its own product name in everywhere **the original source named its product**". That sentence is consistent with two readings — that both projects instantiated a RichOS-authored scaffold, or that both instantiated something external. No external base was found, and the balance of evidence favors the first reading, but this is the one row in this table that is not closed by a byte comparison. |
| `using-git-worktrees` | RichOS-authored | high | Arrived `femcboost` `15c11e86e` (2026-07-07), "add using-git-worktrees engineer skill" — the day of this project's own jj-to-git migration. Describes `TaskUpdate`, the commit-is-the-handoff model and the lossy-mailbox doctrine, none of which exist outside this engine. No public copy. |

## Undetermined

**None.** Every one of the 27 has a verdict. The two places where certainty is
qualified are stated in place rather than deferred: `ui-ux-design`
(medium-high, doubt written out above) and `marketing-strategy-pmm` (high rather
than certain, because its upstream re-badges other people's work and the
attribution therefore rests on dates rather than on a byte comparison).

---

## FOR THE CEO — third-party skills that carry no license file

These nine are the entire decision. Each is established third-party at the
confidence stated above; each currently has **no license file in its
directory**; each is permissively licensed upstream. Nothing here has been
changed.

| Skill | Upstream | Upstream license | Copyright holder |
|---|---|---|---|
| `copywriting` | `coreyhaines31/marketingskills` @ `68f5eaf64e85` | MIT | 2025 Corey Haines |
| `customer-research` | `coreyhaines31/marketingskills` @ `cc1a9c106b10` | MIT | 2025 Corey Haines |
| `marketing-psychology` | `coreyhaines31/marketingskills` @ `68f5eaf64e85` | MIT | 2025 Corey Haines |
| `product-marketing-context` | `coreyhaines31/marketingskills` @ `68f5eaf64e85` | MIT | 2025 Corey Haines |
| `playwright-cli` | `microsoft/playwright-cli`, `skills/playwright-cli` | **Apache-2.0** | Microsoft |
| `playwright-e2e-testing` | `bobmatnyc/claude-mpm-skills`, `toolchains/javascript/testing/playwright` | MIT | 2025 Claude MPM Contributors |
| `svelte-code-writer` | `sveltejs/ai-tools`, `plugins/claude/svelte/skills/svelte-code-writer` | MIT | 2026 Svelte Contributors |
| `svelte-core-bestpractices` | `sveltejs/ai-tools` @ `0e55ee792d3d` | MIT | 2026 Svelte Contributors |
| `use-railway` | `railwayapp/railway-skills`, `plugins/railway/skills/use-railway` | MIT | 2026 Railway Corporation |

Two facts belong with that list, because they are the only two that are not
symmetrical with the rest.

- **`playwright-cli` is the Apache-2.0 one, and it is modified.** Apache-2.0
  section 4(a) asks that the license travel with a redistributed copy, and
  section 4(b) asks that a changed file carry a notice that it was changed. Our
  copy adds a "Headed browser requirement" section that is RichOS doctrine. This
  is the same shape as `frontend-design`, which was resolved on 2026-09-04 with
  a `LICENSE.txt` and a `MODIFICATIONS.md`. The other eight are MIT, whose only
  condition is that the copyright notice and permission notice accompany the
  copy.
- **`copywriting` was silently modified too**, in a way worth knowing about: its
  `references/natural-transitions.md` had four British spellings Americanized,
  almost certainly by this project's own dialect sweep, which does not know a
  vendored third-party file from an in-house one. Nothing about that is
  hazardous; it is recorded because a future byte comparison against upstream
  will otherwise look like a mystery.
