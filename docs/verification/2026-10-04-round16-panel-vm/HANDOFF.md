# Round-16 quota panel: the real app beside round 16, seven states, dark and light

Branch `cc/echo-opus-notice2`, workspace `/Users/alex/ab/richos-wt/echo-opus-notice2`
(echo-opus-notice2, 2026-10-05; continues echo-opus-panel16e, echo-opus-panel16d,
echo-opus-panel16c and echo-opus-panel16b).
Design: richos-hq `design/mockups/rounds/round-16/` (frozen, read only). Each `N-<state>-dark.png` /
`-light.png` here is the real app in the test VM; each `N-<state>-round16-*.png` beside it is
round 16's render of that state.

**Where the shots come from.** Shots 1, 2, 3 and 5: walk 3 (`walk-5c66807272b3`, 2026-10-05
02:30-02:53Z, `execution: completed`, `scenario_exit: 0`, `cleanup_complete: true`), the
debug app built at `665d0765a` with the walk fixture of `61e8305e2`. Shots 6 and 7: walk 4
(`walk-e583bad4276f`, 2026-10-05 03:17:41-03:43:41Z, `execution: completed`,
`scenario_exit: 0`, `cleanup_complete: true`), the debug app built at `9cbdac8ea` (the
working-row fix, on top of main's `f2d3ab1c4` merged at `cb07e092e`). Shot 4: walk 5
(`walk-e7974c7e22a6`, 2026-10-05 04:13:25-04:37:43Z, `execution: completed`,
`scenario_exit: 0`, `cleanup_complete: true`), the debug app built at `76ea3f500` (the
notice fix `32852260c` on top of walk 4's build). Walk 5 also shot states 6 and 7; they show
the same content as walk 4's, so walk 4's stay.

**How walk 4's app was built and walked** (walk 3's recipe, taken from echo-opus-panel16d's
own commands; run from `richos/app`):

```
cd src-tauri && mkdir -p ../ui-dist
../scripts/testvm/reserve.py --wait 1800 -- cargo tauri build --debug --bundles app
ditto -c -k --keepParent <cargo target>/debug/bundle/macos/RichOS.app <scratch>/RichOS.app.zip
cd ../scripts/testvm && ./reserve.py --wait 1800 -- ./run-walk.py --wait 1800 \
  --bundle <scratch>/RichOS.app.zip --home <scratch>/home \
  --engine ~/.richos-nightly/releases/v1.2.0-nightly.20261003.35/richos-engine-1.2.0.tar.gz \
  --report <scratch>/report.json -- <workspace>/richos/app/scripts/testvm/round16-panel-walk.sh <scratch>/out
```

`cargo tauri build` exits 1 after the `.app` is bundled: "A public key has been found, but no
private key. Make sure to set `TAURI_SIGNING_PRIVATE_KEY`", the updater archive's signature,
which a debug walk build does not need. The `.app` is checked on its own: `build.rs` staged
`ui/` into `ui-dist/` in the build's minute, and `cmp` finds `ui-dist/style.css` and
`ui-dist/main.js` identical to `9cbdac8ea`'s.

**Main's `f2d3ab1c4` is in walks 4 and 5** ("Switched to" is said only once a turn runs on the
new account). In walk 4 the line was drawn only after that turn ended; `32852260c` draws it
during the turn (see "Shot 4, closed" below), so in walk 5's shot 4 it sits below the running
turn and above "• 3 agents working on Work", as round 16 draws it.

## The seven states

| Shot | Round 16 state | Verdict |
|------|----------------|---------|
| 1 one account | `low` | **Matches.** + Add account beside Refresh (the circular arrow), "Checked … · checks every 5 min", round 16's times, the ruler key with its bold sentence. |
| 2 two accounts | `two` | **Matches.** Home in use 41% / 28%, Work next at **10% / 20%**, the one sentence with Pause, no scrollbar. Home has no Remove (item 1, kept). |
| 3 switched sheet | `switched` | **Matches.** Work **in use**, Home past its line at 95% with **no tag** and "week resets Fri", "switch to the next account — none has room now", the card "In use: Work, since …". |
| 4 switched line | `switched-line` | **Matches.** Rich's line "Switched to Work — Home reached 95% of its five-hour window. Nothing stopped." is on screen while the turn on Work runs ("Working for 27s" dark, "51s" light), then "**• 3 agents working on Work**" below it with round 16's gold dot, in the message column (walk 5, `32852260c`). The user's message and the running turn sit above the line because the row exists only during a turn (below). |
| 5 fast sheet | `fast-switch` | **Matches, with one declared difference.** The card says round 16's sentence: "3 agents reading at once took Work's five-hour window from 19% to 28% in 1 minute. The lines moved to 91% and 97% …". The moved lines carry their ghosts ("switch at 91% · was 93%", "switches at 97% · was 99%"), and + Add account and Refresh keep their row. Declared: "every minute" where round 16 says "every 2 min" (the app's measured interval, quota.rs `note_speed`). The sheet scrolls about 24 px because the VM's window is 1400 × 864 pt (the app's log: "derived 1400x864"), while round 16 draws at 1440 × 900. |
| 6 fast alert | `fast-alert` | **Matches.** Rich's alert "Usage is climbing fast: **3 agents reading at once** took Work's five-hour window from 10% to 13% in 2 minutes …", then a turn with the chip and "• 3 agents working on Work" in the message column. Above it, the switch line from state 4. |
| 7 back to normal | `normal-again` | **Matches.** Rich's line "Usage is back to normal. I'm checking every 5 minutes again, and the lines are back at 93% and 99%.", then a turn with the chip and "• 3 agents working on Work" in the message column. |

**The working row, fixed (`9cbdac8ea`).** `#quota-work-status` had none of the message
column's rules and spanned the composer zone from the pane's edge, with no dot. It now takes
`#messages`' column (reading width, centered, 28 px sides, stepping to 24 px under 1180 px,
20 px under 820 px and 18 px in `bp-narrow`) and round 16's `.working-row`: flex, 10 px gap,
an 8 px gold dot, `--trim-text`. Contrast on `--ground`, computed: text 5.91:1 dark,
5.90:1 light. **Declared difference:** round 16 breathes the dot's opacity down to .35,
which is 1.95:1 dark and 1.43:1 light, under the 3:1 a non-text indicator owes. The app keeps
it at full opacity (7.68:1 dark, 3.15:1 light) and breathes its size, as `.tl-pulse` already
does. Only the working row has the dot (`data-state`, `main.js`); a paused row has none
(round 16's hold ring belongs to a holding state, not one of these seven).

**Shot 4, closed: a line Rich raises during a turn is drawn at once (`32852260c`).** Main's
`f2d3ab1c4` moved the switch notice to `spine.rs` `prepare_request`: `ran_on(account)` then
`raise_quota_notices`, once the turn's lease is in the chair. `raise_proactive` then held the
window's event for any line raised mid-turn until the turn's boundary, so in walk 4 the line
was absent from shot 4 and appeared after the turn, at the top of shot 6. It now sends
`rich://proactive-message` and the §13 events at once; the line is already durable and in the
published read view, so the window's reload draws it beside the running turn. The fast-usage
alert and the other quota notes share this path. `f2d3ab1c4`'s rule is kept: the notice is
still raised only once a turn runs on the new account. The thread summary sent with it says
"working" while a turn of that thread runs. `405434563`: such a line no longer makes the
screen reader say "Rich finished." beside a running turn; its own text is announced. No new
color: the line is the existing "reached out" treatment, already in shots 6 and 7.

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
| 6 | "N agents working on Work" row | **Done, seen**: "• 3 agents working on Work" in the message column with round 16's dot, in shots 4, 6 and 7, dark and light (`9cbdac8ea`). |
| 7 | Two-account sheet scrolls in 1400 × 835 | **Done**: no scrollbar in shots 2 and 3; `tests/quota.js` measures it. The fast sheet (shot 5) scrolls about 24 px at 1400 × 864 (above). |
| 8 | "Signed in. Reading its allowance…" stays | **Done**: no stale line in shot 2. |
| 9 | Refresh has no icon | **Done**: the circular arrow. Shots 1, 2, 3 and 5. |
| 10 | Ruler key text | **Done**, round 16's words with the bold second sentence. Shots 1, 2, 3 and 5. |
| 11 | Five-hour bar past the "now" tick | **Done**: the bar runs past the tick in shots 1 and 2 (round 16's clock), stamps 8 px above "now". |

## Commits on this branch (echo-opus-notice2)

- `32852260c` spine: a proactive line raised during a turn is sent to the window at once; `rotation_tests` `the_switch_notice_is_drawn_while_the_turn_on_the_new_account_runs`.
- `405434563` ui: a line Rich raised himself is not announced as "Rich finished".
- `76ea3f500` state registry: the fast card's round-16 sentence classified ("1 agent took .", "agents reading at once took ." information; "from % to % in" a fragment), which `affordances.js` refused at the panel's merge.
- This hand-off's commit: walk 5's shot 4, dark and light.

## Commits on this branch (echo-opus-panel16e)

- `9cbdac8ea` the working row sits in the message column with round 16's dot; `tests/quota.js` measures its text edge against `#messages`' and its dot.
- This hand-off's commit: walk 4's shots 4, 6 and 7, dark and light.

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
- `cargo test -p richos-core --lib -- quota claude_accounts`: 73 passed. `--test rotation_tests`: 31 passed (at `665d0765a`, the walked build).
- After merging main `065021f15`: `--lib -- switch work_host quota claude_accounts`: 155 passed; `--test rotation_tests`: 32 passed. Three switch tests needed the automatic switch on, and two of them round 16's words. One of the three, main's earlier `a_long_background_run_…`, had failed on this branch unseen since an earlier merge, because the old proof filter never selected `work_host`.
- `scripts/testvm/test/fake-claude-fill-first.test.py`: 9 ok.
- Walks: walk 1 (echo-opus-panel16c's, `walk-c9dcf2ba1a38`), walk 2 (`walk-2b34a9ca8b95`), walk 3 (`walk-5c66807272b3`), walk 4 (echo-opus-panel16e's, `walk-e583bad4276f`) and walk 5 (echo-opus-notice2's, `walk-e7974c7e22a6`); each report says `cleanup_complete: true`.
- At `32852260c`: `the_switch_notice_is_drawn_while_the_turn_on_the_new_account_runs` is RED with `spine.rs` at `40de1962f` ("the switch line was held until his turn ended"; events TurnStarted, Chunk, TurnCompleted, ProactiveMessage) and GREEN with the fix. `reserve.py -- cargo test -p richos-core --test rotation_tests --test live_event_tests --test action_ledger_tests`: 33, 20 and 15 passed. `node ui/tests/quota.js`: 26 PASS, 0 FAIL.
- At `76ea3f500`: `node affordances.js` exit 0.
- Walk 5's app: `cargo tauri build --debug --bundles app` at `76ea3f500` (exit 1 at the updater signature only, as above); `cmp` finds `ui-dist/main.js` and `ui-dist/style.css` identical to the branch's.
- At `9cbdac8ea`: `node ui/tests/quota.js`: 26 PASS, 0 FAIL. Its first run failed only the new check, which caught the row's text 4 px right of the message text at the test's 820-1179 px viewport (28 px sides against `#messages`' 24 px there). Fixed, then the one re-run.
