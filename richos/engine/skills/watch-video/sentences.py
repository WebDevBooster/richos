#!/usr/bin/env python3
"""sentences.py <transcript.md> [<me.json>] -- index rows for watch.sh.

Prints one row per line, "SSSSSSS.SS<TAB>**[MM:SS] Me:** text", sorted later by
watch.sh. The rows are built from whisper's RAW words (the JSON's per-word token
times): the word stream is split into sentences at the end punctuation whisper
itself put on its words (a closing quote stays with its sentence), each sentence
is stamped with the time of its first raw word, and only then is each sentence's
text run through the vocabulary corrector (correct-text.mjs). Nothing matches
corrected text back to raw words, so a name correction can never move a time.
The transcript.md paragraphs supply the speaker and each paragraph's own stamp,
and decide which raw words belong to which paragraph. With no usable whisper
JSON, or a paragraph with no raw words, the paragraph stays one row at its own
time (its text as the transcript has it), which is the old behavior.
"""
import json
import os
import re
import subprocess
import sys

PARA = re.compile(r"^\*\*\[([0-9:]+)\] ([^:]*):\*\* (.*)$")
END = re.compile(r"[.!?][\"”’')\]]*$")
OPENS = re.compile(r"^[\"'(“‘\[]*[A-Z0-9]")


def whisper_words(path):
    """[(raw word text, start seconds)] from the token times."""
    words = []
    try:
        with open(path) as f:
            data = json.load(f)
        for seg in data.get("transcription", []):
            for tok in seg.get("tokens", []):
                text = tok.get("text", "")
                if text.startswith("[_") or not text.strip():
                    continue
                start = tok["offsets"]["from"] / 1000.0
                if text.startswith(" ") or not words:
                    words.append([text.strip(), start])
                else:
                    words[-1][0] += text
    except (OSError, ValueError, KeyError, TypeError):
        return []
    return [(w, s) for w, s in words if w]


def split_sentences(words):
    """Group raw words into sentences: [[(word, start), ...], ...]."""
    out, cur = [], []
    for i, (w, s) in enumerate(words):
        cur.append((w, s))
        last = i + 1 == len(words)
        if END.search(w) and (last or OPENS.match(words[i + 1][0])):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def correct_all(texts):
    """The vocabulary corrector over every sentence in one Node call; the raw text on any failure."""
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        r = subprocess.run(["node", os.path.join(here, "correct-text.mjs")],
                           input=json.dumps(texts), capture_output=True, text=True, timeout=60)
        out = json.loads(r.stdout)
        if r.returncode == 0 and isinstance(out, list) and len(out) == len(texts):
            return [str(t) for t in out]
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return texts


def parse_stamp(stamp):
    parts = [int(p) for p in stamp.split(":")]
    secs = 0
    for p in parts:
        secs = secs * 60 + p
    return secs, len(parts)


def fmt_stamp(secs, nparts):
    secs = int(secs)
    if nparts >= 3 or secs >= 3600:
        return "%02d:%02d:%02d" % (secs // 3600, secs % 3600 // 60, secs % 60)
    return "%02d:%02d" % (secs // 60, secs % 60)


def main():
    transcript = sys.argv[1]
    words = whisper_words(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else []
    with open(transcript) as f:
        paras = [m.groups() for m in map(PARA.match, f.read().splitlines()) if m]
    stamps = [parse_stamp(p[0]) for p in paras]
    # rows: [paragraph index, first raw word's start or None, text, is raw]
    rows = []
    k = 0  # next unassigned raw word
    for i, (_stamp, _speaker, text) in enumerate(paras):
        if i + 1 < len(paras):
            limit = stamps[i + 1][0] - 1.0
            j = k
            while j < len(words) and words[j][1] < limit:
                j += 1
        else:
            j = len(words)
        mine = words[k:j]
        k = j
        if mine:
            for sent in split_sentences(mine):
                rows.append([i, sent[0][1], " ".join(w for w, _ in sent), True])
        else:
            rows.append([i, None, text, False])
    raw_idx = [n for n, r in enumerate(rows) if r[3]]
    if raw_idx:
        for n, t in zip(raw_idx, correct_all([rows[n][2] for n in raw_idx])):
            rows[n][2] = t
    last = 0.0
    prev_para = -1
    for i, start, text, _raw in rows:
        _stamp, speaker, _text = paras[i]
        psecs, nparts = stamps[i]
        if i != prev_para or start is None:
            secs = psecs  # the paragraph's own stamp, as before
        else:
            secs = start if start >= last else last
        prev_para = i
        last = max(last, secs)
        # The stamp is a whole second; .01 puts a frame taken at exactly that
        # second ahead of the words, so the picture comes first.
        print("%010.2f\t**[%s] %s:** %s" % (int(secs) + 0.01, fmt_stamp(secs, nparts), speaker, text))


main()
