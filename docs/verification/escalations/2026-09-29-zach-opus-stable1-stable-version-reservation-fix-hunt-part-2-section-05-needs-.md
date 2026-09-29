# Escalation: Stable version reservation fix (hunt part 2, section 05) needs a one-line change in make-release.sh, outside the brief's nightly.py-only scope

- id: `esc-20260929T223359Z-e6844413`
- raised: 2026-09-29T22:33:59Z
- from: zach-opus-stable1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-stable1` (branch `cc/zach-opus-stable1`)
- head: `b45c9cf3b2a580ccb5e841bb88c06800c35e2924`
- state: **proceeding**
- for: lead

## The question

Is it acceptable that a stable build pins its engine to the digest-named asset on the nightly channel release (the same place every nightly candidate already pins it, never overwritten or deleted), which needs make-release.sh to accept --candidate-engine for a stable engine build? Without that, the v<version> tag cannot move to the publish step at all.

## What was already tried

Read the stable path end to end at b45c9cf3. The brief says the bug is prepare() pushing v<version> early (nightly.py:614-616). That is only half of it: build() (nightly.py:905-915) then runs gh release create v<version> --verify-tag and uploads the engine tarball to that release BEFORE the app compiles, because make-release.sh compiles the engine URL releases/download/v<version>/richos-engine-*.tar.gz into the binary and verify-engine must read those bytes back off the wire first (make-release.sh:14-21, 158-159, 333-365). So as long as stable keeps a per-version engine URL, a public v<version> tag and a public prerelease must exist before compile, and the brief's done-means (reservation invisible, tag created only at publish) is impossible inside nightly.py alone. make-release.sh:185-188 refuses --candidate-engine for anything but a nightly.

## Proceeding meanwhile

Implementing it: stable reserves refs/candidates/stable/v<version> with a compare-and-swap lease recorded in the plan, takes the digest-named channel engine like nightly candidates, and creates v<version> only in finish via ensure_version_tag. The make-release.sh guard relaxation is its own commit so it can be judged separately. Note also: a stable run executes the SOURCE commit's own nightly.py, so the fix applies only to stable releases of commits that contain it; promoting a nightly built before this lands still uses the old behavior.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T223359Z-e6844413`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T223359Z-e6844413 --disposition "<what you decided or did>"
