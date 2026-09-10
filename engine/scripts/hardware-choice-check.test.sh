#!/usr/bin/env bash
#
# hardware-choice-check.test.sh — the hardware-choice check, proven by execution.
#
# EVERY CASE RUNS AGAINST A SYNTHETIC TREE built in a sandbox, never against this repository.
# That is deliberate and it is the same reason `ci-shard.test.sh` gives: the properties being
# proven are "a NEWLY ADDED fixed hardware choice is caught" and "a DECLARED one is silent",
# and neither can be arranged in the real tree without adding a defect to it. A property you
# can only prove by breaking production is a property nobody proves.
#
# The real tree is measured separately, and that measurement is a corpus rather than a test:
# docs/verification/hardware-choice-check-2026-09-10.md. This file proves the MECHANISM; that
# file reports the RATE. Confusing the two is how a check ends up scored against the cases it
# was written from.
#
# WHAT IS PROVEN:
#
#   H1   A newly added `-t 4` in argv is CAUGHT.  <- the completion criterion, positive half
#   H2   The same site, DECLARED, is SILENT.      <- the completion criterion, negative half
#   H3   A BARE `hardware-fixed:` with no reason exempts NOTHING, and says so. Without this the
#        declaration is a magic word rather than a decision, which is the failure mode the
#        contrast and dialect rules already name.
#   H4   A reason under MIN_REASON_CHARS is likewise refused, so "ok" is not a reason.
#   H5   A declaration in a MULTI-LINE doc comment is honored at any distance within the block.
#        This is a regression test with a story: the check first used a fixed 3-line lookbehind
#        and the FIRST REAL DECLARATION written against it did not fit.
#   H6   A declaration is NOT inherited across a gap — a blank line ends the comment block, so a
#        declaration cannot silence an unrelated site further down the file.
#   H7   `ffmpeg -t 0.1` (a DURATION) is NOT flagged. The integer requirement, which is the one
#        thing keeping TOOL_FLAG usable.
#   H8   `-t` with a computed value (`String(n)`) is NOT flagged — it is not a fixed choice.
#   H9   A `-t` split across lines by rustfmt IS caught. THE REGRESSION TEST FOR THE REAL BUG:
#        the first draft was line-scoped and missed `stt.rs:245`, the headline defect of the
#        audit this check exists to serve.
#   H10  `std::thread::sleep(Duration::from_millis(200))` is NOT flagged. Five of the first six
#        findings on the real corpus were this, at 83.3 % false.
#   H11  A byte budget under MIN_BUDGET_BYTES (a protocol limit) is NOT flagged; one over it is.
#   H12  A `#[cfg(test)]` block is NOT scanned, so a forced-machine struct literal in a test is
#        the tested thing rather than a violation.
#   H13  `--strict` exits 1 on a firm finding and 0 on a clean tree; the default mode exits 0
#        either way. This is what makes "ships reporting" a fact about the artifact rather than
#        a claim in a document.
#   H14  `--json` emits parseable findings with shape, file and line.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/hardware-choice-check.py"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hardware-choice-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CHECK" ] || { echo "FATAL: missing $CHECK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== hardware-choice-check tests ==="

# ---------------------------------------------------------------------------
# a synthetic tree with the directory shape the check scans
# ---------------------------------------------------------------------------
mk_tree() { # <root>
    rm -rf "$1"
    mkdir -p "$1/app/crates/richos-voice/src" "$1/app/src-tauri/src" \
             "$1/tools/richos-service/lib" "$1/app/ui"
}

# run <root> [extra args...] -> stdout+stderr in $OUT, exit code in $RC
run() {
    local root="$1"; shift
    OUT="$(python3 "$CHECK" --root "$root" "$@" 2>&1)"; RC=$?
}

T="$SANDBOX/t"

# --- H1: a new fixed thread count is caught --------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> {
    vec!["-m".into(), "model".into(), "-t".into(), "4".into()]
}
RS
run "$T"
if grep -q 'TOOL_FLAG' <<<"$OUT" && grep -q 'new.rs' <<<"$OUT"; then
    ok "H1  a newly added fixed -t is caught"
else
    bad "H1  a newly added fixed -t is caught"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H2: the same site, declared, is silent --------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> {
    // hardware-fixed: measured byte-identical from 1 to 10 threads on a Metal host, 6.96% span
    vec!["-m".into(), "model".into(), "-t".into(), "4".into()]
}
RS
run "$T"
if ! grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H2  a declared fixed -t is silent"
else
    bad "H2  a declared fixed -t is silent"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H3: a bare marker exempts nothing -------------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> {
    // hardware-fixed:
    vec!["-t".into(), "4".into()]
}
RS
run "$T"
if grep -q 'TOOL_FLAG' <<<"$OUT" && grep -qi 'bare marker exempts nothing' <<<"$OUT"; then
    ok "H3  a bare hardware-fixed: marker exempts nothing, and says so"
else
    bad "H3  a bare hardware-fixed: marker exempts nothing, and says so"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H4: a too-short reason is refused -------------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> {
    // hardware-fixed: ok
    vec!["-t".into(), "4".into()]
}
RS
run "$T"
if grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H4  a reason under MIN_REASON_CHARS is refused"
else
    bad "H4  a reason under MIN_REASON_CHARS is refused"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H5: a declaration deep in a doc comment is honored --------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
/// The decode flags this path hands to whisper-cli.
///
/// A long explanation of why this function exists at all, which is the ordinary
/// shape of a doc comment in this codebase and is longer than three lines by a
/// wide margin.
///
/// hardware-fixed: the decode is carried by the GPU on every host measured, so the
/// thread count changes nothing; the no-GPU path is a separate resolved decision
pub fn args() -> Vec<String> {
    vec!["-t".into(), "4".into()]
}
RS
run "$T"
if ! grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H5  a declaration anywhere in the doc-comment block is honored"
else
    bad "H5  a declaration anywhere in the doc-comment block is honored"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H6: a declaration does not leak across a gap --------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
/// hardware-fixed: this reason belongs to the function below it and to nothing else at all
pub fn declared() -> Vec<String> {
    vec!["-t".into(), "4".into()]
}

pub fn undeclared() -> Vec<String> {
    vec!["-t".into(), "8".into()]
}
RS
run "$T"
# Scoped to the FINDING lines. The check's explanatory footer quotes the measured `-t 4` and
# `-p 4` numbers, so an unscoped grep for `-t 4` matches the help text and reports a failure
# that is entirely the test's own doing. Caught on this suite's second run.
HITS="$(grep 'new\.rs' <<<"$OUT" || true)"
if grep -q '\-t 8' <<<"$HITS" && ! grep -q '\-t 4' <<<"$HITS"; then
    ok "H6  a declaration does not silence an unrelated site further down"
else
    bad "H6  a declaration does not silence an unrelated site further down"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H7: ffmpeg -t is a duration, not a thread count -----------------------
mk_tree "$T"
cat > "$T/tools/richos-service/lib/norm.js" <<'JS'
export function pad(p) {
  return ['-y', '-f', 'lavfi', '-t', '0.1', '-i', 'anullsrc=r=16000:cl=mono', p];
}
JS
run "$T"
if ! grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H7  ffmpeg -t 0.1 (a duration) is not flagged"
else
    bad "H7  ffmpeg -t 0.1 (a duration) is not flagged"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H8: a computed value is not a fixed choice ----------------------------
mk_tree "$T"
cat > "$T/tools/richos-service/lib/norm.js" <<'JS'
export function a(n) {
  return ['-t', String(n), '-i', 'in.wav'];
}
JS
run "$T"
if ! grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H8  -t with a computed value is not flagged"
else
    bad "H8  -t with a computed value is not flagged"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H9: rustfmt splits argv across lines ----------------------------------
# THE REGRESSION TEST FOR THE REAL BUG. The first draft was line-scoped and missed stt.rs:245.
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> {
    vec![
        "-l".into(),
        "en".into(),
        "-t".into(),
        "4".into(),
        "-fa".into(),
    ]
}
RS
run "$T"
if grep -q 'TOOL_FLAG' <<<"$OUT"; then
    ok "H9  a -t split across lines by rustfmt is caught"
else
    bad "H9  a -t split across lines by rustfmt is caught"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H10: thread::sleep is about time, not parallelism ---------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn wait() {
    std::thread::sleep(std::time::Duration::from_millis(200));
    std::thread::sleep(std::time::Duration::from_millis(5));
}
RS
run "$T"
if ! grep -q 'WORKER_COUNT' <<<"$OUT"; then
    ok "H10 std::thread::sleep is not read as a worker count"
else
    bad "H10 std::thread::sleep is not read as a worker count"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H11: the budget threshold, both sides ---------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
const PAYLOAD_MAX_BYTES: usize = 32 * 1024;
const RAW_MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;
RS
run "$T"
if grep -q 'RAW_MAX_TOTAL_BYTES' <<<"$OUT" && ! grep -q 'PAYLOAD_MAX_BYTES' <<<"$OUT"; then
    ok "H11 a protocol-sized byte cap is ignored; a machine-sized one is flagged"
else
    bad "H11 a protocol-sized byte cap is ignored; a machine-sized one is flagged"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H12: a cfg(test) block is not scanned ---------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn nothing() {}

#[cfg(test)]
mod tests {
    #[test]
    fn a_forced_small_machine_demotes() {
        let args = vec!["-t".into(), "4".into()];
        let _cap: u64 = 2 * 1024 * 1024 * 1024;
        assert_eq!(args.len(), 2);
    }
}
RS
run "$T"
if ! grep -q 'new\.rs' <<<"$OUT"; then
    ok "H12 a #[cfg(test)] block is not scanned"
else
    bad "H12 a #[cfg(test)] block is not scanned"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- H13: the shipping mode reports; --strict is the gate ------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> { vec!["-t".into(), "4".into()] }
RS
run "$T"; DEFAULT_RC=$RC
run "$T" --strict; STRICT_RC=$RC
mk_tree "$T"
printf 'pub fn nothing() {}\n' > "$T/app/crates/richos-voice/src/new.rs"
run "$T" --strict; CLEAN_RC=$RC
if [ "$DEFAULT_RC" -eq 0 ] && [ "$STRICT_RC" -eq 1 ] && [ "$CLEAN_RC" -eq 0 ]; then
    ok "H13 default reports (exit 0); --strict gates (exit 1 dirty, 0 clean)"
else
    bad "H13 default reports (exit 0); --strict gates (exit 1 dirty, 0 clean)"
    printf '        default=%s strict=%s clean=%s\n' "$DEFAULT_RC" "$STRICT_RC" "$CLEAN_RC"
fi

# --- H14: --json is parseable ----------------------------------------------
mk_tree "$T"
cat > "$T/app/crates/richos-voice/src/new.rs" <<'RS'
pub fn args() -> Vec<String> { vec!["-t".into(), "4".into()] }
RS
run "$T" --json
if python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
assert isinstance(d, list) and len(d) == 1, d
assert d[0]['shape'] == 'TOOL_FLAG', d
assert d[0]['file'].endswith('new.rs'), d
assert isinstance(d[0]['line'], int), d
" <<<"$OUT" 2>/dev/null; then
    ok "H14 --json emits parseable findings with shape, file and line"
else
    bad "H14 --json emits parseable findings with shape, file and line"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

echo
printf '=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
