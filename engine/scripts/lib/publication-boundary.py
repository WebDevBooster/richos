#!/usr/bin/env python3
"""publication-boundary.py — the content half of the publication-boundary guard.

Why this is a separate file rather than a heredoc inside the shell library:
scan-secrets.sh embeds its scanner because exactly one hook uses it. This
predicate is shared by TWO hooks — the write-time guard and the commit-time
guard — and a predicate that exists in two copies is the defect this whole
mechanism was built to stop. One implementation, two callers.

Contract with the caller (scripts/lib/publication-boundary.sh):

  argv[1] is a JSON job file:

      {
        "min_speech_lines": 8,
        "min_quote_words": 8,
        "corpus_max_files": 4000,
        "corpus_max_bytes": 67108864,
        "items_max_files": 5000,
        "sources": ["/abs/path/to/private/tree", ...],
        "items":   [{"label": "docs/x.md", "path": "/tmp/blob"},
                    {"label": "docs/y.md", "text": "inline content"},
                    {"label": "docs/notes/", "path": "/repo/docs/notes"}]
      }

  An item whose "path" is a DIRECTORY is expanded to the files beneath it and
  every one is scanned. It is spelled out in the contract because the opposite
  behaviour is what a scanner does by accident: `open()` on a directory raises,
  the unreadable-path branch skips it, and the run reports CLEAN having read
  ZERO BYTES. See expand_items for the shape that walked past this.

  stdout is one line per finding, tab-separated, and nothing else:

      BLOCK <TAB> label <TAB> detector <TAB> evidence
      BROKEN <TAB> reason
      CLEAN

  Any other output shape is a contract violation the caller treats as
  fail-closed. Exit status is 0 for a completed analysis (clean or blocking),
  2 for BROKEN — but the caller reads the LINES, not the status, because a
  scanner that says CLEAN on stdout and 2 on exit is ambiguous and ambiguity
  here is what gets content published.
"""

import json
import os
import re
import sys

# --- the recorded-speech shape ---------------------------------------------
#
# Three real-world transcript layouts. Between them they cover whisper/
# whisper-cli output, SRT/WebVTT captions, and the Otter/Zoom/Descript
# "Name (0:12):" export style.
#
# The near-miss these are built against is a LOG line — `[12:34:56] ERROR:
# connection refused` matches the timestamp+colon skeleton exactly. Two
# independent filters separate them: a denylist of log-level and log-field
# tokens in the speaker slot, and a prose test on the text that requires real
# words and rejects dense code punctuation. Measured across 57,034 files in
# eleven repositories: 17 flagged, all 17 genuine transcripts, zero
# non-transcript false positives.

"""
A note on the leading class, because it was measured and then narrowed.

It began as `[\\s>*-]*` — leading whitespace, blockquote markers, and markdown
list bullets. The bullet was the mistake. A CHANGELOG line

    - 12:03 Dana: rewrote the loader so it no longer reads the whole file

is a list item, not speech, and eight of them tripped the detector. So `*` and
`-` are gone and only `>` survives: a transcript pasted into a blockquote is a
real shape, a transcript pasted as a bullet list is not one anybody produces.
The cost is stated rather than hidden — a quote inside a markdown LIST is now
invisible to this detector — and it is covered by the corpus detector, which
does not care about line shape at all.
"""

TS_SPEAKER = re.compile(
    r'^[\s>]*'
    r'[\[\(]?\s*(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?\s*[\]\)]?'
    r'\s*[-–—]?\s*'
    r'(?P<who>[A-Za-z][A-Za-z0-9_.\'’-]{0,24}'
    r'(?:\s+[A-Za-z][A-Za-z0-9_.\'’-]{0,24}){0,2})'
    r'\s*:\s*'
    r'(?P<text>\S.*)$'
)

PAREN_SPEAKER = re.compile(
    r'^[\s>]*'
    r'(?P<who>[A-Z][A-Za-z0-9_.\'’-]{0,24}'
    r'(?:\s+[A-Z][A-Za-z0-9_.\'’-]{0,24}){0,2})'
    r'\s*[\[\(]\s*(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?\s*[\]\)]\s*:\s*'
    r'(?P<text>\S.*)$'
)

CUE = re.compile(
    r'^\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}'
)

# Tokens that occupy the speaker slot in machine output, never in a transcript.
LOGISH = set("""
info warn warning error debug trace fatal notice verbose log stdout stderr
ok pass fail failed todo note out in get post put patch delete http https
usage example tip exit rc pid cmd run step time took elapsed duration
""".split())

# Punctuation that appears in code and configuration and effectively never in
# a spoken sentence.
CODEY = set('{}<>=;|&$#`\\')


def _is_prose(text):
    if len(text.split()) < 4:
        return False
    if sum(text.count(c) for c in CODEY) > 2:
        return False
    return True


def speech_lines(blob, cap=None):
    """Count transcript-shaped lines. Stops early once `cap` is reached, so a
    92-minute transcript costs the same as an eight-line one."""
    n = 0
    for line in blob.splitlines():
        if CUE.match(line):
            n += 1
        else:
            m = TS_SPEAKER.match(line) or PAREN_SPEAKER.match(line)
            if not m:
                continue
            if m.group('who').strip().lower() in LOGISH:
                continue
            if not _is_prose(m.group('text')):
                continue
            n += 1
        if cap is not None and n >= cap:
            return n
    return n


# --- the derived-from-private corpus ---------------------------------------

WORD = re.compile(r"[a-z0-9]+")

TEXT_EXT = {
    '.md', '.txt', '.json', '.jsonl', '.vtt', '.srt', '.csv', '.log', '.tsv',
    '.rst', '.text', '',
}

SKIP_DIRS = {'.git', 'node_modules', '.venv', 'venv', 'dist', 'build',
             '__pycache__', '.next', 'target', 'Pods', '.gradle'}


def normalise(text):
    """Lowercase, drop apostrophes, keep only alphanumeric word tokens.

    Matching on this form is what lets a quote survive re-punctuation: prose
    that wrote `"we shouldn't ship it like that"` and a transcript that has
    `we shouldnt ship it like that` both normalise to the same token run.

    The illustration is invented on purpose. An earlier draft used a real
    phrase from the incident that prompted this guard — which put a sample of
    the material inside the thing built to keep it out."""
    return WORD.findall(text.lower().replace('’', '').replace("'", ''))


class BrokenCorpus(Exception):
    pass


# --- the derived-rendering closure -----------------------------------------
#
# WHY THE SHAPE FILTER ALONE IS NOT THE CORPUS.
#
# Measured on the real private record on 2026-08-30: 481 candidate text files
# under the declared PRIVATE_SOURCES, and the shape filter kept TWO. The
# verbatim-quote detector — the half that catches speech quoted inside ordinary
# prose, which is how 28 quotes reached the public tree on 2026-08-29 — was
# matching against 26,339 words, one recording, while the same private tree
# held SEVEN MORE two-channel transcripts of the CEO's real recordings that the
# shape filter cannot see: whisper `.txt` output carries no timestamps and no
# speaker labels, so it has zero transcript-shaped lines. 3,764 to 13,880 words
# of private speech each, invisible.
#
# THE RULE. A private file joins the corpus when it is ANOTHER RENDERING of
# speech already in the corpus — not when it merely quotes it. Two conditions,
# both required, because each alone fails in a direction that was measured:
#
#   CLOSURE_MIN_WINDOWS    at least this many DISTINCT non-overlapping
#                          min_quote_words-windows of the file appear in the
#                          corpus. Absolute, so a document that quotes one
#                          sentence cannot join; distinct, so a file that repeats
#                          the same quoted line — which is exactly what a
#                          transcript with a hallucination loop looks like —
#                          cannot accumulate its way in on one phrase.
#   CLOSURE_MIN_COVERAGE   and that many as a FRACTION of the file's own
#                          windows. Scale-free, so a large document cannot
#                          accumulate its way in on boilerplate either.
#
# NON-OVERLAPPING is a cost decision, stated because it is a real approximation.
# Hashing every position of every candidate is 10x the work and measured at
# +0.8s on every single Write, Edit and commit in the repository — a guard that
# taxes every keystroke is a guard someone turns off, which is the same failure
# as one that blocks ordinary work. Every tenth position is an unbiased estimate
# of the same ratio, it is deterministic rather than sampled, and it left the
# admitted set and the margins where they were.
#
# MEASURED, not chosen. Against the real private record:
#
#   admitted (8 files)   73 - 269 shared windows, 25% - 45% coverage. Every one
#                        a genuine transcript of a real recording: two channels
#                        x two recordings x two model runs.
#   nearest EXCLUDED     14 windows / 2.8% coverage — an engineering brief that
#                        QUOTES the transcript. 2.9x below the gate; the lowest
#                        admission is 1.8x above it, and has to clear the
#                        coverage condition as well.
#
# and the reason that margin matters is the direction this fails in. An earlier
# draft admitted any file sharing ONE 10-word run. That pulled 251 private
# engineering documents into the "private" corpus, whose ordinary boilerplate
# then blocked 206 of 5,333 files across the real public trees — including
# LICENSE files, .gitignore and package.json. Admitting one mixed brief is
# enough to do damage: at a 40-word inbound threshold the corpus took in a
# single brief and its header line ("...requested by Rich on behalf of the
# CEO") and a scratchpad PATH promptly blocked five legitimate public files,
# one of them the technology evaluation .publication-boundary names as
# deliberately public. Under the rule above, both of those documents are
# excluded and the false-positive count across those same 5,333 public files is
# ZERO — unchanged from the narrow corpus.
#
# WHAT WAS REJECTED, with its numbers, so nobody re-proposes it as an
# improvement: harvesting every quoted prose run out of every private file
# (1,339 runs) raises recall on the one shape this cannot see — the CEO's typed
# words in a private wiki page, quoted nowhere else — and blocks 98 public
# files, 23 of them in the publication-bound repository itself, including its
# README, its WALKTHROUGH and two agent definitions. Doctrine sentences live in
# both trees on purpose. That widening is not available at any threshold and
# the gap it leaves is stated in the header of publication-boundary.sh.
CLOSURE_MIN_WINDOWS = 40
CLOSURE_MIN_COVERAGE = 0.08
# Rounds, not one pass: on the real tree a fourth transcript only crossed the
# gate once the three renderings of ITS recording were themselves in the corpus
# (round 2). The cap is a bound on work, and it is never a silent truncation —
# the loop stops when a round admits nothing, which is what happened at round 3.
CLOSURE_MAX_ROUNDS = 3


def _gram_hashes(words, n, stride=1):
    """The n-word windows of `words`, as a set of hashes.

    stride=1 for the corpus side, where every position must be present or a
    genuine reproduction could slip between two windows. stride=n for the
    candidate side, where the question is a RATIO and every tenth window
    estimates it at a tenth of the cost.

    Same fast-path-not-verdict discipline as index_corpus: a collision here can
    only over-count a file's overlap by one window out of dozens, and admission
    needs CLOSURE_MIN_WINDOWS of them and a coverage fraction besides.
    """
    return {hash(tuple(words[i:i + n])) for i in range(0, len(words) - n + 1, stride)}


def build_corpus(sources, min_speech_lines, max_files, max_bytes,
                 min_quote_words=10):
    """Walk the declared private trees and keep the files that ARE private
    speech: the ones that look like a recording, plus the ones that are another
    rendering of a recording already kept.

    This is the composition that buys the precision. The operator declares
    WHERE private material lives — a fact only they know. The machine works out
    WHICH files it is — a fact it can check. A dated list of transcript paths
    would be stale by the next recording; this cannot be. And because a file
    enters only by looking like speech or by REPRODUCING speech already in the
    corpus, a boilerplate sentence shared between two ordinary engineering
    documents can never collide with it — see the closure constants above for
    the measurement that pins that claim.

    Hitting a bound is BROKEN, never a quiet truncation: a corpus that silently
    stopped short would let the guard pass content it simply never looked at,
    which is the original "no media committed" failure wearing a different hat.
    """
    parts = []
    members = []
    # Non-member candidates, kept as gram hashes only. A file is a possible
    # rendering only if it is long enough to reach CLOSURE_MIN_RUNS at all, so
    # the eligibility test is arithmetic rather than a guess, and short files
    # cost nothing.
    pending = {}
    files = 0
    total = 0
    for src in sources:
        if os.path.isfile(src):
            candidates = [src]
        else:
            candidates = []
            for dirpath, dirnames, filenames in os.walk(src):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for fn in filenames:
                    if os.path.splitext(fn)[1].lower() in TEXT_EXT:
                        candidates.append(os.path.join(dirpath, fn))
        for p in candidates:
            files += 1
            if files > max_files:
                raise BrokenCorpus(
                    "the declared PRIVATE_SOURCES contain more than "
                    "CORPUS_MAX_FILES=%d candidate text files. Narrow "
                    "PRIVATE_SOURCES to the trees that actually hold recordings, "
                    "or raise CORPUS_MAX_FILES deliberately. Refusing to scan a "
                    "truncated corpus and report the result as clean." % max_files)
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            if size > 8_000_000:
                continue
            total += size
            if total > max_bytes:
                raise BrokenCorpus(
                    "the declared PRIVATE_SOURCES exceed CORPUS_MAX_BYTES=%d. "
                    "Narrow PRIVATE_SOURCES, or raise the bound deliberately. "
                    "Refusing to scan a truncated corpus and report the result "
                    "as clean." % max_bytes)
            try:
                with open(p, encoding='utf-8', errors='ignore') as fh:
                    blob = fh.read(8_000_000)
            except OSError:
                continue
            if speech_lines(blob, cap=min_speech_lines) < min_speech_lines:
                words = normalise(blob)
                # Arithmetic, not a guess: below this length the file cannot
                # reach CLOSURE_MIN_WINDOWS non-overlapping windows even if
                # every one of them matched, so it never needs hashing.
                if len(words) >= (CLOSURE_MIN_WINDOWS + 1) * min_quote_words:
                    pending[p] = _gram_hashes(words, min_quote_words,
                                              stride=min_quote_words)
                continue
            members.append(p)
            parts.append(' '.join(normalise(blob)))

    # --- the closure ------------------------------------------------------
    # Nothing to be derived FROM means nothing to derive: with no shape-detected
    # speech the corpus stays empty rather than bootstrapping itself out of
    # ordinary documents.
    if parts and pending:
        index = set()
        for part in parts:
            index |= _gram_hashes(part.split(), min_quote_words)
        for _round in range(CLOSURE_MAX_ROUNDS):
            admitted = []
            for p, grams in pending.items():
                if not grams:
                    continue
                shared = len(grams & index)
                if shared >= CLOSURE_MIN_WINDOWS and \
                        shared / len(grams) >= CLOSURE_MIN_COVERAGE:
                    admitted.append(p)
            if not admitted:
                break
            for p in admitted:
                index |= pending.pop(p)
                # Re-read rather than cache every candidate's word list: the
                # admitted set is a handful of files and the blob is in the OS
                # cache, while holding the tokens of every candidate would put
                # the whole private tree in memory for the 99% of runs that
                # admit nothing.
                try:
                    with open(p, encoding='utf-8', errors='ignore') as fh:
                        blob = fh.read(8_000_000)
                except OSError:
                    continue
                members.append(p)
                parts.append(' '.join(normalise(blob)))

    # The double space is a barrier token: it stops a run from being matched
    # across the seam between two unrelated transcripts.
    return '  '.join(parts), members


# --- items: what the caller asked to be scanned ----------------------------

def expand_items(items, max_files):
    """Resolve every job item to something with BYTES behind it.

    THE WALK-PAST THIS EXISTS TO CLOSE. `git status --porcelain` reports a
    wholly-new directory as ONE entry — `?? docs/session-notes/` — and a caller
    that passes that entry through hands this scanner a DIRECTORY. `open()` on a
    directory raises IsADirectoryError, the unreadable-path branch in main()
    treats it exactly like a deleted or binary file, and the scan reports CLEAN
    having examined zero bytes. Every leak on 2026-08-29 was a file inside a
    directory; a new directory of transcripts arriving in one go would have been
    waved through by a guard reporting, on its own terms, the truth.

    So a directory item is EXPANDED here, once, for every caller — the write
    guard, the commit guard, and any by-hand run over a diff.

    Binary files are skipped by a NUL test rather than by extension: an image or
    an audio file carries no reproducible speech TEXT, and media was already
    covered by the check this mechanism replaced. Oversized files are read up to
    the same 8 MB bound the corpus uses.

    Exceeding max_files is BROKEN, never a quiet truncation — half a directory
    scanned and reported clean is the defect this whole file exists to end.
    """
    out = []
    seen = 0
    for item in items:
        path = item.get('path')
        if not path or not os.path.isdir(path):
            out.append(item)
            seen += 1
            if seen > max_files:
                raise BrokenCorpus(
                    "the scan job names more than ITEMS_MAX_FILES=%d files. "
                    "Refusing to scan part of it and report the result as "
                    "clean." % max_files)
            continue
        label = item.get('label') or path
        base = label.rstrip('/')
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in sorted(filenames):
                fp = os.path.join(dirpath, fn)
                if os.path.islink(fp):
                    # A symlink's target is scanned in its own right if it is
                    # inside the scanned set, and following it here would let one
                    # directory item wander out of the tree it names.
                    continue
                try:
                    with open(fp, 'rb') as fh:
                        head = fh.read(8192)
                except OSError:
                    continue
                if b'\0' in head:
                    continue
                seen += 1
                if seen > max_files:
                    raise BrokenCorpus(
                        "expanding the directory items in this scan job passed "
                        "ITEMS_MAX_FILES=%d files. Refusing to scan part of a "
                        "directory and report the result as clean." % max_files)
                rel = os.path.relpath(fp, path)
                out.append({'label': '%s/%s' % (base, rel), 'path': fp})
    return out


def index_corpus(corpus, n):
    """Hash every n-word window of the corpus once.

    Substring-searching the corpus for every window of the incoming content is
    O(content x corpus) and goes quadratic on a large file — a guard that times
    out is a guard that did not run. Hashing the corpus once turns the scan into
    one set lookup per word.

    The hash is a FAST PATH, never the verdict: a hit is re-verified against the
    corpus text below, so a hash collision can produce a wasted comparison and
    never a wrong block. Precision is the contract; a probabilistic accusation
    would not honour it."""
    words = normalise(corpus)
    return {hash(tuple(words[i:i + n])) for i in range(0, len(words) - n + 1)}


def verbatim_run(content, corpus, index, n):
    """First run of >= n consecutive words reproduced verbatim from the corpus.

    Short-circuits on the first hit, then extends it only far enough to report
    honest evidence — the author needs to know WHAT was reproduced, not every
    place it appears."""
    if not corpus or not index:
        return None
    words = normalise(content)
    for i in range(0, len(words) - n + 1):
        window = tuple(words[i:i + n])
        if hash(window) not in index:
            continue
        cand = ' '.join(window)
        if cand not in corpus:      # collision — not a match, keep going
            continue
        j = i + n
        # Bounded extension: enough evidence to be convincing, never a re-scan.
        while j < len(words) and (j - i) < 40 and ' '.join(words[i:j + 1]) in corpus:
            j += 1
        return words[i:j]
    return None


def main():
    try:
        with open(sys.argv[1], encoding='utf-8') as fh:
            job = json.load(fh)
    except Exception as exc:  # noqa: BLE001 — any failure here is fail-closed
        print("BROKEN\tcould not read the scan job: %s" % exc)
        return 2

    min_speech = int(job.get('min_speech_lines', 8))
    min_quote = int(job.get('min_quote_words', 10))
    sources = [s for s in job.get('sources', []) if s]
    items = job.get('items', [])

    try:
        items = expand_items(items, int(job.get('items_max_files', 5000)))
    except BrokenCorpus as exc:
        print("BROKEN\t%s" % exc)
        return 2

    try:
        corpus, members = build_corpus(
            sources, min_speech,
            int(job.get('corpus_max_files', 4000)),
            int(job.get('corpus_max_bytes', 67108864)),
            min_quote,
        )
    except BrokenCorpus as exc:
        print("BROKEN\t%s" % exc)
        return 2

    corpus_index = index_corpus(corpus, min_quote) if corpus else set()

    findings = []
    for item in items:
        label = item.get('label') or item.get('path') or '<unknown>'
        if 'text' in item:
            blob = item['text'] or ''
        else:
            try:
                with open(item['path'], encoding='utf-8', errors='ignore') as fh:
                    blob = fh.read(8_000_000)
            except Exception:
                # A blob that cannot be read cannot be cleared either, but an
                # unreadable path is far more likely a binary/deleted file than
                # a smuggled transcript, and blocking on it would make the guard
                # fire on ordinary work. It is reported, not blocked.
                continue

        # Detector 1 — derived from private. The sharpest signal: no heuristic,
        # no threshold on shape, just "these exact words are already in a file
        # we declared private".
        run = verbatim_run(blob, corpus, corpus_index, min_quote)
        if run:
            findings.append((
                'BLOCK', label, 'derived-from-private',
                '%d words reproduced verbatim: "%s"' % (len(run), ' '.join(run)[:160]),
            ))
            continue

        # Detector 2 — the shape of a recording, for material with no declared
        # corpus to match against.
        n = speech_lines(blob, cap=min_speech)
        if n >= min_speech:
            findings.append((
                'BLOCK', label, 'recorded-speech',
                '%d+ timestamped speaker lines / caption cues' % n,
            ))

    if not findings:
        print("CLEAN")
        return 0
    for row in findings:
        print('\t'.join(row))
    return 0


if __name__ == '__main__':
    sys.exit(main())
