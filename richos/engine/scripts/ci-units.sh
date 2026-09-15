#!/usr/bin/env bash
#
# ci-units.sh — the inventory of CI verification UNITS, and the shard plan.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# `scripts/run-all-tests.sh` runs every discovered suite one after another. On
# GitHub's own hardware that is 123.5 minutes (run 34396549904, 2026-09-09,
# ubuntu-latest, 121 suites), and a person waiting two hours for a verdict
# stops waiting — which is how a verification gate ends up switched off, which
# is exactly what happened to this engine's own workflow on 2026-09-01.
#
# The runner is not the problem and is not changed. What is added is a second
# READING of the same inventory: the same suites, cut into UNITS that can run
# on separate machines at the same time. Sharding is only ever a scheduling
# decision; it must never be able to change WHAT is verified. So:
#
#   THE INVENTORY IS DISCOVERED FROM DISK BY THE SAME RULE run-all-tests.sh
#   USES — find every *.test.sh under the engine, LC_ALL=C sorted. Never a
#   typed list. `ci-units.test.sh` asserts, by execution, that this file's
#   suite set is byte-identical to `run-all-tests.sh --list`, so the two
#   readings cannot drift.
#
# ===========================================================================
# WHAT A UNIT IS, AND WHY ONE SUITE IS NOT ONE UNIT
# ===========================================================================
# Sharding buys nothing past the cost of the largest INDIVISIBLE unit. Measured
# on the runner (same run):
#
#   scripts/hooks/contract-integrity.test.sh        2335.9 s   (39 min)
#   scripts/reconcile-terminal-worktrees.test.sh     939.7 s   (16 min)
#   everything else, 119 suites                     4133.4 s
#
# With one unit per suite the floor is 39 minutes however many machines are
# used. contract-integrity.test.sh, alone among the suites, already takes
# `--only <section>` and carries 24 sections, so it contributes 24 units rather
# than one. That moves the floor to reconcile-terminal-worktrees at 16 minutes,
# and 16 minutes is a verdict somebody will wait for.
#
# A SCOPED SECTION IS GREEN AT EXIT 3, NOT 0 — that suite's own deliberate
# design, so no gate can read a partial run as a full one. This file records
# the expected code per unit as DATA (the `rc` column) rather than leaving
# every consumer to remember it, and `ci-shard.sh` treats exit 0 from a scoped
# section as a FAILURE: it would mean the scoping silently did not apply.
#
# ===========================================================================
# THE WEIGHTS ARE MEASURED, DATED, AND ALLOWED TO BE WRONG
# ===========================================================================
# Packing needs a cost per unit. Those live in `lib/ci-unit-weights.tsv`, one
# measurement per line, each carrying the run it came from. A unit with no
# recorded weight gets DEFAULT_WEIGHT and is packed as if it were average —
# never dropped, never assumed free. Re-measure by reading the durations out of
# a real run's receipts (`ci-shard.sh --receipt`) and updating that file; the
# plan changes, nothing else does.
#
# Usage:
#   ci-units.sh units            every unit: id, kind, expected rc, weight
#   ci-units.sh suites           just the discovered suite paths (for diffing
#                                against run-all-tests.sh --list)
#   ci-units.sh count            how many units
#   ci-units.sh shards [N]       "<shard-index><TAB><unit-id>" for every unit
#   ci-units.sh plan [N]         human-readable per-shard totals
#   ci-units.sh matrix [N]       the GitHub Actions matrix, as JSON
#   ci-units.sh shard-count      the declared default shard count
#   ci-units.sh cmd <unit-id>    the exact argv that runs one unit
#
#   --units-file <path>          restrict the inventory to the unit ids in
#                                <path>, one per line. Applies to units, count,
#                                shards, plan and matrix, so a diff-scoped set
#                                is packed by exactly the same planner as the
#                                whole. An id in the file that is not a unit is
#                                FATAL: a restriction that silently dropped one
#                                would plan over less than it was asked for.
#
# Exit codes:
#   0  fine
#   2  discovery found nothing, or the engine root is unreadable, or bad usage
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WEIGHTS="$ENGINE_ROOT/scripts/lib/ci-unit-weights.tsv"

# The suite that carries sections. Named once; every other suite is one unit.
SECTIONED_SUITE="scripts/hooks/contract-integrity.test.sh"

# ---------------------------------------------------------------------------
# THE DEFAULT SHARD COUNT — declared here, read by the workflow, never typed
# into the YAML. Twelve, and the arithmetic rather than a preference:
#
#   the whole pass, measured on the runner                7409 s
#   / 12                                                   617 s
#   the largest INDIVISIBLE unit                           940-1500 s
#
# So twelve shards already sit BELOW the floor the largest unit sets: adding
# shards cannot improve the wall clock, and fewer than eight would make the
# packing, rather than that unit, the limit.
#
# WHICH unit sets the floor is not settled and is deliberately not asserted
# here. `reconcile-terminal-worktrees.test.sh` is 940 s measured on the runner;
# the sectioned suite's WTI section is 599 s on a quiet Mac and 1500 s on a
# loaded one, and has never been measured on Linux at all because until
# 2026-09-10 that suite ran as ONE unit. The first sharded run answers it, and
# `lib/ci-unit-weights.tsv` is where the answer goes.
#
# WHY NOT MORE, given the runners are free: GitHub Free allows 20 concurrent
# jobs ACCOUNT-WIDE, shared with six other active workflows in this
# repository, and per GitHub's documentation an exceeded limit DROPS runs
# rather than queueing them — a dropped run leaves no record at all, which is
# the failure `ci-run-record-check.sh` exists to catch. Twelve shards plus the
# steps, plan and coverage jobs is fifteen, and the matrix declares
# max-parallel so this workflow can never be the thing that starves another.
# ---------------------------------------------------------------------------
DEFAULT_SHARDS=12

# A unit nobody has measured yet. 60 s is deliberately not 0: an unmeasured
# unit must cost the packer something, or a batch of new suites all land in one
# shard and that shard becomes the wall clock.
DEFAULT_WEIGHT=60

[ -d "$ENGINE_ROOT" ] || { echo "ERROR: ci-units.sh: engine root unreadable: $ENGINE_ROOT" >&2; exit 2; }

# --- discovery -------------------------------------------------------------
# IDENTICAL RULE TO run-all-tests.sh, deliberately duplicated rather than
# refactored into it: that runner is the thing this must be checked AGAINST,
# and a shared helper would make the two agree by construction instead of by
# test. ci-units.test.sh compares them by execution.
_discover_suites() {
    find "$ENGINE_ROOT" -type f -name '*.test.sh' 2>/dev/null | LC_ALL=C sort \
        | while IFS= read -r t; do printf '%s\n' "${t#"$ENGINE_ROOT"/}"; done
}

# Section ids of the sectioned suite, read from its own markers — the same
# source its --list uses, so a section added there becomes a unit here with no
# edit.
_discover_sections() {
    local s="$ENGINE_ROOT/$SECTIONED_SUITE"
    [ -f "$s" ] || return 0
    awk '/^if _section [A-Za-z0-9_.-]+; then$/ { id=$3; sub(/;$/, "", id); print id }' "$s"
}

# ---------------------------------------------------------------------------
# RESTRICTING THE INVENTORY — added 2026-09-10, because the first real push
# proved it necessary rather than nice.
#
# The `affected` gate was one job running whatever the diff selected. That is
# fine for a guard-plus-suite diff, and this work's OWN first push selected 54
# units costing ~100 minutes serial — a change to `contract-integrity-probe.sh`
# is named in the sectioned suite's preamble, so it selects all 24 sections, and
# it pulls in `reconcile-terminal-worktrees.test.sh` at 940 s besides. The job
# would have been killed at its 60-minute timeout, and a required check that
# dies on a large diff is a required check people learn to ignore.
#
# So the packer takes a RESTRICTION: a file of unit ids, and it plans over
# exactly those. Nothing else changes — same discovery, same weights, same
# longest-first packing, same determinism — so the affected gate and the full
# pass are the same mechanism at two scopes rather than two mechanisms that
# have to be kept in step.
#
# AN ID IN THE FILE THAT IS NOT A UNIT IS FATAL. A restriction that silently
# dropped an unrecognized id would plan over less than it was asked for and
# exit 0, which is the failure this whole file exists to refuse.
# ---------------------------------------------------------------------------
RESTRICT_FILE=""

_apply_restriction() {
    if [ -z "$RESTRICT_FILE" ]; then cat; return 0; fi
    [ -f "$RESTRICT_FILE" ] || { echo "ERROR: ci-units.sh: --units-file: no such file: $RESTRICT_FILE" >&2; exit 2; }
    awk -F'\t' -v want="$RESTRICT_FILE" '
        BEGIN {
            n = 0
            while ((getline line < want) > 0) {
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == "" || substr(line, 1, 1) == "#") continue
                keep[line] = 1
                n++
            }
            if (n == 0) {
                print "ERROR: ci-units.sh: --units-file " want " names no unit. Refusing to plan over nothing." > "/dev/stderr"
                exit 2
            }
        }
        $1 in keep { seen[$1] = 1; print; next }
        END {
            missing = 0
            for (k in keep) if (!(k in seen)) {
                print "ERROR: ci-units.sh: --units-file names " k ", which is not a unit in this inventory." > "/dev/stderr"
                missing++
            }
            if (missing > 0) exit 2
        }
    '
}

_weight_of() { # <unit-id>
    local id="$1" w=""
    if [ -f "$WEIGHTS" ]; then
        w="$(awk -F'\t' -v want="$id" '$1 == want { print $2; exit }' "$WEIGHTS")"
    fi
    case "$w" in
        ''|*[!0-9.]*) printf '%s\n' "$DEFAULT_WEIGHT" ;;
        *) printf '%s\n' "$w" ;;
    esac
}

# --- the inventory ---------------------------------------------------------
# One line per unit: id <TAB> kind <TAB> expected-rc <TAB> weight
# id is the engine-relative suite path, with ":<section>" appended for a
# scoped section unit. Sortable, greppable, and it names the file it runs.
emit_units() {
    local rel sec found=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        found=1
        if [ "$rel" = "$SECTIONED_SUITE" ]; then
            local nsec=0
            while IFS= read -r sec; do
                [ -n "$sec" ] || continue
                nsec=$((nsec + 1))
                printf '%s:%s\tsection\t3\t%s\n' "$rel" "$sec" "$(_weight_of "$rel:$sec")"
            done < <(_discover_sections)
            if [ "$nsec" -eq 0 ]; then
                # Not a degradation to a whole-suite unit: a sectioned suite
                # whose markers cannot be read is a broken parser, and packing
                # it as one 39-minute unit would hide that behind a slow but
                # green run.
                echo "ERROR: ci-units.sh: $SECTIONED_SUITE exists but NO section markers could be read from it." >&2
                echo "       Refusing to silently fall back to one whole-suite unit: that would hide a broken" >&2
                echo "       section parser behind a run that is merely slow. Fix the markers or retire the" >&2
                echo "       SECTIONED_SUITE declaration in this file." >&2
                exit 2
            fi
        else
            printf '%s\tsuite\t0\t%s\n' "$rel" "$(_weight_of "$rel")"
        fi
    done < <(_discover_suites)
    if [ "$found" -eq 0 ]; then
        echo "ERROR: ci-units.sh: found NO *.test.sh suites under $ENGINE_ROOT." >&2
        echo "       That is not an empty pass, it is broken discovery. Refusing to emit an inventory" >&2
        echo "       of nothing — a shard plan over zero units is green forever." >&2
        exit 2
    fi
}

# --- packing ---------------------------------------------------------------
# Longest-processing-time-first: heaviest unit into the lightest shard. It is
# the classic 4/3-approximation and, more usefully here, it is DETERMINISTIC —
# ties break on the unit id — so the same tree always produces the same plan
# and two runs of this workflow can be compared line by line.
emit_shards() { # <n>
    local n="$1"
    emit_units | _apply_restriction | python3 -c '
import sys
n = int(sys.argv[1])
units = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    uid, kind, rc, w = line.split("\t")
    units.append((float(w), uid))
if not units:
    sys.stderr.write("ERROR: ci-units.sh: no units to pack\n")
    sys.exit(2)
if n < 1:
    sys.stderr.write("ERROR: ci-units.sh: shard count must be >= 1\n")
    sys.exit(2)
# Heaviest first; the id makes the order total so the plan is reproducible.
units.sort(key=lambda t: (-t[0], t[1]))
load = [0.0] * n
out = [[] for _ in range(n)]
for w, uid in units:
    i = min(range(n), key=lambda k: (load[k], k))
    load[i] += w
    out[i].append(uid)
for i in range(n):
    for uid in out[i]:
        print("%d\t%s" % (i + 1, uid))
' "$n"
}

emit_plan() { # <n>
    local n="$1"
    emit_units | _apply_restriction | python3 -c '
import sys
n = int(sys.argv[1])
w = {}
units = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    uid, kind, rc, weight = line.split("\t")
    w[uid] = float(weight)
    units.append((float(weight), uid))
units.sort(key=lambda t: (-t[0], t[1]))
load = [0.0] * n
out = [[] for _ in range(n)]
for weight, uid in units:
    i = min(range(n), key=lambda k: (load[k], k))
    load[i] += weight
    out[i].append(uid)
total = sum(load)
for i in range(n):
    print("shard %2d  %6.0f s  %3d unit(s)" % (i + 1, load[i], len(out[i])))
    for uid in sorted(out[i]):
        print("             %6.0f s  %s" % (w[uid], uid))
print("")
print("%d unit(s), %.0f s serial, %d shard(s), longest shard %.0f s (%.1f min)"
      % (len(units), total, n, max(load), max(load) / 60.0))
print("the serial pass is %.1fx the longest shard" % (total / max(load) if max(load) else 0))
' "$n"
}

# THE MATRIX IS DERIVED FROM THE PLAN, NOT FROM THE SHARD COUNT.
#
# Two reasons, and the second is the one that would have bitten. A matrix built
# from the count alone (1..n) declares a job for every index whether or not the
# packer gave it any units, so asking for more shards than there are units
# produces jobs that select nothing — and a shard that verifies nothing must
# never exit 0, so those jobs would fail the run for being asked for. Reading
# the plan means the matrix contains exactly the shards that have work.
#
# It also consumes its input. The previous shape piped the plan into a program
# that never read stdin, which was harmless except that it printed
# BrokenPipeError into the log of a passing run — noise in a green log is how
# people learn to skim logs.
emit_matrix() { # <n>
    local n="$1"
    emit_shards "$n" | python3 -c '
import json, sys
n = int(sys.argv[1])
present = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    idx = int(line.split("\t")[0])
    if idx not in present:
        present.append(idx)
present.sort()
if not present:
    sys.stderr.write("ERROR: ci-units.sh: the plan assigned no shards; refusing to emit an empty matrix\n")
    sys.exit(2)
print(json.dumps([{"shard": i, "shards": n} for i in present], separators=(",", ":")))
' "$n"
}

# --- the argv for one unit -------------------------------------------------
emit_cmd() { # <unit-id>
    local id="$1" suite sec
    case "$id" in
        *:*) suite="${id%%:*}"; sec="${id##*:}" ;;
        *)   suite="$id"; sec="" ;;
    esac
    [ -f "$ENGINE_ROOT/$suite" ] || { echo "ERROR: ci-units.sh: no such suite: $suite" >&2; exit 2; }
    # `bash <path>` and never `<path>` directly: several suites in this tree
    # are committed mode 644 (terminalize-agent-worktrees.test.sh among them),
    # so executing them by path exits 126. run-all-tests.sh invokes them the
    # same way, which is why nobody had noticed.
    if [ -n "$sec" ]; then
        printf 'bash\t%s\t--only\t%s\n' "$ENGINE_ROOT/$suite" "$sec"
    else
        printf 'bash\t%s\n' "$ENGINE_ROOT/$suite"
    fi
}

CMD="${1:-units}"
[ "$#" -gt 0 ] && shift

# --units-file <path> may follow any subcommand; it restricts the inventory the
# planner plans over. Pulled out of the positional arguments so `shards 12
# --units-file f` and `shards --units-file f 12` both read naturally.
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --units-file) [ "$#" -ge 2 ] || { echo "ERROR: ci-units.sh: --units-file needs a path" >&2; exit 2; }
                      RESTRICT_FILE="$2"; shift 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

case "$CMD" in
    units)  emit_units | _apply_restriction ;;
    suites) _discover_suites ;;
    count)  emit_units | _apply_restriction | grep -c . ;;
    shards) emit_shards "${1:-$DEFAULT_SHARDS}" ;;
    plan)   emit_plan "${1:-$DEFAULT_SHARDS}" ;;
    matrix) emit_matrix "${1:-$DEFAULT_SHARDS}" ;;
    shard-count) printf '%s\n' "$DEFAULT_SHARDS" ;;
    cmd)    [ "$#" -ge 1 ] || { echo "ERROR: ci-units.sh cmd needs a unit id" >&2; exit 2; }
            emit_cmd "$1" ;;
    -h|--help|help)
            sed -n '/^# Usage:/,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)      echo "ERROR: ci-units.sh: unknown subcommand '$CMD' (try --help)" >&2; exit 2 ;;
esac
