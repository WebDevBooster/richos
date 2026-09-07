# First installed legacy fixture: historical preboot evidence

**Superseded:** its first real reboot exposed numeric device-ID persistence and
resume was refused before cleanup. Preserve this original fixture; do not use
the command below as the next test. See [the failure record](workspace-reboot-findings-2026-09-07.md).

The isolated installed driver at source `e24368f` prepared and gated one tiny
generated repository and linked worktree on 2026-09-07. No real repository was
gated, no launchd job was loaded and public managed creation remains disabled.

Actual root-to-owner checks passed:

- New opens, chmod through the old file descriptor and creation through the old
  directory descriptor were refused after the gate changed ownership.
- The previously opened writable descriptor still appended its final test bytes.
  Those bytes were verified directly in the held file.
- The gate refused a frozen view and the armed job stayed waiting during the same
  kernel boot. It produced no archive or retirement side effects.

The generated fixture is now `waiting-for-reboot`. Its tiny held data and test
helper are intentional test evidence. The helper holds only the disposable test
file. Do not kill an old numeric PID after reboot; a different kernel boot UUID,
not process absence, establishes the write cutoff.

## Exact continuation

After the user has saved their work and restarted the Mac, invoke the following
fixed installed command as administrator. A Claude session restart is not enough.
The driver verifies the exact protected release, fixture identities, approved
plan and a genuinely different kernel boot before starting the disposable broker.

```sh
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B '/Library/Application Support/RichOS/workspace-broker/releases/62d59b86da85476123cfb5afc726795b871c26ecbeebd6e8376ea0155efa3880/legacy-workspace-acceptance.py' resume --acceptance-id legacy-acceptance-a821a7a3498c40258dcc22e1a36c72b4 --approved-plan-sha256 df236cd25b5534be581d156b1a1b111c8ddb870ad198f5602780ce7b22210eda
```

The driver will run the existing armed job through the installed broker using
only the fixture policy. It must verify preserved archive/index/xattr bytes,
worktree and branch retirement, canonical restoration, immediate Git-GC recovery
and idempotent completion before reporting success. It retains the tiny fixture
and recovery evidence; it does not delete real work or activate production.

If this fails, inspect the protected receipt and broker log under the exact
private fixture path below. Preserve partial evidence and use the installed
matching release. Do not invent a new gate, weaken the boot check or overwrite
source paths to make the test pass.

- Acceptance ID: `legacy-acceptance-a821a7a3498c40258dcc22e1a36c72b4`
- Gate ID: `75226780-e048-4827-a74c-fbd3f7123a65`
- Before-reboot kernel UUID: `d8ff1b41-fe97-4df4-aac2-3f40f0b105ce`
- Private receipt: `/private/var/db/richos-workspaces/legacy-acceptance-a821a7a3498c40258dcc22e1a36c72b4/receipt.json`
- Branch: `codex/automatic-worktree-retirement`

The [prepared scope](legacy-workspace-installed-preparation-2026-09-07.json) and
[pre-reboot receipt](legacy-workspace-installed-preboot-2026-09-07.json) record the
fixed identities and checks. Actual post-reboot acceptance is still outstanding.
