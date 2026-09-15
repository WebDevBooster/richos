#!/usr/bin/env bash
#
# scripts/lib/mechanical-findings.sh — FINDINGS BECOME ROWS, NOT MEMORIES.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-02 an audit found eight real defects in twenty minutes that six
# weeks of attention had missed. The audit ran because the CEO asked for it.
# Its findings became rows because the lead typed them. And the one finding
# that had been known for six weeks — a red suite skipped in CI under the
# comment "Tracked separately" — was tracked in none of the three queue files,
# because "tracked separately" is what a person's memory looks like from the
# outside.
#
# Three links were missing and every one of them is plumbing:
#
#   1. NOTHING TRIGGERED THE AUDIT. Automating the search while the CEO stays
#      the trigger moves the babysitting; it does not remove it.
#   2. A FINDING DID NOT BECOME A ROW. The lead wrote each row by hand, so a
#      finding survived exactly as long as he remembered it.
#   3. A ROW DID NOT START ITSELF. The queue's own header says a land ends by
#      starting the top unblocked item; nothing enforced it. (That link
#      already had a hook — notice-unstarted-rows.sh — and this file's job is
#      to hand it rows it can see.)
#
#   A RULE ENFORCED BY ATTENTION LASTS EXACTLY AS LONG AS THE ATTENTION.
#
# That sentence heads three other predicates in this engine. This is the same
# defect one level up: not a row going stale, but a row never being written.
#
# ===========================================================================
# THE TRIGGER IS THE TURN END, GATED ON NOTHING — the design decision
# ===========================================================================
# Every defect this sweep finds is introduced by a LAND: a commit that adds a
# harness without touching a runner, a workflow edit that skips a suite, a
# registry edit that wires a hook nobody tested. All three are visible in the
# tree from the moment they land. Three candidate triggers, argued from where
# the defect becomes visible:
#
#   A PreToolUse GUARD AT THE LAND — rejected. To matter it would have to
#     block, and a guard that blocks on a coverage fact is the guard that gets
#     waived: two waiver ledgers on this machine held 251 entries on the day
#     this was written, every one of them written by the lead and read by
#     nobody. A finding is not a refusal. It is a row.
#
#   SessionStart — nearly right, and rejected for the same reason the
#     unstarted-row sweep rejected the land as its event: the defect lands
#     mid-session and would sit unfound until tomorrow. It is also once per
#     session, so a session that runs twelve lands checks once.
#
#   Stop — CHOSEN. A land is a Bash call inside a turn, and every turn ends at
#     Stop, so the sweep runs at the end of the turn that landed the defect.
#     The sweep reads a few dozen files at HEAD through four version-control
#     calls per root and finishes in well under a second, so it is not gated
#     on HEAD movement: a gate is one more piece of state that can be wrong,
#     and the de-duplication that matters is on the ROW (identity), not on
#     the run.
#
# WHAT IT READS: the record's own declared artifact roots — the repositories
# it already says the work lives in — at HEAD of their MAIN checkouts. Never
# a typed list of repositories, and never the working copy: a finding about
# landed state must not change because somebody has an editor open.
#
# ===========================================================================
# WHAT IT CANNOT SEE — stated here, not discovered later
# ===========================================================================
#   * A DEFECT NOT YET LANDED. A worktree branch is a proposal; the sweep
#     reads main. The defect is found at the end of the turn that lands it.
#   * A REPOSITORY THE RECORD DOES NOT DECLARE. If it is not in
#     ARTIFACT_ROOTS, it is not swept, and the receipt names what was.
#   * ANY DEFECT THAT NEEDS A JUDGMENT. A pass condition that is also the
#     failure-to-run condition, an assertion that cannot fail for its stated
#     reason, a suite that is RED — these need a reader or a run, and this
#     sweep does neither. It carries three MECHANICAL classes, named in
#     scripts/lib/mechanical-findings.py, and a fourth class is one function.
#   * WHETHER A FINDING MATTERS. The row says what was seen. Deciding whether
#     to fix it, or to close it as won't-fix, is a person's job and stays one.
#   * A TURN IN A SESSION THAT DID NOT LOAD THIS HOOK. Hooks snapshot at
#     session start; the hook that carries this is inert until the next one.
#
# ===========================================================================
# USAGE
# ===========================================================================
#     . "$SCRIPT_DIR/../lib/mechanical-findings.sh"
#     mf_resolve "$repo"          # 0 governed / 1 stand down / 2 broken
#     mf_sweep [write]            # -> MF_VERDICT and the counts below
#     mf_receipt "$path"          # the positive probe, written on every path

_MF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MF_RC_LIB="$_MF_LIB_DIR/row-currency.sh"
_MF_PY="$_MF_LIB_DIR/mechanical-findings.py"

# ---------------------------------------------------------------------------
# mf_require_libs
# ---------------------------------------------------------------------------
# The record's location, its governed sections and its artifact roots are read
# through row-currency.sh (which reads .ceo-todos through ceo-todos.sh). Not a
# second copy: a predicate in two copies is the drift this engine keeps
# finding in itself.
mf_require_libs() {
    MF_BROKEN_REASON=""
    if [ ! -f "$_MF_RC_LIB" ]; then
        MF_BROKEN_REASON="scripts/lib/row-currency.sh is missing at $_MF_RC_LIB. The record's location, its governed sections and its artifact roots are read through that library and nowhere else."
        return 2
    fi
    # shellcheck source=./row-currency.sh
    . "$_MF_RC_LIB"
    if ! rc_require_ceo_todos_lib; then
        MF_BROKEN_REASON="$RC_BROKEN_REASON"
        return 2
    fi
    if [ ! -f "$_MF_PY" ]; then
        MF_BROKEN_REASON="scripts/lib/mechanical-findings.py is missing at $_MF_PY. The sweep is not present, so nothing was checked — and a sweep that reports a clean tree because its checker is absent is the exact shape of the failure it exists to catch."
        return 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        MF_BROKEN_REASON="python3 is not on PATH, so neither the tree nor the record can be read."
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# mf_resolve <repo_root>
# ---------------------------------------------------------------------------
#   rc 0  governed  -> MF_RECORD_REPO MF_RECORD_FILE MF_RECORD_LABEL
#                      MF_SECTIONS MF_STATUS_TOKENS MF_TERMINAL_TOKENS
#                      MF_ROOTS (tab-separated prefix=abs, MAIN checkouts)
#                      MF_ABSENT (tab-separated prefix=declared)
#   rc 1  stand down -> MF_STANDDOWN_REASON
#   rc 2  broken     -> MF_BROKEN_REASON
mf_resolve() {
    local root="${1:-}" here rrc
    MF_RECORD_REPO=""; MF_RECORD_FILE=""; MF_RECORD_LABEL=""
    MF_SECTIONS=""; MF_STATUS_TOKENS=""; MF_TERMINAL_TOKENS=""
    MF_ROOTS=""; MF_ABSENT=""
    MF_STANDDOWN_REASON=""; MF_BROKEN_REASON=""

    mf_require_libs || return 2
    [ -n "$root" ] || { MF_BROKEN_REASON="mf_resolve called with no repository"; return 2; }
    here="$(ct_repo_root "$root")" || {
        MF_STANDDOWN_REASON="$root is not inside a repository."
        return 1
    }

    rrc=0
    rc_load_declaration "$here" || rrc=$?
    case "$rrc" in
        0) ;;
        1)
            MF_STANDDOWN_REASON="no $ROW_CURRENCY_DECLARATION in $here, so no working record is declared and there is nowhere a finding could be written."
            return 1 ;;
        *) MF_BROKEN_REASON="$RC_BROKEN_REASON"; return 2 ;;
    esac
    rrc=0
    rc_resolve_record "$here" || rrc=$?
    case "$rrc" in
        0) ;;
        1) MF_STANDDOWN_REASON="$RC_STANDDOWN_REASON"; return 1 ;;
        *) MF_BROKEN_REASON="$RC_BROKEN_REASON"; return 2 ;;
    esac

    MF_RECORD_REPO="$RC_RECORD_REPO"
    MF_RECORD_LABEL="$RC_RECORD_REL"
    MF_RECORD_FILE="$RC_RECORD_REPO/$RC_RECORD_REL"
    MF_SECTIONS="$RC_ROW_SECTIONS"
    MF_STATUS_TOKENS="$RC_STATUS_TOKENS"
    MF_TERMINAL_TOKENS="$RC_TERMINAL_TOKENS"
    if [ ! -f "$MF_RECORD_FILE" ]; then
        MF_BROKEN_REASON="the working record declared by .ceo-todos ($RC_RECORD_REL) is not present in $MF_RECORD_REPO."
        return 2
    fi

    # THE ROOTS ARE THE MAIN CHECKOUTS. rc_resolve_record re-points the
    # caller's own prefix at the tree the caller stands in, which is right for
    # a landing guard (the tree being committed) and wrong here: a sweep over
    # landed state reads main, whichever worktree happens to run it. So the
    # roots are resolved again from the record's declaration, untouched.
    ct_resolve_roots "$MF_RECORD_REPO" || {
        MF_BROKEN_REASON="the record repository's artifact roots could not be resolved."
        return 2
    }
    MF_ROOTS="$CT_ROOTS_OK"
    MF_ABSENT="$CT_ROOTS_ABSENT"
    if [ -z "$MF_ROOTS" ]; then
        MF_BROKEN_REASON="the record declares artifact roots and none of them is on this machine ($CT_ARTIFACT_ROOTS); there is no tree to read."
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# mf_lock_dir
# ---------------------------------------------------------------------------
# OUTSIDE EVERY REPOSITORY, deliberately. Two sessions seated in two different
# repositories can both reach one record; a lock inside either seat would not
# be seen by the other. The ownership ledger set this precedent
# (~/.claude/state/), for the same reason.
mf_lock_dir() {
    local base="${MECHANICAL_FINDINGS_STATE_DIR:-$HOME/.claude/state/mechanical-findings}"
    local id
    id="$(printf '%s' "$MF_RECORD_FILE" | cksum | cut -d' ' -f1)"
    printf '%s/%s.lock' "$base" "$id"
}

# ---------------------------------------------------------------------------
# mf_sweep [write]
# ---------------------------------------------------------------------------
# Requires mf_resolve.
#   MF_VERDICT      CLEAN | FINDINGS | BROKEN
#   MF_N_SUBJECTS   MF_N_FINDINGS MF_N_NEW MF_N_KNOWN MF_N_GONE MF_N_CONTRA MF_N_WRITTEN
#   MF_NEW_KEYS     MF_GONE_IDS  MF_CONTRA_IDS  MF_WRITTEN_IDS   (space-separated)
#   MF_WRITTEN      "id<TAB>key" per line
#   MF_LINES        the full report, one line per record
#   MF_BROKEN_REASON when MF_VERDICT is BROKEN
mf_sweep() {
    local write="${1:-}" job out head lock
    MF_VERDICT="BROKEN"; MF_BROKEN_REASON=""
    MF_N_SUBJECTS=0; MF_N_FINDINGS=0; MF_N_NEW=0; MF_N_KNOWN=0
    MF_N_GONE=0; MF_N_CONTRA=0; MF_N_WRITTEN=0
    MF_NEW_KEYS=""; MF_GONE_IDS=""; MF_CONTRA_IDS=""; MF_WRITTEN_IDS=""
    MF_WRITTEN=""; MF_LINES=""

    lock="$(mf_lock_dir)"
    job="$(MF_RF="$MF_RECORD_FILE" MF_RL="$MF_RECORD_LABEL" \
           MF_SEC="$MF_SECTIONS" MF_ST="$MF_STATUS_TOKENS" MF_TT="$MF_TERMINAL_TOKENS" \
           MF_R="$MF_ROOTS" MF_A="$MF_ABSENT" MF_W="$write" MF_LOCK="$lock" \
           MF_HOOK="${MF_HOOK_NAME:-notice-mechanical-findings.sh}" \
           python3 -c '
import json, os, time
def pairs(s):
    d = {}
    for p in (s or "").split("\t"):
        if "=" in p:
            k, v = p.split("=", 1)
            d[k] = v
    return d
print(json.dumps({
    "record_label": os.environ["MF_RL"],
    "record_path": os.environ["MF_RF"],
    "row_sections": os.environ["MF_SEC"].split(),
    "status_tokens": os.environ["MF_ST"].split(),
    "terminal_tokens": os.environ["MF_TT"].split(),
    "roots": pairs(os.environ.get("MF_R")),
    "absent_roots": pairs(os.environ.get("MF_A")),
    "today": time.strftime("%Y-%m-%d"),
    "hook_name": os.environ["MF_HOOK"],
    "write": os.environ.get("MF_W") == "write",
    "lock_dir": os.environ["MF_LOCK"],
}))' 2>/dev/null)"
    if [ -z "$job" ]; then
        MF_BROKEN_REASON="the sweep job could not be assembled — python3 produced nothing."
        return 0
    fi

    out="$(printf '%s' "$job" | python3 "$_MF_PY" - 2>/dev/null)"
    if [ -z "$out" ]; then
        MF_BROKEN_REASON="the sweep produced no verdict at all. A silent checker and a clean tree are not the same answer and must never look the same."
        return 0
    fi

    head="$(printf '%s\n' "$out" | head -1)"
    MF_LINES="$(printf '%s\n' "$out" | tail -n +2)"
    case "$head" in
        BROKEN*)
            MF_VERDICT="BROKEN"
            MF_BROKEN_REASON="$(printf '%s' "$head" | cut -f2-)"
            return 0 ;;
        CLEAN*)
            MF_VERDICT="CLEAN"
            MF_N_SUBJECTS="$(printf '%s' "$head" | cut -f2)" ;;
        FINDINGS*)
            MF_VERDICT="FINDINGS"
            MF_N_FINDINGS="$(printf '%s' "$head" | cut -f2)"
            MF_N_NEW="$(printf '%s' "$head" | cut -f3)"
            MF_N_KNOWN="$(printf '%s' "$head" | cut -f4)"
            MF_N_GONE="$(printf '%s' "$head" | cut -f5)"
            MF_N_CONTRA="$(printf '%s' "$head" | cut -f6)"
            MF_N_WRITTEN="$(printf '%s' "$head" | cut -f7)" ;;
        *)
            MF_BROKEN_REASON="the sweep answered in a shape this caller does not recognize: ${head:0:120}"
            return 0 ;;
    esac
    MF_N_SUBJECTS="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="CLASS"{s+=$3} END{print s+0}')"
    MF_NEW_KEYS="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="F" && $2=="NEW"{printf "%s ", $3}' | sed 's/ $//')"
    MF_GONE_IDS="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="F" && $2=="GONE"{printf "%s ", $4}' | sed 's/ $//')"
    MF_CONTRA_IDS="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="F" && $2=="CLOSED-BUT-PRESENT"{printf "%s ", $4}' | sed 's/ $//')"
    MF_WRITTEN="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="WROTE"{printf "%s\t%s\n", $2, $3}')"
    MF_WRITTEN_IDS="$(printf '%s\n' "$MF_LINES" | awk -F'\t' '$1=="WROTE"{printf "%s ", $2}' | sed 's/ $//')"
    return 0
}

# ---------------------------------------------------------------------------
# mf_receipt <path>
# ---------------------------------------------------------------------------
# THE POSITIVE PROBE. Written on EVERY path, including the silent ones and the
# broken ones: silence plus a receipt saying three classes checked 214
# subjects is a fact; silence on its own is a hope. Best effort by design — a
# receipt that could not be written must never turn into a refusal.
mf_receipt() {
    local path="${1:-}" dir
    [ -n "$path" ] || return 0
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || return 0
    {
        echo "# mechanical-findings sweep receipt — the positive probe."
        echo "# Its presence proves the sweep RAN. Silence with a receipt is a"
        echo "# result; silence without one is a check that never happened."
        echo "when-utc:      $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
        echo "verdict:       ${MF_VERDICT:-UNKNOWN}"
        echo "record:        ${MF_RECORD_FILE:-<unresolved>} sections ${MF_SECTIONS:-?}"
        echo "roots:         $(printf '%s' "${MF_ROOTS:-<none>}" | tr '\t' ' ')"
        echo "absent-roots:  $(printf '%s' "${MF_ABSENT:-}" | tr '\t' ' ')"
        echo "subjects:      ${MF_N_SUBJECTS:-0}"
        echo "findings:      ${MF_N_FINDINGS:-0}  new ${MF_N_NEW:-0}  known ${MF_N_KNOWN:-0}  gone ${MF_N_GONE:-0}  closed-but-present ${MF_N_CONTRA:-0}"
        echo "written:       ${MF_N_WRITTEN:-0}  [${MF_WRITTEN_IDS:-}]"
        [ -n "${MF_BROKEN_REASON:-}" ] && echo "broken:        $MF_BROKEN_REASON"
        [ -n "${MF_STANDDOWN_REASON:-}" ] && echo "stood-down:    $MF_STANDDOWN_REASON"
        echo "--- report ---"
        printf '%s\n' "${MF_LINES:-}"
    } > "$path" 2>/dev/null || true
    return 0
}
