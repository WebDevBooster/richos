#!/usr/bin/env bash
#
# scripts/lib/resolve-model.sh — WHICH MODEL DOES THIS SPAWN ACTUALLY BOOT ON?
#                                ASKED IN ONE PLACE, ANSWERED ONCE.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Two separate guards now decide something from the model a spawn will run on:
#
#   guard-worktree-isolation.sh  clause 2b — is the <model> token in the
#                                teammate's name TRUTHFUL?
#                                clause 6  — is this a move to a LOWER
#                                capability tier than the definition's default?
#   guard-model-ceiling.sh       is this pick ABOVE the declared COST ceiling?
#
# All three questions start from the same fact and it is not a trivial one to
# compute: an explicit per-spawn `model:` wins, otherwise the `model:` line in
# the YAML frontmatter of the LIVE agent definition, resolved through the
# namespace-aware roster search in scripts/lib/resolve-roots.sh, normalized from
# a verbose id down to an alias, with "inherit" and a missing definition both
# meaning UNDETERMINABLE rather than "sonnet, probably".
#
# A SECOND COPY OF THAT IS THE DEFECT, NOT A CONVENIENCE. This engine's most
# expensive recurring failure is two pieces of code answering one question and
# quietly disagreeing: the capability order lived in prose and got guessed at
# (scripts/lib/model-tiers.sh); the "which repository am I governing" question
# lived in ~35 hand-copied blocks until it did not (scripts/lib/resolve-roots.sh);
# the "which repository is this git command talking to" question lived in five
# copies and four of them were wrong (scripts/lib/git-jurisdiction.sh). A cost
# ceiling that reads "fable" while the naming clause reads "opus" for the SAME
# spawn is that shape again, and it would surface as a refusal the operator
# cannot make sense of — or, worse, as no refusal at all.
#
# So the resolver moved HERE, byte-for-byte out of guard-worktree-isolation.sh,
# and both guards source it. There is exactly one answer, and both guards are
# wrong together or right together.
#
# ===========================================================================
# THE CONTRACT
# ===========================================================================
#   resolve_expected_model <override> <subagent_type>
#
#     Echoes the model alias this spawn is EXPECTED to boot on, or:
#       ""             UNDETERMINABLE — no override (or `inherit`) AND no live
#                      definition default. The boot model is the session's, and
#                      a spawn is never judged on unknowable information.
#       "UNRESOLVABLE" the subagent_type is NAMESPACED and no definition for it
#                      was found anywhere. That is a broken configuration, NOT
#                      "no definition exists", so it is reported rather than
#                      laundered into "".
#
#     ALWAYS returns 0. Callers run under `set -e`; a library call that returned
#     non-zero inside a command substitution would kill the guard mid-decision,
#     which is a crash dressed as a verdict. Same contract as model-tiers.sh.
#
# READS THREE CALLER GLOBALS, deliberately unchanged from the inline original so
# the extraction could be proven behavior-identical rather than merely reviewed:
#   ALLOWED_MODELS  the alias set (orchestration.config), for normalization
#   ENTITY_ROOT     the governed repository, for its .claude/agents/ roster
#   ENGINE_ROOT     the engine, for its own roster and its plugin namespace
# It also needs resolve_agent_def from scripts/lib/resolve-roots.sh; source that
# FIRST. A caller that has not is a broken caller, not a soft-degrading one.
#
# Plain bash 3.2 (macOS's /bin/bash). Safe to source repeatedly.

if [ -n "${_RESOLVE_MODEL_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_RESOLVE_MODEL_SH_SOURCED=1

# resolve_expected_model <override> <subagent_type> — echo the model this spawn
# is EXPECTED to boot on, or "" (empty) if undeterminable. Precedence: an
# explicit override (arg 1) wins; else the model: line in the YAML frontmatter
# of the LIVE agent definition .claude/agents/<subagent>.md (arg 2, FIRST
# frontmatter block only). LIVE agents ONLY — a non-live template under
# .claude/agents/templates/ is never a spawnable subagent_type, so the plain
# .claude/agents/<subagent>.md path can never reach templates/. A "inherit"
# override, a missing/non-live definition, or a def with no frontmatter model
# line all yield "" (undeterminable). Always returns 0.
resolve_expected_model() {
  local override="$1" subagent="$2" lo m def
  if [ -n "$override" ]; then
    lo="$(printf '%s' "$override" | tr '[:upper:]' '[:lower:]')"
    [ "$lo" = "inherit" ] && { printf ''; return 0; }
    # Normalize a verbose id (e.g. "claude-opus-4-8") down to its alias.
    for m in $ALLOWED_MODELS; do
      case "$lo" in *"$m"*) printf '%s' "$m"; return 0;; esac
    done
    printf '%s' "$lo"   # unknown override: emit as-is (will mismatch -> block)
    return 0
  fi
  # Resolve the LIVE definition through the shared resolver, which strips a
  # plugin namespace (`richos-engine:clark` -> `clark`) and searches the
  # entity roster, then the engine's own, then AGENT_NAMESPACE_ROOTS.
  #
  # WHAT THIS FIXES: this lookup used to be a bare
  # "$REPO_ROOT/.claude/agents/${subagent}.md" stat. A plugin-supplied type
  # carries a namespace, so that path could NEVER exist, the function returned
  # "undeterminable", and clause 2b — the model-truthfulness check — silently
  # stopped checking. A guard clause that stops guarding without saying so is
  # exactly the failure class this contract exists to remove.
  #
  # rc 2 means the type is NAMESPACED and its definition could not be found
  # anywhere. That is NOT the same as "this type legitimately has no
  # definition" (host built-ins), so it is not laundered into "undeterminable":
  # it is reported as UNRESOLVABLE and the caller decides.
  def="$(resolve_agent_def "$ENTITY_ROOT" "$ENGINE_ROOT" "$subagent")"
  case $? in
    0) ;;
    2) printf 'UNRESOLVABLE'; return 0 ;;
    *) printf ''; return 0 ;;
  esac
  [ -n "$def" ] || { printf ''; return 0; }
  python3 - "$def" 2>/dev/null <<'PY' || true
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        lines = f.read().split("\n")
except Exception:
    sys.exit(0)
# frontmatter = the block between the FIRST '---' and the next '---' only.
if not lines or lines[0].strip() != "---":
    sys.exit(0)
for ln in lines[1:]:
    if ln.strip() == "---":
        break
    s = ln.strip()
    if s.lower().startswith("model:"):
        print(s.split(":", 1)[1].strip().strip('"').strip("'").lower())
        break
PY
}
