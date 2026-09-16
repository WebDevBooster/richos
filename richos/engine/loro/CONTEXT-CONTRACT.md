# Loro context and mutation contract

The context slice schema is version 1. The compiler's own version is independent
of the containing engine release. Additive fields may appear without changing the
slice schema; incompatible meanings require a new schema version.

## Root and scope

Every operation requires `--corpus`, `--root`, `LORO_CORPUS` or `LORO_ROOT`.
Flags outrank environment variables. `--corpus` selects the private partitioned
layout and refuses product source or an engine installation as a data location.
`--root` selects the explicit legacy repository layout.

Audiences are `rich`, `worker` and `org`. Only `rich` may receive `ceo-private`
records. Unknown audiences are refused. `--company` selects attention lanes; it
is not an access grant. A caller must also enforce its entity binding and audience.

The selected corpus root may be an alias. Descendant source directories and files
must be ordinary paths within that corpus. Linked source paths and multiply linked
files are refused before scope is assigned, so a shared alias cannot expose a
private page or borrow another company's records.

## Read commands

`compile --topic TEXT` returns one JSON slice containing `schemaVersion`,
`compiler`, `generatedAt`, `request`, `corpus`, `thin`, `coverage`, `text`, `items`,
`deepFetch`, `budget`, `matchedEntities` and `notes`. `--topic-stdin` avoids command
line escaping. The character budget bounds rendered text, not the JSON envelope.

Each company lane is ranked independently. Scores across lanes are not comparable.
An unused lane allocation is reported rather than redistributed. At a larger
character budget the selection must retain records that fit at the smaller budget.
Omitted records remain available through `fetch --ref REF`.

`fetch` reads historical references as well as current records. Superseded records
leave live selection but keep their references. `corpus` reports counts, problems
and coverage. Malformed records are reported; an empty valid corpus is distinct
from a missing root or compiler. Prose-derived kinds remain explicitly inferred.

Context command exits: 0 for success including an empty result, 2 for usage or
invalid configuration, 3 for an absent reference, 4 for scope refusal and 1 for
an internal failure. `--format text` is for people; JSON is the app interface.

## Write commands

`append` requires an explicit ID, kind and nonempty body. Scope defaults to
`ceo-private`. `correct` requires a reason. `supersede` creates a replacement
while retaining the old record and its reference. Widening scope requires the
explicit `--widen-scope` flag. `--dry-run` previews without modifying the corpus.
`--json` emits the writer receipt used by the app correction desk.

Mutating commands share an OS-managed SQLite lock per corpus. They wait up to
five seconds for another writer, then refuse with a retryable explanation.
Corrections and replacements reload their record while holding the lock instead
of trusting an earlier reader snapshot. The persistent `writer-lock.sqlite` file
is coordination state, not a stale lock to delete. Process exit releases the
lock automatically. Dry runs create no lock file. This serializes writers;
it does not make two separate record files an atomic filesystem transaction.

Prose sections and generated entity vocabulary are readable references but are
not typed beliefs the writer can silently supersede. Those operations explain
which source owns the content. Correcting a belief does not rewrite conversation
evidence or close an ECS obligation.

Coverage proposals are candidates. They never automatically promote a heading
into an authorized belief. Coverage baselines are explicit private corpus state.
