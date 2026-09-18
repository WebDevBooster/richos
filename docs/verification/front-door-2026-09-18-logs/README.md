# The four dumps row 2 was settled on

Captured by `app/scripts/front-door.test.sh --evidence` against
`v1.2.0-nightly.20260918.3` (`RichOSSourceCommit` `794eac7f`), on this machine, 2026-09-18.
The reasoning that reads them is the postscript of
[`2026-09-18-front-door-what-the-harness-was-measuring-instead.md`](../2026-09-18-front-door-what-the-harness-was-measuring-instead.md).

Each line is `role | x,y WxH | name=… | value=…`. The box is the whole point: presence in this
tree is not evidence of being on screen.

| File | Run | What it is evidence of |
|---|---|---|
| `c4-settings-menu-open.txt` | 16:46:41Z, dump `5-setmenu` | The settings menu open — `AXMenu \| 1375,196 267x637 \| name=Settings` and its rows, 107 nodes. |
| `c4-after-escape.txt` | same run, dump `6-setmenu-esc` | One Escape later — the `AXMenu` and every row inside it gone, 48 nodes, only the `AXPopUpButton` that opens it left. **This is the answer to row 2.** |
| `c5-closed-sheets-at-rest.txt` | same run, dump `0-rest` | The C5 calibration: three `display:none` sheets all reporting `260,130 1400x10`, which is why "0x0 for an unrendered subtree" was wrong. |
| `the-boot-that-put-an-alert-on-his-screen.log` | 16:11:56Z | The one line behind the modal the CEO photographed: `home is not a canonical directory`. |

The runs at 16:47:57Z and 17:00:50Z reproduce the first two dumps and are not copied here; the
check prints its own `--evidence` path on every run, so any of them can be retaken.
