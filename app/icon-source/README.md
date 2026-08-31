# The RichOS app icon — source artwork

`richos-icon-1024.png` is the file `app/scripts/generate-app-icons.sh` was run against.
Everything under `app/src-tauri/icons/` is derived from it and nothing else.

```sh
app/scripts/generate-app-icons.sh app/icon-source/richos-icon-1024.png
```

`richos-icon.svg` is the vector the PNG was exported from — open it in a browser or any
vector tool and re-export at 1024 to change the artwork. The PNG is what the pipeline
takes; the SVG is what a human edits. The pipeline rejects SVG on purpose (`APP-ICON.md`).

**What it is made of.** The mark is
`assets/logo-wordmark/RichOS-logo_v3.5_black-and-white.svg` (richos-hq) with its path data
untouched — the R whose counter is the rising arrow. The colours are the CEO's Sovereign
standard, `ceo-decisions.md` §14: ground `0C1322`, surface `141E34`, light `DFE4EE`,
signal `C2A35C`, trim `4C6087`. The body is Apple's 824-of-1024 icon grid drawn as a
superellipse; everything outside it is transparent, and there is no baked drop shadow —
macOS and Windows each apply their own.

**Measured contrast**, worst case over every pixel of the mark against the ground directly
beneath it: R body **9.03:1**, arrow **4.11:1**, and the arrow against the R body where they
meet **3.67:1**. The floor for a non-text indicator is 3:1, so all three clear it.

`preview/` is the shipped bytes, not a re-render: 32 and 128 are copied out of
`app/src-tauri/icons/`, 16 is the `icon.ico` 16px layer, 1024 is the `icon.icns` `ic10`
layer. Look at 16 and 32 before changing anything — that is where an icon fails.
