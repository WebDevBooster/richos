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
#   BLOCK a Bash command when a write operation's OWN TARGET — never merely
#   some unrelated text elsewhere on the same command line — is a protected
#   tree in the main checkout:
#     1. a write verb (mkdir/cp/mv/rm/tee/touch/rsync): only THAT verb's own
#        argument list, up to the next `;`/`&`/`|`, is scanned for a protected
#        target. A write verb in one clause never condemns an unrelated
#        protected mention in a different clause of the same line; AND/OR
#     2. a real write-redirection (`>` / `>>`) whose TARGET TOKEN is protected.
#        fd-duplication (`2>&1`, `>&2`, `N>&M`) is excluded up front: it
#        duplicates a file descriptor and creates no file at all.
#   Each target found by (1) or (2) is then classified as before:
#     - an absolute path under <root>/<protected>/ NOT inside .claude/worktrees/,
#     - a relative protected target behind a compound `cd <repo-root> ...`, or
#     - a relative protected target while the Bash cwd IS the main checkout
#       (the real drift vector — no cd needed).
#   Everything else passes: git commands, worktree-scoped paths, reads, tests,
#   scratchpad writes, docs/scripts/config writes.
#
# WHY THE TARGET ANCHORING (root-caused 2026-08-19 in a downstream adopter,
# into the engine 2026-08-28). The earlier rule was pure co-occurrence: "a
# write-ish token appears ANYWHERE" AND "a protected path appears ANYWHERE".
# The two facts were never tied to the same operation, so ordinary reads were
# blocked — measured, on the engine's own shipped guard:
#     ls <tree>/ && ls *.csv                       -> BLOCKED (a listing)
#     python3 <tree>/gate.py --check 2>&1 | head   -> BLOCKED (2>&1 matched the
#                                                     bare redirect regex)
#     mkdir -p /tmp/scratch && cat <tree>/x.py     -> BLOCKED (unrelated clauses)
# All three now pass, and every genuine write (relative, redirect, absolute,
# cd-compound) still blocks — pinned as pairs in guard-bash-main-writes.test.sh.
#
# Acknowledged, deliberate limit — this is shell-TEXT analysis, not a shell
# parser or a sandbox: it does not see through command substitution
# (`$(mkdir ...)`), and it cannot know whether an interpreter invocation like
# `python3 <tree>/tool.py` performs file I/O of its own. That was never caught
# before or after this change; the hook's scope is and always was the Bash-cwd
# drift vector, not arbitrary-code sandboxing.
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
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

# Resolve the governed repository. Three outcomes, three different behaviors —
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
cwd = (d.get('cwd') or '').rstrip('/')

def is_abs_protected(tok):
    # Absolute path under the MAIN checkout's protected tree, outside any worktree.
    if not ROOT:
        return False
    if not re.match(r'^' + re.escape(ROOT) + r'/' + TREES + r'(?:/|\$)', tok):
        return False
    return WT not in tok

def is_rel_protected(tok):
    return bool(re.match(r'^' + TREES + r'(?:/|\$)', tok))

def cd_into_worktree_precedes():
    return bool(re.search(r'cd\s+\S*' + re.escape(WT), cmd))

def cd_to_root_precedes():
    if not ROOT:
        return False
    return bool(re.search(r'(?:^|[;&|]\s*)cd\s+' + re.escape(ROOT) + r'/?(?:\s|&&|;|\$)', cmd))

def classify_relative_hit():
    # Branch ORDER and conditions are the pre-anchoring ones, unchanged: branch
    # 2 has no in-worktree-cd exclusion (deliberately conservative), branch 3
    # does. Only the ANCHORING to a real write target is new.
    if cd_to_root_precedes():
        return 'cd-compound'
    if not cd_into_worktree_precedes() and (cwd == ROOT or not cwd):
        return 'cwd-main-relative'
    return None

def check_targets(tokens):
    for raw in tokens:
        tok = raw.strip('\'\"')
        if not tok:
            continue
        if is_abs_protected(tok):
            return 'abs:' + tok[:120]
        if is_rel_protected(tok):
            cat = classify_relative_hit()
            if cat:
                return cat
    return None

# 1) write-verb clauses — only THAT verb's own argument list (up to the next
#    ; & | control operator) is checked, never the whole command line.
VERB_CLAUSE = re.compile(r'(?:^|[;&|]\s*|\s)(mkdir|cp|mv|rm|tee|touch|rsync)\b(?P<args>[^;&|]*)')
for vm in VERB_CLAUSE.finditer(cmd):
    hit = check_targets(re.findall(r'\S+', vm.group('args')))
    if hit:
        print('BLOCK ' + hit); raise SystemExit

# 2) real write-redirection (> / >>) — only the redirect's OWN target token is
#    checked. fd-duplication (2>&1, >&2, N>&M) creates no file, so it is never
#    a write no matter what path text sits elsewhere on the line.
REDIRECT = re.compile(r'>{1,2}\s*(\S+)')
for rdm in REDIRECT.finditer(cmd):
    target = rdm.group(1)
    if target.startswith('&'):
        continue  # fd duplication, e.g. 2>&1 / >&2 — not a file write
    hit = check_targets([target])
    if hit:
        print('BLOCK ' + hit); raise SystemExit

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
