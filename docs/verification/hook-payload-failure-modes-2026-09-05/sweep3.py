#!/usr/bin/env python3
"""Violation controls.

For each hook a payload is constructed that the hook MUST refuse. Then the
same payload is degraded three ways. The truncation is engineered so the
VIOLATING BYTES SURVIVE THE CUT and only the JSON structure is destroyed --
that is exactly the shape a bounded read produces, and it is the case the
"a payload that cannot be understood is not itself a threat" rationale
assumes away.

  violation  well-formed, must be refused
  empty      zero bytes
  truncated  violation payload cut after the violating field, JSON broken
  nonjson    prose

Nothing is inferred from source: the refusal is observed on the control.
"""
import json, os, subprocess, sys, time

HOOKS = "/Users/alex/ab/richos/engine/scripts/hooks"
SANDBOX = os.path.dirname(os.path.abspath(__file__))
FB = "/Users/alex/ab/femcboost"
RICHOS = "/Users/alex/ab/richos"
SESSION = "v3sweep00-0000-0000-0000-000000000000"
TRANSCRIPT = os.path.join(SANDBOX, "trans-violate.jsonl")

# A long benign tail. Truncation at 60% lands INSIDE this tail, so every field
# before it -- including the violation -- is present in the bytes fed to the hook.
TAIL = "z" * 4000

# The dialect fixture below is built from its component letters at run time
# rather than spelled out, so this file carries no non-American word of its own.
DIALECT_BAD = "The " + "colo" + "ur of the " + "analys" + "er is fine.\n"


def payload(root, **kw):
    d = {"session_id": SESSION, "transcript_path": TRANSCRIPT, "cwd": root}
    d.update(kw)
    d["_pad"] = TAIL
    return d


def pre(root, tool, ti, **extra):
    return payload(root, hook_event_name="PreToolUse", tool_name=tool,
                   tool_input=ti, **extra)


AWSKEY = "AKIA" + "Q7ZM4KD9TXR2VBLC"
SECRETLINE = 'aws_access_key_id = "%s"\n' % AWSKEY

CASES = [
    # (hook, entity_root, violation payload, what it must refuse)
    ("guard-worktree-isolation.sh", FB,
     pre(FB, "Agent", {"subagent_type": "clark", "name": "clark-sonnet-zz9",
                       "prompt": "Do some file work.", "description": "x"}),
     "file-writing spawn with no isolation"),

    ("guard-model-ceiling.sh", FB,
     pre(FB, "Agent", {"subagent_type": "sage", "name": "sage-fable-zz9",
                       "model": "fable", "prompt": "Design something.",
                       "description": "x", "isolation": "worktree"}),
     "spawn above the declared model ceiling"),

    ("verify-agent-prompt.sh", FB,
     pre(FB, "Agent", {"subagent_type": "mark", "name": "mark-sonnet-zz9",
                       "isolation": "worktree",
                       "prompt": "You must spawn a teammate to help you and dispatch agents as needed.",
                       "description": "x"}),
     "prompt telling a subagent to spawn agents"),

    ("guard-main-checkout-writes.sh", FB,
     pre(FB, "Write", {"file_path": os.path.join(FB, "avelor", "src", "zz.js"),
                       "content": "export const zz = 1;\n"}),
     "write to protected source in the main checkout"),

    ("scan-secrets.sh", FB,
     pre(FB, "Write", {"file_path": os.path.join(FB, "docs", "zz.md"),
                       "content": SECRETLINE}),
     "AWS-shaped credential in new content"),

    ("guard-dialect.sh", FB,
     pre(FB, "Write", {"file_path": os.path.join(FB, "docs", "zz.md"),
                       "content": DIALECT_BAD}),
     "non-American spelling in new content"),

    ("guard-interactive-prompt.sh", FB,
     pre(FB, "Bash", {"command": "security import D.p12 -k /tmp/t3.keychain-db -T /usr/bin/codesign",
                      "description": "import"}),
     "command that can wait on a human"),

    ("guard-bash-main-writes.sh", FB,
     pre(FB, "Bash", {"command": "echo x > %s/avelor/src/zz.js" % FB,
                      "description": "write"}),
     "shell write into protected source in the main checkout"),

    ("guard-worktree-removal.sh", FB,
     pre(FB, "Bash", {"command": "git worktree remove %s/.claude/worktrees/agent-a752abb3003179648 --force" % FB,
                      "description": "remove"}),
     "removal of a live agent worktree"),

    ("guard-inflight-notify.sh", FB,
     pre(FB, "Bash", {"command": "git merge --no-ff worktree-a752abb3003179648",
                      "description": "land"}),
     "land while teammates are in flight"),

    ("guard-ceo-ask-first.sh", FB,
     pre(FB, "Agent", {"subagent_type": "clark", "name": "clark-sonnet-zz8",
                       "isolation": "worktree", "prompt": "Research.", "description": "x"}),
     "dispatch before the CEO ask"),

    ("guard-workflow-ban.sh", FB,
     pre(FB, "Workflow", {"workflow": "anything"}),
     "any Workflow call"),

    ("guard-resume-isolation.sh", FB,
     pre(FB, "SendMessage", {"to": "zach-opus-st1", "message": "please make one more edit"}),
     "resume of a completed teammate"),

    ("guard-publication-writes.sh", RICHOS,
     pre(RICHOS, "Write", {"file_path": os.path.join(RICHOS, "docs", "zz.md"),
                           "content": "Transcript of the call: he said he would pay us more if we shipped by Friday.\n"}),
     "private material into a publication-bound repository"),

    ("guard-named-persons-writes.sh", RICHOS,
     pre(RICHOS, "Write", {"file_path": os.path.join(RICHOS, "docs", "zz.md"),
                           "content": "PLACEHOLDER-NAME met us on Tuesday.\n"}),
     "a named person in new content"),

    # commit-time guards: a real `git commit` command shape
    ("guard-publication-commits.sh", RICHOS,
     pre(RICHOS, "Bash", {"command": "git commit -m 'add material'", "description": "commit"}),
     "commit into a publication-bound repository"),
    ("guard-named-persons-commands.sh", RICHOS,
     pre(RICHOS, "Bash", {"command": "git commit -m 'remove PLACEHOLDER-NAME from the fixture'",
                          "description": "commit"}),
     "a named person in the commit message"),
    ("guard-ceo-todos-commits.sh", FB,
     pre(FB, "Bash", {"command": "git commit -m 'update the record'", "description": "commit"}),
     "commit that should have touched CEO TODOs"),
    ("guard-completeness-commits.sh", FB,
     pre(FB, "Bash", {"command": "git commit -m 'update the record'", "description": "commit"}),
     "incomplete publication commit"),
    ("guard-row-currency-commits.sh", FB,
     pre(FB, "Bash", {"command": "git commit -m 'land the row'", "description": "commit"}),
     "commit leaving a stale row"),
    ("guard-vendoring-commits.sh", RICHOS,
     pre(RICHOS, "Bash", {"command": "git commit -m 'vendor a library'", "description": "commit"}),
     "vendoring with no provenance record"),

    ("guard-sealed-worktree.sh", FB,
     pre(FB, "Write", {"file_path": os.path.join(FB, "docs", "zz.md"), "content": "x"},
         agent_id="anever0000000000", agent_type="zach"),
     "unsealed worker write"),

    ("guard-definition-drift.sh", FB,
     pre(FB, "Agent", {"subagent_type": "zach", "name": "zach-sonnet-zz9",
                       "isolation": "worktree", "prompt": "Do work.", "description": "x"}),
     "spawn against a drifted definition"),

    ("reader-teammate-hint.sh", FB,
     pre(FB, "Agent", {"subagent_type": "mark", "name": "mark-sonnet-zz8",
                       "isolation": "worktree",
                       "prompt": "Read all of the following documents in full and enumerate every finding from the wiki pages.",
                       "description": "x"}),
     "read-everything task given to a non-reader"),

    ("guard-ceo-ruled-ask.sh", FB,
     pre(FB, "AskUserQuestion",
         {"questions": [{"question": "Should the app use pagination for long lists?",
                         "options": [{"label": "Yes, paginate"}, {"label": "No, infinite scroll"}]}]}),
     "asking something already ruled"),
]

# Stop hooks: the trigger evidence lives in the payload's own fields.
STOP_CASES = [
    ("guard-stated-actions.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="Zach builds it tomorrow. Frank breaks it first, and I want him on it."),
     "a stated action with no matching tool call"),
    ("guard-unresolved-claims.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="I merged the branch and pushed it; the deploy succeeded."),
     "an unresolved claim of a completed action"),
    ("guard-idle-land.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="The teammate has finished. I will land it with the next batch."),
     "going idle with an unlanded handoff"),
    ("guard-agent-state-claims.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="zach-opus-st1 is completed and its worktree is gone."),
     "an agent-state claim contradicted by the lock"),
    ("notice-unasked-deferral.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="I am not spawning that right now; it goes in with the next land."),
     "a deferral the CEO never agreed to"),
    ("turn-manifest.sh",
     payload(FB, hook_event_name="Stop", stop_hook_active=False,
             prompt_id="v3prompt-0000",
             last_assistant_message="Landed at 1234abc."),
     "the turn manifest"),
]


def run(hook, root, payload_text, timeout=45):
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = root
    env["CLAUDE_PLUGIN_ROOT"] = "/Users/alex/ab/richos/engine"
    env.pop("RICHOS_ENTITY_ROOT", None)
    t0 = time.time()
    try:
        p = subprocess.run(["/bin/bash", os.path.join(HOOKS, hook)],
                           input=payload_text, capture_output=True, text=True,
                           env=env, cwd=root, timeout=timeout)
        return {"rc": p.returncode, "out": p.stdout, "err": p.stderr,
                "sec": round(time.time() - t0, 2), "timeout": False}
    except subprocess.TimeoutExpired:
        return {"rc": None, "out": "", "err": "", "sec": round(time.time() - t0, 2),
                "timeout": True}


def degrade(obj):
    full = json.dumps(obj)
    # cut inside the padding tail: everything meaningful survives, JSON does not
    cut = full[: full.index(TAIL) + 500]
    return [("violation", full), ("empty", ""), ("truncated", cut),
            ("nonjson", "the payload never arrived and this is not JSON\n")]


def main():
    with open(TRANSCRIPT, "w") as fh:
        for text in ("Zach builds it tomorrow.",
                     "I merged the branch and pushed it; the deploy succeeded."):
            fh.write(json.dumps({"type": "assistant", "promptId": "v3prompt-0000",
                                 "message": {"role": "assistant",
                                             "content": [{"type": "text", "text": text}]}}) + "\n")

    results = []
    jobs = [(h, r, p, w) for h, r, p, w in CASES] + \
           [(h, FB, p, w) for h, p, w in STOP_CASES]
    for hook, root, obj, what in jobs:
        row = {"hook": hook, "root": root, "refuses": what, "cases": {}}
        for name, text in degrade(obj):
            r = run(hook, root, text)
            row["cases"][name] = r
            print("%-34s %-10s rc=%-7s %5.2fs out=%d err=%d" % (
                hook, name, "TIMEOUT" if r["timeout"] else r["rc"],
                r["sec"], len(r["out"]), len(r["err"])), flush=True)
        results.append(row)
        print("")
    with open(os.path.join(SANDBOX, "sweep3-results.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    print("wrote sweep3-results.json (%d cases)" % len(results))


if __name__ == "__main__":
    main()
