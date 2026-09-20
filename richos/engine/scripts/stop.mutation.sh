#!/usr/bin/env bash
#
# stop.mutation.sh — PROVES stop.test.sh WOULD CATCH THE COMMAND GOING WRONG.
#
# A green suite is evidence of nothing until somebody has watched it go red for
# the right reason, and this command is one whose suite could very easily be
# green over nothing: most of its cases assert that something was NOT written
# (no ack for the control, nothing under --dry-run, no everything mode), and an
# absence is also what a predicate that never runs produces.
#
# Each mutant removes ONE property from a throwaway copy of the engine and
# demands that the NAMED case go red. The loop is scripts/lib/mutation-harness.sh.
#
# WHAT IS NOT MUTATED HERE, AND WHY IT IS SAID RATHER THAN LEFT TO BE NOTICED:
#
#   S12 (the registry is not mutated) has NO mutant. The natural one — swap the
#   read-only lookup for the registry's own `_resolve`, which observes and
#   saves — does not write in this fixture: `observe_platform_end` reads the
#   platform's per-agent record, the suite redirects HOME to an empty directory,
#   so there is no record to observe and the function returns untouched. A
#   mutant that cannot fail is worse than no mutant: it scores PROVEN and means
#   nothing. S12 carries its own positive probe inside the suite instead — it
#   writes a record and demands its own fingerprint notice.
#
#   S5, S6, S9, S10 and S13 have no mutant either. Each of them is a different
#   view of machinery that M1..M7 already mutate (the refusal path, the ack
#   write, the measurement, the per-name loop); a mutant per case would cost a
#   whole suite run each for the same evidence. That is a stated cost decision,
#   not an oversight.
#
# Run directly: scripts/stop.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "stop.sh — the CEO's stop, on names only" "scripts/stop.test.sh"

L="scripts/lib/stop.py"

# --- 1. A NAME THAT IS NOT RUNNING IS SKIPPED, NOT ACKED -------------------
# Acking a finished teammate is paperwork, and a habit of paperwork is how the
# three guards of 2026-09-05 died: broad enough that waiving became routine.
mutant acks-the-finished-too "S3" "$L" \
    '        if verdict == NOT_ALIVE:' \
    '        if False:' \
    "an ack would be written for a teammate that is not running, which the guard already allows silently -- paperwork for nothing, on the one tool where the ack is meant to mean something."

# --- 2. HIS WORDS ARE IN THE ACK, VERBATIM ---------------------------------
# The ack's --why is the whole difference between a stop he ordered and a stop
# somebody inferred. A summary of his words is an inference.
mutant ack-drops-his-words "S2W" "$L" \
    '            % ceo_word.strip())' \
    '            % "the CEO objected to the spend")' \
    "the ack would carry a paraphrase instead of his sentence, and the record of why an agent was destroyed would be somebody's summary of him."

# --- 3. WHAT IS DESTROYED IS MEASURED, NOT DESCRIBED -----------------------
# On 2026-09-20 the three branches held zero commits and nothing was lost. The
# only reason anyone knows that is that somebody ran `git log`.
mutant destroying-is-a-phrase "S2D" "$L" \
    '    text = "%s: %s" % (name, " | ".join(parts))' \
    '    text = "%s: whatever it has not committed is lost" % name' \
    "the ack would describe the loss instead of measuring it, and 'zero commits, nothing lost' would read exactly like 'a session of uncommitted work'."

# --- 4. THE ACK GOES WHERE THE GUARD READS IT ------------------------------
# An ack in the wrong root is a file that exists and protects nothing.
mutant ack-written-to-the-wrong-root "S8" "$L" \
    '             "--why", why, "--entity", entity],' \
    '             "--why", why],' \
    "the ack would land under whatever directory the command was run from, the guard would not find it, and the stop would be refused exactly as it was on 2026-09-20."

# --- 5. ONE TARGET, BOTH ITS SPELLINGS -------------------------------------
# find_live_ack matches task_id by exact string; 7 of 116 real TaskStop calls
# on this machine carry the raw agent id.
mutant only-the-name-spelling "S11" "$L" \
    '            if row["agent_id"] and row["agent_id"] != name:{NL}                targets.append(row["agent_id"])' \
    '            pass' \
    "a TaskStop made with the agent id rather than the name would find no ack and be refused, on the 6% of real calls that use that form."

# --- 6. AN EVERYTHING MODE IS A DESIGN FAILURE, NOT A FEATURE --------------
# "WHEN THE FUCK DID I SAY THAT 'EVERYTHING RUNNING' NEEDS TO STOP???"
mutant an-everything-flag-appears "S7" "$L" \
    '    ap.add_argument("--dry-run", action="store_true")' \
    '    ap.add_argument("--dry-run", action="store_true"){NL}    ap.add_argument("--all", action="store_true")' \
    "a flag that stops everything could be added and nothing would notice -- which is the 05:15Z failure with a command line in front of it."

# --- 7. IT REACHES THE NAMED TEAMMATES AND NO OTHER ------------------------
# The widening does not need a flag to happen. This is the same defect by the
# other route: the loop quietly reading the roster instead of his words.
mutant widens-to-every-registered-agent "S1" "$L" \
    '    for i, name in enumerate(a.names, 1):' \
    '    for i, name in enumerate([r.get("name") for r in cache] or a.names, 1):' \
    "every registered teammate would be acked and stopped on a sentence that named two of them, and the control teammate sitting untouched in the fixture is the only thing that says so."

mutation_end
