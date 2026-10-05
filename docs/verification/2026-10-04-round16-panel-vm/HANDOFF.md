# Round-16 quota panel: the real app beside round 16, seven states, dark and light

Branch `cc/echo-opus-panel16d`, workspace `/Users/alex/ab/richos-wt/echo-opus-panel16d`
(echo-opus-panel16d, 2026-10-05; continues echo-opus-panel16b and echo-opus-panel16c).
Design: richos-hq `design/mockups/rounds/round-16/` (frozen, read only). Each `N-<state>-dark.png` /
`-light.png` here is the real app in the test VM; each `N-<state>-round16-*.png` beside it is
round 16's render of that state.

**Where the shots come from.** Walk 3 (`walk-5c66807272b3`, 2026-10-05 02:30-02:53Z,
`execution: completed`, `scenario_exit: 0`, `cleanup_complete: true`), the debug app built at
`665d0765a` (every app commit on this branch up to then) with the walk fixture of `61e8305e2`.
No app code changed between that build and this commit's parent.

**Not in these shots: main's `f2d3ab1c4`** ("Switched to" is said only once a turn runs on
the new account), merged after the walk. With it, shot 4's switch line appears when the
user's turn starts on Work, not before the user's message.

## The seven states

| Shot | Round 16 state | Verdict |
|------|----------------|---------|
| 1 one account | `low` | **Matches.** + Add account beside Refresh (the circular arrow), "Checked … · checks every 5 min", round 16's times, the ruler key with its bold sentence. |
| 2 two accounts | `two` | **Matches.** Home in use 41% / 28%, Work next at **10% / 20%**, the one sentence with Pause, no scrollbar. Home has no Remove (item 1, kept). |
| 3 switched sheet | `switched` | **Matches.** Work **in use**, Home past its line at 95% with **no tag** and "week resets Fri", "switch to the next account — none has room now", the card "In use: Work, since …". |
| 4 switched line | `switched-line` | **Partly.** Rich's line "Switched to Work — Home reached 95% … Nothing stopped.", a turn on Work, the chip "··· 3 working", and the working row "**3 agents working on Work**". **Open:** the row sits at the conversation pane's left edge with no dot; round 16 draws "• 3 agents working on Work" in the message column under Rich's line. |
| 5 fast sheet | `fast-switch` | **Matches, with one declared difference.** The card says round 16's sentence: "3 agents reading at once took Work's five-hour window from 19% to 28% in 1 minute. The lines moved to 91% and 97% …". The moved lines carry their ghosts ("switch at 91% · was 93%", "switches at 97% · was 99%"), and + Add account and Refresh keep their row. Declared: "every minute" where round 16 says "every 2 min" (the app's measured interval, quota.rs `note_speed`). The sheet scrolls about 24 px because the VM's window is 1400 × 864 pt (the app's log: "derived 1400x864"), while round 16 draws at 1440 × 900. |
| 6 fast alert | `fast-alert` | **Partly.** Rich's alert "Usage is climbing fast: **3 agents reading at once** took Work's five-hour window from 10% to 13% in 3 minutes …", then a turn with the chip and the working row. **Open:** the same row placement as shot 4. |
| 7 back to normal | `normal-again` | **Partly.** Rich's line "Usage is back to normal. I'm checking every 5 minutes again, and the lines are back at 93% and 99%.", then a turn with the chip and the working row. **Open:** the same row placement as shot 4. |

**The one open difference, with its cause.** `#quota-work-status` (`richos/app/ui/style.css`,
the rule `#quota-work-status { color: var(--ink-soft); font-size: 1rem; margin-bottom: 8px; }`)
has none of its sibling `#drill-chip-zone`'s column rules (`max-width: var(--reading-width);
margin: 0 auto; padding: 0 28px 6px`), so it spans the composer zone from the pane's edge. It
also draws no leading dot. Not changed here: the lead's instruction for this walk was to
report a remaining difference, not to walk again.

**Why the row comes with a user turn in shots 4, 6 and 7.** The row and the chip exist only
while a turn of this conversation runs (`main.rs` `get_worker_status` reads the conversation's
lease during its turn). Round 16 draws them after Rich's reply, with the turn over. So each
of those shots holds one turn open, which adds the user's message above the row.

**Not panel differences (left as they are).** The technical view's "Rich *reached out*"
heading on Rich's lines (round 16: "Rich · 11:34 PM"), the "Worked" and "Between turns"
blocks, and the fixture's own row "? rate_limit_event · outcome not recorded" (shot 7). These
come from the app's conversation in technical view, not from the panel.

## The 11 items

| # | Item | State, and the shot that shows it |
|---|------|-----------------------------------|
| 1 | Remove on Account 1 | **Kept, with reason**: Account 1 is the user's own Claude Code sign-in, so forgetting it would sign Claude Code out on this Mac (`claude_accounts.rs` `remove` refuses it). Shots 2, 3 and 5: Home has no Remove. |
| 2 | Open Claude Usage in the reset section | **Done**: no reset section and no button in any state round 16 draws. Kept only inside a weekly-reset offer or attempt, its one way to Claude's Usage page. Shots 1 to 3 and 5: none. |
| 3 | Time and duration formats | **Done**: "Resets in **2 h 42 min** · at 5:27 AM", "resets in **1 d 5 h**", "began **12:27 AM**", "Checked 2 min ago". Shots 1, 2, 3 and 5. |
| 4 | Fast alert has no agent count | **Done, seen**: "3 agents reading at once took Work's five-hour window from 10% to 13% in 3 minutes" (shot 6), and the same sentence on the sheet's card (shot 5, `8e6b0a169`). |
| 5 | Every-account-used-up line says time left | **Done in code**, unit-tested (`quota.rs` "Every account is used up. 3 agents are holding their place until …"). Round 16 draws no such state among these seven, and the walk does not exhaust both accounts. |
| 6 | "N agents working on Work" row | **Done, seen, one open difference**: "3 agents working on Work" in shots 4, 6 and 7, at the pane's edge with no dot (above). |
| 7 | Two-account sheet scrolls in 1400 × 835 | **Done**: no scrollbar in shots 2 and 3; `tests/quota.js` measures it. The fast sheet (shot 5) scrolls about 24 px at 1400 × 864 (above). |
| 8 | "Signed in. Reading its allowance…" stays | **Done**: no stale line in shot 2. |
| 9 | Refresh has no icon | **Done**: the circular arrow. Shots 1, 2, 3 and 5. |
| 10 | Ruler key text | **Done**, round 16's words with the bold second sentence. Shots 1, 2, 3 and 5. |
| 11 | Five-hour bar past the "now" tick | **Done**: the bar runs past the tick in shots 1 and 2 (round 16's clock), stamps 8 px above "now". |

## Commits on this branch (echo-opus-panel16d)

- `e679eea49` a lane reads "used up" only at 100%; past the line it only has no room (shot 3).
- `8e6b0a169` the fast card says round 16's sentence; `quota.rs` View publishes `rises` and `agentsWorking`.
- `807394b97` + Add account and Refresh keep their place on the reading's row (shot 5).
- `fa766bf4c` testvm fake claude: each lease keeps its own evidence journal; only the user's turn is held.
- `82e10cef7` round16-panel-walk.sh: states 4 to 7 hold a user turn, rise from Work's own figures, stop after shot 5.
- `61e8305e2` testvm fake claude: reports Claude Code's startup inventory (`system/init`) with every turn.

**Why walks 1 and 2 showed "Stopped" instead of the row.** The app refuses a company
conversation's turn until the child's `system/init` names the onboarding tools (`native.rs`
`ensure_onboarding_tools_loaded`). The fake never sent one, so no turn of the walk's
conversation could run (the guest's relaunch log: "cognition protocol: The connection did not
report whether company interview tools loaded."). That was a fixture gap, not an app defect.

## Proof

- `node ui/tests/quota.js`: 26 PASS, 0 FAIL, including the dark and light state matrices' fit and contrast checks.
- `cargo test -p richos-core --lib -- quota claude_accounts`: 73 passed. `--test rotation_tests`: 31 passed (at `665d0765a`).
- `scripts/testvm/test/fake-claude-fill-first.test.py`: 9 ok.
- Walks: walk 1 (echo-opus-panel16c's, `walk-c9dcf2ba1a38`), walk 2 (`walk-2b34a9ca8b95`) and walk 3 (`walk-5c66807272b3`); each report says `cleanup_complete: true`.
