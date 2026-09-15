#!/usr/bin/env bash
#
# mechanical-findings.test.sh — the closed loop, end to end, in a sandbox.
#
# Builds two real repositories — a RECORD repository holding the working
# record, and an ARTIFACT repository holding a CI workflow, test suites,
# mutation harnesses and a hook registry — and drives the SHIPPED sweep, the
# SHIPPED writer and the SHIPPED Stop hook against them. Nothing is stubbed
# except the entity root (RICHOS_ENTITY_ROOT) and the lock's state directory,
# because those are the two things a test must not share with the live session.
#
# THE LOOP THIS PROVES, and where each link is asserted:
#   1. a defect in the tree is FOUND, with a control beside every class
#        cases 1a-1h  (a skipped suite; a harness no runner names; a hook no
#                      test names — and, for each, the neighbor that must NOT
#                      be reported)
#   2. a finding becomes a ROW, in the record's own format, with a warrant
#      minted by the landing guard's own code, read back OFF DISK
#        cases 2a-2f
#   3. the same finding on the next run is ONE row, not two
#        cases 3a-3b
#   4. the rows obey the two contracts that already govern the page — the
#      landing guard accepts them and the unstarted-row sweep NAMES them
#        cases 4a-4b
#   5. a finding that goes away is named so its row can be closed; a row
#      closed over a live finding is named as a contradiction
#        cases 5a-5c
#   6. a declared exemption is honored and reported; a bare marker is not
#        cases 6a-6b
#   7. the Stop hook: the notice, the silence, the receipt, the stand-down
#        cases 7a-7f
#   8. a sweep that cannot read is LOUD, never a clean tree
#        cases 8a-8d
#
# Run directly:  scripts/hooks/mechanical-findings.test.sh [--verbose]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t mechanical-findings.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ENG="$SANDBOX/engine"
HQ="$SANDBOX/hq"
APP="$SANDBOX/app"
mkdir -p "$ENG/scripts/hooks" "$ENG/scripts/lib" "$HQ/wiki" \
         "$APP/scripts/hooks" "$APP/hooks" "$APP/.github/workflows"

# --- the sandbox engine copy ----------------------------------------------
# The hook resolves its libraries relative to its own location, so the sandbox
# hosts them all. A copy, not a symlink: a mutation test rewrites one.
cp "$SRC_DIR/notice-mechanical-findings.sh" "$ENG/scripts/hooks/"
for l in mechanical-findings.sh mechanical-findings.py \
         unstarted-rows.sh unstarted-rows.py \
         row-currency.sh row-currency.py ceo-todos.sh ceo-todos.py \
         declaration-path.sh \
         resolve-roots.sh resolve-main-checkout.sh seat-jurisdiction.sh \
         stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$ENG/scripts/lib/$l" 2>/dev/null || true
done
for s in mechanical-findings-lint.sh unstarted-rows-lint.sh row-currency-lint.sh; do
    cp "$ENGINE_ROOT/scripts/$s" "$ENG/scripts/"
done
chmod +x "$ENG/scripts/hooks/"*.sh "$ENG/scripts/"*.sh

HOOK="$ENG/scripts/hooks/notice-mechanical-findings.sh"
LINT="$ENG/scripts/mechanical-findings-lint.sh"
URLINT="$ENG/scripts/unstarted-rows-lint.sh"
RCLINT="$ENG/scripts/row-currency-lint.sh"
RECORD="$HQ/wiki/open-items.md"
RECEIPT="$APP/.claude/state/mechanical-findings/last-sweep.txt"

export MECHANICAL_FINDINGS_STATE_DIR="$SANDBOX/state"

vc() { git -C "$1" "${@:2}"; }
setup_repo() {
    vc "$1" init -q -b main
    vc "$1" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
    vc "$1" config user.name "$(git config user.name 2>/dev/null || echo tester)"
}
commit_all() { vc "$1" add -A >/dev/null 2>&1; vc "$1" commit -q -m "${2:-change}" >/dev/null 2>&1; }
oid_of() { vc "$1" rev-parse --verify --quiet "HEAD:$2" | cut -c1-12; }

# --- the record repository -------------------------------------------------
cat > "$HQ/.ceo-todos" <<'EOF'
TODO_RECORD="wiki/open-items.md"
TODO_VIEW="CEO-TODOs.md"
ROOT_README="README.md"
CEO_SECTIONS="1"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="hq=. app=../app"
EOF
cat > "$HQ/.row-currency" <<'EOF'
ROW_SECTIONS="3"
ROW_STATUS_TOKENS="OPEN BUILT BOUNDED BLOCKED-ON-RICH CLOSED"
ROW_TERMINAL_TOKENS="CLOSED"
EOF
echo "# sandbox" > "$HQ/README.md"
echo "# view" > "$HQ/CEO-TODOs.md"
echo "artifact" > "$HQ/a.txt"
cat > "$HQ/RICH-TODOs.md" <<'EOF'
# Backlog

| # | Item | Blocked by |
|---|---|---|
| ~~0~~ | ~~**A landed thing**~~ | done |
| 1 | **A queue row the CEO owns** | **CEO — his call** |
EOF
setup_repo "$HQ"
commit_all "$HQ" "artifact first"
A_OID="$(oid_of "$HQ" a.txt)"

write_record() { # <state-token-for-3.1> <extra prose for 3.1>
    cat > "$RECORD" <<EOF
# Open items

## 1. Waiting on the CEO — a decision

### 1.1 READY-FOR-CEO — a decision

- **Open:** \`README.md\`

## 3. Buildable now — nobody blocked

| # | Item | State — the warrant this row is checked against |
|---|---|---|
| 3.1 | **A hand-written open row.** ${2:-}**Blocked:** the CEO — his call. | **State:** \`${1:-OPEN}\` — \`hq/a.txt\`@\`$A_OID\` |
| 3.2 | **A finished row.** | **State:** \`CLOSED\` — \`hq/a.txt\` |

## Deliberately NOT open

- prose that follows the table
EOF
}
write_record
commit_all "$HQ" "record"
BASE_HQ="$(vc "$HQ" rev-parse HEAD)"

# --- the artifact repository -----------------------------------------------
printf 'PROTECTED_PATHS="src"\n' > "$APP/orchestration.config"
printf 'ROW_RECORD_REPO="../hq"\n' > "$APP/.row-currency"
write_ci() { # <skip-b: yes|no>
    if [ "${1:-yes}" = "yes" ]; then
        cat > "$APP/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
jobs:
  suites:
    runs-on: ubuntu-latest
    steps:
      - run: |
          for t in scripts/hooks/*.test.sh; do
            if [ "$(basename "$t")" = "b.test.sh" ]; then
              echo "SKIP  $t"
              echo "      tracked separately"
              continue
            fi
            bash "$t"
          done
      # a.test.sh is named here in a comment only; the word skip follows.
      - run: bash scripts/hooks/a.test.sh
EOF
    else
        cat > "$APP/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
jobs:
  suites:
    runs-on: ubuntu-latest
    steps:
      - run: |
          for t in scripts/hooks/*.test.sh; do
            bash "$t"
          done
      - run: bash scripts/hooks/a.test.sh
EOF
    fi
}
write_ci yes
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/hooks/a.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/hooks/b.test.sh"
# x names ITSELF on a code line (a usage string), which is the one shape of
# self-reference a comment filter does not remove; it must still be an orphan.
printf '#!/usr/bin/env bash\n# x.mutation.sh — run by nothing\necho "usage: x.mutation.sh"\nexit 0\n' > "$APP/scripts/hooks/x.mutation.sh"
printf '#!/usr/bin/env bash\n# y.mutation.sh — run by scripts/run.sh\nexit 0\n' > "$APP/scripts/hooks/y.mutation.sh"
printf '#!/usr/bin/env bash\n# z.mutation.sh — named only in a comment\nexit 0\n' > "$APP/scripts/hooks/z.mutation.sh"
cat > "$APP/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
# The runner. z.mutation.sh is mentioned in this comment and nowhere else.
bash scripts/hooks/y.mutation.sh
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/hooks/h1.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/hooks/h2.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/hooks/h3.sh"
cat > "$APP/scripts/hooks/h1.test.sh" <<'EOF'
#!/usr/bin/env bash
# h3.sh is named in this comment and in no test's code.
bash scripts/hooks/h1.sh
EOF
cat > "$APP/hooks/hooks.json" <<'EOF'
{"hooks": {"Stop": [{"hooks": [
  {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/h1.sh"},
  {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/h2.sh"},
  {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/h3.sh"}
]}]}}
EOF
setup_repo "$APP"
commit_all "$APP" "base"

export RICHOS_ENTITY_ROOT="$APP"

K_B="ci-excluded-suite:app/scripts/hooks/b.test.sh"
K_X="unrun-harness:app/scripts/hooks/x.mutation.sh"
K_Z="unrun-harness:app/scripts/hooks/z.mutation.sh"
K_H2="untested-hook:app/scripts/hooks/h2.sh"
K_H3="untested-hook:app/scripts/hooks/h3.sh"

stop_payload() {
    python3 -c '
import json
print(json.dumps({"hook_event_name": "Stop",
                  "session_id": "deadbeef-2222-4000-8000-000000000000",
                  "cwd": "", "stop_hook_active": False,
                  "last_assistant_message": "Done.",
                  "background_tasks": [], "session_crons": []}))'
}
forget() { rm -rf "$APP/.claude/state/stop-hook-notices"; }
run_hook() { # -> HRC / HOUT ; from a forgotten ledger unless --remember
    [ "${1:-}" = "--remember" ] || forget
    HOUT="$(stop_payload | bash "$HOOK" 2>&1)"
    HRC=$?
}
spoke() { printf '%s' "$HOUT" | grep -q 'systemMessage'; }
lint() { # <args...> -> LRC / LOUT
    LOUT="$(bash "$LINT" "$APP" "$@" 2>&1)"
    LRC=$?
}
reset_record() { vc "$HQ" checkout -q "$BASE_HQ" -- wiki/open-items.md; }

echo "=== mechanical findings: found, written once, governed, surfaced, loud when blind ==="

# ===========================================================================
# 1. FOUND — with a control beside every class
# ===========================================================================
lint
if [ "$LRC" -eq 1 ]; then ok "1a  a tree with defects makes the lint exit 1"
else bad "1a  a tree with defects makes the lint exit 1" "rc=$LRC $LOUT"; fi
say "1a" "$LOUT"

if printf '%s' "$LOUT" | grep -q "NEW .*$K_B"; then ok "1b  a suite skipped BY NAME in a workflow is found (b.test.sh)"
else bad "1b  a suite skipped by name is found" "$LOUT"; fi
if ! printf '%s' "$LOUT" | grep -q 'a.test.sh'; then ok "1c  CONTROL: a suite that is RUN, and named only in a comment near 'skip', is NOT reported"
else bad "1c  CONTROL: a.test.sh must not be reported" "$LOUT"; fi

if printf '%s' "$LOUT" | grep -q "NEW .*$K_X"; then ok "1d  a harness no script names is found (x.mutation.sh)"
else bad "1d  x.mutation.sh must be found" "$LOUT"; fi
if printf '%s' "$LOUT" | grep -q "NEW .*$K_Z"; then ok "1e  a harness named ONLY IN A COMMENT is found (z.mutation.sh) — a comment is not a runner"
else bad "1e  z.mutation.sh must be found" "$LOUT"; fi
if ! printf '%s' "$LOUT" | grep -q 'y.mutation.sh'; then ok "1f  CONTROL: a harness a script actually invokes is NOT reported"
else bad "1f  CONTROL: y.mutation.sh must not be reported" "$LOUT"; fi

if printf '%s' "$LOUT" | grep -q "NEW .*$K_H2" && printf '%s' "$LOUT" | grep -q "NEW .*$K_H3"; then
    ok "1g  a registered hook no test names is found (h2), and one named only in a test's COMMENT is found (h3)"
else bad "1g  h2 and h3 must be found" "$LOUT"; fi
if ! printf '%s' "$LOUT" | grep -q 'untested-hook:app/scripts/hooks/h1.sh'; then ok "1h  CONTROL: a hook a test names on a code line is NOT reported"
else bad "1h  CONTROL: h1 must not be reported" "$LOUT"; fi

if printf '%s' "$LOUT" | grep -qE 'ci-excluded-suite +[1-9][0-9]* subject' \
   && printf '%s' "$LOUT" | grep -qE 'unrun-harness +[1-9][0-9]* subject' \
   && printf '%s' "$LOUT" | grep -qE 'untested-hook +[1-9][0-9]* subject'; then
    ok "1i  POSITIVE PROBE: every class reports how many subjects it examined, and none examined zero"
else bad "1i  POSITIVE PROBE: per-class subject counts" "$LOUT"; fi

if grep -q 'mechanical-findings.tmp' "$RECORD" 2>/dev/null || [ -f "$RECORD.mechanical-findings.tmp" ]; then
    bad "1j  report-only leaves no temp file behind"
else ok "1j  report-only wrote nothing: the record is untouched and no temp file exists"; fi
if vc "$HQ" diff --quiet -- wiki/open-items.md; then ok "1k  report-only: the record is byte-identical to HEAD"
else bad "1k  report-only must not modify the record"; fi

# ===========================================================================
# 2. WRITTEN — the row, read back off disk
# ===========================================================================
lint --write
say "2a" "$LOUT"
if [ "$LRC" -eq 1 ] && printf '%s' "$LOUT" | grep -q '5 row(s) appended'; then
    ok "2a  --write appends one row per NEW finding (5) and says so"
else bad "2a  --write appends 5 rows" "rc=$LRC $LOUT"; fi

N_ROWS="$(grep -c 'finding:' "$RECORD")"
if [ "$N_ROWS" -eq 5 ]; then ok "2b  READ BACK OFF DISK: the record carries exactly 5 \`finding:\` rows"
else bad "2b  the record carries 5 finding rows" "found $N_ROWS"; fi

if grep -q "^| 3.3 | .*\`finding:$K_B\` | \*\*State:\*\* \`OPEN\` — \`app/scripts/hooks/b.test.sh\`@\`$(oid_of "$APP" scripts/hooks/b.test.sh)\`, \`app/.github/workflows/ci.yml\`@\`$(oid_of "$APP" .github/workflows/ci.yml)\` |$" "$RECORD"; then
    ok "2c  row 3.3 is the skipped suite: id allocated above 3.2, key inside, warrant pinning BOTH the suite and the workflow at their real HEAD object ids"
else bad "2c  row 3.3's exact shape and stamps" "$(grep 'finding:ci' "$RECORD")"; fi

if grep -q "^| 3.4 | .*\`finding:$K_X\` | \*\*State:\*\* \`OPEN\` — \`app/scripts/hooks/x.mutation.sh\`@\`$(oid_of "$APP" scripts/hooks/x.mutation.sh)\` |$" "$RECORD"; then
    ok "2d  row 3.4 is the unrun harness, stamped at the harness's own object id"
else bad "2d  row 3.4's shape" "$(grep 'finding:unrun' "$RECORD" | head -1)"; fi

L31="$(grep -n '^| 3\.1 |' "$RECORD" | cut -d: -f1)"
L32="$(grep -n '^| 3\.2 |' "$RECORD" | cut -d: -f1)"
L33="$(grep -n '^| 3\.3 |' "$RECORD" | cut -d: -f1)"
L37="$(grep -n '^| 3\.7 |' "$RECORD" | cut -d: -f1)"
NOT_OPEN_LINE="$(grep -n '^## Deliberately NOT open' "$RECORD" | cut -d: -f1)"
if [ "$L31" -lt "$L32" ] && [ "$L32" -lt "$L33" ] && [ "$L33" -lt "$L37" ] && [ "$L37" -lt "$NOT_OPEN_LINE" ] \
   && [ "$L37" -eq "$((L32 + 5))" ] && sed -n "$((L37 + 1))p" "$RECORD" | grep -q '^$'; then
    ok "2e  rows are appended at the END of section 3's table — after 3.2, in order, before the next heading, with the table's blank line intact"
else bad "2e  insertion position" "3.1@$L31 3.2@$L32 3.3@$L33 3.7@$L37 heading@$NOT_OPEN_LINE"; fi

if grep -q "^| 3.1 | \*\*A hand-written open row.\*\* \*\*Blocked:\*\* the CEO — his call. | \*\*State:\*\* \`OPEN\` — \`hq/a.txt\`@\`$A_OID\` |$" "$RECORD" \
   && [ "$(vc "$HQ" diff -- wiki/open-items.md | grep -c '^-|')" -eq 0 ]; then
    ok "2f  no existing row was edited, re-stamped or removed — the diff is additions only"
else bad "2f  existing rows untouched" "$(vc "$HQ" diff -- wiki/open-items.md | grep '^-' | head -3)"; fi

if grep -q 'not by a person' "$RECORD" && grep -q 'notice-mechanical-findings.sh' "$RECORD"; then
    ok "2g  every written row says a machine wrote it, and which one"
else bad "2g  rows name their writer"; fi

# ===========================================================================
# 3. ONCE — the same defect on the next run is one row, not two
# ===========================================================================
SUM1="$(cksum < "$RECORD")"
lint --write
SUM2="$(cksum < "$RECORD")"
if [ "$SUM1" = "$SUM2" ] && [ "$(grep -c 'finding:' "$RECORD")" -eq 5 ]; then
    ok "3a  a second --write over the same tree writes NOTHING: the record is byte-identical, still 5 rows"
else bad "3a  identity: second write must add nothing" "$(grep -c 'finding:' "$RECORD") rows"; fi
if printf '%s' "$LOUT" | grep -q '5 known' && printf '%s' "$LOUT" | grep -q '0 new'; then
    ok "3b  the second sweep reports every finding as KNOWN with its row id, none as new"
else bad "3b  KNOWN not NEW" "$LOUT"; fi
if printf '%s' "$LOUT" | grep -qE 'KNOWN +3\.3 '; then ok "3c  a KNOWN finding names the row that holds it (3.3)"
else bad "3c  KNOWN names its row" "$LOUT"; fi

# ===========================================================================
# 4. GOVERNED — the two contracts already on the page accept and see the rows
# ===========================================================================
RCOUT="$(bash "$RCLINT" "$HQ" 2>&1)"; RCRC=$?
say "4a" "$RCOUT"
if [ "$RCRC" -eq 0 ]; then ok "4a  the LANDING GUARD's own lint accepts the written rows: their warrants are current (row-currency-lint exit 0)"
else bad "4a  row-currency-lint must accept the machine-written rows" "rc=$RCRC $(printf '%s' "$RCOUT" | tail -12)"; fi

UROUT="$(bash "$URLINT" "$HQ" 2>&1)"; URRC=$?
say "4b" "$UROUT"
if [ "$URRC" -eq 1 ] && printf '%s' "$UROUT" | grep -qE 'unblocked with nothing running for them: .*3\.3 3\.4 3\.5 3\.6 3\.7'; then
    ok "4b  the UNSTARTED-ROW sweep names every written row as unstarted — the third link sees the second's output"
else bad "4b  unstarted-rows-lint must name 3.3-3.7" "rc=$URRC $(printf '%s' "$UROUT" | tail -5)"; fi

# ===========================================================================
# 5. A FINDING GOES AWAY; A ROW DISAGREES WITH THE TREE
# ===========================================================================
write_ci no
commit_all "$APP" "run b.test.sh in CI"
lint --write
say "5a" "$LOUT"
if printf '%s' "$LOUT" | grep -qE 'GONE +3\.3 ' && printf '%s' "$LOUT" | grep -q '0 row(s) written' ; then
    ok "5a  the exclusion fixed in the tree: row 3.3 is named GONE, nothing is written, nothing is edited"
else bad "5a  GONE for 3.3" "$LOUT"; fi
if grep -q "finding:$K_B" "$RECORD"; then ok "5b  the GONE row is NOT touched — closing it is a person's read of the sentence"
else bad "5b  GONE row must remain on the page"; fi

write_ci yes
commit_all "$APP" "exclude b.test.sh again"
python3 - "$RECORD" <<'PYEOF'
import sys, re
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("| **State:** `OPEN` — `app/scripts/hooks/b.test.sh`", "| **State:** `CLOSED` — `app/scripts/hooks/b.test.sh`", 1)
open(p, "w", encoding="utf-8").write(t)
PYEOF
lint
if printf '%s' "$LOUT" | grep -qE 'CLOSED-BUT-PRESENT +3\.3 '; then
    ok "5c  a row closed by hand while the finding is still in the tree is named as a CONTRADICTION, not rewritten"
else bad "5c  CLOSED-BUT-PRESENT for 3.3" "$LOUT"; fi

# ===========================================================================
# 6. A DECLARED EXEMPTION — honored and reported; a bare marker is nothing
# ===========================================================================
reset_record
printf '#!/usr/bin/env bash\n# x.mutation.sh\n# finding-exempt: run by hand only, it needs a live device\nexit 0\n' > "$APP/scripts/hooks/x.mutation.sh"
commit_all "$APP" "declare x exempt"
lint
if ! printf '%s' "$LOUT" | grep -q "NEW .*$K_X" && printf '%s' "$LOUT" | grep -q 'EXEMPT.*x.mutation.sh.*live device'; then
    ok "6a  \`finding-exempt: <reason>\` in the subject removes the finding AND is reported with its reason"
else bad "6a  exemption honored and reported" "$LOUT"; fi
printf '#!/usr/bin/env bash\n# x.mutation.sh\n# finding-exempt:\nexit 0\n' > "$APP/scripts/hooks/x.mutation.sh"
commit_all "$APP" "bare marker"
lint
if printf '%s' "$LOUT" | grep -q "NEW .*$K_X"; then ok "6b  a BARE marker exempts nothing"
else bad "6b  bare marker must not exempt" "$LOUT"; fi
printf '#!/usr/bin/env bash\n# x.mutation.sh\n# finding-exempt: no\nexit 0\n' > "$APP/scripts/hooks/x.mutation.sh"
commit_all "$APP" "short reason"
lint
if printf '%s' "$LOUT" | grep -q "NEW .*$K_X"; then ok "6c  a marker whose reason is two letters exempts nothing either"
else bad "6c  short reason must not exempt" "$LOUT"; fi
printf '#!/usr/bin/env bash\n# x.mutation.sh — run by nothing\necho "usage: x.mutation.sh"\nexit 0\n' > "$APP/scripts/hooks/x.mutation.sh"
commit_all "$APP" "restore x"

# ===========================================================================
# 7. THE Stop HOOK — notice, silence, receipt, stand-down
# ===========================================================================
reset_record
run_hook
say "7a" "$HOUT"
if spoke && printf '%s' "$HOUT" | grep -q 'WROTE 5 ROW' && printf '%s' "$HOUT" | grep -q '3.3 (ci-excluded-suite'; then
    ok "7a  the turn ends with a notice that rows were WRITTEN, naming ids and keys"
else bad "7a  the hook announces what it wrote" "$HOUT"; fi
if [ "$HRC" -eq 0 ]; then ok "7b  it NOTICES, it does not block — exit 0"
else bad "7b  exit 0" "rc=$HRC"; fi
if [ "$(grep -c 'finding:' "$RECORD")" -eq 5 ]; then ok "7c  the hook itself wrote the 5 rows (not only the lint)"
else bad "7c  hook writes rows" "$(grep -c 'finding:' "$RECORD")"; fi
if printf '%s' "$HOUT" | grep -q 'UNCOMMITTED'; then ok "7d  the notice says the rows are uncommitted and whose repository they are in"
else bad "7d  notice says UNCOMMITTED" "$HOUT"; fi

run_hook --remember
if ! spoke; then ok "7e  the next turn, same tree, same rows: SILENT — known open rows are the unstarted sweep's to name"
else bad "7e  silent on a stable state" "$HOUT"; fi
if grep -q '^verdict:       FINDINGS' "$RECEIPT" 2>/dev/null && grep -q '^findings:      5  new 0  known 5' "$RECEIPT" 2>/dev/null; then
    ok "7f  POSITIVE PROBE: the receipt proves the silent turn SWEPT — 5 findings, all known"
else bad "7f  receipt on the silent turn" "$(cat "$RECEIPT" 2>/dev/null | head -12)"; fi

write_ci no
commit_all "$APP" "fix b again"
run_hook --remember
if spoke && printf '%s' "$HOUT" | grep -q 'ROW(S) 3.3 describe a finding the sweep no longer produces'; then
    ok "7g  the finding disappearing SPEAKS AGAIN, naming the row to close"
else bad "7g  GONE speaks" "$HOUT"; fi
run_hook --remember
if ! spoke; then ok "7i  the same GONE row on the next turn is SILENT — a persistent condition is announced once, not every turn"
else bad "7i  GONE announced once" "$HOUT"; fi
write_ci yes
commit_all "$APP" "exclude again"
run_hook --remember
if spoke && printf '%s' "$HOUT" | grep -q 'clear again'; then
    ok "7j  the GONE condition ending is the end of a story the operator was told: one 'clear again' line"
else bad "7j  recovery line after GONE" "$HOUT"; fi

SEAT="$SANDBOX/seat"
mkdir -p "$SEAT"
printf 'PROTECTED_PATHS="src"\n' > "$SEAT/orchestration.config"
setup_repo "$SEAT"; commit_all "$SEAT" "seat"
RICHOS_ENTITY_ROOT="$SEAT" run_hook
if ! spoke && [ "$HRC" -eq 0 ] && grep -q '^verdict:       STOOD-DOWN' "$SEAT/.claude/state/mechanical-findings/last-sweep.txt" 2>/dev/null; then
    ok "7h  a seat with no .row-currency STANDS DOWN silently, and its receipt says so"
else bad "7h  stand-down is silent with a receipt" "$HOUT $(cat "$SEAT/.claude/state/mechanical-findings/last-sweep.txt" 2>/dev/null)"; fi

# ===========================================================================
# 8. BLIND IS LOUD — never a clean tree
# ===========================================================================
reset_record
cp "$RECORD" "$SANDBOX/rec.keep"
python3 - "$RECORD" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
i = t.index("## 3.")
j = t.index("## Deliberately")
open(p, "w", encoding="utf-8").write(t[:i] + "## 3. Buildable now\n\nno table here\n\n" + t[j:])
PYEOF
lint --write
if [ "$LRC" -eq 2 ] && printf '%s' "$LOUT" | grep -q 'BROKEN'; then ok "8a  a record whose governed section has no table: lint exit 2, BROKEN, nothing written"
else bad "8a  no table -> BROKEN" "rc=$LRC $LOUT"; fi
run_hook
if spoke && printf '%s' "$HOUT" | grep -qi 'SWEPT NOTHING\|IS BROKEN'; then ok "8b  the hook says it swept nothing, on the channel the operator sees"
else bad "8b  hook is loud when broken" "$HOUT"; fi
cp "$SANDBOX/rec.keep" "$RECORD"

mv "$ENG/scripts/lib/mechanical-findings.py" "$SANDBOX/py.hidden"
lint
if [ "$LRC" -eq 2 ]; then ok "8c  the analyzer missing: lint exit 2 — never the same code as clean"
else bad "8c  missing analyzer -> exit 2" "rc=$LRC"; fi
run_hook
if spoke && printf '%s' "$HOUT" | grep -q 'BROKEN'; then ok "8d  the analyzer missing: the hook announces it rather than ending the turn quietly"
else bad "8d  hook loud without analyzer" "$HOUT"; fi
mv "$SANDBOX/py.hidden" "$ENG/scripts/lib/mechanical-findings.py"

reset_record
LOCK="$(MF_RECORD_FILE="$RECORD" bash -c '. "$1"; mf_lock_dir' _ "$ENG/scripts/lib/mechanical-findings.sh")"
mkdir -p "$LOCK"
lint --write
if printf '%s' "$LOUT" | grep -q 'WRITE REFUSED: another writer holds' && [ "$(grep -c 'finding:' "$RECORD")" -eq 0 ]; then
    ok "8e  another writer holding the lock: the write is REFUSED and reported, nothing partial lands"
else bad "8e  lock refuses the write" "$LOUT"; fi
rmdir "$LOCK"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
