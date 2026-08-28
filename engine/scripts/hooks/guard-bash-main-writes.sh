#!/usr/bin/env bash
#
# guard-bash-main-writes.sh — PreToolUse hook on Bash.
#
# Closes the Bash-cwd drift vector: native-isolation agents' Bash cwd can
# default to the MAIN checkout, so a compound `cd <repo-root> && mkdir/cp/rm`
# command (or an absolute-path write) scaffolds files / drops artifacts directly
# into the shared checkout's SOURCE trees. The Write/Edit/MultiEdit/NotebookEdit
# guard (guard-main-checkout-writes.sh) never sees raw Bash, so these otherwise
# surface as interactive permission prompts to the human operator — who must
# never be the fallback guardrail. This hook auto-DENIES instead: exit 2 with
# worktree guidance, the agent self-corrects, no human prompt.
#
# The protected trees are project-specific and read from orchestration.config
# (PROTECTED_PATHS) — the SAME trees guard-main-checkout-writes.sh protects.
#
# Policy (conservative, matches the isolation model):
#   BLOCK a Bash command when BOTH hold:
#     1. it contains a write-ish operation (mkdir/cp/mv/rm/tee/touch/rsync or
#        shell redirection) — detection is word-boundary based; AND
#     2. it references a protected tree in the main checkout — either as an
#        absolute path NOT inside .claude/worktrees/, or via a compound
#        `cd <repo-root> ... && <write>` with a relative protected path, or a
#        relative protected write while the Bash cwd IS the main checkout (the
#        real drift vector — no cd needed).
#   Everything else passes: git commands, worktree-scoped paths, reads, tests,
#   scratchpad writes, docs/scripts/config writes.
#
# REPO_ROOT MUST be the TRUE main checkout, never a per-session worktree copy —
# this guard's cd-compound and cwd-relative branches compare against ROOT
# directly, so a worktree-resolved ROOT would BOTH over-block a legitimate
# `cd <my-worktree> && mkdir <tree>/...` AND under-block the real drift. So we
# resolve via scripts/lib/resolve-main-checkout.sh (git --git-common-dir), which
# returns the main checkout from ANY invocation location; SCRIPT_DIR/../.. is
# only the no-git fallback.
#
# Fail-closed on missing python3 (same contract as the other payload parsers):
# an unparsed payload must never silently allow a protected write.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-bash-main-writes.sh: python3 required — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-bash-main-writes.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, three different behaviours —
# see the contract for why "block everything unresolvable" is NOT the rule.
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # This repository never adopted the engine, so there is no enforcement to
    # lose here. Stand down. NOT a silent skip: engine-status.sh announces the
    # stand-down into the orchestrator's own context at every session start.
    exit 0
else
    # BROKEN: this guard believes it is governing something and cannot. Block.
    root_failure_banner "scripts/hooks/guard-bash-main-writes.sh" >&2
    exit 2
fi

# Load the GOVERNED repository's config. Note what changed: the old code
# resolved the main checkout from THIS SCRIPT'S OWN LOCATION, which is right
# only while the engine is the repository. Loaded by reference it returned the
# engine's enclosing repo, so every path comparison below was made against a
# repository the session was not editing.
CONFIG="$ENTITY_ROOT/orchestration.config"
[ -f "$CONFIG" ] && . "$CONFIG"
: "${PROTECTED_PATHS:=}"

# Sensible failure: with no protected paths configured, the guard cannot know
# what to protect. Surface it loudly (never silently) and allow the command —
# consistent with guard-main-checkout-writes.sh.
if [ -z "${PROTECTED_PATHS// /}" ]; then
    echo "(hook: guard-bash-main-writes.sh) NOTE: PROTECTED_PATHS is unset in orchestration.config — Bash-write guard is INACTIVE. Fill PROTECTED_PATHS to enable it." >&2
    exit 0
fi

# (payload already read above, before root resolution)

RESULT="$(GUARD_PAYLOAD="$INPUT" GUARD_ROOT="$ENTITY_ROOT" GUARD_TREES="$PROTECTED_PATHS" python3 -c "
import json, re, os
try:
    d = json.loads(os.environ.get('GUARD_PAYLOAD') or '{}')
except Exception:
    print('PASS'); raise SystemExit
if d.get('tool_name') != 'Bash':
    print('PASS'); raise SystemExit
cmd = (d.get('tool_input') or {}).get('command', '') or ''
ROOT = (os.environ.get('GUARD_ROOT') or '').rstrip('/')
prefixes = [p for p in (os.environ.get('GUARD_TREES') or '').split() if p]
if not prefixes:
    print('PASS'); raise SystemExit
WT = '/.claude/worktrees/'
# Protected SOURCE trees (repo-root-relative prefixes) -> regex alternation.
TREES = r'(?:' + '|'.join(re.escape(p.strip('/')) for p in prefixes) + r')'
write_re = re.compile(r'(?:^|[;&|]\s*|\s)(mkdir|cp|mv|rm|tee|touch|rsync)\s|>{1,2}\s*\S')
if not write_re.search(cmd):
    print('PASS'); raise SystemExit
# 1) absolute main-checkout source path outside any worktree
if ROOT:
    for m in re.finditer(re.escape(ROOT) + r'/' + TREES + r'/\S*', cmd):
        if WT not in m.group(0):
            print('BLOCK abs:' + m.group(0)[:120]); raise SystemExit
# 2) compound cd-to-root + relative protected write
rel_tree = re.search(r'(?<![\w/])' + TREES + r'/', cmd)
if ROOT:
    cd_root = re.search(r'(?:^|[;&|]\s*)cd\s+' + re.escape(ROOT) + r'/?(?:\s|&&|;|\$)', cmd)
    if cd_root and rel_tree:
        print('BLOCK cd-compound'); raise SystemExit
# 3) relative protected write while cwd IS the main checkout
#    (the real drift vector: agents' Bash cwd defaults to main — no cd needed)
cwd = (d.get('cwd') or '').rstrip('/')
in_worktree_cd = re.search(r'cd\s+\S*' + re.escape(WT), cmd)
if rel_tree and not in_worktree_cd and (cwd == ROOT or not cwd):
    print('BLOCK cwd-main-relative'); raise SystemExit
print('PASS')
")"

case "$RESULT" in
  PASS) exit 0 ;;
  BLOCK*)
    echo "=== guard-bash-main-writes: BLOCKED ===" >&2
    echo "  This Bash command writes into the MAIN checkout's SOURCE tree" >&2
    echo "  (protected trees: $PROTECTED_PATHS) — reason: $RESULT." >&2
    echo "  Source is edited ONLY inside your own worktree:" >&2
    echo "    $ENTITY_ROOT/.claude/worktrees/<your-agent-id>/<tree>/..." >&2
    echo "  Use ABSOLUTE paths under your worktree for every file operation; never" >&2
    echo "  'cd $ENTITY_ROOT' for writes. Main receives source only via git merge." >&2
    echo "(hook: scripts/hooks/guard-bash-main-writes.sh)" >&2
    exit 2 ;;
  *) exit 0 ;;
esac
