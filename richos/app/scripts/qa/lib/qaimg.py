"""qaimg.py — the one place this toolkit reads, measures and writes a PNG.

===========================================================================
WHY IT DOES NOT SIMPLY `import PIL`
===========================================================================
Every walk helper that ever measured a pixel opened the frame with Pillow,
and one of them could not: on the candidate .11 walk Pillow was not
importable from the interpreter the walk had, so that run hand-decoded PNG
IDAT chunks with `struct` and `zlib` inside a heredoc, twice, to answer a
contrast question. Hand-rolling a PNG decoder to measure a color is the
whole failure this toolkit exists to end, so the decoder is here, once.

Pillow is used when it imports, because it is faster and it draws text.
When it does not, everything except text rendering still works. A caller
therefore never has to know which case it is in, which is the point: a
helper that works on one machine and refuses on another gets rewritten on
the other machine.

===========================================================================
WHAT IT REFUSES
===========================================================================
Interlaced PNG, and bit depths other than 8 and 16, are refused BY NAME
rather than decoded wrongly. A wrong pixel value is a wrong contrast ratio
is a wrong audit verdict, and the audit has no way to notice.
"""

import os
import struct
import sys
import zlib

try:                                     # pragma: no cover - environment split
    from PIL import Image as _PILImage   # noqa: N812
    from PIL import ImageDraw as _PILDraw
    HAVE_PIL = True
except Exception:                        # pragma: no cover - environment split
    _PILImage = None
    _PILDraw = None
    HAVE_PIL = False


class ImageError(Exception):
    """Something about this image cannot be answered honestly."""


# ---------------------------------------------------------------------------
# The image object. Deliberately tiny: width, height, and a flat RGB bytearray.
# ---------------------------------------------------------------------------
class Img(object):
    __slots__ = ("w", "h", "px")

    def __init__(self, w, h, px):
        self.w = w
        self.h = h
        self.px = px                      # bytearray, len == w*h*3, RGB

    # -- reading ------------------------------------------------------------
    def at(self, x, y):
        if not (0 <= x < self.w and 0 <= y < self.h):
            raise ImageError("point (%d,%d) is outside the %dx%d image"
                             % (x, y, self.w, self.h))
        i = (y * self.w + x) * 3
        return (self.px[i], self.px[i + 1], self.px[i + 2])

    def region(self, x0, y0, x1, y1):
        """Every pixel of the half-open box, as a list of RGB tuples.

        The box is CLAMPED to the image and refused if that leaves it empty:
        a crop that silently falls off the edge returns a handful of border
        pixels and a confident, wrong answer.
        """
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(self.w, x1), min(self.h, y1)
        if cx1 <= cx0 or cy1 <= cy0:
            raise ImageError(
                "region %d,%d..%d,%d does not overlap the %dx%d image"
                % (x0, y0, x1, y1, self.w, self.h))
        out = []
        for y in range(cy0, cy1):
            base = (y * self.w + cx0) * 3
            row = self.px[base:base + (cx1 - cx0) * 3]
            for i in range(0, len(row), 3):
                out.append((row[i], row[i + 1], row[i + 2]))
        return out

    def crop(self, x0, y0, x1, y1):
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(self.w, x1), min(self.h, y1)
        if cx1 <= cx0 or cy1 <= cy0:
            raise ImageError(
                "crop %d,%d..%d,%d does not overlap the %dx%d image"
                % (x0, y0, x1, y1, self.w, self.h))
        w, h = cx1 - cx0, cy1 - cy0
        out = bytearray(w * h * 3)
        for y in range(h):
            src = ((cy0 + y) * self.w + cx0) * 3
            out[y * w * 3:(y + 1) * w * 3] = self.px[src:src + w * 3]
        return Img(w, h, out)

    # -- writing ------------------------------------------------------------
    def fill_box(self, x0, y0, x1, y1, rgb):
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(self.w, x1), min(self.h, y1)
        if cx1 <= cx0 or cy1 <= cy0:
            return 0
        row = bytes(bytearray(rgb) * (cx1 - cx0))
        for y in range(cy0, cy1):
            base = (y * self.w + cx0) * 3
            self.px[base:base + len(row)] = row
        return (cx1 - cx0) * (cy1 - cy0)

    def scale_nearest(self, factor):
        if factor < 1:
            raise ImageError("scale factor must be 1 or more, got %r" % factor)
        if factor == 1:
            return Img(self.w, self.h, bytearray(self.px))
        w, h = self.w * factor, self.h * factor
        out = bytearray(w * h * 3)
        for y in range(self.h):
            src = self.px[y * self.w * 3:(y + 1) * self.w * 3]
            wide = bytearray(w * 3)
            for x in range(self.w):
                p = src[x * 3:x * 3 + 3]
                wide[x * factor * 3:(x + 1) * factor * 3] = bytes(p) * factor
            for k in range(factor):
                r = (y * factor + k) * w * 3
                out[r:r + w * 3] = wide
        return Img(w, h, out)


# ---------------------------------------------------------------------------
# PNG decode
# ---------------------------------------------------------------------------
def _unfilter(raw, w, h, bpp):
    stride = w * bpp
    out = bytearray(stride * h)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ft = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ft == 0:
            pass
        elif ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ImageError("PNG filter type %d is not defined" % ft)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def _decode_png(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ImageError("not a PNG (bad signature)")
    i = 8
    idat = []
    w = h = depth = ctype = interlace = None
    palette = None
    while i + 8 <= len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            w, h, depth, ctype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            palette = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    if w is None:
        raise ImageError("PNG has no IHDR")
    if interlace:
        raise ImageError("interlaced PNG is not supported — re-capture without interlacing")
    if depth not in (8, 16):
        raise ImageError("PNG bit depth %d is not supported (8 and 16 are)" % depth)
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if chans is None:
        raise ImageError("PNG color type %d is not defined" % ctype)
    if ctype == 3 and depth != 8:
        raise ImageError("paletted PNG at bit depth %d is not supported" % depth)
    bpp = chans * (depth // 8)
    raw = _unfilter(zlib.decompress(b"".join(idat)), w, h, bpp)

    px = bytearray(w * h * 3)
    step = depth // 8
    for n in range(w * h):
        o = n * bpp
        if ctype == 3:
            idx = raw[o]
            if palette is None or (idx + 1) * 3 > len(palette):
                raise ImageError("paletted PNG with an index outside its PLTE")
            px[n * 3:n * 3 + 3] = palette[idx * 3:idx * 3 + 3]
            continue
        if ctype in (0, 4):
            g = raw[o]
            px[n * 3] = px[n * 3 + 1] = px[n * 3 + 2] = g
            continue
        px[n * 3] = raw[o]
        px[n * 3 + 1] = raw[o + step]
        px[n * 3 + 2] = raw[o + 2 * step]
    return Img(w, h, px)


def load(path):
    """Read a PNG into an Img. Pillow when it is there, the decoder above when not."""
    if HAVE_PIL:
        try:
            im = _PILImage.open(path).convert("RGB")
            return Img(im.width, im.height, bytearray(im.tobytes()))
        except Exception as exc:
            raise ImageError("could not read %s: %s" % (path, exc))
    try:
        with open(path, "rb") as fh:
            return _decode_png(fh.read())
    except ImageError:
        raise
    except Exception as exc:
        raise ImageError("could not read %s: %s" % (path, exc))


def save(img, path):
    """Write an Img as a PNG. No Pillow needed — the writer is 12 lines."""
    rows = bytearray()
    for y in range(img.h):
        rows.append(0)
        rows += img.px[y * img.w * 3:(y + 1) * img.w * 3]

    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF))

    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", img.w, img.h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(blob)


_FONT_CANDIDATES = (
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
)


def render_text(w, h, lines, fg=(0, 0, 0), bg=(255, 255, 255), size=22):
    """A plain image of text, for fixtures and for OCR positive controls.

    Uses a system TrueType face at a size tesseract reads reliably. The
    built-in bitmap font is too small at any sane canvas size: at 11px the
    reader returns 'qa-fixture @exam ple. invalid', and a positive control
    that only half-reads is not a control.

    Needs Pillow, and says so rather than producing a blank picture a gate
    would then declare clean.
    """
    if not HAVE_PIL:
        raise ImageError(
            "rendering text needs Pillow, which is not importable here "
            "(pip3 install Pillow) — every other tool in qa/ works without it")
    from PIL import ImageFont as _PILFont
    font = None
    for path in _FONT_CANDIDATES:
        if os.path.isfile(path):
            try:
                font = _PILFont.truetype(path, size)
                break
            except Exception:
                continue
    if font is None:
        raise ImageError(
            "no system TrueType face found in %s — a fixture rendered with the "
            "bitmap fallback is not readable enough to be a control"
            % ", ".join(_FONT_CANDIDATES))
    im = _PILImage.new("RGB", (w, h), bg)
    d = _PILDraw.Draw(im)
    y = 8
    for line in lines:
        d.text((10, y), line, fill=fg, font=font)
        y += size + 8
    return Img(im.width, im.height, bytearray(im.convert("RGB").tobytes()))


def render_blocks(w, h, bg, fg, box):
    """A solid `fg` rectangle on a solid `bg` field — exactly two colors.

    The contrast fixtures are blocks rather than glyphs on purpose: an
    antialiased stroke has a dozen shades and the estimator picks one of
    them, so a text fixture would assert the estimator's heuristic rather
    than the arithmetic. A block asserts the arithmetic, and a reviewer can
    verify the expected ratio by hand from the two hex values.
    """
    img = Img(w, h, bytearray(bytes(bytearray(bg)) * (w * h)))
    img.fill_box(box[0], box[1], box[0] + box[2], box[1] + box[3], fg)
    return img


# ---------------------------------------------------------------------------
# Color: ONE luminance, ONE ratio, for every tool here.
# ---------------------------------------------------------------------------
def _lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    return 0.2126 * _lin(rgb[0]) + 0.7152 * _lin(rgb[1]) + 0.0722 * _lin(rgb[2])


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def parse_color(text):
    """'#8f7030', '8F7030', '143,112,48' or 'rgb(143,112,48)' -> (r,g,b).

    All three spellings, because one value has more than one of them and a
    tool that accepts only the one the caller did not use gets replaced by a
    new tool.
    """
    s = text.strip().lower()
    if s.startswith("rgb(") and s.endswith(")"):
        s = s[4:-1]
    if "," in s:
        parts = [p.strip() for p in s.split(",")]
        if len(parts) != 3:
            raise ImageError("%r is not three comma-separated channels" % text)
        try:
            vals = [int(p) for p in parts]
        except ValueError:
            raise ImageError("%r has a non-numeric channel" % text)
        if any(v < 0 or v > 255 for v in vals):
            raise ImageError("%r has a channel outside 0..255" % text)
        return tuple(vals)
    s = s.lstrip("#")
    if len(s) == 3:
        s = "".join(ch * 2 for ch in s)
    if len(s) != 6:
        raise ImageError("%r is not a 3- or 6-digit hex value" % text)
    try:
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
    except ValueError:
        raise ImageError("%r is not hexadecimal" % text)


def hexs(rgb):
    return "#%02X%02X%02X" % (rgb[0], rgb[1], rgb[2])


def die(msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    raise SystemExit(1)
