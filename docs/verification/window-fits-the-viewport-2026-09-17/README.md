# The window fits the screen it opens on — CEO item 3, 2026-09-17

> If the viewport on user's device is smaller than our app's default window size, auto-adjust our
> app's window size to match the smaller viewport.

## What was already true, and why he saw otherwise

`app/src-tauri/src/window_geometry.rs` has derived the window from the work area of the display it
opens on since D2 was repaired on **2026-09-10** (`docs/hardware-choices-2026-09-10.md` D2). The
v1.0.2 he was testing predates that, which is why the behavior he reported is the behavior 1.0.2
has. Re-derived here rather than taken on trust — `decide_with` at `window_geometry.rs:342` is
called from `main.rs:1163` and applied at construction (`inner_size` / `min_inner_size` /
`position`), and `read_displays` (`main.rs:5703`) feeds it `Monitor::work_area()`.

## His two viewports, through the shipped decision function

`raw/02-small-viewports.log`, produced by `cargo run --example window_placement -- 1280x720
1024x640 1280x800 1440x900 1512x982@2` from `app/src-tauri`. The example compiles
`src/window_geometry.rs` itself by `#[path]`, so it is the shipped arithmetic and not a copy, and
it opens no window. Each panel is swept across five menu-bar/Dock models, because the work area is
what the app reads and a dry run cannot ask the window server for it.

| viewport | usable content | window opens at | floor |
|---|---|---|---|
| 1280x720 pt | 1232x644 | **1232x644** | 1024x644 |
| 1024x640 pt | 976x564 | **976x564** | **976x564** — the declared 1024x700 does not fit and is clamped down |
| 1280x800 pt panel, menu bar + Dock | 1232x630 | **1232x630** | 1024x630 |
| 1512x982 pt at scale 2 | 1464x906 | 1400x880 — the preference caps it | 1024x700 |

`raw/01-this-desk.log` is the same program against the three displays actually attached: the main
1920x1080 still opens at 1400x880 and the portrait HP E243 at 1032x880, both unchanged from D2.

The floor row is the half that is easy to miss: `minWidth: 1024` / `minHeight: 700` are a
preference too, and a window that cannot be resized small enough to fit the screen it opened on is
the same defect one level down.

## The work area, not the panel

"Match the smaller viewport" means what is visible, not what the panel measures. A 1280x800 laptop
panel with a 24pt menu bar and a 70pt Dock has 706pt of work area: the window opens 630 tall.
Reading the full frame instead would have chosen 724, whose outer box is 752 against 706 — 46
points of window behind the Dock. `the_window_fits_what_is_visible_not_the_panel` asserts both
halves, including that the panel-derived rect does NOT fit, so the fixture cannot rot into a test
that proves nothing.

## The blind path, and what changed there

`decide_with` has one path that cannot see anything: `read_displays` handed it an empty list,
because `available_monitors()` returned `Err` or an empty `Ok`.

**This is not hypothetical on this machine.** `docs/verification/gui-boot-display-precondition-2026-09-17/`
measured it the same day: macOS `CGGetActiveDisplayList` reports no ACTIVE display while the screens
are asleep, so a nightly boot at 02:06Z took exactly this path.

It used to open at the preferred 1400x880. With a 28pt title bar that is 908 points tall, and the
platform's own `center()` on an 800-point work area puts the content top at `(800 - 908) / 2 = -54`
— the title bar above the top of the screen, a window that cannot be dragged back. It now opens at
the smallest size the UI declares it needs, 1024x700, with the floor set to the same:

```
[richos] window: fallback 1024x700 pt centered by the platform, min 1024x700 —
  no display could be read; the smallest size the UI is designed for is the last resort
  and the platform is left to center it
```

**It is not a guarantee of fitting and is not claimed as one** — a 1024x640 work area holds neither
size — because a guarantee needs a reading and this path has none. It is the only size the product
itself asserts is always usable, it invents no number, and a window that is too small is one he can
fix. `app/scripts/gui-boot.test.sh` carries that sentence as a `refused` fixture and it moves with
the code; what it proves there — that a fallback is not a display-backed placement — is unchanged.

## What his sentence does NOT ask for

A window already open is not at "our app's default window size" any more, so **nothing resizes a
live window when the desk changes underneath it** and no display-change listener was added. The
case that would cover — he unplugs a display and relaunches — is already handled from the other
end: a saved geometry is honored only if a display present right now holds the whole window, so a
stranded rect is discarded and the window derived afresh (last block of both raw logs).

## Reproducing it

```
cd app/src-tauri
cargo test --bin richos-tauri window_geometry     # raw/03: 23 passed, 0 failed
cargo run --example window_placement              # raw/01
cargo run --example window_placement -- 1280x720 1024x640 1280x800 1440x900 1512x982@2   # raw/02
```

**Not proven by any of it:** that a real window opens where these numbers say. Only opening one on
each display settles that, and it needs the CEO's screen at a time he chooses.
