#!/usr/bin/env bash
#
# guard-stale-staging.sh — BLOCKING PreToolUse guard on the Agent tool.
#
# REFUSES A DISPATCH THAT WILL WORK ON, OR TEST AGAINST, A PRODUCT TREE WHOSE
# LANDED COMMITS HAVE NOT REACHED STAGING.
#
# ===========================================================================
# THE FAILURE THIS EXISTS TO PREVENT
# ===========================================================================
# The adopting repository's own rule, in its words:
#
#     "Staging MUST be brought current BEFORE the next `avelor/` or `fitapp/`
#      work or QA run, whatever landed in between. That is where the protection
#      actually lives, and it is a precondition of resuming product work rather
#      than a per-land chore."
#
# That is a paragraph, and a paragraph is a promise. Nothing enforced it. The
# first product QA run after a gap meets a staging that is weeks stale, and the
# only thing between that and a false QA verdict is somebody remembering a
# sentence. A rule enforced by attention lasts exactly as long as the attention
# — the same finding this engine's row-currency contract was built from.
#
# ===========================================================================
# THE HALF THAT MATTERS MORE: WHAT THIS MUST *NOT* DO
# ===========================================================================
# The same ruling that created the obligation also bounded it, on 2026-09-02,
# after a failed deploy was reported to the founder FIVE TIMES in a day during
# which 35 commits landed and ZERO touched product code:
#
#     "A land touching only `scripts/`, `docs/`, `.claude/`, `skills/` or the
#      record still deploys when deploy is working. But a deploy failure on
#      such a land is RECORDED, NEVER REPORTED — nothing shipped and nothing is
#      at risk."
#
# A guard that cannot tell those two cases apart fires on every docs land, gets
# waived on the day, and habitual waiving is how a guard dies. This engine has
# three recorded instances of that shape in a single day.
#
# SO THE REFUSAL IS A CONJUNCTION OF THREE FACTS, AND ALL THREE MUST HOLD:
#
#   1. There is a RECORD of what staging has, and it is behind main.
#   2. The commits between the record and main TOUCH A DECLARED PRODUCT TREE.
#      This is the whole of the 2026-09-02 amendment, mechanized. A staging 35
#      commits behind on docs is SILENT — not tolerated, not warned about,
#      silent — because nothing shipped and nothing is at risk.
#   3. THIS dispatch is product work or a run against staging.
#
# Fact 2 is computed from git and is the one that keeps the guard alive: in the
# adopting repository at the time this was written, `avelor/` had not changed
# since 2026-07-28 and `fitapp/` since 2026-05-05, so the guard is structurally
# incapable of firing until product work resumes — which is the moment the rule
# exists for. Fact 3's prose classifier is deliberately allowed to be a little
# broad BECAUSE fact 2 gates it: an over-broad match can only produce a refusal
# inside the window between a product land and its deploy, and inside that
# window "you mentioned avelor/ and testing" is the RIGHT time to be stopped.
#
# ===========================================================================
# WHY PreToolUse[Agent], AND NOT THE LAND
# ===========================================================================
# The row that asked for this offered two chokepoints — the land, or the
# dispatch. The ruling picks for us: the obligation is "a precondition of
# resuming product work rather than a per-land chore". Refusing the LAND would
# also be backwards, because the land is both what creates the debt and what
# discharges it (deploy is the land's last step); a guard there would wedge the
# very command that fixes it.
#
# Rejected alternatives, argued rather than left to be re-derived:
#
#   PreToolUse[Bash] on the test command — REJECTED. It would have to match
#     every shape of "run something against staging", a large and open class,
#     and it fires after the dispatch that already committed the work.
#   A Stop-hook notice — REJECTED. It reports a QA run that already happened
#     against a stale environment, which is the verdict this exists to prevent.
#   A checklist in the land skill — REJECTED for the reason the paragraph it
#     replaces failed: enforcement by attention.
#
# ===========================================================================
# THE RECORD — WHY A LOCAL FILE, AND WHAT ITS ABSENCE MEANS
# ===========================================================================
# "What does staging have?" has exactly one trustworthy answer and it is not a
# network call. The founder's standing ruling (11.4) is that the Railway login
# is restored when product work resumes and NOT before, so a guard that phoned
# the platform would fail at precisely the moment it matters. A PreToolUse hook
# also must not spend seconds on HTTP.
#
# So the guard reads a LOCAL, DURABLE record that the deploy writes:
#
#     <entity root>/.claude/state/staging-deployed     (STAGING_DEPLOY_RECORD)
#
#         sha=8f3a1c2b9d40
#         outcome=success
#         tree=avelor
#         at=2026-09-06T10:11:12Z
#
# Minted by scripts/staging-record.sh, which the deploy script calls once its
# own freshness gate has passed — never before, so a record can never claim a
# deploy that did not finish. `outcome=` anything but `success` is read as NO
# RECORD, deliberately: "the deploy ran and failed" and "staging is current"
# must never produce the same verdict.
#
# ADOPTION COSTS NOTHING ON THE DAY IT HAPPENS, and that is a design decision
# taken from measurement rather than taste. On 2026-09-06 the sibling headline
# contract was measured on the real record: declaring its jurisdiction produced
# ZERO refusals and 26 rows named, and its teeth were a SECOND declared key.
# The same two-key shape is used here. Until a deploy has ever written a
# record, this guard ALLOWS and ANNOUNCES — and it announces only at the moment
# of a dispatch that would have been in scope, never on the 99% of dispatches
# that have nothing to do with the product. Declare STAGING_RECORD_REQUIRED=1
# when the deploy is wired and the absence of a record should itself refuse.
#
# ===========================================================================
# FAIL OPEN, AND LOUDLY — but never on the quiet path
# ===========================================================================
#   NOT ADOPTED (no orchestration.config)   -> STAND DOWN, silent.
#   STAGING_TREES NOT DECLARED              -> STAND DOWN, SILENT. This is the
#     adoption switch and its absence is silent, unlike the model ceiling's:
#     most repositories have no staging at all, and a per-spawn announcement in
#     every one of them is noise rather than protection.
#   NO DEBT (record current, or nothing
#   product-shaped between it and main)     -> SILENT. Always. See fact 2.
#   NOT AN IN-SCOPE DISPATCH                -> SILENT.
#   RECORD MISSING / MALFORMED / FAILED,
#   on an IN-SCOPE dispatch                 -> ALLOW + ANNOUNCE (or REFUSE if
#     STAGING_RECORD_REQUIRED=1).
#   GIT, PYTHON3, CONFIG OR ROOTS UNREADABLE-> ALLOW + ANNOUNCE. "I cannot
#     tell" is never "forbidden".
#
# The one thing that is NOT fail-open: scripts/lib/resolve-roots.sh missing
# entirely. That is the shared bootstrap's contract and probe Layer R asserts
# every rooted hook carries it byte-identically.
#
# ===========================================================================
# THE ESCAPE HATCH — a live prompt line, with a reason, logged
# ===========================================================================
#     stale-staging-ack: <reason>
#
# anywhere on its own line in the Agent spawn prompt. It permits that ONE
# dispatch and appends to <entity root>/.claude/state/stale-staging-acks.log.
# Same idiom as `model-ceiling-ack:`, `main-checkout-run:`, `resume-ack:` and
# `data-contract-bypass:`. A bare marker exempts nothing.
#
# There IS an escape hatch here, unlike the row-currency contract's deliberate
# refusal to have one, and the difference is real: row currency's judgment ("I
# will fix the row after the deploy") fails at the moment of the land, so an
# override would have been used every time. This guard's legitimate exception
# is a different thing entirely — a dispatch that names a product path while
# genuinely not testing against staging (reading the code, auditing a diff,
# writing a plan). Refusing those with no way through would make the guard a
# nuisance on exactly the tasks that are safe, which is how a guard gets
# routed around instead of used.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the
# next session — it assumes nothing about being live in the session that adds it.

set -eo pipefail

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
        echo "  hook: scripts/hooks/guard-stale-staging.sh"
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

# announce_off <one-line> — the best-effort loud channel for a fail-open. BOTH
# stderr and systemMessage, because neither is proven for this event and a
# condition announced on nothing is the defect this whole file is about.
announce_off() {
    printf '%s\n' "$1" >&2
    if command -v python3 >/dev/null 2>&1; then
        SYSMSG="$1" python3 -c '
import json, os
print(json.dumps({"systemMessage": os.environ.get("SYSMSG", "")}))
' 2>/dev/null || true
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    # SILENT on the tool-missing path is wrong, but so is announcing in every
    # repository on the machine. Only repositories that ADOPTED this have
    # anything to lose, and adoption cannot be read without python3 — so this
    # says so once, on stderr, and allows.
    announce_off "STALE-STAGING GUARD IS OFF: python3 is not on PATH, so this dispatch was not checked against the staging deploy record."
    exit 0
fi

if ! resolve_entity_root "$INPUT"; then
    if [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
        exit 0
    fi
    announce_off "STALE-STAGING GUARD IS OFF: it cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nothing is checking whether a product dispatch is about to run against a stale staging."
    exit 0
fi
ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

# --- THE ADOPTION SWITCH ---------------------------------------------------
# Absent or blank -> this repository has no staging this guard knows about.
# SILENT, and before anything else is read: a repository that never adopted
# must cost nothing, not even a payload parse.
STAGING_TREES="${STAGING_TREES:-}"
[ -n "$(printf '%s' "$STAGING_TREES" | tr -d '[:space:]')" ] || exit 0

: "${STAGING_DEPLOY_RECORD:=.claude/state/staging-deployed}"
: "${STAGING_DEPLOY_COMMAND:=}"
: "${STAGING_RECORD_REQUIRED:=0}"
: "${STAGING_MAIN_REF:=refs/heads/main}"
# The two halves of "is THIS dispatch in scope". Overridable, because an
# adopter's vocabulary is theirs; defaulted, because a key nobody sets is a
# check nobody gets.
: "${STAGING_TRIGGER_RE:=(\btests?\b|\btesting\b|\baudit\b|\bQA\b|\bverif(y|ies|ication)\b|\brender\b|\bscreenshot\b|\bstaging\b|\be2e\b|playwright|install-fresh|\bregression\b|\bimplement\b|\bfix\b|\bbuild\b)}"

# --- UNEVALUATED-PAYLOAD NOTICE --------------------------------------------
# On a payload it cannot read, this guard takes the SAME silent exit 0 that a
# well-formed payload for a DIFFERENT tool takes, which is why 17 of 25
# PreToolUse guards were measured passing a call in complete silence on
# 2026-09-05. This separates the two. NO VERDICT CHANGES — only the silence.
_UE_LIB="$SCRIPT_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_UE_LIB"
    unevaluated_or_continue "guard-stale-staging.sh" "$INPUT" \
        "${ENTITY_ROOT:-${SEAT_ROOT:-${RICHOS_ENTITY_ROOT_RESOLVED:-}}}" \
        "whether this dispatch works on or tests against a product tree whose landed commits have not reached staging"
fi

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

# --- Parse the spawn -------------------------------------------------------
# Newlines survive through a \001 placeholder so the ack marker can be matched
# with a line-start anchor, exactly as the other Agent guards do it.
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        raise ValueError("tool_input not an object")
    pr = str(ti.get("prompt", "") or "").replace("\t", " ").replace("\n", "\x01")
    print("OK\t%s\t%s\t%s\t%s" % (
        str(ti.get("subagent_type", "") or ""),
        str(ti.get("name", "") or ""),
        str(d.get("session_id", "") or ""),
        pr,
    ))
except Exception:
    print("PARSEFAIL\t\t\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f2)"
NAME="$(printf '%s' "$PARSED" | cut -f3)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f4)"
PROMPT="$(printf '%s' "$PARSED" | cut -f5- | tr '\001' '\n')"

# FAIL OPEN on an unparseable payload, and say so. Same choice as
# guard-model-ceiling.sh and for the same reason: this guard cannot read the
# prompt OR the ack line from such a payload, so refusing would block a
# dispatch the operator has no way to permit.
if [ "$STATUS" = "PARSEFAIL" ]; then
    announce_off "STALE-STAGING GUARD: this Agent spawn could not be parsed, so it was not checked against the staging deploy record and the 'stale-staging-ack:' line could not be read either. This ONE dispatch is UNCHECKED."
    exit 0
fi

# --- IS THIS DISPATCH IN SCOPE? --------------------------------------------
# BOTH halves, never one: a product path AND something that works on or runs
# against it. `avelor/` appears in a great deal of this project's prose — a
# row of the working record, a brief quoting that row — and prose is not a
# dispatch. The path half is built from the DECLARATION so an adopter's trees
# are the adopter's.
SCOPE_ALT="$(printf '%s' "$STAGING_TREES" | tr -s '[:space:]' '|' | sed 's/^|//; s/|$//')"
SCOPE_RE="(^|[^A-Za-z0-9_.-])(${SCOPE_ALT})/"

in_scope() {
    printf '%s' "$PROMPT" | grep -qE "$SCOPE_RE" || return 1
    printf '%s' "$PROMPT" | grep -qiE "$STAGING_TRIGGER_RE" || return 1
    return 0
}

# --- THE DEBT --------------------------------------------------------------
# Computed against the MAIN CHECKOUT, from any invocation location: an agent's
# session cwd is usually a linked worktree, and a worktree's HEAD is a proposal
# rather than what landed.
MAIN_ROOT="$ENTITY_ROOT"
_MC_LIB="$SCRIPT_DIR/../lib/resolve-main-checkout.sh"
if [ -f "$_MC_LIB" ]; then
    # shellcheck source=../lib/resolve-main-checkout.sh
    . "$_MC_LIB"
    MAIN_ROOT="$(resolve_main_checkout "$ENTITY_ROOT" "$ENTITY_ROOT" 2>/dev/null || printf '%s' "$ENTITY_ROOT")"
fi

RECORD_PATH="$STAGING_DEPLOY_RECORD"
case "$RECORD_PATH" in
    /*) : ;;
    *)  RECORD_PATH="$ENTITY_ROOT/$RECORD_PATH" ;;
esac

# read_record — sets DEPLOYED and RECORD_PROBLEM. NOT a function that echoes
# its answer: `X="$(read_record)"` runs it in a subshell, so the REASON a record
# was rejected would be discarded and every rejection would print the same
# generic "no record exists". A guard that cannot say WHY it is unsure is the
# shape this engine keeps finding in itself — 'worked' and 'never ran' reported
# identically.
DEPLOYED=""
RECORD_PROBLEM=""
read_record() {
    if [ ! -f "$RECORD_PATH" ]; then
        RECORD_PROBLEM="no staging deploy record exists at ${RECORD_PATH}"
        return 1
    fi
    local sha outcome
    sha="$(grep -E '^[[:space:]]*sha[[:space:]]*=' "$RECORD_PATH" 2>/dev/null | head -1 \
           | sed -E 's/^[[:space:]]*sha[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//' || true)"
    outcome="$(grep -E '^[[:space:]]*outcome[[:space:]]*=' "$RECORD_PATH" 2>/dev/null | head -1 \
           | sed -E 's/^[[:space:]]*outcome[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//' || true)"
    if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{7,40}$'; then
        RECORD_PROBLEM="the record at ${RECORD_PATH} carries no readable 'sha=' line, so what staging is running cannot be read from it"
        return 1
    fi
    # A record with no outcome at all is read as a success record: the field is
    # an ESCALATION of precision, and an adopter whose writer predates it must
    # not be told its staging is unknown. A record that states a NON-success
    # outcome is read as no record — "the deploy ran and failed" and "staging
    # is current" must never produce the same verdict.
    if [ -n "$outcome" ] && [ "$outcome" != "success" ]; then
        RECORD_PROBLEM="the record at ${RECORD_PATH} states outcome='${outcome}', so the last deploy did not succeed and what staging carries is unknown"
        return 1
    fi
    DEPLOYED="$sha"
    return 0
}

read_record || true

if [ -z "$DEPLOYED" ]; then
    # NO USABLE RECORD. Only speak if this dispatch would have been in scope —
    # a repository mid-adoption must not be nagged on every unrelated spawn.
    in_scope || exit 0
    WHY="${RECORD_PROBLEM:-no staging deploy record exists at ${RECORD_PATH}}"
    if [ "$STAGING_RECORD_REQUIRED" = "1" ]; then
        {
            echo "=== STALE STAGING — WHAT STAGING CARRIES IS UNKNOWN, AND THIS DISPATCH IS PRODUCT WORK ==="
            echo "  dispatch : ${NAME:-<unset>} of '${SUBAGENT_TYPE:-<unset>}'"
            echo "  problem  : ${WHY}"
            echo ""
            echo "  This repository declares STAGING_RECORD_REQUIRED=1, so an unknown"
            echo "  staging is refused rather than announced. Deploy, which writes the"
            echo "  record: ${STAGING_DEPLOY_COMMAND:-<your deploy script>}"
            echo ""
            echo "  OR, if this dispatch genuinely does not run against staging, add ONE"
            echo "  line to the spawn prompt:"
            echo ""
            echo "      stale-staging-ack: <why this dispatch cannot be fooled by a stale staging>"
            echo "(hook: scripts/hooks/guard-stale-staging.sh)"
        } >&2
        exit 2
    fi
    announce_off "STALE-STAGING GUARD CANNOT DECIDE: ${WHY}. This dispatch (${NAME:-<unset>}) names a product tree and a run against it, so a QA verdict from it could be about a stale staging. Have the deploy call scripts/staging-record.sh, then declare STAGING_RECORD_REQUIRED=1 in ${CONFIG} to make this a refusal."
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    in_scope || exit 0
    announce_off "STALE-STAGING GUARD IS OFF: git is not on PATH, so the commits between the deploy record (${DEPLOYED}) and main could not be listed. This dispatch is UNCHECKED."
    exit 0
fi

MAIN_TIP="$(git -C "$MAIN_ROOT" rev-parse --verify --quiet "$STAGING_MAIN_REF" 2>/dev/null || true)"
if [ -z "$MAIN_TIP" ]; then
    in_scope || exit 0
    announce_off "STALE-STAGING GUARD IS OFF: '${STAGING_MAIN_REF}' does not resolve in ${MAIN_ROOT}, so there is nothing to compare the deploy record against. This dispatch is UNCHECKED. (STAGING_MAIN_REF in ${CONFIG} names the branch that lands.)"
    exit 0
fi

if ! git -C "$MAIN_ROOT" cat-file -e "${DEPLOYED}^{commit}" 2>/dev/null; then
    in_scope || exit 0
    announce_off "STALE-STAGING GUARD CANNOT DECIDE: the deploy record names commit ${DEPLOYED}, which does not exist in ${MAIN_ROOT}. A record pointing at nothing is not a record. Re-run the deploy so it writes a current one."
    exit 0
fi

# THE ONE QUESTION THAT MATTERS. Not "is staging behind" — "is staging behind
# ON SOMETHING THAT SHIPPED". A pathspec-restricted rev-list is the whole of
# the 2026-09-02 amendment, and it is why a docs-only land is silent here.
# shellcheck disable=SC2086
UNDEPLOYED="$(git -C "$MAIN_ROOT" rev-list --count "${DEPLOYED}..${MAIN_TIP}" -- $STAGING_TREES 2>/dev/null || printf 'ERR')"

if [ "$UNDEPLOYED" = "ERR" ]; then
    in_scope || exit 0
    announce_off "STALE-STAGING GUARD IS OFF: could not list commits between ${DEPLOYED} and ${STAGING_MAIN_REF} in ${MAIN_ROOT}. This dispatch is UNCHECKED."
    exit 0
fi

# NO PRODUCT DEBT -> SILENT, ALWAYS, however far behind staging is otherwise.
# This is the amendment: nothing shipped, nothing is at risk, and a guard that
# spoke here would be waived within the day.
[ "$UNDEPLOYED" -gt 0 ] 2>/dev/null || exit 0

# There IS product debt. Is this dispatch the moment the rule cares about?
in_scope || exit 0

# --- Acknowledged? ---------------------------------------------------------
ACK_MARKER="stale-staging-ack"
ACK_REASON="$(printf '%s' "$PROMPT" \
    | grep -E "^[[:space:]]*${ACK_MARKER}:[[:space:]]*[^[:space:]]" \
    | head -1 \
    | sed -E "s/^[[:space:]]*${ACK_MARKER}:[[:space:]]*//" || true)"

# The length floors are the staffing gate's, deliberately: one engine, one idea
# of what a reason looks like. A bare marker exempts nothing.
ACK_WHY=""
if [ -z "$ACK_REASON" ]; then
    ACK_WHY="no 'stale-staging-ack: <reason>' line is present in the prompt."
elif [ "${#ACK_REASON}" -lt 30 ]; then
    ACK_WHY="the reason given is ${#ACK_REASON} character(s) long; a real justification needs at least 30. A bare or token marker exempts nothing."
fi

if [ -z "$ACK_WHY" ]; then
    LOG_DIR="$ENTITY_ROOT/.claude/state"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    {
        printf '%s\tsession=%s\tagent=%s\tname=%s\tdeployed=%s\tmain=%s\tundeployed=%s\t%s: %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${SESSION_ID:-<unset>}" "${SUBAGENT_TYPE:-<unset>}" "${NAME:-<unset>}" \
            "$DEPLOYED" "$(printf '%s' "$MAIN_TIP" | cut -c1-12)" "$UNDEPLOYED" \
            "$ACK_MARKER" "$ACK_REASON"
    } >>"$LOG_DIR/stale-staging-acks.log" 2>/dev/null || true
    exit 0
fi

# --- REFUSE — and CARRY the rule, do not point at it ------------------------
COMMITS="$(git -C "$MAIN_ROOT" log --oneline --no-decorate -5 "${DEPLOYED}..${MAIN_TIP}" -- $STAGING_TREES 2>/dev/null || true)"
TOUCHED="$(git -C "$MAIN_ROOT" diff --name-only "${DEPLOYED}..${MAIN_TIP}" -- $STAGING_TREES 2>/dev/null | head -5 || true)"

{
    echo "=== STALE STAGING — PRODUCT COMMITS HAVE LANDED AND HAVE NOT BEEN DEPLOYED ==="
    echo "  dispatch     : ${NAME:-<unset>} of '${SUBAGENT_TYPE:-<unset>}'"
    echo "  staging has  : ${DEPLOYED}   (${RECORD_PATH})"
    echo "  main is at   : $(printf '%s' "$MAIN_TIP" | cut -c1-12)   (${STAGING_MAIN_REF} in ${MAIN_ROOT})"
    echo "  undeployed   : ${UNDEPLOYED} commit(s) touching: ${STAGING_TREES}"
    echo ""
    if [ -n "$COMMITS" ]; then
        echo "  WHAT IS NOT ON STAGING (newest first, up to 5):"
        printf '%s\n' "$COMMITS" | sed 's/^/    /'
        echo ""
    fi
    if [ -n "$TOUCHED" ]; then
        echo "  FILES THAT DIFFER (up to 5):"
        printf '%s\n' "$TOUCHED" | sed 's/^/    /'
        echo ""
    fi
    echo "  THE RULE, IN ONE LINE: staging must be brought current BEFORE the next"
    echo "  product work or QA run, whatever landed in between. It is a precondition"
    echo "  of resuming product work, not a per-land chore — which is why you are"
    echo "  hearing it HERE, at the dispatch, and not at the land that created it."
    echo ""
    echo "  WHY THIS IS NOT NOISE: a land touching only scripts/, docs/, .claude/,"
    echo "  skills/ or the record is NEVER refused here, however far behind staging"
    echo "  is — nothing shipped and nothing is at risk. This dispatch is refused"
    echo "  because ${UNDEPLOYED} commit(s) DID touch ${STAGING_TREES}, and a QA verdict"
    echo "  taken against staging now would be a verdict about older code."
    echo ""
    echo "  DEPLOY (the usual answer): ${STAGING_DEPLOY_COMMAND:-<your staging deploy script>}"
    echo "  It writes the record this guard reads, so the refusal clears itself."
    echo ""
    echo "  OR ACKNOWLEDGE, if this dispatch genuinely cannot be fooled by a stale"
    echo "  staging — reading the code, auditing a diff, writing a plan. Add ONE line:"
    echo ""
    echo "      ${ACK_MARKER}: <why a stale staging cannot affect this dispatch's result>"
    echo ""
    if [ -n "$ACK_REASON" ]; then
        echo "  THE LINE YOU GAVE WAS NOT ACCEPTED: ${ACK_WHY}"
        echo ""
    fi
    echo "  Accepted uses are appended to .claude/state/stale-staging-acks.log, so a"
    echo "  habit of waiving is visible rather than invisible."
    echo "(hook: scripts/hooks/guard-stale-staging.sh)"
} >&2
exit 2
