# The `nightly-channel` branch: why the ruleset allowed it, and the commands that closed it

**Date:** 2026-09-17 · **Agent:** zach-opus-channel1 · **Branch:** `cc/zach-opus-channel1`
· **Base:** `345ea76df77f211a90470935f92586bc35363c3c`

**CEO, 2026-09-13 (`ceo-decisions.md` §38):** *"what is anything other than the `main` doing
on GitHub? how many more times will this shit be repeated?"*

---

## 1. The ruleset had no hole. It was told to stand aside.

The brief for this work asked me to find the hole that let the branch through — an
API-created ref, an owner-token bypass, a condition excluding `refs/heads/nightly-*`.
**There is no hole.** Every command below was run against `WebDevBooster/richos` on
2026-09-17.

The ruleset list, which is what the brief quoted, does not print conditions:

```
$ gh api repos/WebDevBooster/richos/rulesets
[{"id":23194738,"name":"main-only","target":"branch","source_type":"Repository",
  "source":"WebDevBooster/richos","enforcement":"active",…,
  "created_at":"2026-09-13T18:42:15.592+01:00",
  "updated_at":"2026-09-16T22:57:22.040+01:00",…}]
```

`updated_at` is **three days after** it was created. The detail endpoint says what changed:

```
$ gh api repos/WebDevBooster/richos/rulesets/23194738
{…"conditions":{"ref_name":{"exclude":["refs/heads/main","refs/heads/nightly-channel"],
 "include":["~ALL"]}},"rules":[{"type":"creation"},{"type":"update"}],
 "bypass_actors":[],"current_user_can_bypass":"never",…}
```

**`refs/heads/nightly-channel` was in the exclusion list.** The version history names when
and by whom:

```
$ gh api repos/WebDevBooster/richos/rulesets/23194738/history
[{"version_id":49950050,"updated_at":"2026-09-16T22:57:22.157+01:00","actor":{"id":29904195,"type":"User"}},
 {"version_id":49562454,"updated_at":"2026-09-13T18:42:15.712+01:00","actor":{"id":29904195,"type":"User"}}]

$ gh api repos/WebDevBooster/richos/rulesets/23194738/history/49562454   # 09-13, original
 …"exclude":["refs/heads/main"]…

$ gh api repos/WebDevBooster/richos/rulesets/23194738/history/49950050   # 09-16, current
 …"exclude":["refs/heads/main","refs/heads/nightly-channel"]…

$ gh api user/29904195 --jq '{login,type,name}'
{"login":"WebDevBooster","name":"Alex Booster","type":"User"}
```

The API's own answer to "which rules apply to this branch" was, before the fix:

```
$ gh api repos/WebDevBooster/richos/rules/branches/nightly-channel
[]
```

**None. That is the whole explanation.** The rule was active, enforced and correct; the
branch was exempted from it by name, five hours before the first nightly created it at
02:53Z on 2026-09-17.

**The account id is the TOKEN's owner, and cannot on its own say who acted.** It was
settled from outside the API: a Codex run at 2026-09-16T21:57:21Z
(`~/.codex/sessions/2026/09/16/rollout-2026-09-16T08-36-58-01a0a925-c097-72d0-bafc-8495bf7ee38d.jsonl`)
read the ruleset through `gh`, wrote the backup `~/.richos-nightly/main-only-before-nightly.json`
and PUT the widened list back. Raised as `esc-20260917T145741Z-843c8c21`.

**Two other things asked for it, and both are fixed in this branch.**
`richos/app/NIGHTLY.md` instructed the operator to create the exception, and
`nightly-local.py` REFUSED to run without one (*"configure its narrow exception first"*).
A publisher that will not start unless the branch rule has a hole in it will get the hole.

## 2. Live probe — the rule works, and worked all along

Before the fix. A throwaway branch, pushed from this Mac with the operator's own
credentials:

```
$ git push origin HEAD:refs/heads/zz-ruleset-probe-20260917a
remote: error: GH013: Repository rule violations found for refs/heads/zz-ruleset-probe-20260917a.
remote: - Cannot create ref due to creations being restricted.
 ! [remote rejected]   HEAD -> zz-ruleset-probe-20260917a (push declined due to repository rule violations)
```

Refused, so nothing was created and nothing needed deleting. **The probe cannot be made to
go red BY the fix, because it was already red** — the ruleset was never broken for branches
in general, only for the one branch named in its exclusion list. The red/green flip that
does exist is on that exact ref, in section 3.

## 3. The fix, restored from the backup rather than hand-typed

The PUT body is derived from `~/.richos-nightly/main-only-before-nightly.json` — the file
the Codex run saved before widening it — by taking exactly the six writable fields:

```
$ jq '{name, target, enforcement, bypass_actors, conditions, rules}' \
     ~/.richos-nightly/main-only-before-nightly.json > restore-body.json
$ gh api --method PUT repos/WebDevBooster/richos/rulesets/23194738 --input restore-body.json
{"id":23194738,"name":"main-only","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"exclude":["refs/heads/main"],"include":["~ALL"]}},
 "rules":[{"type":"creation"},{"type":"update"}],"bypass_actors":[],
 "current_user_can_bypass":"never","updated_at":"2026-09-17T15:58:08.199+01:00",…}
```

Diffed field-by-field against the backup: **identical**.

Read back afterwards — this is the red/green flip on the exact ref:

```
$ gh api repos/WebDevBooster/richos/rules/branches/nightly-channel
[{"type":"creation","ruleset_id":23194738},{"type":"update","ruleset_id":23194738}]   # was []

$ gh api repos/WebDevBooster/richos/rules/branches/main
[]                                                                                    # unchanged

$ git push origin HEAD:refs/heads/zz-ruleset-probe-20260917b
remote: - Cannot create ref due to creations being restricted.
 ! [remote rejected]   HEAD -> zz-ruleset-probe-20260917b
```

**A live update-probe against `refs/heads/nightly-channel` itself was NOT run, deliberately.**
The only unambiguous one would be a fast-forward commit onto the live channel, which would
move the manifest the CEO's two installed nightlies are fetching right now. The evaluation
endpoint above is the same source `nightly-local.py` itself consulted, and it answers the
question without touching what users read.

**And the rule is no longer defended by attention.** `nightly.py verify_repository_rules`
reads it back before every publish and refuses on any of the five ways to neuter it —
inactive, a bypass actor, a narrowed `include`, a widened `exclude`, a missing
`creation`/`update` rule. `nightly.test.py RepositoryRuleTests` widens the list exactly as
2026-09-16 did and requires red.

## 4. The channel, moved

| | before | after |
|---|---|---|
| channel ref | `refs/heads/nightly-channel` | `refs/tags/nightly` (a release tag) |
| endpoint | `raw.githubusercontent.com/WebDevBooster/richos/nightly-channel/latest.json` | `github.com/WebDevBooster/richos/releases/download/nightly/latest.json` |
| compare-and-swap | `--force-with-lease` on the branch | `--force-with-lease` on the tag — **unchanged in kind** |

Both empirical questions were settled before the design was written, not assumed:

- **A prerelease's asset URL serves.** `curl -o /dev/null -w '%{http_code}' -L
  'https://github.com/WebDevBooster/richos/releases/download/v1.2.0-nightly.20260917.2/latest.json'`
  → **200**, body is that nightly's manifest.
- **Compare-and-swap is identical on a tag ref.** Against a local bare remote: an empty
  lease created it; a correct lease moved it; a stale lease was **rejected — "stale info"**
  and the ref did not move.

### The kill switch (spec points 28–32) still works, and here is how

The spec's withdrawal is *"a bad nightly is withdrawn by moving the CHANNEL, not by
touching the artifact"*, under *"the same compare-and-swap lease (`nightly.py:213-215`)"*.
**Both survive verbatim**, because the lease survived verbatim — it is the same
`--force-with-lease`, on a tag instead of a branch. A `withdraw` command (still unbuilt;
point 29 says so) writes the previous good manifest into a channel commit, CAS-moves
`refs/tags/nightly` to it, and then replaces the `nightly` release's `latest.json` asset.
The immutable `v*-nightly.*` releases are untouched, so withdrawal still stops new
installs and uninstalls nothing.

- **Point 28's "it cannot brick the channel"** derivation is undisturbed: `plan()` and
  `promote()` read `build-info.json` out of the channel commit, which still exists.
- **Point 31's mechanism is unaffected.** The withdrawal note is carried *inside*
  `latest.json`, so it does not care where `latest.json` is served from.
- **Point 30's provenance bound is unchanged in kind.** The note was unsigned over plain
  HTTPS from `raw.githubusercontent.com`; it is now unsigned over plain HTTPS from
  `github.com/…/releases/download/…`. Minisign still covers the archive bytes and not the
  note, and the client-side constraint on legal targets is what bounds it, exactly as
  written.
- **One thing genuinely changes, and it is new:** a withdrawal is now two acts (move the
  tag, replace the asset) where it used to be one. `withdraw` must therefore use the same
  lease-first order as `promote`, so that a failure in between leaves users on the bad
  build with a red command rather than on a build no lease was taken for. Whoever builds
  point 29 should take `promote`'s repair arm with it.

## 5. For Rich — deleting the branch

**Not yet.** Run this only after this branch is on `main` AND a nightly has been published
against the new endpoint. The branch is what the two already-published nightlies fetch;
deleting it early takes the channel away from them before anything replaces it.

```sh
git push origin --delete nightly-channel
```

**Unverified, and it is an inference rather than a probe:** the ruleset's `rules` array
is `[{"type":"creation"},{"type":"update"}]` with no `deletion` entry, from which I expect
the delete to be allowed. I could not test it — testing deletion needs a throwaway branch,
and creating one is precisely what the ruleset now refuses, so there is no safe subject.
If the push is refused with `GH013`, the ruleset gained a `deletion` rule since this was
written; read it back with `gh api repos/WebDevBooster/richos/rulesets/23194738` rather
than working around it. Confirm afterwards:

```sh
gh api repos/WebDevBooster/richos/branches --jq '.[].name'    # expect: main
```

**Tell him this, because nothing in the product will:** the two nightlies already on his
Mac (`v1.2.0-nightly.20260917.1` and `.2`) have the old `raw.githubusercontent.com`
endpoint **compiled into the binary**. They will not see the next nightly through the
updater, and no update can fix that, because the fix would have to arrive through the
endpoint they can no longer use. They must be replaced by hand, once. Every nightly
published from this change onward updates normally.

A third tag, `v1.2.0-nightly.20260917.3`, is reserved on the remote with **no release
behind it** — a build that never finished. It is inert and this work does not touch it.
