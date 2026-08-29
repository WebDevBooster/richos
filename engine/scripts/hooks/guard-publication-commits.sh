#!/usr/bin/env bash
#
# guard-publication-commits.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# The write-time half of this pair (guard-publication-writes.sh) sees content an
# agent AUTHORS. This half sees content that is about to become HISTORY,
# whatever produced it.
#
# WHY BOTH, AND WHY THIS ONE IS NOT OPTIONAL
# ------------------------------------------
# Of the 2026-08-29 leak, THREE files were agent-authored briefs — the write
# hook would have caught those. ONE HUNDRED AND THIRTY-SEVEN were not: they were
# whisper output, ffmpeg measurements and analysis-tool results, produced by
# `tools/run.sh` and friends. No Write tool ever touched them. A PreToolUse
# [Write] guard would have reported a clean session and let every one of them
# through, and the land would have been, on its own terms, telling the truth.
#
# That is the same shape as the "18/18 suites" defect: a check whose scope
# quietly excluded the thing that was actually broken. So the predicate is
# re-run where provenance stops mattering — against the staged INDEX, at
# `git commit`. `git mv`, `cp`, an editor, a generator, a script, another
# agent's leftovers: the index sees all of them identically.
#
# WHY COMMIT AND NOT PUSH: by push time the bytes are already in history, and
# removing them needs a rewrite and a force-push — which is precisely the
# expensive, dangerous remedy the 2026-08-29 removal commit had to defer. A
# commit is free to refuse. A push is not.
#
# WHAT THIS DOES NOT COVER, said plainly: `git merge`, `git cherry-pick`,
# `git am` and `git rebase` create commits without running `git commit`.
# Merge is the acceptable gap — the content it carries was gated when it was
# committed on the source branch, which is the whole point of gating commits.
# The others are genuine holes and they are named here rather than discovered.
#
# NO LIVE OVERRIDE — DELIBERATELY. Every other Bash-matcher guard in this engine
# offers an in-prompt escape token (worktree-remove-ack:, main-checkout-run:).
# This one does not, and that is the point: the thing that failed three times in
# a row was in-the-moment human judgment about whether a particular payload was
# safe to publish. An in-the-moment override would rebuild exactly that. The way
# through is ALLOWLIST in .publication-boundary — committed, diffable, reviewed
# by whoever lands it — or a gitignored destination.
#
# PRECISION: fires only on a command that actually contains `git commit`.
# Everything else on the Bash matcher passes untouched, at the cost of one
# regex.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-publication-commits.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-publication-commits.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    :
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/guard-publication-commits.sh" >&2
    exit 2
fi

_PB_LIB="$SCRIPT_DIR/../lib/publication-boundary.sh"
if [ ! -f "$_PB_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-publication-commits.sh"
        echo "  scripts/lib/publication-boundary.sh is missing at: $_PB_LIB"
        echo "  This guard's entire predicate lives there. Without it it cannot"
        echo "  tell private material from ordinary work, and it will not guess."
    } >&2
    exit 2
fi
# shellcheck source=../lib/publication-boundary.sh
. "$_PB_LIB"

# --- Is this a commit at all, and where? -----------------------------------
# Classified in python, assigned via a quoted heredoc first for the same bash
# 3.2 reason guard-worktree-removal.sh documents: a `)` inside a character
# class mis-scans as the close of a $( ) substitution on macOS's /bin/bash.
read -r -d '' _PC_CLASSIFIER <<'PYEOF' || true
import json, os, re

try:
    d = json.loads(os.environ.get("GUARD_PAYLOAD") or "{}")
except Exception:
    print("PASS"); raise SystemExit
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    print("PASS"); raise SystemExit
ti = d.get("tool_input") or {}
cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""

# `git ... commit`, tolerating -C/-c/flags in between but never crossing a
# statement separator, so an unrelated later `git` cannot bleed in.
if not re.search(r"\bgit\b[^\n;|&]*\bcommit\b", cmd):
    print("PASS"); raise SystemExit

# An explicit -C names the repository; otherwise the session cwd does.
m = re.search(r"\bgit\b\s+(?:[^\n;|&]*?\s)?-C\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd)
repo_hint = ""
if m:
    repo_hint = m.group(1).strip("\"'")

# `-a`/`--all` commits tracked modifications that are NOT in the index yet, so
# the staged set alone would understate what is about to be committed. Said
# once, checked once, rather than assumed.
#
# Quoted spans are stripped FIRST. `git commit -m "handle -a properly"` is not
# a `-a` commit, and treating it as one would drag every unstaged modification
# in the worktree into the scan and block a commit over a file the author was
# not committing. Over-blocking is how a guard gets switched off.
unquoted = re.sub(r'"[^"]*"', " ", cmd)
unquoted = re.sub(r"'[^']*'", " ", unquoted)
stage_all = bool(re.search(r"(?:^|\s)-[a-zA-Z]*a[a-zA-Z]*\b", unquoted)
                 or re.search(r"(?:^|\s)--all\b", unquoted))

print("COMMIT\t%s\t%s" % (repo_hint, "1" if stage_all else "0"))
PYEOF

CLASS="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_PC_CLASSIFIER" 2>/dev/null || printf 'PASS')"
case "$(printf '%s' "$CLASS" | cut -f1)" in
  COMMIT) ;;
  *) exit 0 ;;
esac

REPO_HINT="$(printf '%s' "$CLASS" | cut -f2)"
STAGE_ALL="$(printf '%s' "$CLASS" | cut -f3)"

PAYLOAD_CWD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("cwd", "") or "") if isinstance(d, dict) else "")
except Exception:
    print("")' 2>/dev/null || true)"

PB_ANCHOR="${REPO_HINT:-${PAYLOAD_CWD:-$PWD}}"
case "$PB_ANCHOR" in
  /*) ;;
  *) PB_ANCHOR="${PAYLOAD_CWD:-$PWD}/$PB_ANCHOR" ;;
esac

PB_REPO="$(pb_repo_root "$PB_ANCHOR" 2>/dev/null || true)"
[ -n "$PB_REPO" ] || exit 0

PB_DECL_RC=0
pb_load_declaration "$PB_REPO" || PB_DECL_RC=$?
case "$PB_DECL_RC" in
  0) ;;
  1) exit 0 ;;   # this repository declares no publication boundary
  *) pb_broken_banner "guard-publication-commits.sh" "$PB_BROKEN_REASON" >&2; exit 2 ;;
esac

if ! pb_resolve_sources "$PB_REPO"; then
    pb_broken_banner "guard-publication-commits.sh" "$PB_BROKEN_REASON" >&2
    exit 2
fi

# --- What is about to become history ---------------------------------------
STAGED="$(git -C "$PB_REPO" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
if [ "$STAGE_ALL" = "1" ]; then
    STAGED="$STAGED
$(git -C "$PB_REPO" diff --name-only --diff-filter=ACMR 2>/dev/null || true)"
fi
STAGED="$(printf '%s\n' "$STAGED" | LC_ALL=C sort -u | sed '/^$/d')"
[ -n "$STAGED" ] || exit 0

WORK="$(mktemp -d -t pub-boundary-commit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Materialise each staged blob from the INDEX (`git show :path`) — the bytes
# that would actually be committed, not whatever the worktree happens to hold
# afterwards. Binary blobs are skipped by a NUL test: an image or an audio file
# carries no reproducible speech text, and the old check already covered media.
IDX=0
: > "$WORK/manifest"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if pb_allowlisted "$PB_REPO" "$PB_REPO/$rel"; then
        continue
    fi
    IDX=$((IDX + 1))
    BLOB="$WORK/blob.$IDX"
    if ! git -C "$PB_REPO" show ":$rel" > "$BLOB" 2>/dev/null; then
        # Not in the index (the `-a` case) — read the worktree copy instead.
        [ -f "$PB_REPO/$rel" ] || { IDX=$((IDX - 1)); continue; }
        cp "$PB_REPO/$rel" "$BLOB" 2>/dev/null || { IDX=$((IDX - 1)); continue; }
    fi
    # NUL test, done by byte count rather than by grep: bash cannot carry a NUL
    # in a variable and BSD grep has no portable binary-match flag, so a
    # `grep $'\0'` here silently never matches and every binary blob would be
    # handed to the text scanner.
    _RAW="$(head -c 8192 "$BLOB" | wc -c | tr -d ' ')"
    _TXT="$(head -c 8192 "$BLOB" | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')"
    if [ "$_RAW" != "$_TXT" ]; then
        rm -f "$BLOB"
        IDX=$((IDX - 1))
        continue
    fi
    printf '%s\t%s\n' "$rel" "$BLOB" >> "$WORK/manifest"
done <<STAGED_EOF
$STAGED
STAGED_EOF

[ -s "$WORK/manifest" ] || exit 0

JOB="$WORK/job.json"
PB_MANIFEST="$WORK/manifest" PB_JOB="$JOB" \
  PB_MIN_SPEECH="$PB_MIN_SPEECH_LINES" PB_MIN_QUOTE="$PB_MIN_QUOTE_WORDS" \
  PB_MAX_FILES="$PB_CORPUS_MAX_FILES" PB_MAX_BYTES="$PB_CORPUS_MAX_BYTES" \
  PB_SOURCES_RAW="$PB_SOURCES_OK" \
  python3 -c '
import json, os
items = []
with open(os.environ["PB_MANIFEST"], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        label, path = line.split("\t", 1)
        items.append({"label": label, "path": path})
job = {
    "min_speech_lines": int(os.environ.get("PB_MIN_SPEECH", "8")),
    "min_quote_words": int(os.environ.get("PB_MIN_QUOTE", "10")),
    "corpus_max_files": int(os.environ.get("PB_MAX_FILES", "4000")),
    "corpus_max_bytes": int(os.environ.get("PB_MAX_BYTES", "67108864")),
    "sources": [s for s in os.environ.get("PB_SOURCES_RAW", "").split("\t") if s],
    "items": items,
}
with open(os.environ["PB_JOB"], "w", encoding="utf-8") as fh:
    json.dump(job, fh)
' || { echo "ERROR: guard-publication-commits.sh: could not build the scan job — refusing (fail-closed)" >&2; exit 2; }

RESULT="$(pb_scan "$JOB" || true)"

case "$(printf '%s' "$RESULT" | head -1 | cut -f1)" in
  CLEAN)
    exit 0 ;;
  BROKEN)
    pb_broken_banner "guard-publication-commits.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
    exit 2 ;;
  BLOCK)
    pb_refusal "guard-publication-commits.sh" \
        "Refusing this commit in $PB_REPO — the staged tree carries private material." \
        "$RESULT" "$PB_REPO" "$PB_SOURCES_SKIPPED" >&2
    exit 2 ;;
  *)
    echo "ERROR: guard-publication-commits.sh: unexpected scanner output — refusing (fail-closed)" >&2
    exit 2 ;;
esac
