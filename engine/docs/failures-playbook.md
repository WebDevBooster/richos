# Failures playbook — operational failure modes, distilled

This is a playbook of failure modes a multi-agent orchestration setup runs
into in practice, not in theory — each rule below already has a home
somewhere in this engine's own shipped doctrine (`CLAUDE.md.template`); this
document is the consolidated, teachable version, generic only. No product
specifics — every entry is a pattern class, not an incident report.

**How to use this:** read it once before you run a multi-agent sprint for
real, then keep it as a reference for the moment something feels wrong and
you can't immediately tell if it's a bug in your setup or a known failure
class. Each entry: **Symptom → Why it happens → The rule → How to recover.**

This playbook seeds `docs/orchestrator-memory.md`'s persistent operational
memory (see that doc for the boundary between "generic rule, lives here" and
"this-project-specific lesson, lives in the orchestrator's own memory
files") — and the relationship runs both ways: a memory entry that turns out
to generalize beyond one project graduates into a new entry here.

---

## 1. Negative-only gate tests pass for the wrong reason

**Symptom:** a test suite is green, but the feature it's supposed to gate is
completely broken.

**Why it happens:** a test that only checks "the bad case is correctly
rejected" (a permission-denied test, an invalid-input test) can pass even
when the entire underlying feature is non-functional — rejection is trivially
true if nothing works at all. The test proves the failure path exists; it
proves nothing about the success path.

**The rule:** always pair a negative test with a **positive-shape probe** —
a test that proves the good case actually works, not just that the bad case
is refused. `CLAUDE.md.template`'s QA doctrine states this explicitly:
*"Always pair a negative test with a positive-shape probe that proves the
good case still works."*

**How to recover:** when a suite looks suspiciously green given the state of
the feature, audit for missing positive-shape coverage first, before
assuming the code is actually correct.

---

## 2. Non-handoffs — a completion notification is not a report

**Symptom:** a teammate reports "done" or fires an idle event, but nothing
useful actually landed — no commit, or a commit that doesn't match the
claimed work.

**Why it happens:** a teammate kicks off a long-running or background
operation (a build, a test run) and then stops and reports before the
operation actually finishes — the notification arrives, but the result it's
narrating doesn't exist yet.

**The rule:** a completion notification with a stub result ("waiting on the
run") is not a handoff. `CLAUDE.md.template` → Git Worktree Isolation: *"a
completion notification with a stub result... is not a report — inspect the
worktree, resume ONCE to commit+verify+report, then take over if it loops."*

**How to recover:** inspect the teammate's worktree directly. If the
background operation is still genuinely running, resume the teammate once to
let it finish, commit, and report properly. If it loops on the same
non-handoff a second time, take the narrow, specific fix over yourself rather
than resuming indefinitely.

---

## 3. Never infer agent death from filesystem inactivity

**Symptom:** a teammate's worktree hasn't changed in a while, and it's
tempting to conclude the agent died or gave up.

**Why it happens:** agents legitimately do substantial thinking/work before
flushing anything to disk — a quiet worktree looks identical whether the
agent is deep in a hard problem or genuinely gone.

**The rule:** liveness is a **positive** signal, never an absence of one.
`CLAUDE.md.template`: *"Liveness = the worktree lock (`git worktree list` →
`locked` while running; never touch a locked worktree)."* Absence from a
visible roster also isn't proof of death — background/isolated agents don't
always appear where you'd expect them to.

**How to recover:** check the actual lock state before concluding anything.
If genuinely stuck, send an explicit shutdown/status request and wait for a
real termination signal — never act on an inference from silence alone.

---

## 4. Tangle recovery — one clean replacement, not a pile-on

**Symptom:** two or more teammates that were supposed to be independent seem
to have wandered into each other's state — duplicated work, conflicting
commits, or confusing cross-talk.

**Why it happens:** concurrent same-type agents occasionally drift into
shared assumptions or state they shouldn't share, especially under retries
or re-spawns that weren't cleanly terminated first.

**The rule:** shut down **all** suspected agents, wait for real
terminations, then spawn **exactly one** clean replacement under a **new**
name on a **fresh** worktree. Don't add a third or fourth agent to untangle
the first two — that compounds the problem.

**How to recover:** resist the urge to patch around a tangle live. Full stop,
full restart with one clean instance is faster and safer than trying to
reconcile confused concurrent state.

---

## 5. Idle means committed

**Symptom:** a teammate goes idle, and its worktree still has uncommitted or
untracked changes.

**Why it happens:** a teammate treats "I'm done thinking" as equivalent to
"I've handed off," without the final commit step that actually makes the
work durable.

**The rule:** commit — or explicitly defer with a clear reason — **before**
going idle, never after. An idle event carrying a nonzero uncommitted-changes
count is a red flag, not a completed handoff, because the handoff *is* the
commit (see #6).

**How to recover:** if you see a teammate idle with uncommitted changes,
don't assume the work is safe. Resume it to finish the commit, or, if it's
truly abandoned, decide explicitly whether to take over or discard — never
leave it in limbo.

---

## 6. Mailbox lossiness → durable substrates, never a message

**Symptom:** a teammate's status update, or a course-correction sent to a
teammate, seems to have been ignored or never arrived.

**Why it happens:** the agent-to-lead (and lead-to-agent) chat channel is
lossy by design in a multi-agent setup — messages can and do drop, roughly
half the time in practice. Anything that depends on a message surviving is
fragile by construction.

**The rule:** **no load-bearing signal ever depends on the mailbox.**
Durable substrates only: the git commit, the task store, hook-written event
logs, the spawn prompt. A courtesy chat summary is welcome but advisory —
never the trigger for anything, never retried, never waited on.

**How to recover:** if something seems to not have arrived, don't resend and
wait — go read the durable substrate directly (the commit, the task state,
the event log) and act on that ground truth instead.

---

## 7. Wedged-agent takeover is narrow

**Symptom:** a teammate is clearly stuck (wedged, looping, or has produced
a non-handoff twice), and it's tempting to just finish its whole task
yourself.

**Why it happens:** taking over feels faster than diagnosing and re-spawning,
especially under time pressure.

**The rule:** takeover is for **narrow, 1-line fixes only** — never a full
re-implementation of the teammate's task. If the fix is bigger than that,
the correct move is diagnosing why the agent wedged and spawning a fresh
replacement (see #4), not quietly absorbing its whole scope yourself.

**How to recover:** ask "is this a one-line unblock, or am I about to do this
teammate's entire job?" before touching anything. If it's the latter, stop
and re-spawn instead.

---

## 8. Verify-at-consumption, not on a schedule

**Symptom:** something that was verified as correct earlier turns out to be
stale or wrong by the time it's actually used.

**Why it happens:** verifying once, early, and trusting that result forever
assumes nothing changed in between — a false assumption the moment anything
else lands in the same window.

**The rule:** verify freshness **at the moment of consumption**, not on a
schedule or "once at the start." A check that ran an hour ago says nothing
about the state right now if anything could have changed since.

**How to recover:** re-run the actual verification immediately before you
rely on its result, every time — never reuse a prior verification's
conclusion across a time gap you didn't control.

---

## 9. "It looks right" is not verification — run the verifier

**Symptom:** a claim (a number, a build state, a "yes it's deployed")
sounds plausible and is accepted without an independent check.

**Why it happens:** a confident, specific-sounding claim is easy to mistake
for a verified one, especially from a source that's usually right.

**The rule:** if a verifier exists, run it — don't reason your way to "this
looks correct" as a substitute. This engine's own convention: prefer a script's
real exit code over a narrated conclusion, every time one is available.

**How to recover:** before repeating or acting on a claim, ask "is there a
command I could run that would prove or disprove this?" — if yes, run it.

---

## 10. Silent-fail-open guards are worse than no guard

**Symptom:** an enforcement mechanism (a guard, a gate) is supposed to block
something unsafe, but under some untested condition it silently lets the
unsafe thing through instead of refusing.

**Why it happens:** a guard's happy-path logic gets tested; the failure mode
of one of *its own* dependencies (a missing interpreter, an unset config
value) doesn't, and that gap defaults to "allow" instead of "refuse."

**The rule:** every guard must **fail closed** — any condition it can't
positively confirm as safe should block loudly (non-zero exit, clear stderr
naming the missing dependency), never pass silently. A guard that fails open
under a plausible real-world condition is a false sense of security, which
is worse than admitting there's no guard at all.

**How to recover:** audit every guard's own dependency list (interpreters,
config files, external tools) and deliberately test what happens when each
one is missing or malformed. If the answer is ever "it lets the thing
through," that's a required fix, not a nice-to-have.

---

## 11. Vocabulary leaks that a literal grep can't catch

**Symptom:** a "fully generic" claim about a document or codebase turns out
to still contain domain-specific vocabulary — not the literal banned terms a
grep sweep checks for, but adjacent words that carry the same meaning.

**Why it happens:** a grep sweep for known literal strings only catches
exact matches. A domain's vocabulary extends beyond its proper nouns — role
names, feature names, and framing that are specific to one project without
using any of its literal banned terms.

**The rule:** a literal-string grep sweep is necessary but not sufficient for
a genericization claim. A human read-through for domain-adjacent vocabulary
— not just the banned literal list — is still required before calling
something fully generic.

**How to recover:** when a "zero project content" or "fully generic" claim
matters, don't stop at a clean grep. Read the actual content once, looking
specifically for words that assume one particular domain's roles, users, or
concepts even without naming the project itself.

---

## 12. Resume ≠ spawn — a guarantee enforced at spawn lapses on resume

**Symptom:** a teammate that was already finished, landed, and cleaned up gets
a follow-up message, wakes back up, and starts working — but with none of the
safety a fresh spawn would have had (no isolated workspace, or writing where it
shouldn't). Or: two teammates answer to the same name and you can't tell which
is the live one and which is a ghost of a completed run. Or: you delete a
worktree seconds after a "done" notification and destroy work that was still
being committed.

**Why it happens:** three closely-related boundary bugs.
- **Resume bypasses spawn-time enforcement.** The guard that forces every
  file-writing teammate into an isolated worktree only runs at *spawn*. Sending
  a message to a *completed* teammate RESUMES it from its transcript — a code
  path the spawn guard never sees. If that teammate's worktree was already
  landed and removed, it wakes with no workspace and improvises: a hand-rolled
  worktree at best, main-checkout writes or lost work at worst.
- **Name reuse creates live-vs-ghost ambiguity.** If a name can be reused
  within a session — whether the first holder is still active or long
  completed — "message X" and "spawn X" become ambiguous, and latest-wins
  shadowing makes it impossible to reason about which instance you're talking
  to.
- **Completion notifications race cleanup.** A "done" signal can arrive while
  the final commit is still flushing, or before you've confirmed the branch tip
  is what you expect. Deleting the worktree on the strength of the notification
  alone can throw away real work — and, conversely, *not* being able to reach a
  teammate by name is not proof it died (it may simply have completed and been
  pruned from the roster).

**The rule:**
- **Never resume a landed/cleaned agent for file work — spawn fresh.** A
  file-bearing follow-up gets a NEW teammate in a NEW isolated worktree, never
  a resume. The only sanctioned resume of a completed teammate is a
  deliberate, audited one (a pure question, or a serialized external-repo
  writer) carrying an explicit acknowledgement of where any writes will land.
- **Never reuse a name.** A name used once in a session — active or completed
  — is spent. Identifiers are free; pick a fresh `<role>-<model>-<identifier>`
  (the `<model>` token must stay truthful to the model that instance boots on).
- **Re-verify at the moment of deletion, never on the notification.** Before
  removing a worktree, confirm the branch tip is exactly what you expect
  (right there, immediately before the delete — see #8, verify-at-consumption).
  Treat unreachable-by-name as **"completed"**, not **"dead"** — require a
  positive termination signal before concluding death (see #3).

**How to recover:** if you catch yourself about to message a finished
teammate to "just tweak one thing," stop and spawn a fresh one instead. If two
instances share a name, treat it as a tangle (#4): shut both down, spawn one
clean replacement under a new name. If a delete already raced a commit, recover
the work from the branch (the commit is the durable handoff, #6) rather than
trusting the notification's timing. This engine enforces the first two structurally
— `scripts/hooks/guard-resume-isolation.sh` (PreToolUse[SendMessage]) blocks the
unsafe resume, and `scripts/hooks/guard-worktree-isolation.sh` blocks name reuse
(union of a self-maintained ledger + the roster + the idle/task event logs).

---

## 13. Zombie residue — a background child outlives its agent AND its worktree

**Symptom:** an agent stalls and is taken over or replaced; its worktree is
landed and removed. Hours later, state appears in a worktree path that no longer
exists in `git worktree list` — a directory under `.claude/worktrees/agent-<id>/`
is back on disk, holding fresh per-run artifacts (a build seal, a lock, a
render snapshot). Downstream tooling trusts that artifact, even though git
considers the worktree gone.

**Why it happens:** a long-running verification (a device install/build, a seed
run, a sync) is often launched as a *detached background* process. That process
can outlive BOTH the agent that started it AND the worktree it ran in. When the
worktree is reaped with `git worktree remove`, git deletes the directory and its
registry entry — but the still-running orphan holds an open working directory and,
on its next state-write step, simply `mkdir -p`s the path back into existence and
writes into it. The re-created directory is *native-shaped* (`agent-<hex>`), so a
name-based residue check never flags it; and killing the agent does not kill a
process that already double-forked away from it. Cleaning up *directories* alone
leaves the *process* running to re-create them.

**The rule:**
- **Reap processes, not just directories.** When taking over or retiring a
  stalled agent, hunt the orphans: `pgrep -fl '.claude/worktrees/agent-'` and
  kill any process referencing a worktree that is no longer registered.
- **Run long verification in the FOREGROUND** so it dies with its agent, rather
  than detaching it to outlive the workspace it depends on.
- **Make state-writers refuse an unregistered location.** A script that writes
  under a worktree should prove, at startup and before each write, that its own
  location is the true main checkout or a currently-registered worktree —
  identity-or-refuse on its *own* path — and create nothing otherwise.
- **A residue detector must key on registration, not on name shape.** Any
  directory under `.claude/worktrees/` absent from `git worktree list` is unowned
  and safe to auto-reap (re-verify registration immediately before the `rm`, and
  never touch a registered worktree); any process referencing such a path is
  report-only (it may be mid-write — killing is the operator's call).

**How to recover:** kill the orphaned process first (directories it re-creates
are harmless once it is gone), then remove the residue directory, then re-verify
`git worktree list` shows only live worktrees. If a build seal or render snapshot
was minted into a ghost path, treat it as untrusted — re-run the verification
foreground from a registered location. This engine's advanced tier demonstrates the
state-writer refusal inline in `reference/advanced-tier/{android,ios}-install-fresh.sh`;
the mechanical layer's `scripts/hooks/detect-nonnative-worktree.sh` auto-reaps
unregistered residue directories and reports orphaned PIDs with a kill command.

---

## 14. A well-written file in a PUBLISHED repository is also a disclosure

**Symptom:** a rule's file explains itself perfectly — and in doing so tells a
stranger the date a private recording leaked, whose it was, who else was on it,
how many quotes went in, and what the guard still cannot catch. Nobody was
careless; the file is exactly as good as the doctrine asks it to be.

**Why it happens:** "write the WHY into the file, including the failure that
produced the rule" is correct, and it assumes the repository is a private
workspace. That assumption is false the moment a repository is published, and
nothing in the writing habit notices.

**The rule:** it has two modes, and `.publication-boundary` at the repository
root is the signal for which one you are in. Private: unchanged, write it all.
Published: the file carries the rule and the general reasoning in full; the
incident that caused it lives in the private record with a one-line pointer.
The test is **identifying detail**, not "is it an incident" — and it applies to
test fixtures and default config tables as much as to prose.

**Stated in full, once, in `CLAUDE.md.template`, "Writing for a Repository That
PUBLISHES — the same doctrine, in two modes".** Deliberately prose with no hook
behind it: this is a rule to read before writing, not a refusal to meet after.

---

## See also

- `docs/orchestrator-memory.md` — the orchestrator's own persistent
  operational memory, which this playbook seeds and is fed by (see that
  doc's "How this relates to this playbook" section).
- `CLAUDE.md.template` — every rule above already lives somewhere in the
  shipped doctrine; this playbook is the consolidated, cross-referenced
  version for teaching and onboarding, not a new source of truth.
