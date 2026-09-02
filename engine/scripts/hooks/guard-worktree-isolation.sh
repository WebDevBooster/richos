#!/usr/bin/env bash
#
# guard-worktree-isolation.sh — PreToolUse guard (Agent), FIRST in the chain.
#
# HARD, PROMPT-INDEPENDENT enforcement of the teammate-spawn contract. Every
# teammate that can edit repo files MUST be spawned correctly, by STRUCTURE,
# not by the lead remembering to. This guard reads the spawn payload and BLOCKS
# the call unless the spawn is well-formed, so a correct spawn is the only spawn
# that survives.
#
# THE CONTRACT — enforced for every file-capable agent (i.e. every
# subagent_type NOT on the read-only allowlist, which is read from
# orchestration.config: READONLY_ALLOWLIST):
#   1. Native isolation:  isolation == "worktree" (or the isolated "remote")
#      -- OR -- a `cwd` inside a REGISTERED cross-repository worktree (clause
#      4, below)
#      -- OR -- an explicit "main-checkout-run:" marker line in the prompt (the
#      fallback escape hatch, see below).
#   2. A unique, well-formed, TRUTHFUL name:  "<role>-<model>-<identifier>"
#      (e.g. dev-sonnet-1, qa-opus-r3) — THREE dash-joined parts. Never bare
#      ("dev"), 2-part ("dev-1"), or run-together ("devsonnet1"). Required EVEN
#      WHEN the main-checkout-run marker is present — the marker does not relax
#      clause 2.
#        2a. The <model> token must be one of the harness's model aliases
#            (orchestration.config: ALLOWED_MODELS; default fable/opus/sonnet/haiku).
#        2b. TRUTHFULNESS: the <model> token must reflect the model the instance
#            ACTUALLY boots on. Expected model is resolved with this precedence:
#              (i)  an explicit tool_input.model override wins; else
#              (ii) the model: line in the YAML frontmatter of the LIVE agent
#                   definition .claude/agents/<subagent_type>.md.
#            LIVE agents only resolve — a non-live template under
#            .claude/agents/templates/ is never a spawnable type and is never
#            read here. If the expected model is determinable and the token
#            disagrees -> BLOCKED, naming BOTH values. If it is genuinely
#            undeterminable (no override AND no live-def default -- the
#            inherit-from-session case, or model:"inherit"), we cannot know the
#            boot model, so we require only that the token be a valid alias (2a)
#            and accept it -- a spawn is never failed on unknowable information.
#
# The "main-checkout-run:" marker is the FALLBACK escape hatch for a genuine
# one-off main-checkout run of ANY type. A prompt line beginning with
# "main-checkout-run:" followed by a short reason permits that one spawn to run
# without isolation. Every use is best-effort logged to
# .claude/state/main-checkout-runs.log so the opt-out stays auditable, never
# silent.
#
#   Without isolation, AND without the marker, AND not a read-only type
#   -> blocked, with the exact remediation spelled out inline.
#
# CLAUSE 3 — NAME REUSE IS STRUCTURALLY IMPOSSIBLE. A name that has EVER been
# used in this session's team — ACTIVE or COMPLETED — must never be reused.
# Latest-wins name shadowing and resumed-vs-respawned confusion both stem from
# names being reusable; this clause removes the ambiguity at the spawn boundary.
# There is NO escape hatch: identifiers are free (dev-1 -> dev-2 / dev-b /
# dev-0714), so a fresh name is always available.
#
#   Name-history sources (a UNION, so a past name can't slip through — see the
#   resolver for why it can't miss):
#     1. spawned-names.log — a session-scoped ledger. CHECKED here (this guard
#        reads it below), but APPENDED by the PostToolUse[Agent] partner hook,
#        scripts/hooks/detect-nonnative-worktree.sh, NOT by this PreToolUse
#        guard — see "BLOCKED-SPAWN NAME BURN" below. From the first spawn of a
#        session every name that actually EXECUTED is recorded (the can't-miss
#        primary source for real spawns); a spawn this guard itself blocks is
#        never recorded, because it never runs.
#     2. config.json members[] — every roster name, any status (the harness
#        keeps completed members with a terminal status rather than deleting).
#     3. idle-events.jsonl / task-events.jsonl teammate fields — durable
#        completion records that survive roster pruning.
#   Resolvable ONLY by EXACT session match (never a single-dir fallback). The
#   session teams dir is read from orchestration.config (SESSION_TEAMS_DIR, blank
#   -> platform default $HOME/.claude/teams); GUARD_ISOLATION_TEAMS_DIR overrides
#   it for tests. When no session team dir resolves (e.g. a bare unit-test
#   payload), the reuse clause is inert — a real session always has its team dir
#   (it auto-exists at startup), so production spawns are always covered.
#
#   HARNESS-VERSION NOTE: the members[]/status/cwd schema this clause reads is
#   harness-version-coupled (see orchestration.config). The clause fails OPEN on
#   any resolver error (never invents a collision from an IO glitch), so a schema
#   drift degrades to "no reuse check", never to a spurious block.
#
# BLOCKED-SPAWN NAME BURN.
#   This guard used to append NAME to spawned-names.log itself, inline, the
#   moment its own checks passed. But it runs FIRST in a FOUR-hook
#   PreToolUse[Agent] chain (this guard, then guard-definition-drift.sh,
#   reader-teammate-hint.sh, verify-agent-prompt.sh — see hooks/hooks.json),
#   and any LATER hook in that chain can still veto the same call. Result: a
#   spawn this guard approved but a later hook blocked burned its name anyway
#   — no teammate was ever created, yet the corrected retry under the same
#   name was refused as "reuse". Observed in production 2026-08-01, and
#   reproduced against this engine on 2026-08-28: hook 1 rc=0 and the ledger
#   gained the name; hook 4 rc=2; the corrected retry rc=2 "name reuse".
#
#   A name whose spawn never executed carries ZERO resume/shadowing risk, so
#   blocking it was pure friction, not safety.
#
#   Fix: the append now happens ONLY in the PostToolUse[Agent] partner hook
#   (scripts/hooks/detect-nonnative-worktree.sh), which — by construction —
#   never fires for a tool call a PreToolUse hook blocked. This guard still
#   performs the full CLAUSE 3 CHECK below, unchanged; it just no longer
#   performs the WRITE.
#
#   ACCEPTED RACE: two Agent calls issued in the very same in-flight turn with
#   an identical name are not caught against each other — neither hook sees
#   sibling calls still pending in the same batch, and there is no extension
#   point that inspects a whole in-flight tool-call batch. Narrow (distinct
#   identifiers are cheap) and self-healing (the second collides normally on
#   any subsequent attempt, once the first append has landed).
#
# CLAUSE 4 — CROSS-REPOSITORY WORK RUNS IN A WORKTREE RICHOS REGISTERED (2026-09-02).
#   Native isolation roots at the SESSION's repository; the Agent tool's own
#   escape hatch is `cwd`, "mutually exclusive with isolation: worktree". Until
#   now a cross-repository teammate improvised its worktree from a sentence in
#   its prompt ("git -C <repo> worktree add ..."), and nothing on disk said who
#   owned it — so the moment its native worktree was landed, the improvised
#   tree was permanently undecidable to the reaper. The rule is inverted:
#     4a. A `cwd` spawn is ALLOWED without isolation ONLY when `cwd` is the top
#         level of a LINKED git worktree AND that path is registered in the
#         ownership ledger (scripts/lib/worktree-ledger.py — written by
#         scripts/create-teammate-worktree.sh). Anything else -> BLOCKED,
#         naming the helper.
#     4b. `cwd` together with isolation:"worktree" -> BLOCKED (the harness
#         refuses the pair; saying so here is cheaper than a failed spawn).
#     4c. Every `cross-repo-worktree: <path>` line in the prompt (the shape
#         that keeps native isolation in the session repo AND names the
#         cross-repo tree) must be registered the same way -> else BLOCKED.
#     4d. A prompt that INSTRUCTS the teammate to run `git worktree add` is
#         BLOCKED: that is the improvisation this clause ends. The audited
#         escape hatch is a `hand-roll-ack: <reason>` prompt line, logged to
#         .claude/state/hand-roll-acks.log like main-checkout-run: is.
#   Clauses 1-3 are NOT relaxed by any of this: the name contract holds, and a
#   `cwd` spawn still needs a truthful <role>-<model>-<identifier> name. When
#   the ledger library is missing, a cwd/marker spawn is BLOCKED (fail-closed):
#   an unverifiable registration is not a registration.
#
# CLAUSE 5 — A GENERIC AGENT IS NOT A TEAMMATE (STAFFING, 2026-09-02).
#   READONLY_ALLOWLIST answers ONE question: does this agent need an isolated
#   worktree? It has never answered a second one: may delegated work be STAFFED
#   to this type at all? On 2026-09-02 those two were read as the same
#   permission — an engine-wide audit was dispatched to `Explore`, a generic
#   built-in, because a roster teammate would have needed a worktree created
#   first and the built-in could be dispatched immediately. Momentum over
#   correctness. Nothing refused it, correctly by the old contract. A comment
#   was added to orchestration.config saying the exemption is not a staffing
#   permission, and a comment is prose; prose does not hold.
#
#   So the staffing question now has its own gate, in front of the isolation
#   exemption and independent of it:
#     5a. The gate fires for a subagent_type that is on READONLY_ALLOWLIST or on
#         GENERIC_AGENT_TYPES (orchestration.config; default "general-purpose",
#         which closes the obvious detour — it is file-capable, so it passes the
#         whole contract today), MINUS anything on HARNESS_UTILITY_TYPES.
#     5b. HARNESS_UTILITY_TYPES (default: claude-code-guide statusline-setup
#         output-style-setup) is the declared exemption. Those types configure
#         or explain the harness itself; they never carry delegated project
#         work, so there is no roster teammate who should have had the job, and
#         demanding a justification for a statusline change is how a defense
#         becomes a nuisance and then a formality typed by reflex. The list is
#         CONFIG, not code, and the default is deny: a type newly added to
#         READONLY_ALLOWLIST needs the hatch until someone declares it a
#         utility.
#     5c. The escape hatch is one live prompt line, in the established shape:
#           generic-agent: <why no roster teammate fits this work>
#         A BARE MARKER EXEMPTS NOTHING. The reason must be >= 30 characters,
#         >= 5 words and carry >= 3 distinct substantive words, so "because" and
#         "n/a" are refused. It must also not be a SPEED or CONVENIENCE argument
#         ("faster", "saves time", "momentum", "convenient") — that was the
#         rationale in the incident, and it is the one reason this gate exists
#         to refuse. Every accepted use is logged to
#         .claude/state/generic-agent-dispatches.log, so a habit of waiving is
#         visible rather than invisible.
#     5d. The refusal NAMES THE ALTERNATIVE: pick the roster teammate whose
#         domain this is (the live roster is listed inline), and says why it
#         matters — a generic agent is invisible in the CEO's team display and
#         leaves no committed artifact, so work sent to one disappears from his
#         view and from the record.
#   CLAUSE 5 DOES NOT TOUCH THE ISOLATION EXEMPTION. An allowlisted type that
#   passes the staffing gate still exits with NO isolation and NO name required,
#   exactly as before. Both properties hold independently, and the suite proves
#   each without the other.
#
# ALLOWED (exit 0):
#   - any non-Agent tool (passthrough)
#   - spawns of READ-ONLY agent types (they never write repo files) — the
#     allowlist below — with no ISOLATION or NAME requirement, once the
#     clause-5 staffing gate is satisfied.
#   - a file-capable spawn that satisfies BOTH contract clauses.
# BLOCKED (exit 2): every other Agent spawn — with the exact clause(s) it
# failed AND the exact fix, inline.
#
# FAIL-CLOSED: default-deny. Anything not on the read-only allowlist is treated
# as a file-capable teammate and must satisfy the full contract; an unparseable
# Agent payload is blocked, not waved through.

set -eo pipefail

# Fail-closed, not fail-open: every payload check below depends on python3 to
# parse the tool_input JSON. If python3 is missing, EVERY `python3 ... ||
# true`-guarded call below silently returns empty, and an empty parse used to
# read as "not an Agent spawn" / "not file-capable" — i.e. this guard would
# wave every spawn through unchecked. That contradicts the "FAIL-CLOSED:
# default-deny" contract documented above, so refuse outright instead.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-worktree-isolation.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-worktree-isolation.sh"
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
    root_failure_banner "scripts/hooks/guard-worktree-isolation.sh" >&2
    exit 2
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
# Default to Claude Code's built-in read-only agent types if unset.
: "${READONLY_ALLOWLIST:=Explore Plan claude-code-guide statusline-setup}"
# Staffing gate (clause 5). HARNESS_UTILITY_TYPES is the DECLARED exemption from
# it; GENERIC_AGENT_TYPES extends it to generic built-ins that are not on the
# read-only allowlist at all. Deny-by-default: a type added to READONLY_ALLOWLIST
# needs the hatch until someone declares it a harness utility.
: "${HARNESS_UTILITY_TYPES:=claude-code-guide statusline-setup output-style-setup}"
: "${GENERIC_AGENT_TYPES:=general-purpose}"
# Default the session teams dir to the platform location when unset/blank.
: "${SESSION_TEAMS_DIR:=$HOME/.claude/teams}"
# Default the allowed <model> name-token set to Claude Code's aliases if unset.
: "${ALLOWED_MODELS:=fable opus sonnet haiku}"

# (payload already read above, before root resolution)

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

# A well-formed teammate name under the truthful-naming contract:
#   <role>-<model>-<identifier>   (THREE+ dash-joined parts)
# role: starts with a letter, alphanumeric, no dash. model/identifier:
# alphanumeric. Set-membership of the model token (clause 2a) and its
# truthfulness (clause 2b) are checked SEPARATELY so each failure gets a precise
# message; this regex only fixes the SHAPE (rejects bare "dev", 2-part "dev-1",
# run-together "devsonnet1").
NAME_SHAPE_RE='^[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9]+-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'

# model_in_allowed_set <token> — is the token one of ALLOWED_MODELS?
model_in_allowed_set() {
  local tok="$1" m
  for m in $ALLOWED_MODELS; do
    [ "$tok" = "$m" ] && return 0
  done
  return 1
}

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
  # it is reported as UNRESOLVABLE and the caller blocks.
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

# Parse subagent_type / isolation / name / prompt (with embedded newlines
# preserved via a \001 placeholder so the "main-checkout-run:" marker can be
# matched with a line-start anchor).
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {})
    if not isinstance(ti, dict):
        raise ValueError("tool_input not an object")
    st = str(ti.get("subagent_type", "") or "")
    iso = str(ti.get("isolation", "") or "")
    nm = str(ti.get("name", "") or "")
    md = str(ti.get("model", "") or "")
    sid = str(d.get("session_id", "") or "")
    cwd = str(ti.get("cwd", "") or "")
    pr = str(ti.get("prompt", "") or "")
    pr = pr.replace("\t", " ").replace("\n", "\x01")
    print("OK\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (st, iso, nm, sid, md, cwd, pr))
except Exception:
    print("PARSEFAIL\t\t\t\t\t\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f2)"
ISOLATION="$(printf '%s' "$PARSED" | cut -f3)"
NAME="$(printf '%s' "$PARSED" | cut -f4)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f5)"
MODEL_OVERRIDE="$(printf '%s' "$PARSED" | cut -f6)"
SPAWN_CWD="$(printf '%s' "$PARSED" | cut -f7)"
PROMPT="$(printf '%s' "$PARSED" | cut -f8- | tr '\001' '\n')"

# Fail-closed: an Agent spawn we cannot parse is blocked, never waved through.
if [ "$STATUS" = "PARSEFAIL" ]; then
  {
    echo "=== Teammate-spawn guard: BLOCKED ==="
    echo "  - Could not parse the Agent spawn payload to verify the spawn contract."
    echo "    Failing closed. Re-issue with isolation:\"worktree\" and a '<role>-<id>' name"
    echo "    (or, if this is a deliberate main-checkout run, add a"
    echo "    'main-checkout-run: <reason>' prompt line)."
    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# CLAUSE 5 — STAFFING GATE. Runs BEFORE the isolation exemption and is entirely
# separate from it: this asks "may work be staffed to this type at all?", the
# allowlist below asks "does this type need a worktree?". See the header.
# ---------------------------------------------------------------------------
_type_in_set() {   # <type> <space-separated set>
  local _t="$1" _set="$2" _x
  for _x in $_set; do [ "$_t" = "$_x" ] && return 0; done
  return 1
}

# _staffing_reason_problem <reason> — echo NOTHING when the reason is a
# well-formed justification; echo the refusal reason otherwise. Kept as a
# function (not an inline $(...) heredoc) because bash will not parse a
# quoted heredoc containing an apostrophe inside a command substitution.
_staffing_reason_problem() {
  GA_REASON="$1" python3 - <<'PY'
import os, re
r = (os.environ.get("GA_REASON", "") or "").strip()
MIN_CHARS = 30
MIN_WORDS = 5
MIN_CONTENT = 3
STOP = {
    "the","and","for","that","this","with","have","has","had","been","from",
    "just","only","need","needs","needed","want","wants","because","none",
    "null","reason","tbd","todo","fine","okay","yes","not","but","was","were",
    "are","its","here","there","thing","things","stuff","some","any","all",
    "does","doesnt","dont","cant","will","would","should","could","which",
    "them","they","their","when","what","also","into","over","than","then",
    "very","really","quite","sure","done","doing","make","made","use","used",
    "using","work","works","working","task","agent","one","two",
}
if not r:
    print("no 'generic-agent: <reason>' line is present in the prompt.")
else:
    low = r.lower()
    words = re.findall(r"[A-Za-z][A-Za-z'-]*", r)
    content = {w.lower() for w in words if len(w) >= 4 and w.lower() not in STOP}
    speed = re.search(
        r"(fastest|faster|quickest|quicker|save[sd]?\s+time|saving\s+time|"
        r"too\s+slow|no\s+time|momentum|convenien\w*|expedien\w*)", low)
    if len(r) < MIN_CHARS:
        print("the reason given is %d character(s) long; a real justification needs "
              "at least %d. A bare or token marker exempts nothing."
              % (len(r), MIN_CHARS))
    elif len(words) < MIN_WORDS:
        print("the reason given is %d word(s) long; a real justification needs at "
              "least %d. A bare or token marker exempts nothing."
              % (len(words), MIN_WORDS))
    elif len(content) < MIN_CONTENT:
        print("the reason given carries %d substantive word(s) (needs %d) — it "
              "reads as filler, not a justification." % (len(content), MIN_CONTENT))
    elif speed:
        print("the reason given is SPEED or CONVENIENCE (%r). That is the exact "
              "rationale this gate exists to refuse: on 2026-09-02 an engine-wide "
              "audit went to a generic built-in because a roster teammate would "
              "have needed a worktree created first. Creating one is a single call "
              "to scripts/create-teammate-worktree.sh, or one isolation:\"worktree\" "
              "parameter. Being quicker to dispatch is never a reason to staff work "
              "to a non-teammate." % speed.group(0))
    else:
        print("")
PY
}

NEEDS_STAFFING_HATCH=0
if ! _type_in_set "$SUBAGENT_TYPE" "$HARNESS_UTILITY_TYPES"; then
  if _type_in_set "$SUBAGENT_TYPE" "$READONLY_ALLOWLIST" \
     || _type_in_set "$SUBAGENT_TYPE" "$GENERIC_AGENT_TYPES"; then
    NEEDS_STAFFING_HATCH=1
  fi
fi

if [ "$NEEDS_STAFFING_HATCH" -eq 1 ]; then
  GENERIC_REASON=""
  if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*generic-agent:[[:space:]]*.+'; then
    GENERIC_REASON="$(printf '%s' "$PROMPT" \
      | grep -E '^[[:space:]]*generic-agent:[[:space:]]*.+' \
      | head -1 \
      | sed -E 's/^[[:space:]]*generic-agent:[[:space:]]*//')"
  fi

  # Empty output = the hatch is well-formed. Non-empty = the refusal reason.
  STAFFING_WHY="$(_staffing_reason_problem "$GENERIC_REASON" 2>/dev/null || printf 'the justification could not be evaluated (fail-closed).')"

  if [ -n "$STAFFING_WHY" ]; then
    ROSTER_HINT=""
    if [ -d "$ENTITY_ROOT/.claude/agents" ]; then
      ROSTER_HINT="$(ls "$ENTITY_ROOT/.claude/agents"/*.md 2>/dev/null \
        | while IFS= read -r _f; do _b="${_f##*/}"; printf '%s ' "${_b%.md}"; done)"
    fi
    {
      echo "=== Teammate-spawn guard: BLOCKED (clause 5 — staffing) ==="
      echo "  subagent_type '${SUBAGENT_TYPE}' is a GENERIC agent type, not a roster teammate,"
      echo "  and ${STAFFING_WHY}"
      echo ""
      echo "  WHY THIS IS REFUSED, not merely discouraged:"
      echo "    - a generic agent never appears in the CEO's team display, so work sent"
      echo "      to one disappears from his view of what is running;"
      echo "    - it has no worktree and leaves no commit, so the work leaves no artifact"
      echo "      in the record — only this session's transcript, which does not survive."
      echo ""
      echo "  FIX (preferred): re-issue with the ROSTER TEAMMATE whose domain this work is,"
      echo "  with isolation: \"worktree\" and a truthful '<role>-<model>-<identifier>' name."
      if [ -n "$ROSTER_HINT" ]; then
        echo "    roster: ${ROSTER_HINT}"
      fi
      echo "  Needing a worktree first is NOT a reason to reach for a generic agent —"
      echo "  scripts/create-teammate-worktree.sh creates and registers one in a single call."
      echo ""
      echo "  FIX (only when no roster teammate genuinely fits): add ONE live prompt line"
      echo "      generic-agent: <why no roster teammate fits this work>"
      echo "  It must be a real reason — at least 30 characters, at least 5 words, at least"
      echo "  3 substantive words — and it must not be a speed or convenience argument."
      echo "  Every accepted use is logged to .claude/state/generic-agent-dispatches.log,"
      echo "  so a habit of waiving is visible rather than invisible."
      echo ""
      echo "  (READONLY_ALLOWLIST exempts this type from WORKTREE ISOLATION — a safety"
      echo "   question. It has never been a permission to STAFF work here. A harness"
      echo "   utility that carries no delegated work belongs in HARNESS_UTILITY_TYPES"
      echo "   in orchestration.config, not in a waiver typed on every dispatch.)"
      echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
    } >&2
    exit 2
  fi

  # Hatch accepted. Best-effort log — never fail the spawn because logging
  # failed; the marker in the prompt is itself the audit trail.
  GA_LOG_DIR="$ENTITY_ROOT/.claude/state"
  mkdir -p "$GA_LOG_DIR" 2>/dev/null || true
  printf '%s\tagent=%s\tname=%s\tgeneric-agent: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${SUBAGENT_TYPE:-<unset>}" \
    "${NAME:-<unset>}" \
    "$GENERIC_REASON" \
    >>"$GA_LOG_DIR/generic-agent-dispatches.log" 2>/dev/null || true
fi

# Read-only agent types are exempt from the teammate contract (frictionless).
for a in $READONLY_ALLOWLIST; do
  if [ "$SUBAGENT_TYPE" = "$a" ]; then
    exit 0
  fi
done

# File-capable teammate: enforce the FULL correct-spawn contract.
PROBLEMS=()

# main-checkout-run: <reason> — a live prompt line (kept simple/best-effort by
# design; this is an auditable FALLBACK opt-out, not a security boundary — the
# boundary is guard-main-checkout-writes.sh blocking actual writes).
MAIN_CHECKOUT_MARKER=""
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*main-checkout-run:[[:space:]]*.+'; then
  MAIN_CHECKOUT_MARKER="$(printf '%s' "$PROMPT" | grep -oE '^[[:space:]]*main-checkout-run:[[:space:]]*.+' | head -1 | sed -E 's/^[[:space:]]*//')"
fi

# --- CLAUSE 4 helpers ------------------------------------------------------
# registered_teammate_worktree <path> -> 0 when <path> is the top level of a
# LINKED git worktree AND the ownership ledger holds a registration for it;
# prints the reason for a refusal on stdout otherwise.
LEDGER_PY="$SCRIPT_DIR/../lib/worktree-ledger.py"
registered_teammate_worktree() {
  local p="$1" top common gitdir
  [ -n "$p" ] || { printf 'no path given'; return 1; }
  [ -d "$p" ] || { printf "'%s' does not exist" "$p"; return 1; }
  top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || { printf "'%s' is not inside a git worktree" "$p"; return 1; }
  if [ "$(cd "$top" && pwd -P)" != "$(cd "$p" && pwd -P)" ]; then
    printf "'%s' is not the top level of a worktree (that is '%s')" "$p" "$top"; return 1
  fi
  common="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  gitdir="$(git -C "$p" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  if [ -z "$common" ] || [ "$common" = "$gitdir" ]; then
    printf "'%s' is a MAIN checkout, not a linked worktree — a teammate never works in the main checkout" "$p"; return 1
  fi
  if [ ! -f "$LEDGER_PY" ]; then
    printf "the ownership ledger library is missing at %s, so the registration of '%s' cannot be verified (fail-closed)" "$LEDGER_PY" "$p"; return 1
  fi
  if ! python3 "$LEDGER_PY" registrations --worktree "$p" >/dev/null 2>&1; then
    printf "'%s' is a linked worktree but the ownership ledger holds NO registration for it — it was not created by scripts/create-teammate-worktree.sh" "$p"; return 1
  fi
  return 0
}
HELPER_HINT="create it with  <engine>/scripts/create-teammate-worktree.sh <repo> <teammate-name>  which creates, seeds .worktreeinclude, and REGISTERS the tree; then spawn with cwd:\"<path>\" (no isolation) or add the prompt line  cross-repo-worktree: <path>  (with isolation:\"worktree\")."

case "$ISOLATION" in
  worktree|remote)
    if [ -n "$SPAWN_CWD" ]; then
      PROBLEMS+=("cwd and isolation are mutually exclusive — the Agent tool refuses the pair (got cwd='${SPAWN_CWD}' with isolation='${ISOLATION}'). For cross-repository work either drop isolation and spawn with cwd inside a registered worktree, or keep isolation and name the registered worktree on a 'cross-repo-worktree: <path>' prompt line.")
    fi
    ;;
  *)
    if [ -n "$SPAWN_CWD" ]; then
      # CLAUSE 4a — a cwd spawn stands in for native isolation ONLY inside a
      # registered cross-repository worktree.
      CWD_WHY="$(registered_teammate_worktree "$SPAWN_CWD")" || \
        PROBLEMS+=("cwd spawn refused — ${CWD_WHY}. A cross-repository teammate works only in a worktree RichOS registered, so its owner can be judged after this session is gone: ${HELPER_HINT}")
    elif [ -n "$MAIN_CHECKOUT_MARKER" ]; then
      # Auditable fallback opt-out taken. Best-effort log — never fail the
      # spawn because logging failed; the marker itself is the audit trail.
      LOG_DIR="$ENTITY_ROOT/.claude/state"
      mkdir -p "$LOG_DIR" 2>/dev/null || true
      {
        printf '%s\tagent=%s\tname=%s\t%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "${SUBAGENT_TYPE:-<unset>}" \
          "${NAME:-<unset>}" \
          "$MAIN_CHECKOUT_MARKER"
      } >>"$LOG_DIR/main-checkout-runs.log" 2>/dev/null || true
    else
      PROBLEMS+=("missing native isolation — add  isolation: \"worktree\"  to run in an isolated worktree (got isolation='${ISOLATION:-unset}'); OR, for cross-repository work, spawn with cwd inside a worktree registered by scripts/create-teammate-worktree.sh; OR, if this is a deliberate main-checkout run, add a live prompt line starting with 'main-checkout-run: <reason>'.")
    fi
    ;;
esac

# CLAUSE 4c — every cross-repo-worktree: line names a REGISTERED worktree.
while IFS= read -r _marker_path; do
  [ -n "$_marker_path" ] || continue
  MK_WHY="$(registered_teammate_worktree "$_marker_path")" || \
    PROBLEMS+=("cross-repo-worktree: line refused — ${MK_WHY}. ${HELPER_HINT}")
done <<MARKERS_EOF
$(printf '%s' "$PROMPT" | sed -n -E 's/^[[:space:]]*cross-repo-worktree:[[:space:]]*([^[:space:]]+).*$/\1/p')
MARKERS_EOF

# CLAUSE 4d — a prompt that tells the teammate to hand-roll a worktree is the
# improvisation this clause ends. Audited escape hatch: hand-roll-ack: <reason>.
if printf '%s' "$PROMPT" | grep -qE 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+worktree[[:space:]]+add'; then
  HAND_ROLL_ACK=""
  if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*hand-roll-ack:[[:space:]]*.+'; then
    HAND_ROLL_ACK="$(printf '%s' "$PROMPT" | grep -oE '^[[:space:]]*hand-roll-ack:[[:space:]]*.+' | head -1 | sed -E 's/^[[:space:]]*//')"
  fi
  if [ -n "$HAND_ROLL_ACK" ]; then
    LOG_DIR="$ENTITY_ROOT/.claude/state"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '%s\tagent=%s\tname=%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUBAGENT_TYPE:-<unset>}" "${NAME:-<unset>}" "$HAND_ROLL_ACK" >>"$LOG_DIR/hand-roll-acks.log" 2>/dev/null || true
  else
    PROBLEMS+=("the prompt instructs the teammate to run 'git worktree add' — an improvised worktree carries no ownership record and becomes undecidable to the reaper the moment this session's evidence is gone. ${HELPER_HINT} If this instruction is genuinely intended (a task ABOUT worktree tooling), add a live prompt line 'hand-roll-ack: <reason>' — logged to .claude/state/hand-roll-acks.log.")
  fi
fi

if ! printf '%s' "$NAME" | grep -qE "$NAME_SHAPE_RE"; then
  PROBLEMS+=("missing/malformed name — give a unique '<role>-<model>-<identifier>' name, e.g. dev-sonnet-1 / qa-opus-r3 (got name='${NAME:-unset}'). Needs THREE dash-joined parts (role, model, identifier). Never bare ('dev'), 2-part ('dev-1'), or run-together ('devsonnet1'). NOT relaxed by main-checkout-run:.")
else
  # Shape valid: split into role / <model> token / identifier.
  NAME_ROLE="${NAME%%-*}"
  NAME_REST="${NAME#*-}"
  NAME_MODEL_TOKEN="${NAME_REST%%-*}"
  NAME_ID="${NAME_REST#*-}"

  # Clause 2a — the <model> token must be a real alias.
  if ! model_in_allowed_set "$NAME_MODEL_TOKEN"; then
    PROBLEMS+=("model token '${NAME_MODEL_TOKEN}' in name '${NAME}' is not an allowed model — the <model> part of <role>-<model>-<identifier> must be one of: ${ALLOWED_MODELS// /, } (e.g. ${NAME_ROLE}-sonnet-${NAME_ID}). Extend ALLOWED_MODELS in orchestration.config if your harness accepts more.")
  else
    # Clause 2b — TRUTHFULNESS. Resolve the model this spawn boots on and
    # require the name token to match it.
    EXPECTED_MODEL="$(resolve_expected_model "$MODEL_OVERRIDE" "$SUBAGENT_TYPE")"
    if [ "$EXPECTED_MODEL" = "UNRESOLVABLE" ]; then
      # FAIL LOUD. A namespaced subagent_type is by construction supplied by a
      # plugin, so its definition MUST be locatable; if it is not, clause 2b
      # cannot be evaluated at all. The old code degraded to "accept" here
      # without a word.
      PROBLEMS+=("cannot verify the model token — subagent_type '${SUBAGENT_TYPE}' is namespaced, but no definition for it was found under the entity roster (${ENTITY_ROOT}/.claude/agents/), the engine's own roster (${ENGINE_ROOT}/.claude/agents/), or AGENT_NAMESPACE_ROOTS. The model-truthfulness clause cannot be evaluated, so this spawn is refused rather than waved through. Fix: add '<namespace>=<plugin root>' to AGENT_NAMESPACE_ROOTS in orchestration.config, or dispatch the un-namespaced type.")
    elif [ -n "$EXPECTED_MODEL" ] && [ "$NAME_MODEL_TOKEN" != "$EXPECTED_MODEL" ]; then
      if [ -n "$MODEL_OVERRIDE" ]; then
        MODEL_SRC="explicit model override '${MODEL_OVERRIDE}'"
      else
        MODEL_SRC="the '${SUBAGENT_TYPE}' agent definition's model: frontmatter"
      fi
      PROBLEMS+=("untruthful model token — the name claims '${NAME_MODEL_TOKEN}' but this spawn boots on '${EXPECTED_MODEL}' (from ${MODEL_SRC}). The <model> token MUST match the model the instance actually runs on. Fix: rename to '${NAME_ROLE}-${EXPECTED_MODEL}-${NAME_ID}', or change the model so it matches.")
    fi
    # else: expected model is undeterminable (no override AND no live-def
    # default, or model:"inherit" — the inherit-from-session case). We cannot
    # know the boot model, so we accept the (already-valid) alias token rather
    # than fail the spawn on unknowable information.
  fi
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  {
    echo "=== Teammate-spawn guard: BLOCKED ==="
    echo "  Agent '${SUBAGENT_TYPE:-<unset/general-purpose>}' can edit repo files, so it must satisfy the"
    echo "  teammate-spawn contract. It failed:"
    for p in "${PROBLEMS[@]}"; do
      echo "    - $p"
    done
    echo "  Re-issue the Agent call fixing the above."
    echo "  (If this agent is genuinely READ-ONLY, add its type to READONLY_ALLOWLIST"
    echo "   in orchestration.config.)"
    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# CLAUSE 3 — name reuse is structurally impossible.
# ---------------------------------------------------------------------------
# Only reached once isolation + name-format already pass (so we never record a
# name for a spawn that is being blocked for a different reason). Inert unless a
# session team dir resolves by EXACT match (so bare unit-test payloads with a
# nonexistent session are unaffected — existing suites stay green). The teams
# dir is read from orchestration.config (SESSION_TEAMS_DIR); tests override via
# GUARD_ISOLATION_TEAMS_DIR.
GI_TEAMS_DIR="${GUARD_ISOLATION_TEAMS_DIR:-$SESSION_TEAMS_DIR}"
GI_TEAM_DIR=""
if [ -n "$SESSION_ID" ]; then
  CANDIDATE="$GI_TEAMS_DIR/session-$(printf '%s' "$SESSION_ID" | cut -c1-8)"
  [ -d "$CANDIDATE" ] && GI_TEAM_DIR="$CANDIDATE"
fi

if [ -n "$GI_TEAM_DIR" ]; then
  # Union the three durable name-history sources and test NAME against it. Fail
  # OPEN on a resolver error (never invent a collision from an IO glitch); the
  # primary source (spawned-names.log) is written by this same hook so, absent
  # IO failure, it cannot miss a name spawned this session.
  REUSE_VERDICT="$(NAME_ARG="$NAME" python3 - "$GI_TEAM_DIR" 2>/dev/null <<'PY'
import json, os, sys

name = os.environ.get("NAME_ARG", "")
team_dir = sys.argv[1]
history = set()

# 1. self-maintained ledger (one name per line)
ledger = os.path.join(team_dir, "spawned-names.log")
try:
    with open(ledger, "r", encoding="utf-8") as f:
        for line in f:
            v = line.strip()
            if v:
                history.add(v)
except Exception:
    pass

# 2. roster config.json member names (any status)
try:
    with open(os.path.join(team_dir, "config.json"), "r", encoding="utf-8") as f:
        cfg = json.load(f)
    for m in cfg.get("members", []) or []:
        nm = m.get("name")
        if isinstance(nm, str) and nm:
            history.add(nm)
except Exception:
    pass

# 3. durable event logs — completed teammates that may be roster-pruned
for logname in ("idle-events.jsonl", "task-events.jsonl"):
    try:
        with open(os.path.join(team_dir, logname), "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get("teammate")
                if isinstance(t, str) and t:
                    history.add(t)
    except Exception:
        pass

# The lead is not a spawnable teammate name; never treat it as a collision.
history.discard("team-lead")

print("REUSE" if name in history else "FRESH")
PY
)"
  # Fail-OPEN on a resolver error / empty output (never invent a collision).
  [ -n "$REUSE_VERDICT" ] || REUSE_VERDICT="FRESH"

  if [ "$REUSE_VERDICT" = "REUSE" ]; then
    {
      echo "=== Teammate-spawn guard: BLOCKED (name reuse) ==="
      echo "  The name '${NAME}' has ALREADY been used in this session's team"
      echo "  (active OR completed). Reusing a name causes latest-wins shadowing and"
      echo "  resumed-vs-respawned ambiguity, so it is forbidden — there is NO escape"
      echo "  hatch for this one."
      echo "  Fix: pick a FRESH '<role>-<identifier>' name. Identifiers are free —"
      echo "  bump the suffix (${NAME}-2 / ${NAME%%-*}-b / ${NAME%%-*}-0714) or use any"
      echo "  unused identifier. Never resume-vs-respawn by reusing a name."
      echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
    } >&2
    exit 2
  fi

  # NOTE: this guard deliberately does NOT append NAME to spawned-names.log.
  # See "BLOCKED-SPAWN NAME BURN" in this file's header. The append lives in
  # the PostToolUse[Agent] partner hook (detect-nonnative-worktree.sh), which
  # only ever fires for a tool call that actually executed. The CHECK above is
  # unchanged and still runs first, at spawn time.
fi

exit 0
