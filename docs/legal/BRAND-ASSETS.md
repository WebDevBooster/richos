# Brand assets — what the AGPL does not cover

The root `LICENSE` is the GNU AGPL v3 and it covers the **software** in this
repository. It does not cover the RichOS brand.

**The RichOS name, the RichOS mark and wordmark, the application icons, the
banner artwork and the Rich Hand avatar are not licensed under the AGPL. All
rights in them are reserved unless separately authorized in writing by the
copyright holder.**

This is the ordinary shape of an open-source project with a name worth
protecting — the same position Mozilla takes with the Firefox branding and the
Chromium project takes with the Chrome marks. You may take the software; you may
not take the identity and present your build as RichOS.

Without this document a visitor reads a root AGPL and reasonably concludes the
grant covers the logo too, because a license file at the root of a repository
says nothing about scope on its own. That silence was a real gap until
2026-09-04, and this file closes it.

## What is excluded, exactly

Every path below is excluded from the AGPL grant. Nothing outside this list is
excluded — if a file is not named here, the AGPL covers it.

### Image and vector files

| Path | What it is |
|---|---|
| `.github/images/richos-banner.jpg` | The project banner on the repository front page |
| `app/icon-source/richos-icon.svg` | The application icon, vector master |
| `app/icon-source/richos-icon-1024.png` | The application icon, raster master |
| `app/icon-source/preview/richos-icon-1024.png` | Icon preview renders |
| `app/icon-source/preview/richos-icon-128.png` | Icon preview renders |
| `app/icon-source/preview/richos-icon-32.png` | Icon preview renders |
| `app/icon-source/preview/richos-icon-16.png` | Icon preview renders |
| `app/src-tauri/icons/icon.icns` | Generated macOS icon |
| `app/src-tauri/icons/icon.ico` | Generated Windows icon |
| `app/src-tauri/icons/icon.png` | Generated icon |
| `app/src-tauri/icons/32x32.png` | Generated icon |
| `app/src-tauri/icons/128x128.png` | Generated icon |
| `app/src-tauri/icons/128x128@2x.png` | Generated icon |
| `app/ui/assets/rich-hand.png` | The Rich Hand avatar artwork |

`app/icon-source/README.md` is **not** excluded. It is documentation about how
the icons are produced and it stays under the AGPL like every other document
here. The exclusion is the artwork, not the prose about the artwork.

### Artwork embedded in source files

Three constants hold the mark's drawing instructions as data inside JavaScript
files. **The files themselves stay under the AGPL as software.** What is
excluded is the artwork those constants encode — the outline geometry of the
RichOS mark and wordmark:

| File | Constant | What it encodes |
|---|---|---|
| `app/ui/splash.js` | `LOGO` | The RichOS mark, `viewBox 0 0 744 744`, two paths |
| `app/ui/splash.js` | `WORDMARK` | The v3.5 wordmark, `viewBox 0 0 3299.1 754.5`, seven paths |
| `app/ui/home.js` | `MARK_SVG` | The same v3.5 wordmark, as inline SVG markup |

They are named by constant rather than by line number because line numbers move
and a legal boundary that drifts with an unrelated edit is not a boundary. At
the time of writing they are at `splash.js` 283–301 and `home.js` 173–183.

**What this means in practice for a fork:** take the file, keep the renderer,
replace the path data with your own mark. Everything around the constants — the
SVG assembly, the relief filter, the animation, the accessibility handling — is
AGPL software you may use and modify freely.

### Screenshots that reproduce the brand

The committed browser-suite evidence under `app/ui/tests/shots-*` contains
rendered screenshots of the running application, and those images show the mark,
the wordmark and the splash compositions. Twelve directories:

`shots-3-1`, `shots-5`, `shots-5b`, `shots-5c`, `shots-5d`, `shots-7-2`,
`shots-10-1`, `shots-26`, `shots-contrast`, `shots-home`, `shots-splash`,
`shots-updates`.

They are test evidence and they exist so a reviewer can check a rendering claim.
Reading them, diffing them and regenerating them are all ordinary uses of this
repository. Extracting the brand elements out of them is not.

### The name

**RichOS** is the project's name and identity. The AGPL grants no rights in it,
and neither does this document.

## What you may do with the excluded files

You may:

- **View them** in the repository, on GitHub or in a clone.
- **Build and run RichOS unmodified** for yourself, with its own branding
  intact. That is what the artwork is there for.
- **Fork the repository** on GitHub. A fork necessarily copies these files, and
  that is fine — GitHub forks are how the AGPL's source obligations are usually
  satisfied.
- **Reproduce the mark or banner to refer to the project** — in an article, a
  talk, a comparison, a list of tools. Nominative reference is not something
  this document tries to restrict.

You may not, without separate written permission:

- **Distribute a modified RichOS carrying the RichOS name, mark, icons or
  avatar.** Rebrand it. This is the whole point of the exclusion: a user must be
  able to tell whether the thing in front of them came from here.
- **Use the name or mark for your own product, service or organization**, or in
  a way that suggests endorsement by or affiliation with RichOS.
- **Register the name or a confusingly similar one** as a trademark, domain,
  package name or app-store listing.
- **Use the artwork for anything unrelated to RichOS** — merchandise, templates,
  asset packs, training corpora sold as such.

If you want to do something this document does not permit, ask. The answer is
often yes, and it costs an email.

## Why the embedded artwork was not extracted into asset files

The pre-publication audit asked for embedded artwork to be moved into standalone
asset files "where practical", because a file that mixes code and art makes the
boundary ambiguous. It was considered and **not** done, and the reason is
specific rather than reluctance:

- `home.js` builds `MARK_SVG` as an inline string deliberately, on the documented
  ground that the boot path must not wait on a fetch. Turning it into a fetched
  `.svg` moves brand rendering onto the network path of a cold start — a real
  regression traded for a documentation convenience.
- `splash.js` reads its geometry from `LOGO` and `WORDMARK` constants that its
  own suite treats as fixed. `splash-library.js` is checked to be pure JSON data
  and `splash.js` is checked to contain no variation-specific value, so the mark
  lives where it does because two tests require it to.

The ambiguity is therefore resolved by naming the constants here, which costs
nothing and breaks nothing. If the boot path is ever restructured for other
reasons, extraction becomes free and should be taken then.

## Where this is referenced from

- `docs/legal/LICENSING.md` — the licensing overview points here for scope.
- `engine/LICENSING.md` — the engine's own terms point here for the same reason.
- `.github/README.md` — the project front page should link here alongside the
  license and the third-party notices. That link belongs to the README rewrite
  tracked as section 4 of the 2026-09-04 pre-publication audit; this file is
  written to be linked and is not itself the README's author.
