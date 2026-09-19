# The pinned footer on the real binary, in the test VM — 2026-09-19

Two frames from the RichOS app running on a **guest** screen, never the host's. The host's
`pgrep -x richos-tauri` was empty before, during and after.

| | |
|---|---|
| build | `RichOS 1.2.0-dev.eabce90d`, cdhash `5e70f69836775d0059715aa3176c3e2d562bdb84` |
| source commit | `eabce90d81260f52b3a8b6f8ce0181a3ddb23930` (stamped into the executable and `Info.plist`) |
| harness | `richos/app/scripts/testvm/run.sh --vm phonelive2`, ready in **66 s**, guest `192.168.64.8`, app pid **671** in the guest |
| window | **1024x700 at (438,92)** on a 1680x1050 guest screen — the app's own minimum, and the size Ray's audit measured |
| fixture home | the candidate-.16 QA home, company `QA Test Co`, engine installed |
| cleanup | `stop.sh phonelive2` — *"clean: app quit, VM stopped, clone deleted, state removed"*, and it verified `pgrep` empty in the guest first |

## B — `Close` is pinned below the scroll, and the sheet's content is genuinely overflowing

`B-close-pinned-below-the-scroll.png`. Measured **from the pixels of this frame**, not from AX
and not by eye:

* the footer's divider — `--line-control`, rgb(107,126,168) — is one continuous horizontal run at
  **screen y = 702**, 290 of 290 sampled columns across the panel;
* `Close`'s border box is **x 663..731, y 715..748** on screen, which is **window-relative
  y 623..656 of 700** — it ends **44 px above the window's bottom edge**;
* the window's content bottom edge is screen **y = 792**, the same edge Ray measured against.

For comparison, Ray measured the shipped build's three controls at **y = 1175..1364** against that
same y = 792
(`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260919.5-stale-engine-and-phone-audit.md`,
"New defect: the live-code sheet's controls are below the fold").

**The content is scrolled in this frame** — the top of the sheet is cut off and the scrollbar thumb
is visible at the panel's right edge — so the footer is genuinely PINNED here rather than merely
fitting. That is `.phone-scroll` + `.phone-actions` (style.css) doing their job in the WebKit Tauri
actually ships, at the window size the defect lives at.

## A — the Settings phone row in its quiet state

`A-settings-phone-row-quiet-state.png`. Nothing paired and no code live, so the row reads
`Use Rich from your phone >` and nothing else — which is the **control** for defect D2, not the
defect. It shows the new two-line column renders the row unchanged when there is nothing to say.

## What these frames do NOT show, and why

**The live-code screen is unreachable in the guest.** Frame B is the identity screen — *"First:
Tailscale has no password"* — which `phone.js`'s `render()` selects only when the Mac has no
Tailscale account at all. The guest's Tailscale is installed and left signed out on purpose
(`richos/app/scripts/testvm/provision-guest.sh:147-153`), and `begin_pairing` refuses without a
certificate (`src-tauri/src/phone/mod.rs:858-862`, `serving_plan` at `:563-580`). So on this guest
there can be no live code, no paired phone and no phone-to-Mac message — the whole of what this
task's three defects are about. Raised as **`esc-20260919T191255Z-0f3d73c7`**; one human sign-in
unblocks every future phone proof there and it is the CEO's to give.

Both frames were OCR-gated for an address before being committed
(`tesseract <png> stdout | grep -iE '@[a-z0-9.-]+\.[a-z]{2,}'` — no match in either) and
eye-checked: the identity screen names only the four sign-in providers, never an account.
