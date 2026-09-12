#!/usr/bin/env bash
#
# workspace-probes.mutation.sh — PROVES THE GATE'S OWN SUITE CAN FAIL.
#
# This runner is the thing every other check of workspaces.py depends on, and its
# four known routes past the gate were all reproduced with matched controls
# before they were closed. Every one of them made the run print "every discovered
# probe ran, and every one of them is green" and exit 0 — which is to say each of
# them turned a red probe into SILENCE, and silence is what a broken check also
# produces. So the cases that close them are not worth their green ticks until
# each has been watched go red for its own reason.
#
# A NOTE ON THE CASE IDS. Several of them are prefixes of another (`W15` of
# `W15a`, `W16` of `W16b`, `W14` of `W14b`), and mutation-harness.sh greps
# `FAIL  <id>` as a RAW string. Those wants therefore carry a TRAILING SPACE,
# which is what separates `W15 a probe...` from `W15a POSITIVE CONTROL`. The
# alternative — renaming the cases — would break the ids a reviewer's
# certification already cites.
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

# --- 4. A DECLARATION IS CHECKED, NEVER READ -----------------------------
# Route 1, which needed no name at all: one comment line on somebody else's probe
# removed it from discovery.
mutant marker-taken-on-trust "W14 " "$P" \
    '            okd, whyd = marker_authority(root, pr, mine)' \
    '            okd, whyd = True, "read, not checked"' \
    "a not-a-probe declaration added to a red probe would delete it from the run with no check on who added it, and the run would then report every discovered probe green."

# --- 5. UNDISCOVERED IS WORSE THAN RED (route 3) -------------------------
mutant discovery-needs-the-filename "W15 " "$P" \
    '    return loads and drives_entry' \
    '    return False' \
    "a probe handed the library as an argument, which never writes the file name, would be invisible -- and an invisible probe does not exist, where a red one stops a commit."

# --- 6. DELETION IS NOT ATTRIBUTABLE TO ANYBODY (route 4) ----------------
mutant deletion-is-free "W16 " "$P" \
    '        missing = [(q, c) for q, c in deleted_probes(root, mine)' \
    '        missing = [] or [(q, c) for q, c in ()' \
    "removing the file would be enough: the only thing that changes is a count, and nothing was checking the count."

# --- 7. AN INVENTORY THAT NAMES NOTHING IS THE COUNT AGAIN ---------------
# --show-all was offered as the answer to routes 2 and 3 and named 0 of the 242
# files it counted, because its filter kept only the probes and then dropped them.
mutant show-all-names-nothing "W17" "$P" \
    '                    if rel in probe_paths:' \
    '                    if rel not in probe_paths:' \
    "the one command offered for looking at what the runner classified would name only the probes, which are the files already in the table above it."

# --- 8. RETIREMENT IS PER CASE ---------------------------------------------
# Keyed on the FILE, a reviewer with three obsolete cases and one live one had
# only two moves: drop five green assertions, or write nothing. He wrote nothing.
mutant per-case-is-per-file "W19" "$P" \
    '        if rec and rec["cases"]:' \
    '        if False:' \
    "a per-case retirement would be silently ignored and the probe would stay red, which is the state that made a reviewer decline to rule at all."

# --- 9. THE RETIRED CASE IS NOT ASKED -------------------------------------
mutant retired-case-still-asked "W19" "$P" \
    '            argv_cases = list(probe.live_cases) if probe.retired_cases else []' \
    '            argv_cases = []' \
    "the probe would be run over every case including the retired one, so a correct per-case ruling would still leave the run red -- coverage kept and the ruling wasted."

# --- 10. A CASE THAT MATCHES NOTHING IS REFUSED ---------------------------
mutant unknown-case-ignored "W21" "$P" \
    '                    if case not in p.cases:' \
    '                    if False:' \
    "a retirement naming a case the probe does not have -- a typo, or a line copied from another probe -- would silently retire nothing while looking like a ruling."

mutation_end
