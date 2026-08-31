# Derives, from a probe-machinery.js raw JSONL, the three numbers this artifact rests on:
# the long tool's measured duration, every `in_progress` frame's offset from that tool's
# permission-allow, and the longest window in which NO inbound frame of any type arrived.
# Offsets are relative to the `session/prompt` send, which is the only event both the ACP
# and the native captures share a definition of.
#
#   analyse.py <raw.jsonl> [...]        -- also writes <raw>.timings.tsv next to each input
import json, sys

for path in sys.argv[1:]:
    rows = [json.loads(l) for l in open(path)]
    t0 = [r["sinceStartMs"] for r in rows
          if r["dir"] == "out" and (r.get("msg") or {}).get("method") == "session/prompt"][0]
    off = lambda r: (r["sinceStartMs"] - t0) / 1000.0

    inbound = [r for r in rows if r["dir"] == "in"]
    upd = lambda r: ((r.get("msg") or {}).get("params") or {}).get("update") or {}
    meta = lambda r: (upd(r).get("_meta") or {}).get("claudeCode") or {}

    # the long tool = the Bash tool_call whose command is the tick loop
    tick = [r for r in inbound if r.get("kind") == "tool_call"
            and "tick-$i" in json.dumps(upd(r).get("rawInput") or {})]
    # ...or, when rawInput streams in empty, the one the permission request names
    perm = [r for r in inbound if (r.get("msg") or {}).get("method") == "session/request_permission"
            and "tick-$i" in json.dumps(((r["msg"].get("params") or {}).get("toolCall") or {}).get("rawInput") or {})]
    tool_id = (((perm[0]["msg"]["params"]).get("toolCall") or {}).get("toolCallId") if perm
               else upd(tick[0]).get("toolCallId") if tick else None)
    allow_at = off(perm[0]) if perm else None
    done = [r for r in inbound if r.get("kind") == "tool_call_update"
            and upd(r).get("toolCallId") == tool_id and upd(r).get("status") == "completed"]
    prog = [r for r in inbound if r.get("kind") == "tool_call_update"
            and upd(r).get("toolCallId") == tool_id and upd(r).get("status") == "in_progress"]
    nested = bool(meta(tick[0]).get("parentToolUseId")) if tick else None

    # longest silence: consecutive inbound arrivals, after the prompt was sent
    after = [r for r in inbound if off(r) >= 0]
    gaps = [(off(b) - off(a), off(a), off(b)) for a, b in zip(after, after[1:])]
    gmax = max(gaps) if gaps else (0, 0, 0)

    print(f"=== {path}")
    print(f"  long tool           {tool_id}  nested_in_subagent={nested}")
    print(f"  permission allow    +{allow_at:.3f}s")
    if done:
        d = off(done[0]) - allow_at
        print(f"  tool completed      +{off(done[0]):.3f}s   duration {d:.3f}s "
              f"(expected 70.000s, overhead {(d-70)*1000:.0f} ms)")
    print(f"  in_progress frames  {len(prog)}")
    for i, r in enumerate(prog, 1):
        e = ((meta(r).get("toolResponse") or {}).get("elapsedTimeSeconds"))
        print(f"    #{i} at +{off(r):.3f}s  = allow+{off(r)-allow_at:.3f}s  elapsedTimeSeconds={e}")
    if len(prog) > 1:
        print(f"    measured interval   {off(prog[1])-off(prog[0]):.3f}s")
    print(f"  longest silence     {gmax[0]:.3f}s  (+{gmax[1]:.3f}s -> +{gmax[2]:.3f}s)")
    print(f"  inbound frames      {len(inbound)}")

    with open(path.replace(".jsonl", ".timings.tsv"), "w") as f:
        f.write("offset_s\tdir\tkind_or_method\ttoolCallId\tstatus\n")
        for r in rows:
            u = upd(r)
            f.write(f"{off(r):.3f}\t{r['dir']}\t{r.get('kind') or (r.get('msg') or {}).get('method') or ''}"
                    f"\t{u.get('toolCallId') or ''}\t{u.get('status') or ''}\n")
