"""How big is each glyph's INK, vendored vs the system font it replaces?

The rasters come out of raw/render-check.json, which render-check.js already
captured at 64px in WebKit: one drawn in the vendored families, one drawn in the
browser default. Both are 96x96 canvases with the same origin and baseline, so
the ink boxes are directly comparable.

This is not a pass/fail gate. It is the number a design reviewer needs in order
to rule on whether a replacement glyph is the right size, instead of being handed
a screenshot and an assurance.
"""
import base64, io, json, sys
from PIL import Image

REPORT = sys.argv[1]
data = json.load(open(REPORT))
A = data["shipped"]["charCoverage"]
B = data["fonts-starved"]["charCoverage"]


def ink(url):
    raw = base64.b64decode(url.split(",", 1)[1])
    im = Image.open(io.BytesIO(raw)).convert("L")
    # Canvas is white with black ink; anything below 250 is ink.
    bbox = im.point(lambda p: 255 if p < 250 else 0).getbbox()
    if not bbox:
        return None
    return (bbox[2] - bbox[0], bbox[3] - bbox[1])


print("%-8s %-3s  %-14s %-14s %s" % ("code", "ch", "vendored WxH", "system WxH", "height ratio"))
print("-" * 68)
rows = []
for a in A:
    b = next((x for x in B if x["code"] == a["code"]), None)
    ia = ink(a["raster"])
    ib = ink(b["raster"]) if b else None
    if not ia or not ib:
        print("%-8s %-3s  %s" % (a["code"], a["ch"], "no ink in one of the two"))
        continue
    ratio = ia[1] / ib[1]
    wratio = ia[0] / ib[0]
    rows.append((ratio, a["code"], a["ch"], ia, ib, wratio))
    print("%-8s %-3s  %-14s %-14s %.2f" % (a["code"], a["ch"], "%dx%d" % ia, "%dx%d" % ib, ratio))

print()
print("Glyphs whose ink height moved by more than 25% -- the ones a design")
print("reviewer should actually look at:")
for ratio, code, ch, ia, ib, wratio in sorted(rows):
    if ratio < 0.80 or ratio > 1.25 or wratio < 0.80 or wratio > 1.25:
        direction = "SMALLER" if ratio < 1 else "larger"
        print("   %-8s %-3s  %-7s  %dx%d -> %dx%d  (%.0f%% of the system glyph's height)"
              % (code, ch, direction, ib[0], ib[1], ia[0], ia[1], ratio * 100) + "  width %.0f%%" % (wratio * 100))
