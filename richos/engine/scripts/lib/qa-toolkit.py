#!/usr/bin/env python3
"""qa-toolkit.py — every QA dispatch carries the toolkit's index.

THE QUESTION THIS ANSWERS, in the CEO's words (2026-09-20): "what else must be
done to ensure the QA toolkit actually gets used?"

The toolkit (app/scripts/qa) landed on 2026-09-20 against a measured need: 111
helper scripts written from scratch across eight walks, the same nine or ten
jobs every time, the contrast calculation alone written ten times under five
names with five estimators that do not agree. Its README states the rule —
"A QA brief names the tool from this directory" — and that rule has exactly one
failure mode: the brief does not, because the person writing it did not have
the list in front of them.

So the list travels with the dispatch. A QA-type teammate's payload carries the
README's OWN table and the README's OWN rule sentence, read out of the governed
repository AT SPAWN TIME, with the commit they were read at. Not a summary, not
a pointer to go and read, and never a copy in this file that drifts: a tool
added to the toolkit appears in the next spawn's payload because it appears in
the README, and the row and the commit are the freshness contract's identity
rather than a claim that it looks current.

WHAT DECIDES THAT A DISPATCH IS A QA DISPATCH
---------------------------------------------
The subagent TYPE, from `--type`, and nothing else. Not the brief's prose, not
the CEO's words, not a verb in the task. The ruling of 2026-09-20 07:25Z is
explicit that a mechanism does not read his words to decide anything, and a
prose-reading classifier over briefs is the exact shape the data-contract gate
was re-specified away from on 2026-09-15 — it fired 78 times over 968 real
prompts and not one was app work.

WHY A SEPARATE KEY FROM QA_ROLE_AGENTS
---------------------------------------
`QA_ROLE_AGENTS` already exists in orchestration.config and femcboost sets it
to "ray quint kai urban andy isaac ace". It answers a DIFFERENT question —
whose job IS the app, for the data-contract gate's evidence half — and it
includes the client engineers, who build the app and do not walk it with a
frame reader and an OCR gate. Overloading one list for two questions is how
the audience declaration's own header says a list stops meaning anything, so
this is its own key, `QA_TOOLKIT_AGENTS`, declared beside it with its reason.
Widening it is a one-line edit to data, in the file where the reason is.

It never refuses. A payload that cannot carry the table is a payload with a
note saying so, printed where the operator reads it — never a silent skip, and
never a spawn that dies because a README moved.
"""

import importlib.util
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(os.path.dirname(HERE))          # .../engine
# AND THE SAME THING WITH THE SYMLINK RESOLVED. The engine is loaded BY
# REFERENCE: `~/.claude/richos-engine` is a symlink to the repository's engine
# directory, and os.path.abspath does not follow it — so through the plugin
# path ENGINE is `~/.claude/richos-engine`, whose parent is `~/.claude` and
# whose grandparent is the home directory. The sibling-tree fallback below
# looks for the toolkit beside the engine, and measured through a symlinked
# engine it found nothing at all. realpath is what makes that fallback real.
ENGINE_REAL = os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.realpath(__file__))))

DEFAULT_AGENTS = "ray urban kai quint"
DEFAULT_TOOLKIT_DIR = "richos/app/scripts/qa"
HEADING = "## Your committed tools"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ONE reader for orchestration.config, not a second parser. appinstances.py's
# `declared` is the engine's existing env-then-file reader and its header says
# why reading the file as a fallback is what keeps one definition instead of
# two. This module needs exactly that and nothing else from it.
_AI = _load("richos_appinstances", os.path.join(HERE, "appinstances.py"))


def declared(name, default=""):
    return _AI.declared(name, default)


def qa_types():
    return [t for t in declared("QA_TOOLKIT_AGENTS", DEFAULT_AGENTS).split() if t]


def toolkit_dir():
    return (declared("QA_TOOLKIT_DIR", DEFAULT_TOOLKIT_DIR) or DEFAULT_TOOLKIT_DIR).strip("/")


def is_qa_type(subagent_type):
    return (subagent_type or "").strip() in qa_types()


# ---------------------------------------------------------------------------
# finding the toolkit
# ---------------------------------------------------------------------------

def candidate_roots(repos):
    """Where the governed toolkit may be, most specific first.

    The repositories this teammate was given, then the engine's own sibling
    tree — the engine ships inside the repository the toolkit lives in, so a
    QA dispatch into some OTHER repository still gets a real, absolute path to
    the real toolkit instead of nothing. Both the literal and the symlink-
    resolved engine location are tried, because on this machine the engine is
    loaded through a symlink and only the resolved one reaches the tree."""
    roots = []
    for r in (repos or []):
        if r and r not in roots:
            roots.append(r)
    for engine in (ENGINE_REAL, ENGINE):
        sibling = os.path.dirname(engine)                 # .../richos (the tree)
        for up in (os.path.dirname(sibling), sibling):
            if up and up not in roots:
                roots.append(up)
    return roots


def locate(repos):
    """(readme_path, repo_root, relative_dir) or (None, None, None)."""
    rel = toolkit_dir()
    tail = "/".join(rel.split("/")[-2:])
    for root in candidate_roots(repos):
        for candidate in (rel, tail):
            p = os.path.join(root, candidate, "README.md")
            if os.path.isfile(p):
                return p, root, candidate
    return None, None, None


def commit_of(repo, rel):
    try:
        p = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%h", "--", rel],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


# ---------------------------------------------------------------------------
# reading the README — its words, never ours
# ---------------------------------------------------------------------------

_H2 = re.compile(r"^##\s+(.*?)\s*$")


def _section(text, title):
    """The body under a `## <title>` heading, up to the next `##`."""
    out, inside = [], False
    for line in text.split("\n"):
        m = _H2.match(line)
        if m:
            if inside:
                break
            inside = m.group(1).strip().lower() == title.lower()
            continue
        if inside:
            out.append(line)
    return "\n".join(out).strip("\n")


def rule_sentence(text):
    """The first paragraph under `## The rule` — the README's own words."""
    body = _section(text, "The rule")
    para = []
    for line in body.split("\n"):
        if line.strip():
            para.append(line.rstrip())
        elif para:
            break
    return "\n".join(para).strip()


def tools_table(text):
    """The contiguous table under `## The tools`, verbatim, header included."""
    body = _section(text, "The tools")
    rows, started = [], False
    for line in body.split("\n"):
        if line.lstrip().startswith("|"):
            rows.append(line.rstrip())
            started = True
        elif started:
            break
    return "\n".join(rows)


# ---------------------------------------------------------------------------
# the section
# ---------------------------------------------------------------------------

def section(repos):
    """(text, notes). text is "" when there is nothing truthful to attach."""
    notes = []
    readme, root, rel = locate(repos)
    if not readme:
        notes.append("NOT ATTACHED — no %s/README.md under %s"
                     % (toolkit_dir(), ", ".join(candidate_roots(repos)) or "(no repository)"))
        return "", notes
    try:
        with open(readme, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        notes.append("NOT ATTACHED — cannot read %s: %s" % (readme, exc))
        return "", notes

    rule = rule_sentence(text)
    table = tools_table(text)
    sha = commit_of(root, rel)
    missing = [n for n, v in (("the rule sentence", rule), ("the tools table", table)) if not v]
    if missing:
        # Loud, and it still attaches whatever it DID read. A README that was
        # restructured must not silently empty the payload of its own index.
        notes.append("PARTIAL — %s not found in %s; attaching what was read"
                     % (" and ".join(missing), readme))
    if not rule and not table:
        return "", notes

    where = os.path.join(rel, "")
    lines = [HEADING, ""]
    lines.append("`%s` in %s%s. Every tool takes `--help`, exits non-zero with a "
                 "sentence when it cannot answer, and never prints a number it did not "
                 "measure. This table is its README's, read at spawn time."
                 % (where, root, (", at commit %s" % sha) if sha else ""))
    if rule:
        lines += ["", rule]
    if table:
        lines += ["", table]
    lines += ["",
              "A job that is not in this table and that you need: ADD it there and commit "
              "it with your work, in the shape `%s/README.md` sets out. A helper written "
              "under the scratch directory is measured at the land "
              "(`engine/scripts/qa-throwaways.sh`) and is gone with the scratch, so the "
              "next walk writes it again." % rel]
    n = table.count("\n") - 1 if table else 0
    notes.append("attached the toolkit index (%d tools%s) from %s"
                 % (max(n, 0), (", commit %s" % sha) if sha else "", readme))
    return "\n".join(lines) + "\n", notes


def annotate(prompt, subagent_type, repos):
    """(prompt, notes) — the payload's prompt with the toolkit index appended.

    Non-QA types get back the prompt they came with, byte for byte, and no
    note: this says nothing to an engineer, an architect or a researcher."""
    if not is_qa_type(subagent_type):
        return prompt, []
    if HEADING in prompt:
        return prompt, ["the brief already carries its own '%s' section; nothing appended"
                        % HEADING.lstrip("# ")]
    text, notes = section(repos)
    if not text:
        return prompt, notes
    return prompt.rstrip("\n") + "\n\n" + text, notes
