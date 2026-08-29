# The RichOS app icon — what to hand over, and the one command

Everything except the artwork is built and verified. The moment you drop in one
file, one command produces every icon macOS and Windows need, checks its own
output, and tells you plainly whether it worked.

---

## 1. What to supply

**One PNG file.** Not a folder, not a set, not an SVG — a single flat PNG.

| Requirement | Value | Why |
|---|---|---|
| Format | **PNG** | JPEG and friends have no transparency, so the icon would ship with an opaque rectangle behind it |
| Shape | **Exactly square** | Nothing crops or letterboxes it; a non-square source gets squashed at every size |
| Size | **At least 1024 × 1024** | The largest macOS icon layer is 1024px. Smaller means upscaling the one layer people see biggest. Larger (2048, 4096) is fine |
| Background | **Transparent**, with a margin | macOS clips every app icon to a rounded rectangle. Artwork that runs edge to edge gets its corners cut off |
| Colour | **sRGB, 8-bit** | Anything else is converted, and the colours may shift from what your design tool showed you |
| Effects | **No rounded corners, no drop shadow** | macOS and Windows each apply their own. Baked-in ones get applied twice and look wrong |

**On the margin:** Apple draws the icon body inside 824 of 1024 pixels — about
80% of the canvas, with the rest transparent. Fill more than 90% and the
pipeline warns you; run edge to edge with no transparency at all and it stops
and says so rather than producing an icon with clipped corners.

You do not have to measure any of this. Hand over the file and the pipeline
tells you precisely what, if anything, is wrong with it.

---

## 2. Where to put it

Anywhere. Your Desktop is fine — the command takes the path as an argument and
copies what it needs. Nothing has to be moved into the repo by hand.

---

## 3. The one command

From the `richos` repo:

```sh
app/scripts/generate-app-icons.sh ~/Desktop/richos-icon.png
```

That is the whole job. It generates all six artefacts Tauri bundles — the four
PNGs, the macOS `.icns`, the Windows `.ico` — and then re-checks its own output
before it exits.

If Pillow is not installed it stops and gives you the one line to paste:
`python3 -m pip install --upgrade Pillow`.

---

## 4. How you know it worked

The last line is:

```
OK: every artefact declared in tauri.conf.json bundle.icon is present, correctly sized, and distinct.
```

Anything else is a failure, and it will name the reason. There is no ambiguous
middle state and nothing to interpret.

A successful run looks like this end to end (this is a real run, on a synthetic
test image):

```
source OK: /path/to/richos-icon.png (1024x1024 RGBA sRGB)
derived 6 required artefact(s) from app/src-tauri/tauri.conf.json
  wrote icons/32x32.png              32x32
  wrote icons/128x128.png            128x128
  wrote icons/128x128@2x.png         256x256
  wrote icons/icon.png               512x512
  wrote icons/icon.icns              layers [16, 32, 64, 128, 256, 512, 1024]
  wrote icons/icon.ico               layers [16, 24, 32, 48, 64, 256]

verifying what was just written, from tauri.conf.json...
OK: every artefact declared in tauri.conf.json bundle.icon is present, correctly sized, and distinct.
```

And if the artwork is wrong, it says so in those terms rather than producing a
subtly bad icon. Real examples, all measured:

```
FAILED:   - logo.png: is 512x512, must be at least 1024x1024. The macOS .icns
            `ic10` layer is 1024px; anything smaller upscales for exactly the
            layer shown largest, which is where softness is most visible.

FAILED:   - logo.png: the alpha channel is fully opaque edge to edge (full
            bleed). macOS clips app icons to a rounded rectangle, so the corners
            of this artwork WILL be cut off.

FAILED:   - logo.jpg: format is JPEG, must be PNG. JPEG and friends have no
            alpha channel, so the icon would ship with an opaque rectangle
            behind it.
```

Every problem with a file is reported at once, so one re-export fixes all of
them instead of discovering them one at a time.

---

## 5. What happens after

Nothing you need to do. The build gate that currently warns on every build goes
quiet, and the same check becomes a hard blocker on anything that bundles or
signs a release — so a placeholder icon cannot reach an installer from that
point on.

---

## What this does NOT solve

Being honest about the boundary: this closes the icon, and only the icon.

- **The app is still unsigned.** An ad-hoc-signed build re-identifies itself on
  every rebuild, which is why microphone and accessibility permissions reset.
  That needs the Apple Developer ID enrolment, tracked separately.
- **Windows has no code-signing certificate yet.** The `.ico` will be correct;
  the installer carrying it will still be unsigned.
- **The generated icon is only as good as the artwork.** The pipeline checks
  that a file is technically correct — square, large enough, transparent,
  sRGB. It cannot tell you whether the icon reads well at 16px in a Finder
  list. Look at the generated `32x32.png` before shipping.

---

## For engineers

Full reasoning, tool licensing, layer-coverage measurements against
`cargo tauri icon` 2.11.4, and the named off-macOS degradation are documented in
`app/scripts/lib/app_icons.py` and `app/src-tauri/build.rs`. The short version:

- The required artefact list is **derived from `tauri.conf.json`'s `bundle.icon`
  array**, never typed. Adding a size there is picked up by both the generator
  and the build gate with no code change.
- Tooling is **Pillow (SPDX `MIT-CMU`)** plus Apple's own `/usr/bin/iconutil`.
  Both are authoring-time only — nothing from either is linked into or shipped
  inside the signed `.app`, so neither touches the signing/notarisation path.
- To re-check an existing icon set without regenerating:
  `python3 app/scripts/lib/app_icons.py verify`
