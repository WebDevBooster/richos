#!/usr/bin/env python3
"""caption-wer.py — how far a transcript is from a video's captions: word error rate, and the
spelling and capitalization differences, in one JSON answer.

  caption-wer.py CAPTIONS.vtt TRANSCRIPT.txt [--top N] [--disagreements]

CAPTIONS is a WebVTT file as yt-dlp writes it (YouTube's rolling cues, where each cue repeats the
line before it, are read once). TRANSCRIPT is plain text (whisper-cli -otxt).

WHAT IS MEASURED
  wer          (substitutions + deletions + insertions) / caption words, on NORMALIZED words:
               lowercase, curly apostrophes made straight, every character that is not a letter,
               digit or apostrophe removed. Capitalization and punctuation do not count here.
  alignment    difflib's longest matching blocks anchor the two word lists; between two anchors
               the words are aligned by an exact Levenshtein, so the counts are a minimum within
               each gap. Exact over the whole text would cost |captions| x |transcript| cells
               (about 200 million for an hour), which is why it is anchored.
  capitalization  aligned word pairs that are the same word apart from letter case, counted by
               pair (for example "claude" in the captions against "Claude" in the transcript).
  spelling     aligned substitutions whose normalized forms differ but are close (difflib ratio
               at least 0.6), counted by pair: the "Cloud"/"Claude" kind, not a different word.
  disagreements  with --disagreements: every stretch where the two differ in a normalized word,
               with the caption time it starts at (hh:mm:ss, from the cue and its inline word
               times), what the captions say and what the transcript says there.
  repeats      the most frequent 2-word phrase in the transcript and how often it occurs, beside
               the same count in the captions: a decoder loop shows up here first.

Exit 0 with the JSON on stdout; exit 2 with a sentence when a file cannot be read or is empty.
"""
import argparse
import collections
import difflib
import json
import re
import sys
from pathlib import Path

TAG = re.compile(r'<[^>]+>')
CUE = re.compile(r'^\d\d:\d\d(:\d\d)?\.\d{3} --> ')


def caption_text(vtt):
    """The words of a WebVTT file, each spoken word once."""
    lines, out, last = vtt.splitlines(), [], None
    rolling = any('<c>' in line for line in lines)
    for line in lines:
        s = line.strip()
        if not s or s == 'WEBVTT' or CUE.match(s) or re.match(r'^(Kind|Language|NOTE)\b', s) or s.isdigit():
            continue
        if rolling:
            # YouTube's rolling cues: the new words carry inline <hh:mm:ss.mmm><c> tags; the plain
            # line above them is the previous cue repeated.
            if '<c>' not in s:
                continue
            s = TAG.sub('', s)
        elif s == last:
            continue
        out.append(s)
        last = s
    return ' '.join(out)


def caption_times(vtt):
    """Each caption word's start in seconds, in the order caption_text() reads them."""
    lines, out, last, start = vtt.splitlines(), [], None, 0.0
    rolling = any('<c>' in line for line in lines)
    for line in lines:
        s = line.strip()
        cue = CUE.match(s)
        if cue:
            start = seconds(s.split(' --> ')[0])
            continue
        if not s or s == 'WEBVTT' or re.match(r'^(Kind|Language|NOTE)\b', s) or s.isdigit():
            continue
        if rolling:
            if '<c>' not in s:
                continue
            at = start
            for piece in re.split(r'(<\d\d:\d\d:\d\d\.\d{3}>)', s):
                stamp = re.fullmatch(r'<(\d\d:\d\d:\d\d\.\d{3})>', piece)
                if stamp:
                    at = seconds(stamp.group(1))
                    continue
                out += [at] * len(TAG.sub('', piece).split())
        elif s != last:
            out += [start] * len(s.split())
        last = s
    return out


def seconds(stamp):
    parts = [float(x) for x in stamp.split(':')]
    return sum(v * 60 ** i for i, v in enumerate(reversed(parts)))


def clock(t):
    t = int(t)
    return f'{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}'


def words(text):
    return text.split()


def close(x, y):
    """A near spelling of the same word, not a different word."""
    return difflib.SequenceMatcher(None, x, y).ratio() >= 0.6


def norm(word):
    w = word.replace('\u2019', "'").replace('\u2018', "'").lower()
    return re.sub(r"[^\w']", '', w).strip("'")


def levenshtein_ops(a, b):
    """Exact alignment of two short word lists: list of (op, a_word, b_word), op in eq/sub/del/ins."""
    n, m = len(a), len(b)

    def sub(x, y):
        # Equal costs 0, a near spelling 0.99, any other word 1: among alignments with the same
        # number of edits, the one pairing "Claude" with "cloud" wins over pairing it with "uh".
        if x == y:
            return 0
        return 0.99 if close(x, y) else 1

    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + sub(a[i - 1][1], b[j - 1][1]))
    ops, i, j = [], n, m
    while i or j:
        if i and j and abs(d[i][j] - (d[i - 1][j - 1] + sub(a[i - 1][1], b[j - 1][1]))) < 1e-9:
            ops.append(('eq' if a[i - 1][1] == b[j - 1][1] else 'sub', a[i - 1], b[j - 1]))
            i, j = i - 1, j - 1
        elif i and abs(d[i][j] - (d[i - 1][j] + 1)) < 1e-9:
            ops.append(('del', a[i - 1], None))
            i -= 1
        else:
            ops.append(('ins', None, b[j - 1]))
            j -= 1
    return ops[::-1]


def align(ref, hyp, gap_limit=400):
    """(op, ref_word, hyp_word) over the whole text; ref/hyp are lists of (raw, normalized)."""
    sm = difflib.SequenceMatcher(None, [w[1] for w in ref], [w[1] for w in hyp], autojunk=False)
    ops = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            ops += [('eq', ref[i1 + k], hyp[j1 + k]) for k in range(i2 - i1)]
        elif (i2 - i1) * (j2 - j1) <= gap_limit * gap_limit:
            ops += levenshtein_ops(ref[i1:i2], hyp[j1:j2])
        else:
            # A gap too large to align exactly (a dropped stretch, a decoder loop): pair what can be
            # paired and count the rest, which is still a correct edit count for that gap's sizes.
            a, b = ref[i1:i2], hyp[j1:j2]
            k = min(len(a), len(b))
            ops += [('sub' if a[x][1] != b[x][1] else 'eq', a[x], b[x]) for x in range(k)]
            ops += [('del', w, None) for w in a[k:]] + [('ins', None, w) for w in b[k:]]
    return ops


def top_pair(counter, n):
    return [{'captions': a, 'transcript': b, 'count': c} for (a, b), c in counter.most_common(n)]


def repeats(ws):
    pairs = collections.Counter(zip(ws, ws[1:]))
    if not pairs:
        return None
    (a, b), c = pairs.most_common(1)[0]
    return {'phrase': f'{a} {b}', 'count': c}


def compare(vtt, txt, top=25, disagreements=False):
    times = caption_times(vtt)
    ref = [(w, norm(w), times[i] if i < len(times) else None) for i, w in enumerate(words(caption_text(vtt)))]
    hyp = [(w, norm(w)) for w in words(txt)]
    ref = [w for w in ref if w[1]]
    hyp = [w for w in hyp if w[1]]
    ops = align(ref, hyp)
    count = collections.Counter(op for op, _, _ in ops)
    caps, spell = collections.Counter(), collections.Counter()
    case_pairs = 0
    for op, r, h in ops:
        if op == 'eq':
            rw, hw = re.sub(r"[^\w']", '', r[0]), re.sub(r"[^\w']", '', h[0])
            if rw != hw and rw.lower() == hw.lower():
                caps[(rw, hw)] += 1
                case_pairs += 1
        elif op == 'sub' and close(r[1], h[1]):
            spell[(r[1], h[1])] += 1
    errors = count['sub'] + count['del'] + count['ins']
    stretches, current, at = [], None, None
    for op, r, h in ops:
        if r is not None and r[2] is not None:
            at = r[2]
        if op == 'eq':
            if current:
                stretches.append(current)
                current = None
            continue
        if current is None:
            current = {'at': clock(at or 0), 'captions': [], 'transcript': []}
        if r is not None:
            current['captions'].append(r[0])
        if h is not None:
            current['transcript'].append(h[0])
    if current:
        stretches.append(current)
    result = {
        'caption_words': len(ref), 'transcript_words': len(hyp),
        'wer': round(errors / len(ref), 4) if ref else None,
        'substitutions': count['sub'], 'deletions': count['del'], 'insertions': count['ins'],
        'capitalization_differences': case_pairs,
        'capitalization_top': top_pair(caps, top),
        'spelling_differences': sum(spell.values()),
        'spelling_top': top_pair(spell, top),
        'repeats': {'transcript': repeats([w[1] for w in hyp]), 'captions': repeats([w[1] for w in ref])},
    }
    if disagreements:
        result['disagreements'] = [{'at': d['at'], 'captions': ' '.join(d['captions']),
                                    'transcript': ' '.join(d['transcript'])} for d in stretches]
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('captions', type=Path)
    p.add_argument('transcript', type=Path)
    p.add_argument('--top', type=int, default=25, help='how many of each difference to list')
    p.add_argument('--disagreements', action='store_true', help='list every differing stretch with its caption time')
    a = p.parse_args()
    try:
        vtt, txt = a.captions.read_text(encoding='utf-8'), a.transcript.read_text(encoding='utf-8')
    except OSError as exc:
        print(f'caption-wer: cannot read the input: {exc}', file=sys.stderr)
        return 2
    if not caption_text(vtt).strip() or not txt.strip():
        print('caption-wer: the captions or the transcript has no words', file=sys.stderr)
        return 2
    print(json.dumps(compare(vtt, txt, a.top, a.disagreements), indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
