#!/usr/bin/env bash
#
# foreign-app-data.mutation.sh: PROVES guard-foreign-app-data.test.sh WOULD CATCH THE
# BASH RULE AGAINST OTHER APPS' DATA GOING WRONG. Each mutant removes ONE property from a
# throwaway copy of the engine and demands that the NAMED case go red. The loop is
# scripts/lib/mutation-harness.sh.
#
# Run directly: scripts/hooks/foreign-app-data.mutation.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the Bash rule against other apps' data" "scripts/hooks/guard-foreign-app-data.test.sh"

L="scripts/lib/foreign_app_data.py"
H="scripts/hooks/guard-foreign-app-data.sh"

# shellcheck disable=SC2016  # the $-words are literal source text for the harness
{
mutant prefilter-drops-walkers "P3 " "$H" \
    '    *Containers*|*find*|*du\ *|*grep*|*rg\ *|*ls\ *) ;;' \
    '    *Containers*) ;;' \
    "the hook would return before the check for every home-folder walk, the common habit."
mutant group-containers-missed "P2 " "$L" \
    '    + r"/Library/(Containers|Group Containers)(?=$|[/\s'"'"'\"`);|&])(?:/([^/\s'"'"'\"`);|&]*))?")' \
    '    + r"/Library/(Containers)(?=$|[/\s'"'"'\"`);|&])(?:/([^/\s'"'"'\"`);|&]*))?")' \
    "an app-group folder (Notes, Mail, Calendar) would be read without a word."
mutant own-container-refused "N4 " "$L" \
    'OWN_CONTAINER_PREFIXES = ("com.richos.", "group.com.richos.")' \
    'OWN_CONTAINER_PREFIXES = ()' \
    "the app's own container would be refused, the false positive the lead named."
mutant depth-ignored "N5 " "$L" \
    '            if budget is None or (depth is not None and depth <= budget):' \
    '            if budget is None:' \
    "every shallow find of the home folder would be refused, though it never opens a container."
mutant cd-not-tracked "P3 " "$L" \
    '        if cmd == "cd":' \
    '        if False:' \
    "the habitual 'cd ~ && find .' would escape the rule."
mutant mentions-are-reads "N6m" "$L" \
    'MENTION_ONLY = {"echo", "printf", "git", "gh", ":", "true", "false"}' \
    'MENTION_ONLY = set()' \
    "echo and commit messages that name a container would be refused though they read nothing."
mutant prose-is-a-path "N6 " "$L" \
    '                    if not code and m.start() > 0 and t[m.start() - 1] not in "=:":' \
    '                    if False:' \
    "a sentence in a quoted argument (--tried, --body) would be refused as if it were a path."
mutant heredoc-bodies-kept "N6 " "$L" \
    '        keep = bool(INTERPRETERS.search(line[:m.start()]))' \
    '        keep = True' \
    "a heredoc written to a file would be read as commands."
mutant exemption-not-logged "N7 " "$L" \
    '    marker = EXEMPT.search(command)' \
    '    marker = None' \
    "an exemption would pass in silence; the log is how a reviewer sees it was used."
mutant ls-recursion-missed "P3 " "$L" \
    '        rec = any(a == "--recursive" or (a.startswith("-") and not a.startswith("--") and "R" in a)' \
    '        rec = any(a == "--recursive"' \
    "ls -R ~ would walk every app's container."
mutant rg-roots-ignored "P3 " "$L" \
    '        return pos[1:] or ["."]' \
    '        return ["."]' \
    "rg PATTERN ~ would be read as a search of the working directory."
}

mutation_end
