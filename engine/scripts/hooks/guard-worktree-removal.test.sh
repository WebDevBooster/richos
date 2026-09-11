#!/usr/bin/env bash
#
# guard-worktree-removal.test.sh — regression tests for the worktree-removal
# guard, scripts/hooks/guard-worktree-removal.sh (PreToolUse[Bash], blocking).
# Under docs/plans/worktree-spec-2026-09-11.md the only deleters are a land and
# a discard (scripts/workspaces.sh); the guard refuses, with no override, every
# raw command that creates or deletes what only those events may (S* below).
#
# GUARD coverage (classification / precision):
#   (a)  raw git worktree remove                  -> exit 2 (block)
#   (a2) git -C <repo> worktree remove (x-repo)   -> exit 2 (block)
#   (b)  git worktree prune (all forms)              -> exit 2 (block)
#   (c)  git branch -d/-D of a worktree-* branch  -> exit 2 (block)
#   (d)  rm -rf a .claude/worktrees/agent-* path  -> exit 2 (block)
#   (d2) rm -rf a REAL linked worktree top level  -> exit 2 (block)
#   (e)  workspaces.sh invocation                 -> exit 0 (allow)
#   S1-S9 the spec's own refusals, no override: git worktree add, a real
#        agent workspace (cc/, worktree-*) removed by hand, codex/ touched,
#        claude --worktree                        -> exit 2 even with an ack
#   (f)  worktree-remove-ack: override            -> exit 0 (allow) + one log line
#   NO FALSE FIRE:
#   (g)  git worktree list / non-worktree branch -D / rm -rf of an
#        ordinary dir / non-Bash tool / ordinary reads / garbage payload
#   (g7) *** `git rm -r <dir>` is NOT a filesystem removal ***  -> exit 0
#   (g8) *** a plain directory merely NAMED `*-wt` ***          -> exit 0
#   (g9) *** the MAIN checkout of a repo (not a linked worktree) *** -> exit 0
#   RO1-RO10 *** a READ never fires, even beside another verb's -d ***  -> exit 0
#   RO11 a raw `git worktree add` is NOT a read: refused (points 1, 3)   -> exit 2
#   RD1-RD8  *** ...and every destructive shape still blocks ***        -> exit 2
#   PR1-PR8  *** prose that DESCRIBES a removal is not one ***          -> exit 0
#   PX1-PX8  *** ...and text the shell WILL run still blocks ***        -> exit 2
#   (h)  block message names workspaces.sh, the spec's refusal and the ack
#   (i)  missing python3                          -> exit 2 (fail-closed)
#   (j)  unadopted repository                     -> exit 0 (stand down)
#   (k)  DECLARED-but-unadopted root              -> exit 2 (broken, not stand-down)
#
# g7/g8/g9 are the three cases the pre-move copy got WRONG, and they are the
# reason this guard was rewritten rather than copied. g7 blocked a legitimate
# `git rm -r scripts/hooks` during the previous migration step; g8/g9 are the
# `*-wt` naming heuristic replaced by a structural linked-worktree test.
#
# The removal HELPER this suite used to exercise (remove-agent-worktree.sh and
# its ENTITY-lock liveness rules, H1-H7) is deleted: under the spec a workspace
# is deleted by a land or a discard and by nothing else, and those are proven
# by scripts/lib/workspaces.test.sh.
#
# Run directly: scripts/hooks/guard-worktree-removal.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_GUARD="$SRC_DIR/guard-worktree-removal.sh"

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

# A REAL agent workspace (cc/ branch), a REAL native one (worktree-* branch) and
# a REAL codex/ workspace: the structural test reads their branches from disk.
AGENT_WT="$FIX/dev-abc"
git -C "$MAINREPO" worktree add -q -b cc/dev-abc "$AGENT_WT" >/dev/null 2>&1
NATIVE_WT="$FIX/agent-native"
git -C "$MAINREPO" worktree add -q -b worktree-agent-native "$NATIVE_WT" >/dev/null 2>&1
CODEX_WT="$FIX/codex-work"
git -C "$MAINREPO" worktree add -q -b codex/some-task "$CODEX_WT" >/dev/null 2>&1

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

run_case "e  workspaces.sh land -> allow" 0 \
    "$(bash_payload "scripts/workspaces.sh land dev-abc")"
run_case "e2 workspaces.sh discard via bash prefix -> allow" 0 \
    "$(bash_payload "bash ~/.claude/richos-engine/scripts/workspaces.sh discard dev-abc --reason 'superseded by dev-abd' --not-ceo-ordered 'the lead chose this'")"

run_case "f  worktree-remove-ack override -> allow" 0 \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc  # worktree-remove-ack: agent confirmed dead, unlocked wt')"

echo "  -- the spec's own refusals: no override (points 1, 2, 3, 4, 6, 7, 10) --"
run_case "S1 git worktree remove of a REAL cc/ workspace -> refuse" 2 \
    "$(bash_payload "git -C $MAINREPO worktree remove $AGENT_WT")"
run_case "S2 ...and a worktree-remove-ack does NOT exempt it" 2 \
    "$(bash_payload "git -C $MAINREPO worktree remove $AGENT_WT # worktree-remove-ack: agent confirmed dead")"
run_case "S3 git worktree remove of a REAL native worktree-* workspace + ack -> refuse" 2 \
    "$(bash_payload "git -C $MAINREPO worktree remove --force $NATIVE_WT # worktree-remove-ack: done")"
run_case "S4 rm -rf a REAL cc/ workspace + ack -> refuse" 2 \
    "$(bash_payload "rm -rf $AGENT_WT # worktree-remove-ack: done")"
run_case "S5 git branch -D cc/* + ack -> refuse" 2 \
    "$(bash_payload "git branch -D cc/dev-abc # worktree-remove-ack: done")"
run_case "S6 git worktree remove of a codex/ workspace + ack -> refuse (codex/ is never touched)" 2 \
    "$(bash_payload "git -C $MAINREPO worktree remove $CODEX_WT # worktree-remove-ack: done")"
run_case "S7 git branch -D codex/* + ack -> refuse" 2 \
    "$(bash_payload "git branch -D codex/some-task # worktree-remove-ack: done")"
run_case "S8 claude --worktree -> refuse (nobody starts a session in its own workspace)" 2 \
    "$(bash_payload "claude --worktree feature-x")"
run_case "S9 git worktree add + ack -> refuse (a raw workspace is registered by nothing)" 2 \
    "$(bash_payload "git worktree add /tmp/x -b cc/dev-new # worktree-remove-ack: done")"
run_case_msg "S10 the refusal names create-teammate-worktree.sh as the way to create one" 'create-teammate-worktree.sh <repo> <name>' \
    "$(bash_payload "git worktree add /tmp/x -b cc/dev-new")"
run_case "S11 control: a non-system linked worktree removal + ack -> allow (logged)" 0 \
    "$(bash_payload "git -C $MAINREPO worktree remove $REAL_WT # worktree-remove-ack: my own scratch checkout")"
run_case "S12 control: git branch -D of an ordinary branch -> allow" 0 \
    "$(bash_payload "git branch -D linked-old")"
run_case "S13 a trailing ack comment is not read as a worktree-* branch name -> allow" 0 \
    "$(bash_payload "git branch -D linked-old # worktree-remove-ack: my own branch")"

echo "  -- precision (must NOT fire) --"
run_case "g1 git worktree list -> allow" 0 "$(bash_payload 'git worktree list --porcelain')"
run_case "g2 plain git worktree prune (no --expire) -> block" 2 "$(bash_payload 'git worktree prune')"
run_case "b2 dry-run prune is conservatively blocked" 2 "$(bash_payload 'git worktree prune --dry-run')"
run_case "b3 negated dry-run override cannot bypass" 2 "$(bash_payload 'git worktree prune --dry-run --no-dry-run')"
run_case "b4 absolute Git prune cannot bypass" 2 "$(bash_payload '/usr/bin/git worktree prune')"
run_case "b5 quoted Git and prune cannot bypass" 2 "$(bash_payload "'/usr/bin/git' 'worktree' 'prune'")"
run_case "b6 relative Git prune cannot bypass" 2 "$(bash_payload './bin/git -C /repo worktree prune')"
run_case "b8 workspaces.sh cannot authorize a later prune" 2 "$(bash_payload 'scripts/workspaces.sh status; git worktree prune')"
run_case "b9 workspaces.sh cannot authorize a later raw worktree remove" 2 "$(bash_payload "scripts/workspaces.sh status; git -C $MAINREPO worktree remove $REAL_WT")"
run_case "b7 cross-repo quoted-path prune cannot bypass" 2 "$(bash_payload "git -C '/repo with spaces' worktree prune")"
run_case "g2b absolute read-only worktree list -> allow" 0 "$(bash_payload '/usr/bin/git worktree list --porcelain -z')"
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

# --- The 2026-09-02 read-only false positive, BOTH halves -------------------
# The defect: the branch rule's three conjuncts were three independent searches
# over the WHOLE command, so a `-d` belonging to a completely different verb in
# a different clause satisfied one of them. RO1 is the measured reproduction --
# it fired on the VERIFICATION read taken immediately after a removal that had
# just succeeded, which is the moment a guard most needs to stay quiet.
#
# RO* and RD* ship as a PAIR on purpose. A guard can be made to stop
# false-firing by making it allow everything, and a suite that only asserts the
# allow half would call that a fix. So every RO case has RD cases holding the
# other side, including the shapes where a read-only verb sits in FRONT of a
# destructive one and must not launder it.
echo "  -- read-only git verbs never fire (2026-09-02) --"
run_case "RO1 REGRESSION: ls -d then git branch --list -> allow" 0 \
    "$(bash_payload "ls -d /x/.claude/worktrees/agent-abc 2>&1; git branch --list 'worktree-agent-abc*'")"
run_case "RO2 REGRESSION: git branch --list then ls -d -> allow" 0 \
    "$(bash_payload "git branch --list 'worktree-agent-*' && ls -d /x/wt/*")"
run_case "RO3 REGRESSION: git merge-base --is-ancestor + ls -d -> allow" 0 \
    "$(bash_payload 'git merge-base --is-ancestor worktree-agent-abc main && ls -d /tmp/*')"
run_case "RO4 git for-each-ref + ls -d -> allow" 0 \
    "$(bash_payload 'git for-each-ref --format=%(refname:short) refs/heads/ ; ls -d /tmp')"
run_case "RO5 git rev-list + sort -d -> allow" 0 \
    "$(bash_payload 'git rev-list --count main..worktree-agent-abc; sort -d /tmp/x')"
run_case "RO6 git log + ls -d -> allow" 0 \
    "$(bash_payload 'git log --oneline main..worktree-agent-abc; ls -d /tmp')"
run_case "RO7 git show + ls -d -> allow" 0 \
    "$(bash_payload 'git show --stat worktree-agent-abc; ls -d /tmp')"
run_case "RO8 git status + ls -d -> allow" 0 \
    "$(bash_payload 'git status --porcelain; ls -d /tmp')"
run_case "RO9 git worktree list + ls -d -> allow" 0 \
    "$(bash_payload 'git worktree list --porcelain; ls -d /tmp')"
run_case "RO10 git branch --merged + ls -d -> allow" 0 \
    "$(bash_payload 'git branch --merged main; ls -d /tmp')"
run_case "RO11 a raw git worktree add is refused: registered by nothing (points 1, 3)" 2 \
    "$(bash_payload 'git worktree add /tmp/wt -b worktree-agent-new')"

echo "  -- ...and the destructive shapes still do (the other half) --"
run_case "RD1 ls -d THEN git branch -D worktree-* -> block" 2 \
    "$(bash_payload 'ls -d /tmp/* ; git branch -D worktree-agent-abc')"
run_case "RD2 git branch --list THEN git branch -D worktree-* -> block" 2 \
    "$(bash_payload "git branch --list 'worktree-agent-*' ; git branch -D worktree-agent-abc")"
run_case "RD3 a read-only verb does not launder a later worktree remove -> block" 2 \
    "$(bash_payload 'git log --oneline; git worktree remove /x/.claude/worktrees/agent-abc')"
run_case "RD4 git worktree list THEN prune --expire -> block" 2 \
    "$(bash_payload 'git worktree list ; git worktree prune --expire now')"
run_case "RD5 git status THEN git -C <repo> worktree remove -> block" 2 \
    "$(bash_payload "git status --porcelain && git -C $MAINREPO worktree remove $REAL_WT")"
run_case "RD6 long-form git branch --delete worktree-* -> block" 2 \
    "$(bash_payload 'git branch --delete worktree-agent-abc')"
run_case "RD7 short bundle git branch -fD worktree-* -> block" 2 \
    "$(bash_payload 'git branch -fD worktree-agent-abc')"
run_case "RD8 git worktree prune --expire=now (attached value) -> block" 2 \
    "$(bash_payload 'git worktree prune --expire=now')"

# --- PROSE IS NOT A COMMAND: the 2026-09-03/04 false positive ---------------
# The defect: the classifier scanned the whole Bash call as one string, so a
# COMMIT MESSAGE that quoted `git worktree remove` while explaining why the
# reconciler stalls on a locked quarantine was indistinguishable from the
# removal itself. It was hit live twice and routed around by rewording both
# times, which is what a false-positive class costs: the fix is always
# somebody else's job and the record cannot describe the defect being fixed.
#
# PR* and PX* ship as a PAIR, for RO/RD's reason with more force. Blanking text
# is exactly how you would disable this guard by accident, so every PR case has
# a PX case asserting that the same construct STILL blocks when the removal is
# really going to run -- including the two places where the shell would still
# expand a substitution inside otherwise-inert text.
echo "  -- prose that DESCRIBES a removal is not a removal --"
run_case "PR1 REGRESSION: git commit -m quoting 'git worktree remove' -> allow" 0 \
    "$(bash_payload 'git commit -m "the reconciler stalls: git worktree remove refuses a locked quarantine"')"
run_case "PR2 REGRESSION: a MULTI-LINE commit message quoting it -> allow" 0 \
    "$(bash_payload "$(printf 'git commit -m "the subject line\n\nthe body explains that git worktree remove --force refuses a locked\nworking tree, which is why the reconciler stalls"')")"
run_case "PR3 a message quoting the BRANCH rule -> allow" 0 \
    "$(bash_payload "git commit -m 'do not run git branch -D worktree-agent-abc by hand'")"
run_case "PR4 a message quoting the rm rule -> allow" 0 \
    "$(bash_payload "git commit -m 'never rm -rf /x/.claude/worktrees/agent-abc yourself'")"
run_case "PR5 a heredoc WRITING a document that quotes the command -> allow" 0 \
    "$(bash_payload "$(printf "cat > runbook.md <<'EOF'\nTo clean up by hand you would run:\ngit worktree remove /x/.claude/worktrees/agent-abc\nEOF")")"
run_case "PR6 a python heredoc inserting prose that quotes it -> allow" 0 \
    "$(bash_payload "$(printf "python3 - <<'PY'\nrow = 'the reconciler stalls because git worktree remove refuses a lock'\nopen('p.md','a').write(row)\nPY")")"
run_case "PR7 a heredoc writing the rm form into a document -> allow" 0 \
    "$(bash_payload "$(printf "cat > notes.txt <<'EOF'\nrm -rf /x/.claude/worktrees/agent-abc  # never do this\nEOF")")"
run_case "PR8 git commit -F - with the phrase in the heredoc body -> allow" 0 \
    "$(bash_payload "$(printf "git commit -F - <<'MSG'\nWhy the reconciler stalls\n\ngit worktree remove --force refuses a locked working tree.\nMSG")")"

echo "  -- ...and text that WILL run still blocks (the other half) --"
run_case "PX1 a safe message THEN a real removal -> block" 2 \
    "$(bash_payload 'git commit -m "an ordinary subject" && git worktree remove /x/.claude/worktrees/agent-abc')"
run_case "PX2 a heredoc fed to a SHELL is still scanned -> block" 2 \
    "$(bash_payload "$(printf "bash <<'EOF'\ngit worktree remove /x/.claude/worktrees/agent-abc\nEOF")")"
run_case "PX3 command substitution inside a DOUBLE-quoted message -> block" 2 \
    "$(bash_payload 'git commit -m "subject $(git worktree remove /x/.claude/worktrees/agent-abc)"')"
run_case "PX4 command substitution inside an UNQUOTED-tag heredoc -> block" 2 \
    "$(bash_payload "$(printf 'cat > f.txt <<EOF\n$(git worktree remove /x/.claude/worktrees/agent-abc)\nEOF')")"
run_case "PX5 a safe message THEN a worktree-* branch delete -> block" 2 \
    "$(bash_payload "git commit -m 'an ordinary subject' ; git branch -D worktree-agent-abc")"
run_case "PX6 an ack INSIDE a heredoc payload does not exempt a real removal -> block" 2 \
    "$(bash_payload "$(printf "cat > doc.md <<'EOF'\nworktree-remove-ack: this text is a document, not an override\nEOF\ngit worktree remove /x/.claude/worktrees/agent-abc")")"
run_case "PX7 a real trailing ack comment still exempts -> allow" 0 \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc # worktree-remove-ack: verified dead by the entity lock')"
run_case "PX8 a real removal with no message anywhere still blocks -> block" 2 \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"

echo "  -- block message content --"
run_case_msg "h1 block message names workspaces.sh" 'workspaces.sh land|discard' \
    "$(bash_payload 'git worktree remove /x/.claude/worktrees/agent-abc')"
run_case_msg "h2 a spec refusal names land and discard as the only deleters" 'There is no override for this refusal.' \
    "$(bash_payload "git -C $MAINREPO worktree remove $AGENT_WT")"
run_case_msg "h2b ...and the land command itself" 'workspaces.sh land <agent>' \
    "$(bash_payload "git -C $MAINREPO worktree remove $AGENT_WT")"
run_case_msg "h3 block message names the engine's workspaces.sh path" "$TMPROOT/entity/scripts/workspaces.sh" \
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
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-worktree-removal tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-worktree-removal tests: all $PASS passed ==="
    exit 0
fi
