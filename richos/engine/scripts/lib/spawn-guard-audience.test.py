#!/usr/bin/env python3
"""spawn-guard-audience.test.py — THE TEST THAT PROVES THE LIST.

The declaration's whole value is that it is COMPLETE and that it AGREES with
the guards actually registered. A classification with a hole in it is worse
than none: the app's allowlist would quietly drop a real user-work guard, and
nothing would say so. So this suite drives the SHIPPED declaration and the
SHIPPED hooks.json, in both directions, and it goes red on either kind of
disagreement.

It also holds the user-facing half to the standard the CEO set for every string
a person reads (§57, American English, no operator vocabulary), because a
sentence that leaks an acknowledgement line to a non-technical user is the
defect this whole slice exists to remove, just moved one file along.

Run:  python3 scripts/lib/spawn-guard-audience.test.py
"""
import importlib.util
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
ENGINE = os.path.dirname(os.path.dirname(HERE))


def load_module():
    spec = importlib.util.spec_from_file_location(
        "spawn_guard_audience", os.path.join(HERE, "spawn-guard-audience.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


A = load_module()
FAILURES = []
CASES = [0]


def check(name, condition, detail=""):
    CASES[0] += 1
    if condition:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s%s" % (name, ("\n       " + detail) if detail else ""))
        FAILURES.append(name)


def registered_agent_guards():
    """Every PreToolUse hook a real `Agent` call would run, read from the
    engine's own hooks.json with the SAME matcher rule spawn.py uses — a
    matcherless group matches every tool, so guard-sealed-worktree.sh is in
    this set and must be classified like the rest."""
    with open(os.path.join(ENGINE, "hooks", "hooks.json"), encoding="utf-8") as handle:
        data = json.load(handle)
    out = []
    for group in (data.get("hooks") or {}).get("PreToolUse", []):
        matcher = group.get("matcher")
        if matcher is not None:
            matcher = str(matcher).strip()
            if matcher not in ("", "*"):
                try:
                    if not re.search(matcher, "Agent"):
                        continue
                except re.error:
                    if matcher != "Agent":
                        continue
        for hook in group.get("hooks") or []:
            name = A.guard_file_name(hook.get("command"))
            if name and name not in out:
                out.append(name)
    return out


def write_declaration(body):
    handle = tempfile.NamedTemporaryFile("w", suffix=".declaration", delete=False)
    handle.write(body)
    handle.close()
    return handle.name


def refused(path):
    try:
        A.load(path)
        return False
    except A.DeclarationError:
        return True


# ---------------------------------------------------------------------------
# 1. THE SHIPPED DECLARATION PARSES, AND SAYS WHAT IT CLAIMS TO SAY
# ---------------------------------------------------------------------------
print("1. the shipped declaration")
rows = A.load()
check("1a it parses and declares at least one guard", len(rows) > 0)
check("1b every row is on exactly one of the two sides",
      all(row["audience"] in A.AUDIENCES for row in rows))
check("1c no guard is declared twice",
      len({row["id"] for row in rows}) == len(rows))
check("1d both sides are populated, so neither list is vacuously satisfied",
      A.user_work_ids() and A.operator_session_ids())

# ---------------------------------------------------------------------------
# 2. COMPLETENESS, IN BOTH DIRECTIONS — the case this file exists for
# ---------------------------------------------------------------------------
print("2. completeness against the engine's own hooks.json")
registered = registered_agent_guards()
declared = [row["id"] for row in rows]
check("2a hooks.json registers at least one PreToolUse[Agent] guard", len(registered) > 0,
      "found none, which would make every check below pass for the wrong reason")
undeclared = [name for name in registered if name not in declared]
check("2b every registered guard is classified", not undeclared,
      "undeclared, so the app would silently never run it: %s" % ", ".join(undeclared))
unregistered = [name for name in declared if name not in registered]
check("2c every classified guard is registered", not unregistered,
      "declared but registered nowhere, so the classification is stale: %s"
      % ", ".join(unregistered))

# ---------------------------------------------------------------------------
# 3. THE USER-FACING HALF IS THE APP'S OWN WORDS
# ---------------------------------------------------------------------------
print("3. the app's own words")
# Operator vocabulary, spelled out rather than gestured at. Each of these has
# appeared in a real guard refusal on this machine, and none of them means
# anything to the person the app is for.
OPERATOR_WORDS = re.compile(
    r"(-ack:|\back\b|acknowledg|spawn|worktree|guard|hook|repo\b|repository|branch|commit|"
    r"\bCI\b|staging|deploy|orchestrator|teammate|subagent|payload|PreToolUse|stderr|exit code|"
    r"\bSHA\b|merge|dispatch)", re.IGNORECASE)
FILE_NAME = re.compile(r"\S+\.(sh|py|json|md|jsonl)\b")
# American English. Every word here is one this project has actually had to fix
# in its own text, which is why the list is these and not a dictionary.
NOT_AMERICAN = re.compile(  # dialect-exempt: this pattern IS the dictionary of forms to reject
    r"\b(cancelled|behaviour|colour|organis|recognis|authoris|"  # dialect-exempt: the detector's own word list
    r"whilst|initialis|licence|centre)\w*\b", re.IGNORECASE)     # dialect-exempt: the detector's own word list
for row in rows:
    if row["audience"] != A.USER_WORK:
        continue
    message = row["user_message"]
    leak = OPERATOR_WORDS.search(message)
    check("3a[%s] says nothing only an operator would understand" % row["id"], not leak,
          "found %r in: %s" % (leak.group(0) if leak else "", message))
    named = FILE_NAME.search(message)
    check("3b[%s] names no file" % row["id"], not named,
          "found %r" % (named.group(0) if named else ""))
    check("3c[%s] is American English" % row["id"], not NOT_AMERICAN.search(message), message)
    check("3d[%s] says nothing was created" % row["id"],
          "nothing was created" in message.lower() or "nothing was changed" in message.lower(),
          "a refusal a user can see must say the work did not start: %s" % message)
    check("3e[%s] is short enough to be read out" % row["id"], 0 < len(message) <= 200, message)

# ---------------------------------------------------------------------------
# 4. NEGATIVE CONTROLS — every rule above can actually go red
# ---------------------------------------------------------------------------
print("4. negative controls")
BAD = [
    ("4a an unknown audience is refused",
     "id: g.sh\naudience: whatever\nreason: r\nuser_message: m\n"),
    ("4b a user-work row with no user_message is refused",
     "id: g.sh\naudience: user-work\nreason: r\n"),
    ("4c an operator-session row WITH a user_message is refused",
     "id: g.sh\naudience: operator-session\nreason: r\nuser_message: m\n"),
    ("4d a row with no reason is refused",
     "id: g.sh\naudience: user-work\nuser_message: m\n"),
    ("4e the same guard on both sides is refused",
     "id: g.sh\naudience: user-work\nreason: r\nuser_message: m\n\n"
     "id: g.sh\naudience: operator-session\nreason: r\n"),
    ("4f a line that is not `key: value` is refused",
     "id: g.sh\nthis is not a record\naudience: user-work\nreason: r\nuser_message: m\n"),
    ("4g an empty declaration is refused", "# nothing here\n"),
]
for name, body in BAD:
    path = write_declaration(body)
    try:
        check(name, refused(path), "it was accepted")
    finally:
        os.unlink(path)

path = write_declaration("id: a.sh\naudience: user-work\nreason: r\nuser_message: Nothing was created.\n")
try:
    check("4h a well-formed declaration is accepted", A.load(path)[0]["id"] == "a.sh")
    check("4i classify answers for a declared guard", A.classify("a.sh", path) == A.USER_WORK)
    check("4j classify answers None for an undeclared guard", A.classify("b.sh", path) is None)
finally:
    os.unlink(path)
check("4k a missing declaration raises, never an empty allowlist",
      refused(os.path.join(ENGINE, "no-such-file.declaration")))

# ---------------------------------------------------------------------------
# 5. THE COMMAND NAME RULE AGREES WITH spawn.py's
# ---------------------------------------------------------------------------
print("5. the join between a registered command and a declared id")
check("5a a plugin-root command resolves to the file name",
      A.guard_file_name("bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-owned-state.sh")
      == "guard-owned-state.sh")
check("5b a quoted absolute command resolves to the file name",
      A.guard_file_name("/bin/bash '/tmp/engine/scripts/hooks/guard-brief-scope.sh'")
      == "guard-brief-scope.sh")

print("")
print("%d case(s), %d failure(s)" % (CASES[0], len(FAILURES)))
sys.exit(1 if FAILURES else 0)
