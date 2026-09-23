#!/usr/bin/env bash
#
# scripts/lib/mutation-harness.sh — THE SHARED SHAPE OF A MUTATION HARNESS.
#
# A green suite is evidence of nothing until somebody has watched it go red for
# the right reason. A mutation harness takes the SHIPPED source, removes ONE
# property at a time in a throwaway copy of the engine, and asserts that
#   1. the suite FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied — a replacement that matched nothing is a
#      green run that looks like a green run, which is the trap again.
#
# Seven harnesses in this engine each carried their own copy of that loop, and
# eight were run by nothing (open-items 3.22-3.29). This file is the one loop,
# and every harness that sources it is INVOKED FROM THE SUITE IT MUTATES, so the
# runner that discovers *.test.sh runs the harness too. A harness nobody runs
# proves nothing about anything.
#
# Usage, from a harness:
#
#   . "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"
#   mutation_begin "<title>" "<suite path relative to the engine root>"
#   mutant <name> <expected-failing-case-id> <rel-file> <old> <new> <why>
#   ...
#   mutation_end            # exits 0 only if every property was proven load-bearing
#
# <old> and <new> are literal source text; write `{NL}` for a newline. The
# suite's `ok`/`bad` lines must both carry the case id (e.g. "T27  ...") so the
# harness can tell "red for this reason" from "red somewhere else".
#
# The sandbox is a copy of scripts/, hooks/, orchestration.config and
# .claude/settings.local.json — the whole mechanical layer, so a mutated file's
# siblings are the real ones. Nothing here touches the real tree.
#
# ===========================================================================
# WHY THE SANDBOX IS THE MECHANISM, AND NOT AN `EXIT` TRAP
# ===========================================================================
# Two harnesses in this engine used to mutate the SHIPPED guard in place and
# put it back with `trap 'restore' EXIT`. On 2026-09-05 one of them was
# observed mid-run with `guard-worktree-isolation.sh` sitting in a working
# engineer's tree with its clause-6 comparison flipped from `-gt` to `-lt` —
# the model-tier gate refusing upgrades and waving downgrades through. It was
# restored correctly, because the run finished.
#
# AN `EXIT` TRAP IS A PROMISE CONDITIONAL ON EXITING. It does not survive
# `kill -9`, an OOM kill, a power loss, or a terminal that goes away. A run
# that dies mid-mutation leaves the operator's live enforcement inverted,
# silently, with nothing to say so — and `~/.claude/richos-engine` is a
# symlink to the main checkout, so "the operator's live enforcement" is not a
# figure of speech. Worse, both harnesses are invoked by
# contract-integrity.test.sh, so the window was open on every CI verify and
# every full engine self-test, not only when somebody ran a harness by hand.
#
# A COPY HAS NO WINDOW. There is no state a signal can interrupt into: the
# shipped file is never opened for writing at all, so the set of kills that
# damage it is empty rather than small.
#
# THE OBJECTION THOSE TWO HARNESSES CARRIED, ANSWERED RATHER THAN IGNORED.
# Their headers said a sandbox was refused on purpose: on 2026-09-02 a harness
# killed 11 of 18 mutants because its sandboxes lacked a dependency, so the
# guard REFUSED TO START and that read exactly like a guard catching the
# mutation. That is a real trap and it is the reason this loop is shaped the
# way it is. It is answered three times over, and none of the three is an
# assurance:
#   1. _mut_copy_engine copies the WHOLE mechanical layer — scripts/, hooks/,
#      orchestration.config, .claude/ — so a mutated file's siblings are the
#      real ones. The 2026-09-02 sandbox copied a file, not a layer.
#   2. Those harnesses' own `alive` arm runs a control payload through the
#      MUTATED guard and demands exit 0, which is precisely the check that
#      distinguishes "caught the mutation" from "could not start". It is kept.
#   3. Each of them now runs its suite ONCE against the UNMUTATED sandbox
#      before any mutant, and refuses to proceed unless that is green. A
#      deficient sandbox is then a loud failure at case zero instead of 21
#      mutants that all score PROVEN for the wrong reason.
# And the empirical answer was already sitting in the same directory:
# worktree-spawn-intent.mutation.sh mutates guard-worktree-isolation.sh in a
# sandbox built by this file and runs that guard's whole suite against it,
# green, on every CI run.
#
# ===========================================================================
# THE MUTANTS RUN CONCURRENTLY — 2026-09-10
# ===========================================================================
# A mutation harness runs a guard's whole behavioral suite once per mutant, so
# it costs N times that suite, and 19 such cases were measured at 70% of
# contract-integrity.test.sh back when there were TWELVE harnesses. There are
# now 40, declaring 526 mutants.
#
# THE SANDBOX SHAPE ABOVE IS WHAT MAKES THIS FREE. `mutant` already gave every
# mutant its OWN directory under $MUT_SANDBOX, built from the shipped tree,
# which is never opened for writing. Two mutants have therefore never shared a
# path, never shared a file, and never had an order between them. The loop was
# serial for one reason: a `for` loop is what a harness was first written as.
# So the change here is a scheduler, not a redesign of the isolation — the
# isolation was always the thing that made this correct, and it is untouched.
#
# WHAT DOES NOT CHANGE, because a harness's report is read by people and grepped
# by contract-integrity.test.sh:
#   - the ORDER of the output is declaration order, never completion order;
#   - the PASS/FAIL strings are byte-identical, with the duration appended at
#     end of line;
#   - the exit code is 0 only when every property was proven, as before;
#   - a mutant that is KILLED counts as a failure rather than vanishing from
#     the tally.
# The mechanism and the two defects found while building it: mutation-pool.sh.
#
# WHY THE BOUND IS NOT "ALL OF THEM AT ONCE": each mutant builds a sandbox and
# then runs a whole suite of processes, so the ceiling is the machine, and an
# unbounded fan-out of 37 mutants turns a ten-core laptop into a swap storm.
# RICHOS_MUTANT_JOBS overrides the derived degree.

# ===========================================================================
# THE TWO REFUSALS ADDED 2026-09-18, AND THE 105 GB THAT BOUGHT THEM
# ===========================================================================
# On 2026-09-17 at 22:39 root-contract.mutation.sh — which kept its own copy of
# this loop and copied the WHOLE engine root with `cp -R "$SRC_ENGINE" "$M"` —
# was killed at exit 144. By the next morning its sandbox held 105.3 GB:
#
#     mutant-1  13.0 GB
#     mutant-2  26.2 GB
#     mutant-3  52.8 GB
#     mutant-4  13.2 GB
#
# 13.0 -> 26.2 -> 52.8 IS THE ARITHMETIC SIGNATURE OF A SELF-COPY. Each mutant
# came out twice the size of the one before, which is what happens when the
# copy SOURCE contains the sandbox: mutant-2 copies the engine plus mutant-1,
# mutant-3 copies the engine plus both, and four mutants of a tree that should
# be tens of megabytes become a tenth of a terabyte.
#
# THE EXACT PATH ARITHMETIC THAT PUT THE SANDBOX INSIDE THE SOURCE WAS NOT
# REPRODUCED, and that is stated rather than papered over. The deletion log
# showed a $TMPDIR-shaped path nested inside mutant-3, so something built a
# destination out of an absolute $TMPDIR — but nothing in the tree does that
# today and the incident is not reproducible from the current source.
#
# SO THE REFUSALS BELOW DO NOT DEPEND ON KNOWING WHICH CONCATENATION IT WAS.
# They close the whole class from the destination's side, where the invariant is
# checkable without a theory: a copy whose source contains its destination, or
# whose source is itself scratch, is refused; and a scratch root that has
# already grown past a declared ceiling stops the next mutant from starting.
# A guard that needed the post-mortem to be complete would be a guard that
# could not be written.

MUT_PASS=0
MUT_FAIL=0
MUT_FOCUS=""
MUT_SANDBOX=""
MUT_SUITE=""
MUT_ENGINE_ROOT=""
MUT_WALL_T0=0
# Set by mutation_sandbox_engine, for harnesses that keep their own loop.
MUT_SANDBOX_DIR=""
MUT_SANDBOX_ENGINE=""

_mut_engine_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$here/../.." && pwd
}

# mut_refuse_recursive_copy <dest> <src> — non-zero, loudly, if this copy is the
# 105 GB shape. Called before every engine copy in this file and in every
# harness that keeps its own loop.
#
# THREE REFUSALS, and each one is a separate way for the same disaster to arrive:
#
#   1. THE DESTINATION IS INSIDE THE SOURCE. This is the exponential case
#      directly: every subsequent mutant copies its predecessors. It is checked
#      on RESOLVED paths, because $TMPDIR on macOS is /var/folders/... reached
#      through a symlink from /private/var/folders/..., and a containment test
#      on unresolved paths is a test two spellings walk straight through.
#   2. THE SOURCE IS ITSELF UNDER $TMPDIR. A mutation harness mutates the
#      SHIPPED engine. A source that is already scratch means something is
#      mutating a mutant — the nested-harness case — and nesting is what turns
#      a bounded cost into an unbounded one.
#   3. THE SOURCE IS THE SCRATCH ROOT, or inside it. Same as 2 but true even
#      when $TMPDIR has been reassigned, which several suites in this engine do.
mut_refuse_recursive_copy() { # <dest> <src>
    local dest="$1" src="$2"
    local rsrc rdest tmp root
    # THE DESTINATION USUALLY DOES NOT EXIST YET, so the DEEPEST EXISTING
    # ANCESTOR is resolved and the remaining components appended.
    #
    # The first version resolved only the immediate parent, and its own test
    # caught the hole: given a destination two levels down (`$SRC/inner/dest`
    # where `inner` does not exist either), `cd "$(dirname ...)"` failed, the
    # function took the unresolvable-path branch, and the copy was refused FOR
    # THE WRONG REASON. It looked like a pass — the call was refused, which is
    # what the case asserted — while the containment check had never run at all.
    # A guard that refuses by accident is a guard that stops refusing the day the
    # accident goes away.
    rsrc="$( cd "$src" 2>/dev/null && pwd -P )" || rsrc=""
    if [ -z "$rsrc" ]; then
        echo "mutation-harness: REFUSING A COPY whose SOURCE cannot be resolved" >&2
        echo "  (src='$src'). An unresolvable path defeats every containment" >&2
        echo "  check below, so it is refused rather than guessed at." >&2
        return 1
    fi
    rdest="$(_mut_resolve_future "$dest")"
    if [ -z "$rdest" ]; then
        echo "mutation-harness: REFUSING A COPY whose DESTINATION cannot be" >&2
        echo "  resolved (dest='$dest') — no existing ancestor to resolve from." >&2
        return 1
    fi

    case "$rdest" in
        "$rsrc"/*)
            {
                echo "mutation-harness: REFUSING A RECURSIVE COPY."
                echo "  source:      $rsrc"
                echo "  destination: $rdest"
                echo "  The destination is INSIDE the source, so this copy would"
                echo "  include the sandbox it is building. That is the shape that"
                echo "  produced 13.0 -> 26.2 -> 52.8 GB across three mutants on"
                echo "  2026-09-17 and left 105.3 GB behind."
            } >&2
            return 1 ;;
    esac

    tmp="$( cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P )" || tmp=""
    if [ -n "$tmp" ]; then
        case "$rsrc" in
            "$tmp"|"$tmp"/*)
                {
                    echo "mutation-harness: REFUSING TO COPY A SOURCE THAT IS SCRATCH."
                    echo "  source: $rsrc"
                    echo "  It is under \$TMPDIR ($tmp). A mutation harness mutates"
                    echo "  the SHIPPED engine; a source that is already a sandbox"
                    echo "  means a mutant is running mutants, and nesting is what"
                    echo "  turns a bounded cost into an unbounded one."
                } >&2
                return 1 ;;
        esac
    fi

    root="$(_mut_scratch_root)"
    if [ -n "$root" ]; then
        case "$rsrc" in
            "$root"|"$root"/*)
                echo "mutation-harness: REFUSING to copy a source inside the" >&2
                echo "  scratch root ($root): $rsrc" >&2
                return 1 ;;
        esac
    fi
    return 0
}

# _mut_resolve_future <path> — the absolute, symlink-resolved form of a path that
# does not exist yet.
#
# Walks up to the deepest ancestor that DOES exist, resolves that with
# `cd`+`pwd -P`, and re-appends the components that were trimmed. Symlinks are
# therefore resolved for the real part of the path and taken literally for the
# part that is not there — which is the only answer available, and the right one
# for a containment test: a component that does not exist cannot be a symlink to
# somewhere else.
_mut_resolve_future() { # <path>
    local p="${1:-}" tail="" base real
    [ -n "$p" ] || return 0
    case "$p" in
        /*) : ;;
        *)  p="$PWD/$p" ;;
    esac
    while [ "$p" != "/" ] && [ -n "$p" ] && [ ! -d "$p" ]; do
        base="$(basename "$p")"
        tail="${tail:+$base/$tail}"
        tail="${tail:-$base}"
        p="$(dirname "$p")"
    done
    real="$( cd "$p" 2>/dev/null && pwd -P )" || return 0
    [ -n "$real" ] || return 0
    if [ -n "$tail" ]; then
        printf '%s/%s\n' "${real%/}" "$tail"
    else
        printf '%s\n' "$real"
    fi
}

_mut_scratch_root() {
    local base="${TMPDIR:-/tmp}"
    base="$( cd "$base" 2>/dev/null && pwd -P )" || return 0
    printf '%s/richos-scratch\n' "$base"
}

# mut_refuse_oversize_root — non-zero if the scratch root ALREADY holds more
# than the declared ceiling.
#
# THE CEILING IS ON THE ROOT AND NOT ON THE MUTANT, which is the opposite of the
# obvious design and is the only version that would have helped. A per-mutant
# check asks "is this copy too big" and the answer on 2026-09-17 was no, four
# times: 13 GB, then 26, then 52, each one a plausible copy of whatever it was
# handed. The thing that was insane was the TOTAL. So the question asked here is
# "has this machine already accumulated more scratch than any legitimate run
# needs", and a harness refuses to ADD to a root that is already past it.
#
# `du -sk` with a one-level depth is cheap here because the root only ever holds
# allocator directories; it is not the 87,330-entry $TMPDIR itself.
mut_refuse_oversize_root() {
    local root ceiling_gb used_kb used_gb
    root="$(_mut_scratch_root)"
    [ -n "$root" ] && [ -d "$root" ] || return 0
    ceiling_gb="${RICHOS_SCRATCH_ROOT_CEILING_GB:-10}"
    used_kb="$(du -sk "$root" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$used_kb" ] || return 0
    used_gb=$(( used_kb / 1048576 ))
    if [ "$used_gb" -ge "$ceiling_gb" ]; then
        {
            echo "mutation-harness: REFUSING TO START A MUTANT."
            echo "  scratch root: $root"
            echo "  it already holds ${used_gb} GB, and the declared ceiling is ${ceiling_gb} GB."
            echo ""
            echo "  This is a CEILING ON THE ROOT, not on one copy, and that is"
            echo "  deliberate: on 2026-09-17 no single mutant was implausible"
            echo "  (13 GB, 26 GB, 52 GB) and the TOTAL was 105.3 GB. Asking"
            echo "  'is this copy too big' answered no, four times."
            echo ""
            echo "  Reclaim it and run again:"
            echo "      scripts/scratch-sweep.sh --apply"
            echo "  Nothing a live process owns is deleted by that."
        } >&2
        return 1
    fi
    return 0
}

mutation_begin() { # <title> <suite-rel-path>
    MUT_ENGINE_ROOT="$(_mut_engine_root)"
    MUT_SUITE="$2"
    # ALLOCATED, NOT NAMED. `mktemp -d -t mutation.XXXXXX` put this sandbox
    # somewhere only a declared glob could ever find, and on 2026-09-17 the
    # glob list did not have `root-mutation.*` in it. scratch.sh puts it under
    # one root with the owning pid in a ledger, so the sweeper finds it whatever
    # it is called and whether or not this process lives to clean up.
    # shellcheck source=scratch.sh
    . "$MUT_ENGINE_ROOT/scripts/lib/scratch.sh"
    MUT_SANDBOX="$(scratch_new mutation)" || {
        echo "FATAL: could not allocate a mutation sandbox" >&2; exit 2; }
    command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
    # shellcheck source=stopwatch.sh
    . "$MUT_ENGINE_ROOT/scripts/lib/stopwatch.sh"
    # shellcheck source=mutation-pool.sh
    . "$MUT_ENGINE_ROOT/scripts/lib/mutation-pool.sh"
    mut_pool_init
    MUT_WALL_T0="$(sw_now_ms)"
    cat >"$MUT_SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
# `{NL}` stands for a newline in <old>/<new>, so a source-level "\n" escape
# (two characters, backslash and n) can still be named literally.
old = old.replace("{NL}", "\n")
new = new.replace("{NL}", "\n")
# `{AND}` separates several (old, new) pairs applied to the same file in one
# mutant — for a property that two redundant checks carry, where removing
# only one is (correctly) not observable.
olds = old.split("{AND}")
news = new.split("{AND}")
if len(olds) != len(news):
    sys.stderr.write("MUTATION MALFORMED — %d old part(s) but %d new part(s)\n" % (len(olds), len(news)))
    sys.exit(3)
with open(path, encoding="utf-8") as fh:
    src = fh.read()
for o, n in zip(olds, news):
    if o not in src:
        sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % o)
        sys.exit(3)
    src = src.replace(o, n, 1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)
PYEOF
    echo "=== $1: every property, proven load-bearing by removing it ==="
}

# mutation_focus <mode> — a harness may declare, once, after mutation_begin, that
# its mutants need not run the WHOLE suite to reach their verdict.
#
# MEASURED, 2026-09-23, on this Mac, standalone: workspace-spec-fourteen.test.sh
# runs its checks in 84 s and its 86 mutants each ran all of them; workspaces.test.sh
# runs 103 tests in 60 s and its 77 mutants each ran all 103. Together they were the
# two longest units of every land that touched the workspace code (2811.7 s and
# 579.6 s in the 2026-09-15 inventory). Every mutant's verdict is ONE named case going
# red; the rest of each run bought nothing the verdict reads.
#
# The proof a mutant gives does not change: the mutation applied, and the named case
# went red because of it. What changes is how much of the suite runs after (or
# around) that case. Two modes, each a claim about the harness's own suite:
#
#   stop-at-want       the suite's cases run in sequence and share state, so they cannot
#                      be run alone. The mutant's run is stopped the moment its
#                      `FAIL  <want>` line is written (scripts/lib/stop-at-line.py). The
#                      CLAIM: in this suite a printed `FAIL  <case>` line always ends the
#                      run red. If the line never appears, the run finishes and is judged
#                      exactly as before.
#   want-as-argument   the suite takes case names as arguments and runs only those
#                      (workspaces.test.py, unittest). The mutant runs the suite with its
#                      want as the argument, TWICE: first on the unmutated copy, which must
#                      be green and must print `PASS  <want>` (a case that fails alone, or
#                      a name that selects nothing, is refused there), then mutated, which
#                      must be red at `FAIL  <want>`.
#
# A harness that declares nothing runs every mutant against the whole suite, as before.
# RICHOS_MUTATION_FOCUS=off makes a declaring harness do the same, for a before/after
# measurement on one tree; it is announced, never silent.
mutation_focus() { # <mode>
    case "${1:-}" in
        stop-at-want|want-as-argument) MUT_FOCUS="$1" ;;
        *) echo "FATAL: mutation_focus: unknown mode '${1:-}' (stop-at-want | want-as-argument)" >&2; exit 2 ;;
    esac
    if [ "${RICHOS_MUTATION_FOCUS:-}" = off ]; then
        echo "  (RICHOS_MUTATION_FOCUS=off: '$MUT_FOCUS' ignored, every mutant runs the whole suite)"
        MUT_FOCUS=""
    fi
}

# mutation_copy_engine <dest> <src-engine-root> — build a throwaway copy of
# the engine's mechanical layer at <dest>. PUBLIC, because a harness that keeps
# its own mutant loop still needs the sandbox; the kill-proof property belongs
# to every harness, not only to the ones that adopted this file's loop.
# Returns non-zero if <src-engine-root> does not look like an engine, so a
# caller can refuse rather than mutate a plausible-looking empty directory.
mutation_copy_engine() { # <dest> <src-engine-root>
    local dir="$1" src="$2"
    [ -d "$src/scripts/hooks" ] && [ -f "$src/orchestration.config" ] || return 1
    mut_refuse_recursive_copy "$dir" "$src" || return 1
    mut_refuse_oversize_root || return 1
    mkdir -p "$dir/.claude"
    cp -R "$src/scripts" "$dir/scripts" || return 1
    cp -R "$src/mega-lander" "$dir/mega-lander" || return 1
    cp -R "$src/ass-kicker" "$dir/ass-kicker" || return 1
    # mega-lander/app.py loads ecs/core and ecs/adapters at import, and its
    # suite reads agents/*.md. Without these the sandbox cannot import the file
    # being mutated -- which the zero-case run would report loudly, and which is
    # the same "the sandbox lacked a dependency" trap this file's header
    # describes. Copying MORE of the real engine is the answer that header gives.
    cp -R "$src/ecs" "$dir/ecs" || return 1
    cp -R "$src/agents" "$dir/agents" || return 1
    cp -R "$src/hooks" "$dir/hooks" || return 1
    cp "$src/orchestration.config" "$dir/orchestration.config" || return 1
    [ -f "$src/.claude/settings.local.json" ] && cp "$src/.claude/settings.local.json" "$dir/.claude/"
    [ -d "$src/.claude/agents" ] && cp -R "$src/.claude/agents" "$dir/.claude/agents"
    cp "$src/VERSION" "$dir/VERSION" 2>/dev/null || printf '0.0.0-mutant\n' >"$dir/VERSION"
    # Sidecars are never copied: a mutant must not carry the shipped hash.
    find "$dir" -name '*.sha256' -delete 2>/dev/null || true
    chmod +x "$dir"/scripts/hooks/*.sh "$dir"/scripts/*.sh 2>/dev/null || true
    return 0
}

_mut_copy_engine() { # <dir>
    mutation_copy_engine "$1" "$MUT_ENGINE_ROOT"
}

# mutation_sandbox_engine <src-engine-root> — mktemp a throwaway directory,
# build an engine copy inside it, and set MUT_SANDBOX_DIR / MUT_SANDBOX_ENGINE.
# The caller mutates MUT_SANDBOX_ENGINE and removes MUT_SANDBOX_DIR when it is
# done; if it never gets the chance to, the only casualty is a directory under
# TMPDIR. FATAL rather than silent on failure: a harness that carried on
# against an empty sandbox would report mutants "caught" by a guard that is
# not there.
mutation_sandbox_engine() { # <src-engine-root>
    local src="$1"
    # shellcheck source=scratch.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch.sh"
    MUT_SANDBOX_DIR="$(scratch_new mutation-sandbox)" || {
        echo "FATAL: mutation_sandbox_engine: could not create a sandbox directory" >&2; exit 2; }
    MUT_SANDBOX_ENGINE="$MUT_SANDBOX_DIR/engine"
    mkdir -p "$MUT_SANDBOX_ENGINE"
    if ! mutation_copy_engine "$MUT_SANDBOX_ENGINE" "$src"; then
        echo "FATAL: mutation_sandbox_engine: $src is not a readable engine root — refusing to mutate an empty sandbox" >&2
        rm -rf "$MUT_SANDBOX_DIR"
        exit 2
    fi
    return 0
}

# _mut_run <argv...> — run a mutant's suite under the caller's worker budget, when there is one
# (RICHOS_WORKER_TOKENS, from proof-run.py; scripts/lib/worker_tokens.py): on this pool's one
# free slot if no other worker of the pool holds it (the caller's own token), otherwise on a
# token of the budget. Without a budget it is the command itself, exactly as before.
_mut_run() {
    if [ -n "${RICHOS_WORKER_TOKENS:-}" ] && [ -n "${MUT_POOL_DIR:-}" ]; then
        # The tool comes with the budget (RICHOS_WORKER_TOKENS_TOOL, set by proof-run.py) so a
        # harness running in a fixture engine without it still counts against the same budget.
        python3 "${RICHOS_WORKER_TOKENS_TOOL:-$MUT_ENGINE_ROOT/scripts/lib/worker_tokens.py}" \
            run "$RICHOS_WORKER_TOKENS" --free "$MUT_POOL_DIR/free.lock" -- "$@"
    else
        "$@"
    fi
}

# _mutant_body — everything a single mutant does, as a function that RETURNS its
# verdict instead of incrementing a counter.
#
# The split from `mutant` is what makes concurrency possible and it is the only
# reason it exists: this body runs inside a pool worker, which is a subshell, so
# `MUT_PASS=$((MUT_PASS + 1))` in here would increment a copy and be discarded
# at the closing paren. A tally that silently counts nothing is precisely the
# green-over-nothing failure this engine was built to refuse, so the verdict
# travels as an EXIT CODE, which a subshell cannot lose.
#
# The output strings are byte-identical to the serial version. Anything that
# greps `^  PASS` or `^  FAIL  <name>` — contract-integrity.test.sh does — keeps
# matching. The duration is appended at END OF LINE for the same reason.
_mutant_body() { # <name> <want> <rel> <old> <new> <why>
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$MUT_SANDBOX/$name"
    local t0 el crc
    t0="$(sw_now_ms)"
    mkdir -p "$dir"
    # EACH MUTANT ALREADY HAD ITS OWN DIRECTORY, and that is why this loop is
    # safe to run concurrently at all: the sandbox is per-name, built from the
    # read-only shipped tree, and no two workers share a path.
    _mut_copy_engine "$dir"
    # THE FOCUSED CONTROL, BEFORE ANYTHING IS MUTATED (want-as-argument only; see
    # mutation_focus). The focused run must be GREEN on the unmutated copy and
    # must show the named case PASSING, so a red below is the mutation's doing:
    # not a case that only fails when run alone, and not a name that selected
    # nothing and exited 0.
    if [ "$MUT_FOCUS" = want-as-argument ]; then
        RICHOS_MUTATION_INNER=1 _mut_run bash "$dir/$MUT_SUITE" "$want" >"$dir/control.txt" 2>&1
        crc=$?
        if [ "$crc" -ne 0 ] || ! grep -qF "PASS  $want" "$dir/control.txt"; then
            el="$(sw_fmt "$(( $(sw_now_ms) - t0 ))")"
            printf '  FAIL  %s — the focused control is not green on the UNMUTATED copy (rc=%s), so a red run could not be credited to the mutation  [%s]\n' "$name" "$crc" "$el"
            tail -15 "$dir/control.txt" | sed 's/^/          /'
            return 1
        fi
    fi
    if ! python3 "$MUT_SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        el="$(sw_fmt "$(( $(sw_now_ms) - t0 ))")"
        printf '  FAIL  %s — the mutation did not apply  [%s]\n' "$name" "$el"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi
    # The suite under test must not recurse into ITS mutation harness: one
    # level is the proof; a mutant running mutants is a fork bomb with a
    # green tick at the bottom. RICHOS_MUTATION_INNER also forces any pool in
    # the inner suite to degree 1, so the process count stays bounded by JOBS
    # rather than by JOBS squared.
    local rc
    case "$MUT_FOCUS" in
        stop-at-want)
            RICHOS_MUTATION_INNER=1 _mut_run python3 "$MUT_ENGINE_ROOT/scripts/lib/stop-at-line.py" \
                --out "$dir/out.txt" --line "FAIL  $want" --marker "$dir/stopped" \
                -- bash "$dir/$MUT_SUITE"
            rc=$?
            if [ "$rc" -eq 0 ] && [ -f "$dir/stopped" ]; then
                el="$(sw_fmt "$(( $(sw_now_ms) - t0 ))")"
                printf '  PASS  %s — removing it turns "%s" red (stopped at that line)  [%s]\n' "$name" "$want" "$el"
                return 0
            fi ;;
        want-as-argument)
            RICHOS_MUTATION_INNER=1 _mut_run bash "$dir/$MUT_SUITE" "$want" >"$dir/out.txt" 2>&1
            rc=$? ;;
        *)
            RICHOS_MUTATION_INNER=1 _mut_run bash "$dir/$MUT_SUITE" >"$dir/out.txt" 2>&1
            rc=$? ;;
    esac
    el="$(sw_fmt "$(( $(sw_now_ms) - t0 ))")"
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.  [%s]\n' "$name" "$el"
        printf '          %s\n' "$why"
        return 1
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at "%s" (so the red is unrelated).  [%s]\n' "$name" "$want" "$el"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns "%s" red  [%s]\n' "$name" "$want" "$el"
    return 0
}

# mutant <name> <expected-failing-case-prefix> <rel-file> <old> <new> <why>
#
# Now a SUBMISSION rather than an execution. Every harness that sources this
# file becomes concurrent with no edit of its own, because a `mutant` line is a
# declaration and never was anything else. The report is still printed in
# declaration order — mut_pool_drain guarantees that — so a run of any harness
# diffs against a run from before this change except for the durations.
mutant() {
    mut_pool_submit "$1" _mutant_body "$@"
}

mutation_end() {
    # THE VERDICT IS DRAINED, NOT ACCUMULATED. Every mutant's exit code is
    # collected here and a worker that left no exit code counts as a FAILURE —
    # see mutation-pool.sh. So a killed mutant cannot quietly leave the tally.
    mut_pool_drain
    # A harness that declared mutants and ran NONE must not exit 0 — see
    # mut_pool_require_submissions for the run where exactly that happened and
    # every layer above it agreed.
    mut_pool_require_submissions "$MUT_SUITE's mutation harness"
    MUT_PASS="$MUT_POOL_PASS"
    MUT_FAIL="$MUT_POOL_FAIL"
    local wall=$(( $(sw_now_ms) - MUT_WALL_T0 ))
    mut_pool_report_line "$wall"
    mut_pool_cleanup
    rm -rf "$MUT_SANDBOX"
    echo ""
    if [ "$MUT_FAIL" -gt 0 ]; then
        echo "=== mutation: $MUT_FAIL property(ies) NOT proven load-bearing, $MUT_PASS proven ==="
        exit 1
    fi
    echo "=== mutation: all $MUT_PASS properties proven load-bearing ==="
    exit 0
}
