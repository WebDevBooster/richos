#!/bin/bash
# Scoped verification for this measurement directory. Run it from anywhere; it locates its own
# directory and checks only what lives here.
#
# WHAT IT IS FOR. Every claim in `whisper-model-choice.md` rests on artifacts in `measurements/`.
# These checks assert the properties that would make those artifacts untrustworthy if they failed:
# that the record's tables really are this rig's output, that each run used the flags and the
# weights its row claims, that a memory figure exists for every decode, that nothing private
# leaked, and that the shim cannot fork-bomb. It replaces no measurement — it makes the record
# falsifiable.
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
cd "$D"
fail=0

echo "== 1. the generated tables regenerate byte-identically from the raw artifacts =="
tmp=$(mktemp)
node tools/model-table.mjs --raw measurements/raw > "$tmp" 2>&1
if diff -q measurements/model-comparison.txt "$tmp" > /dev/null; then
  echo "   OK — model-comparison.txt is exactly tools/model-table.mjs stdout"
else
  echo "   FAIL — committed table differs from a fresh generation"
  diff measurements/model-comparison.txt "$tmp" | head -20
  fail=1
fi
rm -f "$tmp"

echo "== 2. every configuration's argv contains the flag it claims to test, and only that =="
for f in measurements/raw/shortcall/r1-turboNfa.argv.jsonl measurements/raw/shortcall/r1-q5Nfa.argv.jsonl; do
  if grep -q '"-nfa"' "$f"; then echo "   OK — $(basename "$f") contains -nfa"; else echo "   FAIL — $(basename "$f") has no -nfa"; fail=1; fi
done
for f in measurements/raw/shortcall/r1-turbo.argv.jsonl measurements/raw/shortcall/r1-q5.argv.jsonl; do
  if grep -q '"-nfa"' "$f"; then echo "   FAIL — $(basename "$f") should NOT contain -nfa"; fail=1; else echo "   OK — $(basename "$f") has no -nfa"; fi
done

echo "== 3. every q5 run really used the quantized weights, every turbo run the full ones =="
for f in measurements/raw/shortcall/r1-q5.argv.jsonl measurements/raw/longform/q5-me.argv.jsonl measurements/raw/longform/q5-others.argv.jsonl; do
  if grep -q 'ggml-large-v3-turbo-q5_0.bin' "$f"; then echo "   OK — $(basename "$f") -> q5_0"; else echo "   FAIL — $(basename "$f")"; fail=1; fi
done
for f in measurements/raw/longform/turbo-me.argv.jsonl measurements/raw/longform/turbo-others.argv.jsonl; do
  if grep -q 'ggml-large-v3-turbo\.bin' "$f"; then echo "   OK — $(basename "$f") -> full turbo"; else echo "   FAIL — $(basename "$f")"; fail=1; fi
done

echo "== 4. every long-form decode ran the SHIPPING flags =="
n=0; bad=0
for f in measurements/raw/longform/*.argv.jsonl; do
  while IFS= read -r line; do
    case "$line" in *'"-f"'*) ;; *) continue ;; esac
    n=$((n + 1))
    case "$line" in *'"-mc","0"'*) ;; *) echo "   FAIL no -mc 0: $f"; bad=1 ;; esac
    case "$line" in *'"-fa"'*) ;; *) echo "   FAIL no -fa: $f"; bad=1 ;; esac
  done < "$f"
done
if [ "$bad" -eq 0 ]; then echo "   OK — $n long-form decode RECORDS, all with -mc 0 and -fa"; else fail=1; fi
# The collected logs record each invocation TWICE — both shims honored one variable at the time
# these runs were made (measurements/raw/README-argv-doubling.txt). Assert that exact factor, so
# the doubling is a pinned property of these artifacts rather than a number a reader has to guess
# at. A future run made with the fixed shim will record 4 and this line is what will say so.
if [ "$n" -eq 8 ]; then
  echo "   OK — 8 records = 4 real decodes, doubled exactly as documented"
else
  echo "   NOTE — $n records; 8 is the documented doubling for the 2026-09-10 runs, 4 is a clean re-run"
fi

echo "== 5. a memory figure exists for every decode =="
if grep -l '"maxrssBytes":null' measurements/raw/*/*.rss.jsonl 2>/dev/null; then
  echo "   FAIL — a run recorded no memory"; fail=1
else
  echo "   OK — every rss record carries a memory figure"
fi

# THE PATTERNS ARE READ AT RUN TIME AND ARE NOT WRITTEN DOWN HERE. An earlier draft of this file
# grepped for the private basenames literally, which put a real person's name into a file in a
# repository that gets published — the exact failure the deny-list exists to stop, committed by
# the check meant to prevent it. The list lives outside every repository, on the operator's
# machine; absent, this check says so instead of passing quietly, because a privacy check that
# silently succeeds when it cannot run is worse than none.
echo "== 6. privacy: no deny-listed name and no private-tree basename in this directory =="
DENY="${RICHOS_NAMED_PERSONS:-$HOME/.richos-privacy/named-persons}"
if [ ! -r "$DENY" ]; then
  echo "   CANNOT RUN — no deny-list at $DENY. This check did NOT pass; it did not execute."
  fail=1
else
  hits=0
  while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    if grep -rniF -- "$name" . > /dev/null 2>&1; then
      echo "   FAIL — a deny-listed name appears in this directory (not echoed here)"
      hits=1
    fi
  done < "$DENY"
  # The real recordings' own basenames, enumerated from the private tree rather than hard-coded.
  PRIV="${RICHOS_PRIVATE_REFERENCE:-$HOME/ab/richos-hq/docs/reference/local}"
  if [ -d "$PRIV" ]; then
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      if grep -rniF -- "$base" . > /dev/null 2>&1; then
        echo "   FAIL — a private recording basename appears in this directory (not echoed here)"
        hits=1
      fi
    done <<EOF
$(find "$PRIV" -maxdepth 2 -type f \( -name '*.mp3' -o -name '*.mov' \) -exec basename {} \; 2>/dev/null)
EOF
  else
    echo "   NOTE — private reference tree not at $PRIV; basename half of this check did not run"
  fi
  if [ "$hits" -eq 0 ]; then echo "   OK — none"; else fail=1; fi
fi

echo "== 7. the shim refuses to exec itself rather than forking =="
RICHOS_WHISPER_REAL="$D/tools/whisper-rss-shim.sh" "$D/tools/whisper-rss-shim.sh" --version > /dev/null 2>/dev/null
st=$?
if [ "$st" -eq 78 ]; then echo "   OK — exit 78"; else echo "   FAIL — exit $st, expected 78"; fail=1; fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
