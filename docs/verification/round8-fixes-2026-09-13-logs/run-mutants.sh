#!/usr/bin/env bash
# run-mutants.sh <label> <mutant-name> [<mutant-name> ...]
#
# A TARGETED run of named mutants of engine/scripts/workspace-spec-fourteen.mutation.sh,
# with the same contract as scripts/lib/mutation-harness.sh: each mutant gets its
# own copy of the engine's mechanical layer, the shipped tree is never opened for
# writing, `{NL}` is a newline and `{AND}` separates several (old,new) pairs, the
# target must exist, and the verdict is PROVEN only when the fourteen (run WITHOUT
# its own mutation pass) exits non-zero AND prints `FAIL  <want>`.
#
# Why this exists beside the harness: the harness runs every mutant (60+, tens of
# minutes); an engineer adding four wants to watch those four go red for their
# own reason in minutes, then run the whole harness once at the end. The
# declarations are read from the harness file itself by sourcing it with stub
# functions, so a mutant here IS the mutant the harness will run.
set -uo pipefail
S="${RICHOS_R8_SCRATCH:-/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad}"
W="${RICHOS_R8_WORKTREE:-/Users/alex/ab/richos-wt/zach-fable-m5}"
LABEL="${1:?label}"; shift
[ "$#" -gt 0 ] || { echo "name at least one mutant" >&2; exit 2; }
D="$S/$LABEL"; mkdir -p "$D"
mkdir -p "$D/outer-home/.claude" "$D/outer-ws" "$D/outer-sessions"
export CLAUDE_CONFIG_DIR="$D/outer-home/.claude" RICHOS_WORKSPACES_DIR="$D/outer-ws" RICHOS_SESSIONS_DIR="$D/outer-sessions"

# --- the declarations, read from the harness by sourcing it with stubs ---------
STUB="$D/stub"; mkdir -p "$STUB/lib"
cat > "$STUB/lib/mutation-harness.sh" <<'EOF'
mutation_begin() { :; }
mutation_end() { :; }
mutant() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$MUT_DECL"; }
EOF
cp "$W/engine/scripts/workspace-spec-fourteen.mutation.sh" "$STUB/workspace-spec-fourteen.mutation.sh"
: > "$D/decl.tsv"
MUT_DECL="$D/decl.tsv" bash "$STUB/workspace-spec-fourteen.mutation.sh" >/dev/null 2>&1 || true
DECLARED="$(wc -l < "$D/decl.tsv" | tr -d ' ')"

cat > "$D/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("{NL}", "\n"); new = new.replace("{NL}", "\n")
olds = old.split("{AND}"); news = new.split("{AND}")
if len(olds) != len(news):
    sys.stderr.write("MUTATION MALFORMED\n"); sys.exit(3)
src = open(path, encoding="utf-8").read()
for o, n in zip(olds, news):
    if o not in src:
        sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % o); sys.exit(3)
    src = src.replace(o, n, 1)
open(path, "w", encoding="utf-8").write(src)
PYEOF

OUT="$D/mutants.txt"
{
  echo "label: $LABEL  started: $(date -u +%FT%TZ)"
  echo "worktree: $W  HEAD: $(git -C "$W" rev-parse HEAD)  dirty: $(git -C "$W" status --short | wc -l | tr -d ' ')"
  echo "engine: $W/engine  workspaces.py sha256: $(shasum -a 256 "$W/engine/scripts/lib/workspaces.py" | cut -c1-16)  guard sha256: $(shasum -a 256 "$W/engine/scripts/hooks/guard-worktree-removal.sh" | cut -c1-16)"
  echo "declarations read from the harness: $DECLARED"
  PROVEN=0; UNPROVEN=0
  for NAME in "$@"; do
    LINE="$(grep -F "$NAME"$'\x1f' "$D/decl.tsv" | head -1)"
    if [ -z "$LINE" ]; then echo "  UNPROVEN  $NAME — not declared in the harness"; UNPROVEN=$((UNPROVEN+1)); continue; fi
    WANT="$(printf '%s' "$LINE" | cut -d $'\x1f' -f2)"
    REL="$(printf '%s' "$LINE" | cut -d $'\x1f' -f3)"
    OLD="$(printf '%s' "$LINE" | cut -d $'\x1f' -f4)"
    NEW="$(printf '%s' "$LINE" | cut -d $'\x1f' -f5)"
    E="$D/$NAME/engine"; rm -rf "$D/$NAME"; mkdir -p "$E/.claude"
    cp -R "$W/engine/scripts" "$E/scripts"; cp -R "$W/engine/hooks" "$E/hooks"; cp "$W/engine/orchestration.config" "$E/orchestration.config"
    cp "$W/engine/VERSION" "$E/VERSION" 2>/dev/null || printf '0.0.0-mutant\n' > "$E/VERSION"
    find "$E" -name '*.sha256' -delete 2>/dev/null || true
    T0=$(date +%s)
    if ! python3 "$D/mutate.py" "$E/$REL" "$OLD" "$NEW" 2>"$D/$NAME/mutate.err"; then
      echo "  UNPROVEN  $NAME — the mutation did not apply: $(cat "$D/$NAME/mutate.err")"; UNPROVEN=$((UNPROVEN+1)); continue
    fi
    RICHOS_MUTATION_INNER=1 RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash "$E/scripts/workspace-spec-fourteen.test.sh" > "$D/$NAME/out.txt" 2>&1; RC=$?
    EL=$(( $(date +%s) - T0 ))
    if [ "$RC" -eq 0 ]; then
      echo "  UNPROVEN  $NAME — the suite still PASSED without this property  [${EL}s]"; UNPROVEN=$((UNPROVEN+1))
    elif ! grep -q "FAIL  $WANT" "$D/$NAME/out.txt"; then
      echo "  UNPROVEN  $NAME — red, but NOT at \"$WANT\": $(grep '  FAIL' "$D/$NAME/out.txt" | tr '\n' ' ' | head -c 300)  [${EL}s]"; UNPROVEN=$((UNPROVEN+1))
    else
      echo "  PROVEN    $NAME — removing it turns \"$WANT\" red: $(grep "FAIL  $WANT" "$D/$NAME/out.txt" | head -1 | cut -c1-160)  [${EL}s]"; PROVEN=$((PROVEN+1))
    fi
    rm -rf "$E"
  done
  echo "=== targeted mutants: $PROVEN proven, $UNPROVEN unproven ==="
  echo "finished: $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
cat "$OUT"
