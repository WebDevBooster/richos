#!/usr/bin/env bash
#
# workspace-retire.test.sh — THE ACCEPTANCE SUITE THE 2026-09-05 DIAGNOSIS
# SPECIFIES, one section per row of its acceptance table.
#
# Source: richos-hq docs/verification/worktree-container-deletion-2026-09-05.md,
# section "Acceptance criteria" (ten rows). Its own instructions, followed here:
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

json_field() { # <json> <dotted.path>
    python3 - "$2" <<PY
import json, sys
d = json.loads(sys.stdin.read())
cur = d
for k in sys.argv[1].split('.'):
    if isinstance(cur, dict):
        cur = cur.get(k)
    else:
        cur = None
    if cur is None:
        break
print("" if cur is None else (cur if isinstance(cur, str) else json.dumps(cur)))
PY
}
jf() { printf '%s' "$1" | json_field "$1" "$2"; }

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

echo
echo "=== workspace-retire: $PASS passed, $FAIL failed, $NOTCOVERED not covered (stated by name above), $ASSERTS assertions ==="
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
