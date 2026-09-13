#!/usr/bin/env bash
# run-unit-mutants.sh <label> <mutant-name> [<mutant-name> ...]
#
# A TARGETED run of named mutants of engine/scripts/lib/workspaces.mutation.sh
# (the unit harness), with the same contract as scripts/lib/mutation-harness.sh:
# one engine copy per mutant from a snapshot taken once at the start, `{NL}` is
# a newline, `{AND}` separates pairs, the target must exist, and PROVEN means
# the unit file exits non-zero AND prints `FAIL  <witness>`. The declarations
# are read from the harness itself by sourcing it with stubs.
set -uo pipefail
S="${RICHOS_R8_SCRATCH:-/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad}"
W="${RICHOS_R8_WORKTREE:-/Users/alex/ab/richos-wt/zach-fable-m5}"
LABEL="${1:?label}"; shift
[ "$#" -gt 0 ] || { echo "name at least one mutant" >&2; exit 2; }
D="$S/$LABEL"; mkdir -p "$D/outer-home/.claude" "$D/outer-ws" "$D/outer-sessions"
export CLAUDE_CONFIG_DIR="$D/outer-home/.claude" RICHOS_WORKSPACES_DIR="$D/outer-ws" RICHOS_SESSIONS_DIR="$D/outer-sessions"
STUB="$D/stub"; mkdir -p "$STUB"
cat > "$STUB/mutation-harness.sh" <<'EOF'
mutation_begin() { :; }
mutation_end() { :; }
mutant() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$MUT_DECL"; }
EOF
cp "$W/engine/scripts/lib/workspaces.mutation.sh" "$STUB/workspaces.mutation.sh"
: > "$D/decl.tsv"
MUT_DECL="$D/decl.tsv" bash "$STUB/workspaces.mutation.sh" >/dev/null 2>&1 || true
cat > "$D/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("{NL}", "\n"); new = new.replace("{NL}", "\n")
olds = old.split("{AND}"); news = new.split("{AND}")
src = open(path, encoding="utf-8").read()
for o, n in zip(olds, news):
    if o not in src:
        sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % o); sys.exit(3)
    src = src.replace(o, n, 1)
open(path, "w", encoding="utf-8").write(src)
PYEOF
BASE="$D/engine-base"; rm -rf "$BASE"; mkdir -p "$BASE/.claude"
cp -R "$W/engine/scripts" "$BASE/scripts"; cp -R "$W/engine/hooks" "$BASE/hooks"; cp "$W/engine/orchestration.config" "$BASE/orchestration.config"
find "$BASE" -name '*.sha256' -delete 2>/dev/null || true
OUT="$D/mutants.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  echo "engine snapshot: $BASE  workspaces.py sha256: $(shasum -a 256 "$BASE/scripts/lib/workspaces.py" | cut -c1-16)"
  echo "declarations read from the harness: $(wc -l < "$D/decl.tsv" | tr -d ' ')"
  PROVEN=0; UNPROVEN=0
  for NAME in "$@"; do
    LINE="$(grep -F "$NAME"$'\x1f' "$D/decl.tsv" | head -1)"
    if [ -z "$LINE" ]; then echo "  UNPROVEN  $NAME — not declared"; UNPROVEN=$((UNPROVEN+1)); continue; fi
    WANT="$(printf '%s' "$LINE" | cut -d $'\x1f' -f2)"; REL="$(printf '%s' "$LINE" | cut -d $'\x1f' -f3)"
    OLD="$(printf '%s' "$LINE" | cut -d $'\x1f' -f4)"; NEW="$(printf '%s' "$LINE" | cut -d $'\x1f' -f5)"
    E="$D/$NAME/engine"; rm -rf "$D/$NAME"; mkdir -p "$D/$NAME"; cp -R "$BASE" "$E"
    T0=$(date +%s)
    if ! python3 "$D/mutate.py" "$E/$REL" "$OLD" "$NEW" 2>"$D/$NAME/mutate.err"; then
      echo "  UNPROVEN  $NAME — the mutation did not apply: $(cat "$D/$NAME/mutate.err")"; UNPROVEN=$((UNPROVEN+1)); continue
    fi
    # THE WITNESS IS RESOLVED AS Class.method. The first version of this wrapper
    # passed the bare method name; unittest raised _FailedTest ("module has no
    # attribute"), printed `FAIL  <name> (error)` and exited 1, and the grep
    # below read that as PROVEN in 0 s — a negative passing for the wrong
    # reason. Caught by the 0 s; now the run must have RUN exactly one test.
    CLS="$(awk -v m="$WANT" '/^class /{c=$2; sub(/\(.*/,"",c)} $0 ~ ("def " m "\\(") {print c; exit}' "$E/scripts/lib/workspaces.test.py")"
    python3 -B -W ignore "$E/scripts/lib/workspaces.test.py" "$CLS.$WANT" > "$D/$NAME/out.txt" 2>&1; RC=$?
    EL=$(( $(date +%s) - T0 ))
    if grep -q "_FailedTest" "$D/$NAME/out.txt" || ! grep -q "^Ran 1 test" "$D/$NAME/out.txt"; then
      echo "  UNPROVEN  $NAME — the witness \"$CLS.$WANT\" did not run (resolution error), so nothing was proven  [${EL}s]"; UNPROVEN=$((UNPROVEN+1))
    elif [ "$RC" -eq 0 ]; then echo "  UNPROVEN  $NAME — \"$WANT\" still PASSED without this property  [${EL}s]"; UNPROVEN=$((UNPROVEN+1))
    elif ! grep -q "FAIL  $WANT" "$D/$NAME/out.txt"; then echo "  UNPROVEN  $NAME — red, but NOT at \"$WANT\"  [${EL}s]"; UNPROVEN=$((UNPROVEN+1))
    else echo "  PROVEN    $NAME — removing it turns \"$CLS.$WANT\" red  [${EL}s]"; PROVEN=$((PROVEN+1)); fi
    rm -rf "$E"
  done
  echo "=== targeted unit mutants: $PROVEN proven, $UNPROVEN unproven ==="
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
cat "$OUT"
