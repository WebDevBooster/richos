#!/usr/bin/env bash
#
# record-owner.test.sh: ONE WRITER AT CUT-OVER (daily-driver plan step 8;
# two-installs spec points 25-28). The owner line in the record's .row-currency,
# the two terminal-side refusals it switches on, and the switch itself:
#   scripts/lib/row-currency.sh      ROW_RECORD_OWNER parsing, rc_record_owner
#   scripts/lib/record_owner.py      who is calling (the platform's session record)
#   scripts/hooks/guard-row-currency-commits.sh   the landing refusal
#   scripts/hooks/guard-record-owner-memory.sh    the memory-directory refusal
#   scripts/record-owner.sh          the switch: on, off, status
#
#   O0   no owner line (the state until cut-over): the terminal lands in the
#        record as today
#   O1   owner line: a terminal COMMIT in the record's main checkout is refused
#   O2   owner line: a terminal MERGE there is refused
#   O3   owner line: the app's lead (an sdk-* session) lands
#   O4   owner line: a caller with no session record is refused (could not tell)
#   O5   owner line: a commit in a linked worktree of the record, and a landing
#        in a peer repository, are not record landings and pass
#   O6   deleting the line by hand: the terminal lands again
#   O7   a malformed owner line is BROKEN, never a quiet "terminal": a bad value,
#        no memory directory, the line twice, and the line in a peer declaration
#   M0   no owner line: the terminal writes his memory as today, silently
#   M1   owner line: a terminal Write and Edit into the memory directory are
#        refused; another memory directory and an ordinary file pass
#   M2   owner line: the app's lead writes his memory
#   M3   owner line: a caller with no session record is refused
#   M4   the seat in a linked worktree of the entity still finds the record's line
#   M5   deleting the line: the terminal writes his memory again
#   M6   a broken declaration: the write passes and says it was not checked
#   R1   registration: the memory guard is enforced on the plugin surface, named
#        in the probe's oracle and in the Write chain's manifest
#   S1   `on` refuses until the record committer is installed; then it commits
#        exactly one file, and the owner reads back as the app
#   S2   `on` refuses: an uncommitted declaration, a missing or relative memory
#        directory, a linked worktree, a peer repository
#   S3   `off` removes the line in one commit and the declaration is
#        byte-identical to before `on` (the way out); status says so
#   S4   `on` and `off` twice: the second says so and commits nothing
#   P1   ROW 8'S PROOF, end to end on one fixture: switch on; a real loro write
#        is committed by the record committer; a terminal commit and a terminal
#        memory write are refused; the app's lead lands; deleting the line lets
#        the terminal commit (and it lands) and write his memory
#
# Fixtures: the operator-fence fixture (scripts/lib/operator-fences-fixture.sh):
# sessions are processes with their own session records (entrypoint `cli`, or
# rewritten to `sdk-cli` for the app), in a scratch CLAUDE_CONFIG_DIR. Every case
# builds its own entity and record pair, so any case runs alone. Nothing of the
# operator's is read or written, and launchd is never touched.
#
# Usage: scripts/record-owner.test.sh [case ...]   (e.g. "O1")

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$ENGINE_ROOT/scripts/hooks/guard-row-currency-commits.sh"
MGUARD="$ENGINE_ROOT/scripts/hooks/guard-record-owner-memory.sh"
SWITCH="$SCRIPT_DIR/record-owner.sh"
COMMITTER="$SCRIPT_DIR/record-committer.sh"
# The loro writer is an INPUT of P1; its mutation harness points this at the real
# one, because the sandbox copy of the engine carries no loro/.
LORO="${RICHOS_TEST_LORO_WRITE:-$ENGINE_ROOT/loro/bin/loro-write.mjs}"
# shellcheck source=lib/operator-fences-fixture.sh
. "$ENGINE_ROOT/scripts/lib/operator-fences-fixture.sh"
# shellcheck source=lib/registered-hooks.sh
. "$ENGINE_ROOT/scripts/lib/registered-hooks.sh"

WANTED=("$@")
want() {
    [ "${#WANTED[@]}" -eq 0 ] && return 0
    local w
    for w in "${WANTED[@]}"; do [ "${w%% *}" = "$1" ] && return 0; done
    return 1
}
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" | head -14; FAIL=$((FAIL + 1)); return 0; }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
# A glob match that can sit inside $( ): bash 3.2 mis-parses a `case` pattern's
# closing parenthesis there.
matches() { case "$1" in $2) return 0 ;; esac; return 1; }

ofx_init || exit 1
trap ofx_cleanup EXIT
unset RICHOS_OPERATOR_LEAD CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT 2>/dev/null
mkdir -p "$OFX/p"
MEM="$OFX/claude/projects/-fixture-entity/memory"
OTHER_MEM="$OFX/claude/projects/-another-project/memory"
mkdir -p "$MEM" "$OTHER_MEM"
AG="$OFX/agents"

echo "=== one writer at cut-over: the owner line, its refusals and the switch ==="

# make_pair <name> -> ENT (the entity: adopted, a peer declaration) and REC (the
# record: .ceo-todos, .row-currency in the record form, an empty section 3, loro/)
make_pair() {
    local n="$1"
    ofx_repo "$n-ent"; ENT="$OFX_R"
    ofx_repo "$n-rec"; REC="$OFX_R"
    printf '# the fixture entity\n' > "$ENT/orchestration.config"
    printf 'ROW_RECORD_REPO="../%s-rec"\n' "$n" > "$ENT/.row-currency"
    git -C "$ENT" add -A && git -C "$ENT" commit -q -m "entity fixture"
    mkdir -p "$REC/wiki" "$REC/loro"
    printf '# the fixture record\n\nStart at [CEO-TODOs.md](CEO-TODOs.md).\n' > "$REC/README.md"
    {
        echo 'TODO_RECORD="wiki/open-items.md"'
        echo 'TODO_VIEW="CEO-TODOs.md"'
        echo 'ROOT_README="README.md"'
        echo 'CEO_SECTIONS="1 2"'
        echo 'PREPARER_SECTION="3"'
        echo "ARTIFACT_ROOTS=\"rec=. ent=../$n-ent\""
    } > "$REC/.ceo-todos"
    {
        echo '# the fixture record declaration'
        echo 'ROW_SECTIONS="3"'
        echo 'ROW_STATUS_TOKENS="OPEN BUILT CLOSED"'
        echo 'ROW_TERMINAL_TOKENS="CLOSED"'
    } > "$REC/.row-currency"
    {
        printf '# Open items\n\n'
        printf '## 1. Waiting on the CEO — a decision\n\n_Nothing._\n\n'
        printf '## 2. Waiting on the CEO — his hands\n\n_Nothing._\n\n'
        printf '## 3. Buildable now — nobody blocked\n\n| # | Item | State |\n|---|---|---|\n\n'
        printf '## Deliberately NOT open\n\nnothing\n'
    } > "$REC/wiki/open-items.md"
    printf 'the loro root\n' > "$REC/loro/README.md"
    git -C "$REC" add -A && git -C "$REC" commit -q -m "record fixture"
}
line_on()  { printf 'ROW_RECORD_OWNER="app %s"\n' "${2:-$MEM}" >> "$1/.row-currency"; }
line_off() { git -C "$1" checkout -q -- .row-currency; }

bash_payload() { # <name> <cwd> <command>
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' \
        "$2" "$3" > "$OFX/p/$1.json"
}
write_payload() { # <name> <Write|Edit> <cwd> <file>
    python3 -c '
import json, sys
tool, cwd, path = sys.argv[1:4]
ti = {"file_path": path, "content": "a line of memory\n"} if tool == "Write" else \
     {"file_path": path, "old_string": "a", "new_string": "b"}
print(json.dumps({"tool_name": tool, "cwd": cwd, "tool_input": ti}))' "$2" "$3" "$4" > "$OFX/p/$1.json"
}
# hook <session> <hook script> <payload> <cwd> <seat>  -> rc, OFX_OUT
hook() { ofx_in "$1" "cd '$4' && env CLAUDE_PROJECT_DIR='$5' bash '$2' < '$OFX/p/$3.json'"; }
sess() { # <session> <entrypoint>: rewrite a fixture session's record
    local pid; pid="$(cat "$OFX/s/$1.pid")"
    python3 - "$CLAUDE_CONFIG_DIR/sessions/$pid.json" "$2" <<'P'
import json, sys
path, entry = sys.argv[1:3]
rec = json.load(open(path)); rec["entrypoint"] = entry
json.dump(rec, open(path, "w"))
P
}

ofx_session term               # his terminal: entrypoint cli
ofx_session app; sess app sdk-cli   # the app's lead: an SDK session
ofx_session nobody none        # no session record anywhere in its ancestry

REFUSED_OWNER='*THE RICHOS APP OWNS THIS RECORD*'
REFUSED_MEMORY='*THE RICHOS APP OWNS HIS MEMORY*'

# --- O: the landing refusal --------------------------------------------------
if want O0; then
    make_pair o0
    bash_payload o0 "$REC" 'git commit -m "a record change"'
    hook term "$GUARD" o0 "$REC" "$ENT"; rc=$?
    check "O0 no owner line: the terminal lands in the record as today" \
        "$([ "$rc" = 0 ] && ! matches "$OFX_OUT" "$REFUSED_OWNER"; echo $?)" "rc=$rc $OFX_OUT"
fi
if want O1; then
    make_pair o1; line_on "$REC"
    bash_payload o1 "$REC" 'git commit -m "a record change"'
    hook term "$GUARD" o1 "$REC" "$ENT"; rc=$?
    check "O1 owner line: a terminal commit in the record is refused, naming the app and the way back" \
        "$([ "$rc" = 2 ] && matches "$OFX_OUT" "${REFUSED_OWNER}this terminal*record-owner.sh off*"; echo $?)" "rc=$rc $OFX_OUT"
fi
if want O2; then
    make_pair o2; line_on "$REC"
    bash_payload o2 "$REC" 'git merge some-branch'
    hook term "$GUARD" o2 "$REC" "$ENT"; rc=$?
    check "O2 owner line: a terminal merge in the record is refused" \
        "$([ "$rc" = 2 ] && matches "$OFX_OUT" '*REFUSING THIS MERGE*'; echo $?)" "rc=$rc $OFX_OUT"
fi
if want O3; then
    make_pair o3; line_on "$REC"
    bash_payload o3 "$REC" 'git commit -m "a record change"'
    hook app "$GUARD" o3 "$REC" "$ENT"; rc=$?
    check "O3 owner line: the app's lead (an sdk-* session) lands" \
        "$([ "$rc" = 0 ] && ! matches "$OFX_OUT" "$REFUSED_OWNER"; echo $?)" "rc=$rc $OFX_OUT"
fi
if want O4; then
    make_pair o4; line_on "$REC"
    bash_payload o4 "$REC" 'git commit -m "a record change"'
    hook nobody "$GUARD" o4 "$REC" "$ENT"; rc=$?
    check "O4 owner line: a caller with no session record is refused (could not tell is not allowed)" \
        "$([ "$rc" = 2 ] && matches "$OFX_OUT" "${REFUSED_OWNER}could not be identified*"; echo $?)" "rc=$rc $OFX_OUT"
fi
if want O5; then
    make_pair o5; line_on "$REC"
    git -C "$REC" worktree add -q "$OFX/o5-wt" -b o5-branch >/dev/null 2>&1
    bash_payload o5a "$OFX/o5-wt" 'git commit -m "a proposal"'
    hook term "$GUARD" o5a "$OFX/o5-wt" "$ENT"; rc1=$?; out1="$OFX_OUT"
    bash_payload o5b "$ENT" 'git commit -m "entity work"'
    hook term "$GUARD" o5b "$ENT" "$ENT"; rc2=$?; out2="$OFX_OUT"
    check "O5 owner line: a linked worktree of the record and a peer landing are not record landings" \
        "$([ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ! matches "$out1$out2" "$REFUSED_OWNER"; echo $?)" "rc=$rc1/$rc2 $out1 // $out2"
fi
if want O6; then
    make_pair o6; line_on "$REC"
    bash_payload o6 "$REC" 'git commit -m "a record change"'
    hook term "$GUARD" o6 "$REC" "$ENT"; rc1=$?
    line_off "$REC"
    hook term "$GUARD" o6 "$REC" "$ENT"; rc2=$?
    check "O6 deleting the line: the terminal lands again" \
        "$([ "$rc1" = 2 ] && [ "$rc2" = 0 ]; echo $?)" "rc=$rc1/$rc2 $OFX_OUT"
fi
if want O7; then
    make_pair o7
    bash_payload o7 "$REC" 'git commit -m "a record change"'
    printf 'ROW_RECORD_OWNER="ap %s"\n' "$MEM" >> "$REC/.row-currency"
    hook term "$GUARD" o7 "$REC" "$ENT"; r1=$?; o1="$OFX_OUT"; line_off "$REC"
    printf 'ROW_RECORD_OWNER="app"\n' >> "$REC/.row-currency"
    hook term "$GUARD" o7 "$REC" "$ENT"; r2=$?; o2="$OFX_OUT"; line_off "$REC"
    line_on "$REC"; line_on "$REC"
    hook term "$GUARD" o7 "$REC" "$ENT"; r3=$?; o3="$OFX_OUT"; line_off "$REC"
    printf 'ROW_RECORD_OWNER="app %s"\n' "$MEM" >> "$ENT/.row-currency"
    bash_payload o7p "$ENT" 'git commit -m "entity work"'
    hook term "$GUARD" o7p "$ENT" "$ENT"; r4=$?; o4="$OFX_OUT"; git -C "$ENT" checkout -q -- .row-currency
    check "O7 a malformed owner line is BROKEN: a bad value, no memory, twice, and in a peer" \
        "$([ "$r1" = 2 ] && matches "$o1" "*The only value is 'app*" \
           && [ "$r2" = 2 ] && matches "$o2" '*names no memory directory*' \
           && [ "$r3" = 2 ] && matches "$o3" '*ROW_RECORD_OWNER twice*' \
           && [ "$r4" = 2 ] && matches "$o4" '*in the peer form*'; echo $?)" \
        "rc=$r1/$r2/$r3/$r4 // $o1 // $o2 // $o3 // $o4"
fi

# --- M: the memory-directory refusal -----------------------------------------
if want M0; then
    make_pair m0
    write_payload m0 Write "$ENT" "$MEM/note.md"
    hook term "$MGUARD" m0 "$ENT" "$ENT"; rc=$?
    check "M0 no owner line: the terminal writes his memory as today, silently" \
        "$([ "$rc" = 0 ] && [ -z "$OFX_OUT" ]; echo $?)" "rc=$rc [$OFX_OUT]"
fi
if want M1; then
    make_pair m1; line_on "$REC"
    write_payload m1w Write "$ENT" "$MEM/note.md"
    hook term "$MGUARD" m1w "$ENT" "$ENT"; r1=$?; o1="$OFX_OUT"
    write_payload m1e Edit "$ENT" "$MEM/MEMORY.md"
    hook term "$MGUARD" m1e "$ENT" "$ENT"; r2=$?
    write_payload m1o Write "$ENT" "$OTHER_MEM/note.md"
    hook term "$MGUARD" m1o "$ENT" "$ENT"; r3=$?
    write_payload m1p Write "$ENT" "$ENT/memory-notes.md"
    hook term "$MGUARD" m1p "$ENT" "$ENT"; r4=$?
    check "M1 owner line: a terminal Write and Edit into his memory are refused; elsewhere passes" \
        "$([ "$r1" = 2 ] && matches "$o1" "${REFUSED_MEMORY}this terminal*record-owner.sh off*" \
           && [ "$r2" = 2 ] && [ "$r3" = 0 ] && [ "$r4" = 0 ]; echo $?)" "rc=$r1/$r2/$r3/$r4 $o1"
fi
if want M2; then
    make_pair m2; line_on "$REC"
    write_payload m2 Write "$ENT" "$MEM/note.md"
    hook app "$MGUARD" m2 "$ENT" "$ENT"; rc=$?
    check "M2 owner line: the app's lead writes his memory" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc $OFX_OUT"
fi
if want M3; then
    make_pair m3; line_on "$REC"
    write_payload m3 Write "$ENT" "$MEM/note.md"
    hook nobody "$MGUARD" m3 "$ENT" "$ENT"; rc=$?
    check "M3 owner line: a caller with no session record is refused" \
        "$([ "$rc" = 2 ] && matches "$OFX_OUT" "${REFUSED_MEMORY}could not be identified*"; echo $?)" "rc=$rc $OFX_OUT"
fi
if want M4; then
    make_pair m4; line_on "$REC"
    # Where a native worktree sits: under the entity's .claude/worktrees/, so the
    # peer pointer "../<record>" read from the worktree itself names nothing.
    WT="$ENT/.claude/worktrees/m4-agent"
    mkdir -p "$ENT/.claude/worktrees"
    git -C "$ENT" worktree add -q "$WT" -b m4-branch >/dev/null 2>&1
    write_payload m4 Write "$WT" "$MEM/note.md"
    hook term "$MGUARD" m4 "$WT" "$WT"; rc=$?
    # The hook's seat is resolved to the main checkout before the library sees
    # it, so the library's own rule (read the peer pointer from the MAIN
    # checkout) is asked directly as well, with the worktree as the root.
    lib="$(bash -c '. "$1/scripts/lib/row-currency.sh"; rc_record_owner "$2"; printf "%s|%s" "$?" "$RC_OWNER"' _ "$ENGINE_ROOT" "$WT")"
    check "M4 a seat in a linked worktree of the entity still finds the record's line" \
        "$([ "$rc" = 2 ] && [ "$lib" = "0|app" ]; echo $?)" "rc=$rc lib=[$lib] $OFX_OUT"
fi
if want M5; then
    make_pair m5; line_on "$REC"
    write_payload m5 Write "$ENT" "$MEM/note.md"
    hook term "$MGUARD" m5 "$ENT" "$ENT"; r1=$?
    line_off "$REC"
    hook term "$MGUARD" m5 "$ENT" "$ENT"; r2=$?
    check "M5 deleting the line: the terminal writes his memory again" \
        "$([ "$r1" = 2 ] && [ "$r2" = 0 ]; echo $?)" "rc=$r1/$r2 $OFX_OUT"
fi
if want M6; then
    make_pair m6
    printf 'ROW_RECORD_OWNER="app"\n' >> "$REC/.row-currency"
    write_payload m6 Write "$ENT" "$MEM/note.md"
    hook term "$MGUARD" m6 "$ENT" "$ENT"; rc=$?
    check "M6 a broken declaration: the write passes and says it was not checked" \
        "$([ "$rc" = 0 ] && matches "$OFX_OUT" '*systemMessage*NOT checked*'; echo $?)" "rc=$rc $OFX_OUT"
fi

# --- R: registration -----------------------------------------------------------
if want R1; then
    G=guard-record-owner-memory.sh
    r=0
    hook_enforced_on_surface "$ENGINE_ROOT/hooks/hooks.json" "$G" || r=1
    if [ -f "$ENGINE_ROOT/.claude/settings.local.json" ]; then
        hook_enforced_on_surface "$ENGINE_ROOT/.claude/settings.local.json" "$G" || r=1
    fi
    grep -qx "Write|$G" "$ENGINE_ROOT/scripts/hooks/dispatch-pretooluse.manifest" || r=1
    grep -q "^${G}|PreToolUse" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" || r=1
    check "R1 the memory guard runs on the Write chain, on every surface, and the probe expects it" "$r"
fi

# --- S: the switch ---------------------------------------------------------------
switch() { ofx_in term "bash '$SWITCH' $*"; }
if want S1; then
    make_pair s1
    before="$(git -C "$REC" rev-parse HEAD)"
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s1'" --no-load; r1=$?; o1="$OFX_OUT"
    unchanged="$( [ "$(git -C "$REC" rev-parse HEAD)" = "$before" ] && git -C "$REC" diff --quiet; echo $?)"
    bash "$COMMITTER" install --repo "$REC" --agents-dir "$AG-s1" --no-load >/dev/null 2>&1
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s1'" --no-load; r2=$?; o2="$OFX_OUT"
    files="$(git -C "$REC" show --name-only --format= HEAD | sed '/^$/d' | tr '\n' ' ')"
    count="$(git -C "$REC" rev-list --count "$before"..HEAD)"
    switch status --record "'$REC'" --agents-dir "'$AG-s1'" --no-load; o3="$OFX_OUT"
    check "S1 on: refused until the committer is installed; then one commit of one file, and the app owns it" \
        "$([ "$r1" = 2 ] && matches "$o1" '*record committer is not installed*' && [ "$unchanged" = 0 ] \
           && [ "$r2" = 0 ] && [ "$count" = 1 ] && [ "$files" = ".row-currency " ] \
           && git -C "$REC" diff --quiet && matches "$o3" '*owner  : the RichOS app*'; echo $?)" \
        "rc=$r1/$r2 count=$count files=[$files] // $o1 // $o2 // $o3"
fi
if want S2; then
    make_pair s2
    bash "$COMMITTER" install --repo "$REC" --agents-dir "$AG-s2" --no-load >/dev/null 2>&1
    before="$(git -C "$REC" rev-parse HEAD)"
    printf '# an edit in progress\n' >> "$REC/.row-currency"
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s2'" --no-load; r1=$?; o1="$OFX_OUT"
    line_off "$REC"
    switch on --record "'$REC'" --memory "'$OFX/no-such-memory'" --agents-dir "'$AG-s2'" --no-load; r2=$?; o2="$OFX_OUT"
    switch on --record "'$REC'" --memory "relative/memory" --agents-dir "'$AG-s2'" --no-load; r3=$?; o3="$OFX_OUT"
    git -C "$REC" worktree add -q "$OFX/s2-wt" -b s2-branch >/dev/null 2>&1
    switch on --record "'$OFX/s2-wt'" --memory "'$MEM'" --agents-dir "'$AG-s2'" --no-load; r4=$?; o4="$OFX_OUT"
    switch on --record "'$ENT'" --memory "'$MEM'" --agents-dir "'$AG-s2'" --no-load; r5=$?; o5="$OFX_OUT"
    check "S2 on refuses: an uncommitted declaration, a missing or relative memory, a worktree, a peer" \
        "$([ "$r1" = 2 ] && matches "$o1" '*uncommitted changes*' && [ "$r2" = 2 ] && matches "$o2" '*does not exist*' \
           && [ "$r3" = 2 ] && matches "$o3" '*absolute path*' && [ "$r4" = 2 ] && matches "$o4" '*linked worktree*' \
           && [ "$r5" = 2 ] && matches "$o5" '*peer form*' && [ "$(git -C "$REC" rev-parse HEAD)" = "$before" ]; echo $?)" \
        "rc=$r1/$r2/$r3/$r4/$r5 // $o1 // $o2 // $o3 // $o4 // $o5"
fi
if want S3; then
    make_pair s3
    bash "$COMMITTER" install --repo "$REC" --agents-dir "$AG-s3" --no-load >/dev/null 2>&1
    cp "$REC/.row-currency" "$OFX/s3-original"
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s3'" --no-load; r1=$?
    mid="$(git -C "$REC" rev-parse HEAD)"
    switch off --record "'$REC'"; r2=$?; o2="$OFX_OUT"
    files="$(git -C "$REC" show --name-only --format= HEAD | sed '/^$/d' | tr '\n' ' ')"
    switch status --record "'$REC'" --agents-dir "'$AG-s3'" --no-load; o3="$OFX_OUT"
    check "S3 off: one commit, the declaration byte-identical to before on, and status says the terminal" \
        "$([ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(git -C "$REC" rev-list --count "$mid"..HEAD)" = 1 ] \
           && [ "$files" = ".row-currency " ] && cmp -s "$OFX/s3-original" "$REC/.row-currency" \
           && matches "$o3" '*owner  : his terminal*'; echo $?)" "rc=$r1/$r2 files=[$files] // $o2 // $o3"
fi
if want S4; then
    make_pair s4
    bash "$COMMITTER" install --repo "$REC" --agents-dir "$AG-s4" --no-load >/dev/null 2>&1
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s4'" --no-load
    a="$(git -C "$REC" rev-parse HEAD)"
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-s4'" --no-load; r1=$?; o1="$OFX_OUT"
    b="$(git -C "$REC" rev-parse HEAD)"
    switch off --record "'$REC'"
    c="$(git -C "$REC" rev-parse HEAD)"
    switch off --record "'$REC'"; r2=$?; o2="$OFX_OUT"
    d="$(git -C "$REC" rev-parse HEAD)"
    check "S4 on twice and off twice: the second says so and commits nothing" \
        "$([ "$r1" = 0 ] && [ "$a" = "$b" ] && matches "$o1" '*already ON*' \
           && [ "$r2" = 0 ] && [ "$c" = "$d" ] && [ "$b" != "$c" ] && matches "$o2" '*already OFF*'; echo $?)" "$o1 // $o2"
fi

# --- P1: row 8's own proof ------------------------------------------------------
if want P1; then
    command -v node >/dev/null 2>&1 && [ -f "$LORO" ] || { bad "P1 fixture: node and the loro writer are required"; }
    make_pair p1
    bash "$COMMITTER" install --repo "$REC" --agents-dir "$AG-p1" --no-load >/dev/null 2>&1
    switch on --record "'$REC'" --memory "'$MEM'" --agents-dir "'$AG-p1'" --no-load; son=$?
    node "$LORO" append --root "$REC" --id p1-belief --kind fact --body "written by the app after cut-over" \
        --now 2026-09-28T00:00:00Z >/dev/null 2>&1; lrc=$?
    before="$(git -C "$REC" rev-parse HEAD)"
    tout="$(bash "$COMMITTER" run --repo "$REC" 2>&1)"
    files="$(git -C "$REC" show --name-only --format= HEAD | sed '/^$/d' | tr '\n' ' ')"
    check "P1 switch on, and a real loro write is committed by the record committer" \
        "$([ "$son" = 0 ] && [ "$lrc" = 0 ] && [ "$(git -C "$REC" rev-parse HEAD)" != "$before" ] \
           && [ "$files" = "loro/records/p1-belief.md " ]; echo $?)" "on=$son loro=$lrc files=[$files] $tout"
    printf 'a terminal edit\n' >> "$REC/wiki/open-items.md"
    bash_payload p1c "$REC" 'git commit -am "a terminal change"'
    hook term "$GUARD" p1c "$REC" "$ENT"; c1=$?
    write_payload p1m Write "$ENT" "$MEM/note.md"
    hook term "$MGUARD" p1m "$ENT" "$ENT"; m1=$?
    hook app "$GUARD" p1c "$REC" "$ENT"; a1=$?
    check "P1 with the line: a terminal commit and a terminal memory write are refused; the app's lead lands" \
        "$([ "$c1" = 2 ] && [ "$m1" = 2 ] && [ "$a1" = 0 ]; echo $?)" "commit=$c1 memory=$m1 app=$a1"
    python3 - "$REC/.row-currency" <<'P'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r"(?m)^ROW_RECORD_OWNER=.*\n", "", s))
P
    hook term "$GUARD" p1c "$REC" "$ENT"; c2=$?
    pre="$(git -C "$REC" rev-parse HEAD)"
    ofx_in term "cd '$REC' && git commit -q -am 'a terminal change'"; landed=$?
    hook term "$MGUARD" p1m "$ENT" "$ENT"; m2=$?
    check "P1 deleting the line reverses both: the terminal's commit is allowed and lands; his memory write passes" \
        "$([ "$c2" = 0 ] && [ "$landed" = 0 ] && [ "$(git -C "$REC" rev-parse HEAD)" != "$pre" ] && [ "$m2" = 0 ]; echo $?)" \
        "commit=$c2 landed=$landed memory=$m2 $OFX_OUT"
fi

echo ""
echo "=== one writer at cut-over: $PASS passed, $FAIL failed ==="
if [ "${#WANTED[@]}" -eq 0 ] && [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/record-owner.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/record-owner.mutation.sh"; then
        ok "M. the mutation harness: every property is load-bearing"
    else
        bad "M. the mutation harness found a property this suite does not actually prove"
    fi
fi
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
