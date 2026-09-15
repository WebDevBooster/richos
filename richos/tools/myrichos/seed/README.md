# This folder is yours

This is where Rich keeps what he knows about you and about your companies. One folder. You can
open it, read it, change it, move it to another machine, and back it up like anything else.

Everything in here is plain text. Nothing in it is a secret, and nothing in it is a program.

## What is in it

```
me/                  what is true about you, whichever company you are working on
companies/           one folder per company, with what is true about that one
registry/            the list of which folder on this machine belongs to which company
inbox/               things you drop for Rich to pick up
```

### `me/`

The standing instruction Rich works to, and how you want to be addressed. This part does not
change when you switch companies — it is about you.

`me/doctrine.source.md` is a pointer rather than the instruction itself, and it says where the
real one is and why it lives there. The short version: the instruction is a file the app writes
and checks, so that nothing can quietly change how Rich behaves without it being noticed.

`me/identity.config` is blank until you have been asked. Nobody guessed your name from your
computer, on purpose.

### `companies/`

Six folders, one per company:

**FemcBoost · Deeply · Prospects · RichOS · GPT Exporter · Webinar Booster**

That list is not a guess. It is the list you gave on 2026-09-01, and it is the one the app is
already using — see `registry/` below.

Each company folder has:

- **`company.md`** — what that company is, who it serves, and its house rules. Rich is told this
  at the start of every conversation about that company, and told nothing about the others.
- **`team/`** — the workers this company draws on. Empty for now.
- **`guards/`** — the rules that apply to work done for this company.
- **`memory/`** — that company's memory. Empty for now.

**Please read `company.md` for each company and correct it.** Each one marks which lines came
from somewhere and which are still waiting for you to say. A line that is wrong is worse than a
line that is missing, because Rich will act on it.

### `registry/`

Which folder on this machine belongs to which company. When Rich is asked to work somewhere he
does not recognize, he asks you rather than guessing.

## What this folder is not

It is not a copy of something else. Where something has to live elsewhere, this folder holds a
pointer to it and the pointer is **checked** — if what it points at goes missing or changes, that
is reported rather than ignored.

That rule is here because of a specific mistake worth not repeating: elsewhere on this machine
there are four links pointing at a folder that does not exist, and have been for days, and
nothing ever said so.

## Nothing here is running yet

The app does not read this folder yet. It was built first so that everything that comes next has
somewhere to go. You can change anything in it; nothing will break, because nothing is switched
on.
