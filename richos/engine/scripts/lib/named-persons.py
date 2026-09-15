#!/usr/bin/env python3
"""named-persons.py — THE NAMED-PERSON DENY-LIST PREDICATE.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
A third party found his own name in this public repository, hours after it
was published, and told the owner. Nothing in the toolchain had looked for
it, and nothing could have: the two scanners that guard writes here ask
different questions.

  * scan-secrets.sh asks "is this a CREDENTIAL?" — vendor-prefix keys and
    entropy-gated literals. A NAME IS NOT A SECRET AND NEVER TRIPS A SECRET
    SCANNER. It has no vendor prefix, and the entropy of a person's name is
    the entropy of ordinary prose, which is rather the point of a name.
  * the shipped-artifact privacy sweep asks "is this the OWNER's name?" —
    his own name, his own company, his own handle, and nobody else's.

So a client's, a friend's or a family member's name passed every check in
the repository. This file is the check that asks the third question.

The leak itself was a FILENAME — the source recording named in a test
fixture's shell script. The media was never committed and never will be.
A filename is personal data even when the media it names never ships, so
this predicate scans a write's DESTINATION PATH as well as its content.

===========================================================================
THE SCRUB MADE IT WORSE BEFORE IT MADE IT BETTER, AND THAT SHAPES THIS
===========================================================================
The commit that removed the name from the file PUT THE FULL NAME AND THE
COMPANY IN THE COMMIT MESSAGE — on the repository's commit list, more
visible than the line it was removing. It had to be amended and force-pushed
with branch protection temporarily lifted.

  A SCRUB COVERS FOUR SURFACES: file content, commit message, branch name,
  and PR/issue title.

Three of the four were missed by the remedy for the first. Which of them a
hook can actually SEE is answered honestly in COVERAGE below, and the two
guards that call this file are split along exactly that seam.

===========================================================================
WHERE THE LIST LIVES, AND WHY NOT HERE
===========================================================================
NOT IN THIS REPOSITORY. The list of people being protected is itself the
sensitive object — a roster of the owner's clients, friends and family,
which is worse to publish than any single one of the names on it. It is
also the one file whose accidental commit would be unrecoverable in exactly
the way the original incident was: an ancestor of a shipped tag.

The default location is `~/.richos-privacy/named-persons`, and the choice
follows the precedent already set by `~/.richos-signing/`: operator scope,
outside every repository, on the machine rather than in a tree.

  * READABLE FROM ANY REPOSITORY — it is rooted at $HOME, so a hook running
    in any checkout on this machine resolves the same file. A sibling
    private repository would not: a guard running in a different repository
    has no reliable relative route to it, and its privacy would depend on a
    hosting setting staying flipped.
  * NOT PUBLISHABLE BY ACCIDENT — and that is enforced, not asserted:
    load_list() REFUSES a list path that resolves inside a git work tree,
    naming it. The list cannot be moved into a repository and keep working.
  * ITS ABSENCE IS NEVER A PASS. A missing list reports ABSENT, which is a
    distinct verdict from CLEAN, and every caller must handle it as such:
    the write-time guards announce it (loudly, once per repository per
    session) and let the write through, because a stranger who clones this
    repository has no such list and must not be blocked by ours; the
    RELEASE-time check REFUSES, because a release happens on the owner's
    machine where the list must exist. "No list" never silently means "no
    names to check" at any chokepoint that matters.

===========================================================================
FALSE POSITIVES ARE THE EXPENSIVE FAILURE, SO THE MATCH RULE IS NARROW
===========================================================================
A guard that blocks legitimate work gets switched off, and then protects
nothing. The specific hazard here is a COMMON FIRST NAME: put an ordinary
given name on a deny-list and every ordinary sentence containing it is
refused.

THE RULE: a `name:` entry must normalize to TWO OR MORE tokens, and it
matches only where those tokens appear ADJACENT in the scanned text. A bare
first name cannot be entered at all — the loader refuses the line and names
the fix. So the unit of matching is the identifying combination, never a
name part.

A single token CAN be listed, with `token:`, which is a deliberate,
per-entry declaration by the operator that this particular string is rare
enough to stand alone (a distinctive surname, a company name). It is opt-in
per entry rather than a mode, so the cost is priced where it is taken.

WHAT NORMALIZATION BUYS, and it is what would have caught the real leak:
lowercase, diacritics folded, camelCase split, and EVERY non-alphanumeric
character treated as a separator. So a name written with spaces, with
underscores, with hyphens, with dots, in camelCase, or percent-encoded
inside a URL are all ONE match — and so is that name buried in a media
filename with a topic and a year bolted on, which is the shape a filename
actually takes and the shape the incident took. A two-token entry also
matches REVERSED, because "Lastname, Firstname" is how a name is written in
a citation and a directory listing.

WHAT IS DELIBERATELY NOT MATCHED, so nobody assumes more than is here:
  * Initials. An initial plus a surname is two tokens, one of them a single
    letter, and it does not match a two-token entry. List the surname with
    `token:` if it is distinctive enough to stand alone; that is the
    operator's call to make, per entry.
  * Plurals. A surname with an "s" glued on is a different token. But
    POSSESSIVES do match, because the apostrophe is a separator and the run
    stays adjacent.
  * Misspellings, transliterations, nicknames, and anything fuzzy. There is
    no edit distance here on purpose: an approximate matcher over ordinary
    prose is a false-positive engine, and this list's whole value is that a
    block is always right.
  * Paraphrase, description, and "the guy from the webinar". A deny-list
    catches strings; it does not catch identification.

===========================================================================
COVERAGE — WHICH OF THE FOUR SURFACES A HOOK CAN ACTUALLY SEE
===========================================================================
Stated plainly rather than implied, because the incident is proof that the
implied answer was wrong.

  1. FILE CONTENT      SEEN. The PreToolUse[Write|Edit|MultiEdit|
                       NotebookEdit] guard sees the new text before it
                       reaches disk. It also sees the DESTINATION PATH,
                       which is the surface the actual leak used.
                       NOT SEEN: content that never passes through a write
                       tool — a generator, `cp`, an editor. The release-time
                       check is what covers those, because it reads the tree
                       rather than a tool call.

  2. COMMIT MESSAGE    SEEN, when the message is in the command:
                       `-m`, `-m<msg>`, `--message=`, a command-substitution
                       heredoc (its body IS the command string), and
                       `-F <path>` (the file is read).
                       NOT SEEN: `git commit` with no message, which opens
                       the editor — the message is typed into a temporary
                       file no hook is handed. NOT SEEN: messages created by
                       `git merge`, `cherry-pick`, `rebase` and `am`, which
                       make commits without running `git commit`. A merge
                       commit's default message quotes the BRANCH NAME,
                       which surface 3 gates at creation.

  3. BRANCH NAME       SEEN at creation and at push: `git checkout -b`,
                       `git switch -c`, `git branch <name>`, `git worktree
                       add -b`, `git push <remote> <ref>`.
                       NOT SEEN: a branch created in the GitHub web UI.

  4. PR / ISSUE TITLE  SEEN when it goes through `gh` — `pr create`,
                       `issue create`, `pr edit`, `issue edit`, `release
                       create`, and the comment subcommands. Tag names and
                       tag messages likewise, through `git tag`.
                       NOT SEEN, AND THIS IS THE REAL HOLE: a title typed
                       into github.com. No hook on this machine is in that
                       path. The release-time check is the backstop for
                       everything typed rather than executed, and it is why
                       the release check refuses rather than announces.

===========================================================================
OUTPUT PROTOCOL
===========================================================================
Line 1 is the verdict, and every caller switches on it:

    CLEAN                      nothing matched
    FOUND                      followed by one surface/redaction line per hit
    ABSENT + path              no list at that path — NOT a pass
    BROKEN + reason            a list that cannot be trusted; callers BLOCK
    PARSEFAIL                  unreadable hook payload

A FOUND line NEVER carries the matched name in full. It carries the first
and last character of each token — enough for the operator to know which
entry fired, not enough to be a second copy of the leak in a terminal
scrollback or a CI log. That is scan-secrets.sh's redact() convention and
it is here for scan-secrets.sh's reason.
"""

import hashlib
import json
import os
import re
import sys
import unicodedata

# A write big enough to be worth truncating is a write this cannot honestly
# report on. Truncating and reporting CLEAN would be the false green this
# whole mechanism exists to remove, so the cap is a BROKEN verdict instead.
MAX_SCAN_BYTES = 8 * 1024 * 1024

# A `token:` entry shorter than this is refused. Below four characters a
# single token is a fragment, not a name, and it will fire on ordinary prose
# in every file in the tree.
MIN_SINGLE_TOKEN_LEN = 4

DEFAULT_LIST_REL = ".richos-privacy/named-persons"

_CAMEL_1 = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_CAMEL_2 = re.compile(r"(?<=[A-Z])(?=[A-Z][a-z])")


def fold(text):
    """Lowercase, split camelCase, fold diacritics, decode a percent-space.

    Diacritics fold because a name written with an accent in prose and
    without one in a filename is the same person, and a filename is where
    the plain-ASCII spelling always shows up.
    """
    text = text.replace("%20", " ").replace("%2520", " ")
    text = _CAMEL_1.sub(" ", text)
    text = _CAMEL_2.sub(" ", text)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return text.lower()


def _fold_token(tok):
    """Fold ONE token. Same rules as fold(), minus the splitting ones."""
    tok = unicodedata.normalize("NFKD", tok)
    tok = "".join(c for c in tok if not unicodedata.combining(c))
    return tok.lower()


def token_spans(text):
    """[(folded_token, start, end)] with the spans in the ORIGINAL text.

    SPAN-AWARE ON PURPOSE, and the reason is a defect this file had: the block
    message names the artifact it is refusing, and when the artifact is a FILE
    PATH the name is IN that path — so the refusal printed in full the name it
    exists to keep out of sight. Masking it needs to know WHERE in the original
    string the match sits, and folding the whole string first (camelCase
    splitting inserts characters, NFKD changes lengths, %20 becomes one space)
    destroys exactly that correspondence. So spans are computed over the
    original and each token is folded on its own.

    Every non-alphanumeric character is a separator — the single decision that
    makes an underscore-joined media filename and a spaced-out name the same
    string to this matcher — plus a percent-encoded space, and camelCase
    boundaries INSIDE an alphanumeric run.
    """
    # A percent-encoded space is a separator. Replaced by three spaces (and
    # %2520 by five) rather than one, so every following character keeps its
    # original index.
    text = text.replace("%2520", "     ").replace("%20", "   ")

    out = []
    i, n = 0, len(text)
    while i < n:
        if not text[i].isalnum():
            i += 1
            continue
        j = i
        while j < n and text[j].isalnum():
            j += 1
        # One alphanumeric run: split it further at camelCase boundaries.
        run = text[i:j]
        start = 0
        for k in range(1, len(run)):
            prev, cur = run[k - 1], run[k]
            boundary = (prev.islower() or prev.isdigit()) and cur.isupper()
            if not boundary and prev.isupper() and cur.isupper() and k + 1 < len(run):
                boundary = run[k + 1].islower()
                if boundary:
                    # `HTTPServer` splits before the S, not after it.
                    pass
            if boundary:
                out.append((_fold_token(run[start:k]), i + start, i + k))
                start = k
        out.append((_fold_token(run[start:]), i + start, j))
        i = j
    return [(t, s, e) for (t, s, e) in out if t]


def tokens(text):
    """The token stream alone, for callers that do not need the spans."""
    return [t for (t, _s, _e) in token_spans(text)]


def digest(toks):
    return hashlib.sha256(" ".join(toks).encode("utf-8")).hexdigest()


def redact(toks):
    """First and last character of each token. Never the name itself."""
    parts = []
    for t in toks:
        parts.append("*" if len(t) <= 2 else t[0] + "***" + t[-1])
    return " ".join(parts)


class ListBroken(Exception):
    pass


class ListAbsent(Exception):
    pass


def default_list_path():
    env = os.environ.get("RICHOS_NAMED_PERSONS_FILE", "").strip()
    if env:
        return env
    return os.path.join(os.path.expanduser("~"), DEFAULT_LIST_REL)


def _inside_git_worktree(path):
    """Walk up from the list's directory looking for a repository.

    A `.git` entry — directory OR file, because a linked worktree's `.git`
    is a file — means this path is inside a checkout, and a checkout is a
    thing that gets committed and pushed. This is the "not publishable by
    accident" constraint made structural rather than promised.
    """
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


class DenyList(object):
    def __init__(self, path):
        self.path = path
        self.sequences = []      # (tokens, allow_reversed)
        self.singles = []        # single-token entries
        self.digests = {}        # token-count -> set of hex digests
        self.entry_count = 0
        self.mode = None

    def match_spans(self, text):
        """Every match as (tokens, start, end) with spans in the original text."""
        spans = token_spans(text)
        toks = [t for (t, _s, _e) in spans]
        found = []
        seen = set()

        def add(i, n):
            key = (spans[i][1], spans[i + n - 1][2])
            if key in seen:
                return
            seen.add(key)
            found.append((toks[i:i + n], key[0], key[1]))

        n_text = len(toks)
        for seq, reversible in self.sequences:
            n = len(seq)
            rev = list(reversed(seq)) if (reversible and n == 2) else None
            for i in range(0, n_text - n + 1):
                window = toks[i:i + n]
                if window == seq or (rev is not None and window == rev):
                    add(i, n)
        for single in self.singles:
            for i, t in enumerate(toks):
                if t == single[0]:
                    add(i, 1)
        for n, hexes in self.digests.items():
            for i in range(0, n_text - n + 1):
                window = toks[i:i + n]
                if digest(window) in hexes or (
                        n == 2 and digest(list(reversed(window))) in hexes):
                    add(i, n)
        return sorted(found, key=lambda r: r[1])

    def match(self, text, surface):
        """Every distinct hit, as (surface, redacted) pairs."""
        hits = []
        seen = set()
        for window, _s, _e in self.match_spans(text):
            key = " ".join(window)
            if key in seen:
                continue
            seen.add(key)
            hits.append((surface, redact(window)))
        return hits

    def mask(self, text):
        """The text with every match replaced by its redacted form.

        For the block message, which NAMES THE ARTIFACT IT IS REFUSING. When
        that artifact is a file path, the name is in the path — so an
        unmasked banner printed in full the name it exists to keep out of
        sight, in terminal scrollback and in whatever log captures stderr.
        """
        out, prev = [], 0
        for window, start, end in self.match_spans(text):
            if start < prev:
                continue
            out.append(text[prev:start])
            out.append(redact(window))
            prev = end
        out.append(text[prev:])
        return "".join(out)


def load_list(path=None):
    """Parse the deny-list. Raises ListAbsent / ListBroken; never degrades."""
    path = path or default_list_path()
    if not os.path.exists(path):
        raise ListAbsent(path)
    repo = _inside_git_worktree(path)
    if repo is not None:
        raise ListBroken(
            "the deny-list at %s lives INSIDE the git repository at %s. This list "
            "is a roster of private individuals and it must never be committable: "
            "move it to %s, which is outside every checkout on this machine."
            % (path, repo, default_list_path()))
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        raise ListBroken("cannot read the deny-list at %s: %s" % (path, exc))

    dl = DenyList(path)
    try:
        dl.mode = os.stat(path).st_mode & 0o777
    except OSError:
        dl.mode = None

    for lineno, line in enumerate(raw.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            kw, _, rest = line.partition(":")
            kw = kw.strip().lower()
            rest = rest.strip()
        else:
            kw, rest = "name", line

        if kw in ("name", "org"):
            toks = tokens(rest)
            if len(toks) < 2:
                raise ListBroken(
                    "%s line %d declares a %s: entry that is a SINGLE token. A "
                    "one-token name blocks ordinary prose everywhere it appears, "
                    "which is how a guard gets switched off. Use `token: <word>` "
                    "if that string really is rare enough to stand alone, and "
                    "take the false positives knowingly."
                    % (path, lineno, kw))
            dl.sequences.append((toks, True))
            dl.entry_count += 1
        elif kw == "token":
            toks = tokens(rest)
            if len(toks) != 1:
                raise ListBroken(
                    "%s line %d declares `token:` with %d tokens. `token:` is for "
                    "exactly one; use `name:` for a multi-word entry."
                    % (path, lineno, len(toks)))
            if len(toks[0]) < MIN_SINGLE_TOKEN_LEN:
                raise ListBroken(
                    "%s line %d declares a single token of %d characters. Below %d "
                    "a token is a fragment, not a name, and it will fire on every "
                    "file in the tree."
                    % (path, lineno, len(toks[0]), MIN_SINGLE_TOKEN_LEN))
            dl.singles.append(toks)
            dl.entry_count += 1
        elif kw == "sha256":
            parts = rest.split(":")
            if len(parts) != 2:
                raise ListBroken(
                    "%s line %d: a sha256 entry is `sha256:<token-count>:<64 hex>`. "
                    "The token count is carried because the matcher has to know "
                    "which window width to hash; it discloses a length and nothing "
                    "else." % (path, lineno))
            try:
                n = int(parts[0])
            except ValueError:
                raise ListBroken("%s line %d: token count is not a number." % (path, lineno))
            hx = parts[1].strip().lower()
            if n < 1 or n > 8:
                raise ListBroken(
                    "%s line %d: token count %d is out of range 1-8." % (path, lineno, n))
            if not re.fullmatch(r"[0-9a-f]{64}", hx):
                raise ListBroken("%s line %d: not a 64-character sha256 digest." % (path, lineno))
            dl.digests.setdefault(n, set()).add(hx)
            dl.entry_count += 1
        else:
            raise ListBroken(
                "%s line %d: unknown keyword '%s'. Known: name:, org:, token:, "
                "sha256:. A typo that silently does nothing is the defect this "
                "whole mechanism exists to remove, so it is refused by name."
                % (path, lineno, kw))

    if dl.entry_count == 0:
        raise ListBroken(
            "the deny-list at %s has no entries. An empty list is BROKEN, not "
            "CLEAN: everything downstream is conditional on it, and a check that "
            "read nothing and reported clean is precisely the false green this "
            "exists to end. Delete the file to stand the check down explicitly, "
            "or add an entry." % path)
    return dl


def payload_surfaces(payload):
    """(surface-label, text) pairs a hook payload puts at risk."""
    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input", {})
    if not isinstance(ti, dict):
        ti = {}
    out = []
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        fp = ti.get("file_path") or ti.get("notebook_path") or ""
        if fp:
            # The destination path is a surface in its own right. The real
            # incident WAS a filename.
            out.append(("file path", fp))
        if tool == "Write":
            out.append(("file content", ti.get("content") or ""))
        elif tool == "Edit":
            out.append(("file content", ti.get("new_string") or ""))
        elif tool == "MultiEdit":
            for e in (ti.get("edits") or []):
                if isinstance(e, dict):
                    out.append(("file content", e.get("new_string") or ""))
        elif tool == "NotebookEdit":
            out.append(("file content", ti.get("new_source") or ""))
    elif tool == "Bash":
        cmd = ti.get("command") or ""
        out.append(("git/gh command", cmd))
        # `-F <path>` / `--file <path>`: the message is in a file, so the
        # command string alone would report clean over a leak.
        for m in re.finditer(r"(?:^|\s)(?:-F|--file)[=\s]+(\S+)", cmd):
            p = m.group(1).strip("\"'")
            try:
                if os.path.isfile(p) and os.path.getsize(p) <= MAX_SCAN_BYTES:
                    with open(p, "r", encoding="utf-8", errors="replace") as fh:
                        out.append(("commit message file", fh.read()))
            except OSError:
                pass
    return [(label, text) for label, text in out if isinstance(text, str) and text]


def scan_texts(dl, pairs):
    hits = []
    for label, text in pairs:
        if len(text.encode("utf-8", "replace")) > MAX_SCAN_BYTES:
            raise ListBroken(
                "the %s is larger than the %d-byte scan cap. Scanning part of it "
                "and reporting clean would be a false green, so this is refused "
                "instead." % (label, MAX_SCAN_BYTES))
        hits.extend(dl.match(text, label))
    seen = set()
    out = []
    for surface, red in hits:
        if red in seen:
            continue
        seen.add(red)
        out.append((surface, red))
    return out


def emit(verdict, detail=None, rows=None):
    print(verdict + ("\t" + detail if detail else ""))
    for surface, red in (rows or []):
        print("%s\t%s" % (surface, red))
    return 0


def main(argv):
    mode = argv[0] if argv else "--help"
    rest = list(argv[1:])
    list_path = None
    if "--list" in rest:
        i = rest.index("--list")
        list_path = rest[i + 1]
        del rest[i:i + 2]

    if mode == "--mint":
        if not rest:
            sys.stderr.write('usage: named-persons.py --mint "<name>" [--single]\n')
            return 2
        single = "--single" in rest
        name = rest[0]
        toks = tokens(name)
        if not toks:
            sys.stderr.write("that string has no alphanumeric tokens.\n")
            return 2
        if single and len(toks) != 1:
            sys.stderr.write("--single needs exactly one token; got %d.\n" % len(toks))
            return 2
        if not single and len(toks) < 2:
            sys.stderr.write(
                "that string is a single token. A one-token name blocks ordinary "
                "prose; pass --single to declare it anyway.\n")
            return 2
        print("# paste ONE of these into %s" % default_list_path())
        print("%s: %s" % ("token" if single else "name", name))
        print("sha256:%d:%s" % (len(toks), digest(toks)))
        print("#   the sha256 form discloses a token count and nothing else;")
        print("#   the plaintext form is the one you can still read back later.")
        return 0

    if mode == "--doctor":
        path = list_path or default_list_path()
        try:
            dl = load_list(path)
        except ListAbsent:
            print("ABSENT\t%s" % path)
            print("  No deny-list on this machine. This is NOT 'no names to check' —")
            print("  it is 'nothing was checked'. Create it with:")
            print("    mkdir -p -m 700 %s" % os.path.dirname(path))
            print("    touch %s" % path)
            print("    chmod 600 %s" % path)
            print('    <engine>/scripts/named-persons.sh --mint "Firstname Lastname"')
            return 1
        except ListBroken as exc:
            print("BROKEN\t%s" % exc)
            return 2
        print("OK\t%s" % path)
        print("  entries       : %d  (%d multi-token, %d single-token, %d digest)"
              % (dl.entry_count, len(dl.sequences), len(dl.singles),
                 sum(len(v) for v in dl.digests.values())))
        print("  mode          : %s" % ("%04o" % dl.mode if dl.mode is not None else "unknown"))
        if dl.mode is not None and (dl.mode & 0o077):
            print("  NOTICE        : group/other can read this file. `chmod 600` it —")
            print("                  the roster is more sensitive than any one name on it.")
        print("  inside a repo : no  (refused at load if it ever is)")
        return 0

    if mode == "--mask":
        # Anything a caller is about to ECHO. Fails SAFE in both directions:
        # with no usable list nothing can be verified as clean, so the text is
        # returned unchanged (it is the caller's own string, not a scan result),
        # and every caller that echoes a path only does so on a FOUND verdict,
        # which cannot happen without a list.
        raw = rest[0] if rest else sys.stdin.read()
        try:
            dl = load_list(list_path)
        except (ListAbsent, ListBroken):
            sys.stdout.write(raw)
            return 0
        sys.stdout.write(dl.mask(raw))
        return 0

    if mode in ("--scan-payload", "--scan-text", "--scan-files", "--scan-file-list"):
        try:
            dl = load_list(list_path)
        except ListAbsent as exc:
            return emit("ABSENT", str(exc.args[0]))
        except ListBroken as exc:
            return emit("BROKEN", str(exc))

        pairs = []
        if mode == "--scan-payload":
            try:
                payload = json.loads(sys.stdin.read())
            except Exception:
                return emit("PARSEFAIL")
            if not isinstance(payload, dict):
                return emit("PARSEFAIL")
            pairs = payload_surfaces(payload)
        elif mode == "--scan-text":
            pairs = [(rest[0] if rest else "text", sys.stdin.read())]
        else:
            # --scan-files takes paths as arguments; --scan-file-list takes a
            # NUL-separated list on stdin. The stdin form exists because xargs
            # splits a long argument list into SEVERAL invocations, and a
            # caller reading the first verdict line would call a tree clean
            # over a hit in the second batch. One invocation, one verdict.
            if mode == "--scan-file-list":
                blob = sys.stdin.buffer.read().decode("utf-8", "replace")
                paths = [p for p in blob.split("\0") if p]
            else:
                paths = rest
            for p in paths:
                pairs.append(("path %s" % p, p))
                try:
                    if os.path.getsize(p) > MAX_SCAN_BYTES:
                        continue
                    with open(p, "rb") as fh:
                        head = fh.read(4096)
                    if b"\0" in head:
                        # A binary blob is not text and must never be handed to
                        # a text scanner. Its PATH is still scanned above, which
                        # is the surface that actually leaked.
                        continue
                    with open(p, "r", encoding="utf-8", errors="replace") as fh:
                        pairs.append(("content of %s" % p, fh.read()))
                except OSError:
                    pass

        try:
            rows = scan_texts(dl, pairs)
        except ListBroken as exc:
            return emit("BROKEN", str(exc))
        if rows:
            return emit("FOUND", None, rows)
        return emit("CLEAN")

    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
