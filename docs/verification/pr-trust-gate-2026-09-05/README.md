# The pull-request trust gate — 2026-09-05

**State: CONFIGURED, NOT PROVEN.** Everything that can be checked without a second GitHub account
has been checked and is recorded below with the command that produced it. The one thing that
matters most — that a real stranger's pull request is actually closed, and that the person gets a
usable answer rather than a shut door — cannot be proven from here. It needs a pull request from an
account that is not the maintainer's, which is the maintainer's to run. The walkthrough for that is
§4, and §5 is the part worth reading twice: what a FALSE PASS looks like, so a workflow that
silently never ran is not read as "it let me through".

Nothing in this repository describes the gate as working. The workflow header, the workflows README
and this file all say the same thing until a named run has closed a named pull request.

---

## 1. What it does, on one screen

A pull request is opened or reopened. `.github/workflows/vouch-pr.yml` runs
`mitchellh/vouch/action/check-pr`, which asks one question about the AUTHOR:

- a repository collaborator with write or admin access → allowed, and the trust list is never read;
- a username in `.github/VOUCHED.td` **on the default branch** → allowed;
- an account ending in `[bot]` → skipped, which is why Dependabot is unaffected;
- anybody else → a comment is posted and the pull request is closed.

Three properties of that, because they are what make it fair rather than hostile:

- **Issues are NOT gated.** Vouch can gate issues; this repository deliberately does not, and there
  is no second workflow that does. Anybody may open an issue, report a bug, ask a question or
  propose a change. The gate is on the merge path only.
- **Nothing reads the diff.** It is not a quality check and not a security review. Nobody's code is
  being judged; their account is being checked against a list.
- **The closed-out author gets a real answer.** The comment says nobody has read their change, links
  to the contributing guide, says issues are open to them today, gives the one step that gets them
  approved, and tells them their commits are still there and the pull request can be reopened. The
  exact text is in `raw/close-comment-rendered.md`.

The files: `.github/workflows/vouch-pr.yml`, `.github/VOUCHED.td`,
`.github/CONTRIBUTING.md` (the policy in the contributor's own language), and
`.github/PULL_REQUEST_TEMPLATE.md` (the last warning before the button).

## 2. Why a first-time contributor's run is not held for approval

This is the fact that decides whether the gate is fast or theoretical. GitHub's default for public
repositories is that a **first-time contributor's** fork workflow run waits for a maintainer to
approve it. If that applied here, a stranger's pull request would sit open until the maintainer next
looked — and the whole point is that it does not sit.

It does not apply. GitHub's own documentation, verbatim:

> Workflows triggered by `pull_request_target` events are run in the context of the base branch.
> Since the base branch is considered trusted, workflows triggered by these events will always run,
> regardless of approval settings.

So the trigger choice is not only a security decision, it is the reason the gate is automatic. It is
also why the workflow must be on `main` before any of this happens: `pull_request_target` always
runs the file from the base branch, so a pull request that ADDS this workflow does not run it.

## 3. What was proven without opening a pull request, and exactly what each check proves

Every line here has a transcript in `raw/`, and every command in those transcripts can be run again.

### 3.1 The action is pinned to a real commit in the real repository

`raw/vouch-pin-resolution.txt`. `mitchellh/vouch`'s `v1` is an **annotated** tag: `git ls-remote`
prints two lines for it, and the first — `f23dbb5e745334f97414ec70463ce7301071a661` — is the tag
object, not a commit. It peels to `d66fa29a64600490892131ad87597c30c91fcac4`, which is also what
`refs/tags/v1.5.0` names, and `gh api repos/mitchellh/vouch/commits/<sha>` confirms that commit
belongs to that repository rather than to a fork.

**Proves:** the reference in the workflow is immutable and points at code the maintainer of vouch
published. **Does not prove:** that the action works, or that this pin is a good version to be on.

### 3.2 The trust list parses, and the right people match

`raw/vouched-td-parse.txt`. Vouch's own `from td` and `check-user`, run on this machine against this
repository's `.github/VOUCHED.td`: one vouch record, username `webdevbooster`, every other line
classified as a comment. `WebDevBooster`, `webdevbooster` and `github:WebDevBooster` all resolve to
`vouched`; `abooster` and `some-stranger` resolve to `unknown`.

**Proves:** the file is in the format vouch reads, matching is case-insensitive, and the thirty lines
of explanation above the entry are comments rather than accidental usernames. **Does not prove:**
that the workflow reads THIS file — the running job fetches it through the contents API from the
default branch, and only a live run exercises that path.

### 3.3 The message a closed-out contributor reads renders, and its links are alive

`raw/close-comment-rendered.md`. The message body was extracted from the workflow and rendered
through vouch's own `template render` with the record vouch itself passes. Both links in the result
were fetched: the contributing guide returns 200, and the new-issue chooser returns 200.

**This is the check that justifies the workflow not using vouch's default text.** The default points
the author at `CONTRIBUTING.md` at the repository ROOT, and that URL returns **404** here — this
project's guide lives at `.github/CONTRIBUTING.md`, and the root is nine entries by standing
decision. A bot that closes a stranger's weekend and then hands them a dead link is the exact
reputational cost this feature exists to avoid.

**Proves:** the template will render rather than error, and the reader lands on a real page.
**Does not prove:** that the comment gets posted — that needs the token, the API and a live run.

### 3.4 The YAML and the shell both lint, and the linter was made to fail first

`raw/actionlint.txt`. `actionlint` 1.7.12 with `shellcheck` 0.11.0 on PATH exits 0 with no output. A
silent pass proves nothing by itself, so a mutated copy — heredoc target unquoted, pin replaced by
`@v1` — was linted too, and it failed with `SC2086`.

**Proves:** shellcheck really is running against the step body, so the clean pass covers the shell as
well as the YAML. **Does not prove:** anything about pinning — actionlint said nothing at all about
`@v1`, so no linter in this repository will ever catch an unpinned action.

### 3.5 The permissions are the two declared ones, read back out of the file

The workflow was parsed independently and its permissions block dumped: `contents: read` and
`pull-requests: write`, and nothing else. That is the minimum that can comment on and close a pull
request.

### 3.6 No step checks out or runs the contributor's code

```
$ grep -n "checkout\|head\.sha\|head\.ref\|pull_request\.head" .github/workflows/vouch-pr.yml
36:# `actions/checkout` in this file at all, and nothing in it references
37:# `pull_request.head`. The only value taken from the event payload is the pull
39:# checkout of `github.event.pull_request.head.sha` here would hand a
```

Three hits, all of them inside the comment that explains why there are no others. There is no
`uses: actions/checkout` and no reference to the pull request's head anywhere in the file. The only
value taken from the event payload is the pull request NUMBER, an integer assigned by GitHub.

**Why it matters, in one sentence:** `pull_request_target` hands the job a token that can write to
this repository, so a step that ran the contributor's code would be running a stranger's code with
the maintainer's credentials.

### 3.7 The state every corrected document was checked against

`raw/repository-state.txt`. Public repository, issues on, three published releases (v1.0.0, v1.0.1,
v1.0.2, all 2026-09-04), three of five CI workflows active and two disabled in the file. The
contributing guide previously said there were no releases and no tags and that the workflows had
been disabled before publication; both statements were false, and both are corrected against this
output rather than against a memory of it.

## 4. The live test — the half that needs a second account

**Preconditions.** The branch is merged to `main` and pushed. `vouch-pr` appears on the Actions tab
in the left-hand list of workflows. You have a second GitHub account that is **not** a collaborator
on this repository and is not the owner — if it has write access it will pass by the collaborator
route and the trust list will never be consulted, which proves the wiring and nothing about the list.

Allow about two minutes per run: the job installs Nushell before it does anything.

1. **Confirm the workflow is live.** Open `https://github.com/WebDevBooster/richos/actions` and look
   for `vouch-pr` in the workflow list on the left. If it is not there, it is not on `main`, and
   nothing below will happen. *(Equivalent from a terminal:
   `gh api repos/WebDevBooster/richos/actions/workflows --jq '.workflows[].path'`, which should now
   include `.github/workflows/vouch-pr.yml`.)*

2. **Rehearse from your own account, harmlessly.** Open any trivial pull request — a one-word
   documentation fix on a branch of this repository. **Correct result:** a `vouch-pr` run appears
   within a minute, finishes green, and its log says `WebDevBooster is a collaborator with admin
   access`. The pull request stays open and receives no comment. Then close it yourself.
   **What this proves:** the trigger fires, the pin resolves, the runner can install Nushell, the
   token works, and the job reaches a decision. **What it does not prove:** anything about
   `.github/VOUCHED.td` — the collaborator check returns before the file is ever read. If the log
   instead says `is in the vouched contributors list`, that is fine too; it means the collaborator
   lookup returned nothing and the list was read and matched instead.

3. **The real test.** Sign in as the second account. Fork the repository, change one word in a
   documentation file, and open a pull request against `WebDevBooster/richos` `main`.
   **Correct result, within about two minutes:** the pull request is **closed**, and it carries one
   comment beginning "Hi @<that account>, thank you for this and sorry about the abrupt
   landing.". The `vouch-pr` run for it is
   green and its log reads `<that account> is not vouched` then `Closing PR`. Click the contributing
   guide link in the comment and confirm it opens a real page rather than a 404.

4. **Approve that account.** In the GitHub web interface on `main`, open `.github/VOUCHED.td`, click
   the pencil, add the second account's username on its own line at the bottom, and commit directly
   to `main`. Nothing else — no deploy, no restart.

5. **Reopen the same pull request.** As the second account, press **Reopen** on the pull request
   from step 3. **Correct result:** a second `vouch-pr` run appears, its log says
   `<that account> is in the vouched contributors list`, no comment is posted, and the pull request
   **stays open**. That is the line that proves the trust list itself is being read and honored, and
   step 3 alone does not prove it.

6. **Clean up.** Close the pull request yourself, then edit `.github/VOUCHED.td` on `main` again and
   delete the test account's line. Confirm the file is back to one name.

7. **Write down what happened,** in §7 of this document: the two pull request numbers and the two
   run IDs. That is what turns "configured" into "proven", and it is the only thing that does.

## 5. What a FALSE PASS looks like

Every item here is a way the test can look like it succeeded when nothing was gated. **In each case
the fix is the same: open the run and read it. The absence of a comment is not evidence.**

1. **No run ever started, and the pull request stayed open.** This looks exactly like "it let me
   through". Check the Actions tab for a run of `vouch-pr` whose event is `pull_request_target` and
   whose title is that pull request. No run means the workflow is not on `main`, or is disabled, or
   the event types were edited. **A pull request that stays open with no run is a FAILURE, not a
   pass.**

2. **The run is red, and the pull request stayed open.** A job that errors closes nothing. Red looks
   like a normal CI failure and is easy to skim past, but here it means the gate did not gate. The
   likeliest causes are the unpinned Nushell interpreter (see §6), a rate limit, or a bad pin.

3. **You tested with an account that is a collaborator.** The log says `is a collaborator with …
   access`, the pull request stays open, and it proves the wiring only. The trust list was never
   read. Any account you have added to this repository — or an organization owner — passes this way.

4. **You tested with your own account and concluded the gate works.** Same thing as (3), and it is
   the easiest mistake to make because it is the convenient one. Step 3 of §4 exists because it is
   the only step that exercises the "close a stranger" path.

5. **The run says `skipped`.** Vouch skips any account whose username ends in `[bot]`. If a test is
   ever run from an app or bot identity, a skip is correct behavior and not a pass.

6. **The comment appeared but the pull request is open.** Vouch comments and then closes, in that
   order, so this means somebody reopened it — possibly you, possibly the author — and the reopen
   fired a second run whose result is the one that counts. Read the newest run, not the oldest.

7. **Step 5 "passed" without step 4 taking effect.** If the edit to `.github/VOUCHED.td` went onto a
   branch rather than `main`, the file the job reads is unchanged and the reopened pull request will
   be closed again. Confirm the commit landed on `main` before reading the result as a failure of
   the gate.

## 6. How it fails, and how to stop it in a hurry

**The two directions are not symmetric.** If the job errors for any reason, nothing is closed and an
unapproved pull request simply waits for a human — tolerable. If `.github/VOUCHED.td` is deleted or
renamed, vouch catches the fetch error, reads an empty list, and closes **every** non-collaborator
pull request — safe, but silent. Neither failure announces itself.

**The known time bomb.** The action is a composite: its first step installs Nushell through
`hustcer/setup-nu` at `version: "*"`, so the vouch code is pinned and its interpreter is not. On
Nushell 0.115.1, vouch's `parse-handle` already prints a deprecation warning for `str downcase`,
which that release says will be removed in a future version. The transcript in
`raw/vouched-td-parse.txt` keeps the warning rather than filtering it, because it is the evidence.
When the removal lands, this job starts erroring and the gate quietly stops gating. The fix at that
point is to move the pin to a vouch release that has fixed it.

**Turning it off takes one action and no deploy:**

- Actions tab → `vouch-pr` → the `…` menu → **Disable workflow**. Effective immediately; open pull
  requests are untouched. *(Terminal equivalent: `gh workflow disable vouch-pr.yml --repo
  WebDevBooster/richos`, re-enabled with `gh workflow enable`.)*
- A pull request closed by mistake is reopened from its own page, and reopening re-runs the gate —
  so add the person to `.github/VOUCHED.td` on `main` FIRST, then reopen, or it closes again.
- Approving somebody is one edit to `.github/VOUCHED.td` on `main` and takes effect on their next
  opened or reopened pull request.

## 7. The record that would make this "proven"

Filled in by whoever runs §4. Until both rows carry a run ID, the honest description everywhere in
this repository stays "configured, not proven".

| what | pull request | run ID | result | date |
|---|---|---|---|---|
| unapproved author is closed | | | | |
| same author, approved, reopened, stays open | | | | |

## 8. What was deliberately left out

- **Issue gating.** Out of scope by decision, not oversight, and §1 says why.
- **Automated approval by issue comment.** Vouch can add somebody to the list from an issue comment;
  that needs a GitHub App and a token that can commit past branch protection. One edit in the web
  interface is cheaper than that machinery at this volume.
- **Branch protection on `main`.** Recommended as a follow-up rather than done here. The gate filters
  who reaches the review queue; branch protection is what prevents an accidental merge of somebody
  who does reach it. They are different jobs and the second one is a repository setting, not a file.
- **Enforcing SHA pinning at the repository level.** `sha_pinning_required` is off; turning it on
  judges every workflow this repository ever gains, so it stays the maintainer's call.
  `.github/workflows/README.md` carries the one command.
