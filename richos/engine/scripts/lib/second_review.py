#!/usr/bin/env python3
"""second_review.py: ONE SECOND REVIEW OF A TEAMMATE'S EXACT COMMITS, BY A DIFFERENT MODEL.

===========================================================================
WHAT THIS EXISTS FOR
===========================================================================
On 2026-10-08 the CEO fetched a Codex review of an agent's work by hand four
times (richos-hq docs/reviews/2026-10-08-dictation-slices-1-4/). Each one found
defects the author's own tests had passed; the first found two release
blockers in dictation slices 1-4 after they were already on main. His words,
ruling §113: "A regular RichOS user can never be expected anything even
remotely close to that. So, this all must be completely automated."

This is slice 1 of richos-hq docs/plans/2026-10-09-automatic-second-review-
and-t3-ideas.md: the command that does one review the way those four were
done. Slice 2's watcher starts it by itself; slice 3's land refuses work whose
tip has no passing verdict. Sage's check of that plan (...-sage-check.md) is
part of the spec, and every place below that follows one of his catches says
so.

===========================================================================
WHAT IT READS (plan §2.2): RECORDS, NEVER ANYONE'S SUMMARY
===========================================================================
  * THE ORIGINAL WORDS. For a teammate (--name): the brief exactly as it
    received it, the first message of its own transcript, which carries the
    CEO's verbatim sentence. Otherwise --words-file, read as bytes. A review
    with no original words is refused before any reviewer starts: a review
    against nobody's request can only check the code against itself.
  * THE EXACT COMMITS, base..tip. The tree at the tip is exported with
    `git archive` into this run's scratch folder (allocated by the wrapper with
    the engine's scratch.sh), with the commit log and the diff beside it. The
    author cannot move what is reviewed, and the reviewer never works in the
    author's workspace.
  * WHAT THE AUTHOR CLAIMS: its commit messages, its last report (the last
    text it wrote in its transcript) and any --claims-file.
  * EARLIER REVIEWS OF THE SAME WORK, from the ledger below, so a recheck
    says of each earlier finding: fixed, still-open or withdrawn.
  * THE REPOSITORY'S OWN RULES: AGENTS.md and docs/development/verification-
    retries.md as they are at the tip, and the reviewer duty
    (mega-lander/duties/reviewer.md).

===========================================================================
WHICH MODEL (plan §2.3, Sage's catches 3, 4 and 10)
===========================================================================
  * Codex reviews Claude's work: `codex exec` from the CLI inside ChatGPT.app,
    looked up on every run because it moves (it is an alpha), its --version
    recorded. Pinned, never left to a default: model gpt-6.1-sol, reasoning
    effort high (what he reviewed with, from Codex Desktop's own session
    record of 2026-10-08), approvals never, sandbox workspace-write rooted at
    the export (-C), so a fixture compiles there and nothing else is written;
    --skip-git-repo-check because an archive has no .git; --output-schema for
    the one fixed answer shape. Never --ephemeral: the session record is what
    carries the token count and his plan meter, which every row records.
  * Claude reviews Codex's work (a codex/ branch), and is the fallback when
    Codex cannot run (missing, signed out, at its usage limit: any exit without
    an answer that is not the time limit). The fallback is Opus, at high
    effort, in a fresh headless context with no setting sources (none of the
    lead's hooks or plugins), every write going through Bash, which Claude
    Code's OS sandbox confines to the export (the file-writing tools, which
    the sandbox does not confine, are removed), and --json-schema for the
    same answer shape. It respects his quota
    rule: quota-watch's own reading is taken first, and while a pause is in
    force (quota-watch --once exit 1) no Claude review starts.
  * A same-model reviewer is NOT refused (Sage's catch 3: what made the four
    reviews work was a fresh context, the original words and fixtures, not a
    different tier). Both models are recorded, so use can show whether it
    matters.

===========================================================================
HOW IT RUNS (Sage's catch 5)
===========================================================================
  * Admission by the engine's own CPU rule (cpu_policy.admission_open, 80% of
    total CPU), sampled from the kernel's host counters. No cap on how many
    reviews run at once: a review is mostly remote model time. A closed
    admission is waited on (bounded, one sample per 30 s, said once); an
    unmeasurable CPU refuses.
  * A 60-minute limit (the first by-hand review took about 30). Past it the
    reviewer's own process group, captured at spawn, is stopped. When this
    command is itself stopped (review-watch replacing a mid-job review with
    the handover one), it stops that group first.
  * The reviewer's builds are capped at REVIEW_BUILD_JOBS jobs (CARGO_BUILD_JOBS,
    MAKEFLAGS, CMAKE_BUILD_PARALLEL_LEVEL in its environment, and said in its
    input). The first real runs, 2026-10-09: the engine's CPU breaker stopped a
    `rustc` the Claude reviewer started at 5.08 cores for 10 s.

===========================================================================
THE VERDICT (plan §2.2, §2.4)
===========================================================================
  * The answer must have the fixed shape; anything else is no verdict.
  * It must name the exact tip (the full SHA, or a prefix of at least 7);
    a verdict about another commit is refused.
  * Any P1 makes it changes-requested, whatever the reviewer wrote.
  * One row per review in <state>/reviews.jsonl and the full text, answer and
    fixtures in <state>/reviews/<id>/ (<state> is ~/.claude/state, outside
    every repository and session, like the escalation ledger). One line on
    stdout says the verdict.

Test seams (second-review.test.sh only): SECOND_REVIEW_STATE_DIR,
SECOND_REVIEW_CODEX, SECOND_REVIEW_CLAUDE, SECOND_REVIEW_CODEX_SESSIONS,
SECOND_REVIEW_QUOTA_CMD, SECOND_REVIEW_CPU_BUSY, SECOND_REVIEW_TIMEOUT_SECONDS.
"""

import argparse
import ctypes
import fcntl
import glob
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import cpu_policy  # noqa: E402  (sibling in scripts/lib: the engine's CPU admission rule)

CODEX_MODEL = "gpt-6.1-sol"
CODEX_EFFORT = "high"
CLAUDE_MODEL = "opus"
CLAUDE_EFFORT = "high"
LIMIT_SECONDS = 60 * 60
ADMISSION_WAIT_SECONDS = 30 * 60
ADMISSION_SAMPLE_SECONDS = 30
CODEX_APP_ROOTS = ("/Applications/ChatGPT.app", "~/Applications/ChatGPT.app")
RULE_FILES = ("AGENTS.md", "docs/development/verification-retries.md")
MAX_INLINE_RULE_BYTES = 64 * 1024
MAX_INLINE_LOG_BYTES = 128 * 1024
FIXTURE_FILE_BYTES = 1024 * 1024
FIXTURE_TOTAL_BYTES = 20 * 1024 * 1024
REVIEW_BUILD_JOBS = 2
_REVIEWER = {"pgid": None}

EXIT_PASSED, EXIT_CHANGES, EXIT_NO_VERDICT, EXIT_REFUSED = 0, 1, 2, 64

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["reviewed_commit", "verdict", "summary", "checks", "findings", "earlier_findings",
                 "not_yet_claimed"],
    "properties": {
        "reviewed_commit": {"type": "string"},
        "verdict": {"type": "string", "enum": ["passed", "changes-requested"]},
        "summary": {"type": "string"},
        "checks": {"type": "array", "items": {"type": "string"}},
        "findings": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["priority", "title", "files", "evidence", "fixture"],
            "properties": {
                "priority": {"type": "integer", "enum": [1, 2, 3]},
                "title": {"type": "string"},
                "files": {"type": "array", "items": {"type": "string"}},
                "evidence": {"type": "string"},
                "fixture": {"type": "string"}}}},
        "earlier_findings": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["id", "status", "note"],
            "properties": {
                "id": {"type": "string"},
                "status": {"type": "string", "enum": ["fixed", "still-open", "withdrawn"]},
                "note": {"type": "string"}}}},
        "not_yet_claimed": {"type": "array", "items": {"type": "string"}},
    },
}


class Refused(Exception):
    """Refused before any reviewer ran (exit 64)."""


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if t is None else t))


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode != 0:
        raise Refused("git %s failed in %s: %s" % (" ".join(args), repo,
                                                  p.stderr.decode("utf-8", "replace").strip()))
    return p.stdout.decode("utf-8", "replace")


def state_root():
    d = (os.environ.get("SECOND_REVIEW_STATE_DIR") or "").strip()
    if d:
        return d
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state")


def ledger_path():
    return os.path.join(state_root(), "reviews.jsonl")


def read_ledger():
    rows = []
    try:
        with open(ledger_path(), encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def append_row(row):
    os.makedirs(state_root(), exist_ok=True)
    data = (json.dumps(row, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(ledger_path(), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, data)
    finally:
        os.close(fd)


def _env_seconds(name, default):
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return max(0.0, float(raw))
    except ValueError:
        return default


# ---------------------------------------------------------------------------
# the teammate: registry record and transcript
# ---------------------------------------------------------------------------

def load_workspaces(engine_root):
    path = os.path.join(engine_root, "mega-lander", "workspaces.py")
    spec = importlib.util.spec_from_file_location("second_review_workspaces", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_teammate(ws, name):
    """The newest registry record with this name, finished or not. Read only."""
    hits = [r for r in ws.all_agents(include_done=True) if r.get("name") == name or r.get("key") == name]
    if not hits:
        raise Refused("no registered teammate %r" % name)
    return sorted(hits, key=lambda r: str(r.get("registered_at") or ""))[-1]


def teammate_workspace(rec, repo):
    live = [w for w in rec.get("workspaces") or [] if w.get("branch")]
    if repo:
        real = os.path.realpath(repo)
        live = [w for w in live if os.path.realpath(w.get("repo") or "") == real
                or os.path.realpath(w.get("path") or "") == real]
    if not live:
        raise Refused("teammate %r has no workspace%s" % (rec.get("name"), " in " + repo if repo else ""))
    cc = [w for w in live if w.get("kind") == "cc"]
    return (cc or live)[0]


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def transcript_facts(path):
    """(first brief verbatim, model of its first answer, last report text)."""
    words, model, last_id, last_text = None, "", None, {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            m = o.get("message") or {}
            if o.get("type") == "user" and words is None and not o.get("isMeta"):
                words = m.get("content") if isinstance(m.get("content"), str) else _text_of(m.get("content"))
            elif o.get("type") == "assistant":
                model = model or str(m.get("model") or "")
                text = _text_of(m.get("content"))
                if text.strip():
                    mid = m.get("id") or id(o)
                    if mid != last_id:
                        last_id, last_text = mid, {}
                    last_text[len(last_text)] = text
    report = "".join(last_text[k] for k in sorted(last_text)) if last_text else ""
    return words, model, report


def meta_model(transcript):
    try:
        with open(transcript[:-len(".jsonl")] + ".meta.json", encoding="utf-8") as f:
            return str(json.load(f).get("model") or "")
    except (OSError, ValueError, AttributeError):
        return ""


# ---------------------------------------------------------------------------
# the work: what is reviewed
# ---------------------------------------------------------------------------

class Work(object):
    def __init__(self):
        self.repo = ""
        self.branch = ""
        self.base = ""
        self.tip = ""
        self.author = ""
        self.author_model = ""
        self.words = []          # [(label, text)]
        self.claims = []         # [(label, text)]
        self.work_key = ""
        self.workspace = ""


def resolve_work(a):
    w = Work()
    if a.name:
        ws = load_workspaces(a.engine_root)
        rec = find_teammate(ws, a.name)
        space = teammate_workspace(rec, a.repo)
        w.repo = os.path.realpath(space.get("repo") or a.repo)
        w.workspace = os.path.realpath(space.get("path") or "")
        w.branch = a.branch or str(space.get("branch") or "")
        w.author = str(rec.get("name") or a.name)
        w.work_key = "teammate:%s" % rec.get("key")
        transcript = ws.platform_agent_transcript(rec)
        if transcript:
            words, model, report = transcript_facts(transcript)
            if words:
                w.words.append(("the brief exactly as %s received it (the first message of its transcript, %s)"
                                % (w.author, transcript), words))
            if report:
                w.claims.append(("%s's last report (the last text in its transcript)" % w.author, report))
            w.author_model = meta_model(transcript) or model
    else:
        if not a.repo:
            raise Refused("name a teammate (--name) or a repository (--repo)")
        w.repo = os.path.realpath(a.repo)
        w.branch = a.branch or ""
    if a.author_model:
        w.author_model = a.author_model
    if a.tip:
        w.tip = git(w.repo, "rev-parse", "--verify", a.tip + "^{commit}").strip()
    elif w.branch:
        w.tip = git(w.repo, "rev-parse", "--verify", "refs/heads/%s^{commit}" % w.branch).strip()
    else:
        raise Refused("name the commit to review (--tip or --branch)")
    if a.base:
        w.base = git(w.repo, "rev-parse", "--verify", a.base + "^{commit}").strip()
    else:
        w.base = git(w.repo, "merge-base", a.integration, w.tip).strip()
    if w.base == w.tip:
        raise Refused("nothing to review: the tip %s is the base" % w.tip[:12])
    if subprocess.run(["git", "-C", w.repo, "merge-base", "--is-ancestor", w.base, w.tip]).returncode != 0:
        raise Refused("the base %s is not an ancestor of the tip %s" % (w.base[:12], w.tip[:12]))
    codex_author = w.branch.startswith("codex/") or (a.author or "").lower() == "codex" \
        or w.author_model.lower().startswith(("gpt", "codex"))
    if codex_author:
        w.author = "codex"
        w.author_model = w.author_model or "codex"
    if a.author:
        w.author = a.author
    w.author = w.author or "unknown"
    for path in a.words_file or []:
        with open(path, "rb") as f:
            w.words.append(("%s, as given" % os.path.abspath(path), f.read().decode("utf-8", "replace")))
    for path in a.claims_file or []:
        with open(path, "rb") as f:
            w.claims.append(("%s, as given" % os.path.abspath(path), f.read().decode("utf-8", "replace")))
    if not any(t.strip() for _, t in w.words):
        raise Refused("no original words: a review needs the request the work answers (the teammate's own "
                      "transcript through --name, or --words-file); refused before any reviewer started")
    w.work_key = a.work or w.work_key or ("branch:%s:%s" % (w.repo, w.branch) if w.branch
                                          else "range:%s:%s" % (w.repo, w.base))
    return w


def earlier_findings(work_key, tip):
    """The findings still open from the newest earlier verdict on this work:
    its own findings, plus those it reported still-open. [(id, finding)]"""
    rows = [r for r in read_ledger() if r.get("work") == work_key and r.get("verdict")]
    if not rows:
        return []
    last = rows[-1]
    try:
        with open(os.path.join(state_root(), "reviews", last["id"], "verdict.json"), encoding="utf-8") as f:
            v = json.load(f)
    except (OSError, ValueError, KeyError):
        return []
    out = []
    carried = {e.get("id"): e for e in v.get("earlier_findings_in") or []}
    for e in (v.get("answer") or {}).get("earlier_findings") or []:
        if e.get("status") == "still-open" and e.get("id") in carried:
            out.append((e["id"], carried[e["id"]]))
    for i, f in enumerate((v.get("answer") or {}).get("findings") or [], 1):
        out.append(("%s#%d" % (last["id"], i), f))
    return out


# ---------------------------------------------------------------------------
# the export and the input
# ---------------------------------------------------------------------------

def export_tree(repo, tip, dest):
    os.makedirs(dest)
    arch = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", tip], stdout=subprocess.PIPE)
    tar = subprocess.run(["tar", "-x", "-f", "-", "-C", dest], stdin=arch.stdout)
    arch.stdout.close()
    if arch.wait() != 0 or tar.returncode != 0:
        raise Refused("could not export %s from %s" % (tip, repo))


def read_rule(tree, rel):
    p = os.path.join(tree, rel)
    try:
        with open(p, "rb") as f:
            data = f.read(MAX_INLINE_RULE_BYTES + 1)
    except OSError:
        return None
    text = data[:MAX_INLINE_RULE_BYTES].decode("utf-8", "replace")
    if len(data) > MAX_INLINE_RULE_BYTES:
        text += "\n[... cut at %d bytes; the whole file is tree/%s]\n" % (MAX_INLINE_RULE_BYTES, rel)
    return text


def fence(label, text):
    """Verbatim text between two marker lines that cannot occur inside it."""
    tag = "VERBATIM-" + secrets.token_hex(4).upper()
    return "<<<%s %s\n%s%s\n%s>>>\n" % (tag, label, text, "" if text.endswith("\n") else "\n", tag)


def build_input(w, a, export, earlier):
    review = os.path.join(export, "review")
    os.makedirs(review)
    os.makedirs(os.path.join(export, "fixtures"))
    os.makedirs(os.path.join(export, "build"))
    log = git(w.repo, "log", "--format=commit %H%nAuthor: %an%nDate: %cI%n%n%B%n", "%s..%s" % (w.base, w.tip))
    with open(os.path.join(review, "commits.txt"), "w", encoding="utf-8") as f:
        f.write(log)
    with open(os.path.join(review, "diff.patch"), "wb") as f:
        subprocess.run(["git", "-C", w.repo, "diff", "--no-color", "--no-ext-diff", w.base, w.tip], stdout=f, check=False)
    stat = git(w.repo, "diff", "--stat", "--no-color", w.base, w.tip)
    tree = os.path.join(export, "tree")
    mid_job = a.trigger in ("long-job", "quiet")
    duty = ""
    try:
        with open(os.path.join(a.engine_root, "mega-lander", "duties", "reviewer.md"), encoding="utf-8") as f:
            duty = f.read()
    except OSError:
        pass

    parts = []
    parts.append("# Second review: %s at %s\n\n" % (os.path.basename(w.repo), w.tip[:12]))
    parts.append("You are an independent reviewer, a different model from the one that wrote this work. Review "
                 "the exact commits below against the original words, and find what the author's own tests miss.\n\n")
    parts.append("## The commits you review\n\nTIP: %s\nBASE: %s\nREPOSITORY: %s\nBRANCH: %s\nAUTHOR: %s (model: %s)\n"
                 "TRIGGER: %s\n\n" % (w.tip, w.base, w.repo, w.branch or "(none)", w.author,
                                      w.author_model or "unknown", a.trigger))
    parts.append("Your working folder is `%s`. In it:\n"
                 "- `tree/`: the whole repository exactly as it is at the tip (a `git archive`; there is no `.git`).\n"
                 "- `review/commits.txt`: every commit from base to tip, with its full message.\n"
                 "- `review/diff.patch`: the full diff from base to tip.\n"
                 "- `fixtures/`: where any fixture you write goes. Its small files are kept with your verdict.\n"
                 "- `build/`: where build output goes (for example `CARGO_TARGET_DIR=build/target`). Not kept.\n\n"
                 "The change at a glance:\n\n```\n%s```\n\n" % (export, stat))
    parts.append("## The original words\n\nThese are the request the work answers, verbatim. Judge the work "
                 "against them, not against the author's account of them.\n\n")
    for label, text in w.words:
        parts.append(fence(label, text) + "\n")
    parts.append("## What the author claims\n\n")
    msgs = log if len(log) <= MAX_INLINE_LOG_BYTES else (
        log[:MAX_INLINE_LOG_BYTES] + "\n[... cut at %d characters; every commit is in review/commits.txt]\n"
        % MAX_INLINE_LOG_BYTES)
    parts.append(fence("its commit messages, base to tip (also review/commits.txt)", msgs) + "\n")
    for label, text in w.claims:
        parts.append(fence(label, text) + "\n")
    if not w.claims:
        parts.append("(No report beyond the commit messages.)\n\n")
    parts.append("Check the claims: a claimed test, receipt or result is evidence only once you have seen it "
                 "hold in the code at the tip.\n\n")
    parts.append("## Earlier reviews of this work\n\n")
    if earlier:
        parts.append("Say of EACH of these, in `earlier_findings`, by its id: `fixed`, `still-open` or "
                     "`withdrawn`, with a one-line note.\n\n")
        for fid, f in earlier:
            parts.append("- **%s** [P%s] %s (%s): %s\n" % (fid, f.get("priority"), f.get("title"),
                                                          ", ".join(f.get("files") or []), f.get("evidence")))
        parts.append("\n")
    else:
        parts.append("None. `earlier_findings` is an empty list.\n\n")
    parts.append("## The repository's own rules (as they are at the tip)\n\n")
    for rel in RULE_FILES:
        text = read_rule(tree, rel)
        if text is not None:
            parts.append(fence("tree/" + rel, text) + "\n")
    if duty:
        parts.append("## Your duty\n\n" + fence("the reviewer duty (mega-lander/duties/reviewer.md)", duty) + "\n")
    parts.append(
        "## How this review runs (where the duty above differs, this wins)\n\n"
        "- There is no assigned worktree and no `RICHOS_REVIEW` line: your working folder above is the target, "
        "and your final answer is the fixed JSON shape you were given.\n"
        "- Find what the author's tests miss. Where you can, prove a finding with a small fixture: write it "
        "under `fixtures/`, run it, and quote its output in the finding's evidence. Name the fixture's path in "
        "`fixture` (empty when there is none).\n"
        "- Every finding has a priority: 1 blocks a release (any P1 makes the verdict changes-requested), "
        "2 must be fixed, 3 is a note. Give a title, file:line locations (paths as in `tree/`) and evidence.\n"
        "- Never edit `tree/` to change the work, never commit, never touch the author's workspace (%s). "
        "Run no test VM, no app, no microphone, no phone, and no broad suite rerun; never touch the host "
        "display, sleep, lock or input.\n"
        "- `reviewed_commit` is the full TIP above. `checks` lists only the checks you actually ran.\n"
        "- Builds run with at most %d jobs (CARGO_BUILD_JOBS, MAKEFLAGS and CMAKE_BUILD_PARALLEL_LEVEL are set "
        "so); never raise them: the Mac is shared, and its CPU breaker stops a build that takes more.\n"
        % (w.workspace or w.repo, REVIEW_BUILD_JOBS))
    if mid_job:
        parts.append("- This work is still in progress. Review only what the author's commits and last report "
                     "claim is done at this tip; list what is not yet claimed in `not_yet_claimed`, never as "
                     "findings.\n")
    else:
        parts.append("- The author has handed this work over. `not_yet_claimed` lists anything the original words "
                     "ask for that the work does not claim at all.\n")
    prompt = "".join(parts)
    with open(os.path.join(review, "prompt.md"), "w", encoding="utf-8") as f:
        f.write(prompt)
    return prompt


# ---------------------------------------------------------------------------
# admission and the quota hold
# ---------------------------------------------------------------------------

def _host_ticks():
    if sys.platform != "darwin":
        return None
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    lib.mach_host_self.restype = ctypes.c_uint
    ticks = (ctypes.c_uint * 4)()
    count = ctypes.c_uint(4)
    if lib.host_statistics(lib.mach_host_self(), 3, ctypes.byref(ticks), ctypes.byref(count)):
        return None
    return list(ticks)


def cpu_busy():
    """Total CPU percent over one second (user + system + nice), or None."""
    pinned = (os.environ.get("SECOND_REVIEW_CPU_BUSY") or "").strip()
    if pinned:
        try:
            return float(pinned)
        except ValueError:
            return None
    before = _host_ticks()
    time.sleep(1.0)
    after = _host_ticks()
    if before is None or after is None:
        return None
    delta = [(b - a) % 2 ** 32 for a, b in zip(before, after)]
    total = sum(delta)
    return 100.0 * (1 - delta[2] / total) if total else None


def admit(wait_seconds, say):
    """(admitted, why). The engine's CPU rule alone; no count cap."""
    deadline = time.monotonic() + wait_seconds
    told = False
    while True:
        busy = cpu_busy()
        if busy is None:
            return False, "the CPU could not be measured, so the review was not admitted"
        if cpu_policy.admission_open(busy):
            return True, "CPU %.0f%% at admission" % busy
        if time.monotonic() >= deadline:
            return False, ("CPU admission stayed closed (%.0f%% busy, the rule admits below %d%%) for %d s"
                           % (busy, cpu_policy.DEFAULT_MAX_CPU, wait_seconds))
        if not told:
            say("second-review: waiting for CPU admission (%.0f%% busy; admits below %d%%), up to %d s"
                % (busy, cpu_policy.DEFAULT_MAX_CPU, wait_seconds))
            told = True
        time.sleep(min(ADMISSION_SAMPLE_SECONDS, max(0.0, deadline - time.monotonic())))


def quota_hold(engine_root):
    """(held, reading). His 93% rule, read through quota-watch's own --once."""
    cmd = (os.environ.get("SECOND_REVIEW_QUOTA_CMD") or "").strip()
    argv = [cmd] if cmd else ["bash", os.path.join(engine_root, "scripts", "quota-watch.sh"), "--once"]
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, "quota reading unavailable (%s)" % exc.__class__.__name__
    text = p.stdout.decode("utf-8", "replace").strip().splitlines()
    return p.returncode == 1, (text[0] if text else "quota-watch exit %d" % p.returncode)


# ---------------------------------------------------------------------------
# the reviewers
# ---------------------------------------------------------------------------

def find_codex():
    pinned = os.environ.get("SECOND_REVIEW_CODEX")
    if pinned is not None:
        return pinned if os.path.isfile(pinned) and os.access(pinned, os.X_OK) else ""
    for root in CODEX_APP_ROOTS:
        base = os.path.join(os.path.expanduser(root), "Contents")
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            if dirpath[len(base):].count(os.sep) > 7:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if d not in ("Frameworks", "_CodeSignature", "node_modules")]
            if "codex" in filenames and os.path.basename(dirpath) == "MacOS":
                p = os.path.join(dirpath, "codex")
                if os.access(p, os.X_OK):
                    return p
    return shutil.which("codex") or ""


def find_claude():
    pinned = os.environ.get("SECOND_REVIEW_CLAUDE")
    if pinned is not None:
        return pinned if os.path.isfile(pinned) and os.access(pinned, os.X_OK) else ""
    found = shutil.which("claude")
    if found:
        return found
    for p in ("~/.local/bin/claude", "~/.claude/local/claude"):
        p = os.path.expanduser(p)
        if os.access(p, os.X_OK):
            return p
    return ""


def version_of(binary):
    try:
        p = subprocess.run([binary, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        return p.stdout.decode("utf-8", "replace").strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return ""


def run_bounded(argv, cwd, prompt, out_path, err_path, limit, env=None):
    """(exit code or None on the time limit, seconds). The reviewer leads its
    own process group, captured at spawn; past the limit that group, and only
    that group, is stopped."""
    start = time.monotonic()
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=out, stderr=err,
                             start_new_session=True, env=build_env(env))
        _REVIEWER["pgid"] = p.pid
        try:
            p.communicate(prompt.encode("utf-8"), timeout=limit)
            return p.returncode, time.monotonic() - start
        except subprocess.TimeoutExpired:
            for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 10)):
                try:
                    os.killpg(p.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    p.wait(timeout=grace)
                    break
                except subprocess.TimeoutExpired:
                    continue
            return None, time.monotonic() - start
        finally:
            _REVIEWER["pgid"] = None


def build_env(env=None):
    """The reviewer's environment with its builds capped (REVIEW_BUILD_JOBS)."""
    e = dict(os.environ if env is None else env)
    jobs = str(REVIEW_BUILD_JOBS)
    e["CARGO_BUILD_JOBS"] = jobs
    e["CMAKE_BUILD_PARALLEL_LEVEL"] = jobs
    e["MAKEFLAGS"] = "-j" + jobs
    return e


def _on_stop(signum, _frame):
    """Stopped from outside: the reviewer's own process group goes first, so a
    stopped review leaves no reviewer running on its own."""
    pgid = _REVIEWER.get("pgid")
    if pgid:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except OSError:
            pass
    raise SystemExit(128 + signum)


def codex_session_facts(stdout_path, export, started):
    """Model, effort, sandbox, CLI version, tokens and his plan meter, from
    Codex's own session record (never from what this command asked for)."""
    facts = {"session": "", "model": "", "effort": "", "sandbox": "", "cli_version": "",
             "tokens": None, "meter": None}
    tid = ""
    try:
        with open(stdout_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if isinstance(o, dict) and o.get("thread_id"):
                    tid = str(o["thread_id"])
                    break
    except OSError:
        pass
    home = (os.environ.get("CODEX_HOME") or "").strip() or os.path.expanduser("~/.codex")
    sessions = (os.environ.get("SECOND_REVIEW_CODEX_SESSIONS") or "").strip() or os.path.join(home, "sessions")
    cands = glob.glob(os.path.join(sessions, "*", "*", "*", "rollout-*%s.jsonl" % tid)) if tid else []
    if not cands:
        # No thread id on stdout: the newest record started in this export.
        for p in sorted(glob.glob(os.path.join(sessions, "*", "*", "*", "rollout-*.jsonl")),
                        key=lambda p: os.path.getmtime(p), reverse=True)[:20]:
            if os.path.getmtime(p) < started - 5:
                break
            try:
                with open(p, encoding="utf-8") as f:
                    first = json.loads(f.readline())
                if (first.get("payload") or {}).get("cwd") == export:
                    cands = [p]
                    break
            except (OSError, ValueError):
                continue
    if not cands:
        return facts
    facts["session"] = cands[0]
    first_meter = last_meter = None
    with open(cands[0], encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
            if o.get("type") == "session_meta":
                facts["cli_version"] = str(p.get("cli_version") or "")
            elif o.get("type") == "turn_context":
                facts["model"] = str(p.get("model") or facts["model"])
                facts["effort"] = str(p.get("effort") or facts["effort"])
                facts["sandbox"] = str((p.get("sandbox_policy") or {}).get("type") or facts["sandbox"])
            elif p.get("type") == "token_count":
                prim = ((p.get("rate_limits") or {}).get("primary") or {})
                if isinstance(prim.get("used_percent"), (int, float)):
                    first_meter = prim["used_percent"] if first_meter is None else first_meter
                    last_meter = prim["used_percent"]
                tot = ((p.get("info") or {}).get("total_token_usage") or {})
                if tot:
                    facts["tokens"] = {"total": tot.get("total_tokens"), "input": tot.get("input_tokens"),
                                       "cached_input": tot.get("cached_input_tokens"),
                                       "output": tot.get("output_tokens")}
    if first_meter is not None:
        facts["meter"] = {"what": "ChatGPT plan, rate_limits.primary.used_percent",
                          "before": first_meter, "after": last_meter}
    return facts


def codex_argv(codex, export, schema_path, answer_path):
    return [codex, "exec",
            "--sandbox", "workspace-write",
            "-C", export,
            "--skip-git-repo-check",
            "-m", CODEX_MODEL,
            "-c", 'model_reasoning_effort="%s"' % CODEX_EFFORT,
            "-c", 'approval_policy="never"',
            "--output-schema", schema_path,
            "-o", answer_path,
            "--json",
            "--color", "never",
            "-"]


def claude_settings():
    """Every write goes through Bash, and Bash is confined by Claude Code's OS
    sandbox to the working folder (it reads anywhere), the same boundary as
    Codex's workspace-write. No command may leave the sandbox."""
    return json.dumps({"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True,
                                   "allowUnsandboxedCommands": False}})


def claude_argv(claude):
    # bypassPermissions, because with acceptEdits the first real run
    # (2026-10-09, rv-20261009T004917Z-2d5aaf84-fc47) had its `cargo test` and
    # a `cd tree && ...` refused as prompts nobody answers. The boundary is the
    # OS sandbox, which bypassPermissions does not lift; the file-writing tools,
    # which the sandbox does not confine, are removed.
    return [claude, "-p",
            "--model", CLAUDE_MODEL,
            "--effort", CLAUDE_EFFORT,
            "--setting-sources", "",
            "--settings", claude_settings(),
            "--permission-mode", "bypassPermissions",
            "--disallowedTools", "Edit,Write,NotebookEdit",
            "--permission-prompts", "none",
            "--json-schema", json.dumps(SCHEMA),
            "--output-format", "json",
            "--no-session-persistence"]


def claude_env():
    env = dict(os.environ)
    for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
        env.pop(k, None)
    return env


def read_claude_result(stdout_path):
    """(answer dict or None, facts)."""
    facts = {"model": "", "tokens": None, "cost_usd": None}
    try:
        with open(stdout_path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None, facts
    res = None
    for chunk in [text] + text.splitlines()[::-1]:
        try:
            o = json.loads(chunk)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("type") == "result":
            res = o
            break
    if res is None:
        return None, facts
    usage = res.get("modelUsage") or {}
    if isinstance(usage, dict) and usage:
        opus = [k for k in usage if "opus" in k]
        facts["model"] = (opus or sorted(usage, key=lambda k: -int((usage[k] or {}).get("outputTokens") or 0)))[0]
    u = res.get("usage") or {}
    if u:
        facts["tokens"] = {"total": sum(int(u.get(k) or 0) for k in ("input_tokens", "output_tokens",
                                                                     "cache_read_input_tokens",
                                                                     "cache_creation_input_tokens")),
                           "input": u.get("input_tokens"), "cached_input": u.get("cache_read_input_tokens"),
                           "output": u.get("output_tokens")}
    facts["cost_usd"] = res.get("total_cost_usd")
    answer = res.get("structured_output")
    if answer is None and isinstance(res.get("result"), str):
        body = res["result"].strip()
        m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", body, re.S)
        try:
            answer = json.loads(m.group(1) if m else body)
        except ValueError:
            answer = None
    return answer, facts


# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------

def shape_problems(v, schema=SCHEMA, where="answer"):
    """Every way the answer departs from the fixed shape ([] = it fits)."""
    t = schema.get("type")
    if t == "object":
        if not isinstance(v, dict):
            return ["%s is not an object" % where]
        out = []
        props = schema.get("properties") or {}
        for k in schema.get("required") or []:
            if k not in v:
                out.append("%s has no %r" % (where, k))
        if schema.get("additionalProperties") is False:
            out += ["%s has an unexpected %r" % (where, k) for k in v if k not in props]
        for k, sub in props.items():
            if k in v:
                out += shape_problems(v[k], sub, "%s.%s" % (where, k))
        return out
    if t == "array":
        if not isinstance(v, list):
            return ["%s is not a list" % where]
        out = []
        for i, item in enumerate(v):
            out += shape_problems(item, schema.get("items") or {}, "%s[%d]" % (where, i))
        return out
    if t == "string" and not isinstance(v, str):
        return ["%s is not a string" % where]
    if t == "integer" and (isinstance(v, bool) or not isinstance(v, int)):
        return ["%s is not a whole number" % where]
    if "enum" in schema and v not in schema["enum"]:
        return ["%s is %r, not one of %s" % (where, v, schema["enum"])]
    return []


def judge(answer, tip):
    """(verdict or None, forced, why)."""
    if answer is None:
        return None, False, "the reviewer gave no answer"
    problems = shape_problems(answer)
    if problems:
        return None, False, "the answer is outside the fixed shape: " + "; ".join(problems[:5])
    named = answer["reviewed_commit"].strip().lower()
    if len(named) < 7 or not tip.startswith(named):
        return None, False, ("refused: the verdict names commit %r, not the tip %s it was asked to review"
                             % (answer["reviewed_commit"], tip))
    p1 = [f for f in answer["findings"] if f["priority"] == 1]
    if p1 and answer["verdict"] != "changes-requested":
        return "changes-requested", True, "a P1 finding forces changes-requested (the reviewer wrote %s)" % answer["verdict"]
    return answer["verdict"], False, ""


# ---------------------------------------------------------------------------
# one review
# ---------------------------------------------------------------------------

def keep_fixtures(src, dest):
    """Copy the reviewer's fixtures, small files only: a compile's output
    belongs in build/, and a stray one must not fill ~/.claude/state.
    Returns what was left out."""
    left, total = [], 0
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if d not in ("target", ".git", "node_modules")]
        for n in sorted(filenames):
            p = os.path.join(dirpath, n)
            rel = os.path.relpath(p, src)
            try:
                size = os.lstat(p).st_size
            except OSError:
                continue
            if os.path.islink(p) or size > FIXTURE_FILE_BYTES or total + size > FIXTURE_TOTAL_BYTES:
                left.append(rel)
                continue
            os.makedirs(os.path.join(dest, os.path.dirname(rel)), exist_ok=True)
            shutil.copyfile(p, os.path.join(dest, rel))
            total += size
    return left


def repo_identity(path):
    """The canonical identity of the repository at `path`: the real path of Git's
    common directory, exactly as Git reports it. Recorded in every verdict row when
    the review is written, so a worktree moved or removed later still matches."""
    real = os.path.realpath(path or "")
    try:
        r = subprocess.run(["git", "-C", real, "rev-parse", "--git-common-dir"], capture_output=True,
                           text=True, timeout=30)
        common = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout
        if r.returncode == 0 and common:
            real = os.path.realpath(os.path.join(real, common))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return real


def review(a):
    say = lambda s: (sys.stderr.write(s + "\n"), sys.stderr.flush())
    w = resolve_work(a)
    earlier = earlier_findings(w.work_key, w.tip)
    started_at = time.time()
    rid = "rv-%s-%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(started_at)), w.tip[:8], secrets.token_hex(2))
    record = os.path.join(state_root(), "reviews", rid)
    export = os.path.join(a.scratch, "export")
    out_dir = os.path.join(a.scratch, "out")
    os.makedirs(out_dir)
    schema_path = os.path.join(out_dir, "schema.json")
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(SCHEMA, f)
    prompt = ""

    row = {"id": rid, "at": iso(started_at), "repo": w.repo, "repo_id": repo_identity(w.repo), "branch": w.branch, "base": w.base, "tip": w.tip,
           "work": w.work_key, "author": w.author, "author_model": w.author_model, "trigger": a.trigger,
           "reviewer": "", "reviewer_model": "", "reviewer_effort": "", "cli_version": "",
           "verdict": None, "forced": False, "findings": 0, "p1": 0, "earlier_findings": len(earlier),
           "duration_s": None, "tokens": None, "meter": None, "admission": "", "quota": "",
           "fallback_why": "", "why": "", "record": record}

    def finish(answer=None, raw_paths=()):
        row["finished_at"] = iso()
        os.makedirs(record, exist_ok=True)
        for p in [os.path.join(export, "review", "prompt.md")] + list(raw_paths):
            if os.path.isfile(p):
                shutil.copyfile(p, os.path.join(record, os.path.basename(p)))
        fx = os.path.join(export, "fixtures")
        if os.path.isdir(fx) and os.listdir(fx):
            left = keep_fixtures(fx, os.path.join(record, "fixtures"))
            if left:
                row["fixtures_not_kept"] = left[:50]
        with open(os.path.join(record, "verdict.json"), "w", encoding="utf-8") as f:
            json.dump({"row": row, "answer": answer,
                       "earlier_findings_in": [dict(f, id=i) for i, f in earlier]}, f, indent=2, sort_keys=True)
        append_row(row)
        if row["verdict"]:
            line = "SECOND-REVIEW %s %s@%s by %s (%s): %d finding(s), %d P1%s. Record: %s" % (
                row["verdict"], os.path.basename(w.repo), w.tip[:12], row["reviewer"], row["reviewer_model"],
                row["findings"], row["p1"], " (forced by a P1)" if row["forced"] else "", record)
        else:
            line = "SECOND-REVIEW no verdict %s@%s: %s. Record: %s" % (os.path.basename(w.repo), w.tip[:12],
                                                                      row["why"], record)
        print(line)
        sys.stdout.flush()
        return {"passed": EXIT_PASSED, "changes-requested": EXIT_CHANGES}.get(row["verdict"], EXIT_NO_VERDICT)

    admitted, why = admit(a.admission_wait, say)
    row["admission"] = why
    if not admitted:
        row["why"] = why
        return finish()
    export_tree(w.repo, w.tip, os.path.join(export, "tree"))
    prompt = build_input(w, a, export, earlier)

    limit = _env_seconds("SECOND_REVIEW_TIMEOUT_SECONDS", a.limit_minutes * 60.0)
    use_codex = w.author != "codex" and a.reviewer in ("auto", "codex")
    answer = None
    raw = []
    if use_codex:
        codex = find_codex()
        if not codex:
            row["fallback_why"] = "the Codex CLI was not found inside ChatGPT.app or on PATH"
        else:
            row["reviewer"], row["cli_version"] = "codex", version_of(codex)
            answer_path = os.path.join(out_dir, "answer.json")
            so, se = os.path.join(out_dir, "codex.stdout.jsonl"), os.path.join(out_dir, "codex.stderr.txt")
            t0 = time.time()
            rc, secs = run_bounded(codex_argv(codex, export, schema_path, answer_path), export, prompt, so, se, limit)
            row["duration_s"] = round(secs, 1)
            facts = codex_session_facts(so, export, t0)
            row["reviewer_model"] = facts["model"] or "unverified (no session record found; asked for %s)" % CODEX_MODEL
            row["reviewer_effort"] = facts["effort"] or "unverified (asked for %s)" % CODEX_EFFORT
            row["tokens"], row["meter"] = facts["tokens"], facts["meter"]
            row["codex_session"], row["sandbox"] = facts["session"], facts["sandbox"]
            if facts["cli_version"] and not row["cli_version"]:
                row["cli_version"] = facts["cli_version"]
            raw = [so, se, answer_path]
            if rc is None:
                row["why"] = "the reviewer passed its time limit of %d minutes and was stopped" % round(limit / 60.0) \
                    if limit >= 60 else "the reviewer passed its time limit of %d s and was stopped" % limit
                return finish(None, raw)
            try:
                with open(answer_path, encoding="utf-8") as f:
                    answer = json.load(f)
            except (OSError, ValueError):
                answer = None
            if answer is None and rc != 0:
                tail = ""
                try:
                    with open(se, encoding="utf-8", errors="replace") as f:
                        tail = " ".join(f.read().strip().splitlines()[-3:])[:400]
                except OSError:
                    pass
                row["fallback_why"] = "Codex exited %d without an answer: %s" % (rc, tail or "(no message)")
            elif facts["model"] and (facts["model"] != CODEX_MODEL or facts["effort"] != CODEX_EFFORT):
                row["verdict"] = None
                row["why"] = ("refused: Codex's own session record says model %s at effort %s, not the pinned "
                              "%s at %s" % (facts["model"], facts["effort"], CODEX_MODEL, CODEX_EFFORT))
                return finish(answer, raw)
            else:
                verdict, forced, why = judge(answer, w.tip)
                return conclude(row, answer, verdict, forced, why, finish, raw)
    if a.reviewer == "codex":
        row["why"] = row["fallback_why"] or "Codex could not review"
        return finish(None, raw)

    # Claude: the reviewer of Codex's work, and the fallback.
    held, reading = quota_hold(a.engine_root)
    row["quota"] = reading
    if held:
        row["why"] = ("the quota hold is in force (his 93%% rule; %s), so no Claude review started; it waits "
                      "for the reset, as every teammate does" % reading)
        return finish(None, raw)
    claude = find_claude()
    if not claude:
        row["why"] = "no reviewer could run: %sthe claude CLI was not found" % (
            (row["fallback_why"] + "; ") if row["fallback_why"] else "")
        return finish(None, raw)
    row["reviewer"], row["cli_version"] = "claude", version_of(claude)
    row["reviewer_model"], row["reviewer_effort"] = "", CLAUDE_EFFORT
    so, se = os.path.join(out_dir, "claude.stdout.json"), os.path.join(out_dir, "claude.stderr.txt")
    rc, secs = run_bounded(claude_argv(claude), export, prompt, so, se, limit, env=claude_env())
    row["duration_s"] = round((row["duration_s"] or 0) + secs, 1)
    raw = raw + [so, se]
    answer, facts = read_claude_result(so)
    row["reviewer_model"], row["tokens"], row["cost_usd"] = facts["model"], facts["tokens"], facts["cost_usd"]
    row["meter"] = None
    if rc is None:
        row["why"] = "the reviewer passed its time limit and was stopped"
        return finish(None, raw)
    if facts["model"] and "opus" not in facts["model"]:
        row["why"] = "refused: the Claude reviewer ran on %s, not Opus" % facts["model"]
        return finish(answer, raw)
    verdict, forced, why = judge(answer, w.tip)
    return conclude(row, answer, verdict, forced, why, finish, raw)


def conclude(row, answer, verdict, forced, why, finish, raw):
    row["verdict"], row["forced"] = verdict, forced
    if verdict:
        row["findings"] = len(answer["findings"])
        row["p1"] = sum(1 for f in answer["findings"] if f["priority"] == 1)
        if forced:
            row["note"] = why
    else:
        row["why"] = why
    return finish(answer, raw)


def main(argv):
    ap = argparse.ArgumentParser(prog="second-review.sh",
                                 description="One second review of a teammate's exact commits by a different model.")
    ap.add_argument("--scratch", required=True, help=argparse.SUPPRESS)
    ap.add_argument("--engine-root", default=os.path.dirname(os.path.dirname(HERE)), help=argparse.SUPPRESS)
    ap.add_argument("--name", default="", help="the teammate whose work this is (registry name or key)")
    ap.add_argument("--repo", default="", help="the repository (required without --name)")
    ap.add_argument("--branch", default="", help="the branch whose head is the tip")
    ap.add_argument("--tip", default="", help="the exact commit to review (default: the branch head)")
    ap.add_argument("--base", default="", help="the base commit (default: merge-base with --integration)")
    ap.add_argument("--integration", default="main", help="the branch the work lands on (default main)")
    ap.add_argument("--words-file", action="append", help="the original words, verbatim (repeatable)")
    ap.add_argument("--claims-file", action="append", help="a report or receipt the author cites (repeatable)")
    ap.add_argument("--author", default="", help="the author's name, when not a registered teammate")
    ap.add_argument("--author-model", default="", help="the author's model, when no transcript says it")
    ap.add_argument("--work", default="", help="the key that ties rechecks of one piece of work together")
    ap.add_argument("--trigger", default="manual", choices=["handover", "long-job", "quiet", "manual"])
    ap.add_argument("--reviewer", default="auto", choices=["auto", "codex", "claude"])
    ap.add_argument("--limit-minutes", type=float, default=LIMIT_SECONDS / 60.0)
    ap.add_argument("--admission-wait", type=float, default=ADMISSION_WAIT_SECONDS,
                    help="seconds to wait for CPU admission (default 1800)")
    a = ap.parse_args(argv)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _on_stop)
    try:
        return review(a)
    except Refused as exc:
        sys.stderr.write("second-review: %s\n" % exc)
        return EXIT_REFUSED


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
