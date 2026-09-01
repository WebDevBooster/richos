# The home screen, on the shipped bundle — 2026-09-01

What was run on the real, ad-hoc-signed `RichOS.app`, in what order, and — first, because it is
the part that shapes everything else — **what could not be run and why**.

## THE LIMIT, NAMED FIRST

**There is no native screenshot of the home screen, for two different reasons two hours apart,
and both are measured.** The full account is in `screen-capture-is-worth-nothing.txt`.

At 21:30 the display was locked: `screencapture -x`, with RichOS open and running, returned a
valid 1920 × 1080 PNG holding **one distinct color across all 2,073,600 pixels, zero of them
non-black** — against 354,525 colors and 100% non-black for the same screen as WebKit paints it.
`System Events` also returned an empty window list for the process, so the sequence could not be
driven natively either.

At 22:33 the display was awake, and the frame was **the CEO's own working screen** — Chrome in
front of everything on `round-11.2/index.html`, the contact sheet of six switch affordances he is
choosing between. 383,291 colors, and not one of them the app: the RichOS window opened behind
his work, which is what `open -n` should do. **It was not forced to the front**, because taking
his screen away mid-session to photograph a window is not a thing this pass may do, and the frame
would still have been most of his desktop. That capture was deleted rather than kept.

So the interaction sequence — splash → home screen → switch → app UI → click the logo → home
screen — is driven and photographed in **WebKit, the engine Tauri renders through on macOS**, by
`app/ui/tests/home.js`, and its six frames are committed in `app/ui/tests/shots-home/`. What is
proven HERE is the other half: that the thing WebKit drove is byte-for-byte the thing the bundle
ships, and that the bundle boots the way a double-click boots it.

## 1. The launch — `open-launch.txt`

`open -n RichOS.app`, so the process gets what LaunchServices gives it and not what this shell
has.

```
cwd            /
threads        21
rss            102,976 KB at 8s, 103,024 KB at 16s
still alive at ~16s: yes
```

`cwd = /` is the condition that has broken this app three times in one day (`gui-boot.test.sh`
lists the three commits). It survives it, and it is still up well past the curtain's 3,000 ms
hold and the field's arrival at ~460 ms.

**Residue: 0, counted two ways.** Other agents are building and launching their own RichOS
bundles out of their own worktrees on this machine, so the count that means anything is the one
scoped to this bundle's path — and the machine-wide count is printed beside it so the difference
is visible. Both were 0 before and 0 after. An earlier run of this script reported 1 machine-wide
and 0 for this bundle: the one was `echo-opus-sp1`'s build, and it was left alone.

## 2. The boot log — `boot.log`

Captured by running the bundled binary directly under a stripped environment (`HOME`, `USER`,
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `TMPDIR`) from `/`, because `open` detaches and takes
stdout with it. Ten lines, every one of them a resolution, ending in

```
[richos] boot complete — every line above is what this launch resolved
```

Nothing in it mentions the home screen, and nothing should: the home screen is a webview
surface and the shell prints operator lines only. What it proves is that the process this
surface lives inside comes up whole on the CEO's own launch.

## 3. What shipped is what was tested — `shipped-identity.txt`

`build.rs` stages `app/ui` into `app/ui-dist` and `tauri-codegen` brotli-compresses everything
under it INTO the executable — not into `Contents/Resources`, which is where people look. So the
join is by hash:

- **sixteen files byte-identical** between the source tree the acceptance suite drives and the
  staged tree Tauri embedded, including all four ported field files and `fonts/fonts.css`;
- **`tests/` and `node_modules/` absent** from the staged tree (they were 60.8% of the
  application once);
- **eight asset keys present inside the executable**, `/home.js` and the four `/home/field-*.js`
  among them.

Executable: 18,549,648 bytes. `com.richos.app`, ad-hoc signed, no team identifier — Gatekeeper
rejects it and its permission grants die on the next build that changes a byte, which is
`packaging-and-signing.md`'s standing condition and not this pass's business.

## What is NOT proven here

- That the home screen **renders** in the native window. It renders in WebKit from the same
  bytes and the frames are in `app/ui/tests/shots-home/`, but nobody has photographed the real
  window; see above for why not, twice.
- Anything about a signed, notarized bundle. This is ad-hoc.
- Anything about a second machine.
