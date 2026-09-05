#!/usr/bin/env bash
#
# named-persons.sh — the operator front end for the named-person deny-list, and
# the RELEASE-TIME chokepoint.
#
#   scripts/named-persons.sh --doctor                 is there a list, is it sane, is it private?
#   scripts/named-persons.sh --mint "Firstname Lastname" [--single]
#                                                     print the line to paste into the list
#   scripts/named-persons.sh --seed [--hq <dir>]      propose entries from the owner's own records
#   scripts/named-persons.sh --tree [--repo <dir>]    scan everything git tracks — THE RELEASE GATE
#   scripts/named-persons.sh --paths <file>...        scan specific files
#
# WHY A RELEASE GATE AND NOT ONLY HOOKS
# ------------------------------------
# The hooks see what an agent writes and what a command publishes on THIS
# machine. They do not see a title typed into github.com, a file that arrived by
# `cp`, a generator's output, or anything committed before the hooks existed.
# A name reaching a published binary or a release asset is worse than one
# reaching a commit: the commit can be scrubbed at HEAD, and the binary is on a
# stranger's disk.
#
# So this reads the TREE — `git ls-files`, which is the set that actually ships,
# derived the same way `make-engine-asset.sh` derives it — and it refuses.
#
# EXIT CODES, and they are the contract app/scripts/make-release.sh depends on:
#   0  CLEAN     nothing on the list is in the tree
#   1  FOUND     a listed name is in the tree. The release does not proceed.
#   2  ABSENT or BROKEN. A missing list is a REFUSAL here, not a pass — the
#      write-time guards announce and continue because a stranger's clone has no
#      roster, but a release happens on the owner's machine and there the list
#      must exist. "No list" must never be able to look like "no names found".
#
# The predicate, the match rule and the honest coverage statement are in
# scripts/lib/named-persons.py. This file is a front end and a chokepoint; it
# decides nothing about what a name is.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREDICATE="$HERE/lib/named-persons.py"

if [ ! -f "$PREDICATE" ]; then
    echo "named-persons.sh: the predicate is missing at $PREDICATE — refusing." >&2
    exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "named-persons.sh: python3 is required — refusing." >&2; exit 2; }

# shellcheck source=./lib/named-persons.sh
. "$HERE/lib/named-persons.sh"

MODE="${1:---help}"
shift || true

REPO=""
HQ=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --hq)   HQ="${2:-}";   shift 2 ;;
        *)      ARGS+=("$1");  shift ;;
    esac
done

case "$MODE" in
  --doctor)
    python3 "$PREDICATE" --doctor
    exit $?
    ;;

  --mint)
    python3 "$PREDICATE" --mint "${ARGS[@]}"
    exit $?
    ;;

  --seed)
    # SEEDED FROM THE OWNER'S OWN RECORDS, never from a list typed into a brief.
    # `ceo/entities.json` in the private HQ repository is the one file on this
    # machine that names people in a MAINTAINED, STRUCTURED form: the vocabulary
    # the transcription pipeline uses to spell names correctly.
    #
    # AND IT IS NOT A ROSTER OF PRIVATE PEOPLE — measured, on the first run.
    # Seeding from it directly put two names on the list and the release scan
    # then refused the tree over three files, every one of them a SYNTHETIC TEST
    # FIXTURE that is in the repository on purpose: an invented speaker in an
    # end-to-end transcript test, and an invented name in a Rust doctest about
    # learning a correction. That file is an ASR vocabulary. It holds whatever
    # a recording said, real or invented, and a deny-list built from it blocks
    # a repository's own test suite — which is how a guard gets switched off in
    # its first week.
    #
    # So every line it produces is COMMENTED OUT. The operator uncomments the
    # ones that are real people. That is one keystroke per entry and it is the
    # difference between a list somebody reviewed and a list somebody generated.
    #
    # PROPOSED, not written. This prints to stdout and touches nothing: the
    # roster is the operator's, the decision about who is on it is the
    # operator's, and a tool that silently expanded a deny-list would be adding
    # people to a blocklist nobody reviewed.
    [ -n "$HQ" ] || HQ="$(cd "$HERE/../.." 2>/dev/null && pwd)/../richos-hq"
    ENT="$HQ/ceo/entities.json"
    if [ ! -f "$ENT" ]; then
        echo "named-persons.sh --seed: no entity record at $ENT" >&2
        echo "  Pass --hq <path-to-the-private-record>." >&2
        exit 2
    fi
    echo "# Proposed deny-list entries, derived from $ENT"
    echo "# EVERY LINE IS COMMENTED OUT. That file is an ASR vocabulary, not a"
    echo "# roster: it contains synthetic test-fixture names alongside real"
    echo "# people, and pasting it whole makes the release check refuse this"
    echo "# repository's own test suite. Uncomment the real people."
    echo "# Destination: $(np_list_path)   (outside every repository, chmod 600)"
    NP_ENT="$ENT" python3 - <<'PYEOF'
import json, os
data = json.load(open(os.environ["NP_ENT"], encoding="utf-8"))
seen = set()
for e in data.get("entities", []):
    if e.get("type") not in ("person", "customer"):
        continue
    for form in [e.get("canonical", "")] + list(e.get("aliases") or []):
        form = (form or "").strip()
        if not form or form.lower() in seen:
            continue
        seen.add(form.lower())
        n = len([t for t in form.replace("-", " ").replace(".", " ").split() if t])
        if n >= 2:
            print("# name: %s" % form)
        else:
            print("# token: %s   <- SINGLE TOKEN: uncomment only if it is rare" % form)
            print("#            enough to stand alone; a common word here blocks prose.")
PYEOF
    echo "#"
    echo "# WHAT THIS SOURCE CANNOT GIVE YOU, and it is the larger half:"
    echo "#   * anyone whose recording, transcript or document is used as"
    echo "#     MATERIAL here. The 2026-09-04 incident was a speaker in a"
    echo "#     webinar recording, and he was in no machine-readable record."
    echo "#   * family, household and staff. There is no file on this machine"
    echo "#     that enumerates them, so nothing can derive them and this"
    echo "#     command will never propose one. They are typed in by hand or"
    echo "#     they are not protected."
    echo "# Mint each with:  scripts/named-persons.sh --mint \"Firstname Lastname\""
    exit 0
    ;;

  --tree)
    [ -n "$REPO" ] || REPO="$(pwd)"
    TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$TOP" ]; then
        echo "named-persons.sh --tree: $REPO is not a git checkout — refusing." >&2
        exit 2
    fi
    LIST_FILE="$(mktemp -t np-tree.XXXXXX)"
    trap 'rm -f "$LIST_FILE"' EXIT
    ( cd "$TOP" && git ls-files -z ) > "$LIST_FILE" 2>/dev/null
    if [ ! -s "$LIST_FILE" ]; then
        echo "named-persons.sh --tree: git tracks nothing in $TOP. An empty set would" >&2
        echo "  report an empty sweep, which is the false green this exists to remove." >&2
        exit 2
    fi
    # Content AND path, both. The incident was a path.
    #
    # THE LIST GOES IN ON STDIN, and that is not a style choice. `xargs` splits
    # a long argument list across several invocations, so a large tree would run
    # the predicate N times and print N verdict lines — and `head -1` would read
    # the first one and call the release clean over a hit in batch two. The
    # artifact-privacy sweep next door carries a scar from the same family
    # (BSD xargs with no `-a`, reporting every category empty), which is why the
    # predicate takes a NUL-separated list on stdin and answers exactly once.
    RESULT="$( cd "$TOP" && python3 "$PREDICATE" --scan-file-list < "$LIST_FILE" 2>/dev/null )"
    VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
    case "$VERDICT" in
      CLEAN)
        echo "named-persons: CLEAN — $(tr -cd '\0' < "$LIST_FILE" | wc -c | tr -d ' ') tracked files, no listed name in any path or any content."
        exit 0 ;;
      ABSENT)
        np_announce_absent "scripts/named-persons.sh --tree" "$TOP"
        echo "REFUSING: a release cannot proceed while nothing is checking for names." >&2
        exit 2 ;;
      BROKEN)
        np_broken_banner "scripts/named-persons.sh --tree" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)"
        exit 2 ;;
      FOUND)
        np_block_banner "scripts/named-persons.sh --tree" "this release — the tree at $TOP" "$RESULT"
        exit 1 ;;
      *)
        echo "named-persons.sh --tree: unexpected predicate output — refusing (fail-closed)." >&2
        exit 2 ;;
    esac
    ;;

  --paths)
    RESULT="$(python3 "$PREDICATE" --scan-files "${ARGS[@]}" 2>/dev/null)"
    VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
    case "$VERDICT" in
      CLEAN)  echo "named-persons: CLEAN — ${#ARGS[@]} path(s)."; exit 0 ;;
      ABSENT) np_announce_absent "scripts/named-persons.sh --paths" "$(pwd)"; exit 2 ;;
      BROKEN) np_broken_banner "scripts/named-persons.sh --paths" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)"; exit 2 ;;
      FOUND)  np_block_banner "scripts/named-persons.sh --paths" "these paths" "$RESULT"; exit 1 ;;
      *)      echo "named-persons.sh --paths: unexpected predicate output — refusing." >&2; exit 2 ;;
    esac
    ;;

  *)
    sed -n '2,40p' "$0"
    exit 2
    ;;
esac
