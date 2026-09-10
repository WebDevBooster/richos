#!/usr/bin/env bash
#
# ci-status.sh — THE ONE COMMAND THAT ANSWERS "WHAT IS THE STATE OF CI?"
#                honestly, per workflow, on every axis, across every governed
#                repository.
#
# ===========================================================================
# WHY THIS EXISTS RATHER THAN A SENTENCE SOMEBODY TYPES
# ===========================================================================
# On 2026-09-02 the lead told the founder "CI green on main" while three
# workflows were red — one of them for thirteen days. That was not a lie told
# on purpose. It was the only sentence available: checking properly meant
# opening several repositories' Actions tabs by hand, so the blanket claim was
# cheaper than the specific one, and the blanket claim is the one that gets
# made.
#
#   MAKE THE SPECIFIC CLAIM CHEAP AND THE BLANKET CLAIM STOPS BEING NEEDED.
#
# That is this file's entire job. It prints, in one screen, every workflow in
# every governed repository, its verdict on each of the six axes, its last run
# and its duration against its declared budget. Anyone can run it, it takes
# about fifteen seconds, and it can be quoted verbatim.
#
# ===========================================================================
# WHAT IT WILL NOT DO
# ===========================================================================
# It will not print a fraction. "18/20 green" is the shape of claim that hid
# every defect this tool exists to surface: it counts the workflows it knows
# about, it has no opinion about the ones that never ran, and a number over a
# denominator invites the reader to feel proportion instead of reading the two.
#
# It will not print OK lines by default either — but `--all` prints everything,
# and the SUMMARY always names the counts of every verdict class including OK,
# so nothing is hidden by the default any more than by the flag.
#
# ===========================================================================
# EXIT CODES — the reason this is usable from a script
# ===========================================================================
#   0  every workflow clear on every axis, and nothing was unjudged
#   1  at least one FINDING or UNDECLARED
#   2  the surface could not be established (no repositories, no `gh`, no auth)
#   3  the surface was established but something in it is UNJUDGED — the state
#      that must never be collapsed into either of the other two. A checker
#      that could not look is not a checker that found nothing.
#
# Usage:
#   ci-status.sh                     every governed repository, findings only
#   ci-status.sh --all               every workflow, every axis
#   ci-status.sh --repo <path>       one repository
#   ci-status.sh --axis red          one axis
#   ci-status.sh --json              the raw document
#   ci-status.sh --offline           answer from cache only, and say so
#   ci-status.sh --sentence          ONE line, for quoting

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE="$SCRIPT_DIR/lib/ci-surface.py"

[ -f "$SURFACE" ] || { echo "FATAL: missing $SURFACE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }

MODE=findings
AXIS=""
PASSTHRU=()
while [ $# -gt 0 ]; do
    case "$1" in
        --all)      MODE=all ;;
        --json)     MODE=json ;;
        --sentence) MODE=sentence ;;
        --axis)     AXIS="${2:-}"; shift ;;
        --help|-h)  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          PASSTHRU+=("$1") ;;
    esac
    shift
done

# The neighborhood anchor. The surface discovers adopters among the SIBLINGS of
# the repositories it already knows, so on a machine whose repositories all sit
# in one directory this is that directory. It is derived from where the engine
# itself lives, never typed.
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANCHOR="$(cd "$ENGINE_ROOT/../.." 2>/dev/null && pwd || true)"

DOC="$(mktemp "${TMPDIR:-/tmp}/ci-status.XXXXXX")"
trap 'rm -f "$DOC"' EXIT

set +e
if [ -n "$ANCHOR" ]; then
    python3 "$SURFACE" --neighborhood-root "$ANCHOR" ${PASSTHRU[@]+"${PASSTHRU[@]}"} > "$DOC" 2>/dev/null
else
    python3 "$SURFACE" ${PASSTHRU[@]+"${PASSTHRU[@]}"} > "$DOC" 2>/dev/null
fi
RC=$?
set -e

if [ ! -s "$DOC" ]; then
    echo "CI STATUS: THE SURFACE COULD NOT BE READ AT ALL (ci-surface.py exited $RC with no output)." >&2
    echo "That is not 'CI is fine'. Nothing was checked." >&2
    exit 2
fi

if [ "$MODE" = json ]; then
    cat "$DOC"
    exit "$RC"
fi

MODE="$MODE" AXIS="$AXIS" python3 - "$DOC" <<'PY'
import json, os, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
mode = os.environ.get("MODE", "findings")
only_axis = os.environ.get("AXIS") or ""

AXES = ["slow", "red", "skipped", "never-run", "stale", "hollow"]
LOUD = ("FINDING", "UNDECLARED")
QUIET = ("OK", "BENIGN")

wfs = doc.get("workflows", [])
if only_axis:
    if only_axis not in AXES:
        print("no such axis: %s (axes are: %s)" % (only_axis, ", ".join(AXES)), file=sys.stderr)
        sys.exit(2)
    axes = [only_axis]
else:
    axes = AXES

counts = {}
for e in wfs:
    for a in axes:
        counts[e["axes"][a]["verdict"]] = counts.get(e["axes"][a]["verdict"], 0) + 1

loud = sum(counts.get(v, 0) for v in LOUD)
unjudged = counts.get("UNKNOWABLE", 0)
nrepos = doc["counts"]["repositories"]
nwf = doc["counts"]["workflows"]

# --- the sentence ----------------------------------------------------------
# It is a SENTENCE and not a fraction, and it never says "green" unless every
# axis of every workflow is clear AND nothing was unjudged. "Green with three
# unjudged" is the claim this whole tool exists to make impossible.
if loud == 0 and unjudged == 0:
    sentence = ("CI is clear: %d workflows across %d repositories, every one of them OK or declared "
                "on all six axes, read at %s." % (nwf, nrepos, doc["generated_at"]))
elif loud == 0:
    sentence = ("CI has no findings but %d axis reading(s) are UNJUDGED across %d workflows — the "
                "checker could not look, which is not the same as finding nothing." % (unjudged, nwf))
else:
    per = {}
    for e in wfs:
        for a in axes:
            if e["axes"][a]["verdict"] in LOUD:
                per[a] = per.get(a, 0) + 1
    sentence = ("CI is NOT clear: %d finding(s) across %d workflows in %d repositories — %s%s."
                % (loud, nwf, nrepos,
                   ", ".join("%s %d" % (k, v) for k, v in sorted(per.items(), key=lambda t: -t[1])),
                   ("; %d further reading(s) UNJUDGED" % unjudged) if unjudged else ""))

if mode == "sentence":
    print(sentence)
    # The one-line form carries the SAME exit code as the full report. A
    # summary that always exits 0 is a summary a script can quote while the
    # thing it summarizes is on fire.
    if doc.get("api", {}).get("failures") or doc.get("blind"):
        sys.exit(3 if loud == 0 else 1)
    sys.exit(1 if loud else (3 if unjudged else 0))

print("=" * 100)
print("CI SURFACE — %s — branch %s" % (doc["generated_at"], doc["branch"]))
print("=" * 100)
for r in doc.get("repositories", []):
    print("  %-42s %s  (%s)" % (r["slug"], r["root"], r["source"]))
print()

order = {"FINDING": 0, "UNDECLARED": 1, "UNKNOWABLE": 2, "PATH-GATED": 3, "TIP-GATED": 3,
         "BENIGN": 4, "OK": 5}
by_repo = {}
for e in wfs:
    by_repo.setdefault(e["repo"], []).append(e)

# A detail that is IDENTICAL across many workflows is one fact, not many. The
# "no `# ci-budget:`" paragraph is currently true of every workflow in every
# repository, and printing it twenty times buries the four findings that are
# specific. It is printed ONCE, as a note, and referenced — the count stays in
# the summary, so nothing is lost, only repetition.
tally = {}
for e in wfs:
    for a in axes:
        v = e["axes"][a]
        if v["verdict"] in LOUD:
            tally[v["detail"]] = tally.get(v["detail"], 0) + 1
notes, note_of = [], {}
for text, n in sorted(tally.items(), key=lambda t: -t[1]):
    if n >= 3:
        note_of[text] = len(notes) + 1
        notes.append((len(notes) + 1, n, text))

for repo in sorted(by_repo):
    entries = sorted(by_repo[repo], key=lambda e: min(order.get(e["axes"][a]["verdict"], 9)
                                                      for a in axes))
    printed_header = False
    for e in entries:
        rows = []
        for a in axes:
            v = e["axes"][a]
            if mode == "all" or v["verdict"] not in QUIET:
                rows.append((a, v))
        if e.get("drift"):
            rows.insert(0, ("drift", {"verdict": "FINDING", "detail": e["drift"]}))
        if not rows:
            continue
        if not printed_header:
            print("-" * 100)
            print(repo)
            print("-" * 100)
            printed_header = True
        run = ("run #%s %s" % (e.get("latest_run"), e.get("latest_conclusion"))
               if e.get("latest_run") is not None else "no completed run")
        print("  %s   [%s, %s]" % (e["workflow"], e.get("state", "?"), run))
        for a, v in rows:
            head = "    %-10s %-11s " % (a, v["verdict"])
            text = v["detail"]
            if text in note_of:
                print("%ssee note [%d] — shared by %d workflow(s)"
                      % (head, note_of[text], tally[text]))
                continue
            width = 100 - len(head)
            words, line = text.split(), ""
            first = True
            for w in words:
                if len(line) + len(w) + 1 > width:
                    print((head if first else " " * len(head)) + line)
                    first, line = False, w
                else:
                    line = (line + " " + w).strip()
            if line:
                print((head if first else " " * len(head)) + line)
        print()

if notes:
    print("=" * 100)
    print("NOTES — findings that are identical across many workflows, stated once")
    print("=" * 100)
    for num, n, text in notes:
        head = "  [%d] x%-3d " % (num, n)
        width = 100 - len(head)
        words, line, first = text.split(), "", True
        for w in words:
            if len(line) + len(w) + 1 > width:
                print((head if first else " " * len(head)) + line)
                first, line = False, w
            else:
                line = (line + " " + w).strip()
        if line:
            print((head if first else " " * len(head)) + line)
        print()

if doc.get("blind"):
    print("=" * 100)
    print("BLIND SPOTS — what this reading could NOT see. An inventory that shrinks silently")
    print("reports fewer problems, which reads exactly like progress.")
    print("=" * 100)
    for b in doc["blind"]:
        print("  • %s" % b)
    print()

if doc.get("api", {}).get("failures"):
    print("=" * 100)
    print("API FAILURES — %d" % len(doc["api"]["failures"]))
    print("=" * 100)
    for f in doc["api"]["failures"][:10]:
        print("  • %s" % f)
    print()

print("=" * 100)
print("  " + sentence)
print("  verdict counts across %d workflow(s) x %d axis(es): %s"
      % (nwf, len(axes), ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts))))
# THE CACHE MODE IS PRINTED BESIDE THE HIT COUNT. `0 cache hit(s)` on its own
# reads as a broken cache, and on 2026-09-10 it was read that way — the pass
# that produced it had asked for no cache at all.
_api = doc["api"]
print("  api: %d call(s), %d cache hit(s) [mode: %s], %d coalesced, %d failure(s)"
      % (_api["calls"], _api["cache_hits"], _api.get("cache_mode", "unstated"),
         _api.get("coalesced", 0), len(_api["failures"])))
print("=" * 100)

if doc.get("api", {}).get("failures") or doc.get("blind"):
    sys.exit(3 if loud == 0 else 1)
sys.exit(1 if loud else (3 if unjudged else 0))
PY
