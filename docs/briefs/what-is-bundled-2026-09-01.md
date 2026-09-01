# What is bundled with RichOS, and what is not — 2026-09-01

**Right now, four files ship inside RichOS and nothing else: the app itself, its icon, its
Info file and its signature. 8.8 MB to download.**

**Nothing else is in there.** No Claude Code. No Node. No speech software. No voice models.
No engine folder. Everything RichOS needs beyond those four files has to come from the
customer's own machine or be fetched later.

I built that app on this Mac today, ran it, and weighed it. Every number below came out of a
bundle I assembled and launched, not off a list.

**One question is now settled: RichOS does not need Node.** I ran a real conversation with
Node removed from the machine, and Rich answered. Then I launched the shipped app the same
way and it connected to Claude normally. That kills the old middle option outright.

---

## The inventory, plainly

| | today |
|---|---|
| **Inside the 8.8 MB download** | the app, its icon, its Info file, its signature. That is the whole list. |
| **Fetched later** | nothing. No download code exists yet. |
| **Customer must already have** | Claude Code (197 MB), an Anthropic account, a completed Claude login, the engine folder, and — for voice only — the speech program and a 488 MB model |
| **Customer must do by hand** | install RichOS; install Claude Code; open a terminal and log in to Claude; put the engine folder somewhere and point RichOS at it; name their company; install voice bits |

---

## Something I found that matters more than any of this

**A customer who double-clicks RichOS today cannot talk to Rich — even with Claude Code
installed and logged in.** Two reasons, both measured:

1. RichOS looks for its "engine" folder — Rich's personality, his habits, his skills — in a
   place that only exists on your Mac. It is 4 MB, it is not big, and **there is no way to get
   it onto anybody else's computer.** It is in none of the options below.
2. When it cannot find that folder, RichOS reports *"the claude binary was not found"* — the
   wrong cause. Whoever sets it up will go looking in entirely the wrong place.

Neither is a big job. Both are invisible until someone tries to install this, and nobody has.

---

## The options

### Option 1 — Ship nothing extra. Customer installs Claude Code themselves.
- **Download: 8.8 MB.** Fastest possible install for us; nothing to build.
- **The trade:** the customer has to find, install and log in to Claude Code before RichOS is
  worth anything. That is a technical errand for a non-technical person, and if they skip it
  RichOS opens a window and cannot speak.

### Option 2 — Ship nothing extra, but run Anthropic's own installer for them. *(your idea)*
- **Download: 8.8 MB, then 197 MB fetched on first run**, with their permission, using
  Anthropic's official installer.
- **The trade:** it removes one of two setup errands, not both — they still need an Anthropic
  account and still have to log in, and **we have no login screen**, so that step is still a
  terminal. Anthropic's installer keeps their code out of our signature, which is what we
  want. Offline, we can still check the fetched file is genuinely Anthropic's, and we can't
  check Apple's separate stamp — but the fetch needs the internet anyway, so that gap costs
  nothing real. **None of this is built. It is a plan, not a feature.**

### Option 3 — Put Claude Code inside RichOS.
- **Download: 94 MB.** Nothing to fetch, nothing to install, works the moment it opens.
- **The trade:** I proved it technically works — the copy inside runs, untouched, and our
  signature still verifies. But **we have no right to redistribute their program**; the
  documents permit pre-installing it, none permits copying it, and both licenses say all
  rights reserved. This is the weak branch for that reason and no other. Also: if anyone ever
  modifies that file it stops working outright — I broke it doing exactly that, and the broken
  copy still passes a naive version check, so it would ship dead.

---

## My recommendation — and it is a recommendation, not a decision

**Take Option 2, your own.** It is the only one that shrinks the customer's setup without
taking something that isn't ours, and it costs 8.8 MB either way.

**But it does not finish the job on its own, so I would rather you knew that now than after
someone tries to install it.** Option 2 removes one errand of five. The engine folder, the
login screen and the company-name step are the other four, and no choice between the three
options above touches any of them. If the goal is "a customer installs this and talks to
Rich", the remaining work is those four, not the 197 MB.

---

*Every command and every number: `docs/verification/payload-inventory-2026-09-01/README.md`,
which also lists what is still unproven — chiefly that Option 2 is a design and not code, that
nothing here is notarized yet, and that no fresh machine has ever been tried.*
