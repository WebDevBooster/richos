# Onboarding Runbook — the white-glove setup session

**Audience: the operator** (the technical person helping a CEO adopt this
engine) — not the CEO. If you're the CEO reading this yourself, the
[README's Adopter flow](./README.md#adopter-flow) and
`skills/bootstrap-interview/SKILL.md` are what you actually need; this
document is the script for someone sitting with you (or on a call with you)
to run the session.

**What this is:** an exact, timed script for a live setup session with a
non-technical CEO — the commands to run, the output that means "this step
worked," realistic timings, and the specific stalls this has hit before with
their exact fix. **What this is not:** a replacement for reading the README
or the bootstrap interview skill — it assumes you (the operator) have
already read both, and packages that knowledge into a runnable session plan.

---

## Preflight — before the session

Send this checklist (or the email template below) at least a day ahead, so
the session itself isn't spent waiting on installs:

- [ ] **Operating system** — macOS, Linux, or Windows? (Windows changes the
  plan — see "Common stalls" below; find out before the session, not during
  it.)
- [ ] **Claude Code installed** and the CEO has successfully logged in /
  authenticated at least once (open it, confirm it responds to a simple
  prompt — don't just confirm it's downloaded).
- [ ] **git installed** (`git --version` prints something).
- [ ] **A repo to adopt into** — either an existing project repo, or
  confirmation they want to start with just this engine cloned standalone.
- [ ] **~90 minutes set aside**, ideally with no other calls butting up
  against the end (bootstrap interviews run long when the CEO has a lot to
  say — that's a good sign, not a problem, but plan for it).

### Preflight email template

```
Subject: Before our setup session — 3 quick things

Hi [name],

Ahead of our session on [date/time], three things to confirm so we don't
lose time on setup during the call:

1. What operating system are you on — macOS, Windows, or Linux?
2. Do you already have Claude Code installed and logged in? (If you can open
   it and it responds when you type something, you're set. If not, no
   problem — just let me know and we'll do that first on the call.)
3. Is there an existing project repo you want to set this up in, or are we
   starting fresh with just the engine?

That's it — see you [date/time]. Budget ~90 minutes; it usually runs a bit
under that, but we won't rush the interview part.

[operator]
```

---

## Session agenda

Run these in order. Each step names the exact command, what "green" looks
like, and a realistic timing. Don't skip a step because a later one "should"
catch the same thing — each one exists because it catches something the
others don't.

### Step 1 — Mint the sidecars (~2 min)

The hooks themselves are already wired: they register in exactly ONE committed
file, `.claude/settings.local.json`, which Claude Code reads directly (no
generated `.claude/settings.json` — a second copy would make every hook fire
TWICE, the double-fire Layer M now guards). `install.sh` no longer wires hooks;
it mints the gitignored `.sha256` integrity sidecars the probe's hashing needs,
and migrates away any stale hook-duplicating `settings.json` left by an older
install.

```bash
scripts/hooks/install.sh
```

**Expected green** (on a fresh clone with no stale `settings.json`):
```
✓ no settings.json to migrate — settings.local.json is the sole settings file
✓ refreshed hook sha256 manifests
```
(If an older install left a hook-duplicating `settings.json`, the first line reads
`✓ migrated: removed stale hook-duplicating .claude/settings.json …` instead —
that is the de-duplication migration, and re-running converges to the line
above.)

If this doesn't print both lines cleanly, stop here — nothing after this
step will work reliably. See "Common stalls" below.

### Step 2 — The integrity probe, 17 layers (~2 min)

```bash
scripts/hooks/contract-integrity-probe.sh
```

**Expected green** (all seventeen, `A` through `Q`):
```
richos-engine v1.0.0 — contract integrity probe
  ✓ A. .claude/settings.local.json present (canonical hook source)
  ✓ B. write-guard -> guard-main-checkout-writes.sh (path-confined, manifest-matched)
  ✓ C. PreToolUse[Agent] chain -> guard-worktree-isolation.sh, guard-definition-drift.sh, reader-teammate-hint.sh, verify-agent-prompt.sh (path-confined, manifest-matched, in order)
  ✓ D. wired write-guard rejects main-checkout source writes (exit=2 canary)
  ✓ E. wired Agent hook chain scripts present + executable (4 entries)
  ✓ F. TeammateIdle hook wired + present (idle-event logging active)
  ✓ G. TaskCompleted hook wired + present (completion logging active)
  ✓ H. PostToolUse[Agent] detect-nonnative-worktree.sh wired + present (worktree-guard detector active)
  ✓ I. env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="1" present in .claude/settings.local.json
  ✓ J. worktree.baseRef="head" present in .claude/settings.local.json
  ✓ K. secrets scanner wired + rejects a known-bad secret (path-confined, manifest-matched, exit=2 canary)
  ✓ L. PreToolUse[SendMessage] guard-resume-isolation.sh wired + blocks an unresolvable resume (path-confined, manifest-matched, exit=2 canary)
  ✓ M. registration uniqueness — each canonical hook wired exactly once; single-fire canary logged 1 line for 1 registration(s)
  ✓ N. .claude/settings.local.json is git-tracked (will reach the next clone)
  ✓ O. Bash-write guard wired + denies a main-checkout source write (path-confined, manifest-matched, exit=2 canary)
  ✓ P. definition-drift pair wired exactly once (SessionStart snapshotter + PreToolUse[Agent] guard) + blocks drift (exit=2) + allows unchanged (exit=0) — path-confined, manifest-matched
  ✓ Q. worktree-reaper chain wired exactly once (SessionStart wrapper + reap-stale-worktrees.sh) + reaps a merged/clean tree (reaped=1) + REFUSES a dirty one (skipped=1) — path-confined, manifest-matched
```

(Layer N is the git-tracked check. If the CEO copied the engine in but hasn't
committed yet, N may read `⚠ … not yet git-tracked` — a warning, not a failure;
it becomes a green `✓` once the file is committed. A hard `✗ N.` means the
global-gitignore trap — see "Common stalls" below.)

Exit code `0`. Any `✗` here is a stop-and-fix, not a "note it and continue" —
see "Common stalls."

### Step 3 — The 60-second proof, 7/7 beats (~2-3 min)

```bash
scripts/demo.sh
```

**Expected green:** ends with
```
✓ Your team's enforcement machinery works. 7/7 beats passed.
```
This is the moment to actually narrate what's happening to the CEO as it
scrolls by — beats 1-3 blocking/allowing a spawn, beat 4 a real worktree
commit, beats 5-6 a defect caught and fixed, beat 7 the merge + re-verified
probe. This is the "watch it work" moment — don't rush past it. If you have
time, this is also a natural moment to point at `WALKTHROUGH.md` and say
"that's the same story, but the full version, if you want to read it later."

### Step 4 — Provision `CLAUDE.md` (~3 min)

The engine ships `CLAUDE.md.template`, and Claude Code only auto-loads
`CLAUDE.md` — so until this step runs, **a bare boot is generic Claude, not
Rich.** Copy `identity.config.example` to `identity.config`, fill in at least
`COMPANY_NAME` and `CEO_NAME` (ask the CEO how they want to be addressed; it
is the name Rich will use), then:

```bash
scripts/provision-claude-md.sh
```

Green looks like one line:
```
provisioned: /path/to/engine/CLAUDE.md (engine 1.0.0, template ce051221d1ce1383)
```

The script refuses rather than guessing: a blank company or CEO name is an
error, not a `TODO` written into live doctrine. It is safe to re-run at any
time — unchanged inputs are a no-op, and a `CLAUDE.md` the CEO has since
edited is **never** overwritten.

Worth saying out loud to the CEO here: every section the interview hasn't
filled yet now reads *"Not configured for this installation … ask the CEO
rather than assuming"*. That is deliberate — Rich asks instead of inventing.

### Step 5 — The bootstrap interview (~20-30 min, the bulk of the session)

Have the CEO talk to the orchestrator directly from here — tell it to run
`skills/bootstrap-interview/SKILL.md`. Your job for this step is mostly to
get out of the way and let the conversation happen, stepping in only if the
CEO gets stuck on what a question means. Remind them: **short answers are
fine, "not sure yet" is a completely valid answer, and this is resumable** —
if you're running short on time, stopping partway and picking up later
costs nothing.

Watch for the session ending in a real, printed **G5 verification pass**
(the skill re-runs `install.sh` + the probe + `demo.sh` itself, and should
end green) before you consider this step done — a bootstrap interview that
was interrupted mid-generation is not the same as one that finished.

### Step 6 — The CEO queue (~5 min, and do not skip it)

The engine ships a lint, a commit guard, a predicate and a test suite for the
CEO queue — **all of which are inert until the repository carries a
`.ceo-queue` declaration.** For one release there was no template and no step
here, so adopters received enforcement machinery that could never fire and
nothing told them. This step is why that cannot happen again.

```bash
scripts/ceo-queue-init.sh /path/to/their/repo
```

It writes the declaration, a starter record, renders `CEO-QUEUE.md`, puts a
pointer at the top of their `README.md`, runs a **cold open** (a reader with no
context, asked what the repository wants from them), and finishes by running the
lint so the CEO watches the whole thing pass on their own repository.

**Expected green:** ends with

```
✓ CEO queue clean: 0 item(s) in section(s) 1 2 are prepared — artifact on disk, time, done, unblocks.
  entry point: CEO-QUEUE.md — present, singular, named at the head of README.md, byte-current with docs/open-items.md.
```

Say three things to the CEO out loud here, because they are the whole contract:

1. **`CEO-QUEUE.md` is where their work lives.** One page, repository root,
   nothing else to remember. It is regenerated from the record — never edited by
   hand, and the commit guard refuses a copy that has drifted.
2. **Nothing reaches that page unprepared.** An item may not claim to be waiting
   on them unless the file they open already exists, the time cost is stated,
   and "done" is written down. Unprepared work is filed as `BLOCKED-ON-RICH` in
   section 3 and is Rich's problem, not theirs.
3. **The page gets read by a stranger, on purpose.** `scripts/cold-open.sh`
   asks a reader with no context what this repository wants from them; the
   transcript is committed, and changing the front door invalidates it. The gate
   checks that the reading happened, never what it concluded — so an unflattering
   transcript is a finding, not a failure.

If the cold open cannot run (no network, no `claude` on PATH), init leaves
`COLD_OPEN_DIR` commented out and prints the exact line to uncomment later.
That is deliberate: declaring it without a transcript on file would refuse every
commit in the repository from that moment on.

### Step 7 — Orientation tour (~15-20 min)

With a staffed team and a wiki that already has real content, walk the CEO
through, briefly:

- `CLAUDE.md` (their now-filled operating manual) — just enough to know it
  exists and where the QA-pipeline bars live.
- `ceo-wiki/wiki/000_index.md` — the pages the interview just created.
- `ceo-inbox/` — the two subfolders and what each is for.
- `ceo-briefings/` — where they'll see status without asking for it.
- `team/NAMING.md` — the naming convention behind every teammate's name, in
  case they ever want to rename or add one themselves.
- How to spawn a real task: give the orchestrator one small, real piece of
  work and watch it route to the right teammate.

**Total realistic session time: ~60-90 minutes**, with the bootstrap
interview (Step 5) taking the largest and most variable share — a CEO with a
lot to say about their business will run long there, which is a good sign,
not a scheduling failure.

---

## Common stalls — and the exact fix

### "Nothing happened" / no output at all from `install.sh` or the probe

Almost always **missing `python3`**. Every enforcement hook fails **closed**
(refuses loudly), never silently — you should see one of:
```
ERROR: install.sh: python3 is required (JSON generation + sha256 fallback) — refusing
ERROR: contract-integrity-probe.sh: python3 is required for settings.json parsing + path-confinement checks — refusing (fail-closed)
```
**Fix:** install Python 3 (`python3 --version` should print something
afterward), then re-run the step. This is the single most common stall —
check it first if anything in Steps 1-3 looks wrong.

### Claude Code responds strangely, or the bootstrap interview never starts

Usually **Claude Code isn't authenticated**, not an engine problem — this should
have been caught in preflight, but if it wasn't: have the CEO open Claude
Code standalone (outside this session) and confirm it responds to a plain
prompt before touching any engine commands.

### Probe fails on Layer I specifically

```
✗ I. env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS missing or not "1" in .claude/settings.local.json (got: '<unset>'). SYMPTOM: the orchestrator will see/spawn ZERO teammates at the NEXT session start, with NO error shown — this has happened before.
```
This is the engine's single most consequential settings key — see README's
"Critical configuration — never remove." **Fix:** restore
`"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` in
`.claude/settings.local.json`, then re-run `install.sh`. (Layer J is the
same failure shape for `worktree.baseRef` — same fix pattern, different
key.)

### Probe fails on Layer M (double-fire)

```
✗ M. .claude/settings.json registers N hook(s) — Claude Code MERGES it with settings.local.json, so every duplicated hook fires TWICE.
```
Hooks register in exactly ONE file, the committed `.claude/settings.local.json`.
A stale, hook-duplicating `.claude/settings.json` (left by an older install that
generated one) is being merged alongside it, so every duplicated hook fires
twice. **Fix:** run `scripts/hooks/install.sh` — it removes the pure-duplicate
`settings.json` (or strips just its hooks if it carries machine-specific
non-hook config), converging to single-registration. Re-run the probe to
confirm Layer M is green.

### Probe fails on Layer N (settings.local.json not git-tracked)

```
✗ N. .claude/settings.local.json exists on disk but is NOT git-tracked AND is matched by a gitignore rule ... Fix: git add -f .claude/settings.local.json
```
The engine's single most load-bearing file (the sole hook-registration source plus
the two critical keys) is **committed by design**, but a global-gitignore
convention — `**/.claude/settings.local.json` in `~/.config/git/ignore` (git's
default `core.excludesFile`, the way vanilla Claude Code treats that file) —
made `git add -A` **silently skip it**. It looks committed but isn't, so the
CEO's *next* clone/session would strand with no teammates and no error. **Fix:**
force-add it past the ignore rule, then commit:
```bash
git add -f .claude/settings.local.json
git commit -m "Track the committed-by-design settings.local.json"
```
Re-run the probe; Layer N goes green. (A `⚠ N. … not yet git-tracked` warning,
by contrast, just means the file hasn't been committed at all yet — commit it
normally and the warning clears.)

### The CEO is on Windows

**Windows needs WSL.** Every hook is a bash script invoked directly by
`.claude/settings.local.json` — there is no native-Windows execution path
today. Set this expectation in preflight, not mid-session: have WSL
installed and the repo cloned *inside* the WSL filesystem before the
session starts. See `docs/ci-portability-notes.md` for the full portability
reasoning (what's been checked clean for macOS/Linux, and why Windows is the
one real gap).

---

## Definition of done — machine-checkable, not a feeling

The session is done when all four of these are true, not when it "feels"
finished:

1. `scripts/hooks/contract-integrity-probe.sh` exits `0` (all 17 layers, `A`
   through `Q`, green — Layer N may be a `⚠` warning rather than a `✓` if the
   repo isn't committed yet; that is acceptable, a hard `✗ N` is not).
2. `scripts/demo.sh` prints `7/7 beats passed` and exits `0`.
3. `scripts/provision-claude-md.sh --check` exits `0` — a real `CLAUDE.md`
   exists and matches the current template + identity values, so a bare boot
   comes up as Rich rather than generic Claude.
4. The bootstrap interview's own **G5 verification pass** completed green in
   this same session (not a prior, now-stale run).

If all four are true, hand the CEO the `README.md` and
`WALKTHROUGH.md` pointers for anything they want to read later, and end the
session — there's nothing else required to call this a completed onboarding.
