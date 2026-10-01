#!/usr/bin/env python3
"""frame-probe.py <png> — is a captured frame a picture or black? Prints one JSON line
{"w": ..., "h": ..., "nonblack_pct": ...}; `shot.sh` refuses the frame when that is under 2.

The frame is downscaled to 64x64 with sips and decoded as an UNCOMPRESSED BMP, so the pixels
measured are pixel intensities: the color channels of each pixel, read from the file's own
declared pixel-data offset. (The first version read the tail of a TIFF and called it a bitmap;
a TIFF's tail is its metadata directory, which is never black, so an all-black frame measured
17.5% non-black and was accepted as a capture: recheck N05.) sips ships with macOS; no
third-party image library is needed."""
import json
import os
import struct
import subprocess
import sys
import tempfile

THRESHOLD = 24  # a color channel above this counts as lit
SIDE = 64


def prop(png, key):
    out = subprocess.run(["sips", "-g", key, png], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if key in line:
            return line.split(":")[-1].strip()
    return "?"


def nonblack_percent(bmp):
    """Percent of color-channel bytes above THRESHOLD in a BMP's pixel data; raises ValueError
    when the file is not an uncompressed 24/32-bit BMP (a measurement that cannot be made must
    refuse, never read as black or as lit)."""
    if len(bmp) < 54 or bmp[:2] != b"BM":
        raise ValueError("not a BMP")
    offset = struct.unpack_from("<I", bmp, 10)[0]
    width = struct.unpack_from("<i", bmp, 18)[0]
    height = abs(struct.unpack_from("<i", bmp, 22)[0])
    bits = struct.unpack_from("<H", bmp, 28)[0]
    compression = struct.unpack_from("<I", bmp, 30)[0]
    channels = (0, 1, 2)  # byte positions of B, G, R in a pixel
    if bits == 32 and compression == 3 and len(bmp) >= 66:
        # BI_BITFIELDS (what sips writes for a frame with an alpha channel): the red, green and blue
        # masks follow the header; each must be one whole byte, and those bytes are the colors.
        masks = struct.unpack_from("<III", bmp, 54)
        channels = tuple({0xFF: 0, 0xFF00: 1, 0xFF0000: 2, 0xFF000000: 3}.get(m, -1) for m in masks)
        if -1 in channels or len(set(channels)) != 3:
            raise ValueError("unsupported BMP bit masks %s" % (masks,))
        compression = 0
    if bits not in (24, 32) or compression != 0 or width <= 0 or height <= 0:
        raise ValueError("unsupported BMP: %d bits, compression %d" % (bits, compression))
    step = bits // 8
    stride = (width * step + 3) // 4 * 4
    lit = total = 0
    for row in range(height):
        start = offset + row * stride
        pixels = bmp[start:start + width * step]
        if len(pixels) < width * step:
            raise ValueError("truncated BMP pixel data")
        for i in range(0, len(pixels), step):
            for position in channels:  # the alpha byte of a 32-bit pixel is not a color
                total += 1
                if pixels[i + position] > THRESHOLD:
                    lit += 1
    return 100.0 * lit / max(1, total)


def main(png):
    w, h = prop(png, "pixelWidth"), prop(png, "pixelHeight")
    fd, tmp = tempfile.mkstemp(suffix=".bmp", prefix="frame-probe-")
    os.close(fd)
    try:
        run = subprocess.run(["sips", "-s", "format", "bmp", "-z", str(SIDE), str(SIDE), png, "--out", tmp],
                             capture_output=True, text=True)
        if run.returncode != 0:
            raise ValueError("sips could not decode the frame: " + run.stderr.strip())
        with open(tmp, "rb") as fh:
            pct = nonblack_percent(fh.read())
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    print(json.dumps({"w": w, "h": h, "nonblack_pct": round(pct, 1)}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: frame-probe.py <png>")
    try:
        main(sys.argv[1])
    except ValueError as exc:
        sys.exit("frame-probe: cannot measure the frame: %s" % exc)
