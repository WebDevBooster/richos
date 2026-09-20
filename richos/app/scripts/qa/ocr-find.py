#!/usr/bin/env python3
"""Find OCR patterns in frames. Multiple patterns share one read of each frame."""
import argparse
import json
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).parent/'lib'))
import qaocr


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('pattern')
    p.add_argument('targets', nargs='+')
    p.add_argument('--pattern', action='append', default=[], dest='patterns')
    p.add_argument('--first', action='store_true', help='first hit for EACH pattern')
    p.add_argument('--quiet', action='store_true')
    p.add_argument('--show', action='store_true')
    p.add_argument('--json', action='store_true')
    p.add_argument('--flat', action='store_true', help='only this directory, excluding other capture regions')
    p.add_argument('--timeline', action='store_true', help='date hits using meta.tsv beside each frame')
    a=p.parse_args()
    try:
        patterns=[a.pattern]+a.patterns
        regex=[re.compile(v,re.I) for v in patterns]
        frames=[]
        for target in a.targets:
            path=Path(target)
            if path.is_dir(): frames.extend(sorted(f for f in (path.glob('*') if a.flat else path.rglob('*')) if f.suffix.lower()=='.png'))
            elif path.is_file(): frames.append(path)
            else: raise ValueError('no such file or directory: '+target)
        if not frames: raise ValueError('found NO frames under the paths given')
        counts=[0]*len(patterns)
        clocks={}
        for frame in frames:
            text=qaocr.text(frame)
            hit=False
            for i, pattern in enumerate(regex):
                if a.first and counts[i]: continue
                if not pattern.search(text): continue
                counts[i]+=1; hit=True
                record={'frame':str(frame),'pattern':patterns[i]}
                if a.timeline:
                    if frame.parent not in clocks:
                        from timeline import _read_meta
                        meta, times=_read_meta(str(frame.parent))
                        clocks[frame.parent]=(float(meta['t_action_before']),float(meta['t_action_after']),dict(times))
                    start,end,times=clocks[frame.parent]
                    when=times[int(frame.stem)]
                    record.update(offset_ms=when-start,action_window_ms=end-start)
                if a.json: print(json.dumps(record))
                else:
                    print('HIT  '+str(frame)+('  %.1f ms' % record['offset_ms'] if a.timeline else ''))
                    if a.show:
                        for line in [line for line in text.splitlines() if pattern.search(line)][:3]:
                            print('       '+line)
            if not hit and not a.quiet and not a.json: print('---  '+str(frame))
            if a.first and all(counts): break
        if not a.json:
            for pat,count in zip(patterns,counts): print('--- %d of %d frame(s) match /%s/ ---' % (count,len(frames),pat))
        return 0 if all(counts) else 1
    except (qaocr.OcrUnavailable,ValueError,OSError,KeyError,re.error) as exc:
        print('ocr-find: '+str(exc),file=sys.stderr)
        return 2

if __name__=='__main__': sys.exit(main())
