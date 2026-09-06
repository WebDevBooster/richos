# `tools/myrichos` — the seed for the CEO's central folder

This directory builds `~/myrichos`, the folder
`docs/plans/richos-central-folder-2026-09-06.md` designs: **one folder holding everything that is
true about the person, plus one subfolder per company holding what is true about that company.**

It is the design's §6 "smallest useful first commit" and nothing beyond it: the folder, the six
`companies/<id>/company.md` files, and the six copied guard fragments. **It changes no behavior.**
Nothing in `app/**` reads any of it yet. That is the point — after this, every remaining step in
that document is a wiring change against a target that already exists.

```
tools/myrichos/build-myrichos.sh     materialize the folder (idempotent, never overwrites)
tools/myrichos/check-myrichos.sh     verify every pointer resolves and every copy matches
tools/myrichos/seed/                 the version-controlled content
```

## Why the folder is not simply committed

`~/myrichos` is the CEO's. §1.3 rules that it holds the **only** copy of anything it holds, so it
has to be the master, not a checkout of one. But content that exists in exactly one place, in a
directory with no history, is content one `rm` away from gone.

The split: this repository holds the **seed** — the initial content of a folder that does not yet
exist — and the builder **never overwrites**. So the first run creates the folder, every later run
adds only what is missing, and anything the CEO changes is his and stays his. The seed is where a
new company's starting files come from; it is not a mirror of the live folder and must not be
treated as one.

## Where the parent directory is decided

**One line, in `build-myrichos.sh`:**

```sh
MYRICHOS_ROOT="${MYRICHOS_ROOT:-$HOME/myrichos}"
```

The design's §8 leaves `~/myrichos` versus `~/ab/myrichos` genuinely open — Sage marked it
`unverified:`, designed for `~/myrichos`, and noted the choice is one line to change. It is the
CEO's call and he has not been asked. So it is honored as one line rather than an assumption
spread across the tree: **no file in `seed/` names a parent directory.** Where a seed file needs
the absolute path it writes `@MYRICHOS@`, and the builder substitutes it at the single point in
`place()`. Moving the folder costs that one line.

Verify that claim rather than believing it:

```sh
grep -rn 'myrichos' tools/myrichos/seed/ | grep -v '@MYRICHOS@'
```

## The guards are copied on purpose, and the copies are checked

§5.2 step 2 says **copy, do not move**: the originals in `femcboost` and `deeply` keep firing
until step 4 has positively observed the replacements firing. So for the length of that window
there are deliberately two copies of six hook scripts — the one exception to §1.3.

An unchecked copy is precisely how `claude-orchestration-kit` came to ship an isolation guard at
404 lines against the engine's 1090. So `build-myrichos.sh` writes `guards/SOURCES` recording each
copy's origin and SHA-256, and `check-myrichos.sh` compares all three sides — the record, the
live original, and the copy — and names which one moved.

> **Nothing in `claude-orchestration-kit` is touched by any of this.** The design document's rows
> about deleting its 13 hooks are **struck** by the correction at its top: the kit is a standalone
> product other people copy into their own repositories, its hooks are the thing being shipped,
> and on an adopter's machine the engine plugin does not exist at all. This tool neither reads nor
> writes that folder.

## Running it

```sh
tools/myrichos/build-myrichos.sh
tools/myrichos/check-myrichos.sh
```

`check-myrichos.sh` exits non-zero and names the failing pointer. It exists because four symlinks
in `~/Library/Application Support/RichOS/` have pointed at a directory that does not exist since
2026-09-04 and nothing ever said so; §1.3's rule is that a pointer with a missing target is an
error, not a fallback, and this is the thing that computes it.
