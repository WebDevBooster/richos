#!/usr/bin/env bash
#
# workspace-retire.test.sh — THE ACCEPTANCE SUITE THE 2026-09-05 DIAGNOSIS
# SPECIFIES, one section per row of its acceptance table.
#
# Source: richos-hq docs/verification/worktree-container-deletion-2026-09-05.md,
# section "Acceptance criteria" (ten rows), plus the independent review of the
# first fix, richos-hq docs/verification/worktree-removal-fix-review-2026-09-06/
# (three reproduced findings; its reproduce.py is vendored beside this file and
# run verbatim), plus the SECOND independent review,
# docs/verification/worktree-removal-fix-recheck-2026-09-06/ (three more, all
# on the legacy route; its reproduce.py is vendored too and run verbatim in the
# last section). The diagnosis's own instructions, followed here:
#
#   "Use disposable fixtures only. No test should target real workspaces."
#   "Tests must assert preservation of sibling file contents and relevant
#    metadata, not merely check an exit code. Include branches, staged state,
#    ignored files and untracked files in the fixtures."
#
# EVERY FIXTURE IS DISPOSABLE. The sandbox is a fresh mktemp directory removed
# on exit, and nothing in this file names a real workspace, a real repository
# or a real agent. The one literal from the incident that IS replayed verbatim
# is the malformed OWNER string, because it is a string and cannot reach
# anything; the malformed PATH is replayed in its exact SHAPE — a container
# directory holding sibling worktrees, addressed with the same trailing slash —
# against the sandbox, because the literal one is a live path on this machine.
#
# ------------------------------------------------------------------------
# TWO RULES THIS FILE HOLDS ITSELF TO, because the project found eleven
# instances in one day of a check reporting green over something that never ran:
#
#   1. NO CASE MAY REPORT ok WHILE ASSERTING NOTHING. `ok` refuses to pass a
#      case in which the assertion counter did not move, and prints the count
#      it made. A case that stops asserting starts failing.
#   2. A NEGATIVE CONTROL MUST FAIL FOR THE RIGHT REASON. Row 1 does not merely
#      show the repaired helper refusing; it first runs the ACTUAL
#      pre-containment helper (from git history) against the same fixture and
#      requires it to DELETE the container. A refusal test whose fixture was
#      never destructible proves nothing.
#
# Run directly: scripts/lib/workspace-retire.test.sh
# Exit 0 = every case passed; 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/workspace-retire.py"
LEDGER_PY="$SCRIPT_DIR/worktree-ledger.py"
HELPER="$(cd "$SCRIPT_DIR/.." && pwd)/remove-agent-worktree.sh"

PASS=0
FAIL=0
NOTCOVERED=0
ASSERTS=0
LAST_ASSERTS=0

SANDBOX="$(cd "$(mktemp -d -t workspace-retire-test.XXXXXX)" && pwd -P)"
cleanup() {
    # Fixtures are made read-only by two cases on purpose; restore write
    # permission so the sandbox can actually be removed.
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

ok() {
    if [ "$ASSERTS" -le "$LAST_ASSERTS" ]; then
        printf '  FAIL  %s — reported ok while asserting NOTHING\n' "$1"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s  [%d assertions]\n' "$1" "$((ASSERTS - LAST_ASSERTS))"
        PASS=$((PASS + 1))
    fi
    LAST_ASSERTS=$ASSERTS
}
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); LAST_ASSERTS=$ASSERTS; }
notcovered() {
    printf '  NOT COVERED  %s\n           reason: %s\n' "$1" "$2"
    NOTCOVERED=$((NOTCOVERED + 1))
    LAST_ASSERTS=$ASSERTS
}

a() { ASSERTS=$((ASSERTS + 1)); }

assert_eq() { # <want> <got> <label>
    a
    if [ "$1" = "$2" ]; then return 0; fi
    printf '        ASSERT FAILED (%s)\n          want: %s\n          got : %s\n' "$3" "$1" "$2"
    return 1
}
assert_ne() { # <not-want> <got> <label>
    a
    if [ "$1" != "$2" ]; then return 0; fi
    printf '        ASSERT FAILED (%s): value must differ, both are: %s\n' "$3" "$1"
    return 1
}
assert_contains() { # <haystack> <needle> <label>
    a
    case "$1" in *"$2"*) return 0 ;; esac
    printf '        ASSERT FAILED (%s): output does not contain %s\n          got: %s\n' \
        "$3" "$2" "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-300)"
    return 1
}
assert_dir() { # <path> <label>
    a
    if [ -d "$1" ]; then return 0; fi
    printf '        ASSERT FAILED (%s): directory missing: %s\n' "$2" "$1"
    return 1
}
assert_absent() { # <path> <label>
    a
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
    printf '        ASSERT FAILED (%s): path should not exist: %s\n' "$2" "$1"
    return 1
}

[ -f "$LIB" ] || { echo "FATAL: missing $LIB" >&2; exit 1; }
[ -f "$LEDGER_PY" ] || { echo "FATAL: missing $LEDGER_PY" >&2; exit 1; }
[ -f "$HELPER" ] || { echo "FATAL: missing $HELPER" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# --------------------------------------------------------------------------
# fixture construction — disposable, and deliberately full of the states a
# clean `git status` would hide
# --------------------------------------------------------------------------

seed_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    printf 'seed\n' >"$1/seed.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m seed
}

# A byte-level snapshot: every file and symlink under a tree, with its digest
# or link target. Comparing two of these is how "sibling data unchanged" is
# asserted rather than assumed.
snapshot() { # <dir>
    ( cd "$1" 2>/dev/null || exit 0
      find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
          if [ -L "$f" ]; then
              printf '%s\tSYMLINK\t%s\n' "$f" "$(readlink "$f")"
          else
              printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
          fi
      done )
}

refs_snapshot() { git -C "$1" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort; }
wt_snapshot()   { git -C "$1" worktree list --porcelain | LC_ALL=C sort; }
inode_of()      { python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print("%d:%d"%(s.st_dev,s.st_ino))' "$1"; }
# Every quarantine of workspace <name> in container <dir>. Quarantines live in
# <dir>/.richos-retired/ (see the library header for why a dot-directory). A
# row asserting "no quarantine exists" must look HERE: before this helper,
# three rows looked in the container root, and when the location moved they
# went green over a check of nowhere. R6 and QDIR pin the location, so an
# empty answer from this helper means what the row says.
quarantines_of() { ls -d "$1"/.richos-retired/"$2".richos-retired-* 2>/dev/null; }

FIXNO=0
FX=""; OWNER_REPO=""; ENTITY=""; CONTAINER=""; LEDGER=""
WS_ALPHA=""; WS_BETA=""; ALPHA_AGENT="aaaa1111bbbb2222"; BETA_AGENT="cccc3333dddd4444"

L() { python3 "$LEDGER_PY" --ledger "$LEDGER" "$@" >/dev/null; }

# Retire through the SANCTIONED HELPER, which is what a caller actually runs.
H() { bash "$HELPER" --entity-repo "$ENTITY" "$@" 2>&1; }
# ...and directly, where a case needs a subcommand the helper does not route.
R() { python3 "$LIB" "$@" 2>&1; }

new_fixture() { # [--alive] [--indeterminate]
    FIXNO=$((FIXNO + 1))
    FX="$SANDBOX/fx$FIXNO"
    mkdir -p "$FX"
    OWNER_REPO="$FX/owner-repo"
    ENTITY="$FX/entity"
    CONTAINER="$FX/container"
    LEDGER="$FX/ledger.jsonl"
    export RICHOS_WORKTREE_LEDGER="$LEDGER"
    export RICHOS_WORKSPACE_RETIRE_DIR="$FX/retire-state"
    unset RICHOS_WORKSPACE_RETENTION_DAYS

    seed_repo "$OWNER_REPO"
    seed_repo "$ENTITY"
    mkdir -p "$CONTAINER"
    git -C "$OWNER_REPO" worktree add -q -b alpha "$CONTAINER/alpha"
    git -C "$OWNER_REPO" worktree add -q -b beta  "$CONTAINER/beta"

    # alpha carries EVERY state the diagnosis names: committed, staged, dirty,
    # untracked, ignored — plus a symlink and a nested directory.
    printf 'ignored/\n*.ign\n' >"$CONTAINER/alpha/.gitignore"
    printf 'committed body\n'  >"$CONTAINER/alpha/committed.txt"
    mkdir -p "$CONTAINER/alpha/sub"
    printf 'nested body\n'     >"$CONTAINER/alpha/sub/nested.txt"
    git -C "$CONTAINER/alpha" add -A
    git -C "$CONTAINER/alpha" commit -q -m "alpha work"
    printf 'staged body\n'     >"$CONTAINER/alpha/staged.txt"
    git -C "$CONTAINER/alpha" add staged.txt
    printf 'committed body, then edited\n' >"$CONTAINER/alpha/committed.txt"
    printf 'untracked body\n'  >"$CONTAINER/alpha/untracked.txt"
    printf 'ignored body\n'    >"$CONTAINER/alpha/secret.ign"
    mkdir -p "$CONTAINER/alpha/ignored"
    printf 'ignored blob\n'    >"$CONTAINER/alpha/ignored/blob.bin"
    ln -s committed.txt "$CONTAINER/alpha/link.txt"

    # beta is the SIBLING whose bytes every refusal case asserts unchanged.
    printf 'beta committed\n'  >"$CONTAINER/beta/beta.txt"
    git -C "$CONTAINER/beta" add -A
    git -C "$CONTAINER/beta" commit -q -m "beta work"
    printf 'beta untracked\n'  >"$CONTAINER/beta/beta-untracked.txt"

    L record registered --teammate zach-alpha --agent-id "$ALPHA_AGENT" --session-id sess-a \
        --repo "$OWNER_REPO" --worktree "$CONTAINER/alpha" --branch alpha --class hand-rolled
    L record registered --teammate zach-beta --agent-id "$BETA_AGENT" --session-id sess-b \
        --repo "$OWNER_REPO" --worktree "$CONTAINER/beta" --branch beta --class hand-rolled

    case "${1:-}" in
        --alive)
            # A LIVE owner: alpha's agent holds a locked native isolation
            # worktree in the entity, with a running pid.
            mkdir -p "$ENTITY/.claude/worktrees"
            git -C "$ENTITY" worktree add -q -b "worktree-agent-$ALPHA_AGENT" \
                "$ENTITY/.claude/worktrees/agent-$ALPHA_AGENT"
            sleep 300 &
            LIVE_PID=$!
            git -C "$ENTITY" worktree lock \
                --reason "claude agent agent-$ALPHA_AGENT (pid $LIVE_PID start test)" \
                "$ENTITY/.claude/worktrees/agent-$ALPHA_AGENT"
            ;;
        --indeterminate)
            # No native worktree at all, and the host session process is still
            # running: absence, which is NOT a termination signal.
            L record registered --teammate zach-alpha2 --agent-id "eeee5555ffff6666" \
                --session-id sess-c --session-pid "$$" --pid-start-of-session \
                --repo "$OWNER_REPO" --worktree "$CONTAINER/alpha" --branch alpha \
                --class hand-rolled
            ;;
        *)
            # The default: a POSITIVE, witnessed termination for alpha's owner.
            L record terminated --agent-id "$ALPHA_AGENT" --teammate zach-alpha \
                --worktree "$CONTAINER/alpha" --reason "test fixture: witnessed termination" \
                --witness "test"
            ;;
    esac

    WS_ALPHA="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/alpha")"
    WS_BETA="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/beta")"
    # Each fixture publishes its OWN sibling baseline. Carrying one over from a
    # previous fixture would compare two different sandboxes and fail for a
    # reason that has nothing to do with the case — the "negative control that
    # fails for the wrong reason" this suite exists to avoid.
    BEFORE_BETA="$(snapshot "$CONTAINER/beta")"
    BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
}

# The JSON travels in the ENVIRONMENT, not on stdin. The first version of this
# helper piped the JSON to `python3 -` while handing the program to the same
# stdin through a heredoc; the heredoc won, `sys.stdin.read()` returned nothing
# after the program, and the helper printed nothing — silently, for every call.
# No row used it until 2026-09-06, when four new rows did and all four failed
# over a product that was behaving correctly. A helper nobody calls is a helper
# nobody has proven.
json_field() { # <json> <dotted.path>
    JF_JSON="$1" python3 -c '
import json, os, sys
try:
    cur = json.loads(os.environ.get("JF_JSON") or "null")
except Exception:
    cur = None
for k in sys.argv[1].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None:
        break
print("" if cur is None else (cur if isinstance(cur, str) else json.dumps(cur)))
' "$2"
}
jf() { json_field "$1" "$2"; }

echo "=== workspace-retire: the ten acceptance rows of the 2026-09-05 diagnosis ==="
echo

# ==========================================================================
# ROW 1 — "Replay the exact malformed owner and parent path from this
#          incident. Required result: refusal before mutation. All sibling
#          data and Git references unchanged."
# ==========================================================================
echo "--- ROW 1: the incident, replayed ---"

new_fixture
MALFORMED_OWNER="a1a79564774330793 echo-opus-pn1"   # verbatim from the incident
MALFORMED_TARGET="$CONTAINER/"                       # the container, trailing slash and all

BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_BETA="$(snapshot "$CONTAINER/beta")"
BEFORE_REFS="$(refs_snapshot "$OWNER_REPO")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"

# --- 1a. THE NEGATIVE CONTROL. Reconstruct the ACTUAL pre-containment helper
# and run it against this fixture. If it does not destroy the container, this
# fixture cannot prove anything about the repair, and the whole row is void.
PRE_DIR="$FX/pre-containment"
mkdir -p "$PRE_DIR/lib"
cp "$SCRIPT_DIR/agent-liveness.sh" "$SCRIPT_DIR/agent-liveness.py" \
   "$SCRIPT_DIR/resolve-roots.sh" "$SCRIPT_DIR/worktree-ledger.py" "$PRE_DIR/lib/" 2>/dev/null
PRE_SH="$PRE_DIR/remove-agent-worktree.sh"
PRE_SOURCE=""
if git -C "$SCRIPT_DIR" cat-file -e '1b84a1c^:engine/scripts/remove-agent-worktree.sh' 2>/dev/null; then
    git -C "$SCRIPT_DIR" show '1b84a1c^:engine/scripts/remove-agent-worktree.sh' >"$PRE_SH"
    PRE_SOURCE="git history (1b84a1c^, the commit before containment)"
else
    # Fallback for a clone without that object: rebuild the historical
    # fallback by replacing the refusal block with what stood there.
    python3 - "$HELPER" "$PRE_SH" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
start = s.index('elif [ -d "$WT_PATH" ]; then')
end = s.index('\nfi\n', start) + len('\nfi\n')
s = s[:start] + 'elif [ -d "$WT_PATH" ]; then\n    rm -rf "$WT_PATH"\n    git -C "$REPO" worktree prune >/dev/null 2>&1 || true\nfi\n' + s[end:]
io.open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
    PRE_SOURCE="reconstructed fallback (the historical object was not available)"
fi
chmod +x "$PRE_SH"

PRE_OUT="$(bash "$PRE_SH" --entity-repo "$ENTITY" --repo "$OWNER_REPO" \
    --owner "$MALFORMED_OWNER" "$MALFORMED_TARGET" 2>&1)"
PRE_RC=$?
rc=0
assert_eq "0" "$PRE_RC" "pre-containment helper reported SUCCESS on the malformed request" || rc=1
assert_contains "$PRE_OUT" "removed agent worktree" "pre-containment success message" || rc=1
assert_absent "$CONTAINER/alpha" "pre-containment DELETED the sibling workspace alpha" || rc=1
assert_absent "$CONTAINER/beta" "pre-containment DELETED the sibling workspace beta" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R1a  NEGATIVE CONTROL — the pre-containment helper [$PRE_SOURCE] deletes the whole container on the incident's arguments and exits 0"
else
    bad "R1a  NEGATIVE CONTROL did not reproduce the incident — every refusal below would be proving nothing"
fi

# --- 1b. The repaired helper, same arguments, fresh identical fixture.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_BETA="$(snapshot "$CONTAINER/beta")"
BEFORE_REFS="$(refs_snapshot "$OWNER_REPO")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
BEFORE_CONTAINER_INODE="$(inode_of "$CONTAINER")"
MALFORMED_TARGET="$CONTAINER/"

OUT="$(H --repo "$OWNER_REPO" --owner "$MALFORMED_OWNER" "$MALFORMED_TARGET")"
RC=$?
rc=0
assert_eq "5" "$RC" "repaired helper exit code (5 = unregistered target refused)" || rc=1
assert_contains "$OUT" "REFUSING" "refusal banner" || rc=1
assert_dir "$CONTAINER" "the container still exists" || rc=1
assert_eq "$BEFORE_CONTAINER_INODE" "$(inode_of "$CONTAINER")" "the container is the same object" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "sibling alpha byte-for-byte unchanged" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "sibling beta byte-for-byte unchanged" || rc=1
assert_eq "$BEFORE_REFS" "$(refs_snapshot "$OWNER_REPO")" "every git reference unchanged" || rc=1
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "every worktree registration unchanged" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R1b  the incident's exact malformed owner and container path are REFUSED, before mutation, with both siblings, all refs and all registrations byte-identical"
else
    bad "R1b  the repaired helper did not refuse the incident's arguments intact"
fi

# --- 1c. In retirement mode the request cannot even be SPELLED: a path is not
# an identity, so it never reaches the disk.
OUT="$(H --workspace "$MALFORMED_TARGET" --owner "$MALFORMED_OWNER")"
RC=$?
rc=0
assert_eq "3" "$RC" "retirement mode refuses (exit 3)" || rc=1
assert_contains "$OUT" "malformed-workspace-id" "reason code" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha unchanged" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "beta unchanged" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R1c  retirement mode cannot express the incident at all — a path is not a workspace ID and is refused before any filesystem access"
else
    bad "R1c  retirement mode did not refuse a path supplied as an identity"
fi

# ==========================================================================
# ROW 2 — "Empty input, unknown owner, mismatched owner or wrong repository.
#          Required result: refusal before mutation."
# ==========================================================================
echo "--- ROW 2: empty, unknown, mismatched, wrong repository ---"

new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_BETA="$(snapshot "$CONTAINER/beta")"
BEFORE_REFS="$(refs_snapshot "$OWNER_REPO")"

rc=0
OUT="$(R retire "")"; assert_eq "3" "$?" "empty workspace ID refused" || rc=1
assert_contains "$OUT" "empty-workspace-id" "empty input reason code" || rc=1

OUT="$(R retire "ws-0123456789abcdef" --entity-repo "$ENTITY")"
assert_eq "3" "$?" "unknown workspace ID refused" || rc=1
assert_contains "$OUT" "unknown-workspace" "unknown identity reason code" || rc=1

OUT="$(H --workspace "$WS_ALPHA" --owner "not-the-owner")"
assert_eq "3" "$?" "mismatched owner refused" || rc=1
assert_contains "$OUT" "owner-mismatch" "mismatched owner reason code" || rc=1

OUT="$(H --workspace "$WS_ALPHA" --owner "$ALPHA_AGENT" --repo "$ENTITY")"
assert_eq "3" "$?" "wrong repository refused" || rc=1
assert_contains "$OUT" "repo-mismatch" "wrong repository reason code" || rc=1

OUT="$(H --workspace "$WS_ALPHA" "$CONTAINER/beta")"
assert_eq "3" "$?" "path assertion naming a different workspace refused" || rc=1
assert_contains "$OUT" "path-mismatch" "path assertion reason code" || rc=1

assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha unchanged through all five refusals" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "beta unchanged through all five refusals" || rc=1
assert_eq "$BEFORE_REFS" "$(refs_snapshot "$OWNER_REPO")" "refs unchanged through all five refusals" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R2   empty / unknown / mismatched-owner / wrong-repository / mismatched-path all refuse before mutation, and the caller's strings can only fail to match — never widen the target"
else
    bad "R2   one of the five malformed-request classes was not refused intact"
fi

# ==========================================================================
# ROW 3 — "Parent path, equivalent path spelling, symlink or redirected path.
#          Required result: only an authorized exact workspace identity can be
#          acted on. Ambiguity causes refusal."
# ==========================================================================
echo "--- ROW 3: parents, spellings, symlinks, redirection ---"

new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_BETA="$(snapshot "$CONTAINER/beta")"

# 3a. Even a REGISTERED parent refuses. This is the strongest form of the row:
# the container is given a perfectly valid ownership record, so it resolves —
# and it is still refused, because it CONTAINS other workspaces.
L record registered --teammate zach-container --agent-id "9999888877776666" \
    --session-id sess-x --repo "$OWNER_REPO" --worktree "$CONTAINER" \
    --branch container --class hand-rolled
L record terminated --agent-id "9999888877776666" --worktree "$CONTAINER" \
    --reason "test fixture: witnessed termination" --witness "test"
WS_CONTAINER="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER")"
rc=0
OUT="$(H --workspace "$WS_CONTAINER")"
assert_eq "3" "$?" "registered parent directory refused" || rc=1
assert_contains "$OUT" "path-is-parent" "parent reason code" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha unchanged" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "beta unchanged" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R3a  a parent directory is refused EVEN WITH a valid ownership record of its own — containing another workspace is disqualifying by itself"
else
    bad "R3a  a registered parent directory was not refused"
fi

# 3b. Equivalent spellings resolve to ONE identity — a caller cannot mint a
# second, unvalidated identity by respelling the path.
rc=0
ID_PLAIN="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/alpha")"
ID_SLASH="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/alpha/")"
ID_DOTS="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/beta/../alpha")"
ID_REPO_SLASH="$(python3 "$LIB" workspace-id "$OWNER_REPO/" "$CONTAINER/alpha")"
assert_eq "$ID_PLAIN" "$ID_SLASH" "trailing slash yields the same identity" || rc=1
assert_eq "$ID_PLAIN" "$ID_DOTS" "a .. traversal yields the same identity" || rc=1
assert_eq "$ID_PLAIN" "$ID_REPO_SLASH" "repository spelling yields the same identity" || rc=1
assert_ne "$ID_PLAIN" "$WS_BETA" "a DIFFERENT workspace has a different identity" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R3b  equivalent path spellings collapse to one identity and distinct workspaces stay distinct — respelling cannot create an unvalidated target"
else
    bad "R3b  path spelling changed the identity"
fi

# 3c. A symlink standing where a workspace is recorded is refused, not followed.
rc=0
mv "$CONTAINER/alpha" "$CONTAINER/alpha-real"
ln -s "$CONTAINER/alpha-real" "$CONTAINER/alpha"
BEFORE_REAL="$(snapshot "$CONTAINER/alpha-real")"
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "3" "$?" "symlink target refused" || rc=1
assert_contains "$OUT" "symlink-target" "symlink reason code" || rc=1
assert_eq "$BEFORE_REAL" "$(snapshot "$CONTAINER/alpha-real")" "the object the symlink pointed at is untouched" || rc=1
a; [ -L "$CONTAINER/alpha" ] || { printf '        ASSERT FAILED: the symlink itself was removed\n'; rc=1; }
rm -f "$CONTAINER/alpha"
mv "$CONTAINER/alpha-real" "$CONTAINER/alpha"
if [ "$rc" -eq 0 ]; then
    ok "R3c  a symlink at a recorded workspace path is refused with O_NOFOLLOW, and the object it pointed at is untouched"
else
    bad "R3c  a symlink substitution was followed or mutated something"
fi

# 3d. Redirection BETWEEN validation and execution: the held-descriptor
# identity check must notice that the name now points at a different object.
rc=0
REDIRECT_OUT="$(python3 - "$LIB" "$CONTAINER/alpha" "$CONTAINER" <<'PY'
import importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("wr", sys.argv[1])
wr = importlib.util.module_from_spec(spec); spec.loader.exec_module(wr)
path, container = sys.argv[2], sys.argv[3]
t = wr.FsTarget(path)
assert t.open(), "fixture: could not open the target"
before = t.still_the_same()
# Swap the object the NAME resolves to, exactly as a racing caller would.
os.rename(path, os.path.join(container, "alpha-moved"))
os.mkdir(path)
after = t.still_the_same()
t.close()
shutil.rmtree(path)
os.rename(os.path.join(container, "alpha-moved"), path)
print("before=%s after=%s" % (before, after))
PY
)"
assert_contains "$REDIRECT_OUT" "before=True" "the validated object matches itself" || rc=1
assert_contains "$REDIRECT_OUT" "after=False" "a swapped object is detected before execution" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R3d  a path redirected between validation and execution is detected by the held-descriptor identity check, so the rename never lands on the substitute"
else
    bad "R3d  a redirected path was not detected"
fi

# ==========================================================================
# ROW 4 — "Target directory exists but is not registered. Required result:
#          refusal with no recursive deletion fallback."
# ==========================================================================
echo "--- ROW 4: the target exists but is not a registered worktree ---"

new_fixture
mkdir -p "$CONTAINER/orphan/deep"
printf 'orphan payload\n' >"$CONTAINER/orphan/payload.txt"
printf 'deep payload\n'   >"$CONTAINER/orphan/deep/deep.txt"
BEFORE_ORPHAN="$(snapshot "$CONTAINER/orphan")"
L record registered --teammate zach-orphan --agent-id "1111222233334444" \
    --session-id sess-o --repo "$OWNER_REPO" --worktree "$CONTAINER/orphan" \
    --branch orphan --class hand-rolled
L record terminated --agent-id "1111222233334444" --worktree "$CONTAINER/orphan" \
    --reason "test fixture: witnessed termination" --witness "test"
WS_ORPHAN="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/orphan")"

rc=0
OUT="$(H --workspace "$WS_ORPHAN")"
assert_eq "3" "$?" "unregistered directory refused in retirement mode" || rc=1
assert_contains "$OUT" "not-a-worktree-root" "unregistered reason code" || rc=1
assert_eq "$BEFORE_ORPHAN" "$(snapshot "$CONTAINER/orphan")" "the unregistered directory is byte-for-byte intact" || rc=1

# ...and the same directory through the LEGACY path, which is where the
# recursive fallback used to live.
OUT="$(H --owner "1111222233334444" --repo "$OWNER_REPO" "$CONTAINER/orphan")"
assert_eq "5" "$?" "legacy mode refuses an unregistered directory (exit 5)" || rc=1
assert_contains "$OUT" "REFUSING" "legacy refusal banner" || rc=1
assert_eq "$BEFORE_ORPHAN" "$(snapshot "$CONTAINER/orphan")" "still intact after the legacy call" || rc=1

# A directory that IS a git worktree, but of a DIFFERENT repository than the
# record names: registered somewhere, unregistered HERE.
git -C "$ENTITY" worktree add -q -b gamma "$CONTAINER/gamma"
printf 'gamma payload\n' >"$CONTAINER/gamma/gamma.txt"
BEFORE_GAMMA="$(snapshot "$CONTAINER/gamma")"
L record registered --teammate zach-gamma --agent-id "5555666677778888" \
    --session-id sess-g --repo "$OWNER_REPO" --worktree "$CONTAINER/gamma" \
    --branch gamma --class hand-rolled
L record terminated --agent-id "5555666677778888" --worktree "$CONTAINER/gamma" \
    --reason "test fixture: witnessed termination" --witness "test"
WS_GAMMA="$(python3 "$LIB" workspace-id "$OWNER_REPO" "$CONTAINER/gamma")"
OUT="$(H --workspace "$WS_GAMMA")"
assert_eq "3" "$?" "a worktree of another repository is refused" || rc=1
assert_contains "$OUT" "not-registered-worktree" "wrong-repository registration reason code" || rc=1
assert_eq "$BEFORE_GAMMA" "$(snapshot "$CONTAINER/gamma")" "gamma intact" || rc=1

if [ "$rc" -eq 0 ]; then
    ok "R4   an existing but unregistered target is refused in BOTH modes with no recursive fallback, including a real worktree registered to a different repository"
else
    bad "R4   an unregistered target was not refused, or was mutated"
fi

# ==========================================================================
# ROW 5 — "Worker alive, status unknown or worker startup races retirement.
#          Required result: no destructive action while ownership or
#          termination is unresolved."
# ==========================================================================
echo "--- ROW 5: alive, unknown, and a startup racing retirement ---"

LIVE_PID=""
new_fixture --alive
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "3" "$?" "a LIVE owner refuses" || rc=1
assert_contains "$OUT" "owner-alive" "alive reason code" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha untouched while its owner runs" || rc=1
if [ -n "${LIVE_PID:-}" ]; then kill "$LIVE_PID" 2>/dev/null; fi
if [ "$rc" -eq 0 ]; then
    ok "R5a  a workspace whose owner holds a live isolation lock is refused and untouched"
else
    bad "R5a  a live owner's workspace was not protected"
fi

new_fixture --indeterminate
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "3" "$?" "an INDETERMINATE owner refuses" || rc=1
assert_contains "$OUT" "owner-indeterminate" "indeterminate reason code" || rc=1
assert_contains "$OUT" "absence is not a termination signal" "the refusal names the doctrine" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha untouched" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R5b  an owner whose state is UNKNOWN refuses — absence of a lock is never read as a termination"
else
    bad "R5b  an unresolved owner did not refuse"
fi

# 5c. A startup racing retirement: another process holds the workspace lock.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
LOCKDIR="$RICHOS_WORKSPACE_RETIRE_DIR/locks"
mkdir -p "$LOCKDIR"
python3 - "$LOCKDIR/$WS_ALPHA.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("held\n"); sys.stdout.flush()
time.sleep(4)
PY
HOLDER_PID=$!
sleep 1
OUT="$(H --workspace "$WS_ALPHA" --lock-wait 1)"
assert_eq "3" "$?" "retirement refuses while another caller holds the workspace" || rc=1
assert_contains "$OUT" "workspace-busy" "busy reason code" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha untouched while contended" || rc=1
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
if [ "$rc" -eq 0 ]; then
    ok "R5c  retirement is serialized: while another caller holds the workspace lock it refuses rather than proceeding beside it"
else
    bad "R5c  retirement proceeded beside a lock holder"
fi

# 5d. A worker ACQUIRES the workspace while retirement is waiting for the lock.
# The holder appends a fresh ownership record, then releases; retirement must
# notice the record set changed under it and refuse.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
mkdir -p "$LOCKDIR"
LOCKDIR="$RICHOS_WORKSPACE_RETIRE_DIR/locks"
mkdir -p "$LOCKDIR"
(
    python3 - "$LOCKDIR/$WS_ALPHA.lock" <<'PY'
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
PY
) &
HOLDER_PID=$!
sleep 0.5
# The "startup": a new ownership record for the same path appears mid-flight.
( sleep 1
  python3 "$LEDGER_PY" --ledger "$LEDGER" record registered --teammate zach-newcomer \
      --agent-id "abcdabcdabcdabcd" --session-id sess-new --repo "$OWNER_REPO" \
      --worktree "$CONTAINER/alpha" --branch alpha --class hand-rolled >/dev/null ) &
WRITER_PID=$!
OUT="$(H --workspace "$WS_ALPHA" --lock-wait 8)"
RC=$?
wait "$HOLDER_PID" 2>/dev/null
wait "$WRITER_PID" 2>/dev/null
assert_eq "3" "$RC" "retirement refuses after the records changed under it" || rc=1
assert_contains "$OUT" "reacquired" "reacquisition reason code" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha untouched after the race" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R5d  a worker that acquires the workspace while retirement waits on the lock is detected by the under-lock record re-read, and retirement refuses"
else
    bad "R5d  a mid-flight acquisition was not detected"
fi

# ==========================================================================
# ROW 6 — "Workspace contains committed, staged, dirty, untracked and ignored
#          data. Required result: retirement preserves recoverable content and
#          metadata. Verified restoration reproduces it."
# ==========================================================================
echo "--- ROW 6: preservation and verified restoration ---"

new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
ALPHA_HEAD="$(git -C "$CONTAINER/alpha" rev-parse HEAD)"
ALPHA_GITDIR="$(git -C "$CONTAINER/alpha" rev-parse --absolute-git-dir)"
INDEX_SHA="$(shasum -a 256 "$ALPHA_GITDIR/index" | cut -d' ' -f1)"
BEFORE_BETA="$(snapshot "$CONTAINER/beta")"

rc=0
OUT="$(H --workspace "$WS_ALPHA" --owner "$ALPHA_AGENT" --repo "$OWNER_REPO")"
RC=$?
assert_eq "0" "$RC" "retirement succeeds" || rc=1
OUTCOME="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["outcome"])' 2>/dev/null)"
assert_eq "quarantined" "$OUTCOME" "structured outcome" || rc=1
PRES_STATUS="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["preservation"]["status"])' 2>/dev/null)"
assert_eq "verified" "$PRES_STATUS" "preservation verified" || rc=1
COUNTS="$(printf '%s' "$OUT" | python3 -c 'import json,sys; c=json.load(sys.stdin)["preservation"]["counts"]; print("%d %d %d %d"%(c["staged"],c["untracked"],c["ignored"],c["dirty"]))' 2>/dev/null)"
set -- $COUNTS
a; [ "${1:-0}" -ge 1 ] || { printf '        ASSERT FAILED: no STAGED files recorded (%s)\n' "$COUNTS"; rc=1; }
a; [ "${2:-0}" -ge 1 ] || { printf '        ASSERT FAILED: no UNTRACKED files recorded (%s)\n' "$COUNTS"; rc=1; }
a; [ "${3:-0}" -ge 1 ] || { printf '        ASSERT FAILED: no IGNORED files recorded (%s)\n' "$COUNTS"; rc=1; }
a; [ "${4:-0}" -ge 1 ] || { printf '        ASSERT FAILED: no DIRTY files recorded (%s)\n' "$COUNTS"; rc=1; }

QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
assert_dir "$QPATH" "the workspace was quarantined, not erased" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$QPATH")" "the quarantine holds the workspace byte-for-byte" || rc=1
assert_absent "$CONTAINER/alpha" "the original path is vacated" || rc=1
assert_eq "$CONTAINER/.richos-retired" "$(dirname "$QPATH")" "the quarantine lives in <parent>/.richos-retired/ (pins the location every absence check below relies on)" || rc=1
assert_eq "$QPATH" "$(quarantines_of "$CONTAINER" alpha)" "and quarantines_of finds exactly it" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "the sibling workspace is untouched" || rc=1

BACKUP_REF="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["branch"]["backup_ref"])' 2>/dev/null)"
assert_eq "$ALPHA_HEAD" "$(git -C "$OWNER_REPO" rev-parse "$BACKUP_REF")" "the backup ref preserves the exact tip" || rc=1
assert_eq "$ALPHA_HEAD" "$(git -C "$OWNER_REPO" rev-parse refs/heads/alpha)" "the branch itself is NOT deleted by retirement" || rc=1

# The restoration, re-verified against the manifest on the bytes that landed.
REST="$FX/restored"
ROUT="$(R restore "$WS_ALPHA" "$REST")"
assert_eq "0" "$?" "restore succeeds" || rc=1
assert_contains "$ROUT" "re-verified byte for byte" "restore verification message" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$REST/workspace")" "the restored tree reproduces the workspace byte-for-byte, including untracked, ignored and the symlink" || rc=1
a; [ -f "$REST/gitdir/index" ] || { printf '        ASSERT FAILED: the git index (staged state) was not preserved\n'; rc=1; }
assert_eq "$INDEX_SHA" "$(shasum -a 256 "$REST/gitdir/index" | cut -d' ' -f1)" "the restored git index is the original index" || rc=1

if [ "$rc" -eq 0 ]; then
    ok "R6   committed, staged, dirty, untracked and ignored content plus the git index are preserved, and a restore reproduces every byte — the quarantine keeps the tree and the tip stays reachable"
else
    bad "R6   preservation or restoration did not reproduce the workspace"
fi

# ==========================================================================
# ROW 7 — "Preservation or quarantine fails. Required result: original
#          workspace remains available. No success report."
# ==========================================================================
echo "--- ROW 7: preservation fails, quarantine fails ---"

# 7a. Preservation cannot be written: the preservation directory is read-only
# while everything else (the lock, the record) still works, so the failure is
# the one this row names and not an earlier one wearing its label.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
mkdir -p "$RICHOS_WORKSPACE_RETIRE_DIR/preserved"
chmod 500 "$RICHOS_WORKSPACE_RETIRE_DIR/preserved"
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
RC=$?
chmod 700 "$RICHOS_WORKSPACE_RETIRE_DIR/preserved"
assert_eq "4" "$RC" "a failed preservation exits 4, not 0" || rc=1
assert_contains "$OUT" "preservation-failed" "preservation failure reason code" || rc=1
assert_contains "$OUT" '"outcome": "failed"' "the outcome is failed, not a success report" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is still at its own path" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "the workspace is byte-for-byte untouched" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R7a  when preservation cannot be written the workspace is left exactly where it was and the outcome is 'failed' — no success is reported"
else
    bad "R7a  a failed preservation did not leave the workspace intact, or reported success"
fi

# 7b. The quarantine rename cannot be performed: the container is read-only.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
chmod 500 "$CONTAINER"
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
RC=$?
chmod 700 "$CONTAINER"
assert_eq "4" "$RC" "a failed quarantine exits 4, not 0" || rc=1
assert_contains "$OUT" "quarantine-failed" "quarantine failure reason code" || rc=1
assert_contains "$OUT" "UNCHANGED and still available" "the outcome says where the workspace is" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is still at its own path" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "the workspace is byte-for-byte untouched" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R7b  when the quarantine rename fails the workspace remains available at its own path and the outcome is 'failed'"
else
    bad "R7b  a failed quarantine reported success or damaged the workspace"
fi

# ==========================================================================
# ROW 8 — "Request is repeated after successful retirement. Required result:
#          accurate already-retired result. No action against a replacement
#          workspace at the same path."
# ==========================================================================
echo "--- ROW 8: repeated requests and a replacement at the same path ---"

new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "first retirement succeeds" || rc=1
assert_contains "$OUT" '"outcome": "quarantined"' "first outcome is quarantined" || rc=1

OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "a repeat is not an error" || rc=1
assert_contains "$OUT" '"outcome": "already-retired"' "repeat outcome is already-retired" || rc=1
assert_ne "quarantined" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["outcome"])' 2>/dev/null)" "a repeat does not claim a second quarantine" || rc=1

# A REPLACEMENT workspace now occupies the same path.
git -C "$OWNER_REPO" worktree add -q -b alpha-replacement "$CONTAINER/alpha"
printf 'replacement payload\n' >"$CONTAINER/alpha/replacement.txt"
L record registered --teammate zach-replacement --agent-id "0f0f0f0f0f0f0f0f" \
    --session-id sess-r --repo "$OWNER_REPO" --worktree "$CONTAINER/alpha" \
    --branch alpha-replacement --class hand-rolled
L record terminated --agent-id "0f0f0f0f0f0f0f0f" --worktree "$CONTAINER/alpha" \
    --reason "test fixture: witnessed termination" --witness "test"
REPLACEMENT="$(snapshot "$CONTAINER/alpha")"
REPLACEMENT_INODE="$(inode_of "$CONTAINER/alpha")"

OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "the old ID against a reoccupied path is not an error" || rc=1
assert_contains "$OUT" "already-retired-path-reoccupied" "reoccupied reason code" || rc=1
assert_eq "$REPLACEMENT" "$(snapshot "$CONTAINER/alpha")" "the replacement workspace is byte-for-byte untouched" || rc=1
assert_eq "$REPLACEMENT_INODE" "$(inode_of "$CONTAINER/alpha")" "the replacement is the same filesystem object" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "R8   a repeat reports already-retired accurately, and the same ID against a path that a REPLACEMENT workspace now occupies takes no action against it"
else
    bad "R8   a repeat mis-reported, or acted against a replacement workspace"
fi

# ==========================================================================
# ROW 9 — "Agent tries another interpreter, subprocess or direct filesystem
#          API. Required result: OS boundary still denies writes outside its
#          authority."
# ==========================================================================
echo "--- ROW 9: the OS authority boundary ---"

notcovered "R9   OS boundary denies writes outside an agent's authority" \
"NOT BUILT, and deliberately. The diagnosis's 'Enforced authority boundary'
           section specifies kernel-enforced restriction of agent processes plus a
           separate privileged workspace service. It is platform architecture, its
           worked example (Landlock) is Linux and this machine is a Mac, and it needs
           a decision that has not been made. NOTHING in this module can make this row
           pass: any check it ran would be a check of itself. The half that IS in this
           module's power is asserted immediately below."

# What this module CAN prove: it holds no code path that erases anything
# outside the retention sweep, and the sweep's target is never caller-supplied.
rc=0
# Match CALL SITES — `name(` — not the word. The first version of this scan
# matched the module docstring's own sentence "no `rm`, no `rmtree`", which is
# a scan finding the promise instead of the thing promised.
ERASERS="$(grep -n 'shutil\.rmtree(\|os\.remove(\|os\.unlink(\|shutil\.move(\|os\.rmdir(' "$LIB" || true)"
SWEEP_START="$(grep -n '^def sweep(' "$LIB" | cut -d: -f1)"
SWEEP_END="$(grep -n '^def list_workspaces(' "$LIB" | cut -d: -f1)"
OUTSIDE=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%:*}"
    if [ "$n" -lt "$SWEEP_START" ] || [ "$n" -gt "$SWEEP_END" ]; then
        OUTSIDE="$OUTSIDE$line
"
    fi
done <<EOF
$ERASERS
EOF
assert_eq "" "$(printf '%s' "$OUTSIDE" | tr -d '[:space:]')" "every erasing call in the module lives inside sweep()" || rc=1
a; [ -n "$ERASERS" ] || { printf '        ASSERT FAILED: found NO erasing calls at all — the scan matched nothing and would pass over a gutted file\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "R9-partial  the retirement module contains exactly one erasing call site and it is inside the retention sweep (the scan is proven non-empty, so it cannot pass by matching nothing)"
else
    bad "R9-partial  an erasing call exists outside the retention sweep"
fi

# ==========================================================================
# ROW 10 — "Agent tries to edit manager policy or erase recovery copies.
#           Required result: access denied."
# ==========================================================================
echo "--- ROW 10: recovery copies and manager policy ---"

notcovered "R10  access denied when policy or recovery copies are attacked" \
"NOT BUILT for the ACCESS-CONTROL half, for the same reason as row 9: denying
           an agent write access to the manager's own files requires the OS boundary
           and a privileged service outside agent authority. Both are excluded from
           this change. The BEHAVIORAL half — what the manager does when a recovery
           copy is missing or tampered with — is asserted immediately below, and it is
           the half that decides whether data is lost."

new_fixture
rc=0
export RICHOS_WORKSPACE_RETENTION_DAYS=0
OUT="$(H --workspace "$WS_ALPHA" --retention-days 0)"
assert_eq "0" "$?" "retirement succeeds" || rc=1
QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
ARCHIVE="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["preservation"]["archive"])' 2>/dev/null)"
QSNAP="$(snapshot "$QPATH")"

# 10a. The recovery copy is ERASED. The sweep must keep the quarantine, which
# is now the only copy, rather than complete the deletion.
mv "$ARCHIVE" "$ARCHIVE.stolen"
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" "no-preservation" "the sweep names the missing recovery copy" || rc=1
assert_dir "$QPATH" "the quarantine survives when its recovery copy is gone" || rc=1
assert_eq "$QSNAP" "$(snapshot "$QPATH")" "the quarantine is byte-for-byte intact" || rc=1

# 10b. The recovery copy is TAMPERED WITH. The sweep must refuse on the
# digest, not on the file merely existing.
mv "$ARCHIVE.stolen" "$ARCHIVE"
python3 - "$ARCHIVE" <<'PY'
import os, sys
# Flip one byte deep inside the archive: it is still a readable tar, and every
# member is still present. Only the DIGEST catches this.
with open(sys.argv[1], "r+b") as f:
    f.seek(os.path.getsize(sys.argv[1]) // 2)
    b = f.read(1)
    f.seek(os.path.getsize(sys.argv[1]) // 2)
    f.write(bytes([b[0] ^ 0xFF]))
PY
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" "preservation-unverifiable" "the sweep re-verifies the archive rather than trusting its existence" || rc=1
assert_dir "$QPATH" "the quarantine survives a tampered recovery copy" || rc=1
assert_eq "$QSNAP" "$(snapshot "$QPATH")" "the quarantine is byte-for-byte intact" || rc=1
unset RICHOS_WORKSPACE_RETENTION_DAYS
if [ "$rc" -eq 0 ]; then
    ok "R10-partial  erasing or tampering with the recovery copy does not let the retention sweep complete — the quarantine is kept, byte-identical, in both cases"
else
    bad "R10-partial  a missing or tampered recovery copy did not stop the sweep"
fi

# ==========================================================================
# REQUIREMENT 6 — retention actually retains, and the sweep erases only what
# this module minted. (The row above proves the refusals; this proves the
# positive, so that a sweep which never erases anything cannot pass.)
# ==========================================================================
echo "--- retention: the sweep retains, then erases, and only its own names ---"

new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "retirement succeeds" || rc=1
QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
SOUT="$(R sweep --execute)"
assert_contains "$SOUT" "within-retention" "the default retention holds the quarantine" || rc=1
assert_dir "$QPATH" "the quarantine survives inside its retention period" || rc=1

# A decoy that the sweep has no record of, sitting right beside the quarantine.
mkdir -p "$CONTAINER/decoy"
printf 'decoy\n' >"$CONTAINER/decoy/keep.txt"
DECOY="$(snapshot "$CONTAINER/decoy")"

SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" "erased" "retention elapsed, the quarantine is erased" || rc=1
assert_absent "$QPATH" "the quarantine is gone once retention elapsed" || rc=1
assert_eq "$DECOY" "$(snapshot "$CONTAINER/decoy")" "a directory the sweep has no record of is untouched" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "the sibling workspace is untouched by the sweep" || rc=1
a
ARCHIVE="$(R records "$WS_ALPHA" | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin) if r.get("outcome")=="quarantined"]; print(rs[-1]["preservation"]["archive"])' 2>/dev/null)"
[ -f "$ARCHIVE" ] || { printf '        ASSERT FAILED: the verified archive did not survive the sweep\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "RET  the quarantine is RETAINED inside its period and erased after it, the verified archive outlives the erase, and an unrecorded sibling directory is never touched"
else
    bad "RET  retention did not retain, did not expire, or the sweep reached beyond its own records"
fi

# ==========================================================================
# REQUIREMENT 7 — branch deletion is SEPARATE, with its own retention and
# reachability checks.
# ==========================================================================
echo "--- branch retirement: separate, retained, and reachability-checked ---"

new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "retirement succeeds" || rc=1
ALPHA_TIP="$(git -C "$OWNER_REPO" rev-parse refs/heads/alpha)"
assert_ne "" "$ALPHA_TIP" "the branch still exists after workspace retirement" || rc=1
assert_contains "$OUT" '"deleted": false' "the retirement record says the branch was not deleted" || rc=1

BOUT="$(R retire-branch "$WS_ALPHA")"
assert_eq "3" "$?" "branch deletion inside its retention refuses" || rc=1
assert_contains "$BOUT" "within-retention" "branch retention reason code" || rc=1
assert_eq "$ALPHA_TIP" "$(git -C "$OWNER_REPO" rev-parse refs/heads/alpha)" "the branch is untouched" || rc=1

BACKUP_REF="$(R records "$WS_ALPHA" | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin) if r.get("outcome")=="quarantined"]; print(rs[-1]["branch"]["backup_ref"])' 2>/dev/null)"
git -C "$OWNER_REPO" update-ref -d "$BACKUP_REF"
BOUT="$(R retire-branch "$WS_ALPHA" --retention-days 0)"
assert_eq "3" "$?" "branch deletion without its backup ref refuses" || rc=1
assert_contains "$BOUT" "backup-ref-missing" "missing backup ref reason code" || rc=1
assert_eq "$ALPHA_TIP" "$(git -C "$OWNER_REPO" rev-parse refs/heads/alpha)" "the branch survives the refusal" || rc=1

git -C "$OWNER_REPO" update-ref "$BACKUP_REF" "$ALPHA_TIP"
git -C "$OWNER_REPO" branch -f alpha "$(git -C "$OWNER_REPO" rev-parse HEAD)"
BOUT="$(R retire-branch "$WS_ALPHA" --retention-days 0)"
assert_eq "3" "$?" "a branch that moved after retirement refuses" || rc=1
assert_contains "$BOUT" "branch-moved" "moved branch reason code" || rc=1

git -C "$OWNER_REPO" branch -f alpha "$ALPHA_TIP"
BOUT="$(R retire-branch "$WS_ALPHA" --retention-days 0)"
assert_eq "0" "$?" "with retention elapsed and the tip preserved, deletion proceeds" || rc=1
assert_contains "$BOUT" "branch-deleted" "deletion reason code" || rc=1
a
git -C "$OWNER_REPO" show-ref --verify --quiet refs/heads/alpha && {
    printf '        ASSERT FAILED: the branch was not deleted\n'; rc=1; }
assert_eq "$ALPHA_TIP" "$(git -C "$OWNER_REPO" rev-parse "$BACKUP_REF")" "the tip stays reachable from the backup ref after the branch is gone" || rc=1
a
git -C "$OWNER_REPO" cat-file -e "$ALPHA_TIP^{commit}" 2>/dev/null || {
    printf '        ASSERT FAILED: the commit object did not survive branch deletion\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "BR   branch deletion is a separate operation with its own retention, refuses without a backup ref or after the branch moved, and when it proceeds the tip stays reachable"
else
    bad "BR   branch retirement did not hold its own retention and reachability checks"
fi

# ==========================================================================
# REQUIREMENT 8 — structured outcomes, distinguishing all four cases and
# recording the exact workspace identity and preservation result.
# ==========================================================================
echo "--- structured outcomes ---"

new_fixture
rc=0
CHECK='
import json, sys
d = json.loads(sys.stdin.read())
want_outcome, want_code = sys.argv[1], sys.argv[2]
assert d.get("outcome") == want_outcome, "outcome %r != %r" % (d.get("outcome"), want_outcome)
assert want_code in (d.get("reason_code") or ""), "reason_code %r lacks %r" % (d.get("reason_code"), want_code)
assert (d.get("workspace") or {}).get("id"), "no workspace identity recorded"
assert d.get("reason"), "no reason recorded"
print("ok")
'
OUT="$(H --workspace "ws-0123456789abcdef")"
a; printf '%s' "$OUT" | python3 -c "$CHECK" refused unknown-workspace >/dev/null 2>&1 \
    || { printf '        ASSERT FAILED: refusal is not structured\n'; rc=1; }
OUT="$(H --workspace "$WS_ALPHA" --dry-run)"
a; printf '%s' "$OUT" | python3 -c "$CHECK" ok would-retire >/dev/null 2>&1 \
    || { printf '        ASSERT FAILED: dry-run is not structured\n'; rc=1; }
assert_dir "$CONTAINER/alpha" "a dry run mutates nothing" || rc=1
OUT="$(H --workspace "$WS_ALPHA")"
a; printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["outcome"] == "quarantined"
assert d["workspace"]["id"].startswith("ws-")
assert d["workspace"]["path"] and d["workspace"]["repo"]
assert d["preservation"]["status"] == "verified"
assert d["quarantine"]["path"] and d["quarantine"]["retain_until"]
assert d["branch"]["backup_ref"]
assert d["liveness"]["verdict"] == "NOT-ALIVE"
print("ok")
' >/dev/null 2>&1 || { printf '        ASSERT FAILED: the quarantined outcome is missing required fields\n'; rc=1; }
OUT="$(H --workspace "$WS_ALPHA")"
a; printf '%s' "$OUT" | python3 -c "$CHECK" already-retired already-retired >/dev/null 2>&1 \
    || { printf '        ASSERT FAILED: already-retired is not structured\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "SO   refused / dry-run / quarantined / already-retired each return a distinct structured outcome carrying the exact workspace identity, the liveness verdict and the preservation result"
else
    bad "SO   the structured outcomes do not distinguish the four cases"
fi

# ==========================================================================
# The reaper's route through the legacy mode must still work — the reaper's
# own 43-case suite depends on it, and a helper that only refuses is a helper
# that broke its caller.
# ==========================================================================
echo "--- the legacy route still removes a real registered worktree ---"

new_fixture
rc=0
OUT="$(H --owner "$ALPHA_AGENT" --repo "$OWNER_REPO" --branch alpha --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "legacy removal of a registered worktree still succeeds" || rc=1
assert_contains "$OUT" "removed agent worktree" "legacy success message" || rc=1
assert_absent "$CONTAINER/alpha" "the registered worktree was removed" || rc=1
assert_eq "$BEFORE_BETA" "$(snapshot "$CONTAINER/beta")" "the sibling is untouched" || rc=1
a
git -C "$OWNER_REPO" show-ref --verify --quiet refs/heads/alpha && {
    printf '        ASSERT FAILED: --branch did not delete the branch\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "LEG  the legacy route the reaper calls still removes a genuinely registered worktree and its branch — the repair refuses the unknown, not the known"
else
    bad "LEG  the legacy route stopped working for a registered worktree"
fi

# ==========================================================================
# THE 2026-09-06 REVIEW — three findings the first fix missed, each
# reproduced by the reviewer's script against c3e52af, each closed here.
#
# Source: richos-hq docs/verification/worktree-removal-fix-review-2026-09-06/
# (README.md, reproduce.py, results.json). The reviewer's script is vendored
# beside this suite as workspace-retire.review-2026-09-06.py with ONE changed
# line (ENGINE) and is run verbatim in the last row of this section. The rows
# before it are the same three probes expressed in this suite's own fixtures,
# plus the negative and positive controls the reviewer's script does not carry.
#
# THE GENERAL RULE THESE ROWS HOLD THE CODE TO: a NOT-ALIVE that rests on
# ABSENCE — an unregistered owner, a missing record, no lifecycle event — is
# not evidence of death and never authorizes a destructive act. Only positive
# evidence may, and only for an owner BOUND to the path.
# ==========================================================================
echo "--- REVIEW 2026-09-06, finding 1: the legacy route and the unbound owner ---"

# The resolver's own word for the fixture's owner, read directly and not
# through the code under test. A refusal row whose owner was not actually
# alive would be proving the wrong thing.
resolver_verdict() { # <entity> <agent-id>
    python3 "$SCRIPT_DIR/agent-liveness.py" --entity "$1" --owner "$2" --format triple 2>/dev/null | cut -f1
}

# --- F1-control. THE NEGATIVE CONTROL: the helper as it stood at the reviewed
# revision (c3e52af) DOES delete a live worker's registered worktree on a
# bogus owner. Without this, F1a would be a refusal over a fixture nobody
# proved destructible.
LIVE_PID=""
new_fixture --alive
printf 'only copy of live work\n' >"$CONTAINER/alpha/uncommitted.txt"
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
NATIVE_ALPHA="$ENTITY/.claude/worktrees/agent-$ALPHA_AGENT"
REV_DIR="$FX/reviewed-revision"
mkdir -p "$REV_DIR/lib"
cp "$SCRIPT_DIR/agent-liveness.sh" "$SCRIPT_DIR/agent-liveness.py" \
   "$SCRIPT_DIR/resolve-roots.sh" "$SCRIPT_DIR/worktree-ledger.py" "$REV_DIR/lib/" 2>/dev/null
REV_SH="$REV_DIR/remove-agent-worktree.sh"
if git -C "$SCRIPT_DIR" cat-file -e 'c3e52afe4ac1dda240cae987f1fd14426f24c3d6:engine/scripts/remove-agent-worktree.sh' 2>/dev/null; then
    git -C "$SCRIPT_DIR" show 'c3e52afe4ac1dda240cae987f1fd14426f24c3d6:engine/scripts/remove-agent-worktree.sh' >"$REV_SH"
    chmod +x "$REV_SH"
    rc=0
    assert_eq "ALIVE" "$(resolver_verdict "$ENTITY" "$ALPHA_AGENT")" "the fixture's real owner is ALIVE by the resolver's own word" || rc=1
    REV_OUT="$(bash "$REV_SH" --entity-repo "$ENTITY" --repo "$OWNER_REPO" \
        --owner never-registered --force "$CONTAINER/alpha" 2>&1)"
    REV_RC=$?
    assert_eq "0" "$REV_RC" "the reviewed revision reported SUCCESS" || rc=1
    assert_contains "$REV_OUT" "confirmed not alive" "it called a nonexistent owner 'confirmed not alive'" || rc=1
    assert_absent "$CONTAINER/alpha" "it DELETED the live worker's workspace" || rc=1
    assert_dir "$NATIVE_ALPHA" "while the real owner's isolation worktree stood locked beside it" || rc=1
    if [ "$rc" -eq 0 ]; then
        ok "F1-control  NEGATIVE CONTROL — the helper at the reviewed revision c3e52af deletes a live worker's registered worktree on a bogus owner and exits 0 (the reviewer's finding 1, reproduced)"
    else
        bad "F1-control  the reviewed revision did not reproduce finding 1 — F1a below would be proving nothing"
    fi
else
    notcovered "F1-control  negative control against the reviewed revision" \
        "the object c3e52af:engine/scripts/remove-agent-worktree.sh is not in this clone's history, so the destructibility of the fixture could not be shown from the code that had the defect."
fi
if [ -n "${LIVE_PID:-}" ]; then kill "$LIVE_PID" 2>/dev/null; fi

# --- F1a. THE REVIEWER'S PROBE: a live worker's registered worktree, a bogus
# owner. Refused, before mutation, with the uncommitted file intact.
LIVE_PID=""
new_fixture --alive
printf 'only copy of live work\n' >"$CONTAINER/alpha/uncommitted.txt"
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
NATIVE_ALPHA="$ENTITY/.claude/worktrees/agent-$ALPHA_AGENT"
rc=0
assert_eq "ALIVE" "$(resolver_verdict "$ENTITY" "$ALPHA_AGENT")" "the real owner is ALIVE" || rc=1
OUT="$(H --repo "$OWNER_REPO" --owner never-registered --force "$CONTAINER/alpha")"
RC=$?
assert_eq "3" "$RC" "refused (exit 3)" || rc=1
assert_contains "$OUT" "owner-unbound" "the reason is the UNBOUND owner, not a liveness guess" || rc=1
a; case "$OUT" in *"removed agent worktree"*) printf '        ASSERT FAILED: a success line was printed\n'; rc=1 ;; esac
assert_dir "$CONTAINER/alpha" "the workspace is still there" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "byte-for-byte, uncommitted file included" || rc=1
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git still registers it" || rc=1
assert_dir "$NATIVE_ALPHA" "the owner's isolation worktree is untouched" || rc=1
# --- F1b. Same fixture, the REAL owner asserted: refused because ALIVE.
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "3" "$?" "the real owner, alive, refuses too" || rc=1
assert_contains "$OUT" "owner-alive" "alive reason code" || rc=1
assert_contains "$OUT" "ALIVE" "the banner carries the verdict word" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "still byte-for-byte" || rc=1
if [ -n "${LIVE_PID:-}" ]; then kill "$LIVE_PID" 2>/dev/null; fi
if [ "$rc" -eq 0 ]; then
    ok "F1a/b  a bogus owner against a live worker's registered worktree is REFUSED as owner-unbound before mutation, and the real owner is refused as ALIVE — the uncommitted file, the registration and the isolation worktree are untouched"
else
    bad "F1a/b  the legacy route acted on, or misdescribed, a live worker's workspace"
fi

# --- F1c. THE GENERAL RULE, not the case: an owner the record DOES bind to the
# path, whose only evidence is absence (no isolation worktree, host session
# still running) — refused as INDETERMINATE. Then the POSITIVE control: a
# witnessed termination on record, same fixture, and the removal proceeds.
new_fixture --indeterminate
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner eeee5555ffff6666 --force "$CONTAINER/alpha")"
assert_eq "3" "$?" "absence-only evidence refuses" || rc=1
assert_contains "$OUT" "owner-indeterminate" "indeterminate reason code" || rc=1
assert_contains "$OUT" "absence is not a termination signal" "the refusal names the doctrine" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "alpha untouched" || rc=1
L record terminated --agent-id eeee5555ffff6666 --worktree "$CONTAINER/alpha" \
    --reason "test fixture: witnessed termination" --witness test
L record terminated --agent-id "$ALPHA_AGENT" --worktree "$CONTAINER/alpha" \
    --reason "test fixture: witnessed termination" --witness test
OUT="$(H --repo "$OWNER_REPO" --owner eeee5555ffff6666 --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "with a witnessed termination on record the same request proceeds" || rc=1
assert_contains "$OUT" "removed agent worktree" "success line" || rc=1
assert_absent "$CONTAINER/alpha" "the worktree was removed" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F1c   an owner the record binds to the path is still refused while its only evidence is ABSENCE, and the identical request proceeds once a witnessed termination is on record — the refusal was the evidence, not something else"
else
    bad "F1c   absence-only evidence authorized a removal, or positive evidence did not"
fi

# --- F1d. NO record, NO isolation worktree, an owner nobody can bind: refused
# whatever the owner string is. And the one binding that needs no record —
# the agent's OWN isolation worktree, registered and unlocked — proceeds and
# is copied to the ownership ledger as a witnessed termination.
new_fixture
git -C "$OWNER_REPO" worktree add -q -b delta "$CONTAINER/delta"
printf 'delta payload\n' >"$CONTAINER/delta/delta.txt"
BEFORE_DELTA="$(snapshot "$CONTAINER/delta")"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner agent-nobody --force "$CONTAINER/delta")"
assert_eq "3" "$?" "an unbindable owner refuses" || rc=1
assert_contains "$OUT" "owner-unbound" "unbound reason code" || rc=1
assert_eq "$BEFORE_DELTA" "$(snapshot "$CONTAINER/delta")" "delta untouched" || rc=1
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/delta")"
assert_eq "3" "$?" "a real, terminated owner asserted against a path it does not own refuses" || rc=1
assert_contains "$OUT" "owner-unbound" "still unbound: the owner's state says nothing about THIS path" || rc=1
assert_eq "$BEFORE_DELTA" "$(snapshot "$CONTAINER/delta")" "delta still untouched" || rc=1
mkdir -p "$ENTITY/.claude/worktrees"
git -C "$ENTITY" worktree add -q -b worktree-agent-0a0a0a0a0b0b0b0b "$ENTITY/.claude/worktrees/agent-0a0a0a0a0b0b0b0b"
OUT="$(H --owner 0a0a0a0a0b0b0b0b --force "$ENTITY/.claude/worktrees/agent-0a0a0a0a0b0b0b0b")"
assert_eq "0" "$?" "the agent's own unlocked isolation worktree is removed" || rc=1
assert_contains "$OUT" "observed-isolation-worktree" "the basis is an OBSERVATION of this very directory" || rc=1
assert_absent "$ENTITY/.claude/worktrees/agent-0a0a0a0a0b0b0b0b" "gone" || rc=1
a; grep -q '"agent_id": "0a0a0a0a0b0b0b0b"' "$LEDGER" && grep -q '"witness": "remove-agent-worktree"' "$LEDGER" \
    || { printf '        ASSERT FAILED: the observed verdict was not copied to the ownership ledger\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "F1d   with no record and no isolation worktree NO owner string authorizes anything — not a nonsense one, not a real terminated agent asserted against somebody else's path — while an agent's own unlocked isolation worktree is removed on that observation and the observation is written to the ledger"
else
    bad "F1d   an unbound owner was accepted, or the native binding failed"
fi

# --- F1e. --force PRESERVES before it destroys. The legacy route's `--force`
# is what lets git delete dirty and untracked content; the reviewer required
# the same preservation transaction as retirement. Restore reproduces it.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "forced legacy removal succeeds" || rc=1
JSON="$(printf '%s\n' "$OUT" | python3 -c 'import sys,json; s=sys.stdin.read(); i=s.index("{"); j=s.rindex("}")+1; print(s[i:j])' 2>/dev/null)"
assert_eq "verified" "$(jf "$JSON" preservation.status)" "the tree was preserved and VERIFIED before removal" || rc=1
assert_eq "complete" "$(jf "$JSON" journal)" "the completion record landed" || rc=1
assert_absent "$CONTAINER/alpha" "the worktree is gone" || rc=1
REST="$FX/restored-legacy"
ROUT="$(R restore "$WS_ALPHA" "$REST")"
assert_eq "0" "$?" "restore from a legacy removal's archive succeeds" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$REST/workspace")" "every byte of the removed tree — staged, dirty, untracked, ignored — comes back" || rc=1
N_INTENT="$(R records "$WS_ALPHA" | python3 -c 'import json,sys; rs=json.load(sys.stdin); print(sum(1 for r in rs if r.get("operation")=="remove" and r.get("outcome")=="in-progress"))')"
assert_eq "1" "$N_INTENT" "exactly one remove-intent record precedes the completion" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F1e   a --force legacy removal preserves the tree (verified) before git destroys it, records intent and completion, and restore reproduces every byte"
else
    bad "F1e   a forced legacy removal did not preserve, or did not record — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

echo "--- REVIEW 2026-09-06, finding 2: worker startup after the last check ---"

# A python driver shared by F2a/F2b: it imports the library and schedules a
# REAL acquisition (a live native lock, a real ownership record, a real file)
# at the interleaving named by its first argument. Nothing about liveness is
# mocked; only WHEN the worker arrives is chosen.
race_driver() { # <inside-preserve|before-rename> <ws-id> <new-agent-id>
    python3 - "$LIB" "$LEDGER_PY" "$1" "$2" "$3" "$ENTITY" "$OWNER_REPO" "$CONTAINER/alpha" "$LEDGER" <<'PY'
import importlib.util, json, os, subprocess, sys
lib, ledger_py, when, wsid, new, entity, repo, work, ledger = sys.argv[1:10]
spec = importlib.util.spec_from_file_location("wr", lib)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def acquire():
    native = os.path.join(entity, ".claude", "worktrees", "agent-" + new)
    os.makedirs(os.path.dirname(native), exist_ok=True)
    subprocess.run(["git", "-C", entity, "worktree", "add", "-qb", "native-" + new, native], check=True)
    subprocess.run(["git", "-C", entity, "worktree", "lock", "--reason",
                    "claude agent agent-%s (pid %d start test)" % (new, os.getpid()), native], check=True)
    subprocess.run(["python3", ledger_py, "--ledger", ledger, "record", "registered", "--agent-id", new,
                    "--teammate", "zach-newcomer", "--session-id", "sess-new", "--repo", repo,
                    "--worktree", work, "--branch", "alpha", "--class", "hand-rolled"],
                   check=True, capture_output=True)
    with open(os.path.join(work, "new-live-work.txt"), "w") as f:
        f.write("written after the last check\n")

if when == "inside-preserve":
    real = m.preserve
    def wrapped(ws, target, dest):
        r = real(ws, target, dest)
        assert r["status"] == "verified", r
        acquire()
        return r
    m.preserve = wrapped
else:
    real_rename = m.FsTarget.rename_to
    def wrapped_rename(self, new_base):
        acquire()
        return real_rename(self, new_base)
    m.FsTarget.rename_to = wrapped_rename

res = m.retire(wsid, entity=entity, retention=0)
sweep = m.sweep(retention=0, execute=True)
print(json.dumps({"outcome": res.get("outcome"), "reason_code": res.get("reason_code"),
                  "reason": res.get("reason"), "sweep_actions": [i.get("action") for i in sweep["items"]]}))
PY
}

# --- F2a. THE REVIEWER'S INTERLEAVING: the worker acquires INSIDE preservation
# (after the under-lock check, before the rename). Layer one refuses; nothing
# is renamed; the worker's file is where it wrote it.
new_fixture
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
DRV="$(race_driver inside-preserve "$WS_ALPHA" 5555aaaa6666bbbb)"
assert_eq "refused" "$(jf "$DRV" outcome)" "retirement refused" || rc=1
assert_eq "reacquired" "$(jf "$DRV" reason_code)" "because the workspace was reacquired" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is at its own path" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "and is the same object" || rc=1
a; [ -f "$CONTAINER/alpha/new-live-work.txt" ] || { printf '        ASSERT FAILED: the worker'"'"'s file is not at the original path\n'; rc=1; }
assert_eq "written after the last check" "$(cat "$CONTAINER/alpha/new-live-work.txt" 2>/dev/null)" "with its bytes" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine directory exists\n'; rc=1; }
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git registrations unchanged" || rc=1
assert_eq "[]" "$(jf "$DRV" sweep_actions)" "the sweep found nothing to erase" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F2a   a worker that acquires the workspace INSIDE preservation is detected before the rename: retirement refuses (reacquired), nothing is renamed, the worker's new file is at the original path, and the sweep erases nothing"
else
    bad "F2a   a worker acquiring during preservation lost its work or its path — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

# --- F2b. THE TIGHTER WINDOW: the worker acquires between the LAST pre-rename
# check and the rename itself. Layer two catches it AFTER the rename and
# renames the directory BACK through the same parent descriptor.
new_fixture
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
DRV="$(race_driver before-rename "$WS_ALPHA" 7777aaaa8888bbbb)"
assert_eq "refused" "$(jf "$DRV" outcome)" "retirement refused" || rc=1
assert_eq "reacquired-after-quarantine" "$(jf "$DRV" reason_code)" "caught after the rename" || rc=1
assert_contains "$(jf "$DRV" reason)" "UNDONE" "the outcome says the rename was undone" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is back at its own path" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "the same object, renamed there and back" || rc=1
assert_eq "written after the last check" "$(cat "$CONTAINER/alpha/new-live-work.txt" 2>/dev/null)" "the worker's file rode along" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine directory remains\n'; rc=1; }
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git still registers the worktree (nothing was pruned)" || rc=1
assert_eq "[]" "$(jf "$DRV" sweep_actions)" "the sweep erases nothing: no completed quarantine is on record" || rc=1
N_INTENT="$(R records "$WS_ALPHA" | python3 -c 'import json,sys; rs=json.load(sys.stdin); print(sum(1 for r in rs if r.get("outcome")=="in-progress"))')"
assert_eq "1" "$N_INTENT" "the intent is on record" || rc=1
RECON="$(R reconcile)"
assert_eq "[]" "$(jf "$RECON" dangling)" "and reconcile shows it RESOLVED by the refusal record — nothing dangling" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F2b   a worker that acquires between the last check and the rename is caught AFTER the rename: the directory is renamed back (same inode), git still registers it, the worker's file is intact, and no completed quarantine exists for the sweep to erase"
else
    bad "F2b   an acquisition in the rename window was not undone — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

# --- F2c. THE BACKSTOP: the sweep erases only a quarantine whose every byte is
# in the verified archive. Content that appeared after preservation keeps it.
new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA" --retention-days 0)"
assert_eq "0" "$?" "retirement succeeds" || rc=1
QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
printf 'a late writer\n' >"$QPATH/late.txt"
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" "quarantine-diverged" "an extra file keeps the quarantine" || rc=1
assert_dir "$QPATH" "kept" || rc=1
rm -f "$QPATH/late.txt"
cp "$QPATH/untracked.txt" "$FX/untracked.orig"
printf 'changed after preservation\n' >>"$QPATH/untracked.txt"
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" "quarantine-diverged" "changed bytes keep the quarantine" || rc=1
assert_dir "$QPATH" "still kept" || rc=1
cp "$FX/untracked.orig" "$QPATH/untracked.txt"
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" '"action": "erased"' "with every byte covered, the erase proceeds" || rc=1
assert_absent "$QPATH" "erased" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F2c   the sweep refuses (quarantine-diverged) while the quarantine holds any byte the verified archive does not — an extra file, a changed file — and erases once it holds nothing more"
else
    bad "F2c   the sweep erased content the archive did not cover, or never erased at all"
fi

echo "--- REVIEW 2026-09-06, finding 3: the journal that would not take a record ---"

# --- F3a. THE REVIEWER'S PROBE: a read-only journal. Nothing moves, the
# outcome is failed, restore has nothing to find because nothing was retired.
# Then the positive control: writable journal, same fixture, retirement proceeds.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
mkdir -p "$RICHOS_WORKSPACE_RETIRE_DIR"
JOURNAL="$RICHOS_WORKSPACE_RETIRE_DIR/retirements.jsonl"
: >"$JOURNAL"
chmod 400 "$JOURNAL"
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
RC=$?
assert_eq "4" "$RC" "failed (exit 4), not success" || rc=1
assert_contains "$OUT" "journal-unwritable" "the reason is the journal" || rc=1
assert_contains "$OUT" '"outcome": "failed"' "outcome failed" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is at its own path" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "byte-for-byte" || rc=1
assert_eq "0" "$(stat -f %z "$JOURNAL" 2>/dev/null || stat -c %s "$JOURNAL")" "the journal is still empty" || rc=1
ROUT="$(R restore "$WS_ALPHA" "$FX/restored")"
assert_eq "3" "$?" "restore refuses" || rc=1
assert_contains "$ROUT" "no-retirement-record" "accurately: nothing was retired" || rc=1
chmod 600 "$JOURNAL"
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "with the journal writable the same retirement proceeds" || rc=1
assert_contains "$OUT" '"outcome": "quarantined"' "quarantined" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F3a   an unwritable journal fails the retirement BEFORE anything moves (outcome failed, workspace byte-identical, journal empty, restore accurately finds nothing), and the identical retirement proceeds once the journal is writable"
else
    bad "F3a   an unwritable journal was reported as a retirement, or the workspace moved"
fi

# --- F3b. THE COMPLETION record cannot be written AFTER the rename (the intent
# landed). The rename is UNDONE, the outcome is failed, git still registers
# the worktree, and reconcile shows the intent resolved as source-present.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
DRV="$(python3 - "$LIB" "$WS_ALPHA" "$ENTITY" <<'PY'
import importlib.util, json, sys
lib, wsid, entity = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("wr", lib)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = m.append_record
def failing(rec):
    # Only the COMPLETION record fails: the intent before it lands.
    if rec.get("operation") == "retire" and rec.get("outcome") == "quarantined":
        return False
    return real(rec)
m.append_record = failing
res = m.retire(wsid, entity=entity)
m.append_record = real
print(json.dumps({"outcome": res.get("outcome"), "stage": res.get("stage"),
                  "reason_code": res.get("reason_code"), "reason": res.get("reason")}))
PY
)"
assert_eq "failed" "$(jf "$DRV" outcome)" "outcome failed" || rc=1
assert_eq "journal-completion" "$(jf "$DRV" stage)" "at the completion write" || rc=1
assert_eq "journal-unwritable" "$(jf "$DRV" reason_code)" "reason code" || rc=1
assert_contains "$(jf "$DRV" reason)" "UNDONE" "the rename was undone" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is back at its own path" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "same object" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "byte-for-byte" || rc=1
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git still registers it — nothing was pruned" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine directory remains\n'; rc=1; }
RECON="$(R reconcile)"
assert_eq "1" "$(printf '%s' "$RECON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["dangling"]))')" "reconcile lists the one dangling intent" || rc=1
assert_contains "$RECON" "source-present" "and says the workspace is at its own path" || rc=1
ROUT="$(R restore "$WS_ALPHA" "$FX/restored-from-intent")"
assert_eq "0" "$?" "restore finds the archive through the INTENT record" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$FX/restored-from-intent/workspace")" "and reproduces the tree" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F3b   when the completion record cannot be written after the rename, the rename is undone (same inode, git registration intact, nothing pruned), the outcome is failed, reconcile names the dangling intent as source-present, and restore still finds the verified archive through the intent"
else
    bad "F3b   a lost completion record left the workspace moved, or reported success — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

# --- F3c. The sweep records BEFORE it erases; a journal that will not take the
# record erases nothing.
new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA" --retention-days 0)"
assert_eq "0" "$?" "retirement succeeds" || rc=1
QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
JOURNAL="$RICHOS_WORKSPACE_RETIRE_DIR/retirements.jsonl"
chmod 400 "$JOURNAL"
SOUT="$(R sweep --retention-days 0 --execute)"
chmod 600 "$JOURNAL"
assert_contains "$SOUT" "journal-unwritable" "the sweep names the journal" || rc=1
assert_dir "$QPATH" "and erases nothing" || rc=1
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" '"action": "erased"' "writable again, the erase proceeds" || rc=1
assert_absent "$QPATH" "erased" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F3c   the sweep erases nothing it cannot first put on record, and erases once it can"
else
    bad "F3c   the sweep erased without a record"
fi

# --- F3d. The legacy route holds the same line: an unwritable journal fails
# the removal before anything is touched.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
mkdir -p "$RICHOS_WORKSPACE_RETIRE_DIR"
JOURNAL="$RICHOS_WORKSPACE_RETIRE_DIR/retirements.jsonl"
: >"$JOURNAL"
chmod 400 "$JOURNAL"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
RC=$?
chmod 600 "$JOURNAL"
assert_eq "4" "$RC" "failed (exit 4)" || rc=1
assert_contains "$OUT" "journal-unwritable" "the reason is the journal" || rc=1
assert_dir "$CONTAINER/alpha" "the worktree is still there" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "byte-for-byte" || rc=1
# The positive twin, same fixture: with the journal writable the identical
# request removes the worktree — so the refusal above was the journal and not
# some earlier gate wearing its label.
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "writable again, the identical removal proceeds" || rc=1
assert_absent "$CONTAINER/alpha" "and the worktree is gone" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "F3d   the legacy route removes nothing it cannot first put on record, and removes once it can"
else
    bad "F3d   the legacy route removed without a record, or never removed"
fi

echo "--- REVIEW 2026-09-06: the reviewer's own script, verbatim ---"

# The reviewer's reproduce.py, vendored beside this suite with one changed line
# (ENGINE points at the engine it ships with), run as the reviewer ran it and
# read as the reviewer said to read it: by the named outcomes, never the exit
# status. Its temporary root is placed inside this suite's sandbox.
REVIEW_PY="$SCRIPT_DIR/workspace-retire.review-2026-09-06.py"
rc=0
a; [ -f "$REVIEW_PY" ] || { printf '        ASSERT FAILED: the vendored reviewer script is missing at %s\n' "$REVIEW_PY"; rc=1; }
REVIEW_ORIG=/Users/alex/ab/richos-hq/docs/verification/worktree-removal-fix-review-2026-09-06/reproduce.py
if [ -f "$REVIEW_ORIG" ]; then
    # Counted as an assertion ONLY when the reviewer's original is here to
    # compare against. An absent reference is a note, never a pass.
    a; diff <(sed 1,12d "$REVIEW_PY" | grep -v '^ENGINE = ') <(grep -v '^ENGINE = ' "$REVIEW_ORIG") >/dev/null 2>&1 \
        || { printf '        ASSERT FAILED: the vendored script differs from the reviewer'"'"'s beyond the ENGINE line\n'; rc=1; }
else
    printf '        note: the reviewer'"'"'s original is not on this machine (%s); the vendored copy was not byte-compared to it in this run\n' "$REVIEW_ORIG"
fi
REVIEW_OUT="$(cd "$SANDBOX" && TMPDIR="$SANDBOX" PYTHONDONTWRITEBYTECODE=1 python3 "$REVIEW_PY" 2>&1)"
REVIEW_RC=$?
assert_eq "0" "$REVIEW_RC" "the reviewer's script ran to completion (its own asserts hold)" || rc=1
REVIEW_JSON="$(printf '%s\n' "$REVIEW_OUT" | sed -n '/^\[/,/^\]/p')"
REVIEW_ROOT="$(printf '%s\n' "$REVIEW_OUT" | sed -n 's/^Evidence: \(.*\)\/results.json$/\1/p')"
read_case() { # <case> <field>
    printf '%s' "$REVIEW_JSON" | python3 -c '
import json, sys
rs = json.loads(sys.stdin.read())
r = [x for x in rs if x.get("case") == sys.argv[1]][0]
v = r.get(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v))' "$1" "$2" 2>/dev/null
}
assert_eq "ALIVE" "$(read_case legacy_unknown_owner_live_target verified_liveness)" "case 1: the owner was verified ALIVE" || rc=1
assert_eq "3" "$(read_case legacy_unknown_owner_live_target exit)" "case 1: the helper refused (exit 3; was 0)" || rc=1
assert_eq "true" "$(read_case legacy_unknown_owner_live_target workspace_survived)" "case 1: the workspace survived (was false)" || rc=1
assert_eq "true" "$(read_case legacy_unknown_owner_live_target native_owner_workspace_survived)" "case 1: the owner's isolation worktree survived" || rc=1
assert_contains "$(read_case legacy_unknown_owner_live_target output)" "owner-unbound" "case 1: refused as owner-unbound" || rc=1
assert_eq "ALIVE" "$(read_case worker_acquires_after_last_liveness_check liveness_before_rename)" "case 2: the new worker was ALIVE before the rename" || rc=1
assert_eq "refused" "$(read_case worker_acquires_after_last_liveness_check outcome)" "case 2: retirement refused (was quarantined)" || rc=1
assert_eq "true" "$(read_case worker_acquires_after_last_liveness_check original_path_survived)" "case 2: the original path survived (was false)" || rc=1
assert_eq "[]" "$(read_case worker_acquires_after_last_liveness_check sweep)" "case 2: the sweep erased nothing (was one erase)" || rc=1
a; [ -f "$REVIEW_ROOT/startup-after-check/work/new-live-work.txt" ] \
    || { printf '        ASSERT FAILED: case 2: the new worker'"'"'s file is not at the original path (%s)\n' "$REVIEW_ROOT"; rc=1; }
assert_eq "failed" "$(read_case retirement_journal_unwritable outcome)" "case 3: outcome failed (was quarantined)" || rc=1
assert_eq "true" "$(read_case retirement_journal_unwritable workspace_survived_at_original_path)" "case 3: the workspace survived at its path (was false)" || rc=1
assert_eq "0" "$(read_case retirement_journal_unwritable journal_bytes)" "case 3: the journal is empty" || rc=1
assert_eq "refused" "$(read_case retirement_journal_unwritable restore_outcome)" "case 3: restore refuses — accurately, nothing was retired" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "REVIEW  the reviewer's reproduce.py, run verbatim: finding 1 refuses with the workspace intact, finding 2 refuses with the original path and the new worker's file intact and nothing swept, finding 3 fails with the workspace intact and nothing to restore — read by the named outcomes, as the reviewer specified"
else
    bad "REVIEW  the reviewer's script still reproduces at least one finding"
fi


# ==========================================================================
# THE SECOND 2026-09-06 REVIEW — three findings the second fix missed, each
# reproduced by the reviewer against 3aa3acb, each closed here — and the
# further instances of the same class this round went looking for.
#
# Source: richos-hq docs/verification/worktree-removal-fix-recheck-2026-09-06/
# (README.md, reproduce.py, results.json). The reviewer's script is vendored
# beside this suite as workspace-retire.recheck-2026-09-06.py with ONE changed
# line (ENGINE) and is run verbatim in the last row of this section.
#
# THE CLASS EVERY ROW HERE IS ABOUT: a destructive step trusting a fact
# established earlier, elsewhere, or about something else. A liveness verdict
# from before the archive. A clean `git status` read as "nothing to lose". A
# branch name trusted to belong to the workspace. A registration's absence
# read as "nobody's". A tip read a few lines before the delete.
#
# EVERY DESTRUCTIVE ROW HAS A NEGATIVE CONTROL against the library or helper
# as it stood at the reviewed revision 3aa3acb, so that a refusal below is a
# refusal over a fixture proven destructible by the code that had the defect.
# ==========================================================================
echo "--- RECHECK 2026-09-06, finding 1: acquisition during preservation, legacy route ---"

# The library and helper as the reviewer saw them, from git history, with the
# CURRENT sibling libraries (the reviewer ran them with the same siblings).
REVIEWED_REV=3aa3acbbe29ff9a2ae81ad9a55fa844cb1a2b857
reviewed_engine() { # -> prints the dir holding remove-agent-worktree.sh + lib/, or nothing
    local d="$FX/reviewed-3aa3acb"
    if ! git -C "$SCRIPT_DIR" cat-file -e "$REVIEWED_REV:engine/scripts/lib/workspace-retire.py" 2>/dev/null; then
        return 1
    fi
    mkdir -p "$d/lib"
    cp "$SCRIPT_DIR/agent-liveness.sh" "$SCRIPT_DIR/agent-liveness.py" \
       "$SCRIPT_DIR/resolve-roots.sh" "$SCRIPT_DIR/worktree-ledger.py" \
       "$SCRIPT_DIR/worktree-transactions.py" "$d/lib/" 2>/dev/null
    git -C "$SCRIPT_DIR" show "$REVIEWED_REV:engine/scripts/lib/workspace-retire.py" >"$d/lib/workspace-retire.py"
    git -C "$SCRIPT_DIR" show "$REVIEWED_REV:engine/scripts/remove-agent-worktree.sh" >"$d/remove-agent-worktree.sh"
    chmod +x "$d/remove-agent-worktree.sh"
    printf '%s\n' "$d"
}

# A python driver for the LEGACY route: imports the library at <lib>, runs
# remove_legacy() on alpha with the given owner, and schedules a REAL
# acquisition (a live native lock in the entity, a real ownership record, a
# real file) at the interleaving named by <when>: inside-preserve (the
# reviewer's), before-rename (the tighter window), branch-moves (the asserted
# branch is moved by a real git call immediately before the compare-and-
# delete), or none. Nothing about liveness is mocked; only WHEN is chosen.
legacy_driver() { # <lib> <when> <owner> <force 0|1> <branch> <new-agent-id>
    python3 - "$1" "$LEDGER_PY" "$2" "$3" "$4" "$5" "$6" "$ENTITY" "$OWNER_REPO" "$CONTAINER/alpha" "$LEDGER" <<'PY'
import importlib.util, json, os, subprocess, sys
lib, ledger_py, when, owner, force, branch, new, entity, repo, work, ledger = sys.argv[1:12]
spec = importlib.util.spec_from_file_location("wr", lib)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
observed = {}

def acquire():
    native = os.path.join(entity, ".claude", "worktrees", "agent-" + new)
    os.makedirs(os.path.dirname(native), exist_ok=True)
    subprocess.run(["git", "-C", entity, "worktree", "add", "-qb", "native-" + new, native], check=True)
    subprocess.run(["git", "-C", entity, "worktree", "lock", "--reason",
                    "claude agent agent-%s (pid %d start test)" % (new, os.getpid()), native], check=True)
    subprocess.run(["python3", ledger_py, "--ledger", ledger, "record", "registered", "--agent-id", new,
                    "--teammate", "zach-newcomer", "--session-id", "sess-new", "--repo", repo,
                    "--worktree", work, "--branch", "alpha", "--class", "hand-rolled"],
                   check=True, capture_output=True)
    with open(os.path.join(work, "new-live-work.txt"), "w") as f:
        f.write("only copy, written after the archive\n")
    # The REAL authority, asked at this exact moment, with the OLD owner: it
    # must say the workspace is ALIVE now. If it does not, the interleaving
    # proved nothing and the driver says so instead of recording an outcome.
    mod = m._ledger_module()
    auth = m.termination_authority(entity, repo, work, owner=owner, records=mod.read_all(),
                                   ledger_mod=mod, live_mod=mod._liveness_module())
    observed["authority_after_acquisition"] = auth.get("reason_code")
    observed["verdict_after_acquisition"] = auth.get("verdict")
    assert not auth["authorized"] and auth["verdict"] == "ALIVE", auth

if when == "inside-preserve":
    real = m.preserve
    def wrapped(ws, target, dest):
        r = real(ws, target, dest)
        assert r["status"] == "verified", r
        acquire()
        return r
    m.preserve = wrapped
elif when == "before-rename":
    real_rename = m.FsTarget.rename_to
    def wrapped_rename(self, new_base):
        acquire()
        return real_rename(self, new_base)
    m.FsTarget.rename_to = wrapped_rename
elif when == "branch-moves":
    real_git = m._git
    def moving_git(cwd, *args, **kw):
        if len(args) >= 2 and args[0] == "update-ref" and args[1] == "-d":
            # A REAL move of the branch, by git, between the tip read and the delete.
            other = subprocess.run(["git", "-C", repo, "rev-parse", "main"], capture_output=True, text=True).stdout.strip()
            subprocess.run(["git", "-C", repo, "branch", "-f", branch, other], check=True)
            observed["moved_to"] = other
        return real_git(cwd, *args, **kw)
    m._git = moving_git

res = m.remove_legacy(entity, repo, work, owner, force=(force == "1"), branch=branch)
sweep = m.sweep(retention=0, execute=True)
out = {"outcome": res.get("outcome"), "reason_code": res.get("reason_code"), "stage": res.get("stage"),
       "reason": res.get("reason"), "exit": res.get("exit"),
       "preservation_status": (res.get("preservation") or {}).get("status"),
       "archive": (res.get("preservation") or {}).get("archive"),
       "branch": res.get("branch"), "quarantine": res.get("quarantine"),
       "sweep_actions": [i.get("action") for i in sweep["items"]]}
out.update(observed)
print(json.dumps(out))
PY
}

# --- G1-control. THE NEGATIVE CONTROL: the library at the reviewed revision
# DOES lose the new worker's file on the reviewer's interleaving, exit ok.
new_fixture
rc=0
REV_DIR="$(reviewed_engine)" || REV_DIR=""
if [ -n "$REV_DIR" ]; then
    DRV="$(legacy_driver "$REV_DIR/lib/workspace-retire.py" inside-preserve "$ALPHA_AGENT" 1 "" 1111aaaa2222bbbb)"
    assert_eq "ALIVE" "$(jf "$DRV" verdict_after_acquisition)" "the authority said ALIVE after the acquisition" || rc=1
    assert_eq "ok" "$(jf "$DRV" outcome)" "the reviewed revision reported ok" || rc=1
    assert_eq "removed" "$(jf "$DRV" reason_code)" "and called it removed" || rc=1
    assert_absent "$CONTAINER/alpha" "it DELETED the workspace" || rc=1
    assert_absent "$CONTAINER/alpha/new-live-work.txt" "and the live worker's new file with it" || rc=1
    a; tar -tf "$(jf "$DRV" archive)" 2>/dev/null | grep -q 'new-live-work.txt' && { printf '        ASSERT FAILED: the new file IS in the archive, so nothing was lost\n'; rc=1; }
    if [ "$rc" -eq 0 ]; then
        ok "G1-control  NEGATIVE CONTROL — the library at the reviewed revision 3aa3acb deletes a workspace, and a file a live worker wrote into it after the archive, on the reviewer's interleaving (finding 1, reproduced)"
    else
        bad "G1-control  the reviewed revision did not reproduce finding 1 — G1a below would be proving nothing"
    fi
else
    notcovered "G1-control  negative control against the reviewed revision" \
        "the object 3aa3acb:engine/scripts/lib/workspace-retire.py is not in this clone's history."
fi

# --- G1a. THE REVIEWER'S INTERLEAVING against the current library: refused as
# reacquired BEFORE the rename; the workspace, its inode, its registration and
# the worker's file are all where they were; the archive exists and is named
# in the refusal (the reviewer's script reads it); the sweep erases nothing.
new_fixture
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
DRV="$(legacy_driver "$LIB" inside-preserve "$ALPHA_AGENT" 1 "" 3333aaaa4444bbbb)"
assert_eq "ALIVE" "$(jf "$DRV" verdict_after_acquisition)" "the authority said ALIVE after the acquisition" || rc=1
assert_eq "refused" "$(jf "$DRV" outcome)" "legacy removal refused" || rc=1
assert_eq "reacquired" "$(jf "$DRV" reason_code)" "because the workspace was reacquired" || rc=1
assert_eq "verified" "$(jf "$DRV" preservation_status)" "the refusal carries the verified preservation" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is at its own path" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "and is the same object" || rc=1
assert_eq "only copy, written after the archive" "$(cat "$CONTAINER/alpha/new-live-work.txt" 2>/dev/null)" "the worker's file, with its bytes" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine exists\n'; rc=1; }
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git registrations unchanged" || rc=1
assert_eq "[]" "$(jf "$DRV" sweep_actions)" "the sweep found nothing to erase" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G1a   a worker that acquires the workspace INSIDE preservation on the LEGACY route is caught before the rename: refused (reacquired), nothing renamed, the worker's file at the original path, git registration intact, nothing swept"
else
    bad "G1a   the legacy route lost a worker's post-archive work — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

# --- G1b. THE TIGHTER WINDOW on the legacy route: acquisition between the last
# pre-rename check and the rename itself. Caught after the rename; undone.
new_fixture
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
DRV="$(legacy_driver "$LIB" before-rename "$ALPHA_AGENT" 1 "" 5555aaaa6666bbbb)"
assert_eq "refused" "$(jf "$DRV" outcome)" "refused" || rc=1
assert_eq "reacquired-after-quarantine" "$(jf "$DRV" reason_code)" "caught after the rename" || rc=1
assert_contains "$(jf "$DRV" reason)" "UNDONE" "the rename was undone" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is back at its own path" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "the same object, renamed there and back" || rc=1
assert_eq "only copy, written after the archive" "$(cat "$CONTAINER/alpha/new-live-work.txt" 2>/dev/null)" "the worker's file rode along" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine remains\n'; rc=1; }
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git still registers the worktree (nothing was pruned)" || rc=1
assert_eq "[]" "$(jf "$DRV" sweep_actions)" "no completed quarantine for the sweep to erase" || rc=1
RECON="$(R reconcile)"
assert_eq "[]" "$(jf "$RECON" dangling)" "the intent is resolved by the refusal record — nothing dangling" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G1b   a worker that acquires between the last check and the rename on the LEGACY route is caught AFTER the rename: renamed back (same inode), git registration intact, the worker's file intact, intent resolved"
else
    bad "G1b   an acquisition in the legacy rename window was not undone — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

echo "--- RECHECK 2026-09-06, finding 2: ignored files, no --force, clean status ---"

# A fixture whose ONLY local content is an ignored file: git status is clean.
ignored_only_fixture() {
    new_fixture
    git -C "$CONTAINER/alpha" checkout -q -- committed.txt
    git -C "$CONTAINER/alpha" reset -q
    rm -f "$CONTAINER/alpha/staged.txt" "$CONTAINER/alpha/untracked.txt" "$CONTAINER/alpha/secret.ign" "$CONTAINER/alpha/link.txt"
    rm -rf "$CONTAINER/alpha/ignored"
    printf 'local-draft.txt\n' >>"$CONTAINER/alpha/.gitignore"
    git -C "$CONTAINER/alpha" add .gitignore
    git -C "$CONTAINER/alpha" commit -q -m "ignore local draft"
    printf 'only copy of a local draft\n' >"$CONTAINER/alpha/local-draft.txt"
}

# --- G2-control. THE NEGATIVE CONTROL: the reviewed helper, no --force, erases
# the ignored file and creates NO archive.
ignored_only_fixture
rc=0
REV_DIR="$(reviewed_engine)" || REV_DIR=""
if [ -n "$REV_DIR" ]; then
    assert_eq "" "$(git -C "$CONTAINER/alpha" status --porcelain=v1 --untracked-files=all)" "git status is clean (the precondition)" || rc=1
    REV_OUT="$(bash "$REV_DIR/remove-agent-worktree.sh" --entity-repo "$ENTITY" --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" "$CONTAINER/alpha" 2>&1)"
    assert_eq "0" "$?" "the reviewed helper exited 0" || rc=1
    assert_absent "$CONTAINER/alpha/local-draft.txt" "it ERASED the ignored file" || rc=1
    assert_eq "0" "$(find "$RICHOS_WORKSPACE_RETIRE_DIR" -name workspace.tar 2>/dev/null | wc -l | tr -d ' ')" "and created no archive at all" || rc=1
    if [ "$rc" -eq 0 ]; then
        ok "G2-control  NEGATIVE CONTROL — the helper at 3aa3acb erases an ignored file over a clean git status with no archive, exit 0 (finding 2, reproduced)"
    else
        bad "G2-control  the reviewed revision did not reproduce finding 2 — G2a below would be proving nothing"
    fi
else
    notcovered "G2-control  negative control against the reviewed revision" \
        "the object 3aa3acb:engine/scripts/remove-agent-worktree.sh is not in this clone's history."
fi

# --- G2a. The current helper, same fixture, no --force: quarantined with a
# verified archive that counts the ignored file; the file is byte-identical
# in the quarantine and comes back from restore.
ignored_only_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
assert_eq "" "$(git -C "$CONTAINER/alpha" status --porcelain=v1 --untracked-files=all)" "git status is clean (the precondition)" || rc=1
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" "$CONTAINER/alpha")"
assert_eq "0" "$?" "exit 0" || rc=1
JSON="$(printf '%s\n' "$OUT" | python3 -c 'import sys; s=sys.stdin.read(); i=s.index("{"); j=s.rindex("}")+1; print(s[i:j])' 2>/dev/null)"
assert_eq "quarantined" "$(jf "$JSON" outcome)" "outcome quarantined" || rc=1
assert_eq "verified" "$(jf "$JSON" preservation.status)" "preserved and verified" || rc=1
a; [ "$(jf "$JSON" preservation.counts.ignored)" -ge 1 ] 2>/dev/null || { printf '        ASSERT FAILED: the archive counts no ignored file\n'; rc=1; }
QPATH="$(jf "$JSON" quarantine.path)"
assert_dir "$QPATH" "the quarantine exists" || rc=1
assert_eq "only copy of a local draft" "$(cat "$QPATH/local-draft.txt" 2>/dev/null)" "the ignored file is in the quarantine, byte for byte" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$QPATH")" "the whole tree is in the quarantine, byte for byte" || rc=1
assert_absent "$CONTAINER/alpha" "the original path is vacated" || rc=1
a; git -C "$OWNER_REPO" worktree list --porcelain | grep -qxF "worktree $CONTAINER/alpha" && { printf '        ASSERT FAILED: git still registers the worktree\n'; rc=1; }
assert_eq "1" "$(find "$RICHOS_WORKSPACE_RETIRE_DIR" -name workspace.tar 2>/dev/null | wc -l | tr -d ' ')" "exactly one archive" || rc=1
ROUT="$(R restore "$WS_ALPHA" "$FX/restored-ignored")"
assert_eq "0" "$?" "restore succeeds" || rc=1
assert_eq "only copy of a local draft" "$(cat "$FX/restored-ignored/workspace/local-draft.txt" 2>/dev/null)" "and reproduces the ignored file" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G2a   an ordinary legacy removal (no --force) of a tree whose only local content is an IGNORED file preserves it: verified archive counting it, byte-identical in quarantine, restorable — the clean status decided nothing"
else
    bad "G2a   the legacy route erased or failed to preserve an ignored file — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

# --- G2b. Without --force a tree with MODIFIED or UNTRACKED paths is refused
# BEFORE preservation (no archive is made), exactly as `git worktree remove`
# would refuse it; the identical request with --force proceeds. The refusal
# is the flag and not some earlier gate wearing its label.
new_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" "$CONTAINER/alpha")"
assert_eq "3" "$?" "refused (exit 3)" || rc=1
assert_contains "$OUT" "dirty-without-force" "the reason is the missing --force over a dirty tree" || rc=1
assert_dir "$CONTAINER/alpha" "the workspace is still there" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "byte for byte" || rc=1
a; [ -z "$(quarantines_of "$CONTAINER" alpha)" ] || { printf '        ASSERT FAILED: a quarantine exists after a refusal\n'; rc=1; }
assert_eq "0" "$(find "$RICHOS_WORKSPACE_RETIRE_DIR" -name workspace.tar 2>/dev/null | wc -l | tr -d ' ')" "no archive: the refusal came before preservation" || rc=1
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "with --force the identical request proceeds" || rc=1
assert_contains "$OUT" '"outcome": "quarantined"' "quarantined" || rc=1
assert_absent "$CONTAINER/alpha" "and the path is vacated" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G2b   the legacy route without --force refuses a tree with modified or untracked paths before preservation (git's own rule, which the reaper relies on), and the identical request with --force quarantines it"
else
    bad "G2b   the dirty-without-force rule did not hold — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

echo "--- RECHECK 2026-09-06, finding 3: --branch names an unrelated branch ---"

unrelated_branch_fixture() { # creates refs/heads/unrelated-unmerged with its own commit; prints its tip
    new_fixture
    git -C "$OWNER_REPO" checkout -q -b unrelated-unmerged
    printf 'independent committed work\n' >"$OWNER_REPO/unrelated.txt"
    git -C "$OWNER_REPO" add unrelated.txt
    git -C "$OWNER_REPO" commit -q -m "unrelated work"
    UNRELATED_TIP="$(git -C "$OWNER_REPO" rev-parse HEAD)"
    git -C "$OWNER_REPO" checkout -q main
}

# --- G3-control. THE NEGATIVE CONTROL: the reviewed helper deletes the
# unrelated unmerged branch and leaves no ref protecting its tip.
unrelated_branch_fixture
rc=0
REV_DIR="$(reviewed_engine)" || REV_DIR=""
if [ -n "$REV_DIR" ]; then
    REV_OUT="$(bash "$REV_DIR/remove-agent-worktree.sh" --entity-repo "$ENTITY" --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --branch unrelated-unmerged --force "$CONTAINER/alpha" 2>&1)"
    assert_eq "0" "$?" "the reviewed helper exited 0" || rc=1
    a; git -C "$OWNER_REPO" show-ref --verify --quiet refs/heads/unrelated-unmerged && { printf '        ASSERT FAILED: the unrelated branch survived, so this control proves nothing\n'; rc=1; }
    assert_eq "" "$(git -C "$OWNER_REPO" for-each-ref --contains "$UNRELATED_TIP" --format='%(refname)')" "no ref protects the unrelated tip" || rc=1
    if [ "$rc" -eq 0 ]; then
        ok "G3-control  NEGATIVE CONTROL — the helper at 3aa3acb deletes an UNRELATED unmerged branch named by --branch and leaves its tip unreferenced, exit 0 (finding 3, reproduced)"
    else
        bad "G3-control  the reviewed revision did not reproduce finding 3 — G3a below would be proving nothing"
    fi
else
    notcovered "G3-control  negative control against the reviewed revision" \
        "the object 3aa3acb:engine/scripts/remove-agent-worktree.sh is not in this clone's history."
fi

# --- G3a. The current helper: --branch naming a branch that is not the one
# checked out at the path is refused BEFORE the lock — no archive, no backup
# ref, the workspace and the branch untouched.
unrelated_branch_fixture
BEFORE_ALPHA="$(snapshot "$CONTAINER/alpha")"
BEFORE_ALPHA_INODE="$(inode_of "$CONTAINER/alpha")"
BEFORE_REFS="$(refs_snapshot "$OWNER_REPO")"
BEFORE_WT="$(wt_snapshot "$OWNER_REPO")"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --branch unrelated-unmerged --force "$CONTAINER/alpha")"
assert_eq "3" "$?" "refused (exit 3)" || rc=1
assert_contains "$OUT" "branch-mismatch" "the reason is the branch that is not this workspace's" || rc=1
assert_eq "$UNRELATED_TIP" "$(git -C "$OWNER_REPO" rev-parse --verify --quiet refs/heads/unrelated-unmerged)" "the unrelated branch is at its tip" || rc=1
assert_eq "$BEFORE_REFS" "$(refs_snapshot "$OWNER_REPO")" "every ref unchanged — no backup ref was even written" || rc=1
assert_eq "$BEFORE_ALPHA" "$(snapshot "$CONTAINER/alpha")" "the workspace is byte for byte untouched" || rc=1
assert_eq "$BEFORE_ALPHA_INODE" "$(inode_of "$CONTAINER/alpha")" "and the same object" || rc=1
assert_eq "$BEFORE_WT" "$(wt_snapshot "$OWNER_REPO")" "git registrations unchanged" || rc=1
assert_eq "0" "$(find "$RICHOS_WORKSPACE_RETIRE_DIR" -name workspace.tar 2>/dev/null | wc -l | tr -d ' ')" "no archive: the refusal came before anything" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G3a   --branch naming a branch other than the one checked out at the path is REFUSED (branch-mismatch) before the lock: the unrelated branch, every ref, the workspace and its registration are untouched"
else
    bad "G3a   an unrelated branch was acted on, or the refusal came late — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

# --- G3b. The asserted branch IS the workspace's: deleted after the
# quarantine by COMPARE-AND-DELETE, tip reachable from the backup ref. Then
# the row that makes compare-and-delete load-bearing: a REAL move of the
# branch immediately before the delete leaves it in place (branch-moved).
new_fixture
ALPHA_TIP="$(git -C "$CONTAINER/alpha" rev-parse HEAD)"
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --branch alpha --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "exit 0" || rc=1
JSON="$(printf '%s\n' "$OUT" | python3 -c 'import sys; s=sys.stdin.read(); i=s.index("{"); j=s.rindex("}")+1; print(s[i:j])' 2>/dev/null)"
assert_eq "true" "$(jf "$JSON" branch.deleted)" "the workspace's own branch was deleted" || rc=1
assert_eq "branch-deleted" "$(jf "$JSON" branch.reason_code)" "by name" || rc=1
a; git -C "$OWNER_REPO" show-ref --verify --quiet refs/heads/alpha && { printf '        ASSERT FAILED: refs/heads/alpha still exists\n'; rc=1; }
assert_eq "$ALPHA_TIP" "$(git -C "$OWNER_REPO" rev-parse --verify --quiet "refs/richos/retired/$WS_ALPHA/alpha")" "the tip stays reachable from the backup ref" || rc=1
a; git -C "$OWNER_REPO" cat-file -e "$ALPHA_TIP^{commit}" 2>/dev/null || { printf '        ASSERT FAILED: the commit object is gone\n'; rc=1; }
# The load-bearing half.
new_fixture
ALPHA_TIP="$(git -C "$CONTAINER/alpha" rev-parse HEAD)"
DRV="$(legacy_driver "$LIB" branch-moves "$ALPHA_AGENT" 1 alpha 7777aaaa8888bbbb)"
assert_eq "quarantined" "$(jf "$DRV" outcome)" "the workspace itself is quarantined" || rc=1
assert_eq "false" "$(jf "$DRV" branch.deleted)" "the branch was NOT deleted" || rc=1
assert_eq "branch-moved" "$(jf "$DRV" branch.reason_code)" "because it moved between the read and the delete" || rc=1
assert_eq "$(jf "$DRV" moved_to)" "$(git -C "$OWNER_REPO" rev-parse --verify --quiet refs/heads/alpha)" "refs/heads/alpha exists at the tip it was moved to" || rc=1
assert_ne "" "$(jf "$DRV" moved_to)" "the move really happened (the driver recorded it)" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "G3b   the asserted branch, when it IS the workspace's, is deleted by compare-and-delete with its tip reachable from the backup ref — and a branch that moves between the tip read and the delete is LEFT IN PLACE (branch-moved), so the check and the destruction are one operation"
else
    bad "G3b   branch deletion is not bound to the tip it read — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-600)"
fi

echo "--- the same class, found by looking: stale locks, the quarantine's neighbors, reoccupied paths ---"

# --- LOCK. A STALE-LOCKED native isolation worktree (lock names a dead pid).
# Git never prunes a locked registration; retirement never unlocked. Both
# routes must leave the registration GONE and the branch deletable — the
# reaper's `git branch -d` is what follows a reap. The control: the lock is
# shown present before, and git is shown to refuse pruning it while locked.
dead_pid() { sleep 5 & local p=$!; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; printf '%s\n' "$p"; }
new_fixture
rc=0
DP="$(dead_pid)"
mkdir -p "$ENTITY/.claude/worktrees"
git -C "$ENTITY" worktree add -q -b worktree-agent-1a1a1a1a1b1b1b1b "$ENTITY/.claude/worktrees/agent-1a1a1a1a1b1b1b1b"
git -C "$ENTITY" worktree lock --reason "claude agent agent-1a1a1a1a1b1b1b1b (pid $DP start test)" "$ENTITY/.claude/worktrees/agent-1a1a1a1a1b1b1b1b"
assert_contains "$(git -C "$ENTITY" worktree list --porcelain)" "locked claude agent agent-1a1a1a1a1b1b1b1b" "the lock is on (control)" || rc=1
OUT="$(H --owner 1a1a1a1a1b1b1b1b "$ENTITY/.claude/worktrees/agent-1a1a1a1a1b1b1b1b")"
assert_eq "0" "$?" "legacy: a stale-locked native worktree is retired" || rc=1
assert_contains "$OUT" "observed-isolation-worktree" "on the observation of its stale lock" || rc=1
assert_absent "$ENTITY/.claude/worktrees/agent-1a1a1a1a1b1b1b1b" "the path is vacated" || rc=1
a; git -C "$ENTITY" worktree list --porcelain | grep -qxF "worktree $ENTITY/.claude/worktrees/agent-1a1a1a1a1b1b1b1b" && { printf '        ASSERT FAILED: git still registers the stale-locked worktree\n'; rc=1; }
assert_contains "$OUT" '"git_registration": "gone"' "and the outcome READ BACK that the registration is gone" || rc=1
a; git -C "$ENTITY" branch -d worktree-agent-1a1a1a1a1b1b1b1b >/dev/null 2>&1 || { printf '        ASSERT FAILED: the reaper'"'"'s follow-up `git branch -d` would fail\n'; rc=1; }
# Retirement mode, same shape, with an ownership record.
DP="$(dead_pid)"
git -C "$ENTITY" worktree add -q -b worktree-agent-2c2c2c2c2d2d2d2d "$ENTITY/.claude/worktrees/agent-2c2c2c2c2d2d2d2d"
git -C "$ENTITY" worktree lock --reason "claude agent agent-2c2c2c2c2d2d2d2d (pid $DP start test)" "$ENTITY/.claude/worktrees/agent-2c2c2c2c2d2d2d2d"
L record registered --teammate zach-stale --agent-id 2c2c2c2c2d2d2d2d --session-id sess-s \
    --repo "$ENTITY" --worktree "$ENTITY/.claude/worktrees/agent-2c2c2c2c2d2d2d2d" \
    --branch worktree-agent-2c2c2c2c2d2d2d2d --class native
WS_STALE="$(python3 "$LIB" workspace-id "$ENTITY" "$ENTITY/.claude/worktrees/agent-2c2c2c2c2d2d2d2d")"
OUT="$(H --workspace "$WS_STALE")"
assert_eq "0" "$?" "retirement: a stale-locked native worktree is retired" || rc=1
a; git -C "$ENTITY" worktree list --porcelain | grep -qxF "worktree $ENTITY/.claude/worktrees/agent-2c2c2c2c2d2d2d2d" && { printf '        ASSERT FAILED: retirement left the stale-locked registration behind\n'; rc=1; }
a; git -C "$ENTITY" branch -d worktree-agent-2c2c2c2c2d2d2d2d >/dev/null 2>&1 || { printf '        ASSERT FAILED: the branch is still held by a registration\n'; rc=1; }
if [ "$rc" -eq 0 ]; then
    ok "LOCK  a stale-locked native worktree (dead pid) is retired on BOTH routes with its git registration gone and its branch deletable — the sequence unlocks before it prunes and reads the registry back"
else
    bad "LOCK  a stale lock survived retirement, or the registration did — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

# --- QDIR. WHERE the quarantine lives decides whether it survives its
# neighbors. hooks/detect-nonnative-worktree.sh rm -rf's every entry `*/`
# under .claude/worktrees/ that git does not register; the reaper's residue
# scan reports every such entry. A quarantine is unregistered by construction.
# The row: the quarantine is in <parent>/.richos-retired/, the exact `*/`
# glob both scanners run does NOT enumerate it — and DOES enumerate a real
# sibling, so the glob is shown to work.
new_fixture
rc=0
OUT="$(H --workspace "$WS_ALPHA")"
assert_eq "0" "$?" "retirement succeeds" || rc=1
QPATH="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantine"]["path"])' 2>/dev/null)"
assert_dir "$QPATH" "the quarantine exists" || rc=1
assert_eq "$CONTAINER/.richos-retired" "$(dirname "$QPATH")" "and lives in <parent>/.richos-retired/" || rc=1
a; [ -z "$(ls -d "$CONTAINER"/alpha.richos-retired-* 2>/dev/null)" ] || { printf '        ASSERT FAILED: a quarantine sits as a visible sibling in the container\n'; rc=1; }
GLOB_SEEN=""
for d in "$CONTAINER"/*/; do GLOB_SEEN="$GLOB_SEEN $(basename "${d%/}")"; done
assert_contains "$GLOB_SEEN" "beta" "the scanners' glob enumerates a real sibling (control)" || rc=1
a; case "$GLOB_SEEN" in *richos-retired*) printf '        ASSERT FAILED: the scanners'"'"' glob enumerates the quarantine (%s)\n' "$GLOB_SEEN"; rc=1 ;; esac
# The sweep still finds and erases it where it is (the location did not break retention).
SOUT="$(R sweep --retention-days 0 --execute)"
assert_contains "$SOUT" '"action": "erased"' "the sweep erases it there once retention elapses" || rc=1
assert_absent "$QPATH" "erased" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "QDIR  the quarantine lives in <parent>/.richos-retired/, which the \`*/\` glob of the residue scan and of the auto-reaping hook does not enumerate (while the same glob does enumerate a real sibling), and the sweep still erases it there after retention"
else
    bad "QDIR  the quarantine is where a scanner would delete or report it"
fi

# --- PRIOR. A path this module retired, now occupied by a DIFFERENT object.
# Legacy route: unclaimed (no ownership record newer than the retirement) ->
# refused, the object untouched; claimed by a new, witnessed-terminated owner
# -> retired on its own evidence (the reaper reaps reused hand-rolled paths).
new_fixture
rc=0
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "first legacy retirement succeeds" || rc=1
# No sleep here, deliberately. The first version of the rule compared
# timestamps and this row needed a second to pass; a row that needs the clock
# is a row about the clock.
git -C "$OWNER_REPO" worktree add -q -b alpha-again "$CONTAINER/alpha"
printf 'replacement payload\n' >"$CONTAINER/alpha/replacement.txt"
REPL="$(snapshot "$CONTAINER/alpha")"
REPL_INODE="$(inode_of "$CONTAINER/alpha")"
OUT="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "3" "$?" "an UNCLAIMED replacement at a retired path is refused" || rc=1
assert_contains "$OUT" "already-retired-path-reoccupied" "by name" || rc=1
assert_eq "$REPL" "$(snapshot "$CONTAINER/alpha")" "the replacement is byte for byte untouched" || rc=1
assert_eq "$REPL_INODE" "$(inode_of "$CONTAINER/alpha")" "and the same object" || rc=1
L record registered --teammate zach-again --agent-id 9e9e9e9e9f9f9f9f --session-id sess-again \
    --repo "$OWNER_REPO" --worktree "$CONTAINER/alpha" --branch alpha-again --class hand-rolled
L record terminated --agent-id 9e9e9e9e9f9f9f9f --worktree "$CONTAINER/alpha" \
    --reason "test fixture: witnessed termination" --witness test
OUT="$(H --repo "$OWNER_REPO" --owner 9e9e9e9e9f9f9f9f --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "a CLAIMED replacement whose new owner is witnessed dead is retired" || rc=1
assert_contains "$OUT" '"outcome": "quarantined"' "quarantined" || rc=1
assert_absent "$CONTAINER/alpha" "and the path is vacated" || rc=1
assert_eq "2" "$(ls -d "$CONTAINER"/.richos-retired/alpha.richos-retired-* 2>/dev/null | wc -l | tr -d ' ')" "two quarantines now exist, one per occupant" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "PRIOR an object nobody has claimed at a retired path is refused on the legacy route (already-retired-path-reoccupied), while a replacement claimed by a new, witnessed-terminated owner is retired on its own evidence — reused hand-rolled paths keep working for the reaper"
else
    bad "PRIOR the reoccupied-path rule did not hold — raw: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-600)"
fi

# --- TWICE. The same workspace ID retired twice, back to back, with NO sleep
# between. Found by the mutation loop: with a whole-second stamp the second
# retirement minted the same quarantine name AND the same preservation
# directory as the first, overwrote the first's archive, and then failed on
# the occupied name. Both must succeed, into distinct names, and the first
# recovery copy must be byte-identical afterward.
new_fixture
rc=0
OUT1="$(H --repo "$OWNER_REPO" --owner "$ALPHA_AGENT" --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "first retirement succeeds" || rc=1
J1="$(printf '%s\n' "$OUT1" | python3 -c 'import sys; s=sys.stdin.read(); i=s.index("{"); j=s.rindex("}")+1; print(s[i:j])' 2>/dev/null)"
ARCHIVE1="$(jf "$J1" preservation.archive)"
Q1="$(jf "$J1" quarantine.path)"
ARCHIVE1_SHA="$(shasum -a 256 "$ARCHIVE1" | cut -d' ' -f1)"
git -C "$OWNER_REPO" worktree add -q -b alpha-twice "$CONTAINER/alpha"
printf 'second occupant\n' >"$CONTAINER/alpha/second.txt"
L record registered --teammate zach-twice --agent-id 5b5b5b5b5c5c5c5c --session-id sess-t \
    --repo "$OWNER_REPO" --worktree "$CONTAINER/alpha" --branch alpha-twice --class hand-rolled
L record terminated --agent-id 5b5b5b5b5c5c5c5c --worktree "$CONTAINER/alpha" \
    --reason "test fixture: witnessed termination" --witness test
OUT2="$(H --repo "$OWNER_REPO" --owner 5b5b5b5b5c5c5c5c --force "$CONTAINER/alpha")"
assert_eq "0" "$?" "second retirement of the same ID, in the same breath, succeeds" || rc=1
J2="$(printf '%s\n' "$OUT2" | python3 -c 'import sys; s=sys.stdin.read(); i=s.index("{"); j=s.rindex("}")+1; print(s[i:j])' 2>/dev/null)"
assert_eq "quarantined" "$(jf "$J2" outcome)" "quarantined" || rc=1
assert_ne "$Q1" "$(jf "$J2" quarantine.path)" "into a DIFFERENT quarantine name" || rc=1
assert_ne "$ARCHIVE1" "$(jf "$J2" preservation.archive)" "with a DIFFERENT archive path" || rc=1
assert_eq "$ARCHIVE1_SHA" "$(shasum -a 256 "$ARCHIVE1" | cut -d' ' -f1)" "and the FIRST archive is byte-identical to before — the recovery copy was not written over" || rc=1
assert_dir "$Q1" "the first quarantine still exists" || rc=1
assert_eq "second occupant" "$(cat "$(jf "$J2" quarantine.path)/second.txt" 2>/dev/null)" "the second quarantine holds the second occupant" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "TWICE the same workspace ID retired twice with no pause mints two distinct quarantine names and two distinct archives, and the first recovery copy is byte-identical afterward"
else
    bad "TWICE two retirements of one ID collided on a name or an archive — raw: $(printf '%s' "$OUT2" | tr '\n' ' ' | cut -c1-500)"
fi

# --- STAMP. The guards behind TWICE, forced: with the stamp PINNED to one
# constant (a real collision cannot be built against microsecond stamps), the
# second retirement must refuse or fail BEFORE anything moves, and the first
# recovery copy must be byte-identical afterward. Without this row, the
# exist_ok=False in preserve() and the name-taken refusal would be code no
# case ever reaches.
new_fixture
rc=0
DRV="$(python3 - "$LIB" "$LEDGER_PY" "$ENTITY" "$OWNER_REPO" "$CONTAINER/alpha" "$LEDGER" "$ALPHA_AGENT" <<'PY'
import hashlib, importlib.util, json, os, subprocess, sys
lib, ledger_py, entity, repo, work, ledger, owner = sys.argv[1:8]
spec = importlib.util.spec_from_file_location("wr", lib)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._stamp = lambda: "20260101T000000.000000Z"
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()
r1 = m.remove_legacy(entity, repo, work, owner, force=True)
a1 = (r1.get("preservation") or {}).get("archive")
s1 = sha(a1) if a1 and os.path.isfile(a1) else ""
subprocess.run(["git", "-C", repo, "worktree", "add", "-qb", "alpha-stamp", work], check=True)
with open(os.path.join(work, "second.txt"), "w") as f:
    f.write("second occupant\n")
new = "6d6d6d6d6e6e6e6e"
subprocess.run(["python3", ledger_py, "--ledger", ledger, "record", "registered", "--agent-id", new,
                "--teammate", "zach-stamp", "--session-id", "sess-stamp", "--repo", repo,
                "--worktree", work, "--branch", "alpha-stamp", "--class", "hand-rolled"], check=True, capture_output=True)
subprocess.run(["python3", ledger_py, "--ledger", ledger, "record", "terminated", "--agent-id", new,
                "--worktree", work, "--reason", "fixture", "--witness", "test"], check=True, capture_output=True)
r2 = m.remove_legacy(entity, repo, work, new, force=True)
print(json.dumps({"first_outcome": r1.get("outcome"), "first_archive": a1,
                  "second_outcome": r2.get("outcome"), "second_reason_code": r2.get("reason_code"),
                  "second_stage": r2.get("stage"),
                  "first_archive_same_bytes": bool(s1) and os.path.isfile(a1) and sha(a1) == s1,
                  "work_present": os.path.isdir(work),
                  "second_file_present": os.path.isfile(os.path.join(work, "second.txt"))}))
PY
)"
assert_eq "quarantined" "$(jf "$DRV" first_outcome)" "the first retirement succeeds" || rc=1
a; case "$(jf "$DRV" second_outcome)" in failed|refused) ;; *) printf '        ASSERT FAILED: the second retirement under a pinned stamp reported %s\n' "$(jf "$DRV" second_outcome)"; rc=1 ;; esac
a; case "$(jf "$DRV" second_reason_code)" in preservation-failed|quarantine-name-taken) ;; *) printf '        ASSERT FAILED: unexpected reason %s\n' "$(jf "$DRV" second_reason_code)"; rc=1 ;; esac
assert_eq "true" "$(jf "$DRV" first_archive_same_bytes)" "the first archive is byte-identical — not written over" || rc=1
assert_eq "true" "$(jf "$DRV" work_present)" "the second occupant is untouched at its path" || rc=1
assert_eq "true" "$(jf "$DRV" second_file_present)" "with its file" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "STAMP with the stamp pinned to one constant, the second retirement of the same ID stops before anything moves (preservation refuses the existing directory) and the first recovery copy is byte-identical — the collision guards are reached, not merely present"
else
    bad "STAMP a forced name collision overwrote an archive or moved the workspace — driver: $(printf '%s' "$DRV" | tr '\n' ' ' | cut -c1-500)"
fi

echo "--- RECHECK 2026-09-06: the reviewer's own script, verbatim ---"

RECHECK_PY="$SCRIPT_DIR/workspace-retire.recheck-2026-09-06.py"
rc=0
a; [ -f "$RECHECK_PY" ] || { printf '        ASSERT FAILED: the vendored recheck script is missing at %s\n' "$RECHECK_PY"; rc=1; }
RECHECK_ORIG=/Users/alex/ab/richos-hq/docs/verification/worktree-removal-fix-recheck-2026-09-06/reproduce.py
if [ -f "$RECHECK_ORIG" ]; then
    a; diff <(sed 1,12d "$RECHECK_PY" | grep -v '^ENGINE = ') <(grep -v '^ENGINE = ' "$RECHECK_ORIG") >/dev/null 2>&1 \
        || { printf '        ASSERT FAILED: the vendored recheck script differs from the reviewer'"'"'s beyond the ENGINE line\n'; rc=1; }
else
    printf '        note: the reviewer'"'"'s original is not on this machine (%s); the vendored copy was not byte-compared to it in this run\n' "$RECHECK_ORIG"
fi
RECHECK_OUT="$(cd "$SANDBOX" && TMPDIR="$SANDBOX" PYTHONDONTWRITEBYTECODE=1 python3 "$RECHECK_PY" 2>&1)"
RECHECK_RC=$?
assert_eq "0" "$RECHECK_RC" "the reviewer's recheck script ran to completion (its own asserts hold)" || rc=1
RECHECK_JSON="$(printf '%s\n' "$RECHECK_OUT" | sed -n '/^\[/,/^\]/p')"
read_recheck() { # <case> <field>
    printf '%s' "$RECHECK_JSON" | python3 -c '
import json, sys
rs = json.loads(sys.stdin.read())
r = [x for x in rs if x.get("case") == sys.argv[1]][0]
v = r.get(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v))' "$1" "$2" 2>/dev/null
}
assert_eq "owner-alive" "$(read_recheck legacy_worker_acquires_after_preservation authority_after_acquisition)" "case 1: the authority said ALIVE after the acquisition" || rc=1
assert_eq "refused" "$(read_recheck legacy_worker_acquires_after_preservation outcome)" "case 1: refused (was ok)" || rc=1
assert_eq "reacquired" "$(read_recheck legacy_worker_acquires_after_preservation reason_code)" "case 1: reacquired (was removed)" || rc=1
assert_eq "true" "$(read_recheck legacy_worker_acquires_after_preservation workspace_survived)" "case 1: the workspace survived (was false)" || rc=1
assert_eq "true" "$(read_recheck legacy_worker_acquires_after_preservation new_file_survived)" "case 1: the new file survived (was false)" || rc=1
assert_eq "" "$(read_recheck legacy_ignored_file_without_force git_status)" "case 2: git status was clean (the precondition)" || rc=1
assert_eq "0" "$(read_recheck legacy_ignored_file_without_force exit)" "case 2: exit 0" || rc=1
assert_eq "quarantined" "$(read_recheck legacy_ignored_file_without_force outcome)" "case 2: quarantined (was ok/removed)" || rc=1
assert_contains "$(read_recheck legacy_ignored_file_without_force preservation)" '"status": "verified"' "case 2: preservation verified (was null)" || rc=1
assert_eq "1" "$(read_recheck legacy_ignored_file_without_force archive_count)" "case 2: one archive (was zero)" || rc=1
assert_eq "3" "$(read_recheck legacy_unrelated_branch_deletion exit)" "case 3: refused, exit 3 (was 0)" || rc=1
assert_eq "refused" "$(read_recheck legacy_unrelated_branch_deletion outcome)" "case 3: outcome refused" || rc=1
assert_eq "false" "$(read_recheck legacy_unrelated_branch_deletion unrelated_branch_deleted)" "case 3: the unrelated branch was NOT deleted (was true)" || rc=1
assert_contains "$(read_recheck legacy_unrelated_branch_deletion refs_preserving_unrelated_tip)" "refs/heads/unrelated-unmerged" "case 3: its own ref still protects its tip (was none)" || rc=1
assert_eq "true" "$(read_recheck legacy_unrelated_branch_deletion unrelated_commit_object_survives)" "case 3: the commit object survives" || rc=1
if [ "$rc" -eq 0 ]; then
    ok "RECHECK  the reviewer's second reproduce.py, run verbatim: finding 1 refuses as reacquired with the workspace and the new file intact, finding 2 quarantines with a verified archive, finding 3 refuses with the unrelated branch and its ref intact — read by the named outcomes, as the reviewer specified"
else
    bad "RECHECK  the reviewer's second script still reproduces at least one finding"
fi


echo
echo "=== workspace-retire: $PASS passed, $FAIL failed, $NOTCOVERED not covered (stated by name above), $ASSERTS assertions ==="
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
