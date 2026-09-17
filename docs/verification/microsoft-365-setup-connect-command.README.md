# The Microsoft 365 guide's Step 6 — a patch, because I hold no richos-hq workspace

The guide lives in the **other** repository:
`richos-hq/docs/guides/microsoft-365-setup.md`. My spawn carried exactly one workspace,
`/Users/alex/ab/richos-wt/norm-opus-msconnect1`, which is `richos`. My brief anticipated this and
asked for a patch, the way `norm-opus-multiacct1` delivered one for the Google guide on the same day
(`26ee76de`). I did not write into the shared `richos-hq` main checkout and I did not register a
workspace under a name that is not mine.

A patch cannot drift: it either applies to the file as it stands or it refuses. A staged **copy** of
the guide would be a second spelling of a document that already exists, which is the thing that
drifts — and `norm-opus-ms1` staged exactly that copy an evening earlier, which Rich then had to move
and delete (`70f9785f`).

## Apply it

```
cd /Users/alex/ab/richos-hq          # or a richos-hq worktree
git apply -p1 <this directory>/microsoft-365-setup-connect-command.patch
```

**Verified `git apply --check -p1` → exit 0** against `richos-hq` at commit `152a2203`, with the
guide at blob `25224bdf793534ca198d0fa1c7b0adfd33abd820`, on 2026-09-17. If that check ever fails the
guide has moved underneath the patch — re-derive it rather than forcing it.

## What it changes

**Step 6 was the guide's one unfinished section** — *"Not wired yet. The `workspace connect
microsoft` command is the one remaining piece"* — and the command landed on my branch
(`ee2e9392`). Three edits, each where a reader already is:

1. **Step 6 becomes the real command**, with the two IDs from Step 3 and the account address, and
   shows the block RichOS prints *before* the browser opens (account, client, **tenant**, the three
   scopes by name) so a mistyped tenant is caught there rather than after approving a consent screen.
   It explains that omitting `--source` re-requests whatever that account asked for last time, and
   that re-running for the same account re-consents rather than adding anything.
2. **The `AADSTS…` client-secret refusal gets its fix in the guide**, in the same words the refusal
   itself prints: *Authentication → Advanced settings → "Allow public client flows" = Yes*. It also
   says the other legitimate answer exists, so an organization that forbids public client flows is
   not stuck. Then a new **"More than one Microsoft 365 account"** subsection: the same command with a
   different `--account`, the `keeping:` line naming whose grant was untouched, one shared app
   registration and tenant, and `disconnect` needing `--account` once two are connected.
3. **"Things worth knowing afterwards"** gains what a sync actually prints — including the
   `promoted:` line, since `sync --once` now promotes what it pulled (`11ca5e79`) — and where the two
   IDs live (`_oauth_client_microsoft.json`, no secret in it, a separate file from Google's).
   Step 2's redirect URI also now says the string is matched character for character and that the two
   vendors do not share a port.

## Every claim in it is behavior a test covers

In `richos/tools/richos-service/test/workspace.js`, group *"`workspace connect microsoft` (P4)"* and
group *"`sync` PROMOTES what it pulled"*:

| Claim in the guide | Test |
|---|---|
| the command connects and stores in `com.richos.workspace.microsoft` | *connect microsoft completes the Entra ceremony and stores the grant under its OWN service* |
| the printed `tenant:` line, and no `/common` | same test, plus *a Microsoft config with NO tenant is refused* |
| the three scopes, read-only, `offline_access` added | same test (asserts the exchange body) |
| the AADSTS fix, in those words | *THE ENTRA REFUSAL THAT NAMES A ONE-LINE FIX* |
| the confidential-client escape hatch, secret in the Keychain and in no file | *--client-secret records the app as CONFIDENTIAL…* |
| a second account ADDS itself; `keeping:` names the first | *a second Microsoft account ADDS itself* |
| `_oauth_client_microsoft.json`, separate from Google's, redirect 53682 | *connect microsoft writes its own config file and never reads or writes Google's* |
| `disconnect` does not claim a revocation | *disconnect microsoft FORGETS LOCALLY and never claims a revocation Entra cannot perform* |
| the `promoted:` line and `--no-promote` | *sync PROMOTES…* and *--no-promote is a DIAGNOSTIC pull* |

`npm run -s test:workspace` → **328 passed, 0 failed** (55 of them Microsoft, counted from the run).
No live Microsoft call is made anywhere in the suite and no real credential exists in it.
