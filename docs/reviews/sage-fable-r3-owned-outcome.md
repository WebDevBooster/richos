# Third review of Codex `5f519822` (`codex/owned-outcome-completion`)

Reviewer: Sage (`sage-fable-r3`). Reviewed against the second review of record,
`richos-hq/docs/carry-forward/sage-fable-r2-review-of-record.md`. Read-only on
the Codex worktree; every probe below was run on a scratch copy or by reading
Codex's own committed evidence. Committed in pieces on purpose.

## Verdict (provisional until the last section says "final")

**Merge, but do not activate.** Same verdict as the second review, for a
different reason. The second review said "do not activate" because the guard
got the English wrong. This commit fixes that by removing the English-matching
altogether: the dependency question is now put to a model, grounded in the
CEO's actual messages and declared rulings, and the six r2 probe sentences all
come back right in Codex's recorded run. What is new is the *shape* of the
guard: every teammate dispatch in an adopted repository now costs a model call,
can take up to four minutes, and refuses the dispatch — with no escape hatch —
whenever that model call cannot run. That is safe to merge because the adoption
file is committed nowhere and the unadopted path is unchanged. It is not yet
safe to switch on.

Codex's own results page says the same thing in its own words: *"The requested
no-babysitting outcome is not certified."*

## Finding 1 — the predicate changed kind, not just content (items 1 and 2)

The regex the second review broke (`not ` / `n't ` lookbehind) no longer
exists. owned-work-policy.sh (Codex branch, engine/scripts/lib) now hands the whole spawn
payload to owned-dispatch.py (same directory, same branch), which collects the pending
CEO items, the declared rulings and the session's user messages, sends them to
`richos-run audit-dispatch` (the tool-free registrar), and then **validates the
model's citations by string membership** against those sources
(`validate()`, lines 106–130). A verdict of `authorized` must quote a CEO
message or a declared ruling; a quote that is not in the source is refused.
A prompt sentence is not an input to the verdict at all beyond being shown to
the model — the brief cannot self-authorize.

Codex's recorded semantic corpus (`evidence-r3/semantic/inputs.json`,
`result.json`) contains the six r2 sentences verbatim:

| r2 probe | expected | recorded |
|---|---|---|
| "This in no way depends on the CEO's decision." | independent | independent |
| "Nothing here is blocked by the CEO's decision." | independent | independent |
| "An earlier brief said it depends … that is no longer true." | independent | independent |
| "The CEO hasn't answered." | pending | pending |
| "We cannot proceed without his ruling." | pending | pending |
| "We are waiting for the CEO's answer." | pending | pending |

Note what grounds the `independent` verdicts: each cites the CEO's own line
*"Repair the independent local parser defect."* — not the brief's claim. That is
the right design and it is what the r2 review asked for.

Two honest limits on that table. It is one model run, not a determinism claim;
the corpus went **14/15 (`passed: false`)** on the fifteenth case, where the
model said `authorized` and the corpus expected `independent` — both allow the
dispatch, so operationally harmless, but it is the corpus's own exit 1 and Codex
kept it as failed. And the fixture is easy: one CEO message that literally
contains the word "independent". I did not spend model runs re-running the
corpus; the baseline brief said not to.

**What this costs.** Under adoption the guard's control flow is:
collect → model call (≤120 s) → validate → collect again → compare. Any
exception — runner missing, timeout (150 s), transcript unreadable, a session
with zero user messages, a child dispatch with no saved leader binding, or the
sources changing mid-review — prints `CEO DEPENDENCY UNVERIFIED` and exits
**2, refusing the dispatch**. There is no `ceo-todos-deferred:` on this path;
the marker is only read by the legacy branch. The guard file's own header
(lines 90–94) argues that a guard which "wedges every dispatch over its own
plumbing is a guard that gets switched off". The adopted path now does exactly
that, by design, and the only switch is editing `.claude/owned-work.json`.
`hooks.json` raises this hook's timeout from 20 s to 240 s to make room.

That is a defensible trade for a fail-closed authority check. It is not a
trade the CEO has been shown, and it lands in the same week he is holding work
for quota: a model call per spawn is a quota line item.
