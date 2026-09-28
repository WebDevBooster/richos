#!/usr/bin/env bash
#
# record-owner.sh: THE CUT-OVER SWITCH. Who owns a record and its memory: the
# plain terminal (the default, no line) or the RichOS app (one line).
#
#   record-owner.sh status --record <main checkout> [--agents-dir D] [--no-load]
#   record-owner.sh on     --record <main checkout> --memory <dir> [--agents-dir D] [--no-load]
#   record-owner.sh off    --record <main checkout>
#
# Daily-driver plan step 8; two-installs spec points 25-28. The switch is ONE
# LINE in the record's own .row-currency:
#
#   ROW_RECORD_OWNER="app <memory dir>"
#
# `on` writes it and commits that one file; `off` removes it and commits that
# one file. While it is present:
#   * a landing (commit or merge in the main checkout) in the record from his
#     terminal is refused  (guard-row-currency-commits.sh);
#   * a Write/Edit into <memory dir> from his terminal is refused
#     (guard-record-owner-memory.sh).
# The app's own lead is told apart by the platform's session record, never by a
# name (scripts/lib/record_owner.py). Deleting the line by hand reverses both at
# once, exactly as `off` does.
#
# `on` REFUSES unless the record committer is installed for this record
# (record-committer.sh install): a record the app owns with nothing committing
# its loro writes is the unversioned memory spec point 28 warns about.
#
# With the operator fence on for the record, the switch takes the land lease for
# its one commit and gives it back (land-lease.sh; a no-op with the fence off),
# so it is refused while another lead is landing or the app's claim is live.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/row-currency.sh
. "$HERE/lib/row-currency.sh"

say()  { printf '%s\n' "$*"; }
die()  { printf 'record-owner: REFUSED. %s\n' "$*" >&2; exit 2; }

VERB="${1:-}"
[ -n "$VERB" ] && shift
RECORD="" MEMORY="" COMMITTER_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --record)     [ "$#" -ge 2 ] || die "--record needs a value"; RECORD="$2"; shift 2 ;;
        --memory)     [ "$#" -ge 2 ] || die "--memory needs a value"; MEMORY="$2"; shift 2 ;;
        --agents-dir) [ "$#" -ge 2 ] || die "--agents-dir needs a value"; COMMITTER_ARGS+=(--agents-dir "$2"); shift 2 ;;
        --no-load)    COMMITTER_ARGS+=(--no-load); shift ;;
        *) die "unknown argument '$1'" ;;
    esac
done
case "$VERB" in
    status|on|off) ;;
    *) printf 'usage: record-owner.sh status|on|off --record <main checkout> [--memory <dir>]\n' >&2; exit 2 ;;
esac
[ -n "$RECORD" ] || die "--record <the record's main checkout> is required"
[ -d "$RECORD" ] || die "$RECORD is not a directory"
RECORD="$(cd "$RECORD" && pwd -P)"

rc_require_ceo_todos_lib || die "$RC_BROKEN_REASON"
TOP="$(ct_repo_root "$RECORD")" || die "$RECORD is not inside a git repository"
[ "$TOP" = "$RECORD" ] || die "$RECORD is not the top of its repository ($TOP is)"
MAIN="$(ct_main_checkout "$RECORD")"
[ "$MAIN" = "$RECORD" ] || die "$RECORD is a linked worktree; the owner line lives in the main checkout ($MAIN)"

DRC=0
rc_load_declaration "$RECORD" || DRC=$?
case "$DRC" in
    0) ;;
    1) die "$RECORD declares no row-currency contract, so it is not a record this switch governs" ;;
    *) die "the record's declaration is broken: $RC_BROKEN_REASON" ;;
esac
[ "$RC_MODE" = "record" ] || die "$RECORD's declaration is in the peer form; run this on the record it points at"
DECL="$RC_DECLARATION_FILE"
DECL_REL="${DECL#"$RECORD"/}"

committer_installed() {
    python3 "$HERE/lib/record_committer.py" status --repo "$RECORD" --quiet "${COMMITTER_ARGS[@]+"${COMMITTER_ARGS[@]}"}" >/dev/null 2>&1
}

if [ "$VERB" = status ]; then
    say "record : $RECORD"
    say "line   : $DECL"
    if [ "$RC_RECORD_OWNER" = app ]; then
        say "owner  : the RichOS app, with his memory at $RC_RECORD_OWNER_MEMORY"
        say "refused: a landing in this record from his terminal; a write into that memory directory from his terminal"
        say "way out: record-owner.sh off --record $RECORD   (or delete the ROW_RECORD_OWNER line)"
    else
        say "owner  : his terminal (no owner line); nothing is refused"
    fi
    if committer_installed; then
        say "commits: the record committer is installed for this record"
    else
        say "commits: the record committer is NOT installed (record-committer.sh install --repo $RECORD)"
    fi
    exit 0
fi

# --- on and off: one commit of one file, at rest ----------------------------
GITDIR="$(git -C "$RECORD" rev-parse --absolute-git-dir 2>/dev/null)" || die "git cannot read $RECORD"
for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply index.lock; do
    [ -e "$GITDIR/$f" ] && die "the record is not at rest ($GITDIR/$f exists); finish or abort that first"
done
git -C "$RECORD" symbolic-ref -q HEAD >/dev/null 2>&1 || die "HEAD is detached in $RECORD"
git -C "$RECORD" ls-files --error-unmatch -- "$DECL_REL" >/dev/null 2>&1 \
    || die "$DECL_REL is not tracked in $RECORD; the owner line must be a committed, reviewable fact"
git -C "$RECORD" diff --quiet HEAD -- "$DECL_REL" \
    || die "$DECL_REL has uncommitted changes; commit or discard them first, so this switch commits exactly one line"

if [ "$VERB" = on ]; then
    [ -n "$MEMORY" ] || die "--memory <his memory directory> is required"
    case "$MEMORY" in /*|"~/"*) ;; *) die "--memory must be an absolute path or start with ~/ (got '$MEMORY')" ;; esac
    case "$MEMORY" in *'"'*|*"'"*) die "--memory must not contain quotes" ;; esac
    EXPANDED="$MEMORY"
    case "$MEMORY" in "~/"*) EXPANDED="$HOME/${MEMORY#"~/"}" ;; esac
    [ -d "$EXPANDED" ] || die "the memory directory $EXPANDED does not exist"
    if [ "$RC_RECORD_OWNER" = app ]; then
        [ "$RC_RECORD_OWNER_MEMORY" = "$MEMORY" ] && { say "record-owner: already ON: the app owns $RECORD and $MEMORY. Nothing changed."; exit 0; }
        die "the app already owns this record with a different memory directory ($RC_RECORD_OWNER_MEMORY); switch off first"
    fi
    committer_installed || die "the record committer is not installed for $RECORD. Install it first, so the app's memory writes are committed: $ENGINE_ROOT/scripts/record-committer.sh install --repo $RECORD"
else
    if [ "$RC_RECORD_OWNER" != app ]; then
        say "record-owner: already OFF: his terminal owns $RECORD. Nothing changed."
        exit 0
    fi
fi

ORIGINAL="$(mktemp "${TMPDIR:-/tmp}/record-owner.XXXXXX")" || die "no temporary file"
cp "$DECL" "$ORIGINAL"
LEASED=0
cleanup() {
    [ -f "$ORIGINAL" ] && rm -f "$ORIGINAL"
    if [ "$LEASED" = 1 ]; then
        bash "$HERE/land-lease.sh" release --repo "$RECORD" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
restore() { cp "$ORIGINAL" "$DECL"; }

# The land lease, for this one commit (a no-op that says so with the fence off).
LEASE_OUT="$(bash "$HERE/land-lease.sh" acquire --repo "$RECORD" 2>&1)"
LEASE_RC=$?
[ "$LEASE_RC" = 0 ] || die "the land lease for $RECORD could not be taken: $LEASE_OUT"
case "$LEASE_OUT" in *ACQUIRED*) LEASED=1 ;; esac

python3 - "$DECL" "$VERB" "$MEMORY" <<'PY' || { restore; die "the declaration could not be edited"; }
import re, sys, time
path, verb, memory = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
marker = "# THE OWNER LINE (record-owner.sh)."
if verb == "on":
    block = (
        "\n%s The RichOS app owns this record and the memory directory named\n"
        "# below, since %s. His terminal is refused a landing here and a write there.\n"
        "# Delete these lines, or run record-owner.sh off, to give both back to it.\n"
        "ROW_RECORD_OWNER=\"app %s\"\n" % (marker, time.strftime("%Y-%m-%d", time.gmtime()), memory))
    if not text.endswith("\n"):
        text += "\n"
    text += block
else:
    pattern = re.compile(r"\n" + re.escape(marker) + r"[^\n]*\n(?:#[^\n]*\n)*ROW_RECORD_OWNER=[^\n]*\n")
    new, n = pattern.subn("", text, count=1)
    if n == 0:
        new = re.sub(r"(?m)^[ \t]*ROW_RECORD_OWNER[ \t]*=[^\n]*\n?", "", text, count=1)
    text = new
open(path, "w", encoding="utf-8").write(text)
PY

VRC=0
rc_load_declaration "$RECORD" || VRC=$?
if [ "$VRC" != 0 ]; then restore; die "the edited declaration does not parse: $RC_BROKEN_REASON"; fi
if [ "$VERB" = on ] && { [ "$RC_RECORD_OWNER" != app ] || [ "$RC_RECORD_OWNER_MEMORY" != "$MEMORY" ]; }; then
    restore; die "the owner line did not read back as written"
fi
if [ "$VERB" = off ] && [ "$RC_RECORD_OWNER" = app ]; then
    restore; die "the owner line could not be removed"
fi

if [ "$VERB" = on ]; then
    MSG="record: the RichOS app owns this record and his memory from now (cut-over)

record-owner.sh on: ROW_RECORD_OWNER in $DECL_REL. His terminal is refused a
landing here and a write into $MEMORY. record-owner.sh off reverses it."
else
    MSG="record: his terminal owns this record and his memory again

record-owner.sh off: ROW_RECORD_OWNER removed from $DECL_REL. Nothing is refused."
fi
COUT="$(git -C "$RECORD" commit -q --only -m "$MSG" -- "$DECL_REL" 2>&1)" || { restore; die "the commit failed, and the declaration was put back: $COUT"; }
SHA="$(git -C "$RECORD" rev-parse --short=12 HEAD 2>/dev/null)"

if [ "$VERB" = on ]; then
    say "record-owner: ON at $SHA. The RichOS app owns $RECORD and $MEMORY."
    say "  refused from his terminal: a landing in the record; a write into that memory directory"
    say "  way out: record-owner.sh off --record $RECORD"
else
    say "record-owner: OFF at $SHA. His terminal owns $RECORD again; nothing is refused."
fi
exit 0
