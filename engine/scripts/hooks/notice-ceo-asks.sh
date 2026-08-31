#!/usr/bin/env bash
#
# notice-ceo-asks.sh — PostToolUse[AskUserQuestion] hook. LOG-ONLY; never blocks.
#
# THE WITNESS THAT MAKES "HE WAS ASKED" AN ENFORCEABLE FACT.
#
# The rationale, the failure it exists for and the three-state fail-open
# argument all live in scripts/lib/ceo-asks.sh. Read that first; this file is
# the wiring and the record.
#
# ===========================================================================
# WHY A WITNESS AND NOT A CLAIM
# ===========================================================================
# On 2026-08-31 the orchestrator's record said two decisions were prepared for
# the CEO. Every guard agreed. He was not asked. A mechanism that took the
# orchestrator's word for "I put it to him" would have reported exactly the same
# green over exactly the same silence.
#
# So the only thing that produces a record here is a genuine AskUserQuestion
# tool call, observed as it resolves, in the caller's own execution. There is
# nothing to remember and nothing to assert. This is the same trade
# notice-inflight-sends.sh makes one event over, and for the same reason: the
# channel that would otherwise carry the evidence is lossy, and an obligation
# discharged by a message is an obligation discharged by hope.
#
# WHY PostToolUse. PreToolUse fires on the INTENT. A question the host refuses,
# or one the operator escapes out of, would credit the session for an ask that
# never reached anybody. PostToolUse fires only for a call that went through.
#
# ===========================================================================
# THE MATCH IS COMPUTED FROM WHAT HE SAW — never from what was declared
# ===========================================================================
# Which prepared item a question was about is decided from the question TEXT:
# the question itself, its header, every option label and every option
# description. Nothing the orchestrator says about its own intent is read,
# because an intent is exactly what was green on the morning this was ordered.
#
# A QUESTION THAT MATCHES NOTHING IS RECORDED AS `UNMATCHED` AND DISCHARGES
# NOTHING. That is the anti-gaming property and it is load-bearing: without it,
# one junk question per session clears the gate forever and the gate becomes a
# formality with a log. It is pinned by a named case in ceo-asks.test.sh.
#
# EVERY question in the call gets its own ledger line. A multi-question call
# that covers two prepared items discharges both; one that covers none
# discharges neither, and says so twice.
#
# ===========================================================================
# WHAT IS RECORDED
# ===========================================================================
#   -> <entity root>/.claude/state/ceo-asks.jsonl
#
# Per question: the matched item id (or UNMATCHED), which repository it came
# from, the match score and how it matched, the question text, the timestamp and
# the session id. The TEXT is recorded here, deliberately unlike
# notice-inflight-sends.sh which refuses to log message bodies — a question put
# to the CEO is not private correspondence, it is the artifact under audit, and
# an UNMATCHED line is useless for diagnosis without the words that failed to
# match. It is truncated, because a ledger is evidence and not a transcript.
#
# THE ATTRIBUTION GATE: a call carrying an `agent_id` came from a WORKER, not
# from the orchestrator. Recorded with the agent id and `discharges:false`, and
# the assess predicate ignores it — a teammate asking its own clarifying
# question has not put the CEO's prepared decision to him, and letting it count
# would hand every session a free discharge via any subagent that happens to ask
# anything.
#
# NEVER BLOCKS, ALWAYS EXIT 0. A witness that can fail a tool call is a witness
# people remove.

set -o pipefail

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
        echo "  hook: scripts/hooks/notice-ceo-asks.sh"
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

resolve_entity_root "$INPUT" || exit 0
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

_CA_LIB="$SCRIPT_DIR/../lib/ceo-asks.sh"
[ -f "$_CA_LIB" ] || exit 0
# shellcheck source=../lib/ceo-asks.sh
. "$_CA_LIB"

ca_require || exit 0

# A repository with no declared CEO TODOs has nothing to witness an ask AGAINST.
# Silent — the guard and the Stop notice own the announcements; a witness that
# also narrated would put a line under every question in every repository on the
# machine.
ca_resolve "$ENTITY_ROOT" || exit 0

ITEMS="$(mktemp -t ceo-asks-items.XXXXXX.json)" || exit 0
if ! ca_items_json "$ITEMS"; then
    rm -f "$ITEMS"
    exit 0
fi

# --- Split the call into questions -----------------------------------------
# One record per question, so a multi-question call is not collapsed into a
# single ask. Each is emitted as: <question index><TAB><assembled text with
# newlines as \001>, which keeps the whole thing on one line for `read`.
QLIST="$(CA_PAYLOAD="$INPUT" python3 -c '
import json, os, sys

try:
    d = json.loads(os.environ.get("CA_PAYLOAD") or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
if d.get("hook_event_name") not in ("", None, "PostToolUse"):
    sys.exit(0)
if d.get("tool_name") != "AskUserQuestion":
    sys.exit(0)

ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

def flatten(q):
    """Everything the CEO actually saw for one question."""
    parts = []
    if isinstance(q, dict):
        for key in ("header", "question"):
            v = q.get(key)
            if isinstance(v, str):
                parts.append(v)
        for opt in (q.get("options") or []):
            if isinstance(opt, dict):
                for key in ("label", "description"):
                    v = opt.get(key)
                    if isinstance(v, str):
                        parts.append(v)
            elif isinstance(opt, str):
                parts.append(opt)
    elif isinstance(q, str):
        parts.append(q)
    return "\n".join(p for p in parts if p)

questions = ti.get("questions")
if isinstance(questions, list) and questions:
    texts = [flatten(q) for q in questions]
else:
    # SCHEMA DRIFT IS A REAL RISK and it must not be silent. If the tool ever
    # stops carrying `questions`, fall back to every string in tool_input so the
    # witness still sees the words — a witness that quietly recorded nothing
    # because a field was renamed is the exact failure it exists to prevent.
    texts = ["\n".join(v for v in ti.values() if isinstance(v, str))]

for i, t in enumerate(texts):
    if not t.strip():
        continue
    sys.stdout.write("%d\t%s\n" % (i, t.replace("\t", " ").replace("\n", "\x01")))
' 2>/dev/null || true)"

if [ -z "$QLIST" ]; then
    rm -f "$ITEMS"
    exit 0
fi

SESSION_ID="$(CA_PAYLOAD="$INPUT" python3 -c '
import json, os
try:
    d = json.loads(os.environ.get("CA_PAYLOAD") or "{}")
    print(str(d.get("session_id", "") or ""))
except Exception:
    print("")
' 2>/dev/null || true)"
AGENT_ID="$(CA_PAYLOAD="$INPUT" python3 -c '
import json, os
try:
    d = json.loads(os.environ.get("CA_PAYLOAD") or "{}")
    print(str(d.get("agent_id", "") or ""))
except Exception:
    print("")
' 2>/dev/null || true)"

LEDGER="$(ca_ledger_path "$ENTITY_ROOT")"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

QFILE="$(mktemp -t ceo-asks-q.XXXXXX)" || { rm -f "$ITEMS"; exit 0; }

while IFS=$'\t' read -r QIDX QTEXT; do
    [ -n "${QTEXT:-}" ] || continue
    printf '%s' "$QTEXT" | tr '\001' '\n' > "$QFILE"
    LINE="$(ca_match "$QFILE" "$ITEMS" 2>/dev/null || true)"
    # A predicate that could not run records UNMATCHED with `how` naming why.
    # Written with printf rather than as a literal, because tabs typed into a
    # shell string are invisible in every diff that will ever be read.
    [ -n "$LINE" ] || LINE="$(printf 'UNMATCHED\t\t\t0.00\t0\t0\tpredicate-failed')"

    CA_LINE="$LINE" CA_QIDX="$QIDX" CA_SID="$SESSION_ID" CA_AID="$AGENT_ID" \
    CA_QFILE="$QFILE" CA_LEDGER="$LEDGER" python3 -c '
import json, os
from datetime import datetime, timezone

f = (os.environ.get("CA_LINE") or "").split("\t")
f = (f + [""] * 7)[:7]
verdict, repo, item_id, score, hits, needed, how = f

try:
    text = open(os.environ["CA_QFILE"], encoding="utf-8", errors="replace").read()
except Exception:
    text = ""

agent_id = os.environ.get("CA_AID") or ""
record = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "CeoAsk",
    "source_hook": "PostToolUse[AskUserQuestion]",
    "session_id": os.environ.get("CA_SID") or "",
    "question_index": os.environ.get("CA_QIDX") or "",
    # UNMATCHED is written into matched_item verbatim, never left blank: a blank
    # field reads as "not filled in yet" and this one means "asked about nothing
    # on his page".
    "matched_item": item_id if verdict == "MATCH" else "UNMATCHED",
    "match": verdict,
    "repo": repo,
    "score": score,
    "hits": hits,
    "needed": needed,
    "how": how,
    "question_chars": len(text),
    "question": text[:1200],
    "agent_id": agent_id,
    # A worker asking its own clarifying question has not put the CEOs prepared
    # decision to him. Recorded, and explicitly worth nothing.
    "discharges": bool(verdict == "MATCH" and not agent_id),
}
try:
    with open(os.environ["CA_LEDGER"], "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
except Exception:
    pass
' 2>/dev/null || true
done <<EOF
$QLIST
EOF

rm -f "$ITEMS" "$QFILE"
exit 0
