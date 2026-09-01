#!/usr/bin/env bash
#
# guard-loro-capitalization.sh — PreToolUse guard (Write|Edit|MultiEdit|NotebookEdit).
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# `loro` is a GENERIC TERM, like `wiki`, for a living organizational memory. The
# CEO locked the name on 2026-08-23 and CORRECTED ITS CAPITALIZATION on
# 2026-09-01, verbatim:
#
#   "When used as a generic term within a sentence like 'Add this to loro.' the
#    term loro should be spelled lowercase. But when used at the beginning of a
#    sentence or when it functions as a proper noun, it should be spelled as
#    'Loro' with an uppercase 'L'. The same applies when loro is within a
#    heading or title where each word is capitalized."
#
# THAT IS ORDINARY ENGLISH, NOT A HOUSE STYLE. And the reason it needs a guard
# is that it already failed once on attention. The 2026-08-23 entry read
# "lowercase in everyday use — capitalized only when naming the specific RichOS
# implementation". That carve-out never mentioned sentence starts or headings,
# so in practice the record went ALL-LOWERCASE, including at the start of
# sentences, which is a spelling error rather than a style. The CEO's words on
# finding it: "That's not what I meant."
#
# guard-dialect.sh exists for exactly this shape — a rule that a sweep cleans
# and nothing constrains afterwards decays on a measurable schedule. This is the
# same medicine for the same disease, and it is deliberately SMALLER, because
# capitalization is contextual in a way spelling is not.
#
# ===========================================================================
# WHAT IT CHECKS — AND WHAT IT REFUSES TO CHECK
# ===========================================================================
# Three shapes. WHICH ONE MAY BLOCK WAS DECIDED BY MEASUREMENT, NOT BY TASTE.
# Every one was scored against 1,322 + 410 occurrences of the word across the
# richos-hq and richos records, adjudicated site by site on 2026-09-01. The
# numbers are in scripts/hooks/loro-capitalization.corpus.md; the summary:
#
#   HEADING   `# loro ...` — the word OPENS an ATX heading.
#             MEASURED 9 flagged, 9 correct, 0 false.  0.0% -> BLOCKS.
#
#   SENTENCE  `... . loro ...` — the word follows sentence-ending punctuation
#             on the same line, in prose.
#             MEASURED 29 flagged, 29 correct, 0 false.  0.0% -> BLOCKS.
#
#   LIST      `- loro ...`, `1. loro ...`, `| loro ...` — the word opens a
#             bullet, an ordered item or a table cell.
#             MEASURED 30 flagged, 12 correct, 18 false. 60.0% -> REPORTS ONLY.
#
# THE 60% IS THE WHOLE ARGUMENT FOR NOT BLOCKING IT, and the false positives are
# not exotic. Sixteen are table cells quoting the literal string a mockup
# renders, inside a landed append-only design snapshot with screenshots beside
# it. Two are bullet lists whose every other item is also a lowercase fragment
# ("- files and URLs used", "- ECS objects referenced"), where capitalizing one
# word would be the inconsistency. A blocking guard with a false-positive class
# gets waived, and habitual waiving is how a defense decays into a formality.
# So this one reports, names the shape, and gets out of the way.
#
# THE TWO SHAPES IT DOES NOT ATTEMPT AT ALL, said here rather than discovered:
#
#   TITLE-CASE HEADINGS. "The Loro Architecture" takes a capital; "## What loro
#   is" does not. Telling them apart means deciding whether a heading is title
#   case, which needs a stop-word model and, in this record, the sibling
#   headings of the same file — `### 1.6 — loro structure` changes because every
#   other `### 1.n —` heading capitalizes its first word, while `## Defect 4 —
#   loro had no writer` does NOT, because Defects 1 through 3 are lowercase
#   after the dash. No line-local rule gets that right. Unflagged.
#
#   PARAGRAPH STARTS ACROSS A LINE BREAK. Roughly three quarters of the
#   line-initial sites in this record are mid-sentence wraps, not new sentences
#   — the previous line ends "where the", "another company's". The guard sees
#   the new content of ONE tool call, which may begin mid-paragraph, so it
#   cannot always read the previous line. Unflagged, deliberately: under-flagging
#   is the safe direction, because a wrong capital reads as a branding claim the
#   CEO has not made.
#
# UNDER-FLAGGING IS THE POLICY. This guard catches the shapes it can prove and
# says out loud that it catches nothing else.
#
# ===========================================================================
# THE EXEMPTIONS — THE SAME ONES THE SWEEP USED, FOR THE SAME REASONS
# ===========================================================================
#   PATH-LEVEL (whole write skipped)
#     * captured evidence by path segment: raw/, cold-open/, transcripts/,
#       transcript/, fixtures/, fixture/, corpora/, corpus/, snapshots/,
#       snapshot/, logs/, node_modules/, vendor/, third_party/, third-party/,
#       and a QUALIFIED last-hyphen component of the same (licence-snapshots/)
#     * run output and generated data: *.log, *.jsonl, *.lock, *.min.js,
#       *.min.css, *.patch, *.diff, *.map, *.sha256
#     * *.txt. NAMED AS A DELIBERATE HOLE RATHER THAN BURIED: in this record
#       prose is written in .md, and the only .txt files carrying the word are
#       captured command output under docs/verification/ — the one measured
#       false positive the SENTENCE shape had. A .txt file that really is prose
#       is therefore NOT checked. That is the cost, it is stated, and the fix
#       for it is to write prose in .md.
#     * THIS GUARD'S OWN THREE FILES. Self-serving on its face, so it is named
#       here and enumerated below rather than expressed as a pattern: a guard
#       about the word `loro` is made of the word `loro`, in every shape it
#       refuses, and one that cannot have its own corpus edited is one nobody
#       can maintain.
#     * anything matching LORO_CAPS_EXEMPT_PATHS in orchestration.config
#
#   CONTENT-LEVEL (per match)
#     * FENCED CODE BLOCKS (``` / ~~~), tracked across the new content
#     * INLINE CODE SPANS (odd number of backticks before the match)
#     * BLOCKQUOTE lines (^\s*>), INCLUDING behind a comment lead (`* > `,
#       `// > `, `# > `). loro/lib/privacy.js quotes wiki/loro-architecture.md
#       that way, and quoted material is never ours to re-case. Without the
#       comment-lead half this was a measured false positive.
#     * ALREADY CAPITAL. `Loro` and `LORO` are never touched — the guard only
#       ever asks for a capital, never for a lowercase, because the reverse
#       judgment (is this proper-noun use?) is exactly the one it cannot make.
#     * CODE IDENTIFIERS AND PATHS by the enclosing token: `/`, `\`, `_`, `$`,
#       `::`, a dotted member path — AND ANY HYPHEN. `loro-context`,
#       `loro-correction`, `loro-vs-RAG` are command names and compounds, never
#       a bare word opening a sentence. Measured: the hyphen rule alone removed
#       three false positives and cost nothing.
#     * IN A NON-MARKDOWN FILE, ONLY COMMENT LINES ARE PROSE. A code line with
#       a string literal in it is not a sentence. This is what keeps a test
#       fixture's page body (`['Pointer', 'A mirror is a POINTER ... . loro
#       indexes it']`) out of the SENTENCE shape.
#     * ABBREVIATIONS. `e.g. loro`, `i.e. loro`, `cf. loro` and anything of the
#       shape `a.b.` are not sentence ends.
#     * ORDERED-LIST MARKERS. `5. loro-CORRECTION` is a list item, not a
#       sentence; it falls to LIST, which only reports.
#     * a line carrying `loro-caps-exempt: <reason>` — a DECLARED exemption, in
#       the same discipline the contrast floor and the dialect guard use. The
#       reason must start with a word character; a bare marker exempts nothing.
#     * LORO_CAPS_ALLOWLIST in orchestration.config (space-separated literal
#       substrings), for an adopter's own known-safe strings.
#
# ===========================================================================
# JURISDICTION
# ===========================================================================
# Same model as guard-dialect.sh, and for the same reason: this is a POLICY
# RELATIVE TO A DECLARED VOCABULARY, not a universal defect.
#
#   * no `LORO_CAPS` in the governing orchestration.config -> SILENT stand-down.
#     A repository that does not have a loro has made no claim about the word,
#     and inventing one for it would be policy expansion.
#   * `LORO_CAPS` set to anything other than `on` -> silent stand-down too. The
#     switch has one meaning and no half-settings.
#   * repository never adopted the engine -> LOUD stand-down, same as every
#     other guard.
#
# A cross-repository write takes the target repository's own LORO_CAPS when that
# repository has adopted, and otherwise the SEAT's — the drift this exists to
# stop crossed repository lines (the same word went lowercase in richos-hq,
# richos and femcboost), so aiming the guard only at the seat would aim it away
# from half the cases.
#
# FAIL-CLOSED on a missing python3. FAILS OPEN (exit 0) on a malformed payload,
# matching its Write/Edit siblings' convention.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-loro-capitalization.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-loro-capitalization.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

# --- JURISDICTION ----------------------------------------------------------
# Deliberately BELOW the root-resolution bootstrap, never inside it: Layer R of
# contract-integrity-probe.sh extracts that block verbatim and asserts it is
# byte-identical across every rooted hook, so anything added inside it would
# read as divergence.
_SJ_LIB="$SCRIPT_DIR/../lib/seat-jurisdiction.sh"
if [ ! -f "$_SJ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-loro-capitalization.sh"
        echo "  scripts/lib/seat-jurisdiction.sh is missing at: $_SJ_LIB"
        echo "  Without it this guard cannot tell whether the artifact it was"
        echo "  handed belongs to the repository it governs, and a guard that"
        echo "  cannot tell must not answer."
    } >&2
    exit 2
fi
# shellcheck source=../lib/seat-jurisdiction.sh
. "$_SJ_LIB"

# Read the payload BEFORE resolving, so the payload's `cwd` is available as a
# resolution candidate. It is the only candidate a subagent session is
# guaranteed to carry.
INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    richos_announce_stand_down "scripts/hooks/guard-loro-capitalization.sh" \
        "this repository has not adopted the engine, so nothing written here is checked for loro capitalization"
    exit 0
else
    root_failure_banner "scripts/hooks/guard-loro-capitalization.sh" >&2
    exit 2
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${LORO_CAPS:=}"
: "${LORO_CAPS_ALLOWLIST:=}"
: "${LORO_CAPS_EXEMPT_PATHS:=}"

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}; print(ti.get("file_path") or ti.get("notebook_path") or "")' 2>/dev/null || true)"

# The declaration that governs THIS FILE, which is not necessarily the seat's —
# see the jurisdiction section.
LC_GOV=""
LC_GOV="$(richos_governing_root "$FILE_PATH" "${ENTITY_ROOT}" 2>/dev/null || true)"
# BOTH SIDES IN THE SAME SPELLING before the comparison — richos_governing_root
# answers physically, the seat arrives in whatever spelling the payload carried,
# and comparing the two raw makes the seat look foreign to itself.
LC_SEAT_PHYS="$(richos_physical "${ENTITY_ROOT:-}" 2>/dev/null || printf '%s' "${ENTITY_ROOT:-}")"
if [ -n "$LC_GOV" ] && [ "$LC_GOV" != "$LC_SEAT_PHYS" ]; then
    LORO_CAPS=""
    LORO_CAPS_ALLOWLIST=""
    LORO_CAPS_EXEMPT_PATHS=""
    # shellcheck disable=SC1090
    [ -f "$LC_GOV/orchestration.config" ] && . "$LC_GOV/orchestration.config"
    : "${LORO_CAPS:=}"
    : "${LORO_CAPS_ALLOWLIST:=}"
    : "${LORO_CAPS_EXEMPT_PATHS:=}"
fi

# NOTHING DECLARED, NOTHING ENFORCED — silently. A repository without a loro has
# made no claim about the word, and one switch with one meaning beats a set of
# half-settings nobody can remember.
[ "$LORO_CAPS" = "on" ] || exit 0

# --- JURISDICTION: ANNOUNCED, NEVER SILENT --------------------------------
# This guard does NOT decline an artifact outside its seat — the drift it exists
# to stop crossed repository lines — but it must not judge another repository's
# file without saying so. It sits here, BELOW every stand-down, for the reason
# guard-dialect.sh records: placed earlier it announces jurisdiction over a
# decision that was never going to be made, which is noise with a serious face.
richos_assert_jurisdiction "scripts/hooks/guard-loro-capitalization.sh" "$ENTITY_ROOT" "$FILE_PATH" "file" || true

export LORO_CAPS_ALLOWLIST LORO_CAPS_EXEMPT_PATHS

SCAN_PY="$(mktemp -t guard-loro-caps.XXXXXX.py)"
trap 'rm -f "$SCAN_PY"' EXIT
cat >"$SCAN_PY" <<'PY'
import json, os, re, sys

ALLOWLIST = [a for a in os.environ.get("LORO_CAPS_ALLOWLIST", "").split() if a]
EXTRA_EXEMPT_PATHS = [p for p in os.environ.get("LORO_CAPS_EXEMPT_PATHS", "").split() if p]

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("PARSEFAIL"); sys.exit(0)
if not isinstance(payload, dict):
    print("PARSEFAIL"); sys.exit(0)

tool_name = payload.get("tool_name", "")
ti = payload.get("tool_input", {})
if not isinstance(ti, dict):
    ti = {}
file_path = ti.get("file_path") or ti.get("notebook_path") or ""
if not isinstance(file_path, str):
    file_path = ""

# --- PATH-LEVEL EXEMPTIONS -------------------------------------------------
base = os.path.basename(file_path)
low_base = base.lower()
low_path = file_path.lower().replace("\\", "/")

EVIDENCE_SEGMENTS = ("raw", "cold-open", "transcripts", "transcript",
                     "fixtures", "fixture", "corpora", "corpus", "snapshots",
                     "snapshot", "logs", "node_modules", "vendor",
                     "third_party", "third-party", "__pycache__", ".git")
EVIDENCE_EXTS = (".log", ".jsonl", ".lock", ".min.js", ".min.css", ".patch",
                 ".diff", ".map", ".sha256", ".txt")
OWN_FILES = ("guard-loro-capitalization.sh", "guard-loro-capitalization.test.sh",
             "loro-capitalization.corpus.md")

MARKDOWNISH = (".md", ".markdown", ".mdx")


def path_exempt():
    if not file_path:
        return ""
    if low_base in OWN_FILES:
        return "this guard's own implementation/test/corpus file"
    for ext in EVIDENCE_EXTS:
        if low_base.endswith(ext):
            return "generated/captured file type (%s)" % ext
    for seg in low_path.split("/"):
        if seg in EVIDENCE_SEGMENTS:
            return "captured evidence — path segment '%s/'" % seg
        if "-" in seg and seg.rsplit("-", 1)[1] in EVIDENCE_SEGMENTS:
            return "captured evidence — path segment '%s/'" % seg
    for p in EXTRA_EXEMPT_PATHS:
        if p and p.lower() in low_path:
            return "LORO_CAPS_EXEMPT_PATHS entry '%s'" % p
    return ""


if path_exempt():
    print("CLEAN")
    sys.exit(0)

# A notebook cell is prose or markdown, never a bare source file: NotebookEdit
# hands over cell source, and treating `.ipynb` as code would silently exempt
# every markdown cell in it. Caught by case A4.
is_markdown = (tool_name == "NotebookEdit"
               or low_base.endswith(MARKDOWNISH)
               or "." not in low_base)

# --- THE NEW TEXT THIS CALL WOULD INTRODUCE --------------------------------
texts = []
if tool_name == "Write":
    texts.append(ti.get("content") or "")
elif tool_name == "Edit":
    texts.append(ti.get("new_string") or "")
elif tool_name == "MultiEdit":
    for e in (ti.get("edits") or []):
        if isinstance(e, dict):
            texts.append(e.get("new_string") or "")
elif tool_name == "NotebookEdit":
    texts.append(ti.get("new_source") or "")
blob = "\n".join(t for t in texts if isinstance(t, str))

if "oro" not in blob:
    print("CLEAN"); sys.exit(0)

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
# A blockquote, including one behind a comment lead: `* > `, `// > `, `# > `.
QUOTE_RE = re.compile(r"^\s*(?://+!?|\#+|\*|--|;+)?\s*>")
COMMENT_RE = re.compile(r"^\s*(?://+!?|\#|\*|--|;|<!--|/\*)")
DECLARED_EXEMPT_RE = re.compile(r"loro-caps-exempt:\s*[A-Za-z0-9]")
ABBREV = {"e.g.", "i.e.", "cf.", "vs.", "etc.", "no.", "fig.", "approx.",
          "al.", "esp.", "ca.", "resp.", "viz.", "cp.", "ibid."}
ABBREV_SHAPE = re.compile(r"(?:[A-Za-z]\.){2,}$")
TOKEN_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$./:\\-"


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
    # Any hyphen: `loro-context`, `loro-correction`, `loro-vs-RAG`. A label or a
    # command name, never a bare word opening a sentence.
    if "-" in tok:
        return True
    return False


def inside_inline_code(line, col):
    return line.count("`", 0, col) % 2 == 1


BLOCK = []    # (shape, line)
REPORT = []   # (shape, line)

in_fence = False
for line in blob.split("\n"):
    if FENCE_RE.match(line):
        in_fence = not in_fence
        continue
    if in_fence:
        continue
    if QUOTE_RE.match(line):
        continue
    if DECLARED_EXEMPT_RE.search(line):
        continue
    if any(a in line for a in ALLOWLIST):
        continue
    # In a source file, only a comment line is prose. A code line carrying a
    # string literal is not a sentence.
    prose_line = is_markdown or bool(COMMENT_RE.match(line))
    seen = set()
    for shape, rx in (("HEADING", HEADING_RE), ("LIST", LIST_RE), ("SENTENCE", SENTENCE_RE)):
        for m in rx.finditer(line):
            col = m.start(1)
            word = m.group(1)
            if word[0].isupper():
                continue
            if col in seen:
                continue
            if inside_inline_code(line, col):
                continue
            if identifier_or_path(enclosing_token(line, col, col + 4), word):
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
            site = line.strip()[:110]
            if shape == "LIST":
                REPORT.append((shape, site))
            else:
                BLOCK.append((shape, site))

if BLOCK:
    print("FOUND")
    for shape, site in BLOCK:
        print("BLOCK\t%s\t%s" % (shape, site))
    for shape, site in REPORT:
        print("REPORT\t%s\t%s" % (shape, site))
elif REPORT:
    print("REPORTONLY")
    for shape, site in REPORT:
        print("REPORT\t%s\t%s" % (shape, site))
else:
    print("CLEAN")
PY

RESULT="$(printf '%s' "$INPUT" | python3 "$SCAN_PY" 2>/dev/null || printf 'PARSEFAIL')"

case "$(printf '%s' "$RESULT" | head -1)" in
  CLEAN|PARSEFAIL)
    exit 0
    ;;
  REPORTONLY)
    {
      echo "=== loro capitalization NOTE (not blocked) ==="
      echo "  '${FILE_PATH:-<unknown file>}' opens a list item or a table cell with 'loro'."
      echo "  MEASURED 60% false positive on this shape (30 flagged, 12 correct), so it is"
      echo "  reported and never blocked: a table cell quoting a rendered UI string, and a"
      echo "  list whose every other item is a lowercase fragment, both look identical to a"
      echo "  real one from a single line. Capitalize it only if the sibling items do:"
      printf '%s\n' "$RESULT" | tail -n +2 | while IFS=$'\t' read -r kind shape site; do
        [ "$kind" = "REPORT" ] && echo "    ? $shape   — $site"
      done
      echo "(hook: scripts/hooks/guard-loro-capitalization.sh)"
    } >&2
    exit 0
    ;;
  FOUND)
    {
      echo "=== loro capitalization BLOCKED ==="
      echo "  Refusing to write '${FILE_PATH:-<unknown file>}' — 'loro' is a generic term like"
      echo "  'wiki' and takes ORDINARY ENGLISH CAPITALIZATION (CEO, 2026-09-01). It is"
      echo "  lowercase mid-sentence and capitalized where any other word would be:"
      printf '%s\n' "$RESULT" | tail -n +2 | while IFS=$'\t' read -r kind shape site; do
        if [ "$kind" = "BLOCK" ]; then
          case "$shape" in
            HEADING)  echo "    - loro -> Loro   (opens a heading)" ;;
            SENTENCE) echo "    - loro -> Loro   (starts a sentence)" ;;
            *)        echo "    - loro -> Loro   ($shape)" ;;
          esac
          echo "        $site"
        else
          echo "    ? $shape (reported, not the reason for this block)"
          echo "        $site"
        fi
      done
      echo ""
      echo "  Both shapes measured 0% false positive over 1,732 occurrences of the word."
      echo "  If this site really is an exception, say so where a reviewer sees it:"
      echo "  put 'loro-caps-exempt: <reason>' on the line. A bare marker exempts nothing."
      echo "  Rule: wiki/loro-concept.md. (hook: scripts/hooks/guard-loro-capitalization.sh)"
    } >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
