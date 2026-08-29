# Cold-open transcripts

Each file here is a record of **someone with no context reading this
repository's CEO surface and saying what they concluded** — not a test result.

They are produced by the RichOS engine. **The engine is installed outside this
repository** — normally at `~/.claude/richos-engine` — so these commands are
not files you will find in `scripts/` here:

```bash
~/.claude/richos-engine/scripts/cold-open.sh --run   <this repo>   # a fresh reader, no context
~/.claude/richos-engine/scripts/cold-open.sh --brief <this repo>   # the verbatim prompt, for a person
~/.claude/richos-engine/scripts/cold-open.sh --check <this repo>   # is a current transcript on file?
```

## Why they are gated at all

The surface these describe was once built, tested, gated and landed — and the
person it was for could not find it. Every acceptance criterion used was
internal: exit codes, test counts, git state. Nobody opened the repository the
way its reader would and asked "where would I click?", because that question
has no exit code.

So each transcript is stamped with a fingerprint of the front door it describes.
Change the front door and the commit guard refuses the next commit until a fresh
reading is on file. Identity or refuse — the same rule this project applies to
build artifacts, applied to a judgment.

## What the gate does and does not check

It checks that a reading **happened** for the front door as it currently
stands. It has **no opinion on what the reader concluded**, and that is
deliberate: a gate that demanded a favorable verdict would get one every time,
and the finding — the thing worth having — would be the one output that costs
its author a blocked commit.

**So read them.** A transcript reporting that the page is baffling satisfies the
gate exactly as well as one reporting it is clear. The machine cannot tell the
difference and is not trying to.
