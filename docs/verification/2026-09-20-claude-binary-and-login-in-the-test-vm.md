# The claude binary and the claude login in the test VM — measured, 2026-09-20

**Two VM boots on `cc/zach-opus-vmclaude1`, both cleaned up, nothing on the host's screen.**

The CEO asked two questions this morning: *"What happens with the Claude binary in the VM?
Will it always stay on the same version regardless of any updates?"* and *"What happens when
the Claude login expires in the VM?"* Both had the same answer before today — *whatever was
copied in once, and nothing ever looks at it again* — and this is the measurement of the new
one.

## What was verified

| | Claim | Result |
|---|---|---|
| 1 | `run.sh` prints the host's and the guest's `claude` version at every run, and they are equal | **`claude: host 2.1.277 guest 2.1.277`** |
| 2 | A guest binary that is not the host's is detected by sha256, not by version | **`check: copy (host sha 73d6a2a55c46, guest sha 93b5c072956a)`** — the altered copy still *reported* 2.1.277 |
| 3 | `--check` reports and copies nothing | exit 1, no copy attempted |
| 4 | A copy that cannot land is a REFUSAL, not a degraded run | **`REFUSED: the copy of the claude binary into zach-claude1 failed (scp)`**, exit 3 |
| 5 | A real sync restores it | copied in **1 s**, `claude: host 2.1.277 guest 2.1.277`, exit 0 |
| 6 | The guest's own answer matches | `2.1.277 (Claude Code)` from inside the guest |
| 7 | The auto-updater pin is present in the guest | `grep -c DISABLE_AUTOUPDATER ~/.zshenv` → **1** |
| 8 | The login is copied from this Mac at every run | **`login stored: credential file yes (524 bytes, matching this Mac's), keychain item yes`** |
| 9 | The login actually works — a model turn in the guest | **`READY`**, exit 0 |
| 10 | `--engine` lands an engine the app will accept | `scripts/hooks: present`, `VERSION: 1.2.0`, **`no nested engine/engine`** |
| 11 | §54 | both guests quit, `pgrep` verified empty, clones deleted, no `tart list` row |

## Boot 1 — `zach-claude1`, the binary and the refusal

```
[testvm] 07:05:16Z host claude: 2.1.277  (/Users/alex/.local/share/claude/versions/2.1.277)
claude: host 2.1.277 guest 2.1.277
[testvm] 07:05:57Z login stored: credential file yes (524 bytes, matching this Mac's), keychain item yes
claude login: guest logged in
vm=zach-claude1 ip=192.168.64.28 pid=856 ssh=admin@192.168.64.28 windows=1 elapsed=68s
tailnet=not-joined
claude: host 2.1.277 guest 2.1.277
claude login: guest logged in
run.sh rc=0
```

Then the guest's copy was altered deliberately (one byte appended, `93b5c072956a`):

```
--- 4a. --check must now report a mismatch and copy nothing ---
claude: host 2.1.277 guest 2.1.277
[testvm] 07:06:16Z check: copy (host sha 73d6a2a55c46, guest sha 93b5c072956a)
check rc=1
--- 4b. with a copy that cannot land, the run REFUSES ---
[testvm] 07:06:19Z the guest's claude is not the host's (2.1.277 vs 2.1.277) — copying the host's in
[testvm] 07:06:20Z REFUSED: the copy of the claude binary into zach-claude1 failed (scp).
sync-with-failing-copy rc=3
```

**The line worth keeping is `2.1.277 vs 2.1.277`.** The altered binary answered `--version`
with the same string as the host's; only the sha256 saw the difference. A version-string
comparison would have called that guest in sync and been wrong.

Restored, and re-measured rather than assumed:

```
[testvm] 07:06:24Z copied in 1s
claude: host 2.1.277 guest 2.1.277      check rc=0
```

## Boot 2 — `zach-claude2`, the engine payload and a model turn

```
[testvm] 07:08:32Z engine payload verified in the guest (scripts/hooks + VERSION present)
vm=zach-claude2 ip=192.168.64.29 pid=923 ssh=admin@192.168.64.29 windows=1 elapsed=94s

$ ls $PAYLOAD/engine | head    →  agents  ass-kicker  assets  ceo-briefings  ceo-inbox  CHANGELOG.md
scripts/hooks: present
VERSION: 1.2.0
no nested engine/engine

$ wc -c < <fixture home>/.claude/.credentials.json   →  524
$ wc -c < ~/.claude/.credentials.json                →  524

$ claude -p 'Reply with the single word READY and nothing else.'   →  READY   (rc=0)
```

**Row 9 is the one that settles the question Ray could not.** His `.7` and `.8` walks both
lost the Mac → phone half because a desk message in the guest was refused before it became a
message. A model turn in the guest now answers, from a login this Mac handed over at the
start of the run.

## What is still open

**Whether a token refresh inside the guest rotates the credential and logs the host out** is
**unverified**. Nothing observed it in either boot, and neither boot lasted long enough to
force a refresh. It is the first thing to check the next time a walk in the guest outlives an
access token. Everything else here is measured.

## How it was run, and what was not touched

Two boots from the branch's own scripts, `--no-tailnet` (neither proof is about the phone), a
minimal fixture home, `RichOS-macos-aarch64.zip` from
`~/.richos-nightly/releases/v1.2.0-nightly.20260920.1`. Nothing was rendered or launched on
the host; no `pmset`, no keystroke, no lock, no sleep. The host's own login keychain was read
exactly twice — once per boot, attributes first and then the value straight into a pipe — and
never written, never logged, never printed. The value is in no file on this Mac and in no
command line anywhere.

Both guests were quit by pid and deleted before this file was written; `tart list` has no row
for either.

## The wait

The first boot was queued behind `ray-opus-vm9`'s guest for **1530 s** (25.5 minutes) of
polling, on Rich's instruction not to run a second guest beside Ray's latency measurement.
Raised as `esc-20260920T062837Z-726542d6` while waiting; the answer was *no second guest*, and
it was the right one — a second VM at 188% CPU would have made his numbers a measurement of
mine.
