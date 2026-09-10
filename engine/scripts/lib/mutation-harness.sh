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

MUT_PASS=0
MUT_FAIL=0
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

mutation_begin() { # <title> <suite-rel-path>
    MUT_ENGINE_ROOT="$(_mut_engine_root)"
    MUT_SUITE="$2"
    MUT_SANDBOX="$(cd "$(mktemp -d -t mutation.XXXXXX)" && pwd -P)"
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

# mutation_copy_engine <dest> <src-engine-root> — build a throwaway copy of
# the engine's mechanical layer at <dest>. PUBLIC, because a harness that keeps
# its own mutant loop still needs the sandbox; the kill-proof property belongs
# to every harness, not only to the ones that adopted this file's loop.
# Returns non-zero if <src-engine-root> does not look like an engine, so a
# caller can refuse rather than mutate a plausible-looking empty directory.
mutation_copy_engine() { # <dest> <src-engine-root>
    local dir="$1" src="$2"
    [ -d "$src/scripts/hooks" ] && [ -f "$src/orchestration.config" ] || return 1
    mkdir -p "$dir/.claude"
    cp -R "$src/scripts" "$dir/scripts" || return 1
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
    MUT_SANDBOX_DIR="$(cd "$(mktemp -d -t mutation-sandbox.XXXXXX)" && pwd -P)" || {
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
    local t0 el
    t0="$(sw_now_ms)"
    mkdir -p "$dir"
    # EACH MUTANT ALREADY HAD ITS OWN DIRECTORY, and that is why this loop is
    # safe to run concurrently at all: the sandbox is per-name, built from the
    # read-only shipped tree, and no two workers share a path.
    _mut_copy_engine "$dir"
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
    RICHOS_MUTATION_INNER=1 bash "$dir/$MUT_SUITE" >"$dir/out.txt" 2>&1
    local rc=$?
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
