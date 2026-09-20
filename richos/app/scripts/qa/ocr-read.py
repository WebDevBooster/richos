#!/usr/bin/env python3
"""Read frames through the shared OCR cache. Export text by index for shell callers."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent/'lib'))
import qaocr

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--export', type=Path)
p.add_argument('--fresh', action='store_true', help='run the reader even when a cache entry exists')
p.add_argument('frames', nargs='+')
a = p.parse_args()
try:
    if a.export:
        a.export.mkdir(parents=True, exist_ok=True, mode=0o700)
    for n, frame in enumerate(a.frames):
        text = qaocr.text(frame, fresh=a.fresh)
        if a.export:
            (a.export/('%d.txt' % n)).write_text(text)
        else:
            print(text, end='')
except qaocr.OcrUnavailable as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(2)
