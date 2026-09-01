#!/usr/bin/env bash
#
# verify-agent-prompt.sh — PreToolUse gate on Agent spawns.
#
# Five always-on checks plus one OPT-IN check (the QA install-fresh gate,
# toggled by ENABLE_QA_INSTALL_FRESH_GATE in orchestration.config — OFF by
# default):
#
#   1. duplicate-teammate        — reject spawning a name that already exists
#                                  (not shutdown) in the session team. The
#                                  session team is derived from the hook
#                                  input's session_id when team_name is absent.
#   2. agent-not-found           — every in-repo `.claude/agents/<name>.md`
#                                  referenced in the prompt must exist. Skipped
#                                  for the creator meta-role (CREATOR_TEAMMATE,
#                                  whose job is to create the file);
#                                  out-of-repo absolute references are never
#                                  evaluated.
#   3. subagent-as-spawner       — reject prompts that ask a subagent to spawn
#                                  or dispatch agents; only the orchestrator
#                                  spawns.
#   4. missing-worktree-isolation— prompt claims native isolation created the
#                                  worktree but the call didn't set
#                                  isolation:"worktree".
#   5. qa-install-fresh (OPT-IN) — prompts that test/audit/render/capture the
#                                  local app must cite an install-fresh script
#                                  as a precondition, or carry an auditable
#                                  `data-contract-bypass:` line. Part of the
#                                  advanced "identity-or-refuse" tier; enable
#                                  only if you adopt a device/install-fresh
#                                  pipeline (see reference/advanced-tier/).
#   6. ack-contract-missing      — a spawn that gets a worktree must carry the
#                                  in-flight ack contract in its PROMPT (the
#                                  helper name OR the ack path), or an auditable
#                                  `no-inflight-ack:` line. The instruction
#                                  cannot travel in the message it exists to
#                                  make verifiable.

set -eo pipefail

# Fail-closed, not fail-open: every check below (duplicate-teammate,
# agent-not-found, subagent-as-spawner, missing-worktree-isolation, the
# opt-in qa-install-fresh gate) reads PROMPT/SUBAGENT_TYPE/ISOLATION/etc via
# `python3 ... || true`. If python3 is missing, those swallowed failures yield
# empty values, and `[ -n "$PROMPT" ]`-guarded checks below would then just
# skip — i.e. every content check in this gate would silently no-op. Refuse
# outright instead.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: verify-agent-prompt.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/verify-agent-prompt.sh"
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

# Test affordance, preserved: VERIFY_REPO_ROOT_OVERRIDE now feeds the
# contract's own declared-root candidate rather than assigning a root behind
# the resolver's back, so a sandbox root is validated like any other.
[ -n "${VERIFY_REPO_ROOT_OVERRIDE:-}" ] && RICHOS_ENTITY_ROOT="$VERIFY_REPO_ROOT_OVERRIDE"

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
    root_failure_banner "scripts/hooks/verify-agent-prompt.sh" >&2
    exit 2
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${CREATOR_TEAMMATE:=dean}"
: "${ENABLE_QA_INSTALL_FRESH_GATE:=0}"
: "${INSTALL_FRESH_SCRIPTS:=android-install-fresh.sh ios-install-fresh.sh}"
: "${QA_TRIGGER_RE:=(\btest\b|\baudit\b|\bverify\b|\bQA\b|\brender\b|\bscreenshot\b|install-fresh)}"
: "${LOCAL_APP_CONTEXT_RE:=(install-fresh|emulator|simulator|the app|local app|BUILD_SHA)}"
# Test/per-invocation override for the opt-in gate toggle.
[ -n "${VERIFY_QA_GATE_OVERRIDE:-}" ] && ENABLE_QA_INSTALL_FRESH_GATE="$VERIFY_QA_GATE_OVERRIDE"

# (payload already read above, before root resolution)

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

PROMPT="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("prompt",""))' 2>/dev/null || true)"
SUBAGENT_TYPE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("subagent_type",""))' 2>/dev/null || true)"
ISOLATION="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("isolation",""))' 2>/dev/null || true)"
AGENT_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("name",""))' 2>/dev/null || true)"
TEAM_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("team_name",""))' 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_id",""))' 2>/dev/null || true)"

FAIL=0
FAIL_REASONS=()

# ---------------------------------------------------------------------------
# 1. duplicate-teammate
# ---------------------------------------------------------------------------
# team_name is accepted-but-ignored by the harness (one implicit session
# team), so derive the team dir from session_id when it's absent:
# ~/.claude/teams/session-<first8-of-session-id>/config.json.
if [ -z "$TEAM_NAME" ] && [ -n "$SESSION_ID" ]; then
  TEAM_NAME="session-$(printf '%s' "$SESSION_ID" | cut -c1-8)"
fi

if [ -n "$TEAM_NAME" ] && [ -n "$AGENT_NAME" ]; then
  TEAM_CONFIG="$HOME/.claude/teams/$TEAM_NAME/config.json"
  # Override lets the test harness point at a sandbox teams/ directory.
  if [ -n "${V8_TEAMS_DIR_OVERRIDE:-}" ]; then
    TEAM_CONFIG="$V8_TEAMS_DIR_OVERRIDE/$TEAM_NAME/config.json"
  fi

  if [ -f "$TEAM_CONFIG" ]; then
    V8_RESULT="$(AGENT_NAME_ARG="$AGENT_NAME" python3 - "$TEAM_CONFIG" <<'PY'
import json
import os
import sys

name = os.environ.get("AGENT_NAME_ARG", "")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("NONE")
    raise SystemExit

for member in data.get("members", []) or []:
    if member.get("name") == name:
        status = (member.get("status") or "").lower()
        if status == "shutdown":
            print("SHUTDOWN")
        else:
            print("MATCH|%s|%s" % (member.get("agentId", ""), status or "present"))
        raise SystemExit
print("NONE")
PY
)"
    case "$V8_RESULT" in
      MATCH\|*)
        REST="${V8_RESULT#MATCH|}"
        DUP_AGENT_ID="${REST%%|*}"
        DUP_STATUS="${REST#*|}"
        FAIL=1
        FAIL_REASONS+=("duplicate-teammate: ${AGENT_NAME} already exists in ${TEAM_NAME} (agent_id: ${DUP_AGENT_ID}, status: ${DUP_STATUS}). Resume it with SendMessage, or explicitly shut it down and wait for the shutdown confirmation before spawning a replacement — under a NEW name, never a reused one.")
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 2–4. prompt-content checks
# ---------------------------------------------------------------------------
if [ -n "$PROMPT" ]; then
  # 2. agent-not-found
  #
  # Skip entirely for the creator meta-role: its job IS to create the
  # definition file a hiring brief references, so "read
  # .claude/agents/<new-role>.md" in its prompt is a to-be-created target, not
  # a broken reference.
  #
  # For everyone else, only evaluate references that resolve INSIDE this repo.
  # An absolute path like /some/other/repo/.claude/agents/foo.md is a
  # sibling-repo reference model — the trailing ".claude/agents/foo.md"
  # substring looks like an in-repo reference but isn't one, so we must not
  # stat it against $ENTITY_ROOT.
  # Compare on the BARE role: a namespaced `richos-engine:dean` is still dean,
  # and matching the raw string would have silently re-enabled the
  # agent-not-found check for the one role whose entire job is to create the
  # file the check would flag.
  if [ "$(strip_agent_namespace "$SUBAGENT_TYPE")" != "$CREATOR_TEAMMATE" ]; then
    CANDIDATE_REFS=()
    while IFS= read -r line; do
      [ -n "$line" ] && CANDIDATE_REFS+=("$line")
    done < <(
      printf '%s' "$PROMPT" \
        | grep -oE '[^[:space:]]*\.claude/agents/[a-z-]+\.md' \
        | sort -u || true
    )

    for full_ref in "${CANDIDATE_REFS[@]}"; do
      if [[ "$full_ref" == /* ]] && [[ "$full_ref" != "$ENTITY_ROOT"/* ]]; then
        continue  # absolute path outside this repo — not our reference to check
      fi
      agent="${full_ref##*.claude/agents/}"
      agent="${agent%.md}"
      # Search the entity roster first, then the engine's own — a prompt may
      # legitimately cite a plugin-supplied meta-role's definition, which does
      # not live in the entity's repository at all. Resolving only against the
      # entity root would have turned every such citation into a false
      # "agent-not-found" block the moment the engine became a plugin.
      if ! resolve_agent_def "$ENTITY_ROOT" "$ENGINE_ROOT" "$agent" >/dev/null 2>&1; then
        FAIL=1
        FAIL_REASONS+=("agent-not-found: .claude/agents/${agent}.md")
      fi
    done
  fi

  # 3. subagent-as-spawner
  #
  # Split into a case-insensitive keyword pass and a case-SENSITIVE TitleCase
  # pass, deliberately:
  #   - The "Agent tool" phrase is boundary-guarded: `(^|[^A-Za-z-])Agent`
  #     requires a word-start immediately before it, so a hyphen-prefixed
  #     compound like "non-Agent tool" no longer matches, while a genuine
  #     standalone reference ("Use the Agent tool...") still does.
  #   - The launch-verb alternative runs as a SEPARATE, case-sensitive grep so
  #     `[A-Z]` means what it says — only a genuinely capitalized token
  #     following the verb (a real teammate name) fires it.
  if [ -n "$SUBAGENT_TYPE" ]; then
    SPAWNER_CI_RE='(^|[^A-Za-z-])Agent[[:space:]]+tool|(spawn|dispatch)[[:space:]]+(agents?|teammates?|subagents?)\b|dispatch[[:space:]]+(these|the[[:space:]]+following)\b|TeamCreate'
    SPAWNER_CS_RE='\b(spawn|dispatch)[[:space:]]+[A-Z][a-z]+\b'
    if printf '%s' "$PROMPT" | grep -qiE "$SPAWNER_CI_RE" \
       || printf '%s' "$PROMPT" | grep -qE "$SPAWNER_CS_RE"; then
      FAIL=1
      FAIL_REASONS+=("subagent-as-spawner: prompt appears to ask subagent '${SUBAGENT_TYPE}' to spawn or dispatch agents. Only the orchestrator makes Agent tool calls — keep briefs to plain build instructions and don't narrate the orchestration around them.")
    fi
  fi

  # 4. missing-worktree-isolation: the prompt tells the teammate that native
  # isolation ALREADY created its worktree, but the Agent call didn't set
  # isolation:"worktree". That contradiction means the flag was forgotten and
  # the teammate will actually land in the MAIN checkout. Fail fast at the
  # spawn.
  if [ "$ISOLATION" != "worktree" ]; then
    if printf '%s' "$PROMPT" | grep -qiE 'native isolation (has )?already|(isolation|worktree) (has )?already (given|created|placed|put)|already (given|placed|dropped) you (a|an|one|in)( native)?[[:space:]]*(claude code )?worktree'; then
      FAIL=1
      FAIL_REASONS+=("missing-worktree-isolation: the prompt tells the subagent that native isolation already created its worktree, but this Agent call set isolation='${ISOLATION:-unset}' (not \"worktree\"). Add isolation:\"worktree\" to the spawn. If you are deliberately hand-rolling a worktree, remove the 'native isolation already' wording and give the explicit worktree path instead.")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# sanitized_prompt — the prompt with fenced code, HTML comments, blockquotes
# and indented code blocks stripped out.
#
# HOISTED out of check 5 on 2026-08-30, byte-identical, because check 6 needs
# exactly the same treatment for exactly the same reason: an opt-out marker a
# prompt merely QUOTES — from a file, an example, another agent's report — must
# never activate the opt-out. Two copies of this stripper would be the drift
# this engine keeps finding in itself. There is one, it is computed at most
# once per spawn, and both checks read the same answer.
PROMPT_SANITIZED=""
PROMPT_SANITIZED_DONE=0
sanitized_prompt() {
  if [ "$PROMPT_SANITIZED_DONE" -eq 1 ]; then
    printf '%s' "$PROMPT_SANITIZED"
    return 0
  fi
  PROMPT_SANITIZED_DONE=1
    BYPASS_STRIPPER_PY="$(mktemp -t verify-agent-prompt-strip.XXXXXX.py)"
    cat >"$BYPASS_STRIPPER_PY" <<'STRIP_PY'
import re, sys, unicodedata
text = sys.stdin.read()
# Strip HTML comments (multi-line, greedy across lines — not per-line).
text = re.sub(r'<!--[\s\S]*?-->', '', text)

_WS_CATEGORIES = ('Zs', 'Cf', 'Zl', 'Zp')
def _normalize_leading_ws(line):
    """Replace each leading Unicode-whitespace char with an ASCII space,
    leaving the rest of the line untouched. Stops at the first
    non-whitespace character."""
    i = 0
    n = len(line)
    out = []
    while i < n:
        ch = line[i]
        if ch == ' ' or ch == '\t':
            out.append(ch)
            i += 1
            continue
        cat = unicodedata.category(ch)
        if cat in _WS_CATEGORIES:
            out.append(' ')
            i += 1
            continue
        break
    out.append(line[i:])
    return ''.join(out)

fence_re = re.compile(r'^[ \t]{0,3}(`{3,}|~{3,})([^\n]*)$')
out_lines = []
in_fence = False
fence_marker = None   # '`' or '~'
fence_len = 0         # marker-char run length at opening
for raw_line in text.split('\n'):
    line = _normalize_leading_ws(raw_line)
    m = fence_re.match(line)
    if m:
        marker_run = m.group(1)
        marker_char = marker_run[0]
        info = (m.group(2) or '').strip()
        if not in_fence:
            in_fence = True
            fence_marker = marker_char
            fence_len = len(marker_run)
            continue
        # In fence: only close on same marker char, length >= opener,
        # AND no info string (markdown spec for code fences).
        if (marker_char == fence_marker and
            len(marker_run) >= fence_len and
            info == ''):
            in_fence = False
            fence_marker = None
            fence_len = 0
        # Either way, drop the marker line.
        continue
    if in_fence:
        continue
    stripped = line.lstrip()
    if stripped.startswith('>'):
        continue
    if line.startswith('    ') or line.startswith('\t'):
        continue
    out_lines.append(raw_line)
# If the prompt ended mid-fence, everything after the last open fence was
# dropped — safe direction (bypass lines inside unterminated fences remain
# stripped, not leaked).
print('\n'.join(out_lines))
STRIP_PY
    PROMPT_FOR_BYPASS="$(printf '%s' "$PROMPT" | python3 "$BYPASS_STRIPPER_PY" 2>/dev/null || printf '%s' "$PROMPT")"
    rm -f "$BYPASS_STRIPPER_PY"
  PROMPT_SANITIZED="$PROMPT_FOR_BYPASS"
  printf '%s' "$PROMPT_SANITIZED"
}

# ---------------------------------------------------------------------------
# 5. qa-install-fresh precondition (OPT-IN — advanced identity-or-refuse tier)
# ---------------------------------------------------------------------------
# Any spawn that tests / audits / renders / captures the LOCAL APP must either
# (a) cite an install-fresh script as a precondition or (b) opt out with an
# auditable `data-contract-bypass:` line. Runs ONLY when the gate is enabled.
if [ "$ENABLE_QA_INSTALL_FRESH_GATE" = "1" ] && [ -n "$SUBAGENT_TYPE" ] && [ -n "$PROMPT" ]; then
  if printf '%s' "$PROMPT" | grep -qiE "$QA_TRIGGER_RE" \
     && printf '%s' "$PROMPT" | grep -qE "$LOCAL_APP_CONTEXT_RE"; then

    # Bypass detection runs against a SANITIZED copy of the prompt: fenced
    # code, HTML comments, blockquotes, and indented code blocks are stripped
    # first, so a forged bypass inside any of those never activates the opt-out.
    BYPASS_LINE=""
    PROMPT_FOR_BYPASS="$(sanitized_prompt)"
    if printf '%s' "$PROMPT_FOR_BYPASS" | grep -qE '^[[:space:]]*data-contract-bypass:[[:space:]]*.+'; then
      BYPASS_LINE="$(printf '%s' "$PROMPT_FOR_BYPASS" | grep -oE '^[[:space:]]*data-contract-bypass:[[:space:]]*.+' | head -1 | sed -E 's/^[[:space:]]*//')"
    fi

    if [ -n "$BYPASS_LINE" ]; then
      # Audit log under .claude/state/. Best-effort — never fail the spawn
      # because logging failed; the bypass itself is the audit.
      BYPASS_LOG_DIR="$ENTITY_ROOT/.claude/state"
      mkdir -p "$BYPASS_LOG_DIR" 2>/dev/null || true
      {
        printf '%s\tagent=%s\t%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "$SUBAGENT_TYPE" \
          "$BYPASS_LINE"
      } >>"$BYPASS_LOG_DIR/data-contract-bypasses.log" 2>/dev/null || true
      # Allow the spawn.
    else
      CITES_INSTALL_FRESH=0
      for s in $INSTALL_FRESH_SCRIPTS; do
        if printf '%s' "$PROMPT" | grep -qF "$s"; then
          CITES_INSTALL_FRESH=1
          break
        fi
      done
      if [ "$CITES_INSTALL_FRESH" -eq 0 ]; then
        FAIL=1
        FAIL_REASONS+=("qa-install-fresh-precondition-missing: prompt assigns a task to agent \`${SUBAGENT_TYPE}\` that tests / audits / renders / captures the local app but does NOT cite an install-fresh script (${INSTALL_FRESH_SCRIPTS}) as a precondition. Every testing operation against the local app MUST start from a fresh install that passes the data-render contract — otherwise the result is meaningless. Either add 'Precondition: <install-fresh script> <sha> exits 0.' to the prompt, or — if the task is genuinely app-free — add a live-prose line starting with 'data-contract-bypass:' and the reason (logged to .claude/state/data-contract-bypasses.log).")
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. ack-contract-missing — a file-writing spawn must be TOLD how to acknowledge
# ---------------------------------------------------------------------------
# You cannot bootstrap reliability from an unreliable channel. If the
# instruction "here is how you acknowledge" travels in the follow-up message,
# it is lost with the message it rode in on — and the lead is then left waiting
# for an ack the teammate was never told to write. That is not hypothetical: on
# 2026-08-30 the lead sent two receipt checks to a teammate and sat waiting for
# replies that never came, having never told it how to reply durably.
#
# So the ack contract belongs in the SPAWN PROMPT, which is one of the four
# substrates the doctrine calls durable, and this is the chokepoint where every
# spawn prompt passes exactly once.
#
# WHO IT APPLIES TO: spawns that get a worktree — native isolation, or a
# hand-rolled worktree named in the prompt. Those are the teammates who can be
# left behind by a land, because they are the ones holding a snapshot. A
# read-only or synchronous subagent holds nothing and is owed nothing.
#
# HOW TO SATISFY IT: name either the helper (`inflight-ack.sh`) or the ack path
# (`inflight-acks/`) in the prompt. One line:
#
#   If I message you saying main moved, acknowledge it durably — I cannot rely
#   on a reply reaching me. Run: scripts/inflight-ack.sh --sha <sha> --impact
#   <conflict|stale-record|grew-scope|none> --detail "<your own words>"
#   --paths "<paths or none>"
#
# BOTH FORMS ARE ACCEPTED because the FORMAT is the contract, not the script.
# The engine is loaded by reference, so `scripts/inflight-ack.sh` is not a path
# that exists inside the governed repository — a teammate reaches the helper at
# ~/.claude/richos-engine/scripts/inflight-ack.sh, and only if the operator has
# installed it. A prompt that spells out the ack FILE instead
# (<worktree>/.claude/inflight-acks/<sha12>.<teammate>.ack and its keys) has satisfied
# the requirement completely, and a check that insisted on the script name would
# be refusing the more robust of the two.
#
# HOW TO OPT OUT: a live prompt line starting  no-inflight-ack: <reason>
# Auditable, visible in the prompt itself, and never silent — the same shape as
# main-checkout-run: and data-contract-bypass:.
if [ -n "$SUBAGENT_TYPE" ] && [ -n "$PROMPT" ]; then
  ACK_APPLIES=0
  [ "$ISOLATION" = "worktree" ] && ACK_APPLIES=1
  if [ "$ACK_APPLIES" -eq 0 ] && printf '%s' "$PROMPT" | grep -qiE 'worktree'; then
    ACK_APPLIES=1
  fi
  if [ "$ACK_APPLIES" -eq 1 ]; then
    if ! printf '%s' "$PROMPT" | grep -qE 'inflight-ack\.sh|inflight-acks/' \
       && ! printf '%s' "$(sanitized_prompt)" | grep -qiE '^[[:space:]]*no-inflight-ack:[[:space:]]*[^[:space:]]'; then
      FAIL=1
      FAIL_REASONS+=("ack-contract-missing: this spawn gets a worktree (isolation='${ISOLATION:-unset}'), so a land can move main under it and nothing will tell it. The prompt must carry the ack contract — either name the helper (scripts/inflight-ack.sh, reachable at ~/.claude/richos-engine/scripts/inflight-ack.sh) or spell out the ack file itself (<worktree>/.claude/inflight-acks/<sha12>.<teammate>.ack with its sha/impact/detail/paths/teammate keys) — because an instruction sent LATER travels the same lossy channel as the notice it is supposed to make verifiable. If this teammate genuinely writes nothing and reads nothing that can go stale, opt out on the record with a live prompt line: 'no-inflight-ack: <reason>'.")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Emit result
# ---------------------------------------------------------------------------
if [ "$FAIL" -eq 1 ]; then
  echo "=== Agent prompt verification FAILED ===" >&2
  for reason in "${FAIL_REASONS[@]}"; do
    echo "  - $reason" >&2
  done
  echo "(hook: scripts/hooks/verify-agent-prompt.sh)" >&2
  exit 2
fi

exit 0
