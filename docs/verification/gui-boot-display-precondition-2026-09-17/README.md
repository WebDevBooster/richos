# The boot that saw no display — which side changed, measured rather than argued

On 2026-09-17 the fourth nightly attempt failed in `app/scripts/gui-boot.test.sh` on B2 alone:

```
UNACCOUNTED  [richos] window: the runtime reported no attached display
NOT RESOLVED  window placement — nothing in this boot proved it was found.
```

The only app change since the last green run was the voice-provisioning land `516975db`. It
changed nothing on the window path, and it is not the cause. **The screens were asleep.**

## The call, end to end

`read_displays` (`app/src-tauri/src/main.rs:5703`) asks `app.available_monitors()`:

| hop | file:line |
|---|---|
| `AppHandle::available_monitors` | `tauri-2.11.5/src/app.rs:888` |
| runtime handle | `tauri-runtime-wry-2.11.4/src/lib.rs:2805` |
| tao, macOS | `tao-0.35.3/src/platform_impl/macos/monitor.rs:146` |

The last hop is, in full, `CGDisplay::active_displays()` — `CGGetActiveDisplayList`. macOS
**active** means connected, **awake** and available for drawing. A Mac whose screens have gone
to sleep reports every display **online** and **no display active**, so the app is told there
is no display, and it says so. It was telling the truth.

## The measurement

`pmset -g log` (`raw/04`), local time +0100; UTC in the right-hand column:

| event | local | UTC |
|---|---|---|
| displays off | 2026-09-17 02:33:47 | 01:33:47Z |
| displays on | 2026-09-17 03:16:29 | 02:16:29Z |

| run | source | window (UTC) | screens | result |
|---|---|---|---|---|
| nightly `815e318a` | `49caef3f` | ended 23:59:24Z | awake | `all 29 passed` |
| nightly `61831cdb` | `49caef3f` | ended 00:42:10Z | awake | `all 29 passed` |
| nightly `84aa5e62` | `516975db` | 02:06:26–02:13:09Z | **asleep** | `1 FAILED (B2), 28 passed` (`raw/01`) |
| by hand | `516975db` | 02:14Z | **asleep** | `1 FAILED (B2), 28 passed` |
| by hand | `516975db` | 02:25:06–02:27:11Z | awake | `all 29 passed` (`raw/02`) |
| by hand | `4e34e27d` (pre-voice control) | 02:27:56–02:30:00Z | awake | `all 29 passed` (`raw/03`) |

Row 5 is the one that settles it: the **same source** that failed passes with nothing changed
but the power state of the screen. Row 6 is the control the brief prescribed — the pre-voice
commit behaves identically.

## What changed in the suite

B2 is untouched: the two display sentences stay unaccountable, the `refused` declarations are
as they were, and A6 still holds them there. The host is now **asked first**, by
`gui_display_counts` / `gui_display_verdict` (`app/scripts/lib/gui-launch.sh`), and four cases
hold that gate to account.

| capture | what it proves |
|---|---|
| `raw/05` | `all 33 passed`, with `PASS D4 this host can answer: 3 display(s) awake … (3 online)` |
| `raw/06` | a host with no awake display is **refused by name**, exit 2, with the repair |
| `raw/07` | a host that could not be asked is refused too — an unknown is not a zero |

`raw/06` and `raw/07` were produced by stubbing `gui_display_counts` in the working tree (this
Mac's three displays are awake and this desk is not a place to put screens to sleep to prove a
point), running the suite, and reverting the stub. The command is in each file's header.

## The one thing an operator must do

Run it with the screen awake. `caffeinate -u -t 1` wakes it; `caffeinate -u -- bash
scripts/gui-boot.test.sh` wakes it and holds it awake for the whole run — which turns the
screen **on**, a visible side effect on this desk and therefore a choice rather than something
this suite does by itself.

**A nightly started while the Mac's screens are asleep still cannot pass this suite.** It now
says so in one named line in five seconds instead of failing on B2 and sending somebody to read
the source for two hours.
