#!/usr/bin/env python3
"""The launch screen's icon, made from the app icon itself (App/Platform/Assets.xcassets/AppIcon.appiconset/
AppIcon-1024.png): the same artwork in the shape iOS gives an app icon on the Home Screen (a continuous-
corner square, drawn here as a superellipse with exponent 5), with clear corners, at 2x and 3x of
LaunchShell.iconPoints, once for each look (the same art: the launch screen's images on this iPhone
render only from sets with light and dark entries, as the earlier launch art had). Android's launch
shows its launcher icon the same way (themes.xml: the window is launch_ground, and Android 12+ draws
@mipmap/ic_launcher centered on it).

    python3 Tools/launch-icon.py            write LaunchIcon.imageset/LaunchIcon-{light,dark}@{2,3}x.png
    python3 Tools/launch-icon.py --check    exit 1 when the committed images differ from a fresh render

Needs Pillow. Deterministic: the same source and Pillow give the same bytes.
"""
import io, os, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "App/Platform/Assets.xcassets")
SOURCE = os.path.join(ASSETS, "AppIcon.appiconset/AppIcon-1024.png")
OUT = os.path.join(ASSETS, "LaunchIcon.imageset")
BASE_POINTS = 134      # LaunchShell.iconPoints: 0.3583 (the share Android's icon takes) of the test iPhone's 375 pt
EXPONENT = 5.0         # the superellipse that approximates iOS's continuous-corner icon shape
SUPERSAMPLE = 4


def mask(size):
    big = size * SUPERSAMPLE
    m = Image.new("L", (big, big), 0)
    px = m.load()
    half = big / 2.0
    for y in range(big):
        v = abs((y + 0.5 - half) / half) ** EXPONENT
        for x in range(big):
            if abs((x + 0.5 - half) / half) ** EXPONENT + v <= 1.0:
                px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


def render(scale):
    size = BASE_POINTS * scale
    art = Image.open(SOURCE).convert("RGB").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(art, (0, 0), mask(size))
    buf = io.BytesIO()
    out.save(buf, format="PNG", optimize=False)
    return buf.getvalue()


def main():
    check = "--check" in sys.argv
    bad = []
    for scale, look in [(s, l) for s in (2, 3) for l in ("light", "dark")]:
        path = os.path.join(OUT, f"LaunchIcon-{look}@{scale}x.png")
        data = render(scale)
        if check:
            if not os.path.exists(path) or open(path, "rb").read() != data:
                bad.append(path)
        else:
            os.makedirs(OUT, exist_ok=True)
            open(path, "wb").write(data)
            print("wrote", path)
    if bad:
        print("launch icon differs from a fresh render of AppIcon-1024.png:", *bad, sep="\n  ")
        sys.exit(1)


if __name__ == "__main__":
    main()
