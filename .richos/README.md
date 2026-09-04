# `.richos/` — this repository's declarations

Three files here, and each one is an **adoption switch**. Its presence is the
whole decision: no flag, no config key, no code change.

| File | What its presence declares |
|---|---|
| `publication-boundary` | This repository gets published. Switches on the two leak guards and the completeness contract. |
| `publication-completeness` | The reviewed exemptions the completeness contract honors. Carries no adoption switch of its own. |
| `row-currency` | Landings here are checked against a working record, which lives in another repository. |

Every one of them is a commented file. Open it: the argument for the mechanism
is written at the top, above the settings.

## Why they are in a directory

They used to sit at the repository root, one entry each. This repository is
read by strangers on a page where the root listing is the first thing rendered,
and three declaration dotfiles were three of eleven rows. They are one row now.

## The names did not change

The declaration is still called `.publication-boundary` — that is the string
every guard names in its refusals, the string `engine/README.md` teaches an
adopter, and the string the completeness check derives its own subject list
from. Only the directory moved, and the leading dot came off on the way in,
because a hidden file inside a hidden directory is one nobody browsing here
would ever see.

## The root form still works

`engine/scripts/lib/declaration-path.sh` is the one place that resolves a
declaration, and it looks here first and at the repository root second. Any
repository that adopted this engine while these files lived at the root keeps
working, untouched — `femcboost` carries a root `.row-currency` right now.

Two copies of one declaration is **BROKEN**, never a choice between them:
choosing one quietly is how the wrong one stays live.

## What may live here

Only the three files above, and this README. Anything else is refused by name,
loudly, at the next guard invocation. That rule is the point of the directory
rather than a tidiness preference: without it, moving a declaration this engine
does not resolve from here — `.ceo-todos`, say — would switch its contract off
in silence, and a stood-down guard is indistinguishable from a clean one.

A declaration adopting this directory adds its stem to `DECL_ADOPTED_STEMS` in
`engine/scripts/lib/declaration-path.sh` in the same edit that makes it call
`decl_find`. The list cannot drift into licensing a silent miss.
