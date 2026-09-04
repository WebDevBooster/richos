#!/usr/bin/env bash
#
# mechanical-findings.mutation.sh — PROVES THE MECHANICAL-FINDINGS SUITE CAN
#                                   FAIL.
#
# 41 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. Thirteen instances of "green over code that never ran"
# were found in this codebase in the 24 hours before this file was written, and
# this suite's own first run had one: an exemption case passed its negative
# half and failed its positive half because the lint never printed the line
# the case was looking for. So: take the shipped source, remove ONE property at
# a time, and assert that
#   1. mechanical-findings.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives
#      a green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# NOT RUN BY ANY RUNNER, BY ITS OWN SWEEP'S DEFINITION — unless a suite names
# it on a code line. contract-integrity.test.sh is where the six other
# harnesses are invoked; the line for this one is reported to the lander
# rather than added here, because that file is held by another engineer today.
# Until it is added, this harness is itself an `unrun-harness` finding, which
# is the correct verdict and the loop will say so.
#
# Run directly: scripts/hooks/mechanical-findings.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t mechanical-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# build <dir> — a throwaway copy of exactly the files the suite needs.
build() {
    local dir="$1"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/notice-mechanical-findings.sh" \
       "$ENGINE_ROOT/scripts/hooks/mechanical-findings.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/mechanical-findings.sh" "$ENGINE_ROOT/scripts/lib/mechanical-findings.py" \
       "$ENGINE_ROOT/scripts/lib/unstarted-rows.sh" "$ENGINE_ROOT/scripts/lib/unstarted-rows.py" \
       "$ENGINE_ROOT/scripts/lib/row-currency.sh" "$ENGINE_ROOT/scripts/lib/row-currency.py" \
       "$ENGINE_ROOT/scripts/lib/ceo-todos.sh" "$ENGINE_ROOT/scripts/lib/ceo-todos.py" \
       "$ENGINE_ROOT/scripts/lib/declaration-path.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/scripts/mechanical-findings-lint.sh" \
       "$ENGINE_ROOT/scripts/unstarted-rows-lint.sh" \
       "$ENGINE_ROOT/scripts/row-currency-lint.sh" "$dir/scripts/"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/"*.sh
}

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    build "$dir"

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/mechanical-findings.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

echo "=== mechanical findings: every property, proven load-bearing by removing it ==="

# The control first: the unmutated suite must be GREEN in this sandbox, or
# every "red" below is a red that was already there.
build "$SANDBOX/control"
if bash "$SANDBOX/control/scripts/hooks/mechanical-findings.test.sh" >"$SANDBOX/control.txt" 2>&1; then
    printf '  PASS  control — the unmutated suite is green (%s)\n' "$(tail -1 "$SANDBOX/control.txt" | sed 's/^ *//')"
    PASS=$((PASS + 1))
else
    printf '  FAIL  control — the unmutated suite is already RED; nothing below means anything\n'
    grep '  FAIL' "$SANDBOX/control.txt" | sed 's/^/          /'
    echo ""
    echo "  0 mutant(s) killed, 1 survived or misfired"
    exit 1
fi

H="scripts/hooks/notice-mechanical-findings.sh"
L="scripts/lib/mechanical-findings.sh"
P="scripts/lib/mechanical-findings.py"
T="scripts/mechanical-findings-lint.sh"

# --- 1. FINDING --------------------------------------------------------------
mutant no-skip-window "1b " "$P" \
    '                if not any(SKIP_WORD_RE.search(w) for w in window):' \
    '                if True:' \
    "a suite named in a workflow is not a finding; a suite named AND skipped is. Without the window every run line is an exclusion — and a.test.sh (1c) is reported too."

mutant comment-is-a-runner "1e " "$P" \
    '        if is_comment(text) or IGNORE_RE.search(path):' \
    '        if IGNORE_RE.search(path):' \
    "a harness named only in a comment is run by nobody; counting the comment hides z.mutation.sh."

mutant self-reference-runs "1d " "$P" \
    '        callers = {p for p in named.get(base, set()) if p != h}' \
    '        callers = named.get(base, set())' \
    "a harness's own header names it in its Run-directly line; counting that as a caller hides every orphan."

mutant comment-is-a-test "1g " "$P" \
    '    for path, n, text in refs:\n        if is_comment(text):\n            continue\n        for needle in needles:\n            if needle in text:\n                named.add(needle)' \
    '    for path, n, text in refs:\n        for needle in needles:\n            if needle in text:\n                named.add(needle)' \
    "h3 is named only in a test's comment; a comment is not a test."

mutant census-lies "1i " "$P" \
    '    census["unrun-harness"] = len(harnesses)' \
    '    census["unrun-harness"] = 0' \
    "the positive probe: a class that reports zero subjects examined cannot be told from a class that never ran."

# --- 2. WRITING ------------------------------------------------------------
mutant no-warrant "2c " "$P" \
    '    return "**State:** `OPEN` — " + ", ".join(stamps), None' \
    '    return "**State:** `OPEN` — `%s/%s`@`-`" % (f["prefix"], f["subject"]), None' \
    "a row without a real object-id stamp is a row the landing guard refuses at the next land; the stamp must come from identity()."

mutant no-evidence-stamp "2c " "$P" \
    '    for rel in [f["subject"]] + list(f.get("evidence") or []):' \
    '    for rel in [f["subject"]]:' \
    "the workflow that carries the exclusion must be pinned too, or fixing the workflow leaves the row current."

mutant key-not-written "2b " "$P" \
    '            "`finding:%s` | %s |"' \
    '            "`found:%s` | %s |"' \
    "the key inside the row IS the identity; without it every run writes the row again."

mutant append-at-top "2e " "$P" \
    '    return last["line0"] + len(last["span"]) - 1' \
    '    return last["line0"] - 1' \
    "rows go at the END of the section's table, after the last row, not before it."

mutant writer-names-nobody "2g " "$P" \
    'not by a person: ' \
    '' \
    "a row must say a machine wrote it, or it reads like a judgment somebody made."

# --- 3. IDENTITY -------------------------------------------------------------
mutant no-dedup "3a " "$P" \
    '    return key in known' \
    '    return False' \
    "the same defect on the next run must be the same row; without the one predicate both dedup sites are off and the row is written again."

mutant known-reported-as-new "3b " "$P" \
    '        if has_row(known, k):\n            if known[k]["closed"]:' \
    '        if False:\n            if known[k]["closed"]:' \
    "a finding that already has a row must be reported KNOWN with its id, not NEW — the sweep-time lookup is what the report and the notice are built from."

# --- 5. GONE / CONTRADICTION --------------------------------------------------
mutant gone-is-silent "5a " "$P" \
    '        if k in produced or info["closed"]:\n            continue\n        gone.append((k, info["id"]))' \
    '        continue\n        gone.append((k, info["id"]))' \
    "a row describing a defect the tree no longer has is the staleness this record's contract exists to remove."

mutant closed-is-fine "5c " "$P" \
    '            if known[k]["closed"]:\n                rows_out.append(("CLOSED-BUT-PRESENT", k, known[k]["id"], f["headline"]))' \
    '            if False:\n                rows_out.append(("CLOSED-BUT-PRESENT", k, known[k]["id"], f["headline"]))' \
    "a row that says CLOSED over a finding the tree still has is two statements disagreeing; one of them must be named."

# --- 6. EXEMPTION ------------------------------------------------------------
mutant bare-marker-exempts "6b " "$P" \
    '        if len(why) >= EXEMPT_MIN_REASON:\n            return why' \
    '        return why or "(bare marker)"' \
    "a bare marker must exempt nothing; the reason is the declaration."

mutant short-reason-exempts "6c " "$P" \
    '        if len(why) >= EXEMPT_MIN_REASON:' \
    '        if len(why) >= 0:' \
    "'finding-exempt: no' is not a reason; a marker has to say WHY where a reviewer reads it."

mutant exemption-silent "6a " "$T" \
    '$1=="EXEMPT" {printf' \
    '$1=="NEVER" {printf' \
    "an exemption that is honored and not shown decays into a rumor — this is the defect the suite's own first run had."

# --- 7. THE HOOK -------------------------------------------------------------
mutant hook-does-not-write "7c " "$H" \
    'mf_sweep write' \
    'mf_sweep' \
    "the whole point: the hook writes the row; a hook that only reports leaves the retyping to a person."

mutant hook-silent-on-write "7a " "$H" \
    'stop_notice_abnormal "$STATE" "MECHANICAL SWEEP: ${PIECES} Detail: scripts/mechanical-findings-lint.sh"' \
    'stop_notice_normal ""' \
    "rows written into somebody else's working tree, uncommitted, must be announced."

mutant hook-blocks "7b " "$H" \
    'stop_notice_abnormal "$STATE" "MECHANICAL SWEEP: ${PIECES} Detail: scripts/mechanical-findings-lint.sh"\nexit 0' \
    'stop_notice_abnormal "$STATE" "MECHANICAL SWEEP: ${PIECES} Detail: scripts/mechanical-findings-lint.sh"\nexit 2' \
    "a Stop hook that refuses turns over a coverage fact is the hook that gets waived."

mutant hook-announces-every-turn "7i " "$H" \
    'stop_notice_abnormal "$STATE" "MECHANICAL SWEEP:' \
    'stop_notice_abnormal "$STATE:$RANDOM" "MECHANICAL SWEEP:' \
    "a line under every turn is a line the eye is trained to skip, and then muted."

mutant gone-does-not-speak "7g " "$H" \
    'if [ -n "${MF_GONE_IDS:-}" ]; then' \
    'if false; then' \
    "the finding disappearing is exactly the moment the row must be closed; the operator has to hear it."

mutant receipt-hides-known "7f " "$L" \
    'echo "findings:      ${MF_N_FINDINGS:-0}  new ${MF_N_NEW:-0}  known ${MF_N_KNOWN:-0}' \
    'echo "findings:      ${MF_N_FINDINGS:-0}  new ${MF_N_NEW:-0}  known 0' \
    "a silent turn's receipt must prove the silence came from a sweep that saw every finding."

mutant standdown-writes-no-receipt "7h " "$H" \
    '    MF_VERDICT="STOOD-DOWN"\n    mf_receipt "$RECEIPT"' \
    '    MF_VERDICT="STOOD-DOWN"' \
    "a stand-down with no receipt cannot be told from a hook that never ran."

# --- 8. BLIND IS LOUD ----------------------------------------------------------
mutant no-table-is-fine "8a " "$P" \
    '    if not any(it.get("governed") for it in items):' \
    '    if False:' \
    "a governed section that parses to zero rows is an unread record, not an empty one."

mutant broken-reads-clean "8b " "$H" \
    'MECHANICAL SWEEP SWEPT NOTHING: ${MF_BROKEN_REASON:-unknown}' \
    'MECHANICAL SWEEP: clear again: ${MF_BROKEN_REASON:-unknown}' \
    "a failure that reads like a clean sweep is the whole failure class, restated."

mutant lock-ignored "8e " "$P" \
    '        ok, why = take_lock(lock_dir)' \
    '        ok, why = True, ""' \
    "two sessions can reach one record; the second writer must refuse, not race."

echo ""
echo "  $PASS mutant(s) killed, $FAIL survived or misfired"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
