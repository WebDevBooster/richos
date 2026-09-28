#!/usr/bin/env python3
"""record_owner.py: which side of the cut-over is making this call.

Daily-driver plan step 8 ("one writer at cut-over"); two-installs spec points
25-27. Once the record's owner line says the RichOS app owns his record and his
memory, his plain terminal is refused a landing in the record and a write into
his memory directory. The app's own operator lead runs the SAME engine hooks, so
the hooks must tell the two apart. This file is that question and nothing else.

THE SIGNAL, AND WHY IT IS NOT A GUESS. The answer is the platform's own session
record for the nearest Claude process in this call's ancestry, the same identity
the operator claim already uses (operator_leads.is_terminal, Frank G11):

  * found by ANCESTRY, pid plus the kernel's start time (operator_fences.proc),
    never by a process name, a path or a working directory;
  * the record is written by Claude Code itself at launch, and its `entrypoint`
    says how that process was started: `cli` (or an IDE/desktop entrypoint) for
    an interactive terminal, `sdk-*` for a process driven through the SDK, which
    is how the app starts its leads;
  * a stale record cannot match: its recorded start time must agree with the
    kernel's to within a second; CLAUDE_PID, when set, must agree too.

No environment variable a person sets, no name and no cwd decides it, so it
cannot be flipped by accident. The one shape it cannot tell apart is a print-
mode `claude -p` started by hand from a terminal's shell: that records `sdk-cli`
and is counted as not-the-terminal, the same accepted limit as the claim's.

  record_owner.py caller           -> "terminal\\t<detail>" | "app\\t<detail>" |
                                      "unknown\\t<reason>"      (exit 0)
  record_owner.py inside <dir> <path>  exit 0 when <path> is <dir> or under it,
                                       both resolved physically (a Write names a
                                       file that may not exist yet); 1 otherwise
  record_owner.py memory-guard <memory dir> <declaration file>   (payload on stdin)
                                   exit 2 with the refusal on stderr when a Write
                                   tool targets the memory directory and the
                                   caller is not the app; exit 0 otherwise
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import operator_fences as OF  # noqa: E402  (the one shared process identity)
import operator_leads as OL   # noqa: E402  (entrypoint_of, realish, inside)


def caller():
    who = OF.claude_session()
    if not who:
        return "unknown", "no Claude session record matches any process in this call's ancestry"
    if "error" in who:
        return "unknown", who["error"]
    entry = OL.entrypoint_of(who)
    if not entry:
        return "unknown", "the session record of process %s carries no entrypoint" % who.get("pid")
    detail = "process %s, entrypoint %s" % (who.get("pid"), entry)
    if entry.startswith("sdk-"):
        return "app", detail
    return "terminal", detail


def expand(path):
    if path.startswith("~/"):
        return os.path.join(os.path.expanduser("~"), path[2:])
    return path


def memory_guard(memory_dir, declaration, payload):
    """0 = pass, 2 = refused (message on stderr). Reached only when the owner
    line says the app owns the record, so every exit here is about that."""
    if not isinstance(payload, dict) or payload.get("tool_name") not in OL.WRITE_TOOLS:
        return 0
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    path = OL.target_path(tool_input)
    if not path or not memory_dir:
        return 0
    if not OL.inside(OL.realish(expand(path)), OL.realish(expand(memory_dir))):
        return 0
    side, detail = caller()
    if side == "app":
        return 0
    who = ("this terminal (%s)" % detail) if side == "terminal" else ("could not be identified (%s)" % detail)
    sys.stderr.write(
        "=== THE RICHOS APP OWNS HIS MEMORY — REFUSING THIS WRITE ===\n"
        "  file       : %s\n"
        "  memory     : %s\n"
        "  owner line : ROW_RECORD_OWNER in %s\n"
        "  caller     : %s\n"
        "\n"
        "  Since the cut-over the app keeps his memory, and the terminal does not\n"
        "  write it: a line written here now would be read by nothing. Tell the app.\n"
        "  To give his memory back to the terminal, run record-owner.sh off (or\n"
        "  delete that one line); this write then goes through.\n"
        "(hook: scripts/hooks/guard-record-owner-memory.sh)\n"
        % (path, memory_dir, declaration or "the record's .row-currency", who))
    return 2


def main(argv):
    if argv[:1] == ["memory-guard"] and len(argv) == 3:
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            return 0    # not a payload this guard can read; the notice layer names that
        return memory_guard(argv[1], argv[2], payload)
    if argv[:1] == ["caller"]:
        side, detail = caller()
        sys.stdout.write("%s\t%s\n" % (side, detail))
        return 0
    if argv[:1] == ["inside"] and len(argv) == 3:
        directory, path = expand(argv[1]), expand(argv[2])
        if not directory or not path:
            return 1
        return 0 if OL.inside(OL.realish(path), OL.realish(directory)) else 1
    sys.stderr.write("usage: record_owner.py caller | inside <dir> <path>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
