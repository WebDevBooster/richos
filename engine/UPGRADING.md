# Upgrading — pulling engine updates into a repo that has already adopted it

Once you adopt the engine, your repo diverges from it on purpose: you fill in
`CLAUDE.md`, staff real workers, grow a `ceo-wiki/`, and tune
`orchestration.config`. When the engine ships a new version — a hook hardening, a
new skill, a fixed false-positive — you want *those* improvements without
clobbering *your* filled-in work. That is the whole difference between "a repo I
copied once" and "a product I run." This document is the mechanic.

Read [`VERSIONING.md`](./VERSIONING.md) first for what a version *is* and how to
tell (from [`CHANGELOG.md`](./CHANGELOG.md)) whether an update is a MAJOR that
needs care or a PATCH you can take blind.

## The golden rule — machine-checkable green is the whole safety net

**After ANY update, re-run the three checks. If they're all green, the update is
safe; if any is red, you have a merge to finish before you trust the machine
again.**

```bash
scripts/hooks/install.sh                     # mint .sha256 sidecars + migrate away any stale settings.json
scripts/hooks/contract-integrity-probe.sh    # hooks installed, chained, unmodified (exit 0)
scripts/demo.sh                              # real hooks + git end-to-end (7/7 beats)
```

This is not advice — it is the definition of a successful upgrade. The engine was
built so that "did the upgrade work?" is an *objective* question with a green/red
answer, not a judgment call: the probe verifies every guard is wired and
un-tampered (including the two critical `settings.local.json` keys and the
secrets scanner), and the demo drives the real enforcement path end-to-end. If
you customized a hook and your customization survived the merge intact, the
probe's manifest-hash check will tell you (it will flag the hash mismatch);
if a merge left a guard half-applied, the demo's 7/7 will drop. Never declare an
upgrade done on "it looks merged" — run the three and read the greens. (If you
run the bootstrap interview or the CI workflow, they run these same checks for
you — CI on every push, the interview at the end of its generation pass.)

## Ordering trap — the engine goes FIRST when a `.ceo-todos` key is new

`.ceo-todos` is strict-parsed: a key the running engine does not know is
refused, loudly, rather than silently doing nothing. That is deliberate (a
setting that quietly has no effect is the defect this engine keeps finding in
itself) and it has one consequence worth stating before you hit it.

**If a repository's `.ceo-todos` starts using a key that only a NEWER engine
knows, every commit into that repository is refused until the engine is
upgraded.** The refusal names the key and lists the ones the running engine
accepts, so it diagnoses itself — but it will stop work.

So when an update adds declaration keys (`TODO_VIEW`, `ROOT_README` and
`COLD_OPEN_DIR` arrived together in one such update):

1. Land the **engine** update and run `scripts/hooks/install.sh`.
2. Only then land the `.ceo-todos` change in the repository that owns the record.

Reversing those two wedges the record's repository for everyone using the older
engine. If you have already reversed them, the way out is the same either way:
upgrade the engine. Do not delete keys to make the old parser happy — that
silently switches off whatever they enabled, which is the failure you were being
protected from.

## The CEO's TODOs: the 2026-08-29 rename, and why nothing breaks

The mechanism that was called **the CEO queue** is now **the CEO's TODOs**. The
CEO's reason is not cosmetic: the audience is non-technical CEOs based in the
US, and *queue* is the British word for it. Everything renamed together:

The "before" column is written without backticks on purpose: those paths no
longer exist in this tree, and a citation of a file a reader will never have is
a finding `scripts/publication-completeness.sh` is right to raise.

| Before (gone) | Now |
|---|---|
| .ceo-queue | `.ceo-todos` |
| QUEUE_RECORD / QUEUE_VIEW | `TODO_RECORD` / `TODO_VIEW` |
| CEO-QUEUE.md (the usual view name) | `CEO-TODOs.md` |
| scripts/ceo-queue-{lint,render,init}.sh | `scripts/ceo-todos-{lint,render,init}.sh` |
| scripts/lib/ceo-queue.{sh,py} | `scripts/lib/ceo-todos.{sh,py}` |
| scripts/hooks/guard-ceo-queue-commits.sh | `scripts/hooks/guard-ceo-todos-commits.sh` |
| reference/ceo-queue/ | `reference/ceo-todos/` |

**You do not have to do anything on the day you take this update.** A clean cut
was rejected, and the reason is the ordering trap above turned inside out.
`.ceo-queue` is strict-parsed, so a new engine that only knew `.ceo-todos` would
find no declaration in an un-migrated repository, **stand down, and say
nothing** — the repository would look governed while every commit sailed
through. That is the failure class this mechanism was built to remove, so it is
not an acceptable way to ship its own rename.

Instead:

- The old declaration name and the old key names are **still read and still
  enforced**. Nothing switches off.
- Every verdict — including a **clean** one, and including the commit guard's —
  prints `LEGACY-DECLARATION-NAME` / `LEGACY-DECLARATION-KEYS` naming the file
  and the exact rename command. Accepted, never silent.
- Carrying **both** `.ceo-todos` and `.ceo-queue` is `BROKEN` and blocks. Two
  declarations are two answers to "what is the record"; the engine will not pick
  one quietly.
- `ceo-todos-init.sh` refuses to run in a repository that already declares under
  the old name — that is a rename, not a re-install — and prints the commands.

### The migration, when you want the notice to stop

```bash
git mv .ceo-queue .ceo-todos
# inside it: QUEUE_RECORD -> TODO_RECORD, QUEUE_VIEW -> TODO_VIEW
git mv CEO-QUEUE.md CEO-TODOs.md          # only if that is your TODO_VIEW name
# point TODO_VIEW at the new name, then re-render and re-check:
scripts/ceo-todos-render.sh /path/to/repo
scripts/ceo-todos-lint.sh   /path/to/repo
```

Renaming the view changes the front door, so the render is not optional and the
cold-open freshness gate (if you declare `COLD_OPEN_DIR`) will ask for a fresh
reading: `scripts/cold-open.sh --run /path/to/repo`.

### The direction the alias cannot save — the land order still matters

The alias fixes **new engine + old declaration**. It cannot fix **old engine +
new declaration**, because that engine has already shipped and will look for
`.ceo-queue`, not find it, and stand down silently. So the rule from the
ordering trap is unchanged and now matters more:

1. Land and install the **engine** update.
2. Only then rename the declaration in the repository that owns the record.

If you own both, land them in that order in that sitting. If you are an adopter
pulling this release, you are already safe: the engine arrives first by
definition, and your `.ceo-queue` keeps working until you choose to rename it.

## Which files are yours, and which are the engine's

The upgrade decision for every file reduces to one question: **who owns it after
adoption?** Three classes:

### Engine-owned — safe to overwrite with the new version

These carry no adopter content. Take the upstream version wholesale on every
upgrade; the only reason to review a diff is curiosity about what changed.

- `scripts/hooks/**` — all enforcement hooks, their `*.test.sh` suites, and the
  `install.sh` migrator + `contract-integrity-probe.sh` probe. (Hooks register
  in the committed `.claude/settings.local.json` — `install.sh` no longer
  generates a `.claude/settings.json`; it mints the `.sha256` sidecars from the
  current hook bytes and migrates away any stale hook-duplicating `settings.json`
  an older install left. The sidecars and any residual `settings.json` are
  gitignored — never merge them, just re-run install.)
- `scripts/lib/**`, `scripts/collect-worktree-artifacts.sh`, `scripts/demo.sh`,
  `scripts/demo.test.sh`.
- `skills/**` — the engine-shipped skill library (the ship-as-is + scrubbed +
  template-only skills). If you *added your own* skills alongside them, those are
  yours; the engine's originals are safe to refresh.
- `.claude/agents/templates/**` — the non-live role-template skeletons Dean
  instantiates from. (Your *instantiated* `.claude/agents/<slug>.md` files are
  yours — see below.)
- `.claude/agents/{dean,clark,reed,frank}.md` — the meta-role workers, **unless
  you edited them** for your domain (then treat as adopter-owned).
- `reference/**`, `tools/**` — the advanced-tier reference and vendored tooling.
- `VERSION`, `VERSIONING.md`, `CHANGELOG.md`, `UPGRADING.md`, `WALKTHROUGH.md`,
  `ONBOARDING-RUNBOOK.md`, `LICENSE-TODO.md`, and the reference docs under
  `docs/` (`cost-governance.md`, `failures-playbook.md`, `orchestrator-memory.md`,
  `ci-portability-notes.md`).
- `.github/workflows/engine-self-verify.yml` and `scripts/ci-verify.sh` — take
  upstream unless you extended them. The YAML is a thin caller; `ci-verify.sh`
  holds the actual steps, so an upstream change to what CI verifies arrives in
  the script. **Check the workflow is at your repository ROOT** — Actions
  discovers workflows nowhere else, and a copy left under a subdirectory never
  fires and never says so.

### Adopter-owned — merge carefully, never blind-overwrite

These hold *your* work. An upgrade must **preserve your content and layer in the
engine's structural improvements** — never replace.

- **`CLAUDE.md`** — you generated this from `CLAUDE.md.template` and filled it.
  On upgrade, the *template* changes (a new doctrine section, a reworded rule);
  you want that structural improvement without losing your filled-in surfaces
  map, team directory, deploy table, and product hard rules. Diff the new
  `CLAUDE.md.template` against the version you generated from, and hand-apply the
  doctrine changes into your `CLAUDE.md`. (Keeping a copy of the template version
  you started from makes this a clean three-way diff.)
- **`orchestration.config`** — you filled `PROTECTED_PATHS`, allowlists, artifact
  dirs, and meta-role names. An engine upgrade may add a *new key* (with a
  documented default) or a comment. Merge the new keys/comments in; keep every
  value you set. Never take the upstream config wholesale — it would reset your
  paths to the sample literals.
- **`.claude/agents/<slug>.md`** (your instantiated teammates) and their
  **`team/<name>.md`** profiles + **`team/ROSTER.md`** — these are staffed by
  Dean for your domain. Engine upgrades change the *templates*, not your instances;
  if you want a template improvement reflected in an existing teammate, re-apply
  it deliberately (or have Dean re-instantiate).
- **`ceo-wiki/wiki/**`, `ceo-briefings/**`, `qa-audits/**`, `ui-ux-signoffs/**`,
  `docs/audits/**`, `docs/briefs/**`, `docs/plans/**`, `docs/design-system/**`** —
  pure content you and your team produced. The engine ships *scaffolds and worked
  examples* here (`EXAMPLE_*.md`, and `docs/design-system/` ships as an empty
  `.gitkeep` scaffold you fill with your own component specs/tokens/screenshots),
  which you may have deleted or filled after your first real one. Never let an
  upgrade re-drop an example over your content or wipe your pages.
- **`ceo-wiki/AGENTS.md` / `README.md` / `PAGE-TYPES.md` / `PAGE-TEMPLATE.md`** —
  the wiki *doctrine* is engine-owned in principle, but if you tuned it for your
  taxonomy, treat as adopter-owned and merge.
- **`.claude/settings.local.json`** — this is committed and **must keep the two
  critical keys** (`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`,
  `worktree.baseRef: "head"`). If an upgrade touches it, merge — never let a
  merge drop those keys (the probe's Layers I/J will catch it if one slips, but
  don't rely on catching it after the fact).

### Files you should not have touched

Some engine-owned files are *load-bearing enforcement* — if you edited one, an
upgrade will (correctly) fight you, and that's the system working:

- **Any `scripts/hooks/*.sh` enforcement hook.** Editing a hook's body is how you
  gut a guard; the probe's manifest-hash check exists precisely to catch it. If
  you *need* different enforcement behavior, express it through
  `orchestration.config` (the one file meant to be edited) — not by forking a
  hook. If you did fork one, an upgrade is your chance to move that
  customization into config and take the clean upstream hook back.
- **The probe and `install.sh`.** These verify and generate enforcement; a local
  edit to them silently weakens the guarantee they exist to provide. Take
  upstream.

If the probe flags a hash mismatch on a hook after an upgrade, that is the
correct signal that a hook you shouldn't have modified was modified — resolve it
by taking the upstream hook, not by regenerating the sidecar over your fork.

## The pull mechanic — two honest options

There is no magic merge for an engine an adopter has diverged from. Pick the
option that matches how doc-heavy vs. mechanically-invasive the release is (read
the `CHANGELOG.md` section to tell).

### Option 1 — the engine as an upstream git remote (subtree / merge)

Best when you want an ongoing, trackable relationship with upstream and are
comfortable resolving occasional conflicts.

```bash
# One-time: add the engine as a remote.
git remote add engine <engine-repo-url>
git fetch engine --tags

# On each release: fetch the tag and merge (or subtree-pull) it in.
git fetch engine --tags
git merge vX.Y.Z        # or: git subtree pull --prefix=. engine vX.Y.Z --squash
```

**Conflict guidance:**
- Conflicts in **engine-owned** files (`scripts/hooks/**`, `skills/**`,
  reference docs) → **take upstream** ("theirs"). You had no business diverging
  there; the conflict is just git noticing you did (or that a sidecar/generated
  file drifted).
- Conflicts in **adopter-owned** files (`CLAUDE.md`, `orchestration.config`, your
  workers, your wiki) → **resolve by hand, keeping your content** and layering in
  the structural change. These are the conflicts worth your attention.
- After resolving: **run the three golden-rule checks.** Green = the merge is
  sound.

Squash-merging (or `subtree --squash`) keeps your history readable and is
recommended unless you specifically want the engine's full commit history in your
log.

### Option 2 — diff-and-apply (for doc-heavy or small releases)

Best when a release is mostly docs and reference content (many are), or when you
don't want a remote relationship. No merge machinery — you read what changed and
apply it deliberately.

```bash
# Get the new version somewhere separate (clone or download the tag).
git clone --branch vX.Y.Z <engine-repo-url> /tmp/engine-vX.Y.Z

# Diff the engine-owned trees against your repo and copy across what changed.
diff -ru /tmp/engine-vX.Y.Z/scripts/hooks   scripts/hooks
diff -ru /tmp/engine-vX.Y.Z/skills          skills
# docs/ is NOT a single engine-owned tree — ONLY these four files are engine-owned.
# The rest (docs/audits/, docs/briefs/, docs/plans/, docs/design-system/) is
# YOUR content. NEVER `diff -ru … docs docs` + blind-copy — that would re-drop a
# shipped example over your pages or wipe them. Diff only the four named files:
for f in cost-governance.md failures-playbook.md orchestrator-memory.md ci-portability-notes.md; do
  diff -u "/tmp/engine-vX.Y.Z/docs/$f" "docs/$f"
done
# ...copy the engine-owned changes over; hand-apply CLAUDE.md.template and
#    orchestration.config deltas into your filled versions.
```

This is more manual but maximally controlled — you see every change before it
lands, and there is no chance of a merge silently touching an adopter-owned
file. It is the right default for PATCH releases and doc-only MINOR releases.

Either way, the closing step is identical and non-negotiable: **re-run
`install.sh` + the probe + the demo, and confirm green.**

## After a MAJOR upgrade — read the CHANGELOG first

For a MAJOR release, `CHANGELOG.md` will name exactly what breaks (a config key
renamed, a hook behavior changed, a doctrine rule reversed). Do the config/agent
edits it calls for *before* running the golden-rule checks — a MAJOR is the one
case where a red probe/demo after the merge is *expected* until you've applied
the documented migration steps. MINOR and PATCH releases should go green
immediately after the merge with no migration.
