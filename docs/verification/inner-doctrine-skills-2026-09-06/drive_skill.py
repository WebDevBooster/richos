#!/usr/bin/env python3
"""Drive N turns of `claude` over the exact stream-json stdio wire RichOS uses,
with an optional --append-system-prompt. Reproduces native.rs::child_args verbatim
and adds ONE flag pair as the manipulated variable.

Usage: drive_asp.py --cwd DIR [--asp TEXT] [--asp-flag NAME]
                    --prompt TEXT [--prompt TEXT ...] --out RAW.jsonl

THIS IS SAGE'S APPENDIX A HARNESS (docs/plans/richos-inner-doctrine-2026-09-06.md),
reused rather than replaced. Every line below that is not inside a block marked
`--- q14 addition ---` is his. The additions are:

  * --prompt-file PATH   a turn whose text is read from a file (the compaction filler
                         is ~40 KB and does not belong on a command line); --prompt and
                         --prompt-file interleave in the order given.
  * compact_boundary     `system/compact_boundary` frames are captured and printed, with
                         their trigger and pre/post token counts. That frame is the
                         machine-readable proof that a compaction event occurred; without
                         it "the doctrine survived" would be unfalsifiable, because a run
                         that never compacted also survives.
  * per-turn usage       the `result` frame's usage is printed so context growth is visible.

--- dr1 additions, for the SKILL question -------------------------------------------------

  * --extra-arg ARG      an extra flag pair appended to the production vector, repeatable,
                         so `--plugin-dir <path>` can be the manipulated variable exactly the
                         way `--append-system-prompt-file` was.
  * --allow-tool NAME    tools are still DENIED by default, but the named ones are ALLOWED.
                         This matters and is not a convenience: a skill is invoked THROUGH the
                         `Skill` tool, so a harness that denies every tool cannot tell "the
                         skill was never found" from "found, and the harness refused the only
                         way to reach it". `native.rs::decide_permission` allows everything in
                         production, so allowing `Skill` is the closer reproduction; every
                         other tool stays denied, which keeps the property that no child can
                         read a sentinel off disk and hand it back.
  * init.skills          the `system/init` frame carries `skills`, `plugins` and `agents`
                         arrays. THAT is the discriminator this whole probe hangs on: whether
                         a skill was DISCOVERED is a fact on the wire, not an inference from
                         whether the model happened to use it.

The one deliberate deviation from the app is his and is kept: native.rs::decide_permission
ALLOWS every `can_use_tool`; this harness DENIES, so no child can read a sentinel off disk
with a tool and hand it back.
"""
import argparse, json, os, subprocess, sys, threading, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--cwd", required=True)
ap.add_argument("--asp", default=None)
ap.add_argument("--asp-flag", default="--append-system-prompt")
# --- q14 addition: prompts may come from files, and must keep their relative order ---
ap.add_argument("--prompt", action="append", default=[], dest="turns",
                type=lambda s: ("text", s))
ap.add_argument("--prompt-file", action="append", default=[], dest="turns",
                type=lambda s: ("file", s))
# --- end q14 addition ---
# --- q14 addition: build the CHILD's environment explicitly, for the runner simulation.
# Done here rather than with `env -i HOME=... ` in the shell so that this session's own
# HOME is never rewritten (the worktree-isolation guard refuses that, correctly). ---
ap.add_argument("--empty-env", action="store_true",
                help="child gets ONLY PATH plus whatever --child-env supplies")
ap.add_argument("--child-env", action="append", default=[], metavar="KEY=VALUE")
# --- end q14 addition ---
# --- dr1 additions ---
ap.add_argument("--extra-arg", action="append", default=[], metavar="ARG")
ap.add_argument("--sources", default="", help="the --setting-sources VALUE; '' is production")
ap.add_argument("--allow-tool", action="append", default=[], metavar="NAME")
# --- end dr1 additions ---
ap.add_argument("--out", required=True)
ap.add_argument("--bin", default=os.path.expanduser("~/.local/bin/claude"))
ap.add_argument("--timeout", type=float, default=180.0)
a = ap.parse_args()

# --- q14 addition: resolve file turns to text ---
if not a.turns:
    ap.error("at least one --prompt or --prompt-file is required")
prompts = [t[1] if t[0] == "text" else open(t[1]).read() for t in a.turns]
# --- end q14 addition ---

session_id = str(uuid.uuid4())
args = ["--print", "--input-format=stream-json", "--output-format=stream-json",
        "--include-partial-messages", "--verbose",
        "--setting-sources", a.sources,   # dr1: '' is production; overridable for controls
        "--no-session-persistence", "--session-id", session_id,
        "--permission-prompt-tool", "stdio"]
if a.asp is not None:
    args += [a.asp_flag, a.asp]
# --- dr1 addition: the manipulated variable for the skill cells ---
args += a.extra_arg
# --- end dr1 addition ---

env = dict(os.environ)
env.pop("ANTHROPIC_API_KEY", None)
# --- q14 addition ---
if a.empty_env:
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
for kv in a.child_env:
    k, _, v = kv.partition("=")
    env[k] = v
print("[drive] child env keys =", sorted(env), file=sys.stderr)
# --- end q14 addition ---
p = subprocess.Popen([a.bin] + args, cwd=a.cwd, env=env,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1)

raw = open(a.out, "w")
turn_done = threading.Event()
state = {"text": "", "result": None, "denied": [], "allowed": [], "init": None, "stderr": [],
         "compactions": []}   # q14 addition: compactions; dr1 addition: allowed

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def reader():
    for line in p.stdout:
        line = line.strip()
        if not line:
            continue
        raw.write(line + "\n"); raw.flush()
        try:
            m = json.loads(line)
        except Exception:
            continue
        t = m.get("type")
        if t == "control_request" and m.get("request", {}).get("subtype") == "can_use_tool":
            # --- dr1 addition: named tools are ALLOWED; everything else is still denied ---
            name = m["request"].get("tool_name")
            if name in a.allow_tool:
                state["allowed"].append(name)
                send({"type": "control_response", "response": {"subtype": "success",
                      "request_id": m.get("request_id"),
                      "response": {"behavior": "allow",
                                   "updatedInput": m["request"].get("input") or {}}}})
            else:
                state["denied"].append(name)
                send({"type": "control_response", "response": {"subtype": "success",
                      "request_id": m.get("request_id"),
                      "response": {"behavior": "deny", "message": "measurement harness denies tools"}}})
            # --- end dr1 addition ---
        elif t == "control_response":
            turn_done.set()
        elif t == "system" and m.get("subtype") == "init":
            state["init"] = m
        # --- q14 addition: the positive signal that a compaction actually happened ---
        elif t == "system" and m.get("subtype") == "compact_boundary":
            md = m.get("compact_metadata") or m.get("compactMetadata") or {}
            state["compactions"].append(md)
            print("[drive] COMPACT_BOUNDARY %s" % json.dumps(md), file=sys.stderr)
        # --- end q14 addition ---
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
      "request": {"subtype": "initialize", "hooks": None}})
if not turn_done.wait(30):
    p.kill()
    print("[drive] HANDSHAKE TIMEOUT; stderr:\n%s" % "\n".join(state["stderr"]), file=sys.stderr)
    sys.exit(8)
turn_done.clear()
print("[drive] argv =", json.dumps(args), file=sys.stderr)
print("[drive] cwd  =", a.cwd, file=sys.stderr)
# --- q14 addition: on 2.1.263 the `system/init` frame arrives with the FIRST TURN, not
# with the handshake reply, so reading it here raises AttributeError on None. Printed
# after the first turn instead (see the loop below). Model and override recorded too. ---
print("[drive] autocompact_pct_override =",
      os.environ.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"), file=sys.stderr)
init_printed = False
# --- end q14 addition ---

for i, prompt in enumerate(prompts, 1):
    state["text"] = ""; state["result"] = None
    send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": prompt}]},
          "parent_tool_use_id": None, "session_id": session_id})
    if not turn_done.wait(a.timeout):
        p.kill()
        print("[drive] TURN TIMEOUT on turn %d" % i, file=sys.stderr)
        sys.exit(9)
    turn_done.clear()
    # --- q14 addition: the init frame lands with the first turn ---
    if not init_printed and state["init"] is not None:
        print("[drive] memory_paths =", json.dumps(state["init"].get("memory_paths")), file=sys.stderr)
        # --- dr1 addition: the discriminator ---
        for k in ("skills", "plugins", "agents"):
            print("[drive] init.%s = %s" % (k, json.dumps(state["init"].get(k))), file=sys.stderr)
        # --- end dr1 addition ---
        print("[drive] model =", json.dumps(state["init"].get("model")), file=sys.stderr)
        print("[drive] cwd(init) =", json.dumps(state["init"].get("cwd")), file=sys.stderr)
        init_printed = True
    # --- end q14 addition ---
    r = state["result"] or {}
    # --- q14 addition: prompts are up to 40 KB here, so echo a bounded preview + usage ---
    shown = prompt if len(prompt) <= 200 else prompt[:200] + " …[%d chars total]" % len(prompt)
    usage = (r.get("usage") or {})
    print("\n===== TURN %d =====\nPROMPT: %s\nREPLY:\n%s\n"
          "[subtype=%s stop_reason=%s tools_denied=%s in=%s cache_read=%s cache_write=%s out=%s compactions=%d]"
          % (i, shown, state["text"].strip(), r.get("subtype"), r.get("stop_reason"),
             state["denied"], usage.get("input_tokens"), usage.get("cache_read_input_tokens"),
             usage.get("cache_creation_input_tokens"), usage.get("output_tokens"),
             len(state["compactions"])),
          file=sys.stderr)
    # --- end q14 addition ---

p.stdin.close()
p.wait(timeout=15)
raw.close()
# --- q14 addition ---
print("[drive] compactions =", json.dumps(state["compactions"]), file=sys.stderr)
if state["stderr"]:
    print("[drive] stderr tail:\n%s" % "\n".join(state["stderr"][-10:]), file=sys.stderr)
# --- end q14 addition ---
