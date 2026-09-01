# The RichOS Engine

This is the machinery behind Rich.

RichOS is an **AI Operating System for CEOs**: the CEO talks to one AI executive
— **Rich Hand**, AI Chief of Staff & Business Operations Lead — who owns the
work, delegates it to a team of AI workers, supervises them, and comes back with
results and decisions. The engine in this directory is what makes that
survivable in a real repository: worktree-per-worker isolation, a single writer
to `main`, durable "the commit is the handoff" semantics, model tiering, and a
mandatory QA pipeline. Drop it into a repo, point it at the project, and have
the built-in HR worker staff the domain team.

The flagship piece is `ceo-wiki/` — the CEO's second brain, ready to use from
the first commit. It is what turns Rich from a router into a genuine Chief of
Staff: a decision, preference, or precedent recorded once in the wiki never has
to be re-asked, and escalations to the CEO shrink over time as the second brain
grows. See "The Orchestrator as COO" and "Repository Conventions" in
`CLAUDE.md.template`.

**A note on vocabulary.** RichOS's product voice says *Rich* and *AI workers*.
This directory is the engine's own technical documentation, so it also uses the
Claude Code mechanics terms — *orchestrator*, *agent*, *subagent*, *teammate*,
*spawn* — wherever precision demands them. They name the same things: the
orchestrator is Rich; the agents are his AI workers.

## 60-second proof — watch it work before you set anything up

Don't take the rest of this README on faith. Run one command:

```bash
scripts/demo.sh
```

It builds a throwaway sample repo in a temp dir, wires in this engine's actual,
unmodified enforcement hooks via the real `install.sh`, and drives seven
narrated beats end-to-end — no Claude API key, no live agents, no network,
nothing left behind:

1. A file-writing spawn **without** worktree isolation gets **blocked** —
   real hook, real refusal message.
2. A write straight into a protected source path from the shared checkout
   gets **blocked** — same real hook, different trigger.
3. A **correctly** isolated spawn sails through the same gate untouched.
4. An engineer commits on a real, isolated git worktree branch — the
   commit-is-the-handoff, for real.
5. A planted defect gets **rejected** by a QA check.
6. The fix lands and the QA check **passes** — the FIX-FIRST loop closes.
7. The fix merges to `main` and `contract-integrity-probe.sh` runs green.

It ends with a plain verdict: **"Your team's enforcement machinery works.
7/7 beats passed."** Any beat failing turns the summary red and exits
non-zero — the demo doubles as an integrity check of your own install. Beats
1, 2, 3, 4, and 7 are **real enforcement** (the actual hook binaries and git
mechanics, unmodified); beats 5 and 6 are **narrated simulation** — there's no
live QA worker in a one-command demo script, so the git/exit-code mechanics are
real but the "QA verdict" is a scripted stand-in, labeled as such every time.
Runs in a couple of seconds; your own repo, your real config, and this engine's
own checkout are all completely untouched by it.

## Then read the walkthrough

[`WALKTHROUGH.md`](./WALKTHROUGH.md) traces one realistic feature through the
**full** lifecycle the 60-second proof only samples: a wiki consultation, the
real spawn shape, the commit-is-the-handoff, the single-writer land, the
complete four-step QA pipeline **including a genuine FIX-FIRST bounce**, and
a design-gatekeeper signoff with a documented gap — only after which the CEO
sees the work. It's an illustrative narrative (clearly labeled as such), not
a captured transcript — `scripts/demo.sh` above is the runnable counterpart
of its enforcement beats. Read it once, end to end, before you set anything
up; it's the fastest way to understand what this engine actually does.

**Helping someone else set up?** If you're the technical operator running a
live setup session for a non-technical CEO, use
[`ONBOARDING-RUNBOOK.md`](./ONBOARDING-RUNBOOK.md) instead of improvising —
it's the exact timed script: preflight checklist, the session agenda with
expected-green output for every step, the common stalls with their fixes, and
a machine-checkable definition of done.

## License

**No license has been chosen yet.** See [`LICENSE-TODO.md`](./LICENSE-TODO.md)
for the current all-rights-reserved default and what still needs a decision
from the owner. (The one exception: `tools/gpt-exporter/LICENSE` covers only
that vendored subdirectory.)

## Prerequisites

The mechanical layer (`scripts/hooks/`) is plain POSIX shell plus a handful of
external tools it shells out to. All of the following must be resolvable on
`$PATH` wherever Claude Code runs the hooks:

- **bash** — every hook's interpreter (`#!/usr/bin/env bash`).
- **git** — worktree resolution, worktree listing, and the write-guard's repo
  root.
- **python3** — every hook parses its JSON tool-input payload via `python3
  -c '...'`. **This is a hard requirement, not an optional nicety**: every
  enforcement hook (`guard-worktree-isolation.sh`, `guard-definition-drift.sh`,
  `guard-main-checkout-writes.sh`,
  `guard-bash-main-writes.sh`, `verify-agent-prompt.sh`, `detect-nonnative-worktree.sh`,
  `reader-teammate-hint.sh`, `guard-resume-isolation.sh`),
  `snapshot-agent-definitions.sh`,
  `scripts/hooks/install.sh`, and `scripts/hooks/contract-integrity-probe.sh` all
  check `command -v python3` up front and refuse (non-zero exit, loud stderr) if
  it is missing — they do NOT silently pass every spawn/write through. If your
  environment might not have `python3` on `$PATH` by default (some minimal
  containers, some CI images), install it before relying on the engine's
  enforcement.
- **Standard coreutils** — `grep`, `sed`, `awk`, `cut`, `tr`, `date`, `mkdir`,
  `mktemp`, `basename`, `dirname`. Present by default on macOS and virtually
  every Linux distribution.
- **shasum** or **sha256sum** — for the hook `.sha256` integrity sidecars
  (`install.sh` and `contract-integrity-probe.sh` fall back to a `python3`
  one-liner if neither is present, so python3 doubles as the last-resort hash
  backend too).
- **rsync** — only if you use `scripts/collect-worktree-artifacts.sh` to mirror
  gitignored test/QA evidence out of a worktree before removal.

If you adopt `reference/advanced-tier/` (optional, not wired in by default),
its two "identity-or-refuse" verifiers (`freshness-check.sh`,
`client-data-check.sh`) carry the same `python3` requirement and the same
fail-closed preflight check.

## Critical configuration — never remove

`.claude/settings.local.json` (committed) carries two non-hook keys that are
just as load-bearing as any hook, and their absence has caused a REAL
incident:

```json
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "worktree": { "baseRef": "head" }
}
```

- **`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`** — this key was once
  accidentally deleted from `settings.local.json` during an edit. **The
  symptom did not show up until the NEXT session start**: Rich could not see
  or spawn ANY teammates — a silent total failure, with no error shown
  anywhere. If your workers suddenly seem to have vanished (no roster, spawns
  behave as if the team feature doesn't exist), check this key FIRST.
- **`worktree.baseRef: "head"`** — the worktree-isolation doctrine
  (`CLAUDE.md.template`, `skills/using-git-worktrees/`, `skills/rich-lander/`)
  assumes every native isolation worktree branches from local HEAD. Without
  this key, that assumption silently breaks and the land sequence's
  merge-base verification goes wrong in ways that are hard to diagnose after
  the fact.

The engine also ships `env.CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION: "2000"` in the
same `env` block. It is not probe-gated: a long session (a full QA pipeline, a
multi-batch pass, a fresh spawn per follow-up because resuming a landed teammate
is banned) burns spawns fast, and the default ceiling stops the session partway
through — but it fails LOUDLY (spawns simply stop) rather than silently, so it
stays a plain config key rather than a hard gate. Lower it if you want a tighter
budget; don't leave it at the default if you run long sessions.

**This is enforced, not just documented.** `scripts/hooks/contract-integrity-probe.sh`
hard-fails (Layers I and J, exit 2, loud stderr) if either key is missing or
wrong the next time you run it, and `scripts/hooks/install.sh` refuses to
proceed at all (no migration, no sidecar refresh) if `settings.local.json` is
missing either key. If you ever see teammates go missing, or the probe fail on
Layer I/J, restore both keys in `.claude/settings.local.json` and re-run
`scripts/hooks/install.sh`.

### The global-gitignore trap — commit `settings.local.json`, force-add if needed

There is a second, sneakier way to lose this file, and it fails **silently**:
vanilla Claude Code treats `.claude/settings.local.json` as machine-local, so a
common global-gitignore entry — `**/.claude/settings.local.json` in
`~/.config/git/ignore` (git's default `core.excludesFile`) — makes `git add -A`
**quietly skip it**. The file stays on disk, so `install.sh`, the probe, and the
demo all pass locally; the failure only surfaces at the **next clone/session**,
where the file was never committed and Rich wakes with no team and no error
(the same "ghost team" symptom as a deleted `AGENT_TEAMS` key, arriving by a
different door). This engine **force-adds** the file past that rule; you must do
the same in your repo. After adoption, verify and fix:

```bash
git ls-files .claude/settings.local.json          # must print the path
git add -f .claude/settings.local.json && git commit   # if it printed nothing
```

**This is enforced too.** The probe's **Layer N** hard-fails when
`.claude/settings.local.json` is present on disk but untracked AND matched by a
gitignore rule (the trap), naming the `git add -f` fix; it warns (does not fail)
when the file is simply not committed yet, and skips cleanly outside a git repo.

## The two-layer model

The engine is the **generic framework** (Layer A), extracted from a real
production setup. The project-specific instantiation (Layer B) — one product's
stack, surfaces, roster, deploy machinery, and canonical data — is deliberately
left out. What ships here is only what transfers to any project:

- **Layer A (this engine):** the mechanical orchestration layer (hooks +
  config), the meta-roles (HR, researcher, reader, devil's advocate), the
  reusable role templates, the worktree/handoff/land doctrine, and model
  tiering.
- **Layer B (you supply):** your product's surfaces, protected source trees,
  team roster, deploy targets, and any domain-specific hard rules — filled into
  the clearly-marked `<!-- TODO -->` blocks and `orchestration.config`.

## What ships

| Piece | Path | What it is |
|---|---|---|
| Mechanical hooks | `scripts/hooks/` | Worktree-isolation guard (incl. structural no-name-reuse), resume-isolation guard, definition-drift guard pair, SessionStart worktree reaper, spawn-content verifier, reader/creator hints, secrets scanner, durable idle/task handoff loggers, contract-integrity probe + self-test suites, `install.sh` generator |
| Resume-isolation guard | `scripts/hooks/guard-resume-isolation.sh` | Blocks a `SendMessage` that would RESUME a completed/removed teammate (the spawn-side guard never fires on a resume) — a file-bearing follow-up must spawn fresh in a new isolated worktree; a `resume-ack:` line is the audited escape hatch for a safe pure-question resume. Pairs with the spawn guard's structural no-name-reuse to kill live-vs-ghost ambiguity |
| Secrets scanner | `scripts/hooks/scan-secrets.sh` | Blocks a Write/Edit/MultiEdit/NotebookEdit whose content looks like a live secret (AWS/GitHub/Anthropic/OpenAI/Stripe key patterns, PEM private keys, high-entropy assignment literals for `password`, `api_key`, `secret` and `token`) — closes the "will these AI workers leak my keys" objection structurally, not by promise. Config-driven allowlist so placeholders (e.g. `re_xxxxxxxxx`) never false-positive |
| Dialect guard | `scripts/hooks/guard-dialect.sh` + `scripts/lib/dialect-en-US.dict` | Blocks a Write/Edit/MultiEdit/NotebookEdit that introduces a word outside the repository's declared dialect. Built because a rule with no write-time chokepoint decays on a measurable schedule: a 654-site cleanup pass on 2026-08-30 was partly undone **within hours**, into the very page that carries the ruling, because the pass cleaned what existed and constrained nothing that came after. The vocabulary is DATA, in one file, hashed by `install.sh` and verified by probe **Layer T** — a hash-matched guard over an emptied word list is a green tick over an enforcement outage. **The exemptions are the product:** fenced code, inline code spans, blockquotes (quoted external material is never "corrected"), URLs and paths, code identifiers (`\b` boundaries make camelCase/snake_case free; kebab, `--custom-props` and dotted paths are handled explicitly), captured evidence by path segment (`raw/`, `cold-open/`, `transcripts/`, `fixtures/`, `corpora/`, `snapshots/`, `logs/`), vendor `LICENSE`/`NOTICE`, lockfiles, per-word file-type exemptions (`grey` is a legal CSS color), a config allowlist, and a per-line `dialect-exempt: <reason>` — declared where a reviewer sees it, and a bare marker exempts nothing. **`queue` gets its own rule and it is not a spelling:** `CEO queue` is BLOCKED (it is a name, and the CEO's list is CEO-TODOs), the hyphenated `.ceo-queue` legacy file name is untouched, rename narration is exempt, and the genuinely ambiguous `the queue`/`his queue` is REPORTED and never blocked — precision it cannot prove, it does not claim. Blank `DIALECT_TARGET` = silent no-op; a dialect with no shipped dictionary = announced no-op, never pretend enforcement |
| loro capitalization guard | `scripts/hooks/guard-loro-capitalization.sh` + `scripts/hooks/loro-capitalization.corpus.md` | Blocks a Write/Edit/MultiEdit/NotebookEdit that writes `loro` where English capitalizes any other word. `loro` is a GENERIC term like *wiki* for a living organizational memory, so it takes ordinary capitalization — lowercase mid-sentence, **Loro** starting a sentence, starting a heading, in a title-case heading, or as a proper noun (CEO ruling 2026-09-01). Built for the reason the dialect guard was: the original 2026-08-23 entry's carve-out never mentioned sentence starts, so the record drifted to always-lowercase and stayed there. **What may block was decided by measurement, not by taste,** and the numbers ship beside the guard: scored site-by-site over 1,732 occurrences, heading-initial was 9/9 correct and sentence-initial 29/29 — both **0.0% false positive**, so both BLOCK — while list-and-table-cell-initial was 12 of 30, **60% false positive**, so it REPORTS and never blocks. Title-case headings and paragraph starts across a line break are not attempted at all: `### 1.6 — loro structure` changes only because its sibling headings capitalize, `## Defect 4 — loro had no writer` does not because its siblings do not, and 37 of 48 line-initial sites are mid-sentence wraps. **Under-flagging is the policy** — a wrong capital reads as a branding claim the CEO has not made. Exemptions: fenced code, inline spans, blockquotes INCLUDING behind a comment lead (`* > `), any hyphenated compound (`loro-context`), code lines in source files (only comments are prose there), abbreviations, ordered-list markers, captured-evidence paths, `*.txt` as a stated hole, and a per-line `loro-caps-exempt: <reason>` where a bare marker exempts nothing. Blank or non-`on` `LORO_CAPS` = silent no-op |
| Definition-drift guard pair | `scripts/hooks/snapshot-agent-definitions.sh` (SessionStart) + `scripts/hooks/guard-definition-drift.sh` (PreToolUse[Agent]) | Teammate definitions in `.claude/agents/*.md` load ONCE, at session start — exactly like hooks — so a definition installed or updated mid-session never reaches a newly spawned worker's BOOTED prompt, silently. The snapshotter records every definition's sha256 at session start; the guard BLOCKS a spawn whose definition changed since, naming both hashes and the two sanctioned paths (restart into a fresh session, or a live `definition-drift-ack: <current sha256>` line plus an explicit order to read the on-disk definition). Blocks only on PROVEN drift — no snapshot means no evidence, so it warns rather than halting the team |
| Worktree reaper chain | `scripts/hooks/session-start-reap-worktrees.sh` (SessionStart) + `scripts/reap-stale-worktrees.sh` | Every file-writing spawn creates a linked git worktree; Rich is supposed to remove each one at land time, but across restarts, dropped handoffs and interrupted sessions they pile up silently (43 of them upstream before anyone noticed). The wrapper sweeps on every session start — log-only, fail-open, never blocks a start. The reaper it calls is DRY-RUN by default and removes a tree ONLY if all four gates pass: not locked (or provably stale — no live process AND lock file >2h old), branch merged into whatever branch `HEAD` is on, working tree clean (tracked AND untracked), no live process referencing the path. `git worktree remove` + `git branch -d` — never `--force`, never `-D`. Repo-agnostic; residue git doesn't own is reported, never deleted. This is the only hook-reachable code in the engine that DELETES anything, so probe **Layer Q** hashes BOTH halves and runs paired sandbox canaries: a merged/clean tree must be reaped, a dirty one must survive |
| Raw-Bash main-write guard | `scripts/hooks/guard-bash-main-writes.sh` | Blocks a raw `Bash` command that writes into a protected source tree in the shared MAIN checkout (a compound `cd <root> && mkdir/cp/rm <tree>/…` or an absolute-path write) — the cwd-default drift vector the Write/Edit guard never sees, which otherwise surfaces as an interactive permission prompt to the human operator. Auto-denies with worktree guidance so the worker self-corrects. Protected trees from `PROTECTED_PATHS`; main-root resolved via `resolve-main-checkout.sh` (no hardcoded paths) |
| In-flight sweep | `scripts/hooks/notice-inflight-sends.sh` + `scripts/hooks/guard-inflight-notify.sh` + `scripts/hooks/notice-inflight-acks.sh` (+ `scripts/inflight-notify.sh`, `scripts/inflight-ack.sh`) | Landing moves `main`, and every teammate still working was cut from an older base — silently one revision behind, with nothing to tell it. The send half is ENFORCED: a PostToolUse[SendMessage] hook witnesses every message the LEAD sends (recipient + the SHAs in it; never the body), inside the lead's own tool call, so the record survives a mailbox measured at ~50% loss — and `git push origin main` is REFUSED while any live worktree is behind with no witnessed notice naming this tip, by name. The ack half is SURFACED: the teammate answers with a file in its own worktree that the lead can `stat`, because a reply the lead may never receive proves nothing; a Stop-hook notice reports a missing ack after a measured 30 minutes and names `TaskStop` + respawn as the operator's move. Nothing is killed on a timer, and the one thing no machine checks — whether the teammate's restatement is CORRECT — is printed under HUMAN JUDGMENT REQUIRED rather than scored. Escape hatch is a recorded waiver, never a token |
| CEO-ask gate | `scripts/hooks/notice-ceo-asks.sh` + `scripts/hooks/guard-ceo-ask-first.sh` + `scripts/hooks/notice-ceo-unasked.sh` + `scripts/hooks/session-start-ceo-ask.sh` (+ `scripts/ceo-asks-status.sh`) | Every other mechanism here verifies the RECORD; this one verifies the CONVERSATION. A session can prepare decisions for the CEO, pass every lint, and end without anyone having asked him anything — that happened, with all guards green, and he had to ask three times before his own question reached him. So: a PostToolUse[AskUserQuestion] witness records WHICH prepared item a question was about, computed from the words he actually saw (question + option labels + descriptions), never from what the orchestrator asserts — and **a question matching nothing records `UNMATCHED` and discharges nothing**, which is what stops one junk question per session clearing the gate forever. A PreToolUse[Agent] guard then REFUSES to dispatch a teammate while no prepared item has been put to him this session, because dispatching is the exact act that beat the ask. ONE item per session, not all of them; a live `ceo-todos-deferred: <reason>` prompt line is the logged escape hatch. A Stop notice names the rest at every turn end without blocking, and SessionStart opens with a specific answerable question rather than a count. Items come from the repositories named in `CEO_TODOS_REPOS`, parsed by the same code that renders the CEO's own page. No declaration = stand down silently; declared and unreadable = FAIL OPEN, loudly |
| 60-second proof | `scripts/demo.sh` (+ `scripts/demo.test.sh`) | One-command, unattended demo that drives the real hooks + real git mechanics through block → build → reject → fix → land, ending in a pass/fail verdict — see "60-second proof" above |
| Test runner | `scripts/run-all-tests.sh` | Runs EVERY `*.test.sh` suite in the engine, DISCOVERED from disk rather than globbed at one directory, and reports a derived fraction. Exists because `scripts/hooks/*.test.sh` — the loop quoted as "18/18 suites green" at every land — omitted five suites, two of which were red on `main` for a day. Refuses to report green over an empty inventory. `--list` / `--verbose` |
| CI self-verification | `.github/workflows/engine-self-verify.yml` + `scripts/ci-verify.sh` | Ready-to-commit GitHub Actions workflow — runs `run-all-tests.sh` + `install.sh` + the probe + the demo on every push/PR, turning engine integrity into a standing guarantee. The YAML is a thin caller; **`scripts/ci-verify.sh` is the single place the steps are written down**, so the adopter template and this engine's own root workflow cannot drift (and so "what does CI do?" is one command you can run locally). **The workflow must sit at YOUR repository root**: Actions only discovers workflows in a root-level `.github/workflows/`, so a copy left under `engine/` never fires — the engine's own copy sat there, unreachable, and had never executed once until 2026-08-29. See "CI" below + `docs/ci-portability-notes.md` |
| Full walkthrough | `WALKTHROUGH.md` | One feature traced through the complete lifecycle — wiki consult, real spawn, commit-is-the-handoff, single-writer land, the full 4-step QA pipeline with a genuine FIX-FIRST bounce, gatekeeper signoff — illustrative narrative, not a captured transcript; `scripts/demo.sh` is its runnable counterpart |
| White-glove onboarding | `ONBOARDING-RUNBOOK.md` | The operator's timed script for a live setup session with a non-technical CEO — preflight checklist/email template, exact commands + expected-green output per step, realistic ~60-90 min timings, the common-stall playbook, and a machine-checkable definition of done |
| Guided setup | `skills/bootstrap-interview/SKILL.md` | First-session orchestrator skill: interviews the CEO (~20 min, resumable), then fills `CLAUDE.md`/`orchestration.config`, staffs the initial roster via Dean, and seeds the first `ceo-wiki/` pages from the interview itself — the recommended path through "Adopter flow" below |
| Config | `orchestration.config` | The ONE file you edit to point the hooks at your repo (protected paths, allowlists, meta-role names, artifact dirs, optional QA gate) |
| Cost governance | `docs/cost-governance.md` | What a sprint costs in practice (order-of-magnitude reasoning, not invented pricing), why judgment roles get the Opus tier and mechanical roles don't, the per-spawn override, and the levers that keep spend proportional to stakes — grounded in the engine's own role-template mix and QA-pipeline doctrine |
| Failures playbook | `docs/failures-playbook.md` | 12 generic, product-independent operational failure modes distilled from this engine's own doctrine — symptom → why it happens → the rule → how to recover. Seeds orchestrator memory (below); a memory lesson that generalizes graduates back into this playbook |
| Orchestrator memory | `docs/orchestrator-memory.md` | Rich's own persistent operational-memory convention (one file per lesson + an index) — and, front and center, the boundary table distinguishing it from `ceo-wiki/` (CEO's product/business judgment) so the two substrates never get conflated |
| Versioning & upgrade path | `VERSION`, `VERSIONING.md`, `CHANGELOG.md`, `UPGRADING.md` | The packaging that lets the engine be versioned and safely upgraded: the semver scheme for a doctrine + hooks product (what counts as MAJOR/MINOR/PATCH), the engine-owned `VERSION` file the probe prints on every run, the CHANGELOG, and the upgrade mechanic — which files are yours after adoption vs. engine-owned and safe to overwrite, with the golden rule "re-run install.sh + probe + demo; green = safe" |
| Land/worktree helpers | `scripts/lib/`, `scripts/collect-worktree-artifacts.sh` | Main-checkout resolver + gitignored-evidence collector |
| Working meta-workers | `.claude/agents/{dean,clark,reed,frank}.md` | Spawnable out of the box — Dean (HR), Clark (research), Reed (source reading), Frank (devil's advocate) |
| Role templates | `.claude/agents/templates/` | 16 non-live skeletons (architect, CTO, engineers, QA, designer/gatekeeper, copywriter, marketing, advisors, domain expert) Dean turns into real teammates |
| HR records | `team/` | Plain-markdown profiles for the meta-roles + a profile skeleton + starter `ROSTER.md` + the `NAMING.md` teammate-naming convention |
| Doctrine | `CLAUDE.md.template` | Rich's operating manual — generic rules intact, product sections stubbed |
| **The CEO's second brain (flagship)** | `ceo-wiki/` | Ready to use, not optional-adoption reference: the CEO's externalized judgment — decisions, preferences, precedents. One writer (Rich), everyone reads. Grows primarily from distilled daily conversation; `raw/`-ingestion is the bootstrap path. See `ceo-wiki/README.md` + `ceo-wiki/AGENTS.md` |
| Visibility without meetings | `ceo-briefings/` | Committed sprint/milestone briefs — shipped, in-flight, blocked, escalation-ladder decisions (with wiki citations), wiki updates, open CEO decisions. Rich-written only, like `ceo-wiki/`. Ships with a worked model, `ceo-briefings/EXAMPLE_BRIEFING.md` |
| Skill library | `skills/` (index: `skills/README.md`) | 25 skills total: 3 meta-role doctrine skills (worktree workflow, land sequence, bootstrap interview) + 22 domain skills (14 ship-as-is, 7 scrubbed, 1 template-only) covering QA/testing, native mobile, marketing, copywriting, Svelte, and vendor integrations |
| Advanced tier (reference) | `reference/advanced-tier/` | The optional "identity-or-refuse" freshness / data-render pattern — reference only, not wired in |
| Ingestion tooling | `tools/gpt-exporter/` | GPT Exporter — a Chrome extension that exports ChatGPT threads as clean, Obsidian-compatible `.md` files (with frontmatter), for dropping into `ceo-inbox/for-wiki/` for ingestion into `ceo-wiki/` — see `tools/gpt-exporter/README.md` |

## Repository structure

Beyond the mechanical layer and doctrine files above, the engine ships a set of
pre-scaffolded directories (each tracked via `.gitkeep` where empty) so an
adopter's first spawn already has somewhere correct to write. Every one of these
is referenced by name from the doctrine or a role definition — there are no
orphan folders:

```
.
├── .claude/
│   ├── agents/                 — spawnable meta-role workers (dean/clark/reed/frank)
│   │   └── templates/          — 16 non-live role-template skeletons
│   └── worktrees/               — native per-worker worktree landing zone
│                                  (tracked via .gitkeep; CONTENTS gitignored —
│                                  each is a live worktree created/removed at
│                                  spawn/land time). The one scaffold dir that is
│                                  NOT project-specific — part of the mechanical
│                                  layer, not something to rename per domain.
├── .github/
│   └── workflows/
│       └── engine-self-verify.yml — ready-to-commit CI: suites + probe + demo
│                                  on every push/PR. MUST end up at your
│                                  REPOSITORY ROOT — Actions discovers
│                                  workflows nowhere else (see "CI" below)
├── assets/                      — vendored static assets (fonts, logos, sounds,
│                                  images) — local-only by convention
├── ceo-briefings/                — committed sprint/milestone briefs (shipped,
│                                  in-flight, blocked, escalation-ladder
│                                  decisions, wiki updates, open CEO decisions);
│                                  Rich-written only, like ceo-wiki/;
│                                  ships with EXAMPLE_BRIEFING.md, a worked
│                                  model (delete after your first real one)
├── ceo-inbox/                    — CEO's private channel to Rich
│                                  ONLY (teammates never read it); transient —
│                                  a processed inbox is an EMPTY inbox
│   ├── for-wiki/                 — material destined for ceo-wiki/: Rich
│   │                              moves it into ceo-wiki/raw/ and
│   │                              distills it, no per-item instructions needed
│   │                              (incl. exported .md threads — see
│   │                              tools/gpt-exporter/)
│   └── general/                  — everything else for Rich (work
│                                  requests, task context, one-off directives);
│                                  processed case-by-case
├── ceo-wiki/                     — the CEO's second brain (flagship) — decisions,
│                                  preferences, precedents, not documentation.
│                                  One writer (Rich), everyone reads.
│   ├── README.md                 — what this is + the intake pipeline + access rules
│   ├── AGENTS.md                 — the maintenance doctrine (read before editing)
│   ├── CLAUDE.md                 — single-line `@AGENTS.md` import
│   ├── PAGE-TYPES.md              — the 20-type page taxonomy reference
│   ├── PAGE-TEMPLATE.md           — the standalone page-format skeleton
│   ├── raw/assets/                — provenance archive for images (raw/ itself
│   │                              is the permanent, immutable ingested-source
│   │                              archive that source-* pages cite)
│   └── wiki/
│       ├── 000_index.md          — table of contents (sorts first: "000_")
│       └── zzz_log.md            — append-only operations log (sorts last: "zzz_")
├── docs/
│   ├── audits/                  — dated audit registers and findings docs
│   ├── briefs/                  — Reed's durable, committed source-reading briefs
│   ├── ci-portability-notes.md  — macOS-vs-Linux portability reasoning behind
│   │                              the shipped CI workflow (what was checked,
│   │                              what's clean, what to watch)
│   ├── cost-governance.md       — what a sprint costs, the model-tiering
│   │                              economics, and the levers that control spend
│   ├── design-system/           — the living design-system reference (components,
│   │                              tokens, canonical-state screenshots)
│   ├── failures-playbook.md     — generic, product-independent operational
│   │                              failure modes (symptom -> why -> rule ->
│   │                              recovery); seeds orchestrator-memory.md
│   ├── orchestrator-memory.md   — Rich's own persistent operational
│   │                              memory convention, and its boundary vs. ceo-wiki/
│   └── plans/                   — architecture/migration/rollout/sprint plans
├── hr-inbox/
│   └── team-skills/             — skill packages Dean distributes to teammates
├── qa-audits/                   — committed QA audit deliverables (automation,
│                                  functional, adversarial-visual, device QA);
│                                  ships with EXAMPLE_AUDIT.md, a worked model
│                                  (delete after your first real audit)
├── reference/advanced-tier/      — optional "identity-or-refuse" freshness /
│                                  data-render reference tier (not wired in)
├── scripts/                     — mechanical hooks, land helpers, install.sh
├── skills/                      — 25 skills: 3 meta-role doctrine skills
│                                  (using-git-worktrees, rich-lander,
│                                  bootstrap-interview) + 22 domain skills
│                                  (see skills/README.md for the index)
├── team/                        — HR-record profiles + role-profile skeleton +
│                                  ROSTER.md + NAMING.md (teammate-naming convention:
│                                  the mnemonic roster — floor rules + optional hooks)
├── team-inbox/                  — staging area for sub-team-specific material
│                                  (code examples, running TODOs)
├── tools/
│   └── gpt-exporter/             — GPT Exporter Chrome extension: exports
│                                    ChatGPT threads as clean, Obsidian-
│                                    compatible .md files for
│                                    ceo-inbox/for-wiki/ ingestion (see its
│                                    own README.md)
├── ui-ux-signoffs/               — committed design-gatekeeper signoff files;
│                                  ships with EXAMPLE_SIGNOFF.md, a worked model
│                                  (delete after your first real signoff)
├── CHANGELOG.md                  — per-version contents (see VERSIONING.md)
├── CLAUDE.md.template
├── ONBOARDING-RUNBOOK.md         — the operator's timed white-glove setup-
│                                   session script (preflight, agenda,
│                                   common stalls, definition of done)
├── orchestration.config
├── README.md
├── UPGRADING.md                  — how an adopter pulls future engine updates
│                                   without clobbering their filled config,
│                                   staffed workers, and grown wiki
├── VERSION                       — the engine's semantic version (engine-owned,
│                                   one line; the probe prints it on every run)
├── VERSIONING.md                 — the semver scheme for a doctrine + hooks
│                                   engine + the release ritual
└── WALKTHROUGH.md               — one feature traced through the full
                                   lifecycle (illustrative narrative, not a
                                   captured transcript; scripts/demo.sh is
                                   its runnable counterpart)
```

Add any further repo-root directories your product needs (e.g. one per
deployable app/service) — those are yours to define, not part of the generic
scaffold.

## Adopter flow

### Recommended: clone → hooks → the bootstrap interview

1. **Clone** this engine, or copy **its entire contents except its own
   `.git/`** into your existing repo's root — everything, not a hand-picked
   subset: `scripts/`, `.claude/` (**including the committed
   `.claude/settings.local.json`** — see the load-bearing warning just below),
   `.github/workflows/`, `team/`, `skills/`, `orchestration.config`,
   `CLAUDE.md.template`, `reference/`, `tools/`, `ceo-inbox/`, `ceo-wiki/`,
   `ceo-briefings/`, plus `.gitignore` and the `VERSION` / `CHANGELOG.md` /
   `UPGRADING.md` packaging files.
   - **`.claude/settings.local.json` is committed BY DESIGN and easy to lose.**
     It is the SOLE hook-registration source plus the two load-bearing config
     keys below — a copy or `git add -A` that skips it ships a repo that works
     locally but strands the next clone/session with **zero teammates and no
     error**. Worse, a common global-gitignore convention silently drops it
     (next paragraph) — so after copying, confirm it is actually tracked:
     `git ls-files .claude/settings.local.json` must print the path; if it
     doesn't, `git add -f .claude/settings.local.json`. The integrity probe's
     Layer N checks exactly this.
2. **Mint the sidecars:** the hooks are already wired — they register in exactly
   ONE committed file, `.claude/settings.local.json`, which Claude Code reads
   directly (no generated `.claude/settings.json`; a second copy would make
   every hook fire twice — the double-fire the probe's Layer M guards). Run
   `scripts/hooks/install.sh` once to regenerate the gitignored hook `.sha256`
   integrity sidecars from the current hook bytes (and to migrate away any stale
   hook-duplicating `.claude/settings.json` left by an older install). One
   sidecar lands outside `scripts/hooks/` — `scripts/reap-stale-worktrees.sh.sha256`,
   for the half of the worktree-reaper chain that actually removes worktrees;
   both are gitignored and both are hashed by the probe's Layer Q.
3. **Provision `CLAUDE.md` so a bare boot IS Rich:** copy
   `identity.config.example` to `identity.config`, fill in at least
   `COMPANY_NAME` and `CEO_NAME`, then run
   `scripts/provision-claude-md.sh`. The engine ships `CLAUDE.md.template`,
   but Claude Code only auto-loads `CLAUDE.md` — until this runs, a bare boot
   is **generic Claude**, not Rich. The script fills the template with your
   actuals, turns every `<!-- TODO (adopter) -->` block into either your value
   or an explicit "not configured — ask, never invent" note, and stamps the
   result with the engine version + template hash. It is safe to re-run: an
   unedited file refreshes, a file **you** edited is never overwritten
   (`--upgrade` writes `CLAUDE.md.new` beside it to diff). `--check` exits
   non-zero if the file is missing or stale, so an installer can gate on it.
4. **Tell Rich to run the bootstrap interview:**
   `skills/bootstrap-interview/SKILL.md`. It interviews you conversationally
   (~20 minutes, structured stages, resumable if you need to stop partway),
   then does the rest of this section's old manual work FOR you: fills
   `CLAUDE.md` from `CLAUDE.md.template`, fills `orchestration.config`, spawns
   Dean to staff your initial roster from the answers, seeds the first
   `ceo-wiki/` pages from the interview itself (with discuss-before-write
   honored, same as any other wiki ingest), and finishes with its own
   verification pass (`install.sh` + `contract-integrity-probe.sh` +
   `scripts/demo.sh`) so you see a green summary before doing anything else.
   Never fabricates an answer you didn't give — anything unanswered stays an
   explicit TODO. **Prefer voice?** macOS Dictation or Windows `Win+H` work
   today, no setup needed — or run the whole interview in any chat/voice
   assistant first via
   `skills/bootstrap-interview/references/portable-interview-prompt.md` and
   drop the resulting transcript in `ceo-inbox/for-wiki/`; the skill detects
   it automatically ("Transcript mode") and skips straight to generation.
5. **Optionally adopt the advanced tier:** if your project has a comparable
   deploy/device pipeline, adapt `reference/advanced-tier/` and flip
   `ENABLE_QA_INSTALL_FRESH_GATE=1` in `orchestration.config`. Skip it otherwise —
   the mechanical layer stands alone.
6. **Commit `.github/workflows/engine-self-verify.yml` AT YOUR REPOSITORY
   ROOT** (already in the repo, ready as-is) so the same checks keep running on
   every future push/PR — then **check `gh run list` and confirm it actually
   ran.** GitHub Actions discovers workflows only in a root-level
   `.github/workflows/`; a copy anywhere else is inert and silent, which is
   exactly how this engine's own self-verification went months without
   executing once. See "CI — the engine keeps guarding itself" below.
7. **Stay current.** The engine is versioned (see `VERSION` / `VERSIONING.md`);
   when a new release ships a hook hardening, a new skill, or a fix, pull it
   with [`UPGRADING.md`](./UPGRADING.md) — it spells out which files are yours
   after adoption (your filled `CLAUDE.md`, `orchestration.config`, staffed
   workers, and grown `ceo-wiki/`) versus engine-owned and safe to overwrite,
   and the golden rule: after any update, re-run `install.sh` + the probe + the
   demo — all green means the upgrade is safe.

### Fallback: manual setup (no interview)

Every step the bootstrap interview automates can still be done by hand — useful
if you'd rather fill things in yourself, or want to understand exactly what
the interview is doing on your behalf:

1. **Fill `orchestration.config`:** set `PROTECTED_PATHS` to your real source
   trees, adjust `READONLY_ALLOWLIST`, `ARTIFACT_MERGE_DIRS` /
   `ARTIFACT_REPLACE_DIRS`, and the meta-role names if you renamed them. A
   half-configured hook fails loud, not dangerous — so fill this before relying
   on enforcement.
2. **Fill `CLAUDE.md.template`:** the mechanical way is
   `scripts/provision-claude-md.sh` (fill `identity.config` first) — it does the
   copy, the actuals, and every `<!-- TODO -->` block for you, and re-running it
   never overwrites your edits. By hand: copy the template to `CLAUDE.md` and
   replace every `<!-- TODO -->` block (surfaces map, team directory + routing,
   deploy table, product hard rules) **and delete the adopter header comment and
   the sample "No pagination" bullet** — anything left in place reads as your
   doctrine. Keep all the generic doctrine intact, including "The Orchestrator
   as COO" section.
3. **Start using `ceo-wiki/`:** it's ready as-is — no setup required. Either
   drop your first source into `ceo-inbox/for-wiki/` and have Rich
   ingest it, or just start talking; Rich distills durable
   decisions/preferences into the wiki continuously from there. `ceo-inbox/general/`
   is for everything else you hand Rich.
4. **Staff your domain team via Dean:** for each role you need, have Dean read
   the matching template in `.claude/agents/templates/` (asking Clark to research
   the role for your domain when depth helps), copy it to
   `.claude/agents/<slug>.md` with a real `name`, fill in the persona/stack/
   guardrails, write the matching `team/<name>.md` profile, and register the hire
   in `CLAUDE.md` + `team/ROSTER.md`. Never spawn a template directly — instantiate
   a real named copy first.

## Verify the engine works before you rely on it

The fastest check is the [60-second proof](#60-second-proof--watch-it-work-before-you-set-anything-up)
above (`scripts/demo.sh`) — it exercises the real hooks end-to-end against a
throwaway sample and prints a pass/fail verdict. For the lower-level suites:

```bash
# EVERY test suite, discovered from disk (not globbed at one directory):
scripts/run-all-tests.sh          # add --list to see the inventory, --verbose for full output

# The wiring/integrity probe (confirms hooks are installed + chained + unmodified):
scripts/hooks/contract-integrity-probe.sh

# If you run the engine BY REFERENCE (as a plugin), name the repository it
# governs — the probe then runs the plugin-route layers instead of the
# settings-wiring ones:
RICHOS_ENTITY_ROOT=/path/to/your/repo /path/to/engine/scripts/hooks/contract-integrity-probe.sh
```

Use `scripts/run-all-tests.sh` rather than a `scripts/hooks/*.test.sh` loop. That
loop is what this section used to recommend, and it silently omitted five suites
— including `scripts/demo.test.sh` and `scripts/locate-engine.test.sh`. On
2026-08-29 both of those were red on `main` for a day (the buyer-facing
`scripts/demo.sh` exited 2 during setup) while "18/18 suites green" was quoted
at every land and was, for the glob it described, entirely true. The runner
discovers suites instead of enumerating directories, and refuses to report a
fraction over an empty inventory.

Green suites + a passing probe mean the framework is correctly wired standalone.
A useful smoke test: spawn a file-writing teammate WITHOUT `isolation: "worktree"`
and confirm the worktree-isolation guard blocks it. Another: try to write a file
containing an obvious API-key-shaped string and confirm `scan-secrets.sh`
blocks it (`scripts/hooks/scan-secrets.test.sh` covers this exhaustively —
every vendor pattern, every placeholder-must-not-false-positive case).

## Running the engine BY REFERENCE (one engine, many repositories)

Everything above describes the engine **seated**: copied into your repository,
registered through your `.claude/settings.local.json`. That is the right shape
for one repository. For several, copying the mechanical layer into each of them
means N copies drifting apart — and a drifted guard still reports that it is on,
which is worse than not having it.

The alternative is to load the engine **by reference**, as a Claude Code plugin.
One copy on disk; each repository decides at run time whether it is governed.

**1. Register the marketplace.** The engine ships a marketplace manifest at the
repository root (`.claude-plugin/marketplace.json`), so:

```bash
claude plugin marketplace add /path/to/this/repo
```

Use the CLI rather than hand-editing `known_marketplaces.json`: the command
reconciles the registry immediately, so the plugin is live in the **next**
session. Hand-writing the settings key alone leaves the registry unreconciled
and the plugin inert for a session, with nothing said about it.

**2. Enable it at USER scope.** In `~/.claude/settings.json`:

```json
{ "enabledPlugins": { "richos-engine@richos-local": true } }
```

**User scope is not a preference — it is the only scope that works.** The same
two keys at project or local scope do nothing (measured on 2.1.250), while the
same file's `env` block IS honoured, so it is a per-key restriction rather than
a general one. The consequence matters: **the registration is operator-local and
lives in no repository**, so a fresh clone gets NO enforcement until somebody
enables the plugin. Nothing in the repository can tell you that has happened.

**3. Adopt, per repository.** A repository is governed **iff `orchestration.config`
sits at its main-checkout root**. One marker, checked one way. The plugin is
enabled once and loads in every project on the machine; which repository it
GOVERNS is decided per session from `CLAUDE_PROJECT_DIR`. Repositories without
the marker get an explicit stand-down, not silence.

**4. Confirm it, twice.** At every session start `engine-status.sh` states, to
the operator and to the model, whether enforcement is ACTIVE, STOOD DOWN or
BROKEN for this repository, which engine it came from, and how it resolved the
root. For the wiring itself:

```bash
RICHOS_ENTITY_ROOT=/path/to/your/repo /path/to/engine/scripts/hooks/contract-integrity-probe.sh
```

That runs the by-reference layer set (BR1–BR9): the plugin manifest, the plugin
hook table (every guard registered exactly once, on the right event, in the
right order), path confinement to `${CLAUDE_PLUGIN_ROOT}`, sidecar hashes, the
declared meta-roles, **whether this operator's registration actually resolves to
this engine**, whether the marketplace manifest is committed, the announcement
on both channels, and a live paired canary proving a guard still blocks what it
should and allows what it should. `scripts/hooks/by-reference.test.sh` is that
layer set's negative controls — every layer shown failing for its own reason.

> **Do not read `claude plugin details` as an inventory of the roles.** It
> reports `Agents (0)` for a manifest that declares agent FILE paths, because
> its inventory helper `readdir()`s each declared path and drops the resulting
> ENOTDIR. The roles load correctly — the session loader handles files
> explicitly, and the host's own debug log says `Total plugin agents loaded: 4`.
> Ask the probe (BR5) or the session's agent list, not `details`.

> **Why file paths and not an `agents/` directory.** The host's agent loader
> RECURSES into subdirectories and namespaces what it finds as
> `<plugin>:<subdir>:<name>`. `.claude/agents/` here also carries
> `templates/` — sixteen non-live role skeletons — so declaring the directory
> would ship seventeen roles nobody meant to ship. BR5 fails a manifest that
> declares a directory containing subdirectories, for exactly that reason.

## CI — the engine keeps guarding itself

`.github/workflows/engine-self-verify.yml` ships ready to commit as-is — no
edits needed, nothing repo-specific to fill in. It runs on every push/PR
(`ubuntu-latest`) and repeats exactly what "Verify the engine works" above does
by hand, by calling one script:

```
scripts/ci-verify.sh
```

That script — not the YAML — is where the seven steps are written down: tool +
git-identity preconditions, `bash -n` on every shipped script, **every** test
suite via `run-all-tests.sh` (discovered from disk, never globbed at one
directory), `install.sh` to mint the gitignored `.sha256` sidecars a fresh clone
has none of, `contract-integrity-probe.sh`, and `scripts/demo.sh` asserting 7/7
beats. Run it yourself before you push; CI runs the identical thing.

This converts the engine's integrity from a one-time manual check into a
**standing guarantee inside your own repo** — a deleted settings key, a modified
hook, or a broken probe surfaces immediately in CI on the very next push,
instead of as a silent total failure at some future session start (exactly the
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` incident this README warns about above).

**Put it at your repository root, then confirm it ran.** Actions discovers
workflows ONLY in a root-level `.github/workflows/`. This engine's own copy
lived under `engine/` — correct as a template for an adopter who copies the
engine's contents to their root, and completely inert in the engine's own
repository, where it had never executed a single time. `gh run list` returned
nothing. A workflow file is not CI; an executed run is.

The engine is developed on macOS and this runs on Linux. The first execution
found three real defects the pre-CI portability audit had missed — including one
in shipped enforcement code, not a test. `docs/ci-portability-notes.md` records
all three, what was fixed, and the one layer set CI honestly cannot cover
(BR1-BR10, which need an operator's `~/.claude` registration and are covered
instead by `scripts/hooks/by-reference.test.sh`).

## Keeping the working record honest — the row-currency contract

A working list has rows; rows describe things; things change; nothing connects
the two. On one real day, four rows of one record described work as unbuilt
hours after it had landed, and every one was found by a person reading the page,
because a person reading the page was the only detector there was.

Create a **`.row-currency`** file at the root of the repository that owns your
record and each governed row carries a **warrant** — a status word, and every
path that row describes pinned to the object id it had when the row was written:

```
| 4.2 | prose about the work | **State:** `OPEN` — `<repo>/src/parser.rs`@`0a1b2c3d4e5f` |
```

`guard-row-currency-commits.sh` recomputes those ids out of the tree each
landing is about to create. If one has moved and the row has not, the landing is
refused by item id, and the refusal prints the warrant to paste. There is
deliberately **no re-stamp command**: a tool that refreshed the pin would let the
obligation be discharged with nobody reading the sentence beside it.

It fires only at a landing — main checkout, attached HEAD, `git commit` or
`git merge` — so branch work in a linked worktree is never blocked. A second,
narrower check refuses a message that NAMES an item whose row did not change.
Where the work lives in a different repository from the record, that repository
carries a one-key peer form of the same file; if the record repository is not on
the machine, the guard stands down loudly and blocks nothing.

Run it by hand with `scripts/row-currency-lint.sh <repo>`, and
`--explain --message "..."` to see the claim check's reasoning candidate by
candidate. Both declaration forms, and the honest list of what the rule cannot
see, are in [`reference/row-currency/`](./reference/row-currency/README.md).

## Work written down instead of started — the unstarted-row sweep

Writing a row satisfies the same urge as doing the work. So a lead finds
something, records it, and stops — and on one real day that happened three times
before lunch, once about a hook nobody had been asked to build. The prose fix
failed first: the amended paragraph was still on the page, in its author's own
words, when it happened twice more.

`notice-unstarted-rows.sh` runs at **every turn end**, not at a land, because
work is created when something is NOTICED and noticing happens while writing a
report. It reads the ordered backlog and the working record as one corpus — a
half corpus is loud, never a clean sweep of the surviving half — and names any
row that has nothing blocking it and no live worktree working on it.

A row goes quiet by NAMING what it waits on (the backlog's `Blocked by` cell, or
`**Blocked:** <who>` in a record row), or by a live worktree claiming it (a
branch or directory containing `row-<id>`, or `<worktree>/.claude/row-claims.txt`).
It
never blocks a turn, and it speaks once per change rather than once per turn.

Switched on by the backlog file existing; an optional **`.unstarted-rows`**
moves that path or narrows which warrant states count. Run it by hand with
`scripts/unstarted-rows-lint.sh <repo>` — exit 1 means something is unstarted,
exit 2 means nothing was read, and those are never the same answer. Full
documentation in [`reference/unstarted-rows/`](./reference/unstarted-rows/README.md).

## If your repository gets published — the two publication contracts

Some repositories go public. If yours does, create a **`.publication-boundary`**
file at its root. That one committed file is the declaration, and it switches on
both halves of the split — nothing is inferred, exactly as `orchestration.config`
declares engine adoption. Its own header documents every key it takes; copy this
engine's repository-root copy and edit `PRIVATE_RECORD` and `PRIVATE_SOURCES` to
name where your private material actually lives.

**Half one — may this leave?** `guard-publication-writes.sh` (at the write) and
`guard-publication-commits.sh` (at `git commit`, against the staged index, which
is where it catches files that tools generated and no Write ever touched) refuse
private material entering a published tree. They decide on CONTENT, not on file
extension: the incident that produced them was 137 files of recorded speech that
passed a "no media committed" check three times because the payload was text.

**Half two — is everything that must be there, there?** A leak guard is blind to
the opposite failure: the public tree claiming a capability it does not deliver.
Four of those shipped in a single day — enforcement with no declaration file to
switch it on, a mechanism left behind in the private repo, a workflow at a path
Actions never looks at, and a README citing a CI file that exists nowhere. Run:

```
scripts/publication-completeness.sh
```

It derives what must exist from what your tree already declares — no list of
capabilities to maintain — and names anything missing, with the fix. `--explain`
shows what it derived and from where. `ci-verify.sh` runs it on every push, so
this is not a step anybody has to remember.

When a finding is genuinely not a defect — a reference tree whose paths describe
*your* repository rather than the engine's — say so in an optional
**`.publication-completeness`** file beside the boundary declaration, with the
reason in a comment. That escape hatch is safe to have because an entry which
suppresses nothing FAILS and names itself for deletion, so an exemption cannot
outlive its reason. The engine's own copy is at the repository root; read it for
the four keys and for what each exemption is actually buying.

## The meta-roles (ship working)

- **Dean** (`dean`, HR) — creates teammates and re-authors the role templates for
  your domain.
- **Clark** (`clark`, research) — researches the skills/knowledge a real expert in
  a role would have, for Dean to build from.
- **Reed** (`reed`, source reading) — reads long sources in full and always leaves
  a durable, committed, cited brief.
- **Frank** (`frank`, devil's advocate, opus) — brutally honest stress-testing of
  plans and decisions.

The orchestrator is **Rich** — Rich Hand, the AI executive the CEO actually
talks to. In RichOS that name is the product; if you adopt this engine into
another context you can rename him, but the "Rich only delegates, never does the
work" role is what matters, not the name.
