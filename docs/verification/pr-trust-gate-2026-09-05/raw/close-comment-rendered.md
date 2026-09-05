The exact comment an unapproved contributor will read, rendered on 2026-09-05
by vouch's own `template render` at the pinned commit, from the message body
extracted out of `.github/workflows/vouch-pr.yml`.

**REWRITTEN BY THE CEO, 2026-09-05, and carried back to the source in the same
commit.** He edited the wording here, in the evidence — which changes nothing by
itself: this file is a photograph of a render, and the text that actually gets
posted is the heredoc in the workflow. His wording was templated back into that
heredoc (the sample values below substituted out for `{author}`, `{owner}`,
`{repo}` and `{default_branch}`), and this block was then RE-RENDERED from the
workflow's own bytes and compared: byte-for-byte identical to what he wrote. His
twelve markdown hard line breaks — lines ending in two spaces — survive the YAML
block scalar and the heredoc intact, which is what makes them render as breaks.

**Nothing checks that these two stay in step.** Editing either one alone makes
the other false, silently. And a stray `{` or `}` anywhere in the text is a
render error, which is a job that closes nothing — so the templating step
asserts that the only braces present are those four placeholders.

Rendered with the record vouch itself passes: author `some-stranger`, owner
`WebDevBooster`, repo `richos`, default branch `main`. Rendering it at all is
the check that matters, because Nushell's `format pattern` errors on a stray
brace, and a template that fails to render is a job that closes nothing.

Both links in it were fetched: `.github/CONTRIBUTING.md` returns 200, and
`issues/new/choose` returns 200. Vouch's DEFAULT template links to
`CONTRIBUTING.md` at the repository root, which returns 404 here.

--- 8< --- rendered output begins ---

Hi @some-stranger, thank you for this and sorry about the abrupt landing.

**RichOS accepts pull requests only from a short list of pre-approved GitHub accounts.**  
And because yours wasn't on that list, this pull request was closed automatically.  
So, nobody has read your change.  
But this is a rule about who may open a merge request here, not a judgment of your work.

The rule and the reasons for it are in the contributing guide:  
https://github.com/WebDevBooster/richos/blob/main/.github/CONTRIBUTING.md

**Issues are open to everyone and nothing about that has changed.**  
So, bug reports, questions and proposals are welcome from anybody, including you, today:  
https://github.com/WebDevBooster/richos/issues/new/choose

**If you'd like to get on the list of pre-approved accounts,**  
open an issue describing what you would like to work on and say that you would like to be added to the contributor list.  
That's it.  
A maintainer adds your username to `.github/VOUCHED.td` on the default branch and your pull requests stay open from then on. Just keep in mind: there's only one maintainer at present.  
So, a reply can take a while and approval normally follows a conversation about the change rather than arriving cold.

**Your work is not lost.**  
This pull request still holds every commit you pushed and the branch is still in your fork.  
So, once your username is on the list, just reopen this same pull request and it will stay open.

