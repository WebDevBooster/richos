# On-screen proof, in the test VM: the offer holds the window, and its focus ring is visible

```
+---------------------------------------------------------------------------------+
| WHAT WAS RUNNING                                                                  |
|   branch   cc/echo-opus-offer3                                                    |
|   source   4851f0f671731cabee5a7852e1eb7ac8981a74df                               |
|   bundle   RichOS.app, cargo tauri build --debug --bundles app, ad-hoc signed     |
|            zip sha256 5ce500a18204b0296052f191379a7259b2fb3f9602c7bd6d12c03a0ee6d5fa62 |
|   guest    tart clone `offer3`, 192.168.64.15, macOS 15, 1680x1050                |
|   window   RichOS 1024x700 at (438,92) — this build's stated minimum              |
|   home     a COPY of the candidate .14 QA fixture home (1.8 GB, ditto)            |
|   host     nothing rendered; `pgrep -x richos-tauri` empty on this Mac throughout |
+---------------------------------------------------------------------------------+
```

Nothing here was measured on the CEO's screen, and no voice turn was spoken anywhere
(CEO §53). The guest was stopped and deleted before this was written — `stop.sh offer3`:
*"clean: app quit, VM stopped, clone deleted, state removed."*

## How the offer was produced, and the one honest difference from Ray's fixture

Ray's candidate .16 reached the offer through a STALE engine: an engine installed by an
earlier candidate against a binary pinning a newer one. **A `cargo tauri build` cannot
reproduce that**, and the binary says so itself on its first run:

```
[richos] first-run setup: nothing missing.
```

The engine pin is three `option_env!` values read at COMPILE time
(`RICHOS_ENGINE_VERSION` / `RICHOS_ENGINE_URL` / `RICHOS_ENGINE_SHA256`,
`crates/richos-core/src/setup.rs:1004`), so a plain build carries no pin, accepts whatever
engine is on disk, and asks nothing. Measured here on the first launch, exactly as offer2
measured it before me.

So the offer was produced the other way `setup_view::detect` produces it — the engine
directory was moved aside in the guest's fixture home — and the build was redone with a pin
present so the sheet offers `Set it up` rather than explaining that it cannot install
(`setup.js` case 4). The pin's URL is deliberately non-resolving
(`https://example.invalid/richos-engine-1.2.0-offer3-proof.tar.gz`, digest all zeros) and
**`Set it up` was never pressed**: nothing in these three proofs needs it to be.

The binary's own words after the move:

```
[richos] first-run setup: the RichOS engine is NOT installed — 3 place(s) looked:
[richos] first-run setup: this build installs engine 1.2.0.
```

**What that difference does and does not cost.** The three behaviors proven below are
properties of the offer SHEET — what holds focus, what is reachable behind it, what its
primary button's focus ring is painted in. They do not depend on whether the engine is
missing or stale; the sheet, its markup and its stylesheet are identical on both paths. The
stale path's own backend arm is proven separately and by its own instrument
(`cargo test --bin richos-tauri`, and `setup.js` case 21 for the window half).

## A — the window belongs to the question (Ray's row B1b)

With the offer up and the curtain gone, the accessibility tree of the whole window:

```
$ testvm/ax.sh offer3 --focused
window: RichOS
role:   AXButton
title:  Set it up

$ testvm/ax.sh offer3 '<entire contents of window 1>'
elements: 28
group | group | RichOS | There's one thing I need on this Mac. | close button |
full screen button | group | minimize button | text |
```

**28 elements: the window chrome and the sheet.** No composer, no rail, no thread, no
top-right Settings control — they are `inert` and therefore not in the accessibility tree
at all. Ray measured the opposite on candidate .16: *"the whole app subtree is still in the
AX tree, the composer holds focus and accepts typed characters, and the top-right Settings
control is still clickable and takes focus away from the sheet."*

**A real click on the Settings control changes nothing.** `click at {1426, 145}` through
System Events in the guest — the control's own painted position — then:

```
focused role:  AXButton
focused title: Set it up          <- focus never left the sheet
elements after the click: 28      <- no menu, nothing added
```

and the window's pixels, before the click against after it, over the whole 1030x710 window:

```
pixels differing: 0 of 731300
```

Zero. The only pixels that moved anywhere in the 1680x1050 frame were 215 of them in the
guest's menu-bar clock, which turned 9:20 into 9:21. That is why there is no separate
"after the click" frame in this folder: it would be `B-ring-light.png` byte for byte.

## B — the focus ring, measured off the painted frame, in both themes

`Set it up` is `.desk-btn--confirm`: filled with `--accent`, and the shipped
`.desk-btn:focus-visible` drew its ring in `--accent` too — **1.00:1, both themes**. The
two-tone ring is read here from the pixels of the frames in this folder, on a horizontal
scan line through the button's left edge (`y=369`, `x=302..337` in the committed crops):

**A-ring-dark.png**

```
panel #182440  ->  ring #c2a35c (2px)  ->  band #0c1322 (2px)  ->  fill #c2a35c
     6.36:1                    7.68:1                    7.68:1
```

**B-ring-light.png**

```
panel #fdfcf8  ->  ring #9c7c34 (2px)  ->  band #0c1322 (2px)  ->  fill #9c7c34
     3.83:1                    4.72:1                    4.72:1
```

Every boundary of the composite clears the **3:1** a non-text indicator owes, in both
themes, and the six painted numbers are the six the stylesheet's own note derives. The
theme was moved by the STORED preference (`config.json`'s `"theme"`), not by the settings
menu — which is inert while the question is up, and that is the point of section A.

## C — Escape, with nothing covering the offer

```
$ testvm/ax.sh offer3 --key 53        # frontmost verified as the app's own pid first
focused role: AXWebArea
```

The sheet's declared dismissal (`data-dismiss="control:#setup-later,#setup-close"`) pressed
`Not now`, and `init()` then asked the next first-run question — the memory folder — which
holds the window in its turn. **This is the half that keeps the occlusion guard a floor
rather than a wall:** a popup that is painted answers Escape exactly as it always did.

**The covered half is not stageable on a real screen, and that is a fact about the product
rather than a gap in this proof.** The only two full-screen surfaces the window can put over
a popup are the opening curtain — `pointer-events: none` (`splash.css:22`), so invisible to
a hit test and guarded by `splash.js` itself — and the home screen, which gives way to a
desk sheet before it can cover one. There is no third today. The surface written next month
is the case the guard exists for, and it is planted in `escape.js` B8, whose negative
control is this same behavior.

## Privacy

Both frames are cropped to the app window (1030x710 out of 1680x1050) and OCR-gated:

```
tesseract <png> stdout | grep -iE '@[a-z0-9.-]+\.[a-z]{2,}'     -> no match, both frames
tesseract <png> stdout | grep -iE 'secret|token|password|api.key'
    A-ring-dark.png   -> "see your password."   the sheet's own copy: "I never see your
                         password." Product text, not a credential.
    B-ring-light.png  -> no match
```

The guest carried a fixture home and a stock desktop; nothing of the CEO's was on that
screen, because that screen was never his.
