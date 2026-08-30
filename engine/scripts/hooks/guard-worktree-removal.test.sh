#!/usr/bin/env bash
#
# guard-worktree-removal.test.sh — regression tests for the worktree-removal
# safety PAIR, which moves and ships as one unit:
#   - scripts/hooks/guard-worktree-removal.sh   (PreToolUse[Bash] BLOCKING guard)
#   - scripts/remove-agent-worktree.sh          (sanctioned removal helper)
#
# GUARD coverage (classification / precision):
#   (a)  raw git worktree remove                  -> exit 2 (block)
#   (a2) git -C <repo> worktree remove (x-repo)   -> exit 2 (block)
#   (b)  git worktree prune --expire              -> exit 2 (block)
#   (c)  git branch -d/-D of a worktree-* branch  -> exit 2 (block)
#   (d)  rm -rf a .claude/worktrees/agent-* path  -> exit 2 (block)
#   (d2) rm -rf a REAL linked worktree top level  -> exit 2 (block)
#   (e)  helper invocation (marker present)       -> exit 0 (allow)
#   (f)  worktree-remove-ack: override            -> exit 0 (allow) + one log line
#   NO FALSE FIRE:
#   (g)  git worktree list / plain prune / non-worktree branch -D / rm -rf of an
#        ordinary dir / non-Bash tool / ordinary reads / garbage payload
#   (g7) *** `git rm -r <dir>` is NOT a filesystem removal ***  -> exit 0
#   (g8) *** a plain directory merely NAMED `*-wt` ***          -> exit 0
#   (g9) *** the MAIN checkout of a repo (not a linked worktree) *** -> exit 0
#   (h)  block message names the helper, the ENTITY liveness rule and the ack
#   (i)  missing python3                          -> exit 2 (fail-closed)
#   (j)  unadopted repository                     -> exit 0 (stand down)
#   (k)  DECLARED-but-unadopted root              -> exit 2 (broken, not stand-down)
#
# g7/g8/g9 are the three cases the pre-move copy got WRONG, and they are the
# reason this guard was rewritten rather than copied. g7 blocked a legitimate
# `git rm -r scripts/hooks` during the previous migration step; g8/g9 are the
# `*-wt` naming heuristic replaced by a structural linked-worktree test.
#
# HELPER coverage (authoritative ENTITY-lock liveness):
#   (H1) LIVE agent (locked wt + live pid)        -> REFUSE (exit 3), nothing removed
#   (H2) STALE lock (dead pid)                    -> removed (exit 0)
#   (H3) UNLOCKED entity worktree                 -> removed (exit 0)
#   (H4) ABSENT entity worktree (hand-rolled      -> removed (exit 0), correct repo
#        external-repo worktree)
#   (H5) liveness on the HAND-ROLLED worktree lock is NOT trusted — a live pid
#        there with an unlocked entity worktree is still DEAD (the incident)
#   (H6) missing required args                    -> usage error (exit 2)
#   (H7) no governed entity and no --entity-repo  -> REFUSE (exit 3), fail-closed
#
# Run directly: scripts/hooks/guard-worktree-removal.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_GUARD="$SRC_DIR/guard-worktree-removal.sh"
SRC_HELPER="$SRC_DIR/../remove-agent-worktree.sh"

# --- Sandbox: a synthetic ADOPTED entity hosting a copy of the guard --------
# The guard's bootstrap resolves its library relative to its OWN location, so a
# sandbox hosting a copy must host the library too — otherwise every case would
# fail with "BROKEN INSTALL" rather than for the reason under test. And the
# sandbox must carry orchestration.config, or the guard correctly stands down.
TMPROOT="$(mktemp -d -t guard-wt-removal.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/entity/scripts/hooks" "$TMPROOT/entity/scripts/lib"
cp "$SRC_GUARD" "$TMPROOT/entity/scripts/hooks/guard-worktree-removal.sh"
chmod +x "$TMPROOT/entity/scripts/hooks/guard-worktree-removal.sh"
cp "$SRC_DIR/../lib/resolve-roots.sh" "$TMPROOT/entity/scripts/lib/"
printf 'PROTECTED_PATHS=""\n' > "$TMPROOT/entity/orchestration.config"
GUARD="$TMPROOT/entity/scripts/hooks/guard-worktree-removal.sh"
HELPER="$SRC_HELPER"

# Declare the synthetic entity as the governed root. Without this the guard
# would resolve the LAUNCHING session's repository (the engine is itself
# adopted, and $PWD is a last-resort candidate), which is not what any case
# below is about.
RICHOS_ENTITY_ROOT="$TMPROOT/entity"
export RICHOS_ENTITY_ROOT

PASS=0
FAIL=0

run_case() { # <name> <expected-exit> <json>
    local name="$1" expected="$2" json="$3" actual
    printf '%s' "$json" | "$GUARD" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
    fi
}

run_case_msg() { # <name> <needle> <json>
    local name="$1" needle="$2" json="$3" out
    out="$(printf '%s' "$json" | "$GUARD" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (stderr missing "%s")\n' "$name" "$needle"; FAIL=$((FAIL + 1))
    fi
}

# bash_payload <command-string> — build a Bash PreToolUse payload.
bash_payload() {
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# --- Real git fixtures for the STRUCTURAL linked-worktree test --------------
# The `*-wt` string heuristic is gone, so "is this a worktree?" is now answered
# from disk. That means these cases need real repositories, not path strings.
FIX="$TMPROOT/fixtures"
mkdir -p "$FIX"
MAINREPO="$FIX/mainrepo"
mkdir -p "$MAINREPO"
git -C "$MAINREPO" init -q -b main >/dev/null 2>&1
git -C "$MAINREPO" config user.name tester >/dev/null 2>&1
git -C "$MAINREPO" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)" >/dev/null 2>&1
printf 'seed\n' > "$MAINREPO/seed.txt"
mkdir -p "$MAINREPO/scripts/hooks"
printf 'x\n' > "$MAINREPO/scripts/hooks/a.sh"
git -C "$MAINREPO" add -A >/dev/null 2>&1
git -C "$MAINREPO" commit -qm seed >/dev/null 2>&1

# A REAL linked worktree whose name does NOT end in -wt (the old heuristic
# would have missed it entirely).
REAL_WT="$FIX/linked-checkout"
git -C "$MAINREPO" worktree add -q -b linked "$REAL_WT" >/dev/null 2>&1

# A plain directory that merely LOOKS like the old convention.
DECOY_WT="$FIX/not-a-worktree-wt"
mkdir -p "$DECOY_WT"

echo "=== guard-worktree-removal: GUARD classification tests ==="

run_case "a  raw git worktree remove -> block" 2 \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"
run_case "a2 git -C cross-repo worktree remove -> block" 2 \
    "$(bash_payload "git -C $MAINREPO worktree remove $REAL_WT")"
run_case "b  git worktree prune --expire -> block" 2 \
    "$(bash_payload 'git worktree prune --expire now')"
run_case "c  git branch -D worktree-* -> block" 2 \
    "$(bash_payload 'git branch -D worktree-agent-abc')"
run_case "c2 git branch -d worktree-* -> block" 2 \
    "$(bash_payload 'git branch -d worktree-agent-abc')"
run_case "d  rm -rf .claude/worktrees/agent-* -> block" 2 \
    "$(bash_payload 'rm -rf /x/.claude/worktrees/agent-abc')"
run_case "d2 rm -rf a REAL linked worktree top level -> block" 2 \
    "$(bash_payload "rm -rf $REAL_WT")"

run_case "e  helper invocation -> allow" 0 \
    "$(bash_payload "scripts/remove-agent-worktree.sh --owner agent-abc $REAL_WT --repo $MAINREPO --branch linked")"
run_case "e2 helper via bash prefix -> allow" 0 \
    "$(bash_payload 'bash scripts/remove-agent-worktree.sh --owner agent-abc /x/.claude/worktrees/agent-abc')"

run_case "f  worktree-remove-ack override -> allow" 0 \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc  # worktree-remove-ack: agent confirmed dead, unlocked wt')"

echo "  -- precision (must NOT fire) --"
run_case "g1 git worktree list -> allow" 0 "$(bash_payload 'git worktree list --porcelain')"
run_case "g2 plain git worktree prune (no --expire) -> allow" 0 "$(bash_payload 'git worktree prune')"
run_case "g3 git branch -D non-worktree branch -> allow" 0 "$(bash_payload 'git branch -D feature-login')"
run_case "g4 rm -rf node_modules -> allow" 0 "$(bash_payload 'rm -rf node_modules')"
run_case "g5 non-Bash tool -> allow" 0 '{"tool_name":"Write","tool_input":{"file_path":"x"}}'
run_case "g6 ordinary ls -> allow" 0 "$(bash_payload 'ls -la .claude/worktrees/')"
run_case "g6b garbage payload -> allow (fail-open on parse)" 0 'not json {{{'

# --- The three cases the pre-move copy got wrong ----------------------------
# g7/g7b are PINS, not evidence: they pass under the pre-move guard too, because
# that guard's path heuristic never matched this worktree's name. g8b is the
# faithful reproduction of the incident and IS evidence — see the mutation notes.
run_case "g7 PIN: git rm -r inside a worktree -> allow" 0 \
    "$(bash_payload "cd $REAL_WT && git rm -r scripts/hooks")"
run_case "g7b PIN: git  rm (extra space) -> allow" 0 \
    "$(bash_payload "cd $REAL_WT && git  rm -r scripts/hooks")"
run_case "g7c control: a REAL rm -r in the same command shape -> block" 2 \
    "$(bash_payload "cd /tmp && rm -r $REAL_WT")"
run_case "g7d REGRESSION: git rm -r of a .claude/worktrees/agent-* path -> allow" 0 \
    "$(bash_payload 'git rm -r .claude/worktrees/agent-abc/notes')"
run_case "g7e control: a bare rm -r of the same path -> block" 2 \
    "$(bash_payload 'rm -r .claude/worktrees/agent-abc/notes')"
run_case "g8 REGRESSION: plain dir merely NAMED *-wt -> allow" 0 \
    "$(bash_payload "rm -rf $DECOY_WT")"
run_case "g8b REGRESSION: the pre-move whole-command shape -> allow" 0 \
    "$(bash_payload "cd $DECOY_WT && git rm -r scripts/hooks")"
run_case "g9 REGRESSION: the MAIN checkout is not a linked worktree -> allow" 0 \
    "$(bash_payload "rm -rf $MAINREPO")"
run_case "g10 rm -r of a SUBDIR of a worktree -> allow" 0 \
    "$(bash_payload "rm -rf $REAL_WT/scripts")"

echo "  -- block message content --"
run_case_msg "h1 block message names the helper" 'remove-agent-worktree.sh' \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"
run_case_msg "h2 block message names the ENTITY lock liveness rule" "ENTITY's isolation-worktree lock" \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"
run_case_msg "h3 block message names THIS session's entity root" "$TMPROOT/entity" \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"
run_case_msg "h4 block message names the ack override" 'worktree-remove-ack:' \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"

# (f2) ack log append — asserted on the sandbox entity, never the real repo.
ACK_LOG="$TMPROOT/entity/.claude/state/worktree-remove-acks.log"
# Measure the DELTA, not the absolute count: case (f) above already appended a
# (different) ack to this same log, so an absolute "exactly 1" would assert the
# suite's history rather than the dedup behavior under test.
ACK_BEFORE="$(wc -l < "$ACK_LOG" 2>/dev/null | tr -d ' ')"; ACK_BEFORE="${ACK_BEFORE:-0}"
ACK_PAYLOAD="$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc  # worktree-remove-ack: dead agent, artifacts collected')"
# Double-fire (two hook sources merging) must collapse to ONE new line.
for _ in 1 2; do
    printf '%s' "$ACK_PAYLOAD" | "$GUARD" >/dev/null 2>&1
done
if [ -f "$ACK_LOG" ] && grep -qF "dead agent, artifacts collected" "$ACK_LOG" 2>/dev/null; then
    printf '  PASS  f2 ack appended to the ENTITY .claude/state/worktree-remove-acks.log\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  f2 ack appended to the ENTITY .claude/state/worktree-remove-acks.log\n'; FAIL=$((FAIL + 1))
fi
ACK_AFTER="$(wc -l < "$ACK_LOG" 2>/dev/null | tr -d ' ')"; ACK_AFTER="${ACK_AFTER:-0}"
ACK_DELTA=$((ACK_AFTER - ACK_BEFORE))
if [ "$ACK_DELTA" -eq 1 ]; then
    printf '  PASS  f3 double-fire appends EXACTLY ONE new ack line (dedup)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  f3 double-fire appended %s new ack lines, expected 1 (dedup)\n' "$ACK_DELTA"; FAIL=$((FAIL + 1))
fi
# Negative arm: dedup must not swallow a genuinely DIFFERENT override.
printf '%s' "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-zzz  # worktree-remove-ack: a second, different reason')" \
    | "$GUARD" >/dev/null 2>&1
ACK_AFTER2="$(wc -l < "$ACK_LOG" 2>/dev/null | tr -d ' ')"; ACK_AFTER2="${ACK_AFTER2:-0}"
if [ "$((ACK_AFTER2 - ACK_AFTER))" -eq 1 ]; then
    printf '  PASS  f4 a DIFFERENT ack still appends (dedup is not swallowing)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  f4 a DIFFERENT ack did not append (dedup is swallowing)\n'; FAIL=$((FAIL + 1))
fi

# (i) missing python3 -> fail-closed (exit 2). Scrub PATH of python3.
NOPY_DIR="$TMPROOT/nopy"
mkdir -p "$NOPY_DIR"
for b in bash cat dirname grep sed date tr cut mkdir head printf env tail wc git; do
    src="$(command -v "$b" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$NOPY_DIR/$b"
done
printf '%s' "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')" | PATH="$NOPY_DIR" "$GUARD" >/dev/null 2>&1
NOPY_RC=$?
if [ "$NOPY_RC" -eq 2 ]; then
    printf '  PASS  i  missing python3 -> fail-closed (exit 2)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  i  missing python3 -> fail-closed (got exit %s)\n' "$NOPY_RC"; FAIL=$((FAIL + 1))
fi

# (j) an UNADOPTED repository -> stand down (exit 0), never block.
UNADOPTED="$TMPROOT/unadopted"
mkdir -p "$UNADOPTED"
J_RC=0
printf '%s' "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')" \
    | ( unset RICHOS_ENTITY_ROOT; cd "$UNADOPTED" && CLAUDE_PROJECT_DIR="$UNADOPTED" "$GUARD" >/dev/null 2>&1 ) || J_RC=$?
if [ "$J_RC" -eq 0 ]; then
    printf '  PASS  j  unadopted repository -> stand down (exit 0)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  j  unadopted repository -> stand down (got exit %s)\n' "$J_RC"; FAIL=$((FAIL + 1))
fi

# (k) a DECLARED root that carries no marker is BROKEN, not "not applicable".
K_RC=0
printf '%s' "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')" \
    | RICHOS_ENTITY_ROOT="$UNADOPTED" "$GUARD" >/dev/null 2>&1 || K_RC=$?
if [ "$K_RC" -eq 2 ]; then
    printf '  PASS  k  DECLARED unadopted root -> BROKEN, blocks (exit 2)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  k  DECLARED unadopted root -> BROKEN, blocks (got exit %s)\n' "$K_RC"; FAIL=$((FAIL + 1))
fi

echo ""
echo "=== remove-agent-worktree: HELPER liveness tests ==="

# Build a sandbox ENTITY repo (+ a second repo for the hand-rolled case).
HB="$TMPROOT/helper"
ENT="$HB/entity"
mkdir -p "$ENT/.claude/worktrees"
git -C "$ENT" init -q -b main >/dev/null 2>&1
git -C "$ENT" config user.name tester >/dev/null 2>&1
git -C "$ENT" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)" >/dev/null 2>&1
printf 'seed\n' > "$ENT/seed.txt"
git -C "$ENT" add seed.txt >/dev/null 2>&1
git -C "$ENT" commit -qm seed >/dev/null 2>&1

helper_case() { # <name> <expected-rc> <expected-wt-exists yes|no> <wt-path> <extra-args...>
    local name="$1" exp_rc="$2" exp_exists="$3" wt="$4"; shift 4
    "$HELPER" --entity-repo "$ENT" "$@" >/dev/null 2>&1
    local rc=$?
    local exists="no"; [ -d "$wt" ] && exists="yes"
    if [ "$rc" -eq "$exp_rc" ] && [ "$exists" = "$exp_exists" ]; then
        printf '  PASS  %s (rc=%s, wt-exists=%s)\n' "$name" "$rc" "$exists"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (rc=%s exp=%s ; wt-exists=%s exp=%s)\n' "$name" "$rc" "$exp_rc" "$exists" "$exp_exists"; FAIL=$((FAIL + 1))
    fi
}

# (H1) LIVE agent — locked entity wt with a LIVE pid -> REFUSE (exit 3), keep wt.
WT_LIVE="$ENT/.claude/worktrees/agent-live0001"
git -C "$ENT" worktree add -q -b worktree-agent-live0001 "$WT_LIVE" >/dev/null 2>&1
sleep 120 & LIVE_PID=$!
git -C "$ENT" worktree lock --reason "claude agent agent-live0001 (pid $LIVE_PID start now)" "$WT_LIVE" >/dev/null 2>&1
helper_case "H1 LIVE agent -> REFUSE, nothing removed" 3 yes "$WT_LIVE" \
    --owner agent-live0001 "$WT_LIVE" --branch worktree-agent-live0001 --force
H1_OUT="$("$HELPER" --entity-repo "$ENT" --owner agent-live0001 "$WT_LIVE" --force 2>&1 >/dev/null)"
if printf '%s' "$H1_OUT" | grep -qF "ALIVE"; then
    printf '  PASS  H1b refusal message states the agent is ALIVE\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  H1b refusal message states the agent is ALIVE\n'; FAIL=$((FAIL + 1))
fi
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

# (H2) STALE lock — dead pid -> removed.
WT_STALE="$ENT/.claude/worktrees/agent-stale002"
git -C "$ENT" worktree add -q -b worktree-agent-stale002 "$WT_STALE" >/dev/null 2>&1
git -C "$ENT" worktree lock --reason "claude agent agent-stale002 (pid 999999 start old)" "$WT_STALE" >/dev/null 2>&1
helper_case "H2 STALE lock (dead pid) -> removed" 0 no "$WT_STALE" \
    --owner agent-stale002 "$WT_STALE" --branch worktree-agent-stale002 --force

# (H3) UNLOCKED entity worktree -> removed.
WT_UNLK="$ENT/.claude/worktrees/agent-unlk003"
git -C "$ENT" worktree add -q -b worktree-agent-unlk003 "$WT_UNLK" >/dev/null 2>&1
helper_case "H3 UNLOCKED entity wt -> removed" 0 no "$WT_UNLK" \
    --owner agent-unlk003 "$WT_UNLK" --force

# (H4) hand-rolled external-repo worktree, no entity worktree at all -> removed there.
OTHER="$HB/other"
mkdir -p "$OTHER"
git -C "$OTHER" init -q -b main >/dev/null 2>&1
git -C "$OTHER" config user.name tester >/dev/null 2>&1
git -C "$OTHER" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)" >/dev/null 2>&1
printf 'r\n' > "$OTHER/r.txt"
git -C "$OTHER" add r.txt >/dev/null 2>&1
git -C "$OTHER" commit -qm r >/dev/null 2>&1
WT_HAND="$HB/other-norm-wt"
git -C "$OTHER" worktree add -q -b feat "$WT_HAND" >/dev/null 2>&1
helper_case "H4 hand-rolled external wt (no entity wt) -> removed" 0 no "$WT_HAND" \
    --owner agent-norm999 "$WT_HAND" --repo "$OTHER" --branch feat --force

# (H5) THE INCIDENT: a LIVE pid on the HAND-ROLLED worktree must NOT be trusted.
# The entity wt is UNLOCKED (the agent finished its entity-side isolation) while
# the hand-rolled wt is locked with a live pid. Liveness reads the ENTITY lock
# only -> DEAD -> removed. This is exactly the artifact that was checked wrong.
WT_ENT5="$ENT/.claude/worktrees/agent-inc005"
git -C "$ENT" worktree add -q -b worktree-agent-inc005 "$WT_ENT5" >/dev/null 2>&1
WT_HAND5="$HB/other-inc-wt"
git -C "$OTHER" worktree add -q -b feat5 "$WT_HAND5" >/dev/null 2>&1
sleep 120 & DECOY_PID=$!
git -C "$OTHER" worktree lock --reason "claude agent agent-inc005 (pid $DECOY_PID start now)" "$WT_HAND5" >/dev/null 2>&1
helper_case "H5 hand-rolled live pid NOT trusted; entity wt unlocked -> removed" 0 no "$WT_ENT5" \
    --owner agent-inc005 "$WT_ENT5" --branch worktree-agent-inc005 --force
kill "$DECOY_PID" 2>/dev/null
wait "$DECOY_PID" 2>/dev/null

# (H6) missing required args -> usage error (exit 2).
"$HELPER" --entity-repo "$ENT" --owner agent-x >/dev/null 2>&1
H6_RC=$?
if [ "$H6_RC" -eq 2 ]; then
    printf '  PASS  H6 missing worktree-path arg -> usage error (exit 2)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  H6 missing worktree-path arg -> usage error (got exit %s)\n' "$H6_RC"; FAIL=$((FAIL + 1))
fi

# (H7) NO governed entity and no --entity-repo -> REFUSE, fail-closed. The
# entity's lock is the only authoritative liveness signal; with no entity there
# is nothing to check against, and "nothing to check" must never mean "proceed".
WT_H7="$HB/other-h7-wt"
git -C "$OTHER" worktree add -q -b feat7 "$WT_H7" >/dev/null 2>&1
H7_RC=0
( unset RICHOS_ENTITY_ROOT REMOVE_AGENT_ENTITY_REPO
  cd "$HB" && CLAUDE_PROJECT_DIR="$HB" "$HELPER" --owner agent-h7 "$WT_H7" --repo "$OTHER" --force ) >/dev/null 2>&1 || H7_RC=$?
if [ "$H7_RC" -eq 3 ] && [ -d "$WT_H7" ]; then
    printf '  PASS  H7 no governed entity -> REFUSE (exit 3), nothing removed\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  H7 no governed entity -> REFUSE (rc=%s, wt-exists=%s)\n' "$H7_RC" "$([ -d "$WT_H7" ] && echo yes || echo no)"; FAIL=$((FAIL + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-worktree-removal tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-worktree-removal tests: all $PASS passed ==="
    exit 0
fi
