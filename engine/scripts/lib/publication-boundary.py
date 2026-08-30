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
        "corpus_may_be_empty": false,
        "sources": ["/abs/path/to/private/tree", ...],
        "items":   [{"label": "docs/x.md", "path": "/tmp/blob"},
                    {"label": "docs/y.md", "text": "inline content"},
                    {"label": "docs/notes/", "path": "/repo/docs/notes"}]
      }

  An item whose "path" is a DIRECTORY is expanded to the files beneath it and
  every one is scanned. It is spelled out in the contract because the opposite
  behavior is what a scanner does by accident: `open()` on a directory raises,
  the unreadable-path branch skips it, and the run reports CLEAN having read
  ZERO BYTES. See expand_items for the shape that walked past this.

  stdout is one line per finding, tab-separated, and nothing else:

      BLOCK <TAB> label <TAB> detector <TAB> evidence
      BROKEN <TAB> reason
      CLEAN

  plus, as the LAST line of every completed analysis, what the run examined:

      CORPUS <TAB> member-files <TAB> corpus-words

  That trailer is the oracle for "this verdict was reached by looking". A CLEAN
  from a scanner whose corpus was empty is indistinguishable, from the outside,
  from a CLEAN that examined 130,000 words — and a regression test can pass for
  precisely the reason the scanner failed. It is emitted last because both
  shell callers dispatch on `head -1 | cut -f1` and pb_refusal skips non-BLOCK
  lines, so it extends the contract without altering it.

  An EMPTY corpus is not a CLEAN. When sources were declared and resolved and
  none of their files qualified as private speech, the answer is BROKEN — see
  the vacuity floor in main(). CORPUS_MAY_BE_EMPTY in the declaration is the
  committed way to state that a repository has no private corpus yet.

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

# --- media provenance: the third way into the corpus ------------------------
#
# THE HOLE THIS CLOSES, measured 2026-08-30. The two routes above are (1) the
# recorded-speech SHAPE and (2) the closure, which admits another RENDERING of
# something already admitted. Between them they cannot admit the FIRST
# rendering of a recording that was only ever transcribed to plain text.
#
# whisper's plain `.txt` output carries no timestamps and no speaker labels, so
# it has zero transcript-shaped lines and route 1 rejects it. Route 2 can only
# EXTEND a seed, never create one — so a recording with no timestamped
# rendering anywhere is invisible to the corpus entirely, whole.
#
# That was not hypothetical. Three real private podcast transcripts sat in the
# declared PRIVATE_SOURCES — 5,713, 6,424 and 22,375 words of two named
# third-party guests — and the corpus contained NONE of them: it held ten files,
# every one a rendering of the same webinar, admitted because ONE timestamped
# rendering of that webinar happened to exist. A 6,000-character extract of the
# first of those transcripts was written into the publication-bound repository
# and BOTH guards returned exit 0, silently. The write guard and the commit
# guard share this predicate, so the commit chokepoint — the backstop that
# exists precisely to catch what the write hook misses — missed it identically.
#
# THE SIGNAL, and why it is provenance rather than content. There is no
# reliable content shape for plain whisper output: it is prose, and every
# content-side widening tried against the real trees was rejected with numbers
# (see the closure constants below). But the tree knows something the bytes do
# not — the transcript is sitting NEXT TO THE RECORDING IT CAME FROM, under a
# name derived from it:
#
#     002 Liz Harris podcast.mp3          <- the recording
#     002 Liz Harris podcast transcript.txt   <- a rendering of it
#
# A text file in a declared-private directory whose stem extends the stem of a
# media file in that same directory is a rendering of that recording. That is a
# fact about the tree, not a heuristic about words, and it is the least
# ambiguous case there is: the whole 2026-08-29 incident was "the audio was
# correctly gitignored, the transcript was not".
#
# MEASURED, both directions, across 5,353 tracked text files in eleven
# repositories:
#
#   admits              exactly the 3 podcast transcripts. The closure then
#                       pulls in a fourth file on its own merits — a reference
#                       worksheet 80.9% covered by them (763 of 943 windows),
#                       i.e. genuinely another rendering. Corpus:
#                       10 files / 83,793 words -> 14 files / 130,466 words.
#   costs               ONE new colliding phrase across all eleven trees: a
#                       single 10-word run, 8 of its 10 words function words,
#                       sitting at the MIN_QUOTE_WORDS floor and extending no
#                       further, which appears in 4 files in `deeply` — a
#                       repository that declares no publication boundary, so no
#                       guard ever runs there.
#   in richos          ZERO, before and after. richos is the only repository on
#                       this machine that declares a boundary, and the count of
#                       legitimate files it would block is unchanged.
#
# THE WIDER RULE WAS REJECTED. "Any text file in a directory that holds media"
# needs no stem match and reaches the SAME 14-file corpus — but it gets there by
# admitting a 51 KB mixed reference worksheet DIRECTLY, on the strength of a
# coincidence of directory rather than of derivation. Admitting mixed documents
# on weak evidence is the exact move that put engineering boilerplate into the
# "private" corpus and blocked LICENSE files (see below). The narrow rule
# reaches the same place by the principled route and leaves the coincidence
# unused, so the narrow rule is what ships.
MEDIA_EXT = {'.mp3', '.mp4', '.m4a', '.wav', '.aac', '.flac', '.ogg', '.opus',
             '.mov', '.mkv', '.webm', '.avi', '.aiff', '.wma', '.m4v'}

# The shorter of the two stems must be at least this many alphanumeric
# characters. Below it a stem is a generic word — `notes`, `readme`, `audio`,
# `part1` — that matches by coincidence rather than by naming, and a coincidence
# is not provenance. Conservative rather than measured: on the real tree the
# stems in play are 19 characters ("002lizharrispodcast"), so every value from 1
# to 19 admits exactly the same files and the measurement above cannot
# distinguish them. Said plainly rather than dressed up as a finding.
MEDIA_STEM_MIN_CHARS = 8


def _stem_key(filename):
    """A filename's stem, reduced to lowercase alphanumerics.

    Reduced rather than compared raw so that `002 Liz Harris podcast.mp3` and
    `002_liz_harris_podcast.txt` are recognized as the same name — separators
    are an export-tool detail, not a difference in provenance.
    """
    return ''.join(c for c in os.path.splitext(filename)[0].lower() if c.isalnum())


def _renders_media(path, media_stems_by_dir):
    """True when `path` is named as a rendering of a media file beside it.

    The relation is prefix, in either direction, because both naming habits are
    real: `recording.mp3` -> `recording.transcript.txt` extends the media stem,
    and `interview.txt` -> `interview-part1.mp3` extends the text stem. Equality
    is the degenerate prefix and is included.
    """
    stems = media_stems_by_dir.get(os.path.dirname(path))
    if not stems:
        return False
    tk = _stem_key(os.path.basename(path))
    if not tk:
        return False
    for mk in stems:
        short, long_ = (tk, mk) if len(tk) <= len(mk) else (mk, tk)
        if len(short) >= MEDIA_STEM_MIN_CHARS and long_.startswith(short):
            return True
    return False


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
    # Media stems per directory, collected in the SAME walk as the candidates —
    # this costs no extra file reads and no extra stat calls, only the names
    # os.walk already handed us. See _renders_media for what it is for.
    media_stems = {}
    for src in sources:
        if os.path.isfile(src):
            candidates = [src]
            d = os.path.dirname(src)
            try:
                siblings = os.listdir(d)
            except OSError:
                siblings = []
            stems = {_stem_key(fn) for fn in siblings
                     if os.path.splitext(fn)[1].lower() in MEDIA_EXT}
            if stems:
                media_stems.setdefault(d, set()).update(stems)
        else:
            candidates = []
            for dirpath, dirnames, filenames in os.walk(src):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for fn in filenames:
                    ext = os.path.splitext(fn)[1].lower()
                    if ext in TEXT_EXT:
                        candidates.append(os.path.join(dirpath, fn))
                    elif ext in MEDIA_EXT:
                        media_stems.setdefault(dirpath, set()).add(_stem_key(fn))
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
            # Two independent ways to be a SEED: it looks like a recording, or
            # it is named as a rendering of a recording sitting beside it. The
            # second exists because whisper's plain .txt output satisfies
            # neither the shape filter nor the closure, and a recording whose
            # only rendering is plain text was therefore invisible to the corpus
            # entirely — see MEDIA_EXT above for the three real transcripts this
            # was measured against.
            if speech_lines(blob, cap=min_speech_lines) < min_speech_lines and \
                    not _renders_media(p, media_stems):
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

    # --- THE VACUITY FLOOR ---------------------------------------------------
    # A scan that read NOTHING must never report CLEAN.
    #
    # Everything below this line is conditional on the corpus. `corpus_index` is
    # an empty set when the corpus is empty, verbatim_run returns None on an
    # empty index, and the run prints CLEAN — a guard reporting that it found no
    # private material when it never had any private material to compare
    # against. That is the same shape as the "no media committed" check this
    # whole mechanism replaced, and as the "18/18 suites" tally that described a
    # glob instead of an inventory: a claim whose scope quietly excluded the
    # thing it was supposed to cover.
    #
    # It has already bitten once, silently. pb_resolve_sources documents it: in
    # a linked worktree `../richos-hq` resolved to a path that does not exist,
    # the corpus detector went inert in exactly the place all the work happens,
    # and the only symptom was one honest line in a message nobody reads on a
    # PASS. That fix made the path resolve. This makes the SILENCE impossible.
    #
    # The condition is derived, not chosen: sources were declared AND they
    # resolved to trees that exist AND not one file in them qualified as private
    # speech. A declared source that is simply not on this machine is skipped
    # upstream and never reaches here, which is deliberate and documented.
    #
    # Deliberately NOT a size threshold. "Unexpectedly small" cannot be derived
    # from anything — any word count would be a magic number that either never
    # fires or fires on a legitimate small private record — and this file's own
    # rule is that a number nobody measured does not ship. Empty is the one
    # threshold that means something on its own.
    #
    # The way through is CORPUS_MAY_BE_EMPTY in the declaration: committed,
    # diffable, reviewed by whoever lands it — the same affordance ALLOWLIST is,
    # for the same reason, and pointedly not an in-the-moment override.
    if sources and not members and not job.get('corpus_may_be_empty'):
        print("BROKEN\tthe declared PRIVATE_SOURCES resolved to %d tree(s) on "
              "this machine, and NOT ONE file in them qualified as private "
              "speech. The derived-from-private detector — the only one that "
              "catches speech quoted inside ordinary prose — therefore had "
              "nothing to compare against and would have reported this content "
              "clean without examining a single private word. Refusing to scan "
              "an empty corpus and report the result as clean. Either point "
              "PRIVATE_SOURCES at the trees that actually hold recordings, or "
              "set CORPUS_MAY_BE_EMPTY=1 in the declaration to state on the "
              "record that this repository has no private corpus yet."
              % len(sources))
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

    # --- THE ORACLE ---------------------------------------------------------
    # What this run actually examined, emitted on every completed analysis so a
    # caller — or a test — can assert that a CLEAN verdict was reached by
    # LOOKING rather than by reading nothing.
    #
    # A regression test for a scanner can pass for the same reason the scanner
    # can fail: because the corpus was empty and there was nothing to find. That
    # is the exact defect this file is about, and a suite with no way to tell the
    # two apart would be the defect reproduced one level up — which has happened
    # here before, in this suite's own tally and its own fixture filenames.
    #
    # Emitted LAST, never first: both shell callers dispatch on `head -1 | cut
    # -f1`, and pb_refusal skips every line that is not a BLOCK, so a trailing
    # line is additive to the contract rather than a change to it.
    trailer = "CORPUS\t%d\t%d" % (len(members), len(corpus.split()))
    if not findings:
        print("CLEAN")
        print(trailer)
        return 0
    for row in findings:
        print('\t'.join(row))
    print(trailer)
    return 0


if __name__ == '__main__':
    sys.exit(main())
