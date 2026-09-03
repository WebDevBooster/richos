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

MUT_PASS=0
MUT_FAIL=0
MUT_SANDBOX=""
MUT_SUITE=""
MUT_ENGINE_ROOT=""

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

_mut_copy_engine() { # <dir>
    local dir="$1"
    mkdir -p "$dir/.claude"
    cp -R "$MUT_ENGINE_ROOT/scripts" "$dir/scripts"
    cp -R "$MUT_ENGINE_ROOT/hooks" "$dir/hooks"
    cp "$MUT_ENGINE_ROOT/orchestration.config" "$dir/orchestration.config"
    [ -f "$MUT_ENGINE_ROOT/.claude/settings.local.json" ] && cp "$MUT_ENGINE_ROOT/.claude/settings.local.json" "$dir/.claude/"
    [ -d "$MUT_ENGINE_ROOT/.claude/agents" ] && cp -R "$MUT_ENGINE_ROOT/.claude/agents" "$dir/.claude/agents"
    cp "$MUT_ENGINE_ROOT/VERSION" "$dir/VERSION" 2>/dev/null || printf '0.0.0-mutant\n' >"$dir/VERSION"
    # Sidecars are never copied: a mutant must not carry the shipped hash.
    find "$dir" -name '*.sha256' -delete 2>/dev/null || true
    chmod +x "$dir"/scripts/hooks/*.sh "$dir"/scripts/*.sh 2>/dev/null || true
}

# mutant <name> <expected-failing-case-prefix> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$MUT_SANDBOX/$name"
    mkdir -p "$dir"
    _mut_copy_engine "$dir"
    if ! python3 "$MUT_SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        MUT_FAIL=$((MUT_FAIL + 1)); return
    fi
    # The suite under test must not recurse into ITS mutation harness: one
    # level is the proof; a mutant running mutants is a fork bomb with a
    # green tick at the bottom.
    RICHOS_MUTATION_INNER=1 bash "$dir/$MUT_SUITE" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        MUT_FAIL=$((MUT_FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at "%s" (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        MUT_FAIL=$((MUT_FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    MUT_PASS=$((MUT_PASS + 1))
}

mutation_end() {
    rm -rf "$MUT_SANDBOX"
    echo ""
    if [ "$MUT_FAIL" -gt 0 ]; then
        echo "=== mutation: $MUT_FAIL property(ies) NOT proven load-bearing, $MUT_PASS proven ==="
        exit 1
    fi
    echo "=== mutation: all $MUT_PASS properties proven load-bearing ==="
    exit 0
}
