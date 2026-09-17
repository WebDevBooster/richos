# The Google setup guide's multi-account paragraphs — a patch, because I hold no richos-hq workspace

The guide lives in the **other** repository: `richos-hq/docs/guides/google-workspace-oauth-setup.md`.
My spawn carried exactly one workspace, `/Users/alex/ab/richos-wt/norm-opus-multiacct1`, which is
`richos`, and `create-teammate-worktree.sh` refuses a second one under my name (exit 3, *"agent
norm-opus-multiacct1 already has a spawned registration in this session; names are used once"*). I did
not write into the shared `richos-hq` main checkout and I did not register a workspace under a name
that is not mine. Raised as `esc-20260917T015139Z-93146d7c`, state `proceeding`.

`norm-opus-ms1` hit the same wall an hour earlier and staged a whole new guide file in this
repository, which Rich then moved and deleted (`70f9785f`). Mine is an **edit to an existing file**,
so a staged copy would be a second spelling of a document that already exists — the thing that drifts.
A patch cannot drift: it either applies to the file as it stands or it refuses.

## Apply it

```
cd /Users/alex/ab/richos-hq        # or a richos-hq worktree
git apply -p1 <this directory>/google-workspace-oauth-setup-multi-account.patch
```

Verified `git apply --check -p1` → **exit 0** against `richos-hq` at the guide's blob `97d056d6`,
2026-09-17. If that check ever fails, the guide has moved underneath the patch; re-derive it rather
than force it.

## What it says

Six edits, each where a reader already is rather than in a new section at the end:

1. **What you'll end up with** — every address you want to connect is a test user, and as many Google
   accounts as you like, side by side.
2. **Step 3.2, Test users** — add *every* address, not only the one you signed in with. A
   Testing-mode app refuses the rest at Google's own consent screen, which is the one failure in this
   flow RichOS cannot explain for him.
3. **Step 5 + 6** — a new `### Adding a second Google account`: the same command with a different
   `--account`, no `--client-file` the second time, the `keeping:` line naming whose grant is
   untouched, the test-user precondition, `status`/`sync` covering every account with `--account` to
   narrow, the per-account `gmail: unavailable` line beside the other account's real count, and the
   note that a pre-2026-09-17 `_oauth_client.json` is rewritten as a list in place with nothing to do
   first.
4. **The config-file paragraph** — it holds a list of accounts, each with its own scopes, not one
   address.
5. **Step 7's `status` output** — the real header lines, and a sentence saying a second account prints
   a second block sharing nothing but the client ID.
6. **The 7-day note and Disconnecting** — each account has its own clock, and `disconnect` needs
   `--account` once two are connected (`--forget-cursors` drops only that account's cursors).

Every claim in it is behavior covered by a test in
`richos/tools/richos-service/test/workspace.js` — the `keeping:` line, the per-account unavailable
line beside a real count, the in-place migration message, the disconnect refusal and its list, and the
per-account `--forget-cursors`.
