# The false-positive corpus for `guard-interactive-prompt.sh`

A blocking guard that is wrong gets waived, and a guard that is waived habitually
is a formality with a hook attached. So the rate is measured, on real commands,
before the guard is trusted with `exit 2` — and the measurement is reproducible
by anyone who doubts it.

## The corpus

**Every distinct Bash command in every Claude Code transcript on this machine.**
Not a sample, not a hand-picked set, and not commands written for this purpose.

| | |
|---|---|
| Source | `~/.claude/projects/**/*.jsonl` |
| Session files read | 1,762 |
| Unique commands | 65,781 |
| Projects covered | femcboost, richos, richos-hq, prospects, li-profile-data-grabber, and every scratchpad session |
| Measured | 2026-09-01, against the shipped `scripts/lib/interactive-prompt.py` |

It is the right corpus for this question for one reason: it is what agents on
this machine actually typed, including the night the guard exists because of.
A corpus of invented commands would measure the author's imagination.

## Regenerating it

```
python3 - <<'PY' > /tmp/corpus.jsonl
import json, os, glob
seen = set()
for path in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"Bash"' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            msg = d.get("message")
            if not isinstance(msg, dict) or not isinstance(msg.get("content"), list):
                continue
            for c in msg["content"]:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash":
                    cmd = (c.get("input") or {}).get("command")
                    if isinstance(cmd, str) and cmd.strip():
                        seen.add(cmd)
for c in sorted(seen):
    print(json.dumps(c))
PY

scripts/lib/interactive-prompt.py --corpus /tmp/corpus.jsonl
```

## The measured rate

| Tier | Findings | Rate | What they were |
|---|---|---|---|
| **block** | **4** | **0.0061%** | all four `security import` with no `-P` |
| report | 5 | 0.0076% | all five `git add -p` fed from a pipe |
| clean | 65,772 | 99.986% | everything else |

### The four blocking hits, named rather than rounded away

All four are the incident shape, and all four import material that is almost
certainly unencrypted, so all four would probably not in fact have prompted:

1. `security import DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db`
   — an Apple intermediate certificate. No private key, nothing to decrypt.
2. `... openssl pkcs8 -topk8 -nocrypt ... && security import "$d/key.p8" -f pkcs8 ...`
   — a deliberately unencrypted PKCS8 key.
3. and 4. `security import ~/.richos-signing/developer-id.key -f openssl ...`
   — an unencrypted PEM, twice.

**The exemption that would clear all four was considered and rejected.** Trusting
`-f openssl` / `-f pkcs8` / a `.cer` extension buys a false negative on exactly
the path that produced the incident: a PEM can be encrypted, and the 02:01
command carried no `-f` at all. The trade is one token of typing against a window
on the CEO's screen.

**And none of the four is broken by complying.** `-P ''` is correct and harmless
for unencrypted material — the command still succeeds. That is what makes a
no-waiver blocking tier defensible here: the refusal never leaves an author
without a working command, so there is never a day when the only move is to
switch the guard off.

### The five report-tier hits

`printf 'y\ny\nn\n' | git add -p <file>` and one `git add -p ... <<< 'y'`. Every
one feeds the keystrokes in deliberately. They are reported, not blocked, and the
tier is correct: whether `git add -p` waits depends on stdin, which is state the
analyzer cannot see.

## Shapes that were CUT because measuring them showed they were wrong

A shape that looks obviously right and measures badly is the most valuable thing
a corpus produces, so these are recorded rather than quietly deleted.

**`git merge` / `git cherry-pick` / `git revert` / `git pull` without `--no-edit`
— 14 findings, all false.** Git opens the merge-message editor only when stdin is
a terminal, which it never is for an agent. Measured directly rather than
reasoned about, with `GIT_EDITOR` set to a tripwire that prints and fails:

```
git merge --no-ff side </dev/null      ->  merge completed, editor NEVER invoked
git commit            </dev/null       ->  EDITOR-WAS-INVOKED
```

The same experiment is why the `git commit`-without-a-message shape SURVIVED:
git invokes the editor there unconditionally. It sits at report tier because what
happens next depends on `$EDITOR` — a terminal editor fails in a second, a
windowed one waits all night — and that is outside the command string.

**`ed` as an interactive program — 40 findings, all false.** Every one was
`ed() { python3 -c "..."; }`, one engineer's helper function, seen through a
clause split on `(`. Two independent fixes came out of it: `ed` left the shape
table (nobody runs the line editor), and function-definition headers are blanked
before clause splitting, which still matters for a wrapper named after a program
that IS in the table.

**`openssl req` without a passphrase flag — 3 findings, all false.** All three
were `openssl req -in <csr> -noout -verify`, which reads a CSR and prompts for
nothing. Narrowed to `req` that is GENERATING a key (`-newkey` / `-keyout`), and
demoted to report tier, since whether an existing key is encrypted is not visible
in the command.

## What the number does not cover

The corpus measures FALSE POSITIVES — how often this guard would have interrupted
work that was fine. It says nothing about false negatives, and two are known and
stated rather than discovered later:

* **Commands inside scripts are invisible.** `bash app/scripts/install-signing-cert.sh`
  is one token; that script contains `security import`. The guard's scope is what
  an agent types, which is where the 02:01 command came from.
* **Flags supplied through a variable are invisible**, so `security import "$F" $FLAGS`
  is refused even when `$FLAGS` contains `-P`. Conservative in the safe direction,
  and counted above as one of the ways the blocking tier can be blunt.

Both are restated in the headers of `scripts/lib/interactive-prompt.py` and
`scripts/hooks/guard-interactive-prompt.sh`, so a reader hits them wherever they
enter.
