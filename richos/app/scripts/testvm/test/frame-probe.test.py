#!/usr/bin/env python3
"""frame-probe.py on generated frames: a black frame must measure black (recheck N05), a lit frame
must measure lit, and a frame that cannot be measured must refuse. Needs sips (macOS); no guest."""
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / 'frame-probe.py'
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


def png_bytes(w, h, pixel):
    raw = b''.join(b'\x00' + b''.join(pixel(x, y) for x in range(w)) for y in range(h))

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def probe(directory, name, data):
    path = Path(directory) / name
    path.write_bytes(data)
    r = subprocess.run([sys.executable, str(TOOL), str(path)], capture_output=True, text=True)
    return r.returncode, (json.loads(r.stdout) if r.stdout.strip() else {}), r.stderr


BLACK, WHITE = b'\x00\x00\x00', b'\xff\xff\xff'

with tempfile.TemporaryDirectory(prefix='frame-probe-test-') as tmp:
    rc, black, err = probe(tmp, 'black.png', png_bytes(128, 96, lambda x, y: BLACK))
    check('an all-black frame measures under the 2% line shot.sh refuses at',
          rc == 0 and black.get('nonblack_pct', 100) < 2, (rc, black, err))
    check('the probe reports the frame size', black.get('w') == '128' and black.get('h') == '96', black)

    rc, white, err = probe(tmp, 'white.png', png_bytes(128, 96, lambda x, y: WHITE))
    check('an all-white frame measures lit (control)', rc == 0 and white.get('nonblack_pct', 0) > 90, (rc, white, err))

    rc, half, err = probe(tmp, 'half.png', png_bytes(128, 96, lambda x, y: WHITE if x < 64 else BLACK))
    check('a half-lit frame measures about half lit, not black',
          rc == 0 and 35 < half.get('nonblack_pct', 0) < 65, (rc, half, err))

    rc, sparse, err = probe(tmp, 'sparse.png', png_bytes(128, 96, lambda x, y: WHITE if y < 12 else BLACK))
    check('a mostly black frame with a lit strip (a menu bar) measures above the line',
          rc == 0 and sparse.get('nonblack_pct', 0) >= 2, (rc, sparse, err))

    rc, _, err = probe(tmp, 'garbage.png', b'this is not a png')
    check('a file that cannot be decoded refuses rather than measuring as black or lit',
          rc != 0 and 'cannot' in err, (rc, err))

def rgba_png_bytes(w, h, pixel):
    """A color-type-6 (RGBA) PNG, the shape the guest's own screencapture writes: sips turns it into
    a 32-bit BI_BITFIELDS bitmap (compression 3), which the first probe refused (walk of candidate 33)."""
    raw = b''.join(b'\x00' + b''.join(pixel(x, y) + b'\xff' for x in range(w)) for y in range(h))

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


with tempfile.TemporaryDirectory(prefix='frame-probe-rgba-') as tmp:
    rc, black, err = probe(tmp, 'black.png', rgba_png_bytes(128, 96, lambda x, y: BLACK))
    check('an all-black RGBA frame measures black', rc == 0 and black.get('nonblack_pct', 100) < 2, (rc, black, err))
    rc, white, err = probe(tmp, 'white.png', rgba_png_bytes(128, 96, lambda x, y: WHITE))
    check('an all-white RGBA frame measures lit', rc == 0 and white.get('nonblack_pct', 0) > 90, (rc, white, err))
    rc, half, err = probe(tmp, 'half.png', rgba_png_bytes(128, 96, lambda x, y: WHITE if x < 64 else BLACK))
    check('a half-lit RGBA frame measures about half lit',
          rc == 0 and 35 < half.get('nonblack_pct', 0) < 65, (rc, half, err))

print('frame-probe.test.py: %d failed' % len(failures))
sys.exit(1 if failures else 0)
