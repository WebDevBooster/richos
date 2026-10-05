# Round-16 quota panel: hand-off from echo-opus-panel16b (stopped by the CEO, 2026-10-05 ~00:12Z)

Branch `cc/echo-opus-panel16b`, workspace `/Users/alex/ab/richos-wt/echo-opus-panel16b`.
Design: richos-hq `design/mockups/rounds/round-16/` (frozen, read only).

**Main is already merged into this branch**: main at `191d73326` overlaps `quota.rs`,
`claude_accounts.rs`, `spine.rs`, `rotation_tests.rs` and the README count; it was merged in
`e9fd447d1` and the one semantic conflict fixed in `4b3742e2d` (main's new switch-waits rotation
test now turns the automatic switch on, which `e1ac24d27` requires; README total 1777). If main
has moved again, the next Echo merges main first, then reruns
`cargo test -p richos-core --lib -- quota claude_accounts` and `--test rotation_tests`.

## The 11 items

| # | Item | State | Commit |
|---|------|-------|--------|
| 1 | Remove on Account 1 | **Kept, with reason**: Account 1 is the user's own Claude Code sign-in (the folder Claude Code in the terminal uses too), so forgetting it would sign Claude Code out on this Mac, the opposite of the design's "nothing on the account itself changes" (`claude_accounts.rs` `remove` refuses it). | 8b5de929f (reason recorded) |
| 2 | Open Claude Usage in the reset section | **Done**: no reset section and no button in any state round 16 draws. **Kept** only inside the weekly-reset section when there is a reset offer, an approval or an attempt (none drawn by round 16); reason: an uncertain reset blocks automatic retry and tells the user to check Claude's Usage page, and this is its one way there. | 8b5de929f |
| 3 | Time and duration formats | **Done**: "Resets in **3 h 22 min** · at Mon 2:57 AM", "resets in **4 d 2 h**", "began **9:57 PM**", "Checked 2 min ago", "Last reading 47 min ago — stale". Seen on the real app in run 1, shots 1 and 2. | 8b5de929f |
| 4 | Fast alert has no agent count | **Done in code, not yet seen in the VM**: "15 agents reading at once took Home's five-hour window from 40% to 71% in 12 minutes…" from the shell's count (`set_agents_working`) and the measured rise; unit-tested. | 092f11469, 5f54e1c84 |
| 5 | Every-account-used-up line says time left | **Done in code**: "…until 2:17 AM, when Home's window resets — the soonest." at the webview's offset (`set_utc_offset` from `launch_state`); unit-tested. Not reached in the VM walk (no walk step exhausts both accounts). | 092f11469, 5f54e1c84 |
| 6 | "N agents working on Work" row | **Done in code, mock-tested** ("1 agent working on Home"); not yet seen in the VM. Shows while the conversation's chip counts agents working (that count exists only during the thread's active turn, as the chip itself does). | 5f54e1c84, 8b5de929f |
| 7 | Two-account sheet scrolls in 1400 × 835 | **Done**: no scrollbar on the real app (run 1 shot 2) and measured in `tests/quota.js` at 1400 × 835. | 8b5de929f |
| 8 | "Signed in. Reading its allowance…" stays | **Done**: Add/Sign in/Remove lines pass after 3.6 s (round 16's toast time); the reading line ends when the reading arrives. Run 1 shot 2 shows no line. | 8b5de929f |
| 9 | Refresh has no icon | **Done** (circular arrow; turns while asking). Run 1 shots 1 and 2. | 8b5de929f |
| 10 | Ruler key text | **Done**, round 16's words with the bold second sentence. Run 1 shots 1 and 2. | 8b5de929f |
| 11 | Five-hour bar past the "now" tick | **Done**: the drawing already matched; the walk's fixture put the tick at 42% with the bar at 41%. The walk now uses round 16's clock (3 h 22 min left → tick at 32.7%, bar 8.3 points past it), visible in run 1 shots 1 and 2. Stamps now sit 8 px above "now" as round 16 draws them. | d2ae951e9, 8b5de929f |

Other commits: a0df244c2 (affordances.js prints stale registry rows beside unclassified ones).

Proof run once each under `scripts/testvm/reserve.py --`: `node ui/tests/quota.js` 26 PASS 0 FAIL;
`node ui/tests/contrast.js` 76 PASS 0 FAIL; `node ui/tests/affordances.js` 121 PASS 0 FAIL;
core `quota claude_accounts` 73 passed, `rotation_tests` 31 passed (after the merge).

## Screenshots

Committed here from run 1 (build before the merge, 2026-10-04 23:37-00:03Z), named `panel16b-run1-*`:
`1-one-account` and `2-two-accounts`, dark and light. They show items 3, 7, 8, 9, 10, 11.
In run 1's shot 2 the Work lane reads Home's figures (41% / 28%): that is main's hunt finding 48
(an added account's reader swapped for Account 1's during a read), fixed on main in `3ac58b9a7`
and now merged; because of it Work had no room, no switch happened, and states 3 to 7 of run 1
are not valid evidence (not committed).

**Missing**: states 3 to 7 (switched sheet, switched line with the working row, fast sheet, fast
alert with the agent count, back to normal), dark and light, from a build that includes the merge.
Run 2 (built at `4b3742e2d`) was stopped at state 1 by the CEO's restart and cleaned up
(`stop.sh walk-4cf4d2523ca0`: app quit, VM stopped, clone deleted).

## Exact next step

1. Merge main if it moved; rebuild: `cd richos/app/src-tauri && mkdir -p ../ui-dist && ../scripts/testvm/reserve.py --wait 1800 -- cargo tauri build --debug --bundles app` (exit 1 at the updater signing step is expected; the `.app` is complete), then `ditto -c -k --keepParent RichOS.app <scratch>/RichOS.app.zip`.
2. One walk: `cd richos/app/scripts/testvm && ./reserve.py --wait 1800 -- ./run-walk.py --wait 1800 --bundle <zip> --home <empty dir> --engine ~/.richos-nightly/releases/v1.2.0-nightly.20261003.35/richos-engine-1.2.0.tar.gz --report <json> -- $PWD/round16-panel-walk.sh <out-dir>` (about 26 minutes).
3. Check shot 2's Work lane reads 10% / 20%, shot 3 shows Work in use, shot 4 the working row "3 agents working on Work", shot 6 the alert with "3 agents reading at once"; commit shots 1-7 beside the existing round-16 renders in this folder, replacing the `panel16b-run1-*` files.
