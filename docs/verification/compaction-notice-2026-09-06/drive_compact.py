#!/usr/bin/env python3
"""Drive `claude` over the exact stream-json wire RichOS uses and TIME every frame's arrival.

Descended from `docs/verification/inner-doctrine-opens-2026-09-06/drive_asp.py` (echo-opus-q14,
itself Sage's Appendix A harness). The child argv is unchanged and still reproduces
`native.rs::child_args` verbatim. The one thing added is the thing q14's record could not
answer: WHEN each frame arrives.

  * every stdout line is stamped with milliseconds since the child was spawned, and written
    to `<out>.timed.jsonl` as {atMs, kind, type, subtype, bytes} - metadata only, no frame
    text, so the timing file needs no redaction;
  * every prompt WE send is stamped the same way (kind="send"), so a boundary can be placed
    inside or outside a turn;
  * at exit, the inter-arrival gap on each side of every `system/compact_boundary` is printed.

The question it exists to settle: does `compact_boundary` announce the START of the pause or
report the END of it? `duration_ms` inside the frame suggests the latter; a suggestion is not
a measurement.

Deliberate deviation kept from q14/Sage: `can_use_tool` is DENIED here (the app allows), so
nothing the child does can reach the filesystem during a measurement.
"""
import argparse, json, os, subprocess, sys, threading, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--cwd", required=True)
ap.add_argument("--prompt", action="append", default=[], dest="turns", type=lambda s: ("text", s))
ap.add_argument("--prompt-file", action="append", default=[], dest="turns", type=lambda s: ("file", s))
ap.add_argument("--out", required=True)
ap.add_argument("--bin", default=os.path.expanduser("~/.local/bin/claude"))
ap.add_argument("--timeout", type=float, default=600.0)
a = ap.parse_args()

if not a.turns:
    ap.error("at least one --prompt or --prompt-file is required")
prompts = [t[1] if t[0] == "text" else open(t[1]).read() for t in a.turns]

session_id = str(uuid.uuid4())
args = ["--print", "--input-format=stream-json", "--output-format=stream-json",
        "--include-partial-messages", "--verbose",
        "--setting-sources", "",
        "--no-session-persistence", "--session-id", session_id,
        "--permission-prompt-tool", "stdio"]

env = dict(os.environ)
env.pop("ANTHROPIC_API_KEY", None)

t0 = time.monotonic()


def at_ms():
    return int(round((time.monotonic() - t0) * 1000))


p = subprocess.Popen([a.bin] + args, cwd=a.cwd, env=env,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1)

raw = open(a.out, "w")
timed = open(a.out + ".timed.jsonl", "w")
timed_lock = threading.Lock()
turn_done = threading.Event()
state = {"text": "", "result": None, "denied": [], "init": None, "stderr": [], "compactions": []}
events = []


def stamp(rec):
    with timed_lock:
        events.append(rec)
        timed.write(json.dumps(rec) + "\n")
        timed.flush()


def send(obj, kind=None, note=None):
    line = json.dumps(obj)
    if kind:
        stamp({"atMs": at_ms(), "kind": kind, "note": note, "bytes": len(line)})
    p.stdin.write(line + "\n")
    p.stdin.flush()


def reader():
    for line in p.stdout:
        t_ms = at_ms()
        line = line.strip()
        if not line:
            continue
        raw.write(line + "\n")
        raw.flush()
        try:
            m = json.loads(line)
        except Exception:
            stamp({"atMs": t_ms, "kind": "frame", "type": "<unparsable>", "bytes": len(line)})
            continue
        t = m.get("type")
        sub = m.get("subtype")
        rec = {"atMs": t_ms, "kind": "frame", "type": t, "subtype": sub, "bytes": len(line)}
        if t == "stream_event":
            rec["event"] = ((m.get("event") or {}).get("type"))
        if t == "system" and sub == "compact_boundary":
            md = m.get("compact_metadata") or {}
            rec["compact_metadata"] = {k: v for k, v in md.items()
                                       if k not in ("preserved_segment", "preserved_messages")}
        stamp(rec)
        if t == "control_request" and m.get("request", {}).get("subtype") == "can_use_tool":
            state["denied"].append(m["request"].get("tool_name"))
            send({"type": "control_response", "response": {"subtype": "success",
                  "request_id": m.get("request_id"),
                  "response": {"behavior": "deny", "message": "measurement harness denies tools"}}})
        elif t == "control_response":
            turn_done.set()
        elif t == "system" and sub == "init":
            state["init"] = m
        elif t == "system" and sub == "compact_boundary":
            md = m.get("compact_metadata") or {}
            state["compactions"].append(md)
            print("[drive] t=%dms COMPACT_BOUNDARY %s" % (t_ms, json.dumps(
                {k: v for k, v in md.items() if k not in ("preserved_segment", "preserved_messages")})),
                file=sys.stderr)
        elif t == "assistant":
            for blk in m.get("message", {}).get("content", []):
                if blk.get("type") == "text":
                    state["text"] += blk["text"]
        elif t == "result":
            state["result"] = m
            turn_done.set()


def errreader():
    for line in p.stderr:
        state["stderr"].append(line.rstrip())


threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=errreader, daemon=True).start()

send({"type": "control_request", "request_id": str(uuid.uuid4()),
      "request": {"subtype": "initialize", "hooks": None}}, kind="send", note="initialize")
if not turn_done.wait(30):
    p.kill()
    print("[drive] HANDSHAKE TIMEOUT; stderr:\n%s" % "\n".join(state["stderr"]), file=sys.stderr)
    sys.exit(8)
turn_done.clear()
print("[drive] argv =", json.dumps(args), file=sys.stderr)
print("[drive] cwd  =", a.cwd, file=sys.stderr)
print("[drive] autocompact_pct_override =", os.environ.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"), file=sys.stderr)

for i, prompt in enumerate(prompts, 1):
    state["text"] = ""
    state["result"] = None
    send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": prompt}]},
          "parent_tool_use_id": None, "session_id": session_id},
         kind="send", note="turn %d prompt (%d chars)" % (i, len(prompt)))
    if not turn_done.wait(a.timeout):
        p.kill()
        print("[drive] TURN TIMEOUT on turn %d" % i, file=sys.stderr)
        sys.exit(9)
    turn_done.clear()
    r = state["result"] or {}
    shown = prompt if len(prompt) <= 160 else prompt[:160] + " ...[%d chars total]" % len(prompt)
    print("\n===== TURN %d (done at t=%dms) =====\nPROMPT: %s\nREPLY:\n%s\n"
          "[subtype=%s stop_reason=%s compactions=%d]"
          % (i, at_ms(), shown, state["text"].strip(), r.get("subtype"), r.get("stop_reason"),
             len(state["compactions"])), file=sys.stderr)

p.stdin.close()
p.wait(timeout=15)
raw.close()

# --- the measurement this harness exists for -------------------------------------------
print("\n[drive] ===== GAP ANALYSIS AROUND EVERY compact_boundary =====", file=sys.stderr)
for idx, e in enumerate(events):
    if e.get("subtype") != "compact_boundary":
        continue
    prev = events[idx - 1] if idx else None
    nxt = events[idx + 1] if idx + 1 < len(events) else None
    md = e.get("compact_metadata", {})
    dur = md.get("duration_ms")
    gap_before = e["atMs"] - prev["atMs"] if prev else None
    gap_after = nxt["atMs"] - e["atMs"] if nxt else None
    keys = ("atMs", "kind", "type", "subtype", "event", "note")
    print(json.dumps({
        "boundary_atMs": e["atMs"],
        "frame_duration_ms": dur,
        "prev_event": {k: prev.get(k) for k in keys} if prev else None,
        "gap_before_ms": gap_before,
        "next_event": {k: nxt.get(k) for k in keys} if nxt else None,
        "gap_after_ms": gap_after,
        "gap_before_minus_duration_ms": (gap_before - dur) if (gap_before is not None and dur is not None) else None,
    }), file=sys.stderr)
print("[drive] frames=%d compactions=%d wall=%dms" % (len(events), len(state["compactions"]), at_ms()),
      file=sys.stderr)
timed.close()
if state["stderr"]:
    print("[drive] child stderr:\n%s" % "\n".join(state["stderr"][-20:]), file=sys.stderr)
