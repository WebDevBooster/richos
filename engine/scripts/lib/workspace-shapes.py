#!/usr/bin/env python3
"""workspace-shapes.py — THE DECLARED ALLOW-LIST OF WORKSPACES THIS ENGINE OWNS.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
The CEO, 2026-09-10: *"if the cc/ prefix helps fix this shitshow once and for
all, add it now and be done with it."* What he was reaching for, in his own
earlier words, is *"finally NOT have anything undecided AFTER the corresponding
one was landed"*.

Until now the question "is this workspace mine?" was OPEN-WORLD: everything
that is not `main`, minus whatever the ownership record happens to know. Every
gap in the record therefore became a permanent undecidable, and undecidables
accumulate — 33 standing worktrees on this machine the day this was written, of
which the tools could say nothing at all about two.

This makes it CLOSED-WORLD over a list somebody wrote down:

    cc-branch      a branch named `cc/<teammate>`, created by
                   scripts/create-teammate-worktree.sh. Hand-rolled,
                   cross-repository, the common case (48 of 53 worktrees on
                   this machine).
    native-agent   `agent-<id>` under `.claude/worktrees/`, or a branch
                   `worktree-agent-<id>`. The harness names these and we
                   cannot rename them, so they are DECLARED rather than
                   inferred.
    legacy-teammate  the convention `cc/` replaces: a `<repo>-wt/<teammate>`
                   directory whose branch is the SAME `<role>-<model>-<id>`
                   name. Three properties coinciding — the `-wt/` location,
                   the enforced spawn-name shape, and branch == directory —
                   which is this engine's older signature and not a guess
                   about a name.

That is the complete list. Anything else is NOT OURS, and not-ours is a
decision — "someone else's, by declaration" — rather than an unknown.

WHY `legacy-teammate` EXISTS AND WHEN IT GOES. A prefix applied only going
forward leaves every workspace already on disk permanently off the list, and
on the day this was written that was 14 landed, overdue worktrees the CEO can
see. Renaming their branches under running agents to fix a bookkeeping rule
would be worse. So both conventions are recognized, the old one is named as
legacy, and it drains: when no `<repo>-wt/` directory carries a bare
`<role>-<model>-<id>` branch any more, drop `legacy-teammate` from
OWNED_WORKSPACE_SHAPES and the closed world is one convention wide. That
retirement is a one-line diff in a config file, which is the point of the
list being data.

===========================================================================
WHAT THIS FILE DOES *NOT* DECIDE, AND WHY IT MATTERS MORE THAN WHAT IT DOES
===========================================================================
BEING ON THE LIST IS SCOPE, NEVER PERMISSION.

The tempting next step — "prefixed, merged, clean and unlocked, therefore
remove it" — reads only facts on disk and would destroy a running agent's
work on an ordinary day. Measured 2026-09-10: a hand-rolled cross-repository
worktree takes NO lock by construction, a tree is clean between commits, and
the orchestrator lands teammate branches MID-ASSIGNMENT as standing practice.
So a live worker's workspace is `cc/`-prefixed, merged, clean and unlocked
while the worker is still typing in it. That is the 2026-08-24 incident —
an orchestrator destroying a running agent's worktree by checking the wrong
artifact — with the record removed instead of misread.

Removal authority therefore stays where it was: an exact ownership record
(scripts/lib/worktree-transactions.py), or the adoption tiers
(scripts/lib/worktree-adoption.py), whose T4 uses this list as a
PRECONDITION and never as the evidence.

===========================================================================
THE CODEX EXCLUSION IS SEPARATE AND STAYS SEPARATE
===========================================================================
An allow-list protects `codex/` by omission. The CEO's ruling
(richos-hq/wiki/ceo-decisions.md section 31) asks for more than protection: an
excluded workspace must be REPORTED as "excluded by CEO ruling", never
silently absent. Omission satisfies "never touched" and not that sentence, so
`codex` is classified explicitly here and refused by name in
scripts/lib/daily-workspace-cleanup.py.

Declaration: OWNED_WORKSPACE_SHAPES in orchestration.config. A shape this file
knows but the declaration omits is NOT OURS — the data decides, not the code.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_ROOT = os.path.dirname(os.path.dirname(HERE))

CC_PREFIX = "cc/"
NATIVE_DIR = os.path.join(".claude", "worktrees")
NATIVE_BRANCH_PREFIX = "worktree-agent-"
DEFAULT_SHAPES = "cc-branch native-agent legacy-teammate"

# Kinds this file can produce. `codex` and `not-ours` are never "owned" and
# are not declarable: they are the two ways of saying no.
OWNED_KINDS = ("cc-branch", "native-agent", "legacy-teammate")


def config_value(key, default, repo=None):
    """The entity's orchestration.config if it declares the key, else the
    engine's, else the default — the same resolution the reclaim lane uses."""
    candidates = ([os.path.join(repo, "orchestration.config")] if repo else []) + \
                 [os.path.join(ENGINE_ROOT, "orchestration.config")]
    for cfg in candidates:
        try:
            with open(cfg, encoding="utf-8") as stream:
                for line in stream:
                    line = line.strip()
                    if line.startswith(key + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return default


def declared_shapes(repo=None):
    """The shapes an operator has declared this engine owns. Data a reviewer
    can read; an undeclared shape is somebody else's."""
    return [s for s in config_value("OWNED_WORKSPACE_SHAPES", DEFAULT_SHAPES, repo).split()
            if s in OWNED_KINDS]


def _norm_branch(branch):
    branch = str(branch or "")
    return branch[len("refs/heads/"):] if branch.startswith("refs/heads/") else branch


def is_codex(path, branch=""):
    """BOTH shapes, because two of the nine codex worktrees standing on
    2026-09-10 live outside any `-wt/` directory and their branch is `main`."""
    parts = [p for p in str(path or "").split(os.sep) if p]
    base = parts[-1] if parts else ""
    ref = _norm_branch(branch)
    if ".codex" in parts:
        return True, "the path lies under a .codex directory"
    if base == "codex" or base.startswith("codex-") or base.startswith("codex_"):
        return True, "the workspace directory is named %r" % base
    if ref == "codex" or ref.startswith("codex/") or ref.startswith("codex-"):
        return True, "the branch is %r" % ref
    return False, ""


def classify(path, branch="", repo=None):
    """(kind, reason). kind is one of the declared owned kinds, `codex`, or
    `not-ours`. Never raises, and never guesses: every answer names the exact
    property it read.
    """
    path = str(path or "")
    ref = _norm_branch(branch)
    parts = [p for p in path.split(os.sep) if p]
    base = parts[-1] if parts else ""

    codex, why = is_codex(path, ref)
    if codex:
        return "codex", ("excluded by CEO ruling 2026-09-10 (do not touch codex workspaces): %s" % why)

    shapes = declared_shapes(repo)
    if "cc-branch" in shapes and ref.startswith(CC_PREFIX):
        where = "" if _under_wt_dir(path) else \
            " (NOTE: outside a `<repo>-wt/` directory, which the declaration also names — reported, never quietly claimed)"
        return "cc-branch", "the branch is %r, this engine's own prefix%s" % (ref, where)
    if "native-agent" in shapes and (_is_native_path(path, base) or ref.startswith(NATIVE_BRANCH_PREFIX)):
        return "native-agent", ("the harness's own isolation worktree (%s)"
                                % ("path %s" % base if _is_native_path(path, base) else "branch %r" % ref))
    if "legacy-teammate" in shapes and _under_wt_dir(path) and base and ref == base \
            and _is_spawn_name(base, repo):
        return "legacy-teammate", ("the pre-`cc/` convention: a `-wt/` directory named %r, of the "
                                   "enforced spawn shape, whose branch is the same name" % base)
    return "not-ours", ("no declared owned shape matches (branch %r, directory %r); "
                        "not this engine's to touch" % (ref or "(none)", base or "(none)"))


def _under_wt_dir(path):
    parent = os.path.basename(os.path.dirname(str(path).rstrip(os.sep)))
    return parent.endswith("-wt")


def _is_spawn_name(name, repo=None):
    """The `<role>-<model>-<identifier>` shape create-teammate-worktree.sh
    enforces, with the model aliases read from the same declaration the spawn
    guard reads. A name that is not of this shape was never one of ours."""
    import re
    models = config_value("ALLOWED_MODELS", "fable opus sonnet haiku", repo).split()
    if not models:
        return False
    pattern = r"^[a-z][a-z0-9]{1,15}-(%s)-[a-z0-9]{1,12}$" % "|".join(re.escape(m) for m in models)
    return bool(re.match(pattern, str(name or "")))


def _is_native_path(path, base):
    return NATIVE_DIR in str(path) and base.startswith("agent-")


def owned(path, branch="", repo=None):
    """True when this workspace is one this engine is accountable for."""
    return classify(path, branch, repo)[0] in OWNED_KINDS


def _main(argv):
    import argparse
    import json
    ap = argparse.ArgumentParser(prog="workspace-shapes.py")
    ap.add_argument("path")
    ap.add_argument("--branch", default="")
    ap.add_argument("--repo", default=None)
    a = ap.parse_args(argv)
    kind, reason = classify(a.path, a.branch, a.repo)
    print(json.dumps({"path": a.path, "branch": a.branch, "kind": kind,
                      "owned": kind in OWNED_KINDS, "reason": reason}, sort_keys=True))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv[1:]))
