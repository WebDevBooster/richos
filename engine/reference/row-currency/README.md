# Row currency — the starter kit an adopter actually receives

The engine ships a lint (`scripts/row-currency-lint.sh`), a landing guard
(`scripts/hooks/guard-row-currency-commits.sh`), a predicate
(`scripts/lib/row-currency.{sh,py}`) and a 47-case suite for all of it.

**Every one of them is inert until a repository carries a `.row-currency`
declaration.** This folder exists so that cannot ship as machinery a customer
receives and can never fire — the same defect the `.ceo-todos` starter kit next
door was written to close, one contract later.

## The problem, in one paragraph

A working list has rows; rows describe things; things change. Nothing connects
the two. On 2026-08-29 four rows of one real record described work as unbuilt,
pending or open, hours after it had landed — in a single day, in a repository
whose owners are unusually careful about exactly this. Every one was found by a
person reading the page, because a person reading the page was the only
detector that existed. Updating a row is a manual step that comes after the
merge, and a step nobody is forced to take is the step that gets skipped on the
day with four landings in it.

## The mechanism

> A row that describes open work states the identity of the work it describes.
> When that identity changes and the row does not, the next landing is refused
> until somebody rewrites the row.

The identity is an object id — the blob id of a file, the tree id of a
directory — read out of the tree the commit is about to create. Content, not a
clock: it survives a rebase, it needs no two machines to agree about the time,
and it answers the only question that matters.

```
| 4.2 | prose about the work | **State:** `OPEN` — `<repo>/src/parser.rs`@`0a1b2c3d4e5f` |
```

Rows almost always already carry the path. All four of the rows that rotted did,
on the morning they were wrong. This contract adds no new fact to maintain; it
pins the one that was already there.

**There is no re-stamp command, and there will not be one.** A tool that
refreshes the pin discharges the obligation without anybody reading the prose,
which is the original defect wearing a fix's clothes. The refusal prints the
warrant to paste, into a row you are already looking at, beside a sentence you
have to decide is still true.

## The second warrant: a CEO item's PREMISE

The mechanism above answers *is this row still describing the work?* The
CEO-TODOs contract answers *is this item already finished?* Neither answers the
question that rots a question on the CEO's own page:

> Is the reason for asking him this still true?

The case it was built from: an item asked the CEO to rule on whether a
repository should enforce its own rules, resting on a measurement taken three
days earlier — the contracts were committed and nothing read them. By the time
he read it that was false; the mechanism had been fixed and had been refusing
commits all day. The item was never *finished*, so its Done-check was correctly
unsatisfied and correctly silent. **Its premise had rotted, and nothing had an
opinion about premises.** His attention is the scarcest thing in the system, and
a question whose reason has evaporated spends it directly.

So an item in a CEO section may pin the observable fact its question rests on:

```
- **Premise:** `<repo>/src/scope.rs`@`4f2a9c1e83bd` — this resolver exits before
  it reads the destination's declaration, so both contracts are read by nothing
```

Same identity rule, same refusal, same absence of a re-stamp command. When that
object id moves, the next landing is refused, naming the item and what moved.

**The stated fact is part of the warrant, not decoration.** A pin with no
sentence beside it can be cleared by retyping a hex string, which is the
original defect wearing a fix's clothes — and it is exactly what the rotted item
had: its premise sentence lived thirty lines below in prose, attached to
nothing.

**Not every question has a pinnable premise, and forcing one would produce
fiction.** "Run `railway login`" rests on no artifact. An item may say
`unobservable "<why not>"` instead — and a bare marker exempts nothing, it must
carry a reason. Every such declaration is counted and printed by the census on
every run, clean or not:

```
PREMISE CENSUS  sections=1,2 items=9 evaluated=1 pinned=1 stamps=1 moved=1
                unobservable=0 broken=0 skipped=0 unstated=8
```

That line rides on passes as well as refusals, because the correct output for an
unobservable premise is silence — and silence is also what a checker that never
ran produces.

**It is opt-in, in the record repository's `.ceo-todos`**, not here: the CEO
sections are that declaration's jurisdiction and `CEO_SECTIONS` is already
stated there once.

| key | meaning |
|---|---|
| `PREMISE_SECTIONS` | a subset of `CEO_SECTIONS`. Undeclared = not adopted, and the census says so rather than passing in silence. |
| `PREMISE_REQUIRED` | `0` (default) names every premise-less item in a notice; `1` makes it a refusal. Default 0 for the reason `DONE_CHECK_REQUIRED` is: shipping it as a requirement would refuse the next commit in every repository that already has a record. |

## The second check, and why it is second

A commit or merge message that NAMES an item ("we closed item 4.2") is claiming
that item's truth changed, so that item's row must be in hand. That check reads
prose, and prose is a claim rather than evidence — so it is the second net, not
the first. Its precision rules were written against 800 real commit messages;
`--explain` prints its reasoning candidate by candidate, because a precision
argument nobody can inspect is one nobody should believe.

## The files here

| file | what it becomes |
|---|---|
| `row-currency.example` | `.row-currency` in the repository that owns the record |
| `row-currency-peer.example` | `.row-currency` in a repository where the work lives and the record does not |

Either one goes at the repository root, or at `.richos/row-currency` — the
engine resolves the grouped form first and the root form second, so both work
and neither has to be migrated. Grouping is a preference about what a
repository's root listing looks like and changes nothing else. Declaring the
same thing in both places at once is refused as BROKEN rather than resolved to
one of them.

Copy one, edit it, and run the lint against your own repository before you
write a single warrant:

```bash
scripts/row-currency-lint.sh /path/to/your/repo
scripts/row-currency-lint.sh /path/to/your/repo --explain --message "closes item 4.2"
```

It will tell you, by item id, exactly which rows are not yet warranted.

## Where it fires, and where it deliberately does not

Only at a **landing**: the main checkout, an attached HEAD, at `git commit` or
`git merge`. An engineer's branch in a linked worktree is a proposal — it has
changed nothing the record describes, and the engineer usually cannot reach the
record from there anyway. A guard that fired on every branch commit would be
switched off inside a day, and then it would protect nothing.

## What it cannot see

Stated here rather than discovered later:

- **A landing that changes an item's truth without touching anything the row
  points at, and without naming the item.** Nothing observable connects them. A
  row pointing at a *summary* rather than at the work is the common shape of
  this, and it is the row author's to fix — point the row at the work.
- **Whether the new prose is true.** The contract forces the row into a human's
  hands at the moment its subject moves. It has no opinion on what they write.
- **`git cherry-pick`, `git am`, `git rebase`, `git revert`** — they create
  commits without running `git commit` or `git merge`.
- **A commit whose message comes from an editor.** The currency check is
  unaffected; only the claim check goes blind, and it says so on that run
  rather than reporting a clean claim check it never performed.

## No override

There is no in-the-moment escape token, and that is a decision rather than an
omission. What failed was in-the-moment judgment — "I will update the row after
the deploy" — made by the lander, at the moment of the land. An override would
have been reached for all four times. The way through is to delete the
declaration in a committed diff, which is an override with a memory.
