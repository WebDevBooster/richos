#!/usr/bin/env bash
#
# record-committer.test.sh: the scheduled committer for loro writes in a record
# (scripts/record-committer.sh, scripts/lib/record_committer.py; daily-driver plan
# step 8, two-installs spec point 28).
#
#   K0   nothing to commit: no commit, the tick is recorded as clean
#   K1   a real loro write (loro-write append) is committed, and ONLY it: a
#        person's staged change stays staged and uncommitted, an untracked note
#        and the writer's in-flight temporary are left alone, the message says
#        what made it
#   K2   the app lander's land lock held by another process: skipped, nothing
#        committed; released: committed
#   K3   a merge in progress in the checkout: skipped; aborted: committed
#   K4   the loro writer's own lock held: skipped; released: committed
#   K5   HEAD detached, or on another branch: skipped; back on main: committed
#   K6   operator fence on: a live land lease skips the tick; with the lease
#        released it commits (the fence itself still refuses a plain commit)
#   K7   a two-file supersession lands in ONE commit
#   K8   install, status and uninstall of the scheduled job (a fixture agents
#        directory, never launchd): the plist names the engine, the repository
#        and the interval; out-of-range intervals and a relative python refused
#   K9   a linked worktree is refused as the repository
#   K10  index.lock present: skipped, naming it; removed: committed
#
# Every case runs in its own scratch record under the operator-fence fixture
# (scripts/lib/operator-fences-fixture.sh): its own CLAUDE_CONFIG_DIR, land-lock
# home and git config. Nothing of the operator's is read or written, and launchd
# is never touched. Lock holders are processes this suite spawns and ends by the
# pid captured at spawn.
#
# Usage: scripts/record-committer.test.sh [case ...]   (e.g. "K2")

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$SCRIPT_DIR/record-committer.sh"
# The loro writer is this suite's INPUT. Its mutation harness runs the suite from
# a sandbox copy of the engine that carries no loro/, and points it here.
LORO="${RICHOS_TEST_LORO_WRITE:-$ENGINE_ROOT/loro/bin/loro-write.mjs}"
# shellcheck source=lib/operator-fences-fixture.sh
. "$ENGINE_ROOT/scripts/lib/operator-fences-fixture.sh"

WANTED=("$@")
want() {
    [ "${#WANTED[@]}" -eq 0 ] && return 0
    local w
    for w in "${WANTED[@]}"; do [ "${w%% *}" = "$1" ] && return 0; done
    return 1
}
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -12; FAIL=$((FAIL + 1)); return 0; }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
# A glob match that can sit inside $( ): bash 3.2 mis-parses a `case` pattern's
# closing parenthesis there.
matches() { case "$1" in $2) return 0 ;; esac; return 1; }

command -v node >/dev/null 2>&1 || { echo "FATAL: node is required (the loro writer is the thing whose writes are committed)"; exit 1; }
[ -f "$LORO" ] || { echo "FATAL: missing $LORO"; exit 1; }

HOLDER_PID=""
stop_holder() {
    if [ -n "$HOLDER_PID" ]; then
        kill "$HOLDER_PID" 2>/dev/null
        wait "$HOLDER_PID" 2>/dev/null
        HOLDER_PID=""
    fi
    return 0
}
ofx_init || exit 1
trap 'stop_holder; ofx_cleanup' EXIT
unset RICHOS_OPERATOR_LEAD CLAUDE_PROJECT_DIR 2>/dev/null

echo "=== the record committer ==="

fresh_record() { # <name> -> REC
    ofx_repo "$1"; REC="$OFX_R"
    mkdir -p "$REC/loro" "$REC/wiki"
    printf 'the loro root\n' > "$REC/loro/README.md"
    printf '# Open items\n' > "$REC/wiki/open-items.md"
    git -C "$REC" add -A && git -C "$REC" commit -q -m "record fixture"
}
tick() { TOUT="$(bash "$CLI" run --repo "$REC" 2>&1)"; TRC=$?; }
head_of() { git -C "$REC" rev-parse HEAD; }
loro_append() { # <id> <body>
    node "$LORO" append --root "$REC" --id "$1" --kind fact --body "$2" --now 2026-09-28T00:00:00Z >/dev/null 2>&1
}
committed_files() { git -C "$REC" show --name-only --format= HEAD | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' '; }
land_lock_of() {
    python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import workspaces as W; print(W.land_lock_path(sys.argv[2]))" \
        "$ENGINE_ROOT/mega-lander" "$REC"
}
start_holder() { # flock|sqlite <path>: a process of ours holds it until stop_holder
    rm -f "$OFX/held.flag"
    python3 - "$1" "$2" "$OFX/held.flag" <<'P' &
import fcntl, sqlite3, sys, time
kind, path, flag = sys.argv[1:4]
if kind == "flock":
    fh = open(path, "a+")
    fcntl.flock(fh, fcntl.LOCK_EX)
else:
    db = sqlite3.connect(path, isolation_level=None)
    db.execute("BEGIN IMMEDIATE")
open(flag, "w").write("held")
time.sleep(120)
P
    HOLDER_PID=$!
    local i=0
    while [ ! -f "$OFX/held.flag" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$OFX/held.flag" ]
}

if want K0; then
    fresh_record k0
    before="$(head_of)"; tick
    state="$(ls "$CLAUDE_CONFIG_DIR/state/record-committer/"*.json 2>/dev/null | head -1)"
    check "K0 nothing to commit: no commit, recorded as clean" \
        "$([ "$TRC" = 0 ] && [ "$(head_of)" = "$before" ] && matches "$TOUT" '*clean*' \
           && [ -n "$state" ] && grep -q '"outcome": "clean"' "$state"; echo $?)" "rc=$TRC out=$TOUT state=$state"
fi

if want K1; then
    fresh_record k1
    printf 'a person is editing this\n' >> "$REC/wiki/open-items.md"
    git -C "$REC" add wiki/open-items.md
    printf 'an untracked note\n' > "$REC/wiki/notes.md"
    loro_append k1-belief "the committer commits this belief"
    mkdir -p "$REC/loro/records"
    printf 'half written\n' > "$REC/loro/records/.loro-0000.incoming"
    before="$(head_of)"; tick
    check "K1 a real loro write is committed" \
        "$([ "$TRC" = 0 ] && [ "$(head_of)" != "$before" ] && matches "$TOUT" '*committed*'; echo $?)" "$TOUT"
    files="$(committed_files)"
    check "K1 only the loro write is in that commit" \
        "$([ "$files" = "loro/records/k1-belief.md " ]; echo $?)" "committed: [$files]"
    staged="$(git -C "$REC" diff --cached --name-only | tr '\n' ' ')"
    check "K1 a person's staged change stays staged and uncommitted" \
        "$([ "$staged" = "wiki/open-items.md " ]; echo $?)" "staged: [$staged]"
    check "K1 an untracked note, the writer's lock and its in-flight temporary are left alone" \
        "$(git -C "$REC" ls-files --error-unmatch wiki/notes.md >/dev/null 2>&1 && exit 1
           git -C "$REC" ls-files | grep -q -e writer-lock -e '\.incoming' && exit 1
           [ -f "$REC/loro/records/.loro-0000.incoming" ] && [ -f "$REC/wiki/notes.md" ]; echo $?)" \
        "$(git -C "$REC" ls-files | tr '\n' ' ')"
    check "K1 the commit says what made it" \
        "$(git -C "$REC" log -1 --format=%B | grep -q '^Committed-By: record-committer' && echo 0 || echo 1)" \
        "$(git -C "$REC" log -1 --format=%B)"
fi

if want K2; then
    fresh_record k2
    loro_append k2-belief "held behind a land"
    before="$(head_of)"
    if start_holder flock "$(land_lock_of)"; then
        tick
        check "K2 the land lock held elsewhere: skipped, nothing committed" \
            "$([ "$(head_of)" = "$before" ] && matches "$TOUT" '*skipped*land lock*'; echo $?)" "$TOUT"
        stop_holder
        tick
        check "K2 released: committed" \
            "$([ "$(head_of)" != "$before" ] && matches "$TOUT" '*committed*'; echo $?)" "$TOUT"
    else
        stop_holder; bad "K2 fixture: the land lock holder did not start"
    fi
fi

if want K3; then
    fresh_record k3
    git -C "$REC" checkout -q -b side && printf 'side\n' > "$REC/side.txt" && git -C "$REC" add side.txt \
        && git -C "$REC" commit -q -m side && git -C "$REC" checkout -q main
    git -C "$REC" merge -q --no-ff --no-commit side >/dev/null 2>&1
    loro_append k3-belief "written during a merge"
    before="$(head_of)"; tick
    check "K3 a merge in progress: skipped, nothing committed" \
        "$([ "$(head_of)" = "$before" ] && [ -f "$REC/.git/MERGE_HEAD" ] && matches "$TOUT" '*skipped*merge in progress*'; echo $?)" "$TOUT"
    git -C "$REC" merge --abort
    tick
    check "K3 the merge aborted: committed, and only the loro write" \
        "$(matches "$TOUT" '*committed*' && [ "$(committed_files)" = "loro/records/k3-belief.md " ]; echo $?)" "$TOUT / $(committed_files)"
fi

if want K4; then
    fresh_record k4
    loro_append k4-belief "one write"
    before="$(head_of)"
    if start_holder sqlite "$REC/loro/writer-lock.sqlite"; then
        tick
        check "K4 a loro write in progress (the writer's own lock): skipped" \
            "$([ "$(head_of)" = "$before" ] && matches "$TOUT" '*skipped*loro write is in progress*'; echo $?)" "$TOUT"
        stop_holder
        tick
        check "K4 the writer done: committed" \
            "$([ "$(head_of)" != "$before" ]; echo $?)" "$TOUT"
    else
        stop_holder; bad "K4 fixture: the writer lock holder did not start"
    fi
fi

if want K5; then
    fresh_record k5
    loro_append k5-belief "written while HEAD wandered"
    before="$(head_of)"
    git -C "$REC" checkout -q --detach
    tick; out1="$TOUT"
    git -C "$REC" checkout -q main && git -C "$REC" checkout -q -b elsewhere
    tick; out2="$TOUT"
    git -C "$REC" checkout -q main
    check "K5 HEAD detached, or on another branch: skipped both times" \
        "$([ "$(head_of)" = "$before" ] && [ "$(git -C "$REC" rev-parse elsewhere)" = "$before" ] \
           && matches "$out1" '*skipped*detached*' \
           && matches "$out2" '*skipped*refs/heads/elsewhere*'; echo $?)" "$out1 / $out2"
    tick
    check "K5 back on main: committed" "$([ "$(head_of)" != "$before" ]; echo $?)" "$TOUT"
fi

if want K6; then
    fresh_record k6
    if ofx_install "$REC" >/dev/null 2>&1 && ofx_on "$REC" >/dev/null 2>&1; then
        ofx_session k6s
        ofx_in k6s "$(ofx_lease acquire --repo "$REC")"; lrc=$?
        loro_append k6-belief "written under a lease"
        before="$(head_of)"; tick
        check "K6 fence on, a land lease held: skipped" \
            "$([ "$lrc" = 0 ] && [ "$(head_of)" = "$before" ] && matches "$TOUT" '*skipped*land lease*'; echo $?)" "lease rc=$lrc $OFX_OUT / $TOUT"
        ofx_in k6s "$(ofx_lease release --repo "$REC")"
        printf 'x\n' > "$REC/plain.txt"; git -C "$REC" add plain.txt
        git -C "$REC" commit -q -m "a plain commit with no lease" >/dev/null 2>&1; prc=$?
        git -C "$REC" reset -q -- plain.txt; rm -f "$REC/plain.txt"
        tick
        check "K6 fence on, no lease: committed (and the fence still refuses a plain commit)" \
            "$([ "$prc" != 0 ] && [ "$(head_of)" != "$before" ] && [ "$(committed_files)" = "loro/records/k6-belief.md " ]; echo $?)" \
            "plain rc=$prc / $TOUT / $(committed_files)"
        ofx_end k6s
        ofx_off "$REC" >/dev/null 2>&1
    else
        bad "K6 fixture: the fence could not be installed"
    fi
fi

if want K7; then
    fresh_record k7
    loro_append k7-old "the first belief"
    tick
    base="$(head_of)"
    printf 'the corrected belief\n' | node "$LORO" supersede --root "$REC" --ref rec:loro/records/k7-old \
        --id k7-new --kind fact --body-stdin --why "it changed" --now 2026-09-28T01:00:00Z >/dev/null 2>&1; src=$?
    tick
    check "K7 a two-file supersession lands in ONE commit" \
        "$([ "$src" = 0 ] && [ "$(git -C "$REC" rev-list --count "$base"..HEAD)" = 1 ] \
           && [ "$(committed_files)" = "loro/records/k7-new.md loro/records/k7-old.md " ]; echo $?)" \
        "supersede rc=$src / $(committed_files)"
fi

if want K8; then
    fresh_record k8
    AG="$OFX/agents"
    out="$(bash "$CLI" install --repo "$REC" --agents-dir "$AG" --no-load --interval 120 2>&1)"; irc=$?
    plist="$(ls "$AG"/com.richos.record-committer.*.plist 2>/dev/null | head -1)"
    check "K8 install writes the job: engine, repository and interval" \
        "$([ "$irc" = 0 ] && [ -n "$plist" ] && python3 - "$plist" "$REC" "$(cd "$ENGINE_ROOT" && pwd -P)" <<'P'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
args = p["ProgramArguments"]
ok = (args[1] == sys.argv[3] + "/scripts/lib/record_committer.py" and args[2:6] == ["run", "--repo", sys.argv[2], "--branch"]
      and p["StartInterval"] == 120 and p["RunAtLoad"] is True and p["Label"].startswith("com.richos.record-committer."))
sys.exit(0 if ok else 1)
P
        echo $?)" "rc=$irc $out"
    st="$(bash "$CLI" status --repo "$REC" --agents-dir "$AG" --no-load 2>&1)"; src=$?
    check "K8 status says installed, and how many writes wait" \
        "$([ "$src" = 0 ] && matches "$st" '*installed : yes*waiting   : 0 uncommitted*'; echo $?)" "$st"
    bash "$CLI" uninstall --repo "$REC" --agents-dir "$AG" --no-load >/dev/null 2>&1; urc=$?
    bash "$CLI" status --repo "$REC" --agents-dir "$AG" --no-load --quiet; qrc=$?
    check "K8 uninstall removes it (the way out), and status then says not installed" \
        "$([ "$urc" = 0 ] && [ ! -e "$plist" ] && [ "$qrc" = 3 ]; echo $?)" "uninstall=$urc quiet=$qrc"
    bash "$CLI" install --repo "$REC" --agents-dir "$AG" --no-load --interval 5 >/dev/null 2>&1; r1=$?
    bash "$CLI" install --repo "$REC" --agents-dir "$AG" --no-load --python python3 >/dev/null 2>&1; r2=$?
    check "K8 an interval under a minute and a relative python are refused" \
        "$([ "$r1" = 2 ] && [ "$r2" = 2 ] && [ -z "$(ls "$AG" 2>/dev/null)" ]; echo $?)" "rc=$r1/$r2"
fi

if want K9; then
    fresh_record k9
    git -C "$REC" worktree add -q "$OFX/k9-wt" -b k9-branch >/dev/null 2>&1
    out="$(bash "$CLI" run --repo "$OFX/k9-wt" 2>&1)"; rc=$?
    check "K9 a linked worktree is refused as the repository" \
        "$([ "$rc" = 2 ] && matches "$out" '*REFUSED*not the main checkout*'; echo $?)" "rc=$rc $out"
fi

if want K10; then
    fresh_record k10
    loro_append k10-belief "written while git held the index"
    before="$(head_of)"
    : > "$REC/.git/index.lock"
    tick
    check "K10 index.lock present: skipped, naming it" \
        "$([ "$(head_of)" = "$before" ] && matches "$TOUT" '*skipped*index.lock*'; echo $?)" "$TOUT"
    rm -f "$REC/.git/index.lock"
    tick
    check "K10 removed: committed" "$([ "$(head_of)" != "$before" ]; echo $?)" "$TOUT"
fi

echo ""
echo "=== record committer: $PASS passed, $FAIL failed ==="
if [ "${#WANTED[@]}" -eq 0 ] && [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/record-committer.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/record-committer.mutation.sh"; then
        ok "M. the mutation harness: every property is load-bearing"
    else
        bad "M. the mutation harness found a property this suite does not actually prove"
    fi
fi
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
