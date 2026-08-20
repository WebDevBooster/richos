# Cost governance — what a sprint costs, and the levers that control it

Roadmap item C3. This document exists because "a company that runs itself"
that never mentions its own run-rate is a fiduciary risk, not a feature — a
CEO's first surprise invoice is a churn event. Everything below is grounded
in the kit's own shipped doctrine and role-template mix (cited by section, so
the references survive line-number drift), **not invented numbers.** Where an actual dollar figure would matter, this
doc tells you to check current provider pricing instead of baking one in —
token pricing moves, and a stale number is worse than an honest "go check."

## The one lever that actually controls spend: model tiering

The **Models** paragraph in `CLAUDE.md.template` §"How to Delegate" is the
whole mechanism:

> "definitions default to Opus for the judgment-critical roles (architect /
> senior advisor / CTO / design gatekeeper / adversarial QA — don't
> downgrade) and Sonnet for the rest. Override per spawn (`model: "opus"`)
> the moment a Sonnet teammate's task stops being routine — subtle
> multi-file bugs, security-sensitive logic, adversarial verification,
> load-bearing doctrine."

This is not aspirational — it's the actual default baked into every shipped
role template. Counted directly from `.claude/agents/templates/*.md` and the
four live meta-agents:

| Tier | Roles (as shipped) | Count |
|---|---|---|
| **Opus** | `architect`, `cto`, `designer-ux-gatekeeper`, `adversarial-visual-qa` (role templates); `frank` (devil's-advocate meta-role) | 5 of 20 named roles (25%) |
| **Sonnet** | Every other role template (`backend-engineer`, `frontend-engineer`, `fullstack-engineer`, `mobile-engineer`, `infra-engineer`, `automation-qa`, `functional-qa`, `device-qa`, `copywriter`, `marketing`, `domain-advisor`, `domain-expert`); `dean`, `clark`, `reed` (meta-roles) | 15 of 20 named roles (75%) |

**Why the split lands where it does — the actual reasoning, not a rule of
thumb:**

- **Judgment-critical roles have high blast-radius and low reversibility.**
  An architecture call, a security review, a devil's-advocate stress-test, or
  a design-gatekeeper signoff shapes everything built downstream, and a wrong
  call here is expensive to walk back regardless of what it cost to make.
  Paying for the strongest available judgment on these decisions is a small
  premium relative to the downside of getting one wrong.
- **Mechanical/high-volume roles have low blast-radius per spawn, precisely
  because the QA pipeline exists to catch their mistakes.**
  `CLAUDE.md.template` §"QA Pipeline — Mandatory for ALL Code Changes":
  **"Any failure at any step loops back to
  step 1"** — every engineer commit passes through Automation QA (10/10
  required), Functional QA (10/10 required), and the Design gatekeeper (≥9/10
  required) before the CEO ever sees it. A routine implementation mistake
  gets caught and bounced back structurally, by the pipeline, independent of
  which model wrote the original code. Paying Opus rates for every routine
  spawn doesn't make those mistakes less likely to happen — the pipeline
  already exists to catch them — it just multiplies the token bill across
  every one of the (many) routine spawns in a sprint without buying a
  corresponding reduction in risk.

This is the real cost-control insight: **the mandatory QA pipeline is what
makes it *safe* to default routine work to the cheap tier.** Without a QA
gate, you'd want a stronger model on everything since nothing else would
catch a mistake. With the gate, over-provisioning Opus on mechanical work is
redundant insurance you're already paying for via the pipeline.

## The per-spawn override — the tactical lever

`CLAUDE.md.template` §"How to Delegate" (the **Models** paragraph) again:
override a specific Sonnet-tier spawn to Opus "the moment a Sonnet teammate's
task stops being routine":

- subtle multi-file bugs (the failure mode isn't localized to one file/function),
- security-sensitive logic (auth, tenant isolation, payment handling, secrets handling),
- adversarial verification (a second, non-collusive check on a high-stakes verdict),
- load-bearing doctrine (a change to the orchestration rules themselves, not product code).

**"The override is per-instance"** (same line) — it doesn't change the
role's default tier going forward, only that one spawn. This is the dial you
reach for mid-sprint when a specific task's stakes exceed its role's usual
profile, not something you decide once at hire time.

## What a sprint costs — order-of-magnitude reasoning, not a quote

The honest answer to "what will this cost me" has two parts that multiply,
and only one of them is stable enough to write down:

**Stable (structural, doesn't depend on token prices):**

- **Spawn count** — how many teammates get spawned in a sprint, and how many
  times each is re-spawned (a FIX-FIRST bounce through the QA pipeline is an
  ADDITIONAL spawn cycle, not free — this is the real cost of quality, and
  it's proportional to how often the pipeline actually catches something).
- **Role mix** — with the shipped defaults, roughly 1 in 4 named roles is
  Opus-tier; a typical sprint's spawn count is dominated by the *mechanical*
  roles (engineers, QA) doing the bulk of iterative work, so the Opus-tier
  *share of total spawns* in practice tends to be lower than the 25%
  role-count ratio above — Opus roles (architect, CTO, gatekeeper,
  adversarial QA) are invoked for planning/judgment moments, not every
  iteration.
- **Context per spawn** — a spawn prompt that cites a full file read, a long
  audit history, or an extensive doctrine excerpt costs more (in tokens, and
  therefore in money) than a narrowly-scoped, well-defined task regardless of
  model tier. Vague prompts that force a teammate to explore/re-read/
  backtrack cost more than a precise one — this is a lever independent of
  model choice (see "Effort as a lever" below).

**NOT stable (depends on your provider's current pricing — check it, don't
trust a number written here):**

- The per-token rate for Opus vs. Sonnet. Anthropic's pricing has
  consistently priced Opus meaningfully higher than Sonnet per token, but
  the exact multiple is not something this document pins down — check
  [anthropic.com/pricing](https://www.anthropic.com/pricing) (or your
  current plan/contract rate) for today's numbers before doing any real
  budgeting math.
- Absolute dollar figures for "a sprint." A sprint's actual token
  consumption depends entirely on your product's complexity, your team's
  size, how many FIX-FIRST loops the QA pipeline triggers, and how tightly
  scoped your spawn prompts are — multiplying an unstable per-token rate by
  a project-specific spawn count would produce a number that looks precise
  and is actually just wrong the day pricing changes. **Don't budget off a
  number in this document — build your own estimate from your provider's
  current rate card and your own early sprints' actual spawn counts, then
  revisit it periodically.**

## Levers, in the order to reach for them

1. **Model tier per role** (set at hire time, in the role template Dean
   instantiates from) — the primary, structural lever. Leave the shipped
   4-Opus/12-Sonnet template split alone unless you have a specific reason
   to change a role's *default* judgment requirements.
2. **Per-spawn `model: "opus"` override** — the tactical lever, for the
   specific task that departs from its role's routine profile this one time
   (see above). Cheaper than permanently upgrading a role's tier, because
   it's scoped to the one spawn that actually needs it.
3. **Effort as a lever, independent of model tier** — a narrowly-scoped
   spawn prompt with an explicit, observable completion criterion (what
   "done" looks like, stated up front) costs less than an open-ended one
   regardless of which model does the work, because it reduces the
   exploration/backtrack/re-read cycles a vague prompt forces. Tight scoping
   is a cost lever you control on every single spawn, for free.
4. **When the cheap tier is safe to lean on hardest:** routine, well-scoped,
   pipeline-backed work — which, per the QA Pipeline section above, is most
   of what a sprint's engineer and QA spawns actually are. The mandatory
   4-step gate (`CLAUDE.md.template` §"QA Pipeline — Mandatory for ALL Code
   Changes") is precisely what makes defaulting
   this work to Sonnet a sound bet rather than a risk.

## Where this does (and doesn't) live in `orchestration.config`

Model tiering is **not** an `orchestration.config` setting — there is no
`MODEL_TIER_DEFAULT` variable to fill in, and adding one would be misleading
about how the mechanism actually works. The real control point is the
`model:` field in each role definition's YAML frontmatter
(`.claude/agents/<slug>.md`), set when Dean instantiates a role from
`.claude/agents/templates/*.md` (which already ship with the tier comment
inline, e.g. `model: opus   # judgment-critical role — keep opus`), and
overridden per-spawn via the `Agent` tool call's own `model` parameter. This
document intentionally does not add tiering-default comments to
`orchestration.config` for that reason — the templates themselves are
already the right place, and already carry the guidance.
