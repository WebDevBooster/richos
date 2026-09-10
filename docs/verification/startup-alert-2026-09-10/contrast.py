"""Measure WCAG contrast off a screenshot region.

Text is antialiased, so the extreme of the distribution is the true ink and the mode is the
true paper. Both are read from the pixels rather than from a palette somebody typed.
"""
import sys
from collections import Counter
from PIL import Image


def lum(c):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def region(im, box, label):
    px = list(im.crop(box).convert("RGB").getdata())
    counts = Counter(px)
    paper = counts.most_common(1)[0][0]
    # ink = the pixel furthest in luminance from paper that is not a stray (>=0.2% of area)
    floor = max(2, len(px) // 500)
    candidates = [c for c, n in counts.items() if n >= floor]
    ink = max(candidates, key=lambda c: abs(lum(c) - lum(paper)))
    print(f"{label:22s} paper=rgb{paper} ink=rgb{ink} ratio={ratio(ink, paper):.2f}:1")
    return ratio(ink, paper)


if __name__ == "__main__":
    im = Image.open(sys.argv[1])
    boxes = eval(sys.argv[2])  # [(label, (l, t, r, b)), ...]
    for label, box in boxes:
        region(im, box, label)
