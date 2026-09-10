#!/usr/bin/env bash
#
# scripts/lib/mutation-pool.sh — RUN INDEPENDENT MUTANTS AT THE SAME TIME,
# AND REPORT THEM IN THE ORDER THEY WERE DECLARED.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# A mutation harness runs a guard's entire behavioral suite once per mutant, so
# it costs N times that suite. Measured 2026-09-04: 19 such cases were 2347.7s,
# 70.0% of contract-integrity.test.sh, at TWELVE harnesses. There are now 40 of
# them declaring 526 mutants. The suite's cost tracks the number of MUTANTS.
#
# Every one of those mutants is independent by construction — it builds its own
# throwaway copy of the engine, edits one file in the copy, and runs a suite
# against the copy. Nothing is shared and nothing is ordered. They ran one at a
# time anyway, on a ten-core machine, because a `for` loop is what a harness was
# first written as.
#
# THE BINDING CONSTRAINT IS NOT TOTAL WALL CLOCK. IT IS THE PER-CHECK CEILING.
# An agent's Bash call is capped at 600 seconds. A real `--only IL,SA` call in
# the record hit that cap, and 239 polling calls hit it — the polling loops
# exist BECAUSE of it. So a section that cannot finish inside the cap does not
# merely take longer; it converts into a background run plus a poll loop plus a
# model turn per re-issue. Section sharding cannot split these: the six mutation
# sections are each a SINGLE case. Concurrency inside the harness is the only
# thing that lowers the largest indivisible unit.
#
# ===========================================================================
# WHAT MUST NOT CHANGE, AND IS THE REASON THIS IS A POOL AND NOT A `&`
# ===========================================================================
# 1. THE ORDER OF THE OUTPUT. A harness's report is read by humans and grepped
#    by contract-integrity.test.sh (`grep -E '^  FAIL'`). Completion order under
#    concurrency is a function of machine load, so a run whose lines arrive in
#    finishing order is a run that cannot be diffed against another run. Every
#    worker writes to its own file and the drain prints them in SUBMISSION
#    order, so the report is byte-identical to the serial one but for durations.
#
# 2. THE EXIT STATUS AND THE NAMED CASES. contract-integrity.test.sh reads only
#    the harness's exit code for its verdict (`emit_case "WTI1..." 0 "$rc"`) and
#    greps the log for diagnosis. The tally therefore comes from the workers'
#    exit codes, and a worker that left NO exit code counts as a FAILURE, never
#    as absent. A killed worker that silently vanished from the tally would be
#    this engine's founding defect rebuilt inside the fix: a green fraction over
#    an inventory that never ran.
#
# 3. NO NESTED EXPLOSION. Each mutant runs a whole suite; if that suite also
#    used a pool, the process count would be JOBS squared. `RICHOS_MUTATION_INNER`
#    is already set for the inner run, and this file treats it as a hard
#    serializer: inside a mutant, the pool degree is 1. The bound is JOBS, always.
#
# ===========================================================================
# WHY IT POLLS A MARKER FILE INSTEAD OF USING `wait -n`
# ===========================================================================
# `wait -n` — return when the NEXT job finishes — is exactly the primitive a
# bounded pool wants, and it does not exist here:
#
#   /bin/bash 3.2.57 on darwin 24.6.0:  `help wait` has no -n
#
# That is the operator's default shell and Apple will not ship newer (bash 4+
# is GPLv3). CI's `ubuntu-latest` has bash 5 and would be fine, so this is the
# usual trap: the primitive works everywhere the author tested and nowhere the
# operator runs.
#
# The rejected alternatives, said rather than implied:
#   - `kill -0 $pid` liveness polling. A finished-but-unreaped child answers
#     `kill -0` differently depending on when the shell got round to reaping it,
#     so the running count is racy in a way that shows up as an occasional
#     over-subscription rather than an error.
#   - Fixed batches of N with a `wait` between them. Simple and wrong for this
#     workload: a batch costs its SLOWEST member, and WTI's mutants are not
#     uniform, so nine cores idle while one 600-second mutant finishes.
#
# So each worker's LAST action is to create `<seq>.done`, after its output, its
# duration and its exit code are all on disk. A marker's existence therefore
# means "this slot is complete and safe to read", which is the drain's
# precondition.
#
# THE THROTTLE NEEDS ONE MORE FACT THAN THE MARKER, and finding out why cost a
# deadlock. Counting markers alone makes a SIGKILLed worker occupy its slot for
# ever, because a killed worker never writes one — see _mut_pool_occupied. The
# throttle therefore asks "no marker AND the process is still alive", which is
# the only formulation that is correct for both a worker that finishes and a
# worker that is killed.
#
# Usage, from a harness:
#
#   . "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
#   mut_pool_init                       # degree from RICHOS_MUTANT_JOBS or cores
#   mut_pool_submit "<label>" <fn> [args...]     # fn returns 0=PASS, non-0=FAIL
#   ...
#   mut_pool_drain                      # waits, prints in order, sets the tally
#   # -> MUT_POOL_PASS, MUT_POOL_FAIL, MUT_POOL_N, MUT_POOL_SLOWEST
#
# The submitted function must print its own report and must not depend on any
# variable it sets being visible afterwards: it runs in a subshell. Anything it
# needs to say comes back as stdout or as an exit code.

MUT_POOL_DIR=""
MUT_POOL_N=0
MUT_POOL_JOBS=1
MUT_POOL_PASS=0
MUT_POOL_FAIL=0
MUT_POOL_SLOWEST=""
MUT_POOL_TOTAL_MS=0

# mut_pool_jobs_default — the degree, derived rather than typed.
#
# Chosen from the measurement in docs/measurements/mutant-concurrency-2026-09-10/
# rather than from taste: a mutant is a shell suite, so it is dominated by
# process spawning, git and python3 rather than by arithmetic, and it neither
# saturates one core nor scales past the core count. The cap is what stops a
# 64-core CI runner from starting 64 sandbox builds at once and going
# IO-bound — the sandbox is a recursive copy of the whole mechanical layer, and
# `clonefile` copy-on-write is NOT available under /tmp on the Linux runner
# (the run log says so in plain text), so on CI every sandbox is a full copy.
mut_pool_jobs_default() {
    local n=""
    if [ -n "${RICHOS_MUTANT_JOBS:-}" ]; then
        case "$RICHOS_MUTANT_JOBS" in
            ''|*[!0-9]*) n="" ;;
            *) [ "$RICHOS_MUTANT_JOBS" -ge 1 ] && n="$RICHOS_MUTANT_JOBS" ;;
        esac
        if [ -n "$n" ]; then printf '%s' "$n"; return 0; fi
        echo "WARNING: RICHOS_MUTANT_JOBS='$RICHOS_MUTANT_JOBS' is not a positive integer — deriving instead" >&2
    fi
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n="" ;; esac
    [ -z "$n" ] && n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n="" ;; esac
    [ -z "$n" ] && n=2
    [ "$n" -lt 1 ] && n=2
    [ "$n" -gt 8 ] && n=8
    printf '%s' "$n"
}

# mut_pool_init [<jobs>] — make the slot directory and fix the degree.
mut_pool_init() {
    MUT_POOL_DIR="$(cd "$(mktemp -d -t mutation-pool.XXXXXX)" && pwd -P)" || {
        echo "FATAL: mut_pool_init: could not create a pool directory" >&2; exit 2; }
    MUT_POOL_N=0
    MUT_POOL_PASS=0
    MUT_POOL_FAIL=0
    MUT_POOL_SLOWEST=""
    MUT_POOL_TOTAL_MS=0
    if [ -n "${1:-}" ]; then
        MUT_POOL_JOBS="$1"
    else
        MUT_POOL_JOBS="$(mut_pool_jobs_default)"
    fi
    # THE HARD SERIALIZER. Inside a mutant, the degree is 1 — see property 3 in
    # the header. Without this the process count is the product of the nesting
    # levels rather than the pool's bound.
    if [ "${RICHOS_MUTATION_INNER:-0}" = "1" ]; then
        MUT_POOL_JOBS=1
    fi
    # The clock. sw_init is idempotent, so sourcing order between this file and
    # stopwatch.sh does not matter, but the library must BE there: a pool that
    # silently reported every mutant as taking `?` would remove the only number
    # this whole change is judged on.
    if ! command -v sw_init >/dev/null 2>&1; then
        echo "FATAL: mut_pool_init: scripts/lib/stopwatch.sh must be sourced before mutation-pool.sh" >&2
        exit 2
    fi
    sw_init
    return 0
}

# _mut_pool_occupied — how many slots are STILL RUNNING.
#
# THE OBVIOUS VERSION OF THIS FUNCTION DEADLOCKS, and it was a mutation of this
# very file that proved it rather than a review. The first version counted
# `*.done` markers and called the rest occupied. A worker killed by SIGKILL
# never writes its marker, so it stayed "occupied" for ever: at degree 1 the
# next submit blocked immediately and permanently, and at degree 8 the pool lost
# one slot per killed worker and deadlocked on the eighth. The `silently-serial`
# mutant hung the suite instead of failing it — the shape of bug that, in a
# harness invoked from contract-integrity.test.sh, is a run that never returns
# and no output saying why.
#
# So a slot is occupied when it has NO completion marker AND its process is
# still alive. The reap behavior this leans on is measured, not assumed:
#
#   /bin/bash 3.2.57, a SIGKILLed background child, no blocking `wait`:
#   within 50ms `kill -0` answers GONE and `jobs -pr` is empty.
#
# A slot with no marker and no PID FILE YET counts as occupied: `.pid` is
# written by the parent immediately after `&`, so the window is microseconds,
# but treating it as free would over-subscribe the pool by one.
_mut_pool_occupied() {
    local i seq n=0 pid
    i=1
    while [ "$i" -le "$MUT_POOL_N" ]; do
        seq="$(printf '%04d' "$i")"
        if [ ! -e "$MUT_POOL_DIR/$seq.done" ]; then
            if [ ! -e "$MUT_POOL_DIR/$seq.pid" ]; then
                n=$(( n + 1 ))
            else
                pid="$(cat "$MUT_POOL_DIR/$seq.pid" 2>/dev/null)"
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    n=$(( n + 1 ))
                fi
            fi
        fi
        i=$(( i + 1 ))
    done
    printf '%s' "$n"
}

# mut_pool_submit <label> <fn> [args...]
mut_pool_submit() {
    local label="$1"
    shift
    [ -n "$MUT_POOL_DIR" ] || { echo "FATAL: mut_pool_submit before mut_pool_init" >&2; exit 2; }
    # Block until a slot frees. The sleep is 0.05s: short enough that a freed
    # core is not left idle for a human-visible time, long enough that the
    # throttle is not itself a spinning core.
    while [ "$(_mut_pool_occupied)" -ge "$MUT_POOL_JOBS" ]; do
        sleep 0.05
    done
    MUT_POOL_N=$(( MUT_POOL_N + 1 ))
    local seq
    seq="$(printf '%04d' "$MUT_POOL_N")"
    printf '%s' "$label" >"$MUT_POOL_DIR/$seq.label"
    (
        _t0="$(sw_now_ms)"
        "$@" >"$MUT_POOL_DIR/$seq.out" 2>&1
        _rc=$?
        printf '%s' "$(( $(sw_now_ms) - _t0 ))" >"$MUT_POOL_DIR/$seq.ms"
        printf '%s' "$_rc" >"$MUT_POOL_DIR/$seq.rc"
        # LAST, and deliberately so: the marker means the three files above are
        # complete on disk. The throttle and the drain then share one fact.
        : >"$MUT_POOL_DIR/$seq.done"
    ) &
    # The worker's PID, recorded by the PARENT because a bash 3.2 subshell
    # cannot portably learn its own: `$$` inside `( )` is the SCRIPT's pid, not
    # the subshell's, and `$BASHPID` is bash 4+. That is not a footnote — the
    # first version of mutation-pool.test.sh had a worker `kill -9 $$` itself to
    # simulate a killed mutant, and it killed the TEST SUITE instead (rc=137).
    # Written for two consumers: a stuck run can be attributed to a process, and
    # the kill-proofing evidence needs a real signal delivered to a real worker.
    printf '%s' "$!" >"$MUT_POOL_DIR/$seq.pid"
    return 0
}

# mut_pool_drain — wait for every worker, print the slots in SUBMISSION order,
# and set the tally. Also sets MUT_POOL_SLOWEST to "<ms> <label>" of the worst
# slot, which is the number that decides whether a section fits under the tool
# ceiling.
mut_pool_drain() {
    [ -n "$MUT_POOL_DIR" ] || { echo "FATAL: mut_pool_drain before mut_pool_init" >&2; exit 2; }
    wait
    MUT_POOL_PASS=0
    MUT_POOL_FAIL=0
    MUT_POOL_TOTAL_MS=0
    local i seq rc ms label worst_ms=-1 worst_label=""
    i=1
    while [ "$i" -le "$MUT_POOL_N" ]; do
        seq="$(printf '%04d' "$i")"
        label="$(cat "$MUT_POOL_DIR/$seq.label" 2>/dev/null || printf 'slot-%s' "$seq")"
        if [ -f "$MUT_POOL_DIR/$seq.done" ] && [ -f "$MUT_POOL_DIR/$seq.rc" ]; then
            rc="$(cat "$MUT_POOL_DIR/$seq.rc" 2>/dev/null)"
            ms="$(cat "$MUT_POOL_DIR/$seq.ms" 2>/dev/null)"
        else
            # NO RESULT IS A FAILURE, NAMED. A worker killed by a signal, an OOM
            # or a full disk leaves no exit code; counting it as absent would
            # shrink the denominator and print a green tally over a mutant that
            # never ran.
            rc=""
            ms=""
        fi
        case "$ms" in ''|*[!0-9]*) ms="" ;; esac
        if [ -n "$ms" ]; then
            MUT_POOL_TOTAL_MS=$(( MUT_POOL_TOTAL_MS + ms ))
            if [ "$ms" -gt "$worst_ms" ]; then worst_ms="$ms"; worst_label="$label"; fi
        fi
        if [ -f "$MUT_POOL_DIR/$seq.out" ]; then
            # The body's own report, verbatim, so every existing grep over
            # `^  PASS` / `^  FAIL  <name>` keeps matching byte for byte.
            cat "$MUT_POOL_DIR/$seq.out"
        fi
        if [ -z "$rc" ]; then
            printf '  FAIL  %s — NO RESULT: the worker left no exit code (killed, OOM, or out of disk).\n' "$label"
            printf '          This is counted as a failure. A mutant that did not run has proven nothing,\n'
            printf '          and a tally that omitted it would be green over an inventory that never ran.\n'
            MUT_POOL_FAIL=$(( MUT_POOL_FAIL + 1 ))
        elif [ "$rc" -eq 0 ]; then
            MUT_POOL_PASS=$(( MUT_POOL_PASS + 1 ))
        else
            MUT_POOL_FAIL=$(( MUT_POOL_FAIL + 1 ))
        fi
        i=$(( i + 1 ))
    done
    if [ "$worst_ms" -ge 0 ]; then
        MUT_POOL_SLOWEST="$worst_ms $worst_label"
    fi
    return 0
}

# mut_pool_report_line — one line naming the degree, the wall clock and the
# slowest mutant. PRINTED BY EVERY HARNESS, because the slowest single mutant is
# the number that decides whether the section fits under the 600s tool ceiling,
# and nobody should have to hand-time a harness to learn it again.
mut_pool_report_line() { # <wall-ms>
    local wall="${1:-}" slow_ms slow_label
    slow_ms="${MUT_POOL_SLOWEST%% *}"
    slow_label="${MUT_POOL_SLOWEST#* }"
    printf '  [%s mutant(s), %s at a time, wall %s' \
        "$MUT_POOL_N" "$MUT_POOL_JOBS" "$(sw_fmt "$wall")"
    if [ -n "$MUT_POOL_SLOWEST" ]; then
        printf ', slowest %s %s' "$(sw_fmt "$slow_ms")" "$slow_label"
    fi
    # Summed mutant time over wall clock is the speedup actually obtained, which
    # is not the degree: it is bounded by the slowest mutant and by whatever the
    # machine was already doing.
    if [ -n "$wall" ] && [ "$wall" -gt 0 ] && [ "$MUT_POOL_TOTAL_MS" -gt 0 ]; then
        printf ', %s.%sx serial' \
            "$(( MUT_POOL_TOTAL_MS / wall ))" "$(( (MUT_POOL_TOTAL_MS * 10 / wall) % 10 ))"
    fi
    printf ']\n'
}

mut_pool_cleanup() {
    [ -n "$MUT_POOL_DIR" ] && rm -rf "$MUT_POOL_DIR"
    MUT_POOL_DIR=""
    return 0
}
