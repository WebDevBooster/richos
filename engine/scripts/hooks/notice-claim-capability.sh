#!/usr/bin/env bash
#
# notice-claim-capability.sh — PostToolUse. THE CLAIM-CAPABILITY CHECK, DELIVERED WHERE IT
#                              ACTUALLY FIRES: the moment a RECORD is written.
#
# ===========================================================================================
# WHY THIS EXISTS — the check was built and pointed at the wrong surface
# ===========================================================================================
# `scripts/brief-provenance.py` grew a fourth check on 2026-09-14 (record:
# docs/verification/claim-capability-2026-09-14.md). It reads a sentence that DOES cite a
# source and states what that source is capable of establishing — a state measurement answers
# what IS; it never answers who did it, when, whether it was allowed, or which of several
# candidates it was.
#
# It was wired into the spawn path, because that is where `brief-provenance.py` already ran.
# Its author measured the result and reported it rather than burying it:
#
#     23 spawn payloads -> 1 row, and that row is a false positive.
#     63 landed records -> 37 rows.
#
# NOT ONE of the four real instances of the failure happened in a brief. Two were in landed
# `docs/verification/` records, one in a memory note, one typed to the CEO in chat. So the
# check sat on a surface where type Y does not happen.
#
# This hook is the delivery surface, and NOTHING ELSE. It reuses
# `brief-provenance.py`'s predicate by importing it; there is no second copy of the rules
# here, and none of them is re-tuned. A hook-shaped reimplementation beside the real one is
# the defect class this engine keeps finding in itself.
#
# ===========================================================================================
# THE CONSTRAINT THIS WAS BUILT UNDER, AND THE MEASUREMENT THAT ANSWERS IT
# ===========================================================================================
# The brief was explicit: this session has repeatedly produced mechanisms nobody reads, and
# "if your own measurement says this becomes wallpaper, say so and do not ship it."
#
# Replayed against every write event recorded in the 753 session transcripts under
# `~/.claude/projects/`, restricted to the surfaces below:
#
#     466 write events on record paths
#     418 of them (90%) touch a file with ZERO capability rows -> the hook is SILENT
#      89 rows over the whole recorded history of this machine = 0.19 rows per write event
#
# Eighty-nine lines across two months is not wallpaper; the honest risk runs the other way —
# it may be too RARE to build a habit around. That is stated in the record rather than
# guessed at here.
#
# ===========================================================================================
# THE THREE DESIGN DECISIONS THAT KEEP IT OFF THE WALL, each forced by a measurement
# ===========================================================================================
# 1. CHECK 4 ONLY. Running the whole of `brief-provenance.py` on a record emits 1633 rows
#    over 64 records — 25.5 per record from checks 1-3. Delivering "the provenance report" on
#    a record write would bury the eight true capability rows under sixteen hundred others.
#    So `check_capability` is called directly. Verified on the six largest documents in the
#    corpus: the row sets from `review()`-filtered and `check_capability()` are identical,
#    and the direct call is 2-4x faster (0.03s on a 160 KB page).
#
# 2. ONLY SENTENCES THIS CALL ACTUALLY WROTE. The hook re-scans the WHOLE file, so a
#    document with N rows edited K times would cost N*K rows. Measured, that is the single
#    largest source of repetition in the corpus. The fix is not a dedupe ledger — it is a
#    narrower and MORE CORRECT question: does the flagged sentence appear in the text THIS
#    call wrote? A row about a paragraph the author did not touch is not about this write.
#    Stateless, and it takes the same history from 89 rows to 32.
#
#    It also makes reads silent for free: `sed -n '1,50p' record.md` and
#    `git add record.md` name the path and write no sentence, so nothing matches.
#
# 3. A SURFACE LIST DERIVED FROM RATES, NOT FROM INTUITION. Measured rows per document:
#
#        docs/verification/  0.59-0.79    <- 2 of the 4 instances live here
#        wiki/               0.66         <- the durable record; the noisiest, and kept
#        memory/*.md         0.04         <- 1 of the 4 instances; the best precision
#        RICH/CEO-TODOs.md   2.00         <- EXCLUDED, see below
#
#    RICH-TODOs.md and CEO-TODOs.md are excluded on the measurement, not on taste: their
#    whole PURPOSE is to record what is awaited by a person, and rule A1 holds "awaited" to
#    be universally unestablishable. Eight recorded writes to RICH-TODOs.md would have
#    re-emitted the same four rows — 32 of the corpus's 89 emissions, from one file whose
#    rows are correct about the words and wrong about the document. A page that would be
#    flagged on every write is the wallpaper this was forbidden to become.
#
#    Source files, `fixtures/` and `*.corpus.md` are out by construction: the check reads
#    prose, and a corpus file asserts known-bad sentences ON PURPOSE.
#
# ===========================================================================================
# WHAT IT WILL NOT DO
# ===========================================================================================
#   * IT NEVER BLOCKS AND NEVER FAILS A TOOL CALL. The write has already happened. Exit 2 on
#     PostToolUse cannot undo it; it puts the text in front of the author and nothing else —
#     the same channel `detect-nonnative-worktree.sh` has used since it landed. Every error
#     path exits 0 silently, because a check that could not run must never look like a failed
#     write.
#   * IT NEVER EDITS THE RECORD. The rows are transient, addressed to the author at the one
#     moment the word can still be changed. They are 62% false on the measured corpus; a
#     permanent section of them inside a landed record would be noise in the durable record.
#   * IT DOES NOT COVER THE FOURTH INSTANCE, and this is said plainly rather than implied
#     away: one of the four was a sentence typed straight to the CEO in chat. It passes
#     through no file and no tool. Nothing textual will ever catch it, and this hook does not.
#
# NOTE: hooks are snapshotted at session start, so this is inert until the next session.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$SCRIPT_DIR/../brief-provenance.py"

# THE SURFACE LIST, DECLARED ONCE. Both readers below use this and only this: the bash fast
# path and the python path resolver. It was two literals for about twenty minutes, and the
# mutation harness caught it immediately — widening the python one left the grep narrow, so
# the mutant survived while looking applied. Two copies of a predicate is the defect class
# this engine keeps finding in itself; here it is, one level down, inside a fix for it.
RECORD_DIRS='docs/verification/|/wiki/|/memory/'
export RECORD_DIRS

INPUT=""
IFS= read -r -t "${RICHOS_HOOK_STDIN_TIMEOUT:-3}" -d '' INPUT || true

# THE FAST PATH. A record-shaped markdown path is named in this payload, or there is nothing
# here for this hook. Registered against every write-shaped tool, so the overwhelmingly
# common answer is reached before python3 is started at all.
if ! printf '%s' "$INPUT" | grep -qE "($RECORD_DIRS)[^\"]*\.md"; then
    exit 0
fi
[ -f "$PROV" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

export RICHOS_PROVENANCE="$PROV"
# Keep the payload out of argv and the environment; descriptor 3 carries its bytes, the same
# way every other payload-reading hook in this engine does it.
python3 - 3<<< "$INPUT" <<'PY'
import importlib.util
import json
import os
import re
import sys

try:
    with os.fdopen(3, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    sys.exit(0)

ti = payload.get("tool_input") or {}
cwd = payload.get("cwd") or os.getcwd()

# --- WHAT THIS CALL WROTE --------------------------------------------------------------
# Not "what is in the file" — what THIS tool call put there. Each write-shaped tool carries
# it in a different field, and Bash carries it in the command itself, heredoc body included.
# A command that only READS a record contributes no sentences and therefore matches nothing.
written = []
for key in ("content", "new_string", "new_source", "command"):
    v = ti.get(key)
    if isinstance(v, str):
        written.append(v)
for e in (ti.get("edits") or []):
    if isinstance(e, dict) and isinstance(e.get("new_string"), str):
        written.append(e["new_string"])
if not written:
    sys.exit(0)
written = "\n".join(written)

# --- WHICH RECORDS ---------------------------------------------------------------------
# Absolute or relative to the call's own cwd; it must exist on disk, because the check reads
# the file to get the citation into scope with the sentence.
RECORD = re.compile(r"(?:^|[\s\"'=(])((?:/|\./|\.\./)?[^\s\"'<>|;:()]*"
                    r"(?:%s)[^\s\"'<>|;:()]*\.md)" % os.environ["RECORD_DIRS"])
EXCLUDE = re.compile(r"(/fixtures/|\.corpus\.md$|/node_modules/)")

blob = " ".join(str(v) for v in ti.values() if isinstance(v, (str, int, float)))
paths, seen = [], set()
for m in RECORD.finditer(blob):
    p = m.group(1)
    if EXCLUDE.search(p):
        continue
    full = p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd, p))
    if full in seen or not os.path.isfile(full):
        continue
    seen.add(full)
    paths.append(full)
if not paths:
    sys.exit(0)

# --- THE PREDICATE, IMPORTED RATHER THAN REIMPLEMENTED ----------------------------------
try:
    spec = importlib.util.spec_from_file_location("brief_provenance",
                                                  os.environ["RICHOS_PROVENANCE"])
    PROV = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(PROV)
except Exception:
    sys.exit(0)                        # a check that cannot run is silent, never a failure

norm_written = PROV.norm(written)
out = []
for path in paths:
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
        rows = PROV.dedupe(PROV.check_capability(PROV.segment(body)))
    except Exception:
        continue
    # Only what this call wrote. `text` is already markdown-stripped and truncated, so the
    # comparison is made in the same normal form on both sides.
    rows = [r for r in rows if PROV.norm(r["text"]) and PROV.norm(r["text"]) in norm_written]
    if rows:
        out.append((path, rows))

if not out:
    sys.exit(0)

total = sum(len(r) for _, r in out)
lines = [
    "NOTICE — nothing failed. Your write succeeded; this is the claim-capability check "
    "reading what you just wrote.",
    "",
    "%d sentence%s you just wrote cite%s a source that does NOT establish what "
    "%s say%s:" % (total, "" if total == 1 else "s", "s" if total == 1 else "",
                   "it" if total == 1 else "they", "s" if total == 1 else ""),
]
for path, rows in out:
    lines.append("")
    lines.append("  %s" % path)
    for r in rows:
        lines.append("    [capability] %s" % r["text"])
        lines.append("                 %s" % r["detail"])
lines += ["", PROV.CAPABILITY_LEAD, "",
          "This is a DISCLOSURE, not a verdict: the first half of each row is a fact about "
          "the command, and the check never judges your sentence. It is also often "
          "unnecessary — hand-classified over 92 rows on these surfaces, roughly three in "
          "five are sentences that turn out to be fine, so the cost of a row is one re-read. "
          "Nothing is blocked and there is no waiver to grant. "
          "Rules, corpus and counts: docs/verification/claim-capability-2026-09-14.md and "
          "docs/verification/claim-capability-delivery-2026-09-14.md."]
print("\n".join(lines), file=sys.stderr)
sys.exit(2)
PY
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
