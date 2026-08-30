#!/usr/bin/env bash
#
# guard-worktree-removal.sh — BLOCKING PreToolUse guard on the Bash tool.
# Makes it STRUCTURALLY impossible to remove a LIVE agent's worktree with a
# raw command.
#
# THE FAILURE MODE (a downstream adopter's operator directive, 2026-08-24):
#   The orchestrator removed a RUNNING agent's hand-rolled worktree because it
#   checked the WRONG artifact for liveness — the hand-rolled worktree (which
#   carries NO agent lock) instead of the agent's native isolation-worktree
#   lock in the ENTITY's own repository. The agent was alive and had to be
#   cancelled. A doctrine note is not enough: removal must be gated by
#   STRUCTURE, like every other guard here.
#
# THE CONTRACT (precision over recall — a guard that blocks normal work gets
# disabled, so this fires ONLY on genuine worktree-destroying ops):
#   BLOCK a Bash command that is a worktree-destroying op:
#     - git worktree remove            (incl. `git -C <repo> worktree remove`)
#     - git worktree prune --expire    (plain prune is harmless -> allowed)
#     - git branch -d / -D of a `worktree-*` branch
#     - a FILESYSTEM `rm -r`/`-rf` whose target is a `.claude/worktrees/agent-*`
#       path OR the top level of a real linked git worktree (see below)
#   UNLESS one of:
#     (a) HELPER: the command invokes remove-agent-worktree.sh (its name is the
#         marker) — the ONLY blessed removal path, which performs its OWN
#         authoritative entity-lock + live-pid liveness check first.
#     (b) ACK: the command carries an explicit
#           worktree-remove-ack:<reason>
#         override token (mirrors resume-ack: / main-checkout-run:) — logged to
#         the ENTITY's .claude/state/worktree-remove-acks.log.
#   Everything else Bash-related (git worktree list, plain git worktree prune,
#   rm of non-worktree paths, ordinary git/rm) passes untouched.
#
# TWO FALSE POSITIVES THIS VERSION REMOVES, both measured on the pre-move copy:
#
#   1. `git rm` IS NOT `rm`. The old rule matched `\brm\b`, which fires inside
#      `git rm -r <dir>` — a removal of TRACKED FILES from the index, not a
#      filesystem removal and never a worktree removal. This blocked a
#      legitimate `git rm -r scripts/hooks` during the previous migration step.
#      The verb must now be a bare `rm`, never one preceded by `git`.
#
#   2. `*-wt` IS NOT "a worktree". The old rule treated any path token whose
#      last component ended in `-wt` as a worktree. That is a naming convention
#      of ONE adopter, it fires on every unrelated directory that happens to end
#      that way, and it misses every hand-rolled worktree that does not. The
#      test is now STRUCTURAL: the token must be the TOP LEVEL of a real LINKED
#      git worktree on disk — `git -C <tok> rev-parse --show-toplevel` equals the
#      token AND its `--git-common-dir` lives elsewhere (a main checkout is not a
#      linked worktree and is not what this guard is about). That covers native
#      `.claude/worktrees/agent-*` worktrees AND hand-rolled external-repo ones —
#      including the one from the 2026-08-24 incident, which the naming
#      convention only caught by luck.
#
#   `.claude/worktrees/agent-*` is KEPT as an unconditional structural match
#   alongside the linked-worktree test: that path shape is self-describing, and
#   a residue directory whose registration is already gone is exactly the shape
#   the zombie-residue doctrine says not to reach for casually.
#
# WHY THE HELPER BYPASSES THIS GUARD CLEANLY: PreToolUse[Bash] fires on the
# AGENT's top-level Bash tool call only, never on subprocesses a script spawns.
# remove-agent-worktree.sh runs `git worktree remove` internally as a
# subprocess, so the destructive git call is invisible to this hook; the guard
# sees only the helper invocation (not destructive-shaped) and allows it.
# Clause (a) is belt-and-suspenders for any invocation form where the guard
# WOULD see the git call.
#
# FAIL-CLOSED on missing python3, matching the sibling PreToolUse[Bash] guard
# (guard-bash-main-writes.sh): an unparsed payload must never wave a worktree
# removal through. (That sibling already blocks all Bash without python3, so
# this adds no new collateral.) A JSON parse error of a PRESENT payload fails
# OPEN to PASS (precision — never block unrelated Bash on a parse glitch),
# again matching the sibling.
#
# NOTE: hooks are snapshotted per session; a change here takes effect from the
# NEXT session.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-worktree-removal.sh: python3 required — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-worktree-removal.sh"
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
    root_failure_banner "scripts/hooks/guard-worktree-removal.sh" >&2
    exit 2
fi

HOOK_TAG="(hook: scripts/hooks/guard-worktree-removal.sh)"

# Detection + classification in one python pass. Prints one of:
#   PASS                     not a Bash tool / not a worktree-destroying op
#   HELPER                   destructive but invokes remove-agent-worktree.sh
#   ACK\t<reason>            destructive but carries worktree-remove-ack:<reason>
#   BLOCK\t<reasons>         destructive, no helper, no ack
#   CANDIDATE\t<reasons>\t<tok>[\t<tok>...]
#                            an `rm -r` whose targets need the STRUCTURAL
#                            linked-worktree test, which needs git. Resolved
#                            below in bash; if no target is a worktree -> PASS.
#
# The classifier is assigned to a VARIABLE via a quoted heredoc first, and only
# then handed to `python3 -c "$VAR"`. Embedding it directly inside a `$(...)`
# command substitution is what the sibling guards do, and it breaks HERE: this
# program's regexes contain a `)` inside a character class (`[^;&|)]`), and
# bash 3.2 — the /bin/bash every macOS operator runs — mis-scans that as the
# close of the command substitution even though it sits inside single quotes.
# Measured: `bash -n` reported "syntax error near unexpected token `('" 150
# lines further down, pointing at innocent code. A heredoc assignment is
# scanned once, as text, so the class is impossible.
read -r -d '' _WTR_CLASSIFIER <<'PYEOF' || true
import json, os, re

try:
    d = json.loads(os.environ.get("GUARD_PAYLOAD") or "{}")
except Exception:
    print("PASS"); raise SystemExit
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    print("PASS"); raise SystemExit
ti = d.get("tool_input") or {}
cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""

reasons = []
candidates = []

# 1) git worktree remove — incl. `git -C <repo> worktree remove ...`. The
#    [^\n;|]* between git and worktree carries -C/flags but stops at a
#    statement separator so a later, unrelated `git` cannot bleed in.
if re.search(r"\bgit\b[^\n;|]*\bworktree\s+remove\b", cmd):
    reasons.append("git worktree remove")

# 2) git worktree prune --expire (plain prune is non-destructive -> allowed)
if re.search(r"\bgit\b[^\n;|]*\bworktree\s+prune\b", cmd) and re.search(r"--expire\b", cmd):
    reasons.append("git worktree prune --expire")

# 3) git branch -d/-D of a worktree-* branch (a bare -d/-D of a NON-worktree
#    branch is NOT blocked — precision).
if (re.search(r"\bgit\b[^\n;|]*\bbranch\b", cmd)
        and re.search(r"(?:^|\s)-[dD]\b", cmd)
        and re.search(r"\bworktree-\S+", cmd)):
    reasons.append("git branch -D of a worktree-* branch")

# 4) A FILESYSTEM recursive rm whose OWN argument list names a worktree.
#
#    FIX 1 — `git rm` is not `rm`. The token immediately preceding the verb is
#    inspected, so `git rm -r <dir>` (an index removal of tracked files) never
#    reaches this rule no matter how much whitespace separates the two words.
#    `sudo rm` / `xargs rm` are NOT excluded — those really do remove files.
#
#    FIX 2 — the target must LOOK like a worktree to even become a candidate;
#    whether it IS one is decided structurally in bash, below.
RM_CLAUSE = re.compile(r"(?:^|[;&|(]\s*|\s)rm\b(?P<args>[^;&|)]*)")
for m in RM_CLAUSE.finditer(cmd):
    before = cmd[:m.start()].rstrip()
    if before.split()[-1:] == ["git"]:
        continue  # `git rm` — an index removal, not a filesystem removal
    args = m.group("args")
    if not (re.search(r"(?:^|\s)-[A-Za-z]*[rR][A-Za-z]*\b", args) or re.search(r"--recursive\b", args)):
        continue
    for raw in re.findall(r"\S+", args):
        tok = raw.strip("\"'")
        if not tok or tok.startswith("-"):
            continue
        if re.search(r"\.claude/worktrees/agent-\S*", tok):
            # Structural, self-describing, and decided without touching disk.
            reasons.append("rm -r of a .claude/worktrees/agent-* path")
        else:
            candidates.append(tok)

# Sanctioned helper invocation? (its name is the marker). Checked BEFORE the
# verdict so a helper call is allowed even when it also looks destructive.
helper = bool(re.search(r"(?:^|[\s;&|(])(?:\S*/)?remove-agent-worktree\.sh\b", cmd))
ack = re.search(r"worktree-remove-ack:[ \t]*(.+)", cmd)

if not reasons and not candidates:
    print("PASS"); raise SystemExit
if helper:
    print("HELPER"); raise SystemExit
if ack:
    print("ACK\t" + ack.group(1).strip()); raise SystemExit
if reasons:
    print("BLOCK\t" + "; ".join(sorted(set(reasons)))); raise SystemExit

# Only unresolved rm targets remain — bash decides.
print("CANDIDATE\trm -r of a linked git worktree\t" + "\t".join(candidates))
PYEOF

RESULT="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_WTR_CLASSIFIER")"

RESULT_KIND="$(printf '%s' "$RESULT" | cut -f1)"

# --- STRUCTURAL linked-worktree test (replaces the old `*-wt` heuristic) ----
# A token is a worktree iff, on disk:
#   git -C <tok> rev-parse --show-toplevel   == <tok>   (it is a TOP LEVEL, not
#                                                        some directory inside one)
#   git -C <tok> rev-parse --git-dir  differs from  --git-common-dir
#                                                       (it is LINKED, not a main
#                                                        checkout — in a main
#                                                        checkout the two are the
#                                                        SAME path, in a linked
#                                                        worktree --git-dir is
#                                                        <common>/worktrees/<name>)
# The --git-dir/--git-common-dir comparison is used rather than a `<top>/.git`
# string test because it needs no path-format flag (portable to older git) and
# is unaffected by a repository whose .git is a file, a symlink, or elsewhere.
# Any token that is not a directory, not in a repo, a subdirectory, or a main
# checkout is not a worktree and does not make the command destructive.
is_linked_worktree() { # <path>
    local p="$1" top gd cd_
    [ -d "$p" ] || return 1
    top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$(cd "$top" 2>/dev/null && pwd -P)" ] || return 1
    gd="$(cd "$p" 2>/dev/null && git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    cd_="$(cd "$p" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$cd_" in
        /*) : ;;
        *)  cd_="$(cd "$p" 2>/dev/null && cd "$cd_" 2>/dev/null && pwd -P)" || return 1 ;;
    esac
    [ -n "$gd" ] && [ -n "$cd_" ] || return 1
    [ "$gd" != "$cd_" ]
}

if [ "$RESULT_KIND" = "CANDIDATE" ]; then
    _reason="$(printf '%s' "$RESULT" | cut -f2)"
    _hit=""
    _i=3
    while :; do
        _tok="$(printf '%s' "$RESULT" | cut -f"$_i")"
        [ -n "$_tok" ] || break
        if is_linked_worktree "$_tok"; then _hit="$_tok"; break; fi
        _i=$((_i + 1))
    done
    if [ -n "$_hit" ]; then
        RESULT="$(printf 'BLOCK\t%s (%s)' "$_reason" "$_hit")"
        RESULT_KIND="BLOCK"
    else
        RESULT_KIND="PASS"
    fi
fi

case "$RESULT_KIND" in
    PASS|HELPER)
        exit 0 ;;
    ACK)
        ACK_REASON="$(printf '%s' "$RESULT" | cut -f2-)"
        # Best-effort audit log (mirrors resume-acks.log / main-checkout-runs.log),
        # written into the ENTITY's state dir — never the engine's.
        # Consecutive-duplicate dedup keyed on the ack text ONLY (the timestamp is
        # display-only) so a settings double-fire collapses to one line while two
        # genuinely different overrides both persist.
        LOG_DIR="$ENTITY_ROOT/.claude/state"
        LOG_FILE="$LOG_DIR/worktree-remove-acks.log"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        LAST_KEY=""
        [ -f "$LOG_FILE" ] && LAST_KEY="$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -f2- || true)"
        if [ "$ACK_REASON" != "$LAST_KEY" ]; then
            printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACK_REASON" \
                >>"$LOG_FILE" 2>/dev/null || true
        fi
        exit 0 ;;
    BLOCK)
        REASONS="$(printf '%s' "$RESULT" | cut -f2-)"
        {
            echo "=== Worktree-removal guard: BLOCKED ==="
            echo "  This Bash command is a worktree-destroying op ($REASONS) issued"
            echo "  RAW — not through the sanctioned helper. Removing a LIVE agent's"
            echo "  worktree corrupts its workspace and forces a cancel (the"
            echo "  2026-08-24 incident)."
            echo ""
            echo "  Use the ONLY blessed removal path, which checks the AUTHORITATIVE"
            echo "  liveness signal before removing anything:"
            echo "    $ENGINE_ROOT/scripts/remove-agent-worktree.sh \\"
            echo "        --owner <agent-id> <worktree-path> [--branch <branch>] \\"
            echo "        [--repo <repo-path>] [--force]"
            echo ""
            echo "  Liveness = the ENTITY's isolation-worktree lock with a LIVE pid."
            echo "  This session's entity is:"
            echo "    $ENTITY_ROOT"
            echo "    git -C $ENTITY_ROOT worktree list --porcelain"
            echo "      -> 'locked claude agent agent-<id> (pid <p> ...)' AND pid <p> running."
            echo "  A stale lock (dead pid), an UNLOCKED worktree, or an ABSENT one = not"
            echo "  alive. NEVER judge liveness from a hand-rolled external-repo"
            echo "  worktree — it carries no lock (the exact 2026-08-24 mistake)."
            echo ""
            echo "  Deliberate one-off override (logged): add a"
            echo "    worktree-remove-ack: <why this removal is safe>"
            echo "  token to the command."
            echo "$HOOK_TAG"
        } >&2
        exit 2 ;;
    *)
        # Unknown classifier output -> fail OPEN (precision; never block unrelated
        # Bash on an unexpected result). Destructive ops are only ever emitted as
        # BLOCK/ACK/HELPER/CANDIDATE above.
        exit 0 ;;
esac
