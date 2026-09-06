# GitHub accounts approved to open a pull request against RichOS.
#
# ANYONE MAY OPEN AN ISSUE. This file gates pull requests and nothing else.
# Bug reports, questions and proposals are welcome from everybody, including
# people who will never appear in this file. Nothing here touches issues,
# discussions, forks, or the right to use the software.
#
# Read by `.github/workflows/vouch-pr.yml` through mitchellh/vouch. A pull
# request whose author is not on this list, and is not a repository
# collaborator with write or admin access, is commented on and closed
# automatically, usually within a minute of being opened.
#
# THE FORMAT, which is vouch's, not ours:
#
#   * One GitHub username per line, with no leading @.
#   * A leading minus denounces: `-someuser` is blocked. A denounce does not
#     override collaborator access -- vouch checks collaborator permission
#     first and returns early -- so it blocks outsiders, not insiders.
#   * `#` starts a comment. Text after a username on the same line is a note
#     attached to that entry.
#   * Usernames ending in `[bot]` never reach this file at all; vouch skips
#     bots, which is why Dependabot's pull requests are not closed.
#
# TO APPROVE SOMEBODY: edit this file on `main` -- the GitHub web interface is
# enough -- add their username on its own line, and commit. It takes effect on
# their next pull request. No deploy, no restart, nothing to restart. Deleting
# a line withdraws the approval the same way.
#
# THE FILE THAT COUNTS IS ALWAYS THE ONE ON `main`. The workflow fetches it
# from the default branch through the API, so a pull request that adds its own
# author to this file changes nothing about itself.
#
# IF THIS FILE IS DELETED OR RENAMED, the gate fails CLOSED: vouch reads an
# empty list and every non-collaborator pull request is closed. That is the
# safe direction, but it is silent, so do not rename it casually.
#
# How a contributor gets on this list is written for contributors, in plain
# language, in `.github/CONTRIBUTING.md`.

# The maintainer. He is also the repository owner, so he would pass the
# collaborator check even if this line were missing; it is here so the list is
# never empty and so the format has a worked example on it.
WebDevBooster
