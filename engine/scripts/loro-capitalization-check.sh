#!/usr/bin/env bash
#
# loro-capitalization-check.sh — A BY-HAND TOOL. NOT A GUARD. NOT REGISTERED.
#
# ===========================================================================
# READ THIS BEFORE YOU "FIX" ANYTHING ABOUT THIS FILE
# ===========================================================================
# THIS IS DELIBERATELY NOT WIRED UP, BY CEO RULING, 2026-09-01. In his words:
#
#   "Actually using a guard just for that is probably overkill. The
#    capitalization of that word is not important enough to warrant a guard.
#    A 100% correct capitalization of that word is not necessary."
#
# So: no `hooks/hooks.json` entry, no `.claude/settings.local.json` entry, no
# probe layer, no sandbox file list, no orchestration.config switch, and the
# engine's guard count is untouched. It lives in `scripts/` rather than
# `scripts/hooks/` for exactly that reason, and its own checks live in
# `loro-capitalization-check.selftest.sh` rather than a `*.test.sh` so that
# `run-all-tests.sh` — which discovers suites from disk — does not pick it up
# and quietly make the engine depend on it.
#
# IF YOU FOUND THIS FILE AND THOUGHT "someone forgot to register this": nobody
# forgot. Registering it would reverse a ruling. Don't.
#
# It exists because the work existed. A one-time sweep on 2026-09-01 corrected
# 82 sites across richos-hq and richos, and this is the instrument that scored
# it. Run it by hand if a similar sweep ever comes round again. Nothing runs it
# for you, and nothing should.
#
# ===========================================================================
# WHAT IT CHECKS
# ===========================================================================
# `loro` is a GENERIC TERM, like `wiki`, for a living organizational memory. The
# CEO locked the name on 2026-08-23 and corrected its capitalization on
# 2026-09-01:
#
#   "When used as a generic term within a sentence like 'Add this to loro.' the
#    term loro should be spelled lowercase. But when used at the beginning of a
#    sentence or when it functions as a proper noun, it should be spelled as
#    'Loro' with an uppercase 'L'. The same applies when loro is within a
#    heading or title where each word is capitalized."
#
# THAT IS ORDINARY ENGLISH, not a house style. Canonical page with the decision
# table: `wiki/loro-concept.md` in the private richos-hq record.
#
# Three shapes, and which of them this tool is CONFIDENT about was decided by
# measurement rather than taste — scored site by site against that sweep, over
# 1,732 occurrences of the word. Full numbers: loro-capitalization.corpus.md.
#
#   HEADING   `# loro ...` — the word OPENS an ATX heading.
#             MEASURED 9 flagged, 9 correct, 0 false.  0.0% -> reported FIRM.
#
#   SENTENCE  `... . loro ...` — the word follows sentence-ending punctuation
#             on the same line, in prose.
#             MEASURED 29 flagged, 29 correct, 0 false.  0.0% -> reported FIRM.
#
#   LIST      `- loro ...`, `1. loro ...`, `| loro ...` — the word opens a
#             bullet, an ordered item or a table cell.
#             MEASURED 30 flagged, 12 correct, 18 false. 60.0% -> reported as
#             MAYBE, and it is genuinely a coin flip: sixteen of those false
#             positives are table cells quoting the literal string a mockup
#             renders, and two are lists whose every other item is also a
#             lowercase fragment. Capitalize one only if its siblings are.
#
# TWO SHAPES IT DOES NOT ATTEMPT AT ALL, said here rather than discovered:
#
#   TITLE-CASE HEADINGS. "The Loro Architecture" takes a capital; "## What loro
#   is" does not. Telling them apart needs a stop-word model AND the sibling
#   headings of the same file — `### 1.6 — loro structure` changes because every
#   other `### 1.n —` heading in that file capitalizes its first word, while
#   `## Defect 4 — loro had no writer` does NOT, because Defects 1 to 3 are
#   lowercase after the dash. No line-local rule gets that right.
#
#   PARAGRAPH STARTS ACROSS A LINE BREAK. 37 of 48 line-initial sites in the
#   record are mid-sentence wraps — the previous line ends "where the",
#   "another company's" — not new sentences.
#
# UNDER-FLAGGING IS THE POLICY, and the CEO's ruling makes it the right one
# twice over: 100% is explicitly not the target, and a wrong capital reads as a
# branding claim nobody has made. Where a use is ambiguous, lowercase is
# correct.
#
# ===========================================================================
# WHAT IT SKIPS, AND WHY THAT IS THE PRODUCT
# ===========================================================================
#   BY PATH   captured evidence by segment (raw/, cold-open/, transcripts/,
#             fixtures/, corpora/, snapshots/, logs/, node_modules/, vendor/,
#             third_party/), and a qualified last-hyphen component of the same
#             (licence-snapshots/); run output and generated data (*.log,
#             *.jsonl, *.lock, *.min.js, *.min.css, *.patch, *.diff, *.map,
#             *.sha256); its own three files.
#
#             *.txt is skipped too, AND THAT IS A STATED HOLE: in this record
#             prose is written in .md and the only .txt files carrying the word
#             are captured command output, which was the one measured false
#             positive the SENTENCE shape had. A .txt that really is prose is
#             not checked. The fix is to write prose in .md.
#
#   BY LINE   fenced code blocks; inline code spans; blockquotes INCLUDING one
#             behind a comment lead (`* > `, `// > `, `# > `) — loro/lib/
#             privacy.js quotes the architecture page that way and quoted
#             material is never ours to re-case; a line carrying
#             `loro-caps-exempt: <reason>`, where a bare marker with no reason
#             exempts nothing.
#
#   BY TOKEN  already-capital `Loro`/`LORO` — this tool only ever asks for a
#             capital, never for a lowercase, because the reverse judgment (is
#             this a proper noun?) is exactly the one it cannot make; paths and
#             identifiers (`/`, `\`, `_`, `$`, `::`, a dotted member path); ANY
#             hyphenated compound (`loro-context`, `loro-correction`,
#             `loro-vs-RAG`) because those are command names and labels;
#             abbreviations before the period (`e.g.`, `i.e.`, `cf.`);
#             ordered-list markers misread as sentence ends. And in a
#             NON-markdown file, only COMMENT lines count as prose — a code line
#             carrying a string literal is not a sentence.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scripts/loro-capitalization-check.sh <path>...    files and/or directories
#   scripts/loro-capitalization-check.sh --firm-only <path>...
#
#   --firm-only   report only the two 0%-false-positive shapes; drop the
#                 60% one. Useful on a big tree.
#
# EXIT CODES
#   0  no FIRM findings (MAYBE findings may still have been printed)
#   1  at least one FIRM finding
#   2  cannot run (no python3, no readable path)
#
# It reads. It never writes. There is deliberately no --fix: the whole lesson of
# the 2026-09-01 sweep is that these sites are judged one at a time, and a
# mechanical rewrite of them would be the sed this tool exists to replace.

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: loro-capitalization-check.sh: python3 is required" >&2; exit 2; }

FIRM_ONLY=0
PATHS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --firm-only) FIRM_ONLY=1 ;;
        -h|--help)
            sed -n '116,131p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: loro-capitalization-check.sh: unrecognized argument '$1'" >&2; exit 2 ;;
        *)  PATHS+=("$1") ;;
    esac
    shift
done
[ "${#PATHS[@]}" -gt 0 ] || { echo "ERROR: loro-capitalization-check.sh: no path given. Usage: $0 [--firm-only] <path>..." >&2; exit 2; }

FIRM_ONLY="$FIRM_ONLY" python3 - "${PATHS[@]}" <<'PY'
import os, re, sys

FIRM_ONLY = os.environ.get("FIRM_ONLY", "0") == "1"

WORD = r"[Ll][Oo][Rr][Oo]"
EMPH = r"(?:[*_~]{0,3})"
# What may sit between the period and the space, INCLUDING markdown emphasis:
# `9. **Push, not just pull.** loro feeds …` ends its sentence inside a bold
# run, and 8 of the measured true positives are on the far side of the `*`.
SENT_CLOSERS = r"[)\]\"'’”*_~]*"
SENTENCE_RE = re.compile(r"[.!?]" + SENT_CLOSERS + r"\s+" + EMPH + r"(" + WORD + r")\b")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+" + EMPH + r"(" + WORD + r")\b")
# `*` is NOT a bullet marker: `* loro ...` is the continuation line of a C-style
# block comment far more often than a markdown bullet. Measured — treating it as
# one produced 35 of 53 false positives.
LIST_RE = re.compile(r"^\s*(?:[-+]\s+|\d+[.)]\s+|\|\s*)" + EMPH + r"(" + WORD + r")\b")
ORDERED_LEAD_RE = re.compile(r"^[\s>*/#|-]*\d+[.)]\s+" + EMPH + r"$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
QUOTE_RE = re.compile(r"^\s*(?://+!?|\#+|\*|--|;+)?\s*>")
COMMENT_RE = re.compile(r"^\s*(?://+!?|\#|\*|--|;|<!--|/\*)")
DECLARED_EXEMPT_RE = re.compile(r"loro-caps-exempt:\s*[A-Za-z0-9]")
ABBREV = {"e.g.", "i.e.", "cf.", "vs.", "etc.", "no.", "fig.", "approx.",
          "al.", "esp.", "ca.", "resp.", "viz.", "cp.", "ibid."}
ABBREV_SHAPE = re.compile(r"(?:[A-Za-z]\.){2,}$")
TOKEN_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$./:\\-"

EVIDENCE_SEGMENTS = ("raw", "cold-open", "transcripts", "transcript",
                     "fixtures", "fixture", "corpora", "corpus", "snapshots",
                     "snapshot", "logs", "node_modules", "vendor",
                     "third_party", "third-party", "__pycache__", ".git",
                     ".worktrees")
EVIDENCE_EXTS = (".log", ".jsonl", ".lock", ".min.js", ".min.css", ".patch",
                 ".diff", ".map", ".sha256", ".txt")
OWN_FILES = ("loro-capitalization-check.sh", "loro-capitalization-check.selftest.sh",
             "loro-capitalization.corpus.md")
MARKDOWNISH = (".md", ".markdown", ".mdx")
READABLE = (".md", ".markdown", ".mdx", ".rs", ".js", ".mjs", ".cjs", ".ts",
            ".sh", ".bash", ".py", ".html", ".swift", ".cs", ".toml", ".css",
            ".svelte", ".kt", ".java", ".go", ".rb")


def path_skip_reason(path):
    base = os.path.basename(path)
    low_base = base.lower()
    low_path = path.lower().replace("\\", "/")
    if low_base in OWN_FILES:
        return "this tool's own implementation/selftest/corpus file"
    for ext in EVIDENCE_EXTS:
        if low_base.endswith(ext):
            return "generated/captured file type (%s)" % ext
    for seg in low_path.split("/"):
        if seg in EVIDENCE_SEGMENTS:
            return "captured evidence — path segment '%s/'" % seg
        if "-" in seg and seg.rsplit("-", 1)[1] in EVIDENCE_SEGMENTS:
            return "captured evidence — path segment '%s/'" % seg
    return ""


def enclosing_token(line, start, end):
    i = start
    while i > 0 and line[i - 1] in TOKEN_CHARS:
        i -= 1
    j = end
    while j < len(line) and line[j] in TOKEN_CHARS:
        j += 1
    return line[i:j]


def identifier_or_path(tok, word):
    if tok == word:
        return False
    if "/" in tok or "\\" in tok or "://" in tok:
        return True
    if "_" in tok or "$" in tok or "::" in tok:
        return True
    if re.search(r"\.[A-Za-z_]", tok):
        return True
    if "-" in tok:
        return True
    return False


def inside_inline_code(line, col):
    return line.count("`", 0, col) % 2 == 1


def scan(blob, is_markdown):
    """Yield (shape, line_no, line)."""
    in_fence = False
    for ln, line in enumerate(blob.split("\n"), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence or QUOTE_RE.match(line) or DECLARED_EXEMPT_RE.search(line):
            continue
        prose_line = is_markdown or bool(COMMENT_RE.match(line))
        seen = set()
        for shape, rx in (("HEADING", HEADING_RE), ("LIST", LIST_RE), ("SENTENCE", SENTENCE_RE)):
            for m in rx.finditer(line):
                col = m.start(1)
                if m.group(1)[0].isupper() or col in seen:
                    continue
                if inside_inline_code(line, col):
                    continue
                if identifier_or_path(enclosing_token(line, col, col + 4), m.group(1)):
                    continue
                if shape == "SENTENCE":
                    if not prose_line:
                        continue
                    pre = re.sub(r"[*_~]+$", "", line[:col].rstrip()).rstrip()
                    parts = pre.split()
                    prev_word = parts[-1] if parts else ""
                    if prev_word.lower() in ABBREV or ABBREV_SHAPE.search(prev_word):
                        continue
                    if ORDERED_LEAD_RE.match(line[:col]):
                        continue
                seen.add(col)
                yield (shape, ln, line)


def walk(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
            continue
        for dirpath, dirnames, filenames in os.walk(p):
            dirnames[:] = [d for d in dirnames if d not in EVIDENCE_SEGMENTS
                           and d not in ("target", "dist", "build", ".venv")]
            for fn in sorted(filenames):
                if fn.endswith(READABLE):
                    yield os.path.join(dirpath, fn)


firm = 0
maybe = 0
scanned = 0
for path in walk(sys.argv[1:]):
    if path_skip_reason(path):
        continue
    try:
        blob = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        continue
    if "oro" not in blob:
        continue
    scanned += 1
    is_md = os.path.basename(path).lower().endswith(MARKDOWNISH)
    for shape, ln, line in scan(blob, is_md):
        if shape == "LIST":
            if FIRM_ONLY:
                continue
            maybe += 1
            label = "MAYBE"
            why = "opens a list item or table cell — 60% false positive; capitalize only if the sibling items do"
        else:
            firm += 1
            label = "FIRM "
            why = ("opens a heading" if shape == "HEADING" else "starts a sentence")
        print("%s %s:%d  loro -> Loro  (%s)" % (label, path, ln, why))
        print("        %s" % line.strip()[:140])

print("")
print("scanned %d file(s) containing the word: %d FIRM, %d MAYBE" % (scanned, firm, maybe))
if firm == 0 and maybe == 0:
    print("Nothing to change. Remember: 100% correctness is explicitly NOT the target (CEO, 2026-09-01),")
    print("and where a use is ambiguous, lowercase is the right answer.")
sys.exit(1 if firm else 0)
PY
