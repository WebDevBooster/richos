#!/usr/bin/env python3
"""sentences.py <transcript.md> [<me.json>] -- index rows for watch.sh.

Prints one row per line, "SSSSSSS.SS<TAB>**[MM:SS] Me:** text", sorted later by
watch.sh. Each transcript paragraph is split at sentence ends, and each sentence
is stamped with the time of its first word, taken from the whisper JSON's
per-word token times, so a frame sits beside the sentence it goes with and not
beside a 27-second paragraph. The paragraph's text is the corrected transcript;
the whisper words are used only for times, matched in order (a corrected word
that no longer matches is skipped, never invented). With no usable whisper JSON,
or a paragraph that cannot be matched, the paragraph stays one row at its own
time, which is the old behavior.
"""
import json
import re
import sys

PARA = re.compile(r"^\*\*\[([0-9:]+)\] ([^:]*):\*\* (.*)$")
SPLIT = re.compile(r"(?<=[.!?])[\"\u201d\u2019']?\s+(?=[\"'(\u201c\u2018]?[A-Z0-9])")


def norm(word):
    return re.sub(r"[^a-z0-9]", "", word.lower())


def whisper_words(path):
    """[(normalized word, start seconds)] from the token times."""
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
    return [(norm(w), s) for w, s in words if norm(w)]


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
    pos = 0
    last = 0.0
    with open(transcript) as f:
        lines = f.read().splitlines()
    for line in lines:
        m = PARA.match(line)
        if not m:
            continue
        stamp, speaker, text = m.groups()
        psecs, nparts = parse_stamp(stamp)
        # Skip whisper words before this paragraph (never go back past it).
        while pos < len(words) and words[pos][1] < psecs - 1.0:
            pos += 1
        sentences = SPLIT.split(text) if words else [text]
        first = True
        for sentence in sentences:
            start = None
            for w in sentence.split():
                nw = norm(w)
                if not nw:
                    continue
                for k in range(pos, min(pos + 8, len(words))):
                    if words[k][0] == nw:
                        if start is None:
                            start = words[k][1]
                        pos = k + 1  # align the whole sentence before the next one
                        break
                else:
                    # A corrected name ("Deep Graham" -> "Deepgram") has no single
                    # whisper word: consume the 1-3 original words it replaced, the
                    # run sharing the longest start with it (at least 3 letters).
                    best, best_j = 2, 0
                    for j in range(1, 4):
                        joined = "".join(x[0] for x in words[pos:pos + j])
                        n = 0
                        while n < min(len(joined), len(nw)) and joined[n] == nw[n]:
                            n += 1
                        if n > best:
                            best, best_j = n, j
                    pos += best_j
            if first:
                secs = psecs  # the paragraph's own stamp, as before
            elif start is not None and start >= last:
                secs = start
            else:
                secs = last
            first = False
            last = max(last, secs)
            # The stamp is a whole second; .01 puts a frame taken at exactly that
            # second ahead of the words, so the picture comes first.
            print("%010.2f\t**[%s] %s:** %s" % (int(secs) + 0.01, fmt_stamp(secs, nparts), speaker, sentence))


main()
