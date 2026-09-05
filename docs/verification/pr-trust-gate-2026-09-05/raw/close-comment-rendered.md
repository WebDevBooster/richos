The exact comment an unapproved contributor will read, rendered on 2026-09-05
by vouch's own `template render` at the pinned commit, from the message body
extracted out of `.github/workflows/vouch-pr.yml`.

Rendered with the record vouch itself passes: author `some-stranger`, owner
`WebDevBooster`, repo `richos`, default branch `main`. Rendering it at all is
the check that matters, because Nushell's `format pattern` errors on a stray
brace, and a template that fails to render is a job that closes nothing.

Both links in it were fetched: `.github/CONTRIBUTING.md` returns 200, and
`issues/new/choose` returns 200. Vouch's DEFAULT template links to
`CONTRIBUTING.md` at the repository root, which returns 404 here.

--- 8< --- rendered output begins ---

Hi @some-stranger, and thank you for this — sorry about the abrupt landing.

**RichOS accepts pull requests only from a short list of approved GitHub accounts.** Yours is not on it yet, so this pull request was closed automatically. Nobody has read your change: this is a rule about who may open a merge request here, not a judgment of your work.

The rule and the reasons for it are in the contributing guide:
https://github.com/WebDevBooster/richos/blob/main/.github/CONTRIBUTING.md

**Issues are open to everyone, and nothing about that has changed.** Bug reports, questions and proposals are welcome from anybody, including you, today:
https://github.com/WebDevBooster/richos/issues/new/choose

**To ask for approval,** open an issue describing what you would like to work on, and say that you would like to be added to the contributor list. That is the whole process — a maintainer adds your username to `.github/VOUCHED.td` on the default branch, and your pull requests stay open from then on. There is one maintainer, so a reply can take a while, and approval normally follows a conversation about the change rather than arriving cold.

**Your work is not lost.** This pull request still holds every commit you pushed, and the branch is still in your fork. Once your username is on the list, reopen this same pull request and it will stay open.

