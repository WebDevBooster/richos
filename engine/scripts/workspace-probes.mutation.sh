#!/usr/bin/env bash
#
# workspace-probes.mutation.sh — PROVES THE GATE'S OWN SUITE CAN FAIL.
#
# This runner is the thing every other check of workspaces.py depends on, and
# every known route past the gate was reproduced with matched controls before
# it was closed. Every one of them made the run print "every discovered probe
# ran, and every one of them is green" and exit 0 — which is to say each of
# them turned a red probe into SILENCE, and silence is what a broken check also
# produces. So the cases that close them are not worth their green ticks until
# each has been watched go red for its own reason.
#
# A NOTE ON THE CASE IDS. Several of them are prefixes of another (`W15` of
# `W15a`, `W16` of `W16b`, `W14` of `W14b`, `W28` of `W28b`), and
# mutation-harness.sh greps `FAIL  <id>` as a RAW string. Those wants therefore
# carry a TRAILING SPACE, which is what separates `W15 a probe...` from `W15a
# POSITIVE CONTROL`. The alternative — renaming the cases — would break the ids
# a reviewer's certification already cites.
#
# Run directly: scripts/workspace-probes.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the probe runner's gate" "scripts/workspace-probes.test.sh"

P="scripts/workspace-probes.py"

# --- 1. A TYPED NAME IS NOT AUTHORITY -------------------------------------
# Route 2 as both reviewers reproduced it: the party failing the probe types the
# reviewer's name, and the name check passes because a name is a string.
mutant typed-name-is-authority "W12" "$P" \
    '            okr, witness = attributable(root, "HEAD", RETIREMENTS, raw, mine)' \
    '            okr, witness = True, "a name was typed"' \
    "anybody could retire anybody's probe by spelling the author's name, which is the whole of what the check used to be."

# --- 2. AN UNCOMMITTED RETIREMENT IS NOT A RETIREMENT (A1) ----------------
mutant uncommitted-retires "W11" "$P" \
    '    if not commit:' \
    '    if False:' \
    "a line written into the working tree and never committed would retire a probe, so the gate could be opened without leaving a record of who opened it."

# --- 3. THE COMMIT THAT BREAKS IT MAY NOT RETIRE IT (A2) -----------------
mutant bundling-allowed "W13" "$P" \
    '    if docs_only and outside:' \
    '    if False and outside:' \
    "one commit could rewrite the library and retire the probe that the rewrite is failing -- the exact shortcut an engineer under pressure reaches for."

# --- 4. THE WITNESS IS THE RECORDED BRANCH, NOT ANY BRANCH (A3) ----------
# Route 2 again, and route (c) of certification-frank-gate-integrity: a branch
# cut at the engineer's tip contained every engineer commit, so the old A3
# refused nothing in a whole round.
mutant witness-is-any-commit "W28b" "$P" \
    '    if not is_ancestor(root, commit, tip):' \
    '    if False:' \
    "a retirement would be accepted without having landed on the recorded integration branch -- the ordinary review handoff (a branch cut at the engineer's tip) would then witness the engineer's own retirement, with no forgery at all."

# --- 5. NO RECORD MEANS REFUSE, NEVER MAIN --------------------------------
mutant no-record-assumes-a-branch "W29" "$P" \
    '    if why_not:{NL}        return False, ("A3: no branch is recorded as the one this repository'"'"'s work "' \
    '    if False:{NL}        return False, ("A3: no branch is recorded as the one this repository'"'"'s work "' \
    "with nothing recorded the runner would go on to compare against an empty tip instead of refusing and naming the recording command -- a second answer to point 14's one question."

# --- 6. A DECLARATION IS CHECKED, NEVER READ -----------------------------
# Route 1, which needed no name at all: one comment line on somebody else's probe
# removed it from discovery.
mutant marker-taken-on-trust "W14 " "$P" \
    '            okd, whyd = marker_authority(root, pr, mine)' \
    '            okd, whyd = True, "read, not checked"' \
    "a not-a-probe declaration added to a red probe would delete it from the run with no check on who added it, and the run would then report every discovered probe green."

# --- 7. DISCOVERY IS THE MANIFEST (route 3) ------------------------------
mutant manifest-not-read "W15 " "$P" \
    '    for rel in entries:{NL}        if not rel.endswith(".py") or not exists_at(root, "HEAD", rel):{NL}            continue{NL}        p = materialize(root, "HEAD", rel, stage, "HEAD")' \
    '    for rel in []:{NL}        if not rel.endswith(".py") or not exists_at(root, "HEAD", rel):{NL}            continue{NL}        p = materialize(root, "HEAD", rel, stage, "HEAD")' \
    "a probe the text rule cannot see (getattr, no file name) would be invisible again -- and an invisible probe does not exist, where a red one stops a commit."

# --- 8. AN UNLISTED PROBE BLOCKS -----------------------------------------
mutant unlisted-probe-does-not-block "W26" "$P" \
    '        if red or stuck or gone or unlisted:' \
    '        if red or stuck or gone:' \
    "a committed probe left off the manifest would be named and then waved through with the all-clear printed under it."

# --- 9. DELETION IS NOT ATTRIBUTABLE TO ANYBODY (route 4) ----------------
mutant deletion-is-free "W16 " "$P" \
    '        for q, c in deleted_probes(root, mine):' \
    '        for q, c in []:' \
    "removing the file would be enough: the only thing that changes is a count, and nothing was checking the count."

# --- 10. MISSING IS ASKED OF GIT, NOT OF THE TREE --------------------------
# Route 4 re-opened on 2026-09-12: a file at the deleted path in the working
# tree, committed or not, un-deleted the probe.
# Three parts since round 7: the manifest-history scan (10b) is a third detector
# of a deleted probe, and a mutant that blinds two of three would be caught by
# the third and read as proven for the wrong reason.
mutant missing-reads-the-tree "W16c" "$P" \
    '            if exists_at(root, "HEAD", line):{NL}                continue{AND}        if rel.endswith(".py") and not exists_at(root, "HEAD", rel) and all(q != rel for q, _c in gone):{AND}                if rel.endswith(".py") and not exists_at(root, "HEAD", rel) and all(q != rel for q, _c in gone):' \
    '            if os.path.exists(os.path.join(root, line)):{NL}                continue{AND}        if rel.endswith(".py") and not os.path.exists(os.path.join(root, rel)) and all(q != rel for q, _c in gone):{AND}                if rel.endswith(".py") and not os.path.exists(os.path.join(root, rel)) and all(q != rel for q, _c in gone):' \
    "an uncommitted file at the deleted path would conceal a committed deletion."

# --- 10b. THE MANIFEST IS READ AT EVERY COMMIT THAT TOUCHED IT ---------------
# RN2d (certification-frank-round6-2026-09-12.md §4): a text-invisible probe
# deleted together with its manifest line in ONE commit left no trace, because
# the manifest was read at HEAD only.
mutant manifest-history-not-read "W30 " "$P" \
    '        for c in out.split():                       # newest first{NL}            for rel in manifest_at(root, c)[0]:' \
    '        for c in []:                                # newest first{NL}            for rel in manifest_at(root, c)[0]:' \
    "a probe deleted in the same commit as its manifest line would leave no trace: the deletion scan judges the file's text and the HEAD manifest no longer names it, so both are satisfied and the run prints its all-clear."

# --- 10c. DELISTING IS NOT DELETION, AND IT IS NOT FREE EITHER ---------------
# Round 8, item 1: a RED probe hollowed into a non-probe stub and delisted in one
# docs-only commit left no trace, because MISSING meant "the path is absent".
mutant delisting-is-free "W31 " "$P" \
    '                elif rel.endswith(".py") and rel not in head_entries and all(q != rel for q, _c in gone):' \
    '                elif False:' \
    "a red probe could be gutted into a stub and dropped from the manifest in one commit: DELETED 0, NOT LISTED 0, the probe gone from the report, exit 0."

# --- 11. AN UNCOMMITTED LINE EXCUSES NO DELETION ---------------------------
mutant uncommitted-line-excuses-deletion "W16d" "$P" \
    '    ok, detail = attributable(root, "HEAD", RETIREMENTS, raw, mine){NL}    return ok, detail' \
    '    return True, "a line was found"' \
    "a retirement line nobody committed, or nobody landed, would excuse a deletion -- the deletion had to be committed and the concealment did not."

# --- 12. THE WRONG NAME EXCUSES NO DELETION --------------------------------
mutant wrong-name-excuses-deletion "W16e" "$P" \
    '    if who.lower() != author:{NL}        return False, ("its retirement is signed' \
    '    if False:{NL}        return False, ("its retirement is signed' \
    "a landed retirement signed by anyone would excuse the deletion of anyone's probe."

# --- 13. AN INVENTORY THAT NAMES NOTHING IS THE COUNT AGAIN ---------------
mutant show-all-names-nothing "W17" "$P" \
    '                if rel in probe_paths:' \
    '                if rel not in probe_paths:' \
    "the one command offered for looking at what the runner classified would name only the probes, which are the files already in the table above it."

# --- 14. RETIREMENT IS PER CASE ---------------------------------------------
mutant per-case-is-per-file "W19" "$P" \
    '        if rec and rec["cases"]:' \
    '        if False:' \
    "a per-case retirement would be silently ignored and the probe would stay red, which is the state that made a reviewer decline to rule at all."

# --- 15. THE RETIRED CASE IS NOT ASKED -------------------------------------
mutant retired-case-still-asked "W19" "$P" \
    '            argv_cases = list(probe.live_cases) if probe.retired_cases else []' \
    '            argv_cases = []' \
    "the probe would be run over every case including the retired one, so a correct per-case ruling would still leave the run red -- coverage kept and the ruling wasted."

# --- 16. A CASE THAT MATCHES NOTHING IS REFUSED ---------------------------
mutant unknown-case-ignored "W21" "$P" \
    '                    if case not in p.cases:' \
    '                    if False:' \
    "a retirement naming a case the probe does not have -- a typo, or a line copied from another probe -- would silently retire nothing while looking like a ruling."

mutation_end
