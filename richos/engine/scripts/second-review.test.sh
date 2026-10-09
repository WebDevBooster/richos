#!/usr/bin/env bash
#
# second-review.test.sh: THE SECOND REVIEW, STARTED BY A COMMAND, NEVER BY HAND
# (scripts/second-review.sh running scripts/lib/second_review.py), against a
# fake reviewer program and fixture state only. Never the operator's registry,
# ~/.claude/state, ~/.codex or a real model.
#
# 2026-10-08: the CEO fetched a Codex review of an agent's work by hand four
# times, and each found defects the author's tests had passed. His words
# (ruling §113): "A regular RichOS user can never be expected anything even
# remotely close to that. So, this all must be completely automated." Every
# case below fails on a checkout without scripts/second-review.sh.
#
#   C01  a handover review by teammate name: the input holds the brief exactly
#        as the teammate received it, the exact 40-character tip, the author's
#        commit message and last report; Codex runs with the pinned model and
#        effort, a workspace-write sandbox rooted at the export, outside a git
#        repository and --ephemeral (no entry in the user's Codex app); the
#        export is not the author's workspace; one ledger row with both models
#        (Codex's from its own logged session start), the CLI version and the
#        token count; the fixture is kept; the scratch is gone
#   C02  a P1 finding forces changes-requested whatever the reviewer wrote
#   C03  a recheck of the same work carries the earlier finding into the input
#   C04  a verdict naming another commit is refused: no verdict
#   C05  an answer outside the fixed shape is no verdict
#   C06  Codex at its usage limit: the Claude fallback reviews, on Opus
#   C07  Codex missing and the quota hold in force: no Claude review starts
#   C08  work Codex wrote (a codex/ branch) is reviewed by Claude
#   C09  CPU admission closed: no reviewer starts
#   C10  a reviewer past its time limit is stopped by its own process id
#   C11  no original words: refused before any reviewer runs
#   C12  the reviewer's builds are capped at 2 jobs (environment and input): on
#        2026-10-09 the CPU breaker stopped a reviewer's rustc at 5.08 cores
#   C13  second-review stopped from outside (review-watch replacing a mid-job
#        review) stops its reviewer too, and its scratch is released
#   C14  the reviewer never runs the user's own setup: Codex --ephemeral (no
#        session or history entry his Codex or ChatGPT app shows), without his
#        config.toml (its notify program made macOS ask the CEO, 2026-10-09) or
#        his exec-policy rules, notify empty, plugins, apps, hooks, computer use
#        and browser use off; Claude with no MCP server (--strict-mcp-config)
#   C15  an app review runs Claude on the account the app's work runs on when the
#        reviewer starts: started by the app's watcher (review_watch.py's spawn of
#        an app item) through this command, the reviewer gets the added account's
#        folder as CLAUDE_CONFIG_DIR and its id; after a switch back, Account 1's
#        inherited folder; the ledger stays where it was
#   C16  the app's Codex review switch (round 20.2, CEO §114) picks the reviewer of
#        each app review when it starts, through the watcher's own spawn: off (or
#        never set, first run) Claude; on with Codex signed in, Codex with every
#        isolation flag; on with Codex signed out (what `codex login status`
#        reports), Claude, and no Codex review is run; on with Codex missing, Claude
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$SCRIPT_DIR/second-review.sh"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
SB="$(scratch_new second-review-test)" || { echo "FATAL: no scratch" >&2; exit 1; }
cleanup() { scratch_release "$SB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1 -- $3"; fi; }
has()   { printf '%s' "$1" | grep -qF -- "$2"; }

# --- isolation -------------------------------------------------------------
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT RICHOS_ENGINE_ROOT CODEX_HOME
mkdir -p "$SB/bin" "$SB/state" "$SB/calls" "$SB/tmp" "$SB/claude" "$SB/codex-sessions" \
         "$SB/workspaces/agents" "$SB/workspaces/done"
export SECOND_REVIEW_STATE_DIR="$SB/state"
export SECOND_REVIEW_CODEX="$SB/bin/fake-reviewer"
export SECOND_REVIEW_CLAUDE="$SB/bin/fake-reviewer"
export SECOND_REVIEW_QUOTA_CMD="$SB/bin/fake-quota"
export SECOND_REVIEW_CPU_BUSY=10
export RICHOS_WORKSPACES_DIR="$SB/workspaces"
export RICHOS_PROJECTS_DIR="$SB/projects"
export FAKE_LOG="$SB/calls"
# The command's own scratch lands in the fixture, so the test can see it go.
RUN_TMP="$SB/tmp"
RUN_CFG="$SB/claude"

# --- the fake reviewer: Codex when called as `exec`, Claude when `-p` -------
cat >"$SB/bin/fake-reviewer" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys, time
argv = sys.argv[1:]
if argv[:1] == ["--version"]:
    print("codex-cli 9.9.9-fake")
    sys.exit(0)
if argv[:2] == ["login", "status"]:
    # What codex-cli 0.162.0-alpha.2 answers, measured 2026-10-09: exit 0 and "Logged in using
    # ChatGPT" on stderr when signed in, exit 1 and "Not logged in" when not. Never a review call.
    with open(os.path.join(os.environ["FAKE_LOG"], "..", "login-status.count"), "a") as f:
        f.write("1\n")
    if os.environ.get("FAKE_CODEX_LOGIN") == "out":
        sys.stderr.write("Not logged in\n")
        sys.exit(1)
    sys.stderr.write("Logged in using ChatGPT\n")
    sys.exit(0)
log = os.environ["FAKE_LOG"]
d = os.path.join(log, "%02d" % len(os.listdir(log)))
os.makedirs(d)
prompt = sys.stdin.read()
with open(os.path.join(d, "prompt.md"), "w") as f:
    f.write(prompt)
kind = "codex" if argv[:1] == ["exec"] else "claude"
if kind == "codex":
    # What Codex logs at RUST_LOG=codex_exec=info: its session start, with the model and effort it runs
    # and where its session record goes (None with --ephemeral, as measured on codex-cli 0.162.0-alpha.2).
    effort = ""
    for i, a in enumerate(argv):
        if a == "-c" and argv[i + 1].startswith("model_reasoning_effort="):
            effort = argv[i + 1].split("=", 1)[1].strip('"')
    if "codex_exec=info" in os.environ.get("RUST_LOG", ""):
        sys.stderr.write('2026-10-09T05:36:46Z  INFO codex.exec: codex_exec: Codex initialized with event: '
                         'SessionConfiguredEvent { model: "%s", model_provider_id: "openai", reasoning_effort: '
                         'Some(%s), rollout_path: %s }\n' % (argv[argv.index("-m") + 1], effort.capitalize(),
                         "None" if "--ephemeral" in argv else 'Some("/fake/rollout.jsonl")'))
        sys.stderr.flush()
try:
    tree_a = open(os.path.join("tree", "a.txt")).read()
except OSError:
    tree_a = ""
with open(os.path.join(d, "call.json"), "w") as f:
    json.dump({"argv": argv, "cwd": os.getcwd(), "pid": os.getpid(), "kind": kind, "tree_a": tree_a,
               "jobs": [os.environ.get(k, "") for k in ("CARGO_BUILD_JOBS", "MAKEFLAGS", "CMAKE_BUILD_PARALLEL_LEVEL")],
               "config": os.environ.get("CLAUDE_CONFIG_DIR", ""), "account": os.environ.get("RICHOS_CLAUDE_ACCOUNT", "")}, f)
mode = os.environ.get("FAKE_MODE", "pass")
if mode == "sleep":
    time.sleep(600)
if mode == "fail" and kind == "codex":
    sys.stderr.write("ERROR: You've hit your usage limit.\n")
    sys.exit(1)
m = re.search(r"^TIP: ([0-9a-f]{40})$", prompt, re.M)
answer = {"reviewed_commit": m.group(1) if m else "", "verdict": "passed", "summary": "fake review",
          "checks": ["fake check"], "findings": [], "earlier_findings": [], "not_yet_claimed": []}
if mode == "other-commit":
    answer["reviewed_commit"] = "0123456789abcdef0123456789abcdef01234567"
if mode == "p1-passed":
    answer["findings"] = [{"priority": 1, "title": "Shutdown leaves audio on disk", "files": ["a.txt:1"],
                           "evidence": "the fixture kept the file", "fixture": "fixtures/witness.txt"}]
if mode == "malformed":
    answer = {"verdict": "passed"}
os.makedirs("fixtures", exist_ok=True)
with open(os.path.join("fixtures", "witness.txt"), "w") as f:
    f.write("fixture output\n")
if kind == "codex":
    with open(argv[argv.index("-o") + 1], "w") as f:
        json.dump(answer, f)
    tid = "019fake0-0000-7000-8000-%012d" % len(os.listdir(log))
    print(json.dumps({"type": "thread.started", "thread_id": tid}))
    print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 1000, "cached_input_tokens": 900,
                                                         "output_tokens": 50}}))
else:
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "structured_output": answer,
                      "modelUsage": {"claude-opus-5-5": {"inputTokens": 100, "outputTokens": 10}},
                      "usage": {"input_tokens": 100, "output_tokens": 10}, "duration_ms": 5}))
PY
chmod +x "$SB/bin/fake-reviewer"
cat >"$SB/bin/fake-quota" <<'SH'
#!/bin/sh
echo "quota: fake reading"
exit "${FAKE_QUOTA_EXIT:-0}"
SH
chmod +x "$SB/bin/fake-quota"

# --- the author's repository and its registry record and transcript --------
REPO="$SB/repo"
# core.hooksPath=/dev/null: the machine's global commit-identity guard is for
# real repositories, not for a fixture's throwaway commits.
G() { git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=Author -c user.email=author@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$REPO"
G init -q -b main
printf 'base\n' >"$REPO/a.txt"
printf '# Rules of this repository\nAGENTS-RULE-LINE\n' >"$REPO/AGENTS.md"
G add -A; G commit -qm "base"
BASE="$(G rev-parse HEAD)"
G checkout -qb cc/echo-sonnet-x1
printf 'base\nslice one\n' >"$REPO/a.txt"
G commit -qam "Dictation slice 1: COMMIT-MESSAGE-LINE"
TIP1="$(G rev-parse HEAD)"

SID="beadfeed-0000-4000-8000-0000000000aa"
AID="abc123def456"
cat >"$SB/brief.txt" <<'TXT'
cross-repo-worktree: /somewhere/echo-sonnet-x1

**His words, the acceptance criterion:** *"A regular user can never be expected anything — even "quoted" $HOME `cmd` \ backslash."*

Line after a blank line, with trailing spaces
TXT
python3 - "$SB" "$SID" "$AID" "$REPO" <<'PY'
import json, os, sys
sb, sid, aid, repo = sys.argv[1:5]
brief = open(os.path.join(sb, "brief.txt")).read()
rec = {"key": sid + "--echo-sonnet-x1", "name": "echo-sonnet-x1", "agent_id": aid, "session_id": sid,
       "registered_at": "2026-10-09T00:00:00Z", "subagent_type": "echo",
       "workspaces": [{"repo": repo, "path": repo, "branch": "cc/echo-sonnet-x1", "kind": "cc", "deleted_at": None}]}
json.dump(rec, open(os.path.join(sb, "workspaces", "agents", rec["key"] + ".json"), "w"))
d = os.path.join(sb, "projects", "-fixture", sid, "subagents")
os.makedirs(d)
rows = [{"type": "user", "message": {"role": "user", "content": brief}},
        {"type": "user", "isMeta": True, "message": {"role": "user", "content": "<system-reminder>x</system-reminder>"}},
        {"type": "assistant", "message": {"id": "m1", "role": "assistant", "model": "claude-sonnet-5-5",
                                          "content": [{"type": "text", "text": "Starting."}]}},
        {"type": "assistant", "message": {"id": "m2", "role": "assistant", "model": "claude-sonnet-5-5",
                                          "content": [{"type": "text", "text": "LAST-REPORT-LINE: 12 tests green."}]}}]
with open(os.path.join(d, "agent-%s.jsonl" % aid), "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
json.dump({"agentType": "echo", "name": "echo-sonnet-x1", "model": "sonnet"},
          open(os.path.join(d, "agent-%s.meta.json" % aid), "w"))
PY

run() { # <args...>: runs the command with the fixture TMPDIR and config
    OUT="$(TMPDIR="$RUN_TMP" CLAUDE_CONFIG_DIR="$RUN_CFG" bash "$SR" "$@" 2>&1)"; RC=$?
}
calls() { ls "$SB/calls" | wc -l | tr -d ' '; }
last_call() { ls -d "$SB/calls"/* 2>/dev/null | tail -1; }
last_row() { tail -1 "$SB/state/reviews.jsonl" 2>/dev/null; }
field() { # <json> <python expression over r>
    printf '%s' "$1" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}"); print('"$2"')' 2>/dev/null
}
scratch_left() { find "$RUN_TMP/richos-scratch" -maxdepth 1 -name '*second-review*' 2>/dev/null | wc -l | tr -d ' '; }

echo "second-review.test.sh"

# --- C01 ---------------------------------------------------------------------
FAKE_MODE=pass run --name echo-sonnet-x1 --repo "$REPO" --trigger handover
C="$(last_call)"
check "C01 the command exits 0 on a passing verdict" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" "rc=$RC out=$OUT"
python3 - "$SB/brief.txt" "$C/prompt.md" <<'PY'
import sys
brief, prompt = open(sys.argv[1]).read(), open(sys.argv[2]).read()
sys.exit(0 if brief in prompt else 1)
PY
check "C01 the input holds the brief verbatim, as the teammate received it" $? "prompt: $C/prompt.md"
P="$(cat "$C/prompt.md" 2>/dev/null)"
has "$P" "TIP: $TIP1"; check "C01 the input names the exact 40-character tip" $? "tip $TIP1"
has "$P" "BASE: $BASE"; check "C01 the input names the base" $? "base $BASE"
has "$P" "COMMIT-MESSAGE-LINE"; check "C01 the input holds the author's commit message" $? ""
has "$P" "LAST-REPORT-LINE: 12 tests green."; check "C01 the input holds the author's last report" $? ""
has "$P" "AGENTS-RULE-LINE"; check "C01 the input holds the repository's own rules" $? ""
ARGV="$(field "$(cat "$C/call.json")" '" ".join(r["argv"])')"
CWD="$(field "$(cat "$C/call.json")" 'r["cwd"]')"
has " $ARGV " " exec "; check "C01 Codex runs as codex exec" $? "$ARGV"
has "$ARGV" "--sandbox workspace-write"; check "C01 the sandbox is workspace-write" $? "$ARGV"
has "$ARGV" "--skip-git-repo-check"; check "C01 --skip-git-repo-check" $? "$ARGV"
has "$ARGV" "-m gpt-6.1-sol"; check "C01 the model is pinned to gpt-6.1-sol" $? "$ARGV"
has "$ARGV" '-c model_reasoning_effort="high"'; check "C01 the effort is pinned to high" $? "$ARGV"
has "$ARGV" "exec --ephemeral "
check "C14 Codex runs --ephemeral: no session or history entry the user's Codex or ChatGPT app shows" $? "$ARGV"
has "$ARGV" "-C $CWD"; check "C01 the sandbox is rooted where the reviewer runs" $? "cwd=$CWD argv=$ARGV"
has "$ARGV" "--ignore-user-config --ignore-rules -c notify=[] --disable plugins --disable apps --disable hooks --disable computer_use --disable browser_use --sandbox"
check "C14 Codex runs isolated from the user's own Codex setup: no config.toml, no rules, no notify, no plugins, apps, hooks, computer or browser use" $? "$ARGV"
TREE_A="$(field "$(cat "$C/call.json")" 'r["tree_a"]')"
[ -n "$CWD" ] && [ "${CWD#"$REPO"}" = "$CWD" ] && has "$TREE_A" "slice one"
check "C01 the reviewer works in an export of the tip, never in the author's workspace" $? "cwd=$CWD tree_a=$TREE_A"
ROW="$(last_row)"
[ "$(field "$ROW" 'r["verdict"]')" = "passed" ]; check "C01 one ledger row: verdict passed" $? "$ROW"
[ "$(field "$ROW" 'r["tip"]')" = "$TIP1" ]; check "C01 the row names the exact tip" $? "$ROW"
[ "$(field "$ROW" 'r["reviewer"]')" = "codex" ] && [ "$(field "$ROW" 'r["reviewer_model"]')" = "gpt-6.1-sol" ] \
  && [ "$(field "$ROW" 'r["reviewer_effort"]')" = "high" ]
check "C01 the row records the reviewer, its model and effort as Codex's own session start logged them" $? "$ROW"
[ "$(field "$ROW" 'r["author"]')" = "echo-sonnet-x1" ] && [ "$(field "$ROW" 'r["author_model"]')" = "sonnet" ]
check "C01 the row records the author and the author's model" $? "$ROW"
[ "$(field "$ROW" 'r["cli_version"]')" = "codex-cli 9.9.9-fake" ]; check "C01 the row records the CLI version" $? "$ROW"
[ "$(field "$ROW" 'r["tokens"]["total"]')" = "1050" ] && [ "$(field "$ROW" 'r["codex_record"]')" = "None" ]
check "C01 the row records the token count, and that Codex wrote no session record" $? "$ROW"
[ "$(field "$ROW" 'r["trigger"]')" = "handover" ] && [ -n "$(field "$ROW" 'r["duration_s"]')" ]
check "C01 the row records the trigger and the duration" $? "$ROW"
RID="$(field "$ROW" 'r["id"]')"
[ -f "$SB/state/reviews/$RID/fixtures/witness.txt" ] && [ -f "$SB/state/reviews/$RID/verdict.json" ] \
  && [ -f "$SB/state/reviews/$RID/prompt.md" ]
check "C01 the full text and the fixtures are kept under reviews/<id>/" $? "id=$RID"
[ "$(scratch_left)" = "0" ] && [ ! -d "$CWD" ]; check "C01 the scratch folder is deleted" $? "left=$(scratch_left) cwd=$CWD"
has "$OUT" "SECOND-REVIEW passed"; check "C01 the verdict is printed once" $? "$OUT"

# --- C02 ---------------------------------------------------------------------
FAKE_MODE=p1-passed run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
[ "$RC" -eq 1 ] && [ "$(field "$ROW" 'r["verdict"]')" = "changes-requested" ] && [ "$(field "$ROW" 'r["forced"]')" = "True" ]
check "C02 a P1 forces changes-requested though the reviewer wrote passed" $? "rc=$RC row=$ROW"
P1ID="$(field "$ROW" 'r["id"]')"

# --- C03 ---------------------------------------------------------------------
printf 'base\nslice one\nfix\n' >"$REPO/a.txt"
G commit -qam "Dictation slice 1: the fix"
TIP2="$(G rev-parse HEAD)"
FAKE_MODE=pass run --name echo-sonnet-x1 --repo "$REPO" --trigger handover
P="$(cat "$(last_call)/prompt.md" 2>/dev/null)"
has "$P" "TIP: $TIP2" && has "$P" "$P1ID#1" && has "$P" "Shutdown leaves audio on disk"
check "C03 the recheck's input carries the earlier finding, by id, and the new tip" $? "id=$P1ID"
[ "$(field "$(last_row)" 'r["earlier_findings"]')" = "1" ]; check "C03 the row counts the earlier findings it asked about" $? "$(last_row)"

# --- C04 ---------------------------------------------------------------------
FAKE_MODE=other-commit run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
[ "$RC" -eq 2 ] && [ "$(field "$ROW" 'r["verdict"]')" = "None" ] && has "$(field "$ROW" 'r["why"]')" "0123456789ab"
check "C04 a verdict naming another commit is refused" $? "rc=$RC row=$ROW"

# --- C05 ---------------------------------------------------------------------
FAKE_MODE=malformed run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
[ "$RC" -eq 2 ] && [ "$(field "$ROW" 'r["verdict"]')" = "None" ] && has "$(field "$ROW" 'r["why"]')" "shape"
check "C05 an answer outside the fixed shape is no verdict" $? "rc=$RC row=$ROW"

# --- C06 ---------------------------------------------------------------------
N0="$(calls)"
FAKE_MODE=fail run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
CL="$(last_call)"
KIND="$(field "$(cat "$CL/call.json")" 'r["kind"]')"
CARGV="$(field "$(cat "$CL/call.json")" '" ".join(r["argv"])')"
[ "$RC" -eq 0 ] && [ "$(( $(calls) - N0 ))" = "2" ] && [ "$KIND" = "claude" ] && has "$CARGV" "--model opus" \
  && [ "$(field "$ROW" 'r["reviewer"]')" = "claude" ] && has "$(field "$ROW" 'r["fallback_why"]')" "usage limit"
check "C06 Codex at its usage limit: the Claude fallback reviews on Opus, and says why" $? "rc=$RC row=$ROW argv=$CARGV"
[ "$(field "$ROW" 'r["reviewer_model"]')" = "claude-opus-5-5" ] && [ "$(field "$ROW" 'r["author_model"]')" = "sonnet" ]
check "C06 the verdict says which model reviewed" $? "$ROW"
has "$CARGV" '"sandbox": {"enabled": true' && has "$CARGV" '"allowUnsandboxedCommands": false' \
  && has "$CARGV" "--disallowedTools Edit,Write,NotebookEdit" && has "$CARGV" "--setting-sources  "
check "C06 the Claude reviewer writes only through sandboxed Bash, with none of the lead's settings" $? "$CARGV"
has "$CARGV" "--setting-sources  --strict-mcp-config "
check "C14 the Claude reviewer starts no MCP server of the user's (--strict-mcp-config)" $? "$CARGV"

# --- C07 ---------------------------------------------------------------------
N0="$(calls)"
FAKE_QUOTA_EXIT=1 SECOND_REVIEW_CODEX="$SB/bin/no-such-codex" FAKE_MODE=pass run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
[ "$RC" -eq 2 ] && [ "$(calls)" = "$N0" ] && has "$(field "$ROW" 'r["why"]')" "quota"
check "C07 Codex missing and the quota hold in force: no Claude review starts" $? "rc=$RC row=$ROW"

# --- C08 ---------------------------------------------------------------------
G checkout -qb codex/some-fix "$BASE"
printf 'base\ncodex wrote this\n' >"$REPO/a.txt"
G commit -qam "codex: a fix"
CTIP="$(G rev-parse HEAD)"
G checkout -q cc/echo-sonnet-x1
cat >"$SB/codex-words.txt" <<'TXT'
CODEX-HANDOVER-ENTRY: READY TO LAND codex/some-fix
TXT
FAKE_MODE=pass run --repo "$REPO" --branch codex/some-fix --base "$BASE" --words-file "$SB/codex-words.txt"
ROW="$(last_row)"
KIND="$(field "$(cat "$(last_call)/call.json")" 'r["kind"]')"
[ "$RC" -eq 0 ] && [ "$KIND" = "claude" ] && [ "$(field "$ROW" 'r["author"]')" = "codex" ] && [ "$(field "$ROW" 'r["tip"]')" = "$CTIP" ]
check "C08 work Codex wrote is reviewed by Claude" $? "rc=$RC kind=$KIND row=$ROW"

# --- C09 ---------------------------------------------------------------------
N0="$(calls)"
SECOND_REVIEW_CPU_BUSY=95 FAKE_MODE=pass run --name echo-sonnet-x1 --repo "$REPO" --admission-wait 0
ROW="$(last_row)"
[ "$RC" -eq 2 ] && [ "$(calls)" = "$N0" ] && has "$(field "$ROW" 'r["why"]')" "CPU"
check "C09 CPU admission closed: no reviewer starts, and the row says why" $? "rc=$RC row=$ROW"

# --- C10 ---------------------------------------------------------------------
SECOND_REVIEW_TIMEOUT_SECONDS=2 FAKE_MODE=sleep run --name echo-sonnet-x1 --repo "$REPO"
ROW="$(last_row)"
FPID="$(field "$(cat "$(last_call)/call.json")" 'r["pid"]')"
GONE=1; if [ -n "$FPID" ] && ! kill -0 "$FPID" 2>/dev/null; then GONE=0; fi
[ "$RC" -eq 2 ] && [ "$GONE" -eq 0 ] && has "$(field "$ROW" 'r["why"]')" "time limit" && [ "$(scratch_left)" = "0" ]
check "C10 a reviewer past its time limit is stopped by its own pid; no verdict; scratch gone" $? "rc=$RC pid=$FPID row=$ROW"

# --- C11 ---------------------------------------------------------------------
N0="$(calls)"
FAKE_MODE=pass run --repo "$REPO" --tip "$TIP2" --base "$BASE"
[ "$RC" -ne 0 ] && [ "$RC" -ne 1 ] && [ "$(calls)" = "$N0" ] && has "$OUT" "original words"
check "C11 no original words: refused before any reviewer runs" $? "rc=$RC out=$OUT"

# --- C12 ---------------------------------------------------------------------
FAKE_MODE=pass run --name echo-sonnet-x1 --repo "$REPO"
C="$(last_call)"
JOBS="$(field "$(cat "$C/call.json")" '",".join(r.get("jobs") or [])')"
[ "$JOBS" = "2,-j2,2" ] && has "$(cat "$C/prompt.md")" "at most 2 jobs"
check "C12 the reviewer's builds are capped at 2 jobs, in its environment and its input" $? "jobs=$JOBS"

# --- C13 ---------------------------------------------------------------------
N0="$(calls)"
( TMPDIR="$RUN_TMP" CLAUDE_CONFIG_DIR="$RUN_CFG" FAKE_MODE=sleep exec python3 -c '
import os, subprocess, sys
p = subprocess.Popen(["bash", sys.argv[1], "--name", "echo-sonnet-x1", "--repo", sys.argv[2]], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(p.pid); sys.stdout.flush(); p.wait()' "$SR" "$REPO" >"$SB/c13.pid" ) &
WAITER=$!
for _ in $(seq 1 100); do [ "$(calls)" != "$N0" ] && [ -f "$(last_call)/call.json" ] && break; sleep 0.1; done
SRPID="$(head -1 "$SB/c13.pid" 2>/dev/null)"
RPID="$(field "$(cat "$(last_call)/call.json" 2>/dev/null)" 'r["pid"]')"
[ -n "$SRPID" ] && kill -TERM -- "-$SRPID" 2>/dev/null
wait "$WAITER" 2>/dev/null
GONE=1
for _ in $(seq 1 50); do if [ -n "$RPID" ] && ! kill -0 "$RPID" 2>/dev/null; then GONE=0; break; fi; sleep 0.1; done
[ -n "$SRPID" ] && [ "$GONE" -eq 0 ] && [ "$(scratch_left)" = "0" ]
check "C13 stopped from outside, second-review stops its reviewer and releases its scratch" $? \
    "second-review pid=$SRPID reviewer pid=$RPID gone=$GONE scratch_left=$(scratch_left)"
[ -n "$RPID" ] && kill -0 "$RPID" 2>/dev/null && kill -KILL "$RPID" 2>/dev/null

# --- C15 ---------------------------------------------------------------------
# The real second review of 802194f0e, finding 1: the app's watcher starts with a cleared
# environment, so after the user switched to an added Claude account its reviews still ran on
# the default one. Now it passes the app's account list (claude-accounts.json, which the app's
# work leases read through quota::Service::lease_account) and this command reads the account in
# use when the reviewer starts, setting its folder as a work lease does (engine_profile.rs).
# The real chain: the watcher's own spawn of an app item, this script, the reviewer it launches.
ROWS0="$(wc -l <"$SB/state/reviews.jsonl" | tr -d ' ')"
TMPDIR="$RUN_TMP" CLAUDE_CONFIG_DIR="$RUN_CFG" python3 - "$SCRIPT_DIR" "$REPO" "$(G rev-parse HEAD)" "$BASE" \
    "$SB/brief.txt" "$SB/claude-accounts.json" "$SB/bin/fake-reviewer" "$SB/account-two" "$SB/rw" <<'PY' >"$SB/c15.out" 2>&1
import json, os, sys
from types import SimpleNamespace
scripts, repo, tip, base, words, accounts, claude, folder, state = sys.argv[1:]
sys.path.insert(0, os.path.join(scripts, "lib"))
import review_watch as rw
os.environ["REVIEW_WATCH_SECOND_REVIEW"] = os.path.join(scripts, "second-review.sh")
os.environ["REVIEW_WATCH_STATE_DIR"] = state
os.makedirs(state)
log = os.environ["FAKE_LOG"]
got = []
for in_use in ("2", "1"):
    with open(accounts, "w") as f:
        json.dump({"accounts": [{"id": "1", "label": "Home"}, {"id": "2", "label": "Work", "folder": folder}],
                   "inUse": in_use}, f)
    it = rw.Item("teammate:x1", "echo-sonnet-x1", repo, tip, base, "running", ref="echo-sonnet-x1",
                 source="app", words=[words])
    it.claude, it.accounts = claude, accounts
    watcher = rw.Watcher(os.path.dirname(scripts), "", world=SimpleNamespace())
    before = len(os.listdir(log))
    pid, _start = watcher.spawn(it, "long-job", os.path.join(state, "review-%s.log" % in_use))
    watcher.children[pid].wait()
    calls = sorted(os.listdir(log))[before:]
    call = json.load(open(os.path.join(log, calls[-1], "call.json"))) if calls else {}
    got.append({"in use": in_use, "reviewer": call.get("kind"), "config": call.get("config"),
                "account": call.get("account")})
print(json.dumps(got))
cfg = os.environ["CLAUDE_CONFIG_DIR"]
sys.exit(0 if got == [{"in use": "2", "reviewer": "claude", "config": folder, "account": "2"},
                      {"in use": "1", "reviewer": "claude", "config": cfg, "account": "1"}] else 1)
PY
check "C15 an app review runs Claude on the account in use when the reviewer starts: the added account's folder, then Account 1's after a switch" \
    $? "$(cat "$SB/c15.out")"
[ "$(( $(wc -l <"$SB/state/reviews.jsonl" | tr -d ' ') - ROWS0 ))" = "2" ]
check "C15 both reviews are in the same ledger: the account's folder moves only the reviewer" $? "rows before=$ROWS0"

# --- C16 ---------------------------------------------------------------------
# The Codex review switch in the app's Settings (round 20.2; his words, §114: "we should give
# the user a toggle/switch to manually enable that"). The app saves it as codex-reviews.json
# beside its account list; the watcher hands each app item that path, and the choice is read
# when the review starts. The real chain again: the watcher's spawn of an app item, this
# script, the reviewer it launches. Each case: (setting, Codex as the Mac reports it) ->
# which reviewer ran, whether a Codex review was run at all, and its arguments.
TMPDIR="$RUN_TMP" CLAUDE_CONFIG_DIR="$RUN_CFG" python3 - "$SCRIPT_DIR" "$REPO" "$(G rev-parse HEAD)" "$BASE" \
    "$SB/brief.txt" "$SB/bin/fake-reviewer" "$SB/codex-reviews.json" "$SB/rw16" "$SB/bin/no-such-codex" <<'PY' >"$SB/c16.out" 2>&1
import json, os, sys
from types import SimpleNamespace
scripts, repo, tip, base, words, claude, setting, state, missing = sys.argv[1:]
sys.path.insert(0, os.path.join(scripts, "lib"))
import review_watch as rw
os.environ["REVIEW_WATCH_SECOND_REVIEW"] = os.path.join(scripts, "second-review.sh")
os.environ["REVIEW_WATCH_STATE_DIR"] = state
os.makedirs(state)
log = os.environ["FAKE_LOG"]
ledger = os.path.join(os.environ["SECOND_REVIEW_STATE_DIR"], "reviews.jsonl")
cases = [("never set (first run)", None, {}),
         ("off", False, {}),
         ("on, Codex signed in", True, {}),
         ("on, Codex signed out", True, {"FAKE_CODEX_LOGIN": "out"}),
         ("on, Codex missing", True, {"SECOND_REVIEW_CODEX": missing})]
got = []
for name, on, env in cases:
    if on is None:
        if os.path.exists(setting):
            os.unlink(setting)
    else:
        with open(setting, "w") as f:
            json.dump({"on": on}, f)
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    it = rw.Item("teammate:x1", "echo-sonnet-x1", repo, tip, base, "running", ref="echo-sonnet-x1",
                 source="app", words=[words])
    it.claude, it.codex_reviews = claude, setting
    watcher = rw.Watcher(os.path.dirname(scripts), "", world=SimpleNamespace())
    before = len(os.listdir(log))
    pid, _start = watcher.spawn(it, "long-job", os.path.join(state, "review-%d.log" % len(got)))
    watcher.children[pid].wait()
    for k, v in saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    calls = [json.load(open(os.path.join(log, c, "call.json"))) for c in sorted(os.listdir(log))[before:]]
    row = json.loads(open(ledger).read().splitlines()[-1])
    codex = [c for c in calls if c["kind"] == "codex"]
    got.append({"case": name, "reviewer": row.get("reviewer"), "verdict": row.get("verdict"),
                "codex runs": len(codex), "argv": " ".join(codex[0]["argv"]) if codex else "",
                "fallback": row.get("fallback_why") or ""})
print(json.dumps(got, indent=1))
ISOLATION = ("exec --ephemeral --ignore-user-config --ignore-rules -c notify=[] --disable plugins --disable apps "
             "--disable hooks --disable computer_use --disable browser_use --sandbox workspace-write")
want = {"never set (first run)": "claude", "off": "claude", "on, Codex signed in": "codex",
        "on, Codex signed out": "claude", "on, Codex missing": "claude"}
bad = []
for g in got:
    if g["reviewer"] != want[g["case"]] or g["verdict"] != "passed":
        bad.append("%s: reviewed by %s (%s), want %s" % (g["case"], g["reviewer"], g["verdict"], want[g["case"]]))
    if want[g["case"]] == "claude" and g["codex runs"]:
        bad.append("%s: a Codex review was run" % g["case"])
    if want[g["case"]] == "codex" and not g["argv"].startswith(ISOLATION):
        bad.append("%s: Codex ran without its isolation flags: %s" % (g["case"], g["argv"]))
by = {g["case"]: g for g in got}
if "signed in" not in by["on, Codex signed out"]["fallback"]:
    bad.append("signed out: the row does not say why Claude reviewed: %r" % by["on, Codex signed out"]["fallback"])
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
check "C16 the app's Codex switch picks each review's reviewer when it starts: off or never set Claude; on and signed in Codex, isolated; on and signed out or missing Claude, with no Codex review run" \
    $? "$(cat "$SB/c16.out")"

echo
echo "second-review.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
