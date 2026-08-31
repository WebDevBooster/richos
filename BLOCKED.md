# BLOCKED — the proposed claim-guard rule does not clear the bar, and the number says so

**Raised 2026-08-31 by zach-opus-idlerows. Measured, not argued.**

## What I am blocked on

The brief's rule is: *the prose in-flight-dispatch signal fired AND no
`<role>-<model>-<identifier>` token appears anywhere in that message*, on the
stated expectation that this is "decidable and should be near-100% precision".

**It is not a filter at all.** Measured on the real corpus, same source as the
existing numbers, 4,134 turns / 3,532 with a final message:

```
prose signal fired                     30
  ...the message named an agent id      1
  ...the message named nobody          29   <- the proposed rule
```

**The refinement removes ONE hit out of thirty.** Hand-adjudicating all 29:

| verdict | n | what they are |
|---|---|---|
| TRUE  | 3 | "dispatching it rather than queuing it", "I'm dispatching that separation now", "Dispatching it as the next round:" |
| borderline | 1 | "Dispatching the moment the polish round lands" — a FUTURE dispatch, which by construction cannot name a live agent |
| FALSE | 25 | negations (6: "I'm not dispatching anything", "not re-spawning him"), quotations of the guard's own header (4), past tense (5: "spawning the duplicate at all"), hypotheticals (4), advice to a third party (3), and the word applied to a non-agent ("Launching the real app now") |

**Precision 3/29 = 10.3%** (13.8% counting the borderline). The rule it is meant
to replace measures 17%. **The proposal is measurably worse, and it cannot block.**

The reason is structural rather than a matter of tuning: the prose signal's
false positives are negations, quotations, past tense and hypotheticals — and
**none of those name an agent either**. "Names nobody" and "is a false alarm"
are almost the same set, so intersecting them changes nothing.

## What I already tried

**Candidate C — a bare capitalized roster role as the subject of a present-
progressive verb** ("Zach is building", "Dean is writing"). This is the actual
shape of the failure and it is far narrower than `dispatching|spawning|launching`:
102 hits over the same 3,532 messages.

**Candidate D — C, grounded on the roster the way the 0-FP agent-name check is
grounded.** 102 of 102 grounded, 0 would fire — including, and this is the
finding, **the real failing sentence itself**:

> "**Zach is building it now**, in the engine, alongside the three already running."

It grounds clean because a `zach-<model>-<id>` had been spawned EARLIER in the
same session, for different work. So "has this role ever been spawned" is the
wrong ground truth. The right one is **liveness** — is an agent of that role
running RIGHT NOW — which is what "is building it now" actually asserts.

## The smallest question that would unblock me

None for you; this is a finding, not a decision I need. **But you are telling the
CEO this is live today, and on the rule as written that would not be true.** You
need that now rather than in my final report.

## What I am proceeding on

Building the liveness-grounded version of Candidate D, which is the rule that
actually catches the sentence the CEO is angry about:

> a bare capitalized roster role used as the subject of a present-progressive
> verb requires a LIVE agent of that role — roster non-terminal, an owned
> worktree, or an Agent call in this same turn.

Inert when liveness cannot be established, exactly like the existing agent-name
check. If it measures 0 FP with the real failure firing, it blocks. If not, it
ships reporting and I will say so in the same breath.

The lead's rule ships too, as a REPORTING observation with its measured 10.3%
in its own docstring, so nobody promotes it later without re-measuring.
