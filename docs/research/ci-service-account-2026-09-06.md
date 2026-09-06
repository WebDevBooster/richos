# A separate Claude account for the CI instruction-channel check — cost and permission

**Researched 2026-09-06** on richos `5ad505b`, branch `clark-opus-sa1`. Every claim below carries
its source URL and the date it was read. Anything not settled from an Anthropic primary source is
marked `unverified:` and says what would settle it.

## The short answer

**Buy nothing.** The cheapest permitted option is an **Anthropic Console API key on pay-as-you-go
billing**: no subscription, no seat, no monthly fee, and the sentinel costs roughly **$2 to $11 a
month** depending on which model it runs. An API key drives Claude Code directly — it is the
*default* in every workflow example Anthropic publishes — so the cheap option is available.

**The terms permit it cleanly, and they permit it for a specific reason.** The Consumer Terms
prohibit automated access *"Except when you are accessing our Services via an Anthropic API Key"* —
the API key is the named exception, not a loophole. A Console key is governed by the Commercial
Terms instead, which contain no automation restriction at all.

**The CEO's instinct was right and it has a clause behind it.** Consumer Terms §2: *"You may not
share your Account login information ... with anyone else or make your Account available to anyone
else."* A personal subscription token in a public repository's secrets makes that account available
to everyone holding write access. He does not need to be talked out of that position.

**And there is a better answer to his actual objection than a second account.** Anthropic supports
**Workload Identity Federation** for GitHub Actions: the workflow trades its GitHub OIDC token for a
short-lived Anthropic token at run time. *"There are no static secrets to mint, store in CI, rotate,
or leak."* The repository holds no credential of any kind. It costs the same as the API key path,
because it bills as the same API usage.

---

## 1. What options exist

Every authentication route Claude Code documents, with what each one is.

| # | Option | What it is | Fixed cost |
|---|---|---|---|
| 1 | **Console API key** (`ANTHROPIC_API_KEY`) | A `sk-ant-...` key from the Claude Console, billed per token | **$0/month** |
| 2 | **Workload Identity Federation** to a Console **service account** | GitHub Actions OIDC token exchanged for a short-lived Anthropic token; no stored secret | **$0/month** |
| 3 | **Subscription OAuth token** (`CLAUDE_CODE_OAUTH_TOKEN`) | One-year token from `claude setup-token`, tied to a Pro/Max/Team/Enterprise subscription | Cost of the subscription |
| 4 | **A second Pro or Max subscription** used only for automation | A separate human-shaped account, driven by option 3 | $20–$100+/month |
| 5 | **A Team seat** for the robot | Same as option 3 but the seat is inside an organization | $40/month minimum (see §2) |
| 6 | **Enterprise seat** | Seat price plus usage at API rates, annual billing only | $20/seat/month + usage |
| 7 | **Cloud provider** — Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry | Inference billed through an existing cloud account | Cloud account cost |

Sources, all read **2026-09-06**:
<https://code.claude.com/docs/en/authentication> (options 1–3, 6, 7 — the "Authentication
precedence" list and "Generate a long-lived token");
<https://code.claude.com/docs/en/github-actions> (options 1–3, 7 and the federation inputs);
<https://platform.claude.com/docs/en/manage-claude/workload-identity-federation> (option 2);
<https://claude.com/pricing> (options 4–6).

Option 7 is listed for completeness and is not a candidate — there is no existing AWS, Google Cloud
or Azure account for this, so it means standing up a cloud account to avoid a $2 API bill.

## 2. What each costs

Read from <https://claude.com/pricing> on **2026-09-06**. Verified against the page's own raw text
rather than a rendered summary, because the summarizer collapsed the two Max tiers into one price.

**Subscriptions**

- **Free** — $0. *"Claude Code: No"* in the feature table. Not a candidate.
- **Pro** — *"$17 Per month with annual subscription discount ($200 billed up front). $20 if billed
  monthly."* Includes Claude Code.
- **Max** — *"From $100 Per month"*, and *"Choose 5x or 20x more usage than Pro"*. Includes Claude Code.
  - `unverified:` **the exact Max 20x price.** The page states only the "from" figure of $100 for
    both tiers; it never prints a separate number for 20x. Settled by starting the Max checkout flow
    and reading the price for the 20x tier, or by reading the plan's billing page in an account that
    holds it. It does not matter to this decision — Max is far more expensive than the recommendation
    either way.
- **Team** — *"For teams of 2 to 150"*. Standard seat *"$20 Per seat / month if billed annually. $25
  if billed monthly."* Premium seat *"$100 Per seat / month if billed annually. $125 if billed
  monthly."* *"Includes Claude Code and Claude Cowork."*
  - **The floor is two seats**, so the cheapest Team plan is **$40/month annual** or **$50/month
    monthly** — you cannot buy a single seat for a robot.
- **Enterprise** — *"Seat price + usage at API rates $20 /seat. Usage cost scales with model and
  task."* Billing is annual only.

**API, pay-as-you-go** — same page, "API" tab, read 2026-09-06. Per million tokens:

| Model | Input | Output | Cache read | Cache write |
|---|---|---|---|---|
| Fable 5.1 | $10 | $50 | $0.25 | $12.50 |
| Opus 5 | $5 | $25 | $0.50 | $6.25 |
| Sonnet 5 | $2 | $10 | $0.20 | $2.50 |
| Haiku 4.5 | $1 | $5 | $0.10 | $1.25 |

The page describes API access as pay-as-you-go with usage-based tiers and states no monthly fee.

`unverified:` **whether the Console imposes a minimum prepaid credit purchase** (historically a small
one, on the order of $5, which would be spend against the bill rather than a fee). The pricing page
does not mention one. Settled by opening <https://platform.claude.com> → Billing and reading the
minimum on the credit-purchase form.

**GitHub Actions minutes** are the other cost line. Anthropic's own note: *"the Claude Code GitHub
Action runs on GitHub-hosted runners, which consume your GitHub Actions minutes"*
(<https://code.claude.com/docs/en/github-actions>, read 2026-09-06). `unverified:` GitHub's current
terms for public repositories; historically standard GitHub-hosted runners are free on public
repositories, which would make this $0. Settled at
<https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions>.

## 3. What the terms actually permit — the clauses, quoted

This is the crux, so nothing here is paraphrased.

### The prohibition, and the exception built into it

**Anthropic Consumer Terms of Service, §3 "Use of our Services", effective October 8, 2025**, read at
<https://www.anthropic.com/legal/consumer-terms> on 2026-09-06. In the list of things you must not
use the Services to do:

> Except when you are accessing our Services via an Anthropic API Key or where we otherwise
> explicitly permit it, to access the Services through automated or non-human means, whether through
> a bot, script, or otherwise.

Two independent exits, both stated in the clause itself.

**Exit one — the API key — is named outright.** A runner driving Claude Code with an
`ANTHROPIC_API_KEY` is accessing the Services via an Anthropic API Key, and the sentence stops
applying. Nothing further is needed.

**Exit two — "where we otherwise explicitly permit it" — is discharged by Anthropic's own product
documentation for exactly this case.** From
<https://code.claude.com/docs/en/authentication#generate-a-long-lived-token>, read 2026-09-06:

> For CI pipelines, scripts, or other environments where interactive browser login isn't available,
> generate a one-year OAuth token with `claude setup-token`

and, of `CLAUDE_CODE_OAUTH_TOKEN` in the same page's authentication-precedence list:

> A long-lived OAuth token generated by `claude setup-token`. Use this for CI pipelines and scripts
> where browser login isn't available.

and from <https://code.claude.com/docs/en/github-actions>, read 2026-09-06:

> `CLAUDE_CODE_OAUTH_TOKEN`: an OAuth token that authenticates with your Claude subscription,
> available on Pro, Max, Team, and Enterprise plans.

Anthropic ships a first-party command whose stated purpose is CI, wires it into `/install-github-app`,
and names the plans it works on. **Reading that as an explicit permission is my judgment, not a
quoted contractual term** — the Consumer Terms do not point at the documentation. It is a strong
reading and I would act on it, but it is a reading, and it is the reason the recommendation goes to
the API key, where no reading is required.

### Why the CEO's refusal was correct

**Consumer Terms §2 "Account creation and access"**, same source and date:

> You may not share your Account login information, Anthropic API key, or Account credentials with
> anyone else or make your Account available to anyone else. You are responsible for all activity
> occurring under your Account and agree to notify us immediately if you become aware of any
> unauthorized access to your Account by sending an email to support@anthropic.com.

A public repository's Actions secrets are readable by every workflow the repository runs, and
writable by anyone with write access. Putting a personal subscription token there is making the
account available to others, and every action taken with it is the CEO's responsibility. His
objection is the clause.

### The Usage Policy does not prohibit unattended automation

**Anthropic Usage Policy, effective September 15, 2025**, read at
<https://www.anthropic.com/legal/aup> on 2026-09-06. The only clause touching this:

> Agentic use cases must still comply with the Usage Policy.

The "Do Not Abuse our Platform" section prohibits *"Utilize automation in account creation or to
engage in spammy behavior"* and coordinating activity across multiple accounts *"to avoid detection
or circumvent product guardrails"*. A single CI check running a few turns per change is neither.
**Unattended automation is not prohibited by the Usage Policy.**

### The API route sits under different terms entirely, and they are silent on automation

**Anthropic Commercial Terms of Service, effective June 17, 2025**, read at
<https://www.anthropic.com/legal/commercial-terms> on 2026-09-06. Scope:

> They govern Customer's use of Anthropic API keys and any other Anthropic offerings that references
> these Terms, as well as all related Anthropic tools, documentation and services (the "Services").

And the Consumer Terms hand off to them explicitly:

> Please note: If you are acting on behalf of an organization, company, or other entity, our
> Commercial Terms of Service govern your use of any Anthropic API key, the Anthropic Console, or
> any other Anthropic offerings that reference the Commercial Terms of Service. For clarity, this
> does not include Claude.ai or Claude Pro use for individuals or entities.

The Commercial Terms contain no automated-access prohibition, no bot clause, and no per-seat
concurrency restriction. **A robot on a Console API key is the case those terms are written for.**

### One flag on the personal-subscription route, and one limit on my ability to settle it

The version of the Consumer Terms served to this machine is the **United Kingdom / Ireland** one:
the counterparty is *"Anthropic Ireland, Limited"*, it says *"These Terms apply to you if you are a
consumer who is resident in the United Kingdom"*, and *"These Terms are governed by English law."*
It carries a clause that a US version may not:

> **Non-commercial use only.** You agree not to use our Services for any commercial or business
> purposes and we (and our Providers) have no liability to you for any loss of profit, loss of
> business, business interruption, or loss of business opportunity.

That sits inside the UK consumer-rights liability section (§11), alongside statutory-rights and
foreseeable-loss language that is a British consumer-contract construct. **If a clause of that shape
is also in the US terms, a personal Pro or Max subscription is not licensed for a company's CI at
all** — which would rule out options 3, 4 and 5 in one stroke.

`unverified:` **the text of the US Consumer Terms.** Both this machine's `curl` and the WebFetch
proxy egress from the UK/EU, so both were served the English-law version, and there is no
US-specific URL — `https://claude.com/legal/consumer-terms` returns 404, and
`?country=US` returns the same UK document. Settled by opening
<https://www.anthropic.com/legal/consumer-terms> from a US IP address and grepping for
`Non-commercial use only` and `Anthropic, PBC`. **This does not block the recommendation**, because
the recommended route is the API key, which is governed by the Commercial Terms and is unaffected
either way. It only matters if someone later proposes reusing a personal subscription.

## 4. The cheapest permitted option, and what it costs per month

**An Anthropic Console API key on pay-as-you-go. Fixed cost $0/month.**

The per-run cost is **measured, not estimated.** Tonight's Q4 evidence run left the token accounting
for exactly this shape of workload — a single short non-interactive Claude Code turn carrying the
full system prompt and tool definitions. Reproduce with:

```
cd /Users/alex/ab/richos/docs/verification/inner-doctrine-opens-2026-09-06/raw
python3 -c "
import json,glob,os
for f in sorted(glob.glob('cellM*.jsonl'))+['cellR0-same-cwd-normal-env.jsonl']:
    for line in open(f):
        d=json.loads(line)
        if d.get('type')=='result': print(os.path.basename(f), d['num_turns'], d['total_cost_usd'])
"
```

Output, five single-turn cells, all on **Opus 5** (`claude-opus-5[1m]`, confirmed from each run's
`system`/`init` frame):

```
cellM1-nonrepo-engine.jsonl 1 0.07085649999999999
cellM2-nonrepo-subdir.jsonl 1 0.07094149999999999
cellM3-repo-worktree-engine.jsonl 1 0.049878500000000006
cellM4-dotfiles-repo-home.jsonl 1 0.0718115
cellR0-same-cwd-normal-env.jsonl 1 0.0706665
```

**$0.050 to $0.072 per short turn on Opus 5**, at API rates. Scaling to "a handful of short turns per
change", taken as **5 turns per change and 30 changes a month = 150 turns**, and scaling the model
rates from §2 against the same token counts:

| Model the sentinel runs | Per turn | **Per month, 150 turns** |
|---|---|---|
| Opus 5 | ~$0.07 | **~$10.50** |
| Sonnet 5 | ~$0.03 | **~$4.20** |
| Haiku 4.5 | ~$0.015 | **~$2.10** |

The Sonnet and Haiku rows are the Opus measurement scaled by the published rate ratio (Sonnet is 40%
of Opus on every token class, Haiku 20%), not separately measured. The Opus row is measured.

**Compare against every alternative:** Team is **$40/month minimum** and cannot be bought as one
seat; a second Pro is **$20/month**; a second Max is **$100/month or more**. The API key is between
**4x and 50x cheaper** than the cheapest account you could buy, and it is the option whose permission
requires no interpretation.

**Prefer Workload Identity Federation (option 2) if the setup cost is acceptable.** Same bill, and it
removes the stored credential entirely, which was the CEO's actual objection. From
<https://platform.claude.com/docs/en/manage-claude/workload-identity-federation>, read 2026-09-06:

> Workload Identity Federation (WIF) lets your workloads authenticate to the Claude API with
> short-lived OpenID Connect (OIDC) tokens instead of long-lived `sk-ant-...` API keys. ... There
> are no static secrets to mint, store in CI, rotate, or leak.

GitHub Actions is a supported issuer, the Console has a guided **Connect workload** wizard for it,
and the GitHub Action takes it through three inputs — `anthropic_federation_rule_id`,
`anthropic_organization_id`, `anthropic_service_account_id` — plus the `id-token: write` permission
on the job. A **service account** (`svac_...`) is *"a named, non-human identity inside your Anthropic
organization"* that *"has no email, no password, and no Console login"*, and its usage bills against
its workspace *"the same as an API key"*. That is, literally, the separate account for automation the
CEO described — and Anthropic gives it away with the API rather than selling it as a seat.

Setting it up needs the admin, owner or primary-owner role in the Anthropic organization, which the
CEO has by virtue of creating it. Start with the API key, move to federation when convenient; the
migration path is documented and needs no downtime.

## 5. Can an API key drive Claude Code at all

**Yes. Unambiguously, and it is the documented default for CI.** This was the question that decided
whether the cheap option existed, and it does.

From <https://code.claude.com/docs/en/setup#authenticate>, read 2026-09-06:

> Claude Code requires a Pro, Max, Team, Enterprise, or **Console** account.

From <https://code.claude.com/docs/en/authentication>, "Authentication precedence", item 3, read
2026-09-06:

> `ANTHROPIC_API_KEY` environment variable. Sent as the `X-Api-Key` header. Use this for direct
> Anthropic API access with a key from the Claude Console. In interactive mode, you are prompted once
> to approve or decline the key, and your choice is remembered. ... **In non-interactive mode (`-p`),
> the key is always used when present.**

That last sentence is the operative one for a sentinel, which runs `--print`: no approval prompt, no
browser, the key is simply used. And every workflow example on
<https://code.claude.com/docs/en/github-actions> authenticates with `anthropic_api_key`; the
subscription token is the documented *substitution*, not the default.

### Three operational facts worth carrying into the implementation

1. **If the sentinel uses `--bare`, it must use an API key.** From the authentication page: *"Bare
   mode does not read `CLAUDE_CODE_OAUTH_TOKEN`. If your script passes `--bare`, authenticate with
   `ANTHROPIC_API_KEY` or an `apiKeyHelper` instead."* The cheap option is the only option there.
2. **A leftover `ANTHROPIC_API_KEY` silently shadows federation.** The WIF page carries this as a
   warning: `ANTHROPIC_API_KEY` sits above the federation tiers in credential precedence, so a
   migration that leaves the key in CI secrets keeps billing the key and looks like it worked.
3. **On a public repository, GitHub withholds secrets from fork pull-request runs** — Anthropic's
   own note on the GitHub Actions page. The sentinel will only ever run on branches in the
   repository itself, whichever credential it uses. Federation does not change this: the OIDC token
   is also restricted on fork runs. `unverified:` the precise fork-run behavior of the Actions OIDC
   token; settled at GitHub's OIDC documentation. It does not affect the purchasing decision.

## Recommendation

1. **Create an Anthropic Console organization and an API key for it.** $0/month fixed, roughly
   **$2–$11/month** of usage for this sentinel, permitted by the exception written into the Consumer
   Terms and governed by the Commercial Terms, which say nothing against automation.
2. **Do not buy a second subscription.** Pro is $20/month, Team cannot be bought below $40/month, and
   both leave open a non-commercial-use question this research could not close from a US source.
3. **Move to Workload Identity Federation when there is a spare hour.** Same bill, and the public
   repository then holds no credential at all — which is the thing the CEO objected to, solved rather
   than relocated.
4. **The personal subscription token stays out of the repository**, exactly as he ruled. The clause
   backing him is Consumer Terms §2, quoted in §3 above.
