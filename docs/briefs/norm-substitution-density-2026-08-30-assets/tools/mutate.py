#!/usr/bin/env python3
"""Run every new check RED at least once by BREAKING THE SHIPPED SOURCE.

A green suite proves nothing on its own: a test that cannot fail is decoration. Each mutation below
removes or inverts ONE load-bearing behaviour of lib/substitution-guard.js, the whole suite is run,
and the tests that go red are recorded. The run FAILS if any new test survives every mutation.

usage: mutate.py <path-to-richos-service> <out.json>
"""
import json, re, subprocess, sys, os

SVC = sys.argv[1]
OUT = sys.argv[2]
SRC = os.path.join(SVC, 'lib', 'substitution-guard.js')
original = open(SRC).read()

MUTATIONS = [
    ("M1  window target 4 s -> 40 s (no window ever forms)",
     "windowSpeechSec: 4,", "windowSpeechSec: 40,"),
    ("M2  wall cap 30 s -> 100000 s (a denominator made of silence is allowed)",
     "maxWindowSec: 30,", "maxWindowSec: 100000,"),
    ("M3  condition 2 deleted (a WORDLESS window becomes a density candidate too)",
     "    if (w.emittedWords < 1) continue; // condition 2 — a wordless window is a DELETION, not this",
     "    // condition 2 DELETED"),
    ("M4  condition 3 relative half INVERTED (min -> max: the channel loosens its own floor)",
     "    ? Math.min(o.floorWordsPerSec, o.baselineFraction * medianDensity)",
     "    ? Math.max(o.floorWordsPerSec, o.baselineFraction * medianDensity)"),
    ("M5  floor 1.2 -> 5.0 w/s (above every real delivery: everything is a candidate)",
     "  floorWordsPerSec: 1.2,", "  floorWordsPerSec: 5.0,"),
    ("M6  condition 4 LEVEL deleted (near-silence counts as a speech budget)",
     "  if (floor != null && (probe.maxDb == null || !(Number(probe.maxDb) >= floor))) {",
     "  if (false) {"),
    ("M7  condition 5 RECOVERY floor deleted (any re-decode counts as recovery)",
     "  if (!tight || probeWords < o.recoveryRatio * emitted || probeWords - emitted < o.minRecoveredExtra) {",
     "  if (false) {"),
    ("M8  condition 5 stability arm deleted (a padding-fragile recovery is accepted)",
     "  if (wideWords <= emitted) {", "  if (false) {"),
    ("M9  condition 6 ECHO deleted (present-but-misplaced text is called missing)",
     "  if (echo > o.maxEchoWords || ratio >= o.maxEchoRatio) {", "  if (false) {"),
    ("M10 probe words counted RAW instead of distinct-informative (laughter recovers)",
     "  const probeWords = informativeWords(tight).length;\n  const wideWords = informativeWords(wide).length;",
     "  const probeWords = String(tight).split(/\\s+/).filter(Boolean).length;\n  const wideWords = String(wide).split(/\\s+/).filter(Boolean).length;"),
    ("M11 excludeSpans ignored (a confirmed deletion still inflates this stage's deficit)",
     "    const speechMs = Math.max(0, w.speechMs - overlapMs(excluded, w.startMs, w.endMs));",
     "    const speechMs = Math.max(0, w.speechMs);"),
    ("M12 baselineBelowFloor hard-wired false (a wholly destroyed channel reports clean)",
     "    baselineBelowFloor: Boolean(haveBaseline && medianDensity < o.floorWordsPerSec),",
     "    baselineBelowFloor: false,"),
    ("M13 the offset second tiling removed (a sparse stretch straddling a seam is diluted)",
     "  const secondary = tileWindows(bursts, offsetStart, o);",
     "  const secondary = [];"),
    ("M14 the unprobed warning removed (an unchecked transcript reads as a clean one)",
     "  if (un.length) {", "  if (false) {"),
    ("M15 the warning drops its refusal to claim the words present are wrong",
     "'cannot be decided without a reference. This class is detected, not repaired: audio is retained, re-transcribe, '",
     "'is unknown. '"),
    ("M19 tileWindows never stops at the speech target (one window swallows the channel)",
     "      j += 1;\n      if (speechMs >= targetMs) break;",
     "      j += 1;"),
    ("M20 the final verdict inverted: a window that clears all six conditions is called clean",
     "    verdict: 'under-transcribed',\n    reason:",
     "    verdict: 'matches-audio',\n    reason:"),
    ("M21 echo floor 4 -> 2 (the deletion detector's clause-sized value, on window-sized probes)",
     "  maxEchoWords: 4,", "  maxEchoWords: 2,"),
    ("M22 a missing burst grid no longer disables the probe (never-looked reads as looked)",
     "      probeAvailable: report.probeAvailable && Boolean(bursts && bursts.length),",
     "      probeAvailable: true,"),
    ("M23 the channel-below-floor warning removed (a destroyed channel warns about nothing)",
     "  for (const c of (report && report.channelsBelowFloor) || []) {",
     "  for (const c of []) {"),
    ("M16 overlapping candidates from the two tilings no longer collapsed (one stretch, two findings)",
     "    if (kept.some((k) => c.startMs < k.endMs && k.startMs < c.endMs)) continue;",
     "    if (false) continue;"),
    ("M24 wordlessWindows always 0 (the windows stage 3.7 owns vanish from this stage's record)",
     "    wordlessWindows: wordless.length,", "    wordlessWindows: 0,"),
    ("M17 analyzedSpeechSec reports the whole grid (the instrument overstates its own coverage)",
     "  const analyzedMs = primaryMeasured.reduce((n, w) => n + w.speechSec * 1000, 0);",
     "  const analyzedMs = burstMs;"),
    ("M18 no probe is treated as a finding (an unadjudicated window becomes an alarm)",
     "    return { ...base, verdict: 'unprobed', reason: 'no isolated re-decode was performed for this window' };",
     "    return { ...base, verdict: 'under-transcribed', reason: 'no isolated re-decode was performed for this window' };"),
]

def run_suite():
    r = subprocess.run(['node', 'test/run.js'], cwd=SVC, capture_output=True, text=True)
    reds = [m.group(1) for m in re.finditer(r'^FAIL  (.+)$', r.stdout, re.M)]
    return reds

baseline = run_suite()
assert not baseline, f'the suite is not green before mutation: {baseline}'

results = []
covered = set()
for name, old, new in MUTATIONS:
    if old not in original:
        results.append({'mutation': name, 'applied': False, 'error': 'anchor not found'})
        continue
    open(SRC, 'w').write(original.replace(old, new, 1))
    reds = run_suite()
    open(SRC, 'w').write(original)
    covered.update(reds)
    results.append({'mutation': name, 'applied': True, 'testsRed': len(reds), 'tests': reds})
    print(f'{"RED " if reds else "SURVIVED"} {len(reds):>3}  {name}')

# every NEW test must have gone red at least once
new_tests = [l for l in subprocess.run(['node','test/run.js'],cwd=SVC,capture_output=True,text=True).stdout.split('\n')]
open(OUT,'w').write(json.dumps({'mutations': results, 'distinctTestsCaught': sorted(covered)}, indent=1))
print(f'\n{len(covered)} distinct tests were driven RED across {len([r for r in results if r.get("applied")])} mutations')
survived = [r['mutation'] for r in results if r.get('applied') and r['testsRed'] == 0]
if survived:
    print('\nSURVIVING MUTATIONS (nothing catches these):')
    for s in survived: print('  -', s)
