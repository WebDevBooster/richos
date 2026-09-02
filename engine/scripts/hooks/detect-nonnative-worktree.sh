#!/usr/bin/env bash
#
# detect-nonnative-worktree.sh — PostToolUse (Agent) DETECTOR.
#
# THIRD JOB (2026-09-02) — the OWNERSHIP LEDGER REGISTRATION. Beside the
# spawned-names append below, this hook writes the durable record that lets a
# worktree's owner be judged AFTER the harness's lock is gone:
# scripts/lib/worktree-ledger.py, ~/.claude/state/worktree-ledger.jsonl. It
# records teammate, agent id (from the async-launch acknowledgement), session
# id, session pid + start time (from the native worktree's lock line, else
# CLAUDE_PID), the native worktree path, a `cwd` spawn's hand-rolled path, and
# every `cross-repo-worktree: <path>` line in the prompt. Same reason it lives
# HERE and not in the PreToolUse guard: PostToolUse fires only for a spawn that
# ran. Best-effort, never changes this hook's verdict.
#
# SECOND JOB — the spawned-names ledger APPEND. This hook is also the ONLY
# place a spawned teammate's name is written to the session-scoped
# spawned-names.log that guard-worktree-isolation.sh's name-reuse clause reads.
# The write used to live inline in that PreToolUse guard, which runs first in a
# four-hook chain, so a spawn it approved and a later hook vetoed burned its
# name for a teammate that never existed. PostToolUse fires only for a call
# that actually ran, which makes "recorded" and "created" the same event. Full
# rationale: "BLOCKED-SPAWN NAME BURN" in guard-worktree-isolation.sh. The
# CHECK stays there; only the WRITE lives here. See the block near the end.
#
# The companion to guard-worktree-isolation.sh (the PreToolUse PREVENTER).
# This is the DETECTOR: it answers "how do I know I fucked up if all guards
# fail?" It runs AFTER an Agent spawn and loudly surfaces the tell —
# independent of the preventer, so if the preventer is unloaded/disabled the
# failure still gets caught. Non-blocking (the spawn already ran): it exits 2
# only to push the warning into the model's context.
#
# It flags two things:
#   (a) THIS spawn was a file-capable agent WITHOUT native isolation AND
#       WITHOUT the "main-checkout-run:" marker — read straight from the same
#       tool_input. Deterministic and immediate; catches the exact "forgot
#       isolation:worktree" failure even with no preventer.
#   (b) ANY non-native worktree currently exists under .claude/worktrees/ —
#       i.e. a directory NOT named agent-<hex> (native isolation ALWAYS names
#       them agent-<hex> on a worktree-<hex> branch). A human-readable slug
#       like "design-v16" is the guard-free signature of a hand-rolled
#       worktree. This also nags until a lingering botched worktree is landed +
#       removed. (Deliberate hand-rolls trip it too, by design — acknowledge
#       and move on.)
#
#       TWO DIFFERENT CAUSES, and (b) does NOT tell you which — check before
#       you go hunting for a bug that isn't there:
#         1. The LEAD omitted isolation:"worktree" on the spawn. The classic.
#         2. The SUBAGENT hand-rolled a worktree ITSELF — ran `git worktree
#            add` from inside its own, perfectly correct, native worktree. Fix
#            is the same (remove the stray), but do not waste time auditing
#            spawn flags that were never wrong — check `git worktree list` for a
#            NATIVE worktree belonging to the same agent sitting right
#            alongside the stray. If it's there, cause 2 is what happened.
#
# The "main-checkout-run:" marker (see guard-worktree-isolation.sh) sanctions a
# deliberate un-isolated run. This detector RESPECTS the marker for check (a):
# do NOT warn on a launch that declared it. Check (b) — lingering hand-rolled
# worktrees on disk — is unaffected by the marker; it is about the FILESYSTEM's
# current state, not this specific launch.

set -eo pipefail

# Fail-closed, not fail-open: check (a) below depends on python3 to parse the
# spawn's tool_input. If python3 is missing, the swallowed `|| true` failure
# yields empty SUBAGENT_TYPE/ISOLATION, which reads as "nothing to warn about"
# — i.e. this detector backstop would go silently blind at the exact moment
# the preventer (guard-worktree-isolation.sh) is ALSO blind for the same
# reason. Refuse loudly instead of degrading silently.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: detect-nonnative-worktree.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/detect-nonnative-worktree.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. A log-only hook must never block a session,
# so a BROKEN root SCREAMS instead of exiting non-zero — but it screams into
# both stderr and the hook's own JSON output, so it cannot pass for a skip.
ROOT_FAILURE=""
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    ENTITY_ROOT=""
else
    ENTITY_ROOT=""
    ROOT_FAILURE="$(root_failure_banner "scripts/hooks/detect-nonnative-worktree.sh")"
    printf '%s\n' "$ROOT_FAILURE" >&2
fi

# Nothing to detect against in a repository that never adopted the engine, and
# nothing this backstop can honestly say when its root is broken — but it has
# already SCREAMED in the broken case above, which is the difference between
# this and the silent skip it replaces.
[ -n "$ENTITY_ROOT" ] || exit 0

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${READONLY_ALLOWLIST:=Explore Plan claude-code-guide statusline-setup}"
: "${SESSION_TEAMS_DIR:=$HOME/.claude/teams}"

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    st = str(ti.get("subagent_type","") or "")
    iso = str(ti.get("isolation","") or "")
    nm = str(ti.get("name","") or "")
    sid = str(d.get("session_id","") or "")
    cwd = str(ti.get("cwd","") or "")
    pr = str(ti.get("prompt","") or "")
    pr = pr.replace("\t", " ").replace("\n", "\x01")
    print("%s\t%s\t%s\t%s\t%s\t%s" % (st, iso, nm, sid, cwd, pr))
except Exception:
    print("\t\t\t\t\t")
' 2>/dev/null || printf '\t\t\t\t\t')"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f1)"
ISOLATION="$(printf '%s' "$PARSED" | cut -f2)"
NAME="$(printf '%s' "$PARSED" | cut -f3)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f4)"
SPAWN_CWD="$(printf '%s' "$PARSED" | cut -f5)"
PROMPT="$(printf '%s' "$PARSED" | cut -f6- | tr '\001' '\n')"

# Respect the same "main-checkout-run:" marker guard-worktree-isolation.sh
# honors — a sanctioned un-isolated run must not be re-flagged here.
MAIN_CHECKOUT_MARKER=""
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*main-checkout-run:[[:space:]]*.+'; then
  MAIN_CHECKOUT_MARKER="yes"
fi

WARN=()

# (a) This spawn: file-capable agent without native isolation, and without the
# main-checkout-run marker.
is_readonly=0
for a in $READONLY_ALLOWLIST; do
  [ "$SUBAGENT_TYPE" = "$a" ] && is_readonly=1
done
if [ "$is_readonly" -eq 0 ] && [ "$ISOLATION" != "worktree" ] && [ "$ISOLATION" != "remote" ] && [ -z "$MAIN_CHECKOUT_MARKER" ]; then
  WARN+=("this spawn — agent '${SUBAGENT_TYPE:-<unset/general-purpose>}' is file-capable but was spawned WITHOUT native isolation (isolation='${ISOLATION:-unset}') and carries no 'main-checkout-run:' marker. The preventive guard (guard-worktree-isolation.sh) should have blocked this; if you are seeing this, it did not. Shut this teammate down and re-spawn with isolation:\"worktree\" — or, if it genuinely must run un-isolated in the main checkout, add a 'main-checkout-run: <reason>' prompt line.")
fi

# --- SECOND JOB — the spawned-names ledger APPEND -------------------------
#
# This is the ONLY place a spawned teammate name is written to the
# session-scoped spawned-names.log that guard-worktree-isolation.sh's
# name-reuse clause CHECKS. The write used to live inline in that guard, but it
# runs FIRST in a four-hook PreToolUse[Agent] chain and any later hook can veto
# the same call — burning the name for a spawn that never executed. See
# "BLOCKED-SPAWN NAME BURN" in guard-worktree-isolation.sh.
#
# PostToolUse[Agent] fires ONLY for a tool call that actually ran, so a name is
# recorded if and only if a teammate was truly created. No re-validation is
# needed or wanted here: any non-read-only NAME reaching this point already
# passed the FULL spawn contract upstream. Read-only types (never required a
# name, never tracked) are skipped, matching the preventer's own early exit.
#
# Same directory-resolution rule as the preventer: EXACT session match only,
# overridable for tests via GUARD_ISOLATION_TEAMS_DIR; inert when no session
# team dir resolves. Best-effort — never fail this detector, and never block an
# already-executed spawn, because an append failed.
if [ "$is_readonly" -eq 0 ] && [ -n "$NAME" ] && [ -n "$SESSION_ID" ]; then
  GI_TEAMS_DIR="${GUARD_ISOLATION_TEAMS_DIR:-$SESSION_TEAMS_DIR}"
  GI_TEAM_DIR="$GI_TEAMS_DIR/session-$(printf '%s' "$SESSION_ID" | cut -c1-8)"
  mkdir -p "$GI_TEAM_DIR" 2>/dev/null || true
  printf '%s\n' "$NAME" >>"$GI_TEAM_DIR/spawned-names.log" 2>/dev/null || true
fi

# --- THIRD JOB — the OWNERSHIP LEDGER registration -------------------------
#
# The spawned-names.log above is names only: no path, no session, no pid, no
# repository. That is why a hand-rolled worktree became permanently
# undecidable the moment its owner's native worktree was landed — nothing
# durable said who owned it. This block writes what the reaper needs LATER,
# at the one moment all of it is in hand: the spawn that actually ran.
#
#   agent_id     from the async-launch acknowledgement in tool_response (the
#                same witness worker-created-handoff.sh reads). A synchronous
#                subagent run carries none; the name + session identity are
#                still recorded so a name-owned tree can be judged by session.
#   session pid  the native worktree's lock line names the host session pid
#                (measured identical for every agent of a session); CLAUDE_PID
#                is the fallback. The start time comes from `ps`, never from
#                the lock's own start string (different format and zone).
#   worktrees    the native isolation tree (<entity>/.claude/worktrees/agent-
#                <id>), a `cwd` spawn's hand-rolled tree, and every
#                `cross-repo-worktree: <path>` line in the prompt — the exact
#                path joins that need no name convention at all.
#
# Best-effort: never fails this detector. RICHOS_WORKTREE_LEDGER redirects the
# record for tests; a sandbox that lacks the library records nothing.
_LEDGER_PY="$SCRIPT_DIR/../lib/worktree-ledger.py"
if [ "$is_readonly" -eq 0 ] && [ -n "$NAME" ] && [ -f "$_LEDGER_PY" ]; then
  INPUT="$INPUT" NAME="$NAME" SESSION_ID="$SESSION_ID" SPAWN_CWD="$SPAWN_CWD" ISOLATION="$ISOLATION" \
  ENTITY_ROOT="$ENTITY_ROOT" LEDGER_PY="$_LEDGER_PY" PROMPT_TEXT="$PROMPT" \
  python3 - <<'PY' 2>/dev/null || true
import importlib.util, json, os, re, subprocess
spec = importlib.util.spec_from_file_location("wl", os.environ["LEDGER_PY"])
wl = importlib.util.module_from_spec(spec); spec.loader.exec_module(wl)

try:
    payload = json.loads(os.environ["INPUT"])
except Exception:
    payload = {}
resp = payload.get("tool_response")
try:
    resp_text = resp if isinstance(resp, str) else json.dumps(resp)
except Exception:
    resp_text = str(resp)
agent_id = wl.agent_id_from_response(resp_text) if "Async agent launched" in (resp_text or "") else ""

entity = os.environ.get("ENTITY_ROOT", "")
name = os.environ["NAME"]
sid = os.environ.get("SESSION_ID", "")
base = {"teammate": name, "session_id": sid, "agent_id": agent_id,
        "source": "detect-nonnative-worktree.sh", "isolation": os.environ.get("ISOLATION", "")}

# session identity: the native lock line first, CLAUDE_PID second
entries = wl.worktree_entries(entity) if entity else None
native_path = os.path.join(entity, ".claude", "worktrees", "agent-" + agent_id) if (entity and agent_id) else ""
lock_pid = None
native_branch = ""
native_registered = False
if entries and native_path:
    for path, branch, lock in entries:
        if wl.norm_path(path) == wl.norm_path(native_path):
            native_registered = True
            native_branch = branch
            lock_pid, _start = wl.lock_identity(lock)
            break
pid = lock_pid or wl.session_pid_from_env()
if pid:
    base["session_pid"] = int(pid)
    st = wl.pid_start(pid)
    if st:
        base["pid_start"] = st

def repo_of(path):
    try:
        r = subprocess.run(["git", "-C", path, "worktree", "list", "--porcelain"],
                           capture_output=True, text=True, timeout=10)
        first = next((l[len("worktree "):] for l in r.stdout.splitlines() if l.startswith("worktree ")), "")
        return os.path.realpath(first) if first else ""
    except Exception:
        return ""

def branch_of(path):
    try:
        r = subprocess.run(["git", "-C", path, "symbolic-ref", "-q", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return ""

wrote = 0
if agent_id or not os.environ.get("SPAWN_CWD"):
    rec = dict(base)
    rec.update({"event": "registered", "class": "native", "repo": entity,
                "worktree": native_path, "branch": native_branch or ("worktree-agent-" + agent_id if agent_id else ""),
                "native_registered": native_registered})
    wl.append(rec); wrote += 1

paths = []
cwd = os.environ.get("SPAWN_CWD", "").strip()
if cwd:
    paths.append(cwd)
for m in re.finditer(r"^[ \t]*cross-repo-worktree:[ \t]*(\S+)", os.environ.get("PROMPT_TEXT", ""), re.M):
    paths.append(m.group(1).strip())
seen = set()
for p in paths:
    p = os.path.realpath(p)
    if p in seen:
        continue
    seen.add(p)
    rec = dict(base)
    rec.update({"event": "registered", "class": "hand-rolled", "repo": repo_of(p),
                "worktree": p, "branch": branch_of(p)})
    wl.append(rec); wrote += 1
PY
fi

# (b) Any non-native worktree on disk (name != agent-<hex>).
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  base="$(basename "$wt")"
  case "$base" in
    agent-*) : ;;                       # native isolation worktree — fine
    *) WARN+=("lingering NON-NATIVE worktree: .claude/worktrees/${base} — native isolation always names worktrees 'agent-<hex>', so a readable slug means someone hand-rolled it. TWO possible causes, and this hook cannot tell them apart: (1) the LEAD omitted isolation:\"worktree\" on the spawn; or (2) the SUBAGENT ran 'git worktree add' ITSELF from inside its own correctly-native worktree — spawn flags were fine, the agent went freelance. Check 'git worktree list': if an agent-<hex> worktree for the same agent sits alongside this stray, it is cause (2), so do NOT go auditing spawn flags that were never wrong. Either way: verify + land any work on its branch, then 'git worktree remove' it — or confirm it was a deliberate hand-roll.") ;;
  esac
done < <(git -C "$ENTITY_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' | grep "/.claude/worktrees/" || true)

# --- new tells: ZOMBIE RESIDUE (dirs + processes) -------------------------
#
# A background child (a detached long-running verification — install-fresh, a
# build, a device sync) can outlive BOTH its agent AND its worktree. `git
# worktree remove` drops the registration, but the still-running orphan
# re-creates the directory on its way to a state write. Tell (b) above cannot
# catch a re-created agent-<hex> dir (its NAME is native-shaped); these two
# tells close that gap.
#
# Registry + main checkout resolved once. `git worktree list` works from any
# checkout; its FIRST porcelain 'worktree' line is the main working tree. If the
# list is empty/unavailable, MAIN_CO is empty and BOTH tells no-op — fail-safe:
# never reap when registration cannot be proven.
REGISTERED_WT="$(git -C "$ENTITY_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' || true)"
MAIN_CO="$(printf '%s\n' "$REGISTERED_WT" | head -1)"

REAPED=()
ZOMBIE_PROCS=()

# (c) ZOMBIE RESIDUE DIRECTORIES — present on disk under
# <main>/.claude/worktrees/ but ABSENT from the git registry. Unregistered ==
# unowned == safe to AUTO-REAP. A REGISTERED worktree is NEVER touched;
# registration is re-checked against a fresh list immediately before the rm.
if [ -n "$MAIN_CO" ] && [ -d "$MAIN_CO/.claude/worktrees" ]; then
  for d in "$MAIN_CO/.claude/worktrees"/*/; do
    [ -d "$d" ] || continue
    dir="$( cd "${d%/}" 2>/dev/null && pwd -P )" || continue
    if printf '%s\n' "$REGISTERED_WT" | grep -qxF "$dir"; then
      continue
    fi
    if git -C "$ENTITY_ROOT" worktree list --porcelain 2>/dev/null \
         | sed -n 's|^worktree ||p' | grep -qxF "$dir"; then
      continue
    fi
    rm -rf "$dir" 2>/dev/null || true
    REAPED+=("$dir")
  done
fi

# (d) ORPHANED PROCESSES referencing an UNREGISTERED worktree path. A background
# child can keep running after its agent and worktree are gone. REPORT-ONLY —
# never auto-kill (it may be mid-write). Scoped to THIS repo's worktrees so a
# sibling repo's live agent is never falsely flagged.
if command -v pgrep >/dev/null 2>&1 && command -v ps >/dev/null 2>&1 && [ -n "$MAIN_CO" ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    [ -n "$cmd" ] || continue
    while IFS= read -r wtpath; do
      [ -n "$wtpath" ] || continue
      case "$wtpath" in
        "$MAIN_CO"/.claude/worktrees/agent-*) : ;;
        *) continue ;;
      esac
      if printf '%s\n' "$REGISTERED_WT" | grep -qxF "$wtpath"; then
        continue
      fi
      ZOMBIE_PROCS+=("pid ${pid} -> ${wtpath}")
    done < <(printf '%s' "$cmd" | grep -oE '/[^[:space:]]*/\.claude/worktrees/agent-[A-Za-z0-9_]+' | sort -u || true)
  done < <(pgrep -f '/\.claude/worktrees/agent-' 2>/dev/null || true)
fi

if [ "${#WARN[@]}" -gt 0 ]; then
  {
    echo "============================================================"
    echo "  WORKTREE FUCK-UP DETECTED — WRONG WORKTREE DIRECTORY NAME"
    echo "============================================================"
    echo ""
    echo "The tell(s):"
    for w in "${WARN[@]}"; do
      echo "  ! $w"
    done
    echo ""
    echo "MANDATORY RESPONSE — do this NOW, before any other work:"
    echo "  1. STOP. Do not continue orchestrating."
    echo "  2. TERMINATE the mis-spawned teammate immediately (SendMessage shutdown_request),"
    echo "     and WAIT for its termination to confirm."
    echo "  3. CORRECT THE MISTAKE: preserve any committed work on its branch, then remove the"
    echo "     non-native worktree ('git worktree remove'). Re-spawn correctly with"
    echo "     isolation:\"worktree\" if the work still needs doing — or add"
    echo "     'main-checkout-run: <reason>' if it genuinely belongs in the main checkout."
    echo "  4. Verify 'git worktree list' shows only agent-<hex> worktrees before proceeding."
    echo ""
    echo "(hook: scripts/hooks/detect-nonnative-worktree.sh — detective; this is the"
    echo " guard-free backstop for when the PreToolUse preventer fails.)"
  } >&2
fi

if [ "${#REAPED[@]}" -gt 0 ] || [ "${#ZOMBIE_PROCS[@]}" -gt 0 ]; then
  {
    echo "============================================================"
    echo "  ZOMBIE WORKTREE RESIDUE — orphaned dir/process detected"
    echo "============================================================"
    echo ""
    if [ "${#REAPED[@]}" -gt 0 ]; then
      echo "AUTO-REAPED unregistered worktree director(ies) — git had already"
      echo "dropped the registration; an orphaned process re-created the path,"
      echo "so this was unowned residue (safe to remove):"
      for r in "${REAPED[@]}"; do
        echo "  - removed $r"
      done
      echo ""
    fi
    if [ "${#ZOMBIE_PROCS[@]}" -gt 0 ]; then
      echo "ORPHANED PROCESS(es) still referencing an unregistered worktree path"
      echo "- these outlived their agent AND its worktree. NOT auto-killed; verify"
      echo "and kill manually:"
      for z in "${ZOMBIE_PROCS[@]}"; do
        echo "  ! $z"
      done
      pids="$(printf '%s\n' "${ZOMBIE_PROCS[@]}" | sed -n 's/^pid \([0-9][0-9]*\) .*/\1/p' | sort -u | tr '\n' ' ')"
      echo ""
      echo "  Recommended (after confirming these are stray): kill ${pids}"
      echo ""
    fi
    echo "Corollary (CLAUDE.md non-handoff rule / playbook #13): a background"
    echo "child can outlive its agent AND its worktree — reap PROCESSES, not just"
    echo "directories, and run long verification foreground so it dies with its"
    echo "agent."
    echo "(hook: scripts/hooks/detect-nonnative-worktree.sh)"
  } >&2
fi

if [ "${#WARN[@]}" -gt 0 ] || [ "${#REAPED[@]}" -gt 0 ] || [ "${#ZOMBIE_PROCS[@]}" -gt 0 ]; then
  exit 2
fi

exit 0
