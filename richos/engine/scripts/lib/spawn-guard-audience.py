#!/usr/bin/env python3
"""The classification in `spawn-guard-audience.declaration`, parsed once.

WHOSE WORK DOES A SPAWN GUARD'S REASON PROTECT? `user-work` (the app user's own
work on the app user's own machine) or `operator-session` (the development
session's standing systems, ledgers and conventions). The declaration is the
answer; this file is the only thing that reads it, and every consumer reads it
through here.

WHY A PARSER AND NOT A `grep`. Every consumer needs the same three things — the
allowlist, the classification of one guard, and the sentence the app says when
a user-work guard refuses — and a consumer that re-derives any of them from the
text derives a second answer that can drift from the first. That is the exact
failure the declaration was written to end, so it is not reintroduced in the
reader.

FAIL LOUD, NEVER OPEN. A declaration that cannot be read, or that contradicts
itself, raises. There is no "assume it is fine" branch: the whole point is that
the app's guard surface is a declared list, and an unreadable list is not a
list. `spawn.py` and `app-engine-hook.py` both turn that into a refusal of the
dispatch, which is the safe direction — nothing is created.

CLI, for the shell and for anything that would rather not import Python:

    spawn-guard-audience.py list --audience user-work [--declaration PATH]
    spawn-guard-audience.py classify <guard-file-name>
    spawn-guard-audience.py message <guard-file-name>
    spawn-guard-audience.py json
"""
import json
import os
import sys

USER_WORK = "user-work"
OPERATOR_SESSION = "operator-session"
AUDIENCES = (USER_WORK, OPERATOR_SESSION)

ENGINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
DEFAULT_DECLARATION = os.path.join(ENGINE, "spawn-guard-audience.declaration")


class DeclarationError(Exception):
    """The declaration is missing, unreadable or self-contradictory."""


def _records(path):
    """Blank-line-separated `key: value` records, `#` comments, one line per
    value — the same format `owned-systems.declaration` uses, parsed the same
    way, deliberately: two declaration formats in one engine is one format too
    many."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise DeclarationError("%s could not be read: %s" % (path, exc))
    out, current, first_line = [], {}, 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if line.startswith("#"):
            continue
        if not line.strip():
            if current:
                out.append((current, first_line))
                current, first_line = {}, 0
            continue
        if ":" not in line:
            raise DeclarationError(
                "%s line %d is neither a comment, a blank line nor `key: value`: %r"
                % (path, lineno, raw))
        key, value = line.split(":", 1)
        if not current:
            first_line = lineno
        current[key.strip()] = value.strip()
    if current:
        out.append((current, first_line))
    return out


def load(path=None):
    """[{id, audience, reason, user_message}] in declaration order.

    Every row is validated HERE rather than at each consumer, so a malformed
    declaration is one error message in one place."""
    path = path or os.environ.get("RICHOS_SPAWN_GUARD_AUDIENCE") or DEFAULT_DECLARATION
    rows, seen = [], {}
    for record, lineno in _records(path):
        for required in ("id", "audience", "reason"):
            if not record.get(required):
                raise DeclarationError(
                    "%s: the record at line %d has no `%s:`; a guard that cannot be "
                    "classified must be fixed, never silently dropped" % (path, lineno, required))
        name, audience = record["id"], record["audience"]
        if audience not in AUDIENCES:
            raise DeclarationError(
                "%s line %d: `audience: %s` is not one of %s"
                % (path, lineno, audience, " or ".join(AUDIENCES)))
        if name in seen:
            raise DeclarationError(
                "%s line %d: %s is declared twice (first at line %d); one guard, one side"
                % (path, lineno, name, seen[name]))
        seen[name] = lineno
        message = record.get("user_message", "")
        # REQUIRED on one side and REFUSED on the other, because both halves are
        # load-bearing: a user-work guard with no sentence would fall back to the
        # guard's own operator-worded output, and an operator-session guard WITH a
        # sentence is somebody quietly planning to show one to a user.
        if audience == USER_WORK and not message:
            raise DeclarationError(
                "%s line %d: %s is user-work and has no `user_message:` — a guard the app "
                "runs must carry the app's own words for its refusal" % (path, lineno, name))
        if audience == OPERATOR_SESSION and message:
            raise DeclarationError(
                "%s line %d: %s is operator-session and carries a `user_message:` — the app "
                "never runs it, so a user can never see one" % (path, lineno, name))
        rows.append({"id": name, "audience": audience, "reason": record["reason"],
                     "user_message": message})
    if not rows:
        raise DeclarationError("%s declares no guard at all" % path)
    return rows


def guard_file_name(command):
    """The declaration's `id` for a registered hook command.

    hooks.json registers a guard as a whole shell line — `bash
    ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-owned-state.sh` — and the
    declaration keys on the file name. The LAST `.sh`/`.py` token is the
    program, which is the same rule `spawn.py:guard_name` already uses; they
    agree on purpose, and the completeness test proves they agree on the real
    hooks.json rather than asserting it."""
    import re
    found = re.findall(r"[^\s/'\"]+\.(?:sh|py)", command or "")
    return found[-1] if found else (command or "").strip()


def user_work_ids(path=None):
    return [row["id"] for row in load(path) if row["audience"] == USER_WORK]


def operator_session_ids(path=None):
    return [row["id"] for row in load(path) if row["audience"] == OPERATOR_SESSION]


def classify(name, path=None):
    """`user-work`, `operator-session`, or None for a guard nobody declared.

    None is the UNCLASSIFIED case and it is not an error here: the decision
    about what to do with it belongs to the caller, and the declaration states
    it — the app does not run an undeclared guard, and the completeness test
    makes an undeclared guard impossible to land."""
    for row in load(path):
        if row["id"] == name:
            return row["audience"]
    return None


def user_message(name, path=None):
    for row in load(path):
        if row["id"] == name:
            return row["user_message"]
    return ""


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    command, rest = argv[0], argv[1:]
    path = None
    if "--declaration" in rest:
        index = rest.index("--declaration")
        if index + 1 >= len(rest):
            sys.stderr.write("--declaration needs a value\n")
            return 2
        path = rest[index + 1]
        rest = rest[:index] + rest[index + 2:]
    try:
        if command == "list":
            audience = USER_WORK
            if "--audience" in rest:
                index = rest.index("--audience")
                if index + 1 >= len(rest):
                    sys.stderr.write("--audience needs a value\n")
                    return 2
                audience = rest[index + 1]
            if audience not in AUDIENCES:
                sys.stderr.write("--audience must be one of %s\n" % " ".join(AUDIENCES))
                return 2
            for row in load(path):
                if row["audience"] == audience:
                    print(row["id"])
            return 0
        if command == "classify":
            if not rest:
                sys.stderr.write("classify needs a guard file name\n")
                return 2
            answer = classify(rest[0], path)
            if answer is None:
                print("unclassified")
                return 1
            print(answer)
            return 0
        if command == "message":
            if not rest:
                sys.stderr.write("message needs a guard file name\n")
                return 2
            print(user_message(rest[0], path))
            return 0
        if command == "json":
            print(json.dumps(load(path), indent=2))
            return 0
    except DeclarationError as exc:
        sys.stderr.write("spawn-guard-audience: %s\n" % exc)
        return 3
    sys.stderr.write("unknown command %r\n%s" % (command, __doc__))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
