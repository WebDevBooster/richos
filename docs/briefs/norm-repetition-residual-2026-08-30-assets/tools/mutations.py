import subprocess, shutil, re, sys
G='lib/repetition-guard.js'; P='lib/pipeline.js'
MUT=[
 ("class-1: the 3-word veto floor put back (minWordsForBurstVeto 1 -> 3)", G, 'run',
  "  minWordsForBurstVeto: 1,", "  minWordsForBurstVeto: 3,"),
 ("class-1: the keep floor lowered below one delivery (max(1, ...) -> max(0, ...))", G, 'run',
  "      let keep = 1;", "      let keep = 0;"),
 ("class-2: an EMPTY isolated decode counted as proof of fabrication", G, 'run',
  "  if (tight === null || wide === null) {\n    return {\n      verdict: 'unprobed',",
  "  if (tight === null || wide === null) {\n    return {\n      verdict: 'fabricated',"),
 ("class-2: the numeral matched in DIGIT form only", G, 'run',
  "  const w = NUMBER_WORDS[value];\n  return w ? new RegExp(`(^|\\\\W)${w}(\\\\W|$)`).test(s) : false;",
  "  return false;"),
 ("class-2: the numeral test anchored to the HEAD of the clip", G, 'run',
  "  const s = String(text == null ? '' : text).trim().toLowerCase();\n  if (!s) return null;\n  if (new RegExp(`(^|\\\\W)${value}(\\\\W|$)`).test(s)) return true;",
  "  const s = String(text == null ? '' : text).trim().toLowerCase().split(/\\s+/).slice(0, 3).join(' ');\n  if (!s) return null;\n  if (new RegExp(`(^|\\\\W)${value}(\\\\W|$)`).test(s)) return true;"),
 ("class-2: 'spoken' requires BOTH paddings to recover the numeral, not either", G, 'run',
  "  if (tight || wide) {", "  if (tight && wide) {"),
 ("class-2: a thrown probe no longer falls back to detect-only", G, 'run',
  "    } catch {\n      // A failed probe must never look like a clean result: every marker falls back to unprobed,\n      // the text is left alone, and the report says so.\n      probes = [];\n    }",
  "    }\n    {"),
 ("class-2: the per-channel probe budget removed", G, 'run',
  "  return { probe: list.slice(0, o.insertionProbeBudget), unprobed: list.slice(o.insertionProbeBudget) };",
  "  return { probe: list, unprobed: [] };"),
 ("class-2: the channel name no longer reaches the probe", G, 'run',
  "      probes = o.probe(spans, o.channel) || [];", "      probes = o.probe(spans) || [];"),
 ("class-2: the KEPT-because-spoken warning dropped from verification.json", G, 'run',
  "    if (Number(i.keptSpoken || 0) > 0) {", "    if (false) {"),
 ("class-2: unadjudicated markers no longer warned about", G, 'run',
  "    if (Number(i.unprobed || 0) > 0) {", "    if (false) {"),
 ("class-3: the hand-off removed — the stutter class may collapse what class 1 preserved", G, 'run',
  "    if (shielded && shielded(segs[i], segs[i + 1])) {\n      link.push(0);\n      continue;\n    }", "    if (false) {}"),
 ("class-3: the hand-off widened to any segment touching a protected span", G, 'run',
  "      (p) => Number(a.startMs) >= Number(p.startMs) - 1 && Number(b.endMs) <= Number(p.endMs) + 1,",
  "      () => true,"),
 ("class-1 -> class-3 hand-off: only PRESERVED runs handed over, not clamped ones", G, 'run',
  "    ...(loop.loops || []).filter((l) => Number(l.kept) > 1).map((l) => ({ startMs: l.startMs, endMs: l.endMs })),", "  "),
 ("pipeline: stage 3.5 no longer passes a probe to the guard at all", P, 'e2e',
  "          probe: (spans, channel) => {", "          probeDisabled: (spans, channel) => {"),
 ("pipeline: the wiring flag hard-coded instead of read back from the guard", P, 'e2e',
  "      insertionProbeAvailable = repetitionReport.insertionProbe === true;", "      insertionProbeAvailable = true;"),
 ("guard: the report claims a probe reached it when none did", G, 'run',
  "      insertionProbe: typeof opts.probe === 'function',", "      insertionProbe: true,"),
]
shutil.copy(G,'/tmp/G.bak'); shutil.copy(P,'/tmp/P.bak')
out=[]
for name, f, suite, old, new in MUT:
    s=open(f).read()
    if old not in s:
        out.append((name, suite, 'MUTATION DID NOT APPLY', [])); continue
    open(f,'w').write(s.replace(old,new,1))
    script = 'test/run.js' if suite=='run' else 'test/e2e.mjs'
    r=subprocess.run(['node',script], capture_output=True, text=True)
    txt=r.stdout + '\n' + (r.stderr or '')
    if suite=='run':
        m=re.search(r'(\d+) passed, (\d+) failed', txt)
        verdict = f"{m.group(2)} check(s) RED" if m else "the suite CRASHED (the guard is load-bearing)"
        blk = txt[txt.find('FAILURES:'):] if 'FAILURES:' in txt else ''
        names=[l[2:].split(': ')[0] for l in blk.splitlines() if l.startswith('- ')]
    else:
        fails=[l[6:].split(' — ')[0] for l in txt.splitlines() if l.startswith('FAIL  ')]
        verdict = f"{len(fails)} check(s) RED" if fails else "GREEN — mutant SURVIVED"
        names=fails
    out.append((name, suite, verdict, names))
    shutil.copy('/tmp/G.bak',G); shutil.copy('/tmp/P.bak',P)
print('| # | mutation applied to the shipped source | suite | result | first check to go red |')
print('|---|---|---|---|---|')
for i,(name,suite,verdict,names) in enumerate(out,1):
    first = names[0] if names else '—'
    print(f"| {i} | {name} | `test/{'run.js' if suite=='run' else 'e2e.mjs'}` | {verdict} | {first} |")
