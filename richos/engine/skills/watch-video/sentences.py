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
    if not paras:
        return
    if words:
        # One stream in spoken order, never cut at a paragraph stamp. The speaker
        # label comes from the last paragraph stamped at or before the sentence's
        # first word (the first paragraph if none is).
        sents = split_sentences(words)
        texts = correct_all([" ".join(w for w, _ in sent) for sent in sents])
        rows = []
        for sent, text in zip(sents, texts):
            start = sent[0][1]
            i = 0
            for n, (psecs, _np) in enumerate(stamps):
                if psecs <= start:
                    i = n
            rows.append((start, paras[i][1], stamps[i][1], text))
    else:
        rows = [(float(stamps[i][0]), paras[i][1], stamps[i][1], paras[i][2])
                for i in range(len(paras))]
    for start, speaker, nparts, text in rows:
        # The key keeps the fractional second, so same-second sentences stay in
        # spoken order; .001 puts a frame taken at exactly that time ahead of the
        # words (frame keys have two decimals, so theirs sort first on a tie).
        print("%010.3f\t**[%s] %s:** %s" % (start + 0.001, fmt_stamp(start, nparts), speaker, text))


main()
