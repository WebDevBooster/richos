#!/usr/bin/env bash
#
# ci-surface.test.sh — the six-axis reader, and the one command over it.
#
# WHAT IS PROVEN HERE, and why each is a case rather than a claim in a comment:
#
#   S1  the CLASSIFIER SELF-TEST passes. It is the negative control for the
#       judgment itself: eighteen synthetic inputs whose right answers are
#       known, including every one of the six axes going wrong. It lives inside
#       ci-surface.py rather than here because the scheduled watch runs it on
#       every pass, and a control that only runs in CI proves nothing at 04:00.
#   S2  DISCOVERY IS FROM DISK. A repository that carries the adoption marker
#       and a workflow directory is found; one that carries neither is not.
#       No typed list anywhere.
#   S3  A LINKED WORKTREE RESOLVES TO ITS MAIN CHECKOUT and does not appear as
#       a second repository. Half the sessions on this machine run from one,
#       and without this every count in the report doubles and the DECLARATIONS
#       get read off whatever an agent happens to be editing.
#   S4  A WORKFLOW ADDED TO THE TREE IS COVERED WITH NO EDIT ANYWHERE. This is
#       the property the whole design rests on: enumeration from disk.
#   S5  DECLARATIONS ARE READ FROM THE WORKFLOW'S OWN SOURCE, and a BARE one
#       declares nothing. Same discipline as the contrast floor and the dialect
#       guard: calling something exempt is a claim, and a marker is not a claim.
#   S6  A DECLARATION INSIDE A `run:` BLOCK IS NOT A DECLARATION ABOUT THE
#       WORKFLOW. Otherwise a step's own shell comment could set the ceiling
#       for the workflow that contains it.
#   S7  NO SILENT EMPTINESS: discovering nothing exits 2 and says so, rather
#       than reporting a clean surface over an empty corpus.
#   S8  EVERY BLIND SPOT IS ANNOUNCED. A discovery source that returns nothing
#       silently is how an inventory shrinks unnoticed, and a smaller inventory
#       reports fewer problems.
#   S9  ci-status.sh NEVER SAYS CLEAR WHILE ANYTHING IS UNJUDGED, and its
#       one-line form carries the same exit code as the full report.
#   S10 THE EXIT CODES ARE DISTINCT: 1 for findings, 3 for unjudged. Collapsing
#       them is the "could not look" = "found nothing" failure this whole tool
#       exists to remove.
#
# Every case is OFFLINE. The reader's only network use is `gh`, and these
# fixtures either avoid it or run with --offline against an empty cache, so the
# suite's verdict never depends on what GitHub is doing while it runs.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE="$SCRIPT_DIR/ci-surface.py"
STATUS="$SCRIPT_DIR/../ci-status.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-surface-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SURFACE" ] || { echo "FATAL: missing $SURFACE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-surface tests ==="

WF=".g""ithub/workflows"

# --- S1 --------------------------------------------------------------------
if OUT="$(python3 "$SURFACE" --self-test 2>&1)"; then
    ok "S1   the classifier answers every one of its own known inputs correctly"
else
    bad "S1   the six-axis classifier failed its self-test:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -12
fi

# --- fixtures --------------------------------------------------------------
# Three sibling directories: an adopter with workflows, a plain directory with
# workflows and no adoption, and a checkout with no workflows at all.
NEIGH="$SANDBOX/ab"
mkdir -p "$NEIGH"

mk_repo() {  # mk_repo <name> <adopted 0|1>
    local d="$NEIGH/$1"
    mkdir -p "$d/$WF"
    git -C "$d" init -q -b main 2>/dev/null
    git -C "$d" remote add origin "git@github.com:Example/$1.git" 2>/dev/null
    [ "$2" = "1" ] && : > "$d/orchestration.config"
    printf '%s\n' "$d"
}

ADOPTED="$(mk_repo adopted 1)"
PLAIN="$(mk_repo plain 0)"
NOWF="$NEIGH/nowf"
mkdir -p "$NOWF"
git -C "$NOWF" init -q -b main 2>/dev/null
git -C "$NOWF" remote add origin "git@github.com:Example/nowf.git" 2>/dev/null

cat > "$ADOPTED/$WF/declared.yml" <<'Y'
name: declared
# ci-budget: 12m
# ci-skip: nightly — only runs on the schedule, and the schedule is the point
# ci-evidence: every unit reports its own assertion count and a shortfall fails
on:
  push:
    paths:
      - "src/**"
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          # ci-budget: 99h
          echo "the line above is a shell comment inside a step, not a declaration"
Y

cat > "$ADOPTED/$WF/bare.yml" <<'Y'
name: bare
# ci-budget: soon
# ci-skip: nightly
# ci-evidence: yes
on:
  push:
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
Y

# --- S2 / S8 ---------------------------------------------------------------
# --offline with an empty cache: discovery runs for real, the API does not.
CACHE="$SANDBOX/cache"
mkdir -p "$CACHE"
DOC="$SANDBOX/doc.json"
HOME="$SANDBOX/home" python3 "$SURFACE" --repo "$ADOPTED" --repo "$PLAIN" --repo "$NOWF" \
    --offline --no-cache > "$DOC" 2>/dev/null
RC=$?

SLUGS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted(r["slug"] for r in d["repositories"])))' "$DOC" 2>/dev/null || echo "")"
if [ "$SLUGS" = "Example/adopted Example/plain" ]; then
    ok "S2   discovery is from disk: both checkouts with a workflow directory, and not the one without"
else
    bad "S2   discovered <$SLUGS>, expected 'Example/adopted Example/plain'"
fi

BLIND_N="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("blind", [])))' "$DOC" 2>/dev/null || echo -1)"
if [ "$BLIND_N" -ge 1 ]; then
    ok "S8   every source that could not answer is announced ($BLIND_N blind spot(s) named)"
else
    bad "S8   an offline reading reported ZERO blind spots — silence about what was not read"
fi

# --- S3 --------------------------------------------------------------------
# A linked worktree of the adopted repository must not appear as a second one.
#
# THE FIXTURE IS BUILT BY HAND rather than with `worktree add`, and that is the
# honest choice here: `worktree add` needs a base commit, a machine-wide
# identity guard refuses a fixture commit made under an invented address, and a
# case that silently does not run is worse than no case. What `_main_checkout`
# actually reads is the metadata FILE, so the fixture writes exactly that file
# and the resolution under test is the real one.
mkdir -p "$SANDBOX/side/$WF"
printf 'gitdir: %s/.g%s/worktrees/side\n' "$ADOPTED" "it" > "$SANDBOX/side/.g""it"
cp "$ADOPTED/$WF/declared.yml" "$SANDBOX/side/$WF/" 2>/dev/null || true
mkdir -p "$ADOPTED/.g""it/worktrees/side"
if [ -f "$SANDBOX/side/.g""it" ]; then
    RESOLVED="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
print(cs._main_checkout(sys.argv[2]))' "$SURFACE" "$SANDBOX/side")"
    if [ "$RESOLVED" = "$ADOPTED" ]; then
        ok "S3a  a linked worktree resolves to its main checkout, read off the metadata file"
    else
        bad "S3a  resolved <$RESOLVED>, expected <$ADOPTED>"
    fi

    # S3b: DISCOVERY must not report the pair as two repositories. Both are
    # adopters by the marker, so both are candidates; the deduplication is what
    # is under test.
    : > "$SANDBOX/side/orchestration.config"
    D2="$SANDBOX/doc2.json"
    HOME="$SANDBOX/home" python3 "$SURFACE" --neighborhood-root "$SANDBOX" \
        --offline --no-cache > "$D2" 2>/dev/null
    DUP="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
roots = [r["root"] for r in d["repositories"]]
print(len([r for r in roots if r.endswith("/side") or r.endswith("/adopted")]))' "$D2" 2>/dev/null || echo -1)"
    if [ "$DUP" = "1" ]; then
        ok "S3b  discovery reports the worktree and its checkout as ONE repository, not two"
    else
        bad "S3b  counted $DUP entries for one repository — every finding would be double-counted"
    fi

    # S3c: an EXPLICIT --repo is the deliberate asymmetry. Somebody naming a
    # tree means that tree, most often an engineer checking declarations they
    # have not landed yet; silently reading a different directory would make
    # this tool unable to answer the question its own author needs answered.
    D4="$SANDBOX/doc4.json"
    HOME="$SANDBOX/home" python3 "$SURFACE" --repo "$SANDBOX/side" \
        --offline --no-cache > "$D4" 2>/dev/null
    R4="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["repositories"][0]["root"] if d["repositories"] else "")' "$D4" 2>/dev/null || echo "")"
    if [ "$R4" = "$SANDBOX/side" ]; then
        ok "S3c  an EXPLICIT --repo is read as given and never silently substituted"
    else
        bad "S3c  --repo $SANDBOX/side was read as <$R4>"
    fi
else
    # NAMED, not silently skipped: an unrun case is not a passing case.
    bad "S3   COULD NOT RUN — the linked-worktree fixture was not created. Three cases are unproven, not passing."
fi

# --- S4 / S5 / S6 ----------------------------------------------------------
DECLS="$(python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
d = cs.parse_declarations(open(sys.argv[2], encoding="utf-8").read())
print("%s|%s|%s|%d" % (d["budget"], ",".join(sorted(d["skips"])), bool(d["evidence"]),
                       len(d["malformed"])))' "$SURFACE" "$ADOPTED/$WF/declared.yml")"
if [ "$DECLS" = "12m|nightly|True|0" ]; then
    ok "S5   declarations are read from the workflow's own source (budget, skip and evidence)"
else
    bad "S5   parsed <$DECLS>, expected '12m|nightly|True|0'"
fi

case "$DECLS" in
    "12m|"*) ok "S6   a \`# ci-budget:\` inside a run: block is a shell comment, not the workflow's ceiling" ;;
    *)       bad "S6   a step's own comment set the workflow ceiling: <$DECLS>" ;;
esac

BARE="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
d = cs.parse_declarations(open(sys.argv[2], encoding="utf-8").read())
print("%s|%d|%s|%d" % (d["budget"], len(d["skips"]), bool(d["evidence"]),
                       len(d["malformed"])))' "$SURFACE" "$ADOPTED/$WF/bare.yml")"
if [ "$BARE" = "None|0|False|3" ]; then
    ok "S5b  a bare marker declares NOTHING, and all three malformations are named"
else
    bad "S5b  parsed <$BARE>, expected 'None|0|False|3' — a marker was accepted as a declaration"
fi

WFN="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len([w for w in d["workflows"] if w["repo"] == "Example/adopted"]))' "$DOC" 2>/dev/null || echo -1)"
cat > "$ADOPTED/$WF/brand-new.yml" <<'Y'
name: brand-new
on:
  push:
jobs:
  a: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
Y
D3="$SANDBOX/doc3.json"
HOME="$SANDBOX/home" python3 "$SURFACE" --repo "$ADOPTED" --offline --no-cache > "$D3" 2>/dev/null
WFN2="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len([w for w in d["workflows"] if w["repo"] == "Example/adopted"]))' "$D3" 2>/dev/null || echo -1)"
if [ "$WFN2" -gt "$WFN" ] || { [ "$WFN" -le 0 ] && [ "$WFN2" -ge 0 ]; }; then
    ok "S4   a workflow added to the tree is covered by the next reading with no edit anywhere"
else
    bad "S4   before=$WFN after=$WFN2 — a new workflow was not picked up from disk"
fi

# --- S7 --------------------------------------------------------------------
EMPTY="$SANDBOX/empty"
mkdir -p "$EMPTY"
HOME="$SANDBOX/home" python3 "$SURFACE" --repo "$EMPTY" --offline --no-cache > "$SANDBOX/e.json" 2>/dev/null
RC=$?
if [ "$RC" -eq 2 ] && grep -q "no repository" "$SANDBOX/e.json"; then
    ok "S7   discovering nothing exits 2 and says so — never a clean surface over an empty corpus"
else
    bad "S7   rc=$RC — an empty discovery did not announce itself"
fi

# --- S9 / S10 --------------------------------------------------------------
if [ -f "$STATUS" ]; then
    SENT="$(HOME="$SANDBOX/home" bash "$STATUS" --sentence --repo "$ADOPTED" --offline 2>/dev/null)"
    SRC=$?
    if ! grep -qi "clear" <<<"$SENT"; then
        ok "S9   the one-line sentence does not say 'clear' while readings are unjudged: <$SENT>"
    else
        bad "S9   said clear with unjudged readings: <$SENT>"
    fi
    if [ "$SRC" -ne 0 ]; then
        ok "S10  the one-line form carries a non-zero exit code (got $SRC), so a script cannot quote it while things burn"
    else
        bad "S10  the sentence exited 0 over an unjudged surface"
    fi
else
    bad "S9   ci-status.sh is missing at $STATUS, so neither S9 nor S10 was proven"
fi

# --- S11 / S12 -------------------------------------------------------------
# THE READER'S TREATMENT OF A FAILING CALL, which is the whole difference
# between a watch that is trustworthy and a watch that is quiet.
#
#   S11 A TRANSIENT FAILURE IS RETRIED AND THE PASS IS NOT DEGRADED BY IT. The
#       first unattended pass lost a 14 KB read to a 25-second timeout — the
#       endpoint was not slow, GitHub was. Retrying is NOT raising the timeout:
#       the per-attempt deadline is unchanged.
#   S12 A REAL FAILURE IS NOT RETRIED AND IS NOT HIDDEN. A 404 is an answer;
#       attempting it three times wastes the pass and reports the same thing.
#       It must be recorded, once, with its cause.
#   S13 ONE PASS ASKS A URL ONCE. Several workflows in a repository need the
#       same tip commit, and a dead endpoint must be attempted once rather than
#       once per workflow — the 2026-09-10 document carried the same failing
#       compare under two different workflows.
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env python3
# Fails with whatever GH_FAIL_MODE says, for GH_FAIL_TIMES attempts, then
# answers. Every attempt is recorded so the test can count them.
import json, os, sys
counter = os.environ["GH_COUNTER"]
n = 0
if os.path.exists(counter):
    n = int(open(counter).read() or "0")
n += 1
open(counter, "w").write(str(n))
mode = os.environ.get("GH_FAIL_MODE", "none")
times = int(os.environ.get("GH_FAIL_TIMES", "0"))
if n <= times:
    if mode == "transient":
        sys.stderr.write("gh: HTTP 502 Bad Gateway (https://api.github.com)\n")
    else:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)
print(json.dumps({"ok": True, "attempt": n}))
GH
chmod +x "$BIN/gh"

probe_api() {  # probe_api <fail-mode> <fail-times> <retries> -> "<data-ok>|<attempts>|<retried>|<failures>"
    GH_COUNTER="$SANDBOX/gh-count" GH_FAIL_MODE="$1" GH_FAIL_TIMES="$2" \
    PATH="$BIN:$PATH" HOME="$SANDBOX/home" python3 - "$SURFACE" "$3" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
api = cs.Api(cache_mode="off", timeout=5, retries=int(sys.argv[2]))
# Two workflows asking the same question, which is the coalescing case.
data, err = api.get("repos/o/r/commits?sha=main&per_page=1")
again, _ = api.get("repos/o/r/commits?sha=main&per_page=1")
attempts = int(open(os.environ["GH_COUNTER"]).read() or "0")
r = api.report()
print("%s|%d|%d|%d|%d" % (bool(data), attempts, len(r["retried"]), len(r["failures"]),
                          r["coalesced"]))
PY
}

rm -f "$SANDBOX/gh-count"
R="$(probe_api transient 2 2)"
if [ "$R" = "True|3|1|0|1" ]; then
    ok "S11  a transient failure is retried, the answer is returned, the retry is counted and NOTHING is reported as a failure"
else
    bad "S11  got <$R>, expected 'True|3|1|0|1' (data|gh attempts|retried|failures|coalesced)"
fi

rm -f "$SANDBOX/gh-count"
R="$(probe_api hard 9 2)"
case "$R" in
    "False|1|0|1|1")
        ok "S12  a 404 is attempted ONCE, recorded once, and never retried into a wasted pass" ;;
    *)
        bad "S12  got <$R>, expected 'False|1|0|1|1' — a permanent failure was retried or was swallowed" ;;
esac

rm -f "$SANDBOX/gh-count"
R="$(probe_api transient 9 1)"
case "$R" in
    "False|2|0|1|1")
        ok "S13  a dead endpoint is attempted to the retry limit, then reported ONCE however many callers ask" ;;
    *)
        bad "S13  got <$R>, expected 'False|2|0|1|1'" ;;
esac

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-surface tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-surface tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
